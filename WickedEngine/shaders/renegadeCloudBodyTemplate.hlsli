#ifndef RENEGADE_CLOUD_BODY_TEMPLATE
#define RENEGADE_CLOUD_BODY_TEMPLATE
// Authored reference-space morphology. Evaluated only when baking the atlas
// or in an explicit analytic QA permutation; no camera, weather, or coverage.
float RenegadeThermalInterior(float3 p,float3 centre,float3 radii)
{
    float3 q=(p-centre)/radii;
    float k=length(q);
    if(k<.0001) return min(radii.x,min(radii.y,radii.z));
    // First-order signed distance of each ellipsoid, in reference metres.
    return k*(1-k)/max(.000001,length(q/radii));
}
float RenegadeMergeThermals(float a,float b,float width)
{
    // Merging is subordinate to thermal size; avoid a single 200 m pillow.
    float h=saturate(.5+.5*(a-b)/width);
    return lerp(b,a,h)+width*h*(1-h);
}
uint RenegadeThermalHash(uint v)
{
    v^=v>>16;v*=0x7feb352du;v^=v>>15;v*=0x846ca68bu;v^=v>>16;
    return v;
}
float3 RenegadeThermalVariation(uint variant,uint index)
{
    uint seed=variant*0x9e3779b9u+index*0x85ebca6bu+0x219c637eu;
    return float3(
        RenegadeThermalHash(seed)&0x00ffffffu,
        RenegadeThermalHash(seed^0x4a39b70du)&0x00ffffffu,
        RenegadeThermalHash(seed^0x12cfa21bu)&0x00ffffffu)
        * (1.0/16777216.0);
}
float3 RenegadeBodyVariantPhase(uint variant)
{
    if(variant==1) return float3(731,2959,-293);
    if(variant==2) return float3(-1307,1719,1871);
    if(variant==3) return float3(2449,883,311);
    return float3(0,1500,0);
}
float RenegadeCumulusTemplateField(Texture3D<float4> detailTexture,float3 local,uint variant)
{
    float3 baseSeed=RenegadeThermalVariation(variant,17u);
    // Low-frequency 3D displacement breaks perfectly spherical thermal lobes.
    // Apply to the entire coherent body rather than a camera-facing opacity
    // mask: the baked volume keeps continuous tops, sides and underside.
    float3 largeNoise=detailTexture.SampleLevel(sampler_linear_wrap,
        (local+RenegadeBodyVariantPhase(variant))/1650.0,0).rgb;
    float3 smallNoise=detailTexture.SampleLevel(sampler_linear_wrap,
        (local+RenegadeBodyVariantPhase(variant)*.71)/720.0,0).rgb;
    float3 warped=local+float3((largeNoise.x-.5)*245+(smallNoise.z-.5)*90,
        (largeNoise.y-.5)*135+(smallNoise.x-.5)*75,
        (largeNoise.z-.5)*245+(smallNoise.y-.5)*90);
    // Connected condensation base with uneven shoulder height. It reaches
    // layer zero locally, but the higher lobes are genuinely 3D, not columns.
    // Four Cumulus subfamilies: broad/low, narrow/high, multi-core and
    // slightly leaning. This does NOT implement the other four Weather types.
    float footprint=variant==0u?1.18:(variant==1u?.86:(variant==2u?1.09:.96));
    float3 baseRadii=float3(1120+baseSeed.y*220,420+baseSeed.z*120,
        1050+baseSeed.x*250);
    baseRadii.xz*=footprint;
    float field=RenegadeThermalInterior(warped,
        float3((baseSeed.x-.5)*160,385+(baseSeed.y-.5)*110,(baseSeed.z-.5)*180),
        baseRadii);
    // Coherent shoulders support rising towers and optional crown lobes.
    // All tiers are signed 3D bodies, not 2D masks or sprite clouds.
    [unroll] for(uint i=0u;i<10u;++i)
    {
        float3 seed=RenegadeThermalVariation(variant,i);
        uint tier=(i<3u)?0u:((i<6u)?1u:2u);
        uint index=tier==0u?i:(tier==1u?i-3u:i-6u);
        // Different *structural* silhouettes, not just four noise seeds.
        if(variant==0u && tier==2u) continue; // fair-weather, no tall crown
        if(variant==1u && tier==0u && index==1u) continue; // narrow base
        if(variant==2u && tier==2u && index>=2u) continue; // twin crowns
        if(variant==3u && tier==0u && index==1u) continue; // asymmetrical base
        float count=tier==2u?4.0:3.0;
        float angle=6.28318530718*(float(index)+.38*(seed.x-.5))/count
            +.71*float(variant)+.41*float(tier);
        float radial=tier==0u?680+(seed.y-.5)*340:
            (tier==1u?370+(seed.y-.5)*330:410+(seed.y-.5)*340);
        float altitude=tier==0u?690+seed.z*330:
            (tier==1u?1400+seed.z*560:2220+seed.z*430);
        if(variant==0u && tier==1u) altitude-=220;
        if(variant==1u && tier==2u) altitude+=140;
        if(variant==2u && tier==2u) altitude-=180;
        // Break three globally identical horizontal lobe shelves. Thermal
        // rise varies from one updraft to the next, even within a formation.
        altitude+=(seed.x-.5)*(tier==0u?420:(tier==1u?690:320));
        float3 radii=tier==0u?
            float3(690+seed.x*190,590+seed.y*230,690+seed.z*170):
            (tier==1u?
            float3(570+seed.x*210,840+seed.y*240,540+seed.z*220):
            float3(340+seed.x*240,480+seed.y*190,360+seed.z*210));
        radii.xz*=footprint;
        // Reserve 150m for native billow displacement and 75m for the crown
        // union before the 3500m cached-volume support. Do not slice tops.
        if(tier>=1u) altitude=min(altitude,3180.0-radii.y);
        // Avoid equal-radius spokes and repeated vertical side towers.
        radial*=lerp(.71,1.18,seed.z);
        float3 centre=float3(cos(angle)*radial,altitude,sin(angle)*radial);
        if(variant==3u) centre.x+=180.0*float(tier);
        float lobe=RenegadeThermalInterior(warped,centre,radii);
        // Much narrower connections keep distinct thermal silhouettes.
        float join=tier==0u?145.0:(tier==1u?125.0:75.0);
        field=RenegadeMergeThermals(field,lobe,join);
    }
    // Existing native detail is only a surface perturbation, not the
    // distribution or the source of the large-scale cloud formation.
    float billow=detailTexture.SampleLevel(sampler_linear_wrap,
        (local+RenegadeBodyVariantPhase(variant))/1000.0,0).a;
    // Two world-scale billow octaves remain subordinate to the connected
    // macro body; the smaller octave gives cauliflower detail, not wisps.
    float finer=detailTexture.SampleLevel(sampler_linear_wrap,
        (local+RenegadeBodyVariantPhase(variant)*1.37)/480.0,0).b;
    return field+(billow-.5)*365+(finer-.5)*115;
}
// Value plus local gradient in metres: the same oracle feeds generator and
// diagnostics. The production camera/shadow kernels only sample baked RGBA16F.
float4 RenegadeCumulusTemplateGeometry(Texture3D<float4> detailTexture,
    float3 local,uint variant,float3 derivativeStep)
{
    float field=RenegadeCumulusTemplateField(detailTexture,local,variant);
    float3 gradient=0;
    [loop] for(uint axis=0;axis<3;++axis)
    {
        float3 offset=0;offset[axis]=derivativeStep[axis];
        float positive=RenegadeCumulusTemplateField(detailTexture,local+offset,variant);
        float negative=RenegadeCumulusTemplateField(detailTexture,local-offset,variant);
        gradient[axis]=(positive-negative)/(2*derivativeStep[axis]);
    }
    return float4(field,gradient);
}
#endif
