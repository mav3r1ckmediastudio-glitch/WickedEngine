// Renegade Gate 1: continuous condensate, independent of primitive surfaces.
// Authored for the pinned Wicked renderer; no external cloud code or assets.
#ifndef RENEGADE_CLOUD_FORMATIONS
#define RENEGADE_CLOUD_FORMATIONS
#include "renegadeCloudBodyTemplate.hlsli"
Texture3D<float4> renegadeCloudBodyVolume : register(t5);
struct RenegadeCloudSiteData { float4 attributes; float4 variation; };
StructuredBuffer<RenegadeCloudSiteData> renegadeCloudSites : register(t6);


uint RenegadeWeatherMix(uint v)
{
    v^=v>>16; v*=0x7feb352d; v^=v>>15; v*=0x846ca68b; v^=v>>16;
    return v;
}
float RenegadeWeatherCorner(int2 p)
{
    uint v=RenegadeWeatherMix(uint(p.x)*0x9e3779b9 ^ uint(p.y)*0x85ebca6b);
    return float(v&0x00ffffff)*(1.0/16777216.0);
}
float RenegadeWeatherValue(float2 p)
{
    int2 cell=int2(floor(p)); float2 f=frac(p);
    f=f*f*(3.0-2.0*f);
    float a=lerp(RenegadeWeatherCorner(cell),RenegadeWeatherCorner(cell+int2(1,0)),f.x);
    float b=lerp(RenegadeWeatherCorner(cell+int2(0,1)),RenegadeWeatherCorner(cell+1),f.x);
    return lerp(a,b,f.y);
}
float RenegadeWeatherPotential(float2 p)
{
    // Kilometre-scale weather columns, independently eroded by a coarser 3D body.
    float2 q=p/8000.0;
    return .625*RenegadeWeatherValue(q)+
        .25*RenegadeWeatherValue(q*2.03+float2(31,-19))+
        .125*RenegadeWeatherValue(q*4.11+float2(-7,43));
}
float RenegadeWeatherQuantile(float percentile)
{
    // Deterministic CPU calibration: 60,000 world samples, seed 29.
    // Threshold percentiles request horizontal weather occupancy, not opacity.
    static const float q[17]={0,.271559245,.321706681,.358664150,.390764633,
        .419752751,.446584492,.473291274,.499413861,.524741851,.551015835,
        .578731550,.607285098,.638776428,.677073148,.726349200,1};
    float x=saturate(percentile)*16; uint i=min(15u,uint(x));
    return lerp(q[i],q[i+1],x-i);
}
float RenegadeSkyAdmission(float amount)
{
    // Inverse upper envelope from 48 GPU views: 3 world positions, 35/70 deg.
    // A sky ray can cross several weather columns; planar occupancy is not
    // screen occupancy. This conservative artist transfer avoids early ceilings.
    // It is a reference calibration, not a promise for every view or profile.
    static const float q[17]={0.000000000,0.016036240,0.032072480,0.048108720,0.064144960,0.080181200,0.096217441,0.124035898,0.155491381,0.186946863,0.227746517,0.275174169,0.345082843,0.446420756,0.552037618,0.694696583,1.000000000};
    float x=saturate(amount)*16; uint i=min(15u,uint(x));
    return lerp(q[i],q[i+1],x-i);
}
float2 RenegadeFormationBand(float mode)
{
    if(mode==2) return float2(.01,.95);
    if(mode==3) return float2(.01,.20);
    if(mode==4) return float2(.01,.25);
    if(mode==5) return float2(.70,.97);
    return float2(0,.81);
}
// Fit: mean positive-elevation opacity across 48 DX12 body-rank views per
// layer. Vulkan curves and held-out poses are independent checks. This is a
// statistical artist transfer; it never reads the camera or alters body shape.
float RenegadeWholeBodyAdmission(float amount)
{
    if(GetWeather().volumetric_clouds.layerFirst.padding1<0) return amount;
    static const float deep[17]={0.000000000,0.020709492,0.039102100,0.049963794,0.060825489,0.071687183,0.082548878,0.093410572,0.132991612,0.209745592,0.258204334,0.312359551,0.408737864,0.634868306,0.697662655,0.848831328,1.000000000};
    static const float thin[17]={0.000000000,0.024982940,0.049965880,0.066621073,0.081103914,0.095586756,0.161363079,0.223352948,0.264889812,0.314033762,0.407167366,0.576044386,0.649487219,0.710010010,0.854638447,0.927319224,1.000000000};
    float ratio=GetWeather().volumetric_clouds.cloudThickness/
        max(100.0,GetWeather().volumetric_clouds.cloudStartHeight);
    float t=saturate(log(max(.01,ratio)/(3190.0/2280.0))/
        log((5000.0/1500.0)/(3190.0/2280.0)));
    float x=saturate(amount)*16;uint i=min(15u,uint(x));
    return lerp(lerp(thin[i],thin[i+1],x-i),
        lerp(deep[i],deep[i+1],x-i),t);
}

float RenegadeFormationCoverage(float2 p,float h,float amount,float mode)
{
    if(amount<=0) return 0;
    // Cumulus admits complete 3D bodies inside the density function. This is
    // only a validity flag; no independent 2D footprint may clip the bodies.
    if(mode==1) return 1;
    float2 band=RenegadeFormationBand(mode);
    if(h<=band.x || h>=band.y) return 0;
    if(amount>=1) return 1;
    if(mode==5) p*=float2(.22,1.5);
    float potential=RenegadeWeatherPotential(p);
    // A positive weather potential grows complete broad columns continuously.
    // Coverage changes admission; it never scales extinction or optical density.
    float peak=GetWeather().volumetric_clouds.layerFirst.padding1;
    // Negative peak is used only by the explicit raw-calibration GPU proof.
    float planar=peak<0 ? amount : RenegadeSkyAdmission(amount);
    float admission=saturate((potential-RenegadeWeatherQuantile(1-planar))/.12);
    // Keep the native cloud body's local weather state fixed while admitting
    // more columns. Saturating local weather to 1 bypassed most native 3D
    // carving and made every admitted region an opaque deck.
    // The final range deliberately permits coalescence into full overcast.
    float localWeather=lerp(abs(peak),1.0,smoothstep(.88,1.0,amount));
    return admission*localWeather;
}
// Isolated morphology proof. No weather footprint clips this volume.
// The same continuous interior can later be cached and placed as whole bodies.
float RenegadeCumulusBody(Texture3D<float4> shapeTexture,
    Texture3D<float4> detailTexture,float3 p,float2 centre,float heightAboveBase,
    float2 radiusScale,float heightScale,float2 rotation,uint variant,
    float3 phase,float lod,bool detail,bool analytic)
{
    float depth=GetWeather().volumetric_clouds.cloudThickness;
    if(depth<=0) return 0;
    float vertical=max(.0001,depth/5000.0*heightScale);
    float2 delta=p.xz-centre;
    float2 horizontal=float2(rotation.x*delta.x-rotation.y*delta.y,
        rotation.y*delta.x+rotation.x*delta.y)/max(float2(.0001,.0001),radiusScale);
    float3 local=float3(horizontal.x,heightAboveBase/vertical,horizontal.y);
    if(any(abs(local.xz)>2300) || local.y<0 || local.y>3500) return 0;
    uint width,height,depthTexels;
    renegadeCloudBodyVolume.GetDimensions(width,height,depthTexels);
    float3 fieldResolution=float3(width/2,height/2,depthTexels);
    float3 extent=float3(5000,4000,5000);
    float4 geometry;
    #if defined(RENEGADE_CLOUD_ANALYTIC_REFERENCE)
    [branch] if(analytic)
        geometry=RenegadeCumulusTemplateGeometry(detailTexture,local,variant,extent/fieldResolution);
    else
    #endif
    {
        float mip=clamp(lod,0.0,6.0);
        float3 uv=(local+float3(2500,0,2500))/extent;
        // Match an independently clamped 3D texture at BOTH trilinear mips.
        float3 margin=.5*exp2(ceil(mip))/fieldResolution;
        uv=clamp(uv,margin,1-margin);
        uv.xy=(uv.xy+float2(variant&1u,variant>>1u))*.5;
        geometry=renegadeCloudBodyVolume.SampleLevel(sampler_linear_clamp,uv,mip);
    }
    float3 inverseScale=1.0/float3(max(.0001,radiusScale.x),vertical,max(.0001,radiusScale.y));
    // Chain rule: reference scalar / world gradient magnitude, in metres.
    float field=geometry.x/max(.0001,length(geometry.yzw*inverseScale));
    float edgeWidth=max(.01,min(100.0,depth*.025));
    // Fine erosion only subtracts. It cannot restore an already empty sample.
    if(field<=-edgeWidth) return 0;
    float3 noisePosition=p+phase;
    if(detail)
    {
        float3 fine=detailTexture.SampleLevel(sampler_linear_wrap,noisePosition/320.0,lod).rgb;
        float cells=saturate((dot(fine,float3(.625,.25,.125))-.640196)/(.867647-.640196));
        field-=(1-cells)*50;
    }
    if(field<=-edgeWidth) return 0;
    float4 n=shapeTexture.SampleLevel(sampler_linear_wrap,noisePosition/3200.0,lod);
    float fbm=dot(n.gba,float3(.625,.25,.125));
    float body=saturate(((n.r+1-fbm)/(2-fbm)-.602444)/(.858194-.602444));
    float water=lerp(.35,1.0,body);
    float baseWidth=max(.01,min(80.0,depth*.05));
    return smoothstep(0,baseWidth,heightAboveBase)*
        smoothstep(-edgeWidth,edgeWidth,field)*water*.10;
}
float RenegadeSingleCumulus(Texture3D<float4> shapeTexture,
    Texture3D<float4> detailTexture,float3 p,float lod,bool detail,float noiseWindY)
{
    // Private single-body proof: fraction .8/30 increments select each
    // immutable atlas variant in both cached and analytic shader packages.
    // Normal Studio states never enter this >2 density-test sentinel path.
    float sentinel=GetWeather().volumetric_clouds.layerFirst.padding1;
    bool analytic=sentinel<3;
    uint variant=min(3u,uint(max(0.0,round((frac(sentinel)-.8)*30.0))));
    return RenegadeCumulusBody(shapeTexture,detailTexture,p,float2(0,0),
        p.y-GetWeather().volumetric_clouds.cloudStartHeight,float2(1,1),1,float2(1,0),variant,
        float3(0,noiseWindY,0),lod,detail,analytic);
}
// Window is offset toward the nearest outer cell as the camera sample
// crosses each site-cell midpoint. Four candidates per axis preserve all
// shapes with |local.xz| <= 2300, max width scale 1.36, and +/-0.45 jitter.
// The far unlisted site's closest centre is 1.55 * 3000 = 4650 m;
// the rotated square's most distant supported point is
// sqrt(2) * 2300 * 1.36 = 4423.7 m. No valid body can be omitted.
int2 RenegadeSiteWindow(float2 p)
{
    float2 fraction=frac(p/3000.0);
    return int2(fraction.x<.5 ? -2 : -1,fraction.y<.5 ? -2 : -1);
}
float3 RenegadeSiteScale(float variation,float independentWidthSeed)
{
    // The cached body's X and Z axes have independent dimensions, rather
    // than every cloud being a uniformly scaled/rotated copy of its siblings.
    // Maximum axis 1.36 preserves the proved 4x4 candidate-window bound.
    return float3(lerp(.72,1.36,frac(variation*17.13)),
        lerp(.65,1.40,frac(variation*31.71+.37)),
        lerp(.72,1.36,independentWidthSeed));
}
float4 RenegadeWholeCloudSite(int2 cell,out float2 rotation,out float3 phase)
{
    uint2 wrapped=uint2(cell)&63u;
    RenegadeCloudSiteData cached=renegadeCloudSites[wrapped.x+wrapped.y*64u];
    rotation=cached.variation.xy;
    phase=float3(cached.attributes.w,cached.variation.zw)*20000;
    float2 centre=(float2(cell)+.5+cached.attributes.xy)*3000;
    return float4(centre,cached.attributes.zw);
}
// Cumulus-only weather payload: inside bounds R=height+1, G=candidate bits;
// outside R is negative conservative box distance, G=0. B remains rain=0.
// The 3D bounds enclose complete bodies; they never sculpt the cloud surface.
float3 RenegadeWholeCloudWeather(float3 p,float3 windOffset)
{
    float amount=GetWeather().volumetric_clouds.layerFirst.coverageAmount;
    if(amount<=0) return float3(-1000000,0,0);
    float peak=abs(GetWeather().volumetric_clouds.layerFirst.padding1);
    bool noSkip=frac(peak)>.85; // explicit proof sentinel only
    float depth=GetWeather().volumetric_clouds.cloudThickness;
    float3 planetCentre=GetWeather().atmosphere.planetCenter*1000.0;
    float height=peak>2 ? p.y-GetWeather().volumetric_clouds.cloudStartHeight :
        distance(p,planetCentre)-(GetWeather().atmosphere.bottomRadius*1000.0+
        GetWeather().volumetric_clouds.cloudStartHeight);
    // Condensation altitude belongs to unadvected world space. Native upward
    // wind animates NOISE; applying it to macro height empties the march layer.
    p.xz+=windOffset.xz;
    float probability=RenegadeWholeBodyAdmission(amount);
    float nearestSquared=1e12;
    uint mask=0;
    if(peak>2)
    {
        float vertical=max(.0001,depth/5000.0);
        float3 q=abs(float3(p.x,height-1750*vertical,p.z))-
            float3(2300,1750*vertical,2300);
        if(all(q<=0)) mask=1;
        float3 outside=max(q,0);nearestSquared=dot(outside,outside);
    }
    else
    {
        int2 cell=int2(floor(p.xz/3000.0));
        int2 start=RenegadeSiteWindow(p.xz);
        [loop] for(int iz=0;iz<4;++iz)
        [loop] for(int ix=0;ix<4;++ix)
        {
            // Test the cached admission rank before deriving rotation, phase,
            // centres, growth and oriented bounds. Rejected bodies must not
            // perform their per-sample geometry work (same exact density).
            int2 candidate=cell+start+int2(ix,iz);
            uint2 wrapped=uint2(candidate)&63u;
            RenegadeCloudSiteData cached=renegadeCloudSites[wrapped.x+wrapped.y*64u];
            float activation=smoothstep(cached.attributes.z-.03125,
                cached.attributes.z+.03125,probability);
            if(activation<=0) continue;
            float2 rotation=cached.variation.xy;
            float3 phase=float3(cached.attributes.w,cached.variation.zw)*20000;
            float4 site=float4((float2(candidate)+.5+cached.attributes.xy)*3000,
                cached.attributes.zw);
            float growth=sqrt(activation);
            float3 scale=RenegadeSiteScale(site.w,frac(phase.z/20000.0));
            float2 radius=float2(scale.x,scale.z)*growth;
            float vertical=max(.0001,depth/5000.0*scale.y*growth);
            float2 delta=p.xz-site.xy;
            float2 horizontal=float2(rotation.x*delta.x-rotation.y*delta.y,
                rotation.y*delta.x+rotation.x*delta.y);
            float3 q=abs(float3(horizontal.x,height-1750*vertical,horizontal.y))-
                float3(2300*radius.x,1750*vertical,2300*radius.y);
            if(all(q<=0)) mask|=1u<<uint(iz*4+ix);
            float3 outside=max(q,0);
            nearestSquared=min(nearestSquared,dot(outside,outside));
        }
        float sheetHeight=min(350.0,depth*.20)*smoothstep(.94,1.0,amount);
        if(sheetHeight>0)
        {
            float distanceToSheet=max(-height,height-sheetHeight);
            if(distanceToSheet<=0) mask|=65536u;
            nearestSquared=min(nearestSquared,max(0.0,distanceToSheet)*max(0.0,distanceToSheet));
        }
    }
    if(mask!=0 || noSkip) return float3(max(.0001,height+1),float(mask),0);
    // The nearest *unvisited* site has a minimum 4650-m centre distance;
    // its largest rotated local support is 4423.7 m. Even when every
    // visited body is far away, do not skip more than that safety gap.
    // A conservative 220 m cap protects the raymarch outside this window.
    nearestSquared=min(nearestSquared,220.0*220.0);
    return float3(-sqrt(nearestSquared),0,0);
}

float RenegadeWholeCumulus(Texture3D<float4> shapeTexture,
    Texture3D<float4> detailTexture,float3 p,float2 weather,float lod,bool detail,float noiseWindY)
{
    float amount=GetWeather().volumetric_clouds.layerFirst.coverageAmount;
    if(amount<=0) return 0;
    float probability=RenegadeWholeBodyAdmission(amount);
    float height=weather.x-1;
    uint mask=uint(weather.y);
    if(mask==0 || height<0) return 0;
    int2 cell=int2(floor(p.xz/3000.0));
    int2 start=RenegadeSiteWindow(p.xz);
    float density=0;
    uint candidates=mask&65535u;
    [loop] while(candidates!=0)
    {
        uint index=firstbitlow(candidates);candidates&=candidates-1;
        int2 c=cell+start+int2(int(index%4),int(index/4));
        float2 rotation;float3 phase;
        float4 site=RenegadeWholeCloudSite(c,rotation,phase);
        float activation=smoothstep(site.z-.03125,site.z+.03125,probability);
        float growth=sqrt(activation);
        float3 scale=RenegadeSiteScale(site.w,frac(phase.z/20000.0));
        float2 radius=float2(scale.x,scale.z)*growth;
        float heightScale=scale.y*growth;
        uint variant=min(3u,uint(site.w*4));
        float peak=abs(GetWeather().volumetric_clouds.layerFirst.padding1);
        bool analytic=peak>1 && peak<2;
        phase.y+=noiseWindY;
        density+=RenegadeCumulusBody(shapeTexture,detailTexture,p,site.xy,
            height,radius,heightScale,rotation,variant,phase,lod,detail,analytic);
        if(density>=.10) return .10;
    }
    float depth=GetWeather().volumetric_clouds.cloudThickness;
    float coalescence=smoothstep(.94,1.0,amount);
    float sheet=min(350.0,depth*.20)*coalescence-height;
    float baseWidth=max(.01,min(80.0,depth*.05));
    float edgeWidth=max(.01,min(100.0,depth*.025));
    float overcast=smoothstep(0,baseWidth,height)*smoothstep(0,edgeWidth,sheet)*.08;
    return min(.10,max(density,overcast));
}


// Gate 1 independent-volume experiment (Cumulus only).
// Coverage selects weather support; morphology never reads the request.
float RenegadeIndependentCumulus(Texture3D<float4> shapeTexture,
    Texture3D<float4> detailTexture,float3 p,float h,float2 weather,float lod,bool detail,float noiseWindY)
{
    if(GetWeather().volumetric_clouds.layerFirst.padding1>2)
        return RenegadeSingleCumulus(shapeTexture,detailTexture,p,lod,detail,noiseWindY);
    return RenegadeWholeCumulus(shapeTexture,detailTexture,p,weather,lod,detail,noiseWindY);
}

// The existing Wicked 3D density/erosion kernel remains unchanged.
// Only the profile inputs and independent weather distribution are selected.
float4 RenegadeNativeFormationGradient(float mode,float3 typeMask)
{
    if(mode==2) return float4(.01,.06,.75,.95);
    if(mode==3) return float4(.01,.10,.11,.20);
    if(mode==4) return float4(.01,.06,.10,.25);
    if(mode==5) return float4(.70,.74,.90,.97);
    float growth=saturate(typeMask.z+.5*typeMask.y);
    float top=lerp(.40,.80,growth);
    return float4(.01,.06,top*.60,top);
}
float4 RenegadeNativeFormationAnvil(float mode)
{
    // Ordinary cumulus has one continuous interior. The old fixed medium
    // anvil curve suppressed the middle and exposed repeated horizontal bands.
    if(mode==1) return 0;
    if(mode==2) return float4(5,.25,5,.15);
    return 0;
}
float RenegadeCloudMarchTopRadius(float nativeTop)
{
    float mode=GetWeather().volumetric_clouds.layerFirst.padding0;
    if(mode<1 || mode>5 || GetWeather().volumetric_clouds.layerSecond.coverageAmount>0 ||
        GetWeather().volumetric_clouds.layerSecond.coverageMinimum>0) return nativeTop;
    return nativeTop-GetWeather().volumetric_clouds.cloudThickness*(1-RenegadeFormationBand(mode).y);
}
bool RenegadeHighCloudLayerOnly()
{
    return GetWeather().volumetric_clouds.layerFirst.padding0==5 &&
        GetWeather().volumetric_clouds.layerSecond.coverageAmount<=0 &&
        GetWeather().volumetric_clouds.layerSecond.coverageMinimum<=0;
}
float RenegadeCloudMarchBottomRadius(float nativeBottom)
{
    return nativeBottom+(RenegadeHighCloudLayerOnly() ?
        GetWeather().volumetric_clouds.cloudThickness*.70 : 0);
}
float RenegadeCloudMarchRenderDistance(float planetRadius,float outerRadius,float nativeDistance)
{
    if(!RenegadeHighCloudLayerOnly()) return nativeDistance;
    float altitude=max(0.0,outerRadius-planetRadius);
    return max(nativeDistance,sqrt(altitude*(2*planetRadius+altitude)));
}
float RenegadeCloudHorizonDistance(float nativeDistance)
{
    if(!RenegadeHighCloudLayerOnly()) return nativeDistance;
    float base=max(100.0,GetWeather().volumetric_clouds.cloudStartHeight);
    return nativeDistance*base/(base+.70*GetWeather().volumetric_clouds.cloudThickness);
}
#endif
