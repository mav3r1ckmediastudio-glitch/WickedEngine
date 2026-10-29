// Renegade Night Atmosphere — optional gradient composited with Wicked realistic sky.
#ifndef RENEGADE_NIGHT_ATMOSPHERE_HLSLI
#define RENEGADE_NIGHT_ATMOSPHERE_HLSLI

float RenegadeNightWeight(float3 sun)
{
    float depth = -normalize(sun).y;
    float t = saturate((depth - 0.052336f) / (0.207912f - 0.052336f));
    return t*t*(3.0f-2.0f*t);
}
float3 RenegadeNightGradient(float3 direction, float3 sun,
                             float brightness, float4 zenith, float4 horizon)
{
    float w = RenegadeNightWeight(sun) * saturate(brightness);
    [branch] if(w <= 0.00001f) return 0;
    float elevation = normalize(direction).y;
    float z = smoothstep(0.12f, 0.96f, saturate(elevation));
    float h = pow(1.0f-smoothstep(0.0f, 0.55f, saturate(elevation)), 3.0f);
    float3 midSky = lerp(zenith.rgb, horizon.rgb, 0.30f);
    float3 colour = lerp(midSky, zenith.rgb, z) +
                    horizon.rgb * saturate(horizon.a / 2.0f) * h;
    float skyMask = smoothstep(-0.035f, 0.03f, elevation);
    return max(colour, 0) * skyMask * w;
}
#endif
