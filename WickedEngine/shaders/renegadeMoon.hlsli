// One embedded NASA SVS lunar albedo map shared by every phase.
// Artistic fixed phase is independent of the Time of Day orbit.
#ifndef RENEGADE_MOON_HLSLI
#define RENEGADE_MOON_HLSLI
float3 RenegadeMoonDirection(float3 sun,float4 orbit)
{
    float a=radians(orbit.x), c=cos(a), s=sin(a);
    if(orbit.z>.5)
    {
        float3 d=-normalize(sun);
        return float3(d.x*c+d.z*s,d.y,-d.x*s+d.z*c);
    }
    float e=radians(orbit.y);
    return float3(cos(e)*sin(a),sin(e),cos(e)*cos(a));
}
float4 RenegadeMoon(float3 ray,float3 sun,float4 settings,float4 orbit)
{
    [branch] if(settings.z<=0) return 0;
    float3 center=RenegadeMoonDirection(sun,orbit);
    [branch] if(center.y<-.12) return 0;
    float radius=radians(settings.y*.5);
    ray=normalize(ray);
    float facing=dot(ray,center);
    // Broad moon-centred atmospheric luminance (not a full-screen glow):
    // strongest next to the lunar disc and falling smoothly away into night.
    // Use the same orbit, phase, horizon and night conditions as the disc.
    float night=RenegadeNightWeight(sun);
    float horizon=smoothstep(-.02,.07,center.y);
    const float phaseVisible=saturate(0.5-0.5*cos(settings.x*6.283185307));
    const float angularDistance=1-saturate(facing);
    const float haloCore=exp2(-30.0*angularDistance);
    const float haloWide=exp2(-6.0*angularDistance);
    const float haloWeight=0.30*haloCore+0.70*haloWide;
    const float3 moonHalo=float3(.021,.028,.040)*haloWeight*
        settings.z*phaseVisible*night*horizon;
    [branch] if(facing<cos(radius*1.03)) return float4(moonHalo,0);
    // A polar-safe tangent basis also keeps the lunar north pole stable at zenith.
    float3 right=normalize(cross(abs(center.y)>.999?float3(0,0,1):float3(0,1,0),center));
    float3 up=cross(center,right);
    float2 uv=float2(dot(ray,right),dot(ray,up))/max(sin(radius),.00001);
    float rr=dot(uv,uv);
    float aa=.006; // derivative-free: sky is also evaluated by compute/reflection passes
    float mask=1-smoothstep(1-aa,1+aa,rr);
    [branch] if(mask<=0) return 0;
    float z=sqrt(saturate(1-rr));
    float angle=settings.x*6.283185307;
    // Quarter presets illuminate opposite limbs; full=.5, new=0/1.
    float illumination=max(0,dot(float3(uv,z),float3(sin(angle),0,-cos(angle))));
    float3 surface=.45;
    [branch] if(settings.w>=0)
    {
        float2 lunarUV=float2(atan2(uv.x,z)/6.283185307+.5,
            .5-asin(clamp(uv.y,-1,1))/3.141592654);
        surface=2.0*bindless_textures[descriptor_index((int)settings.w)].SampleLevel(sampler_linear_clamp,lunarUV,0).rgb;
    }
    float visibility=lerp(.12,1,night)*horizon;
    float3 tint=lerp(float3(1,.72,.48),float3(.92,.95,1),smoothstep(.02,.28,center.y));
    float3 colour=tint*surface*pow(illumination,.62)*settings.z*visibility;
    // Extinguish background stars behind the entire solid disc, including its dark limb.
    return float4(colour*mask+moonHalo,mask*night*horizon);
}
#endif
