// Optional volumetric aurora curtains, composited by Wicked's realistic sky.
#ifndef RENEGADE_AURORA_HLSLI
#define RENEGADE_AURORA_HLSLI

float RenegadeAuroraHash(float2 p)
{
    float3 q = frac(float3(p.x, p.y, p.x) * 0.1031f);
    q += dot(q, q.yzx + 33.33f);
    return frac((q.x + q.y) * q.z);
}
float RenegadeAuroraNoise(float2 p)
{
    float2 i = floor(p), f = frac(p);
    f = f * f * (3.0f - 2.0f * f);
    return lerp(lerp(RenegadeAuroraHash(i), RenegadeAuroraHash(i + float2(1,0)), f.x),
                lerp(RenegadeAuroraHash(i + float2(0,1)),
                     RenegadeAuroraHash(i + float2(1,1)), f.x), f.y);
}
float3 RenegadeAurora(float3 direction, float3 sun,
    float intensity, float speed, float coverage, float seconds)
{
    const float night = RenegadeNightWeight(sun);
    const float strength = night * saturate(intensity);
    [branch] if (strength <= 0.0001f || coverage <= 0.0001f) return 0;
    const float3 V = normalize(direction);
    [branch] if (V.y <= 0.015f) return 0;

    const float t = seconds * clamp(speed, 0.0f, 2.0f);
    const float azimuth = atan2(V.x, V.z);
    coverage = saturate(coverage);
    const float span = lerp(0.55f, 3.55f, coverage);
    const float localExtent = 1.0f - smoothstep(span * 0.68f, span, abs(azimuth));
    const float extent = lerp(localExtent, 1.0f, smoothstep(0.25f, 0.85f, coverage));
    [branch] if (extent <= 0.0001f) return 0;

    // Periodic angular coordinates have no seam behind the viewer.
    const float2 around = float2(sin(azimuth), cos(azimuth));
    const float broad = RenegadeAuroraNoise(around * 2.5f + float2(t * 0.025f, 0));
    const float upperNoise = RenegadeAuroraNoise(around * 3.2f + float2(8, 11 + t * 0.02f));
    const float patchA = max(smoothstep(lerp(0.78f, 0.25f, coverage),
                                   lerp(0.92f, 0.48f, coverage), broad),
        localExtent * (1.0f - smoothstep(0.30f, 0.70f, coverage)));
    const float patchB = smoothstep(lerp(0.86f, 0.34f, coverage),
                                   lerp(0.98f, 0.58f, coverage), upperNoise)
        * smoothstep(0.25f, 0.85f, coverage);
    [branch] if (patchA + patchB <= 0.0001f) return 0;
    const float foldA = 2.65f + 0.65f * sin(azimuth * 3.0f + t * 0.10f)
        + 0.30f * sin(azimuth * 7.0f - t * 0.065f);
    const float foldB = 0.90f + 0.30f * sin(azimuth * 2.0f - t * 0.06f + 1.5f)
        + 0.15f * sin(azimuth * 5.0f + t * 0.045f);

    // Broken outer curtains wrap around the viewer; a separate inner sheet
    // reaches overhead as coverage grows. Coverage changes occupied sky area,
    // leaving clear gaps instead of merely stretching a strip in front.
    // Altitude units are normalized; camera travel does not move the sky.
    const int STEPS = 128;
    const float dh = 1.9f / STEPS;
    const float stepLength = min(dh / max(V.y, 0.07f), 0.42f);
    float3 radiance = 0;
    [loop] for (int i = 0; i < STEPS; ++i)
    {
        const float h = 0.78f + (i + 0.5f) * dh;
        const float2 p = V.xz * (h / max(V.y, 0.07f));
        const float radius = length(p);
        // Height-dependent folds and low-contrast detail prevent rigid spokes.
        const float curl = 0.10f * sin(azimuth * 5.0f + h * 2.2f + t * 0.045f);
        const float fine = RenegadeAuroraNoise(around * 15.0f
            + float2(h * 2.3f + t * 0.075f, h * 0.7f));
        const float rays = 0.45f + 0.55f * fine;
        const float dA = (radius - foldA - curl) / 0.26f;
        const float dB = (radius - foldB + curl * 0.65f) / 0.20f;
        const float sheets = patchA * exp2(-dA * dA * 1.45f)
            + 0.75f * patchB * exp2(-dB * dB * 1.45f);
        const float base = 0.81f + 0.095f * sin(azimuth * 4.0f + t * 0.035f);
        const float altitude = saturate((h - base) / 1.55f);
        const float vertical = smoothstep(0.0f, 0.075f, h - base)
            * exp2(-altitude * 1.5f)
            * (1.0f - smoothstep(0.73f, 1.0f, altitude));
        // Green lower folds rise into pink upper wisps.
        const float pink = smoothstep(0.28f, 0.78f, altitude);
        float3 emission = lerp(float3(0.12f, 1.0f, 0.32f),
                               float3(1.0f, 0.18f, 0.52f), pink);
        emission += float3(0.0f, 0.22f, 0.28f) * exp2(-altitude * 10.0f);
        radiance += emission * sheets * vertical * rays
            * (0.65f + 0.35f * broad) * stepLength;
    }
    return radiance * (0.50f * strength * extent)
        * smoothstep(0.04f, 0.18f, V.y) * smoothstep(0.0f, 0.08f, coverage);
}
#endif
