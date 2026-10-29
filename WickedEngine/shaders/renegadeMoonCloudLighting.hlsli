// Renegade Moonlit Clouds V1.
// Use the existing lunar disc's phase and orbit for the dominant nocturnal cloud light.
// The ordinary Wicked cloud raymarch, atmospheric attenuation, cloud self-shadow
// samples and scattering phase are reused. No extra cloud raymarch is added.
#ifndef RENEGADE_MOON_CLOUD_LIGHTING_HLSLI
#define RENEGADE_MOON_CLOUD_LIGHTING_HLSLI

float3 RenegadeCloudMoonDirection(float3 sunDirection, float4 orbit)
{
    // Must match RenegadeMoonDirection() in renegadeMoon.hlsli.
    const float azimuth = radians(orbit.x);
    const float c = cos(azimuth);
    const float s = sin(azimuth);
    if (orbit.z > 0.5f)
    {
        const float3 d = -normalize(sunDirection);
        return float3(d.x*c + d.z*s, d.y, -d.x*s + d.z*c);
    }
    const float elevation = radians(orbit.y);
    return float3(cos(elevation)*sin(azimuth), sin(elevation),
                  cos(elevation)*cos(azimuth));
}

// Gate 2: single dominant light, smooth twilight energy envelope.
// No extra raymarch or shadow samples and never interpolate opposing
// Sun and Moon directions (which would create a fictional third light).
// The outgoing Sun reaches zero energy before lunar direction is selected.
void RenegadeApplyMoonlightToClouds(
    inout float3 lightDirection, inout float3 lightIlluminance,
    float4 moonParameters, float4 moonOrbit)
{
    const float sunElevation = lightDirection.y;
    // Preserve the accepted Gate 1 daytime source exactly.
    if (sunElevation >= -0.04f)
        return;

    // Fade solar direct cloud illumination smoothly through civil dusk.
    // Direction remains the real Sun until its direct contribution is zero.
    if (sunElevation > -0.10f)
    {
        lightIlluminance *= smoothstep(-0.10f, -0.04f, sunElevation);
        return;
    }

    // At night there is no physically sensible below-horizon Sun source.
    // Ambient sky illumination is handled independently by Wicked.
    lightIlluminance = float3(0.0f, 0.0f, 0.0f);
    if (moonParameters.z <= 0.0f)
        return;

    const float3 lunarDirection = normalize(
        RenegadeCloudMoonDirection(lightDirection, moonOrbit));
    if (lunarDirection.y <= 0.0f)
        return;

    const float phaseIllumination = saturate(
        0.5f - 0.5f * cos(saturate(moonParameters.x) * 6.28318530718f));
    if (phaseIllumination < 0.001f)
        return;

    // Moon rises in luminance only after the Sun's direct contribution
    // has faded completely. Deep-night Gate 1 Moon strength is unchanged.
    const float lunarTwilight = smoothstep(0.10f, 0.30f, -sunElevation);
    const float aboveHorizon = smoothstep(0.0f, 0.13f, lunarDirection.y);
    const float moonBrightness = min(max(moonParameters.z, 0.0f), 2.0f);
    const float strength = lunarTwilight * aboveHorizon *
        pow(phaseIllumination, 1.35f) * moonBrightness;
    if (strength < 0.0001f)
        return;

    // Independent of Sun intensity; directional volumetric scattering and
    // self-shadowing remain identical to Gate 1.
    lightDirection = lunarDirection;
    lightIlluminance = float3(0.50f, 0.60f, 0.74f) * strength;
}

// Gate 2: directional lunar glow for volumetric cloud rays. Angular
// proximity is derived from view and Moon directions, not from screen-space
// positions. This approximates the forward-scattered light apparent around
// the Moon without flattening distant clouds into evenly lit silhouettes.
// Returns (direct scattering scale, soft thin-cloud fill); no texture samples.
float2 RenegadeMoonCloudLocality(float3 viewDirection,
    float3 cloudLightDirection, float sunElevation, float4 moonParameters)
{
    if (sunElevation > -0.10f || moonParameters.z <= 0.0f)
        return float2(1.0f, 0.0f);
    const float angleDistance = 1.0f -
        saturate(dot(viewDirection, cloudLightDirection));
    const float core = exp2(-18.0f * angleDistance);
    const float spread = exp2(-5.0f * angleDistance);
    const float vicinity = 0.40f * core + 0.60f * spread;
    // Direct lunar irradiance must not depend on the viewing angle.
    // Only the forward-scattered fill is concentrated near the Moon;
    // deep opaque cloud interiors remain self-shadowed.
    return float2(1.0f, 0.040f + 0.38f * vicinity);
}

#endif
