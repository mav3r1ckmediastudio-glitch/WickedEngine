// Procedural galactic band. Independent of the native stars and aurora.
#ifndef RENEGADE_MILKY_WAY_HLSLI
#define RENEGADE_MILKY_WAY_HLSLI
float RenegadeGalaxyHash(float3 p)
{
    p = frac(p * 0.1031f);
    p += dot(p, p.yzx + 33.33f);
    return frac((p.x + p.y) * p.z);
}
float RenegadeGalaxyNoise(float3 p)
{
    const float3 i = floor(p);
    float3 f = frac(p);
    f = f*f*(3.0f-2.0f*f);
    return lerp(
        lerp(lerp(RenegadeGalaxyHash(i), RenegadeGalaxyHash(i+float3(1,0,0)),f.x),
             lerp(RenegadeGalaxyHash(i+float3(0,1,0)),RenegadeGalaxyHash(i+float3(1,1,0)),f.x),f.y),
        lerp(lerp(RenegadeGalaxyHash(i+float3(0,0,1)),RenegadeGalaxyHash(i+float3(1,0,1)),f.x),
             lerp(RenegadeGalaxyHash(i+float3(0,1,1)),RenegadeGalaxyHash(i+float3(1,1,1)),f.x),f.y),f.z);
}
float RenegadeGalaxyFBM(float3 p)
{
    float sum = 0, amplitude = 0.5f;
    [unroll] for (int i=0;i<5;++i)
    {
        sum += amplitude * RenegadeGalaxyNoise(p);
        p = p * 2.07f + float3(17.1f,9.2f,4.7f);
        amplitude *= 0.5f;
    }
    return sum;
}
float RenegadeGalaxyStar(float2 uv, float threshold)
{
    const float2 cell = floor(uv);
    const float seed = RenegadeGalaxyHash(float3(cell,7));
    const float2 centre = float2(RenegadeGalaxyHash(float3(cell,13)),
                                RenegadeGalaxyHash(float3(cell,29)));
    const float2 delta = frac(uv)-lerp(0.15f,0.85f,centre);
    return exp2(-dot(delta,delta)*260.0f) * step(threshold,seed);
}
float3 RenegadeMilkyWay(float3 direction, float3 sun, float intensity)
{
    const float strength = saturate(intensity) * RenegadeNightWeight(sun);
    [branch] if (strength <= 0.0001f) return 0;
    const float3 V = normalize(direction);
    const float horizon = smoothstep(-0.015f,0.10f,V.y);
    [branch] if (horizon <= 0.0001f) return 0;

    const float3 N = normalize(float3(0.58f,0.64f,-0.24f));
    const float3 coreHint = float3(0.35f,0.50f,1.0f);
    const float3 coreDirection = normalize(coreHint-N*dot(coreHint,N));
    const float core = exp2((dot(V,coreDirection)-1.0f)*12.0f);
    const float latitude = dot(V,N);
    const float width = lerp(0.085f,0.22f,core);
    const float envelope = exp2(-pow(latitude/width,2.0f)*1.6f);
    [branch] if (envelope < 0.0001f) return 0;

    const float3 axis = normalize(cross(N,float3(0,1,0)));
    const float3 tangent = cross(N,axis);
    const float longitude = atan2(dot(V,tangent),dot(V,axis));
    // Domain-warped multi-scale structure avoids a smooth uniform stripe.
    const float3 warp = float3(RenegadeGalaxyNoise(V*7.0f+float3(1,3,7)),
        RenegadeGalaxyNoise(V*7.0f+float3(17,9,2)),
        RenegadeGalaxyNoise(V*7.0f+float3(43,5,11)));
    const float3 p = V*18.0f + warp*3.2f;
    const float clouds = RenegadeGalaxyFBM(p);
    const float filaments = RenegadeGalaxyFBM(p*3.1f+float3(19,2,31));
    const float knots = pow(saturate((filaments-0.25f)*2.2f),2.0f);
    const float dustNoise = RenegadeGalaxyFBM(V*28.0f+float3(3,29,7));
    const float laneOffset = 0.035f*sin(longitude*3.0f)
        + 0.08f*(RenegadeGalaxyNoise(V*12.0f)-0.5f)
        + 0.025f*(RenegadeGalaxyNoise(V*55.0f)-0.5f);
    const float laneWidth = lerp(0.018f,0.085f,clouds);
    const float mainRift = exp2(-pow((latitude-laneOffset)/laneWidth,2.0f)*1.8f)
        * saturate(0.35f+1.3f*dustNoise);
    const float branchOffset = laneOffset+0.065f+0.045f*sin(longitude*6.0f);
    const float branchRift = exp2(-pow((latitude-branchOffset)/0.027f,2.0f))
        * smoothstep(0.32f,0.65f,dustNoise);
    const float dust = saturate(mainRift+0.65f*branchRift
        + 0.40f*smoothstep(0.55f,0.75f,dustNoise));

    const float hue = RenegadeGalaxyNoise(V*9.0f+float3(5,17,37));
    const float3 coolColour = lerp(float3(0.28f,0.45f,1.0f),
        float3(0.68f,0.35f,0.95f),smoothstep(0.25f,0.75f,hue));
    const float warmHue = smoothstep(0.25f,0.72f,
        RenegadeGalaxyNoise(V*17.0f+float3(31,7,23)));
    const float3 warmColour = lerp(float3(1.0f,0.40f,0.65f),
        float3(1.0f,0.78f,0.62f),warmHue);
    const float3 colour = lerp(coolColour,warmColour,
        smoothstep(0.20f,0.75f,core)*(0.50f+0.45f*hue));
    const float structure = 0.30f+1.8f*clouds+1.3f*knots;
    float3 radiance = colour*envelope*structure*(0.018f+0.30f*core)
        * (1.0f-0.92f*dust);
    const float rose = pow(saturate((RenegadeGalaxyNoise(V*36.0f+float3(11,5,19))-0.48f)*4.0f),2.0f);
    radiance += float3(1.0f,0.30f,0.48f)*rose*0.045f*envelope
        * (0.3f+0.7f*core)*(1.0f-0.7f*dust);
    radiance *= 0.92f+0.18f*RenegadeGalaxyNoise(V*400.0f);

    const float fineStars = RenegadeGalaxyStar(float2(longitude*460.0f,latitude*900.0f),0.12f);
    const float brightStars = RenegadeGalaxyStar(float2(longitude*100.0f,latitude*210.0f),0.80f);
    const float3 starColour = lerp(float3(0.52f,0.67f,1.0f),float3(1.0f,0.87f,0.74f),core*0.6f);
    radiance += starColour*(fineStars*0.022f+brightStars*0.12f)
        * envelope*(0.35f+1.2f*clouds)*(1.0f-0.85f*dust);
    return radiance*strength*horizon;
}
#endif
