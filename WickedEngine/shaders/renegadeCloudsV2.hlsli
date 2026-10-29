// Renegade Clouds V2 / Gate 1: real volumetric formation refinement.
// This works on the existing 3D shape + detail noise evaluated at every
// raymarch sample. It is deliberately not a billboard or screen-space effect.
// The same density sampler is used by primary rays and cloud self-shadow rays.
// No additional 3D texture fetches, compute passes, or GPU ABI modifications.
#ifndef RENEGADE_CLOUDS_V2_HLSLI
#define RENEGADE_CLOUDS_V2_HLSLI

float RenegadeSculptCloudHeight(float heightFraction, float4 shapeNoises,
                                float3 weatherData)
{
    // Low- and middle-frequency *3D* Worley ridges give neighbouring columns
    // irregular vertical growth. Keep bases relatively level, as moisture
    // collects at roughly one altitude, while upper billows become sculpted.
    const float billow = saturate(
        shapeNoises.g * 0.68f + shapeNoises.b * 0.32f);
    const float updraft = (billow - 0.48f) * 0.56f;

    // Weather types affect how strongly the upper body can grow.
    // Larger weather map types become taller with more broken silhouettes.
    const float tallType = smoothstep(0.35f, 0.80f, weatherData.g);
    const float lift = lerp(0.55f, 1.0f, tallType);
    const float upperWeight = smoothstep(0.12f, 0.68f, heightFraction);

    // Subtract lift: the density height gradient will extend farther upward
    // where local 3D noise is strong. No change to the actual cloud volume
    // boundaries; both raymarch and shadow paths evaluate the same function.
    return saturate(heightFraction - updraft * upperWeight * lift);
}

float RenegadePreserveCloudErosionDetail(
    float density, float3 detailNoises, float heightFraction)
{
    // Wicked already performs Worley erosion. Retain high-frequency edges
    // during its final remap, but do not add noise throughout opaque cores.
    const float fine = saturate(detailNoises.r * 0.50f +
                                detailNoises.g * 0.32f +
                                detailNoises.b * 0.18f);
    const float edge = saturate(density * (1.0f - density) * 4.0f);
    const float upperDetail = lerp(0.6f, 1.0f,
                                  smoothstep(0.18f, 0.80f, heightFraction));
    return saturate(density + (fine - 0.5f) * 0.24f * edge * upperDetail);
}

float RenegadeResolveCloudCoverage(float weatherMapCoverage,
                                   float authoredCoverage,
                                   float authoredMinimum)
{
    // Wicked's old weatherMapCoverage * authoredCoverage never reaches a
    // spatially solid overcast, even at the UI maximum of 1.0. Treat the
    // upper end of Renegade's primary Coverage slider as an overcast blend.
    // Weather-map islands still define broken cumulus at low/medium values.
    const float amount = saturate(authoredCoverage);
    // Equivalent to Wicked's RemapClamped(.., 0, 1, minimum, 1),
    // expressed without an include-order dependency.
    const float nativeCoverage = lerp(
        authoredMinimum, 1.0f, saturate(weatherMapCoverage * amount));
    const float overcastBlend = smoothstep(0.88f, 1.0f, amount);
    // Only weather DISTRIBUTION is altered. Every sample still goes through
    // 3D Worley shaping, erosion, raymarch lighting and cloud self-shadow.
    return lerp(nativeCoverage, 1.0f, overcastBlend);
}

#endif // RENEGADE_CLOUDS_V2_HLSLI
