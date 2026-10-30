#define DISABLE_SOFT_SHADOWMAP
#include "globals.hlsli"
#include "volumetricCloudsHF.hlsli"
#include "renegadeMoonCloudLighting.hlsli"
#include "skyAtmosphere.hlsli"
#include "lightingHF.hlsli"
#include "fogHF.hlsli"
#include "ShaderInterop_Postprocess.h"

/**
 * Cloud pass:
 * 
 * As descriped in GPU Pro 7, we combine our shape and detail noises to create a cloud shape.
 * The cloud shape is furthermore affected by the defined weather map.
 * We then perform raymarching towards the cloud shape and evaluate some lighting.
 * 
 * References:
 * 
 * GPU Pro 7: Real-Time Volumetric Cloudscapes - A. Schneider
 *     Follow up presentation: http://advances.realtimerendering.com/s2017/Nubis%20-%20Authoring%20Realtime%20Volumetric%20Cloudscapes%20with%20the%20Decima%20Engine%20-%20Final%20.pdf
 * R. Hogfeldt, "Convincing Cloud Rendering An Implementation of Real-Time Dynamic Volumetric Clouds in Frostbite"
 * F. Bauer, "Creating the Atmospheric World of Red Dead Redemption 2: A Complete and Integrated Solution" in Advances in Real-Time Rendering in Games, Siggraph 2019.
 * 
 * Multi scattering approximation: http://magnuswrenninge.com/wp-content/uploads/2010/03/Wrenninge-OzTheGreatAndVolumetric.pdf
 * Participating media and volumetric integration: https://media.contentapi.ea.com/content/dam/eacom/frostbite/files/s2016-pbs-frostbite-sky-clouds-new.pdf
 *     Small example: https://www.shadertoy.com/view/XlBSRz
 *
 */
 
PUSHCONSTANT(postprocess, PostProcess);

Texture3D<float4> texture_shapeNoise : register(t0);
Texture3D<float4> texture_detailNoise : register(t1);
Texture2D<float4> texture_curlNoise : register(t2);
Texture2D<float4> texture_weatherMapFirst : register(t3);
Texture2D<float4> texture_weatherMapSecond : register(t4);

RWTexture2D<float4> texture_render : register(u0);
RWTexture2D<float2> texture_cloudDepth : register(u1);

struct Variance
{
	float4 history[4];
	float variance_smooth;

	float update(float4 current)
	{
		float4 sum = current;
		for (uint i = 0; i < arraysize(history); ++i)
		{
			sum += history[i];
		}
		float4 mean = sum / float(arraysize(history) + 1);

		float4 variance = sqr(current - mean);
		for (uint i = 0; i < arraysize(history); ++i)
		{
			variance += sqr(history[i] - mean);
		}
		variance /= (float)arraysize(history);

		for (uint i = 0; i < arraysize(history) - 1; ++i)
		{
			history[i] = history[i + 1];
		}
		history[arraysize(history) - 1] = current;

		float maxv = max4(variance);
		variance_smooth = lerp(variance_smooth, maxv, maxv > variance_smooth ? 0.8 : 0.01);
		return variance_smooth;
	}
};
struct VariancePacked
{
	uint4 data0;
	uint4 data1;
	float variance_smooth;

	void store(Variance variance)
	{
		data0.xy = pack_half4(variance.history[0]);
		data0.zw = pack_half4(variance.history[1]);
		data1.xy = pack_half4(variance.history[2]);
		data1.zw = pack_half4(variance.history[3]);
		variance_smooth = variance.variance_smooth;
	};
	Variance load()
	{
		Variance ret;
		ret.history[0] = unpack_half4(data0.xy);
		ret.history[1] = unpack_half4(data0.zw);
		ret.history[2] = unpack_half4(data1.xy);
		ret.history[3] = unpack_half4(data1.zw);
		ret.variance_smooth = variance_smooth;
		return ret;
	}
};
RWStructuredBuffer<VariancePacked> variance_data : register(u2);

static const uint2 halfResIndexToCoordinateOffset[4] = { uint2(0, 0), uint2(1, 0), uint2(0, 1), uint2(1, 1) };

// Octaves for multiple-scattering approximation. 1 means single-scattering only.
#define MS_COUNT 2

// Because the lights color is limited to half-float precision, we can only set intensity to 65504 which in some cases isn't enough.
#define LOCAL_LIGHTS_INTENSITY_MULTIPLIER 100000.0

// Threshold that tells what cloud density we can accept
#define CLOUD_DENSITY_THRESHOLD 0.001

#define LOD_Max 3

#define MAX_STEP_COUNT GetWeather().volumetric_clouds.maxStepCount
#define LOD_Min GetWeather().volumetric_clouds.LODMin
#define SHADOW_SAMPLE_COUNT GetWeather().volumetric_clouds.shadowSampleCount
#define GROUND_CONTRIBUTION_SAMPLE_COUNT GetWeather().volumetric_clouds.groundContributionSampleCount

// Participating media is the term used to describe volumes filled with particles.
// Such particles can be large impurities, e.g. dust, pollution, water droplets, or simply particles, e.g. molecules
struct ParticipatingMedia
{
	float3 scatteringCoefficients[MS_COUNT];
	float3 extinctionCoefficients[MS_COUNT];
	float3 transmittanceToLight[MS_COUNT];
};

ParticipatingMedia SampleParticipatingMedia(float3 baseAlbedo, float3 baseExtinctionCoefficients, float baseMsScatteringFactor, float baseMsExtinctionFactor, float3 initialTransmittanceToLight)
{
	const float3 scatteringCoefficients = baseAlbedo * baseExtinctionCoefficients;

	ParticipatingMedia participatingMedia;
	participatingMedia.scatteringCoefficients[0] = scatteringCoefficients;
	participatingMedia.extinctionCoefficients[0] = baseExtinctionCoefficients;
	participatingMedia.transmittanceToLight[0] = initialTransmittanceToLight;

	float MsScatteringFactor = baseMsScatteringFactor;
	float MsExtinctionFactor = baseMsExtinctionFactor;

	[unroll]
	for (int ms = 1; ms < MS_COUNT; ++ms)
	{
		participatingMedia.scatteringCoefficients[ms] = participatingMedia.scatteringCoefficients[ms - 1] * MsScatteringFactor;
		participatingMedia.extinctionCoefficients[ms] = participatingMedia.extinctionCoefficients[ms - 1] * MsExtinctionFactor;
		MsScatteringFactor *= MsScatteringFactor;
		MsExtinctionFactor *= MsExtinctionFactor;

		participatingMedia.transmittanceToLight[ms] = initialTransmittanceToLight;
	}

	return participatingMedia;
}

void OpaqueShadow(inout ParticipatingMedia participatingMedia, float3 worldPosition)
{
	float shadow = 1.0f;

	// Unlike volumetric fog lighting, we only care about the outmost cascade. This improves performance where we can't see the inner cascades anyway
	ShaderEntity light = (ShaderEntity) 0;
	uint furthestCascade = 0;

	if (furthest_cascade_volumetrics(light, furthestCascade))
	{
		float3 shadow_pos = mul(load_entitymatrix(light.GetMatrixIndex() + furthestCascade), float4(worldPosition, 1)).xyz; // ortho matrix, no divide by .w
		float3 shadow_uv = clipspace_to_uv(shadow_pos.xyz);
				
		if (is_saturated(shadow_uv))
		{
			shadow *= shadow_2D(light, shadow_pos.z, shadow_uv.xy, furthestCascade).r;
		}
	}

	[unroll]
	for (int ms = 0; ms < MS_COUNT; ms++)
	{
		participatingMedia.transmittanceToLight[ms] *= shadow;
	}
}

void VolumetricShadow(inout ParticipatingMedia participatingMedia, in AtmosphereParameters atmosphere, float3 worldPosition, float3 sunDirection, LayerParameters layerParametersFirst, LayerParameters layerParametersSecond, float lod)
{
	int ms = 0;
	float3 extinctionAccumulation[MS_COUNT];

	[unroll]
	for (ms = 0; ms < MS_COUNT; ms++)
	{
		extinctionAccumulation[ms] = 0.0f;
	}
	
	const float sampleCount = SHADOW_SAMPLE_COUNT;
	const float sampleSegmentT = 0.5f;
	
	float lodOffset = 0.5;
	for (float s = 0.0f; s < sampleCount; s += 1.0)
	{
		// More expensive but artefact free
		float t0 = (s) / sampleCount;
		float t1 = (s + 1.0) / sampleCount;
		// Non linear distribution of sample within the range.
		t0 = t0 * t0;
		t1 = t1 * t1;

		float delta = t1 - t0; // 5 samples: 0.04, 0.12, 0.2, 0.28, 0.36
		float t = t0 + delta * sampleSegmentT; // 5 samples: 0.02, 0.1, 0.26, 0.5, 0.82
		
		float shadowSampleT = GetWeather().volumetric_clouds.shadowStepLength * t;
		float3 samplePoint = worldPosition + sunDirection * shadowSampleT; // Step futher towards the light

		float heightFraction = GetHeightFractionForPoint(atmosphere, samplePoint);
		if (heightFraction < 0.0 || heightFraction > 1.0)
		{
			break;
		}
		
		float3 weatherDataFirst = SampleWeather(texture_weatherMapFirst, samplePoint, heightFraction, layerParametersFirst);
		float3 weatherDataSecond = SampleWeather(texture_weatherMapSecond, samplePoint, heightFraction, layerParametersSecond);
		
		if (!ValidCloudDensityLayers(heightFraction, weatherDataFirst, weatherDataSecond, layerParametersFirst, layerParametersSecond))
		{
			continue;
		}

		float shadowCloudDensityFirst = SampleCloudDensity(texture_shapeNoise, texture_detailNoise, texture_curlNoise, samplePoint, heightFraction, layerParametersFirst, weatherDataFirst, lod + lodOffset, true);
		float shadowCloudDensitySecond = SampleCloudDensity(texture_shapeNoise, texture_detailNoise, texture_curlNoise, samplePoint, heightFraction, layerParametersSecond, weatherDataSecond, lod + lodOffset, true);
		float3 shadowExtinction = SampleExtinction(shadowCloudDensityFirst, shadowCloudDensitySecond);
		
		ParticipatingMedia shadowParticipatingMedia = SampleParticipatingMedia(0.0f, shadowExtinction, GetWeather().volumetric_clouds.multiScatteringScattering, GetWeather().volumetric_clouds.multiScatteringExtinction, 0.0f);
		
		[unroll]
		for (ms = 0; ms < MS_COUNT; ms++)
		{
			extinctionAccumulation[ms] += shadowParticipatingMedia.extinctionCoefficients[ms] * delta;
		}

		lodOffset += 0.5;
	}

	[unroll]
	for (ms = 0; ms < MS_COUNT; ms++)
	{
		participatingMedia.transmittanceToLight[ms] *= exp(-extinctionAccumulation[ms] * GetWeather().volumetric_clouds.shadowStepLength);
	}
}

void VolumetricGroundContribution(inout float3 environmentLuminance, in AtmosphereParameters atmosphere, float3 worldPosition, float3 sunDirection, float3 sunIlluminance, float3 atmosphereTransmittanceToLight, LayerParameters layerParametersFirst, LayerParameters layerParametersSecond, float lod)
{
	float planetRadius = atmosphere.bottomRadius * SKY_UNIT_TO_M;
	float3 planetCenterWorld = atmosphere.planetCenter * SKY_UNIT_TO_M;

	float cloudBottomRadius = planetRadius + GetWeather().volumetric_clouds.cloudStartHeight;

	float cloudSampleAltitudde = length(worldPosition - planetCenterWorld); // Distance from planet center to tracing sample
	float cloudSampleHeightToBottom = cloudSampleAltitudde - cloudBottomRadius; // Distance from altitude to bottom of clouds
	
	float3 opticalDepth = 0.0;
	
	const float contributionStepLength = min(4000.0, cloudSampleHeightToBottom);
	const float3 groundScatterDirection = float3(0.0, -1.0, 0.0);
	
	const float sampleCount = GROUND_CONTRIBUTION_SAMPLE_COUNT;
	const float sampleSegmentT = 0.5f;
	
	// Ground Contribution tracing loop, same idea as volumetric shadow
	float lodOffset = 0.5;
	for (float s = 0.0f; s < sampleCount; s += 1.0)
	{
		// More expensive but artefact free
		float t0 = (s) / sampleCount;
		float t1 = (s + 1.0) / sampleCount;
		// Non linear distribution of sample within the range.
		t0 = t0 * t0;
		t1 = t1 * t1;

		float delta = t1 - t0; // 5 samples: 0.04, 0.12, 0.2, 0.28, 0.36		
		float t = t0 + (t1 - t0) * sampleSegmentT; // 5 samples: 0.02, 0.1, 0.26, 0.5, 0.82

		float contributionSampleT = contributionStepLength * t;
		float3 samplePoint = worldPosition + groundScatterDirection * contributionSampleT; // Step futher towards the scatter direction

		float heightFraction = GetHeightFractionForPoint(atmosphere, samplePoint);
		/*if (heightFraction < 0.0 || heightFraction > 1.0) // No impact
		{
			break;
		}*/
		
		float3 weatherDataFirst = SampleWeather(texture_weatherMapFirst, samplePoint, heightFraction, layerParametersFirst);
		float3 weatherDataSecond = SampleWeather(texture_weatherMapSecond, samplePoint, heightFraction, layerParametersSecond);
		
		if (!ValidCloudDensityLayers(heightFraction, weatherDataFirst, weatherDataSecond, layerParametersFirst, layerParametersSecond))
		{
			continue;
		}

		float contributionCloudDensityFirst = SampleCloudDensity(texture_shapeNoise, texture_detailNoise, texture_curlNoise, samplePoint, heightFraction, layerParametersFirst, weatherDataFirst, lod + lodOffset, true);
		float contributionCloudDensitySecond = SampleCloudDensity(texture_shapeNoise, texture_detailNoise, texture_curlNoise, samplePoint, heightFraction, layerParametersSecond, weatherDataSecond, lod + lodOffset, true);
		float3 contributionExtinction = SampleExtinction(contributionCloudDensityFirst, contributionCloudDensitySecond);

		opticalDepth += contributionExtinction * contributionStepLength * delta;
		
		lodOffset += 0.5;
	}
	
	const float3 planetSurfaceNormal = float3(0.0, 1.0, 0.0); // Ambient contribution from the clouds is only done on a plane above the planet
	const float3 groundBrdfNdotL = saturate(dot(sunDirection, planetSurfaceNormal)) * (atmosphere.groundAlbedo / PI); // Lambert BRDF diffuse shading

	const float uniformPhase = UniformPhase();
	const float groundHemisphereLuminanceIsotropic = (2.0f * PI) * uniformPhase; // Assumes the ground is uniform luminance to the cloud and solid angle is bottom hemisphere 2PI
	const float3 groundToCloudTransfertIsoScatter = groundBrdfNdotL * groundHemisphereLuminanceIsotropic;
	
	const float3 scatteredLuminance = atmosphereTransmittanceToLight * sunIlluminance * groundToCloudTransfertIsoScatter;

	environmentLuminance += scatteredLuminance * exp(-opticalDepth);
}

struct ParticipatingMediaPhase
{
	float phase[MS_COUNT];
};

ParticipatingMediaPhase SampleParticipatingMediaPhase(float basePhase, float baseMsPhaseFactor)
{
	ParticipatingMediaPhase participatingMediaPhase;
	participatingMediaPhase.phase[0] = basePhase;

	const float uniformPhase = UniformPhase();

	float MsPhaseFactor = baseMsPhaseFactor;
	
	[unroll]
	for (int ms = 1; ms < MS_COUNT; ms++)
	{
		participatingMediaPhase.phase[ms] = lerp(uniformPhase, participatingMediaPhase.phase[0], MsPhaseFactor);
		MsPhaseFactor *= MsPhaseFactor;
	}

	return participatingMediaPhase;
}

// Exponential integral function (see https://mathworld.wolfram.com/ExponentialIntegral.html)
/*float ExponentialIntegral(float x)
{
	// For x != 0
	return 0.5772156649015328606065 + log(1e-4 + abs(x)) + x * (1.0 + x * (0.25 + x * ((1.0 / 18.0) + x * ((1.0 / 96.0) + x * (1.0 / 600.0)))));
}*/

float3 SampleAmbientLight(float heightFraction)
{
	// Early experiment by adding directionality to ambient, based on: http://patapom.com/topics/Revision2013/Revision%202013%20-%20Real-time%20Volumetric%20Rendering%20Course%20Notes.pdf
	//float ambientTerm = -cloudDensity * (1.0 - saturate(GetWeather().volumetric_clouds.CloudAmbientGroundMultiplier + heightFraction));
	//float isotropicScatteringTopContribution = max(0.0, exp(ambientTerm) - ambientTerm * ExponentialIntegral(ambientTerm));

	float isotropicScatteringTopContribution = saturate(GetWeather().volumetric_clouds.ambientGroundMultiplier + heightFraction);
	
	if (GetFrame().options & OPTION_BIT_REALISTIC_SKY)
	{
		float3 skyLuminance = texture_skyluminancelut.SampleLevel(sampler_point_clamp, float2(0.5, 0.5), 0).rgb;
		return isotropicScatteringTopContribution * skyLuminance;
	}
	else
	{
		float3 skyColor = GetZenithColor();
		return isotropicScatteringTopContribution * skyColor;
	}
}

float3 SampleLocalLights(float3 worldPosition)
{
	float3 localLightLuminance = 0;
	
	[loop]
	for (uint iterator = 0; iterator < lights().item_count(); iterator++)
	{
		ShaderEntity light = load_entity(lights().first_item() + iterator);

		if (light.GetFlags() & ENTITY_FLAG_LIGHT_VOLUMETRICCLOUDS)
		{
			float3 L = 0;
			float dist = 0;
			float3 lightColor = 0;

			// Only point and spot lights are available for now
			switch (light.GetType())
			{
				case ENTITY_TYPE_POINTLIGHT:
			{
						L = light.position - worldPosition;
						const float dist2 = dot(L, L);
						const float range = light.GetRange();
						const float range2 = range * range;

				[branch]
						if (dist2 < range2)
						{
							dist = sqrt(dist2);

							lightColor = light.GetColor().rgb;
							lightColor = min(lightColor, HALF_FLT_MAX) * LOCAL_LIGHTS_INTENSITY_MULTIPLIER;
							lightColor *= attenuation_pointlight(dist2, range, light.GetRange2Rcp());
						}
					}
					break;
				case ENTITY_TYPE_SPOTLIGHT:
			{
						L = light.position - worldPosition;
						const float dist2 = dot(L, L);
						const float range = light.GetRange();
						const float range2 = range * range;

				[branch]
						if (dist2 < range2)
						{
							dist = sqrt(dist2);
							L /= dist;

							const float spotFactor = dot(L, light.GetDirection());
							const float spotCutoff = light.GetConeAngleCos();

					[branch]
							if (spotFactor > spotCutoff)
							{
								lightColor = light.GetColor().rgb;
								lightColor = min(lightColor, HALF_FLT_MAX) * LOCAL_LIGHTS_INTENSITY_MULTIPLIER;
								lightColor *= attenuation_spotlight(dist2, range, light.GetRange2Rcp(), spotFactor, light.GetAngleScale(), light.GetAngleOffset());
							}
						}
					}
					break;
			}

			localLightLuminance += lightColor * UniformPhase();
		}
	}

	return localLightLuminance;
}

// G4 sheet lightning: an in-cloud emission field evaluated at existing
// raymarch samples. Distances are float32 in metres; generic point-light
// attenuation uses half precision and loses useful range at cloud altitudes.
// This adds NO raymarch/shadow samples and draws NO visible lightning bolts.
float3 RenegadeSheetLightningRadiance(float3 worldPosition)
{
    float3 energy = GetWeather().sheet_light_power.xyz;
    [branch]
    if (max(max(energy.x, energy.y), energy.z) <= 0.00001f)
        return 0.0f;

    float4 cell0 = GetWeather().sheet_light_cell0;
    float4 cell1 = GetWeather().sheet_light_cell1;
    float4 cell2 = GetWeather().sheet_light_cell2;
    float3 d0 = worldPosition - cell0.xyz;
    float3 d1 = worldPosition - cell1.xyz;
    float3 d2 = worldPosition - cell2.xyz;
    // Broad, oblique, shallow discharges instead of spherical bright discs.
    // Differently oriented lobes overlap inside the cloud body; scattering
    // and existing optical depth mask their edges naturally.
    float a = saturate(1.0f - (0.72f*d0.x*d0.x +
         2.10f*d0.y*d0.y + 1.18f*d0.z*d0.z + 0.25f*d0.x*d0.z) /
         max(cell0.w * cell0.w, 1.0f));
    float b = saturate(1.0f - (1.14f*d1.x*d1.x +
         2.30f*d1.y*d1.y + 0.74f*d1.z*d1.z - 0.22f*d1.x*d1.z) /
         max(cell1.w * cell1.w, 1.0f));
    float c = saturate(1.0f - (0.89f*d2.x*d2.x +
         2.00f*d2.y*d2.y + 1.02f*d2.z*d2.z + 0.17f*d2.x*d2.z) /
         max(cell2.w * cell2.w, 1.0f));
    // Keep the centre energy bounded, but feather the last part of each
    // expanded radius instead of leaving an identifiable illuminated edge.
    // Unequal falloff widths combined with event-randomised cell radii give
    // each cloud flash a slightly different shape without extra samples.
    float falloffA = a * a * smoothstep(0.0f, 0.42f, a);
    float falloffB = b * b * smoothstep(0.0f, 0.49f, b);
    float falloffC = c * c * smoothstep(0.0f, 0.36f, c);
    float illumination = (energy.x * falloffA + energy.y * falloffB +
                          energy.z * falloffC);
    return float3(0.75f, 0.84f, 1.0f) * illumination * 12.0f;
}

void VolumetricCloudLighting(AtmosphereParameters atmosphere, float3 startPosition, float3 worldPosition, float3 sunDirection, float3 sunIlluminance, float cosTheta, float stepSize, float heightFraction, float3 moonSoftFill,
	float cloudDensityFirst, float cloudDensitySecond, float3 weatherDataFirst, float3 weatherDataSecond,
	LayerParameters layerParametersFirst, LayerParameters layerParametersSecond, float lod,
	inout float3 luminance, inout float3 transmittanceToView, inout float depthWeightedSum, inout float depthWeightsSum)
{
	// Setup base parameters
	float3 albedo = SampleAlbedo(cloudDensityFirst, cloudDensitySecond, weatherDataFirst, weatherDataSecond);
	float3 extinction = SampleExtinction(cloudDensityFirst, cloudDensitySecond);
	
	float3 atmosphereTransmittanceToLight = 1.0;
	if (GetFrame().options & OPTION_BIT_REALISTIC_SKY)
	{
		atmosphereTransmittanceToLight = GetAtmosphericLightTransmittance(atmosphere, worldPosition, sunDirection, texture_transmittancelut); // Has to be in meters
	}
	
	// Sample participating media with multiple scattering
	ParticipatingMedia participatingMedia = SampleParticipatingMedia(albedo, extinction, GetWeather().volumetric_clouds.multiScatteringScattering, GetWeather().volumetric_clouds.multiScatteringExtinction, atmosphereTransmittanceToLight);
	

	// Sample environment lighting
	float3 environmentLuminance = SampleAmbientLight(heightFraction);


	// Only render if there is any sign of scattering (albedo * extinction)
	if (any(participatingMedia.scatteringCoefficients[0] > 0.0))
	{
		// Sample shadows from opaque shadow maps
		if (GetFrame().options & OPTION_BIT_VOLUMETRICCLOUDS_RECEIVE_SHADOW)
		{
			OpaqueShadow(participatingMedia, worldPosition);
		}
		
		// Calcualte volumetric shadow
		VolumetricShadow(participatingMedia, atmosphere, worldPosition, sunDirection, layerParametersFirst, layerParametersSecond, lod);


		// Calculate bounced light from ground onto clouds
		const float maxTransmittanceToView = max(max(transmittanceToView.x, transmittanceToView.y), transmittanceToView.z);
		if (maxTransmittanceToView > 0.01f)
		{
			VolumetricGroundContribution(environmentLuminance, atmosphere, worldPosition, sunDirection, sunIlluminance, atmosphereTransmittanceToLight, layerParametersFirst, layerParametersSecond, lod);
		}
	}


	// Lunar forward-scattering fills the *inside* of thin, backlit clouds,
	// rather than highlighting the outer contour uniformly. The existing
	// self-shadow transmittance and optical thickness control its visibility.
	// No additional density, shadow, or raymarch samples are introduced.
	const float lightVisible = saturate(dot(
		participatingMedia.transmittanceToLight[0], 1.0f / 3.0f));
	const float opticalDepth = dot(extinction, 1.0f / 3.0f) * stepSize;
	environmentLuminance += moonSoftFill * (0.16f + 0.84f * lightVisible) /
		(1.0f + 0.7f * opticalDepth);

	// Sample dual lob phase with multiple scattering
	float phaseFunction = DualLobPhase(GetWeather().volumetric_clouds.phaseG, GetWeather().volumetric_clouds.phaseG2, GetWeather().volumetric_clouds.phaseBlend, -cosTheta);
	ParticipatingMediaPhase participatingMediaPhase = SampleParticipatingMediaPhase(phaseFunction, GetWeather().volumetric_clouds.multiScatteringEccentricity);


	// Update depth sampling
	float depthWeight = min(transmittanceToView.r, min(transmittanceToView.g, transmittanceToView.b));
	depthWeightedSum += depthWeight * length(worldPosition - startPosition);
	depthWeightsSum += depthWeight;

	
	// Sample local lights. Sheet lightning is a separate cloud-scale
	// emission field, scattered by the existing cloud density and attenuated
	// along the ray; it never uses ordinary world-light attenuation.
	float3 localLightLuminance = SampleLocalLights(worldPosition);
	float3 sheetLightning = RenegadeSheetLightningRadiance(worldPosition);

	
	// Analytical scattering integration based on multiple scattering
	
	[unroll]
	for (int ms = MS_COUNT - 1; ms >= 0; ms--) // Should terminate at 0
	{
		const float3 scatteringCoefficients = participatingMedia.scatteringCoefficients[ms];
		const float3 extinctionCoefficients = participatingMedia.extinctionCoefficients[ms];
		const float3 transmittanceToLight = participatingMedia.transmittanceToLight[ms];
		
		float3 lightLuminance = transmittanceToLight * sunIlluminance * participatingMediaPhase.phase[ms];
		lightLuminance += (ms == 0 ? environmentLuminance : float3(0.0, 0.0, 0.0)); // only apply at last
		lightLuminance += localLightLuminance;
		lightLuminance += (ms == 0 ? sheetLightning : float3(0, 0, 0));

		const float3 scatteredLuminance = (lightLuminance * scatteringCoefficients); // + emission. Light can be emitted when media reach high heat. Could be used to make lightning
		
		// See slide 28 at http://www.frostbite.com/2015/08/physically-based-unified-volumetric-rendering-in-frostbite/ 
		const float3 clampedExtinctionCoefficients = max(extinctionCoefficients, 0.0000001);
		const float3 sampleTransmittance = exp(-clampedExtinctionCoefficients * stepSize);
		float3 luminanceIntegral = (scatteredLuminance - scatteredLuminance * sampleTransmittance) / clampedExtinctionCoefficients; // integrate along the current step segment
		luminance += transmittanceToView * luminanceIntegral; // accumulate and also take into account the transmittance from previous steps

		if (ms == 0)
		{
			transmittanceToView *= sampleTransmittance;
		}
	}
}

float CalculateAtmosphereBlend(float tDepth)
{
	// Progressively increase alpha as clouds reaches the desired distance.
	float fogDistance = saturate(RenegadeCloudHorizonDistance(tDepth) * GetWeather().volumetric_clouds.horizonBlendAmount);
	
	float fade = pow(fogDistance, GetWeather().volumetric_clouds.horizonBlendPower);
	fade = smoothstep(0.0, 1.0, fade);
		
	const float maxHorizonFade = 0.0;
	fade = clamp(fade, maxHorizonFade, 1.0);
		
	return fade;
}
 
void RenderClouds(uint3 DTid, float2 uv, float depth, float3 depthWorldPosition, float3 rayOrigin, float3 rayDirection, inout float4 cloudColor, inout float2 cloudDepth)
{
	AtmosphereParameters atmosphere = GetWeather().atmosphere;
	
	float tMin = -FLT_MAX;
	float tMax = -FLT_MAX;
	float t;
	float tToDepthBuffer;
	float steps;
	float stepSize;
	{
		float planetRadius = atmosphere.bottomRadius * SKY_UNIT_TO_M;
		float3 planetCenterWorld = atmosphere.planetCenter * SKY_UNIT_TO_M;

		const float cloudBottomRadius = RenegadeCloudMarchBottomRadius(planetRadius + GetWeather().volumetric_clouds.cloudStartHeight);
		const float cloudTopRadius = RenegadeCloudMarchTopRadius(planetRadius + GetWeather().volumetric_clouds.cloudStartHeight + GetWeather().volumetric_clouds.cloudThickness);
		
		float2 tTopSolutions = RaySphereIntersect(rayOrigin, rayDirection, planetCenterWorld, cloudTopRadius);
		if (tTopSolutions.x > 0.0 || tTopSolutions.y > 0.0)
		{
			float2 tBottomSolutions = RaySphereIntersect(rayOrigin, rayDirection, planetCenterWorld, cloudBottomRadius);
			if (tBottomSolutions.x > 0.0 || tBottomSolutions.y > 0.0)
			{
				// If we see both intersections on the screen, keep the min closest, otherwise the max furthest
				float tempTop = all(tTopSolutions > 0.0f) ? min(tTopSolutions.x, tTopSolutions.y) : max(tTopSolutions.x, tTopSolutions.y);
				float tempBottom = all(tBottomSolutions > 0.0f) ? min(tBottomSolutions.x, tBottomSolutions.y) : max(tBottomSolutions.x, tBottomSolutions.y);
				
				// But if we can see the bottom of the layer, make sure we use the camera view or the highest top layer intersection
				if (all(tBottomSolutions > 0.0f))
				{
					tempTop = max(0.0f, min(tTopSolutions.x, tTopSolutions.y));
				}

				tMin = min(tempBottom, tempTop);
				tMax = max(tempBottom, tempTop);
			}
			else
			{
				tMin = tTopSolutions.x;
				tMax = tTopSolutions.y;
			}
			
			tMin = max(0.0, tMin);
			tMax = max(0.0, tMax);
		}
		else
		{
			cloudColor = float4(0.0, 0.0, 0.0, 0.0);
			cloudDepth = FLT_MAX;
			return;
		}

		if (tMax <= tMin || tMin > RenegadeCloudMarchRenderDistance(planetRadius, cloudTopRadius, GetWeather().volumetric_clouds.renderDistance))
		{
			cloudColor = float4(0.0, 0.0, 0.0, 0.0);
			cloudDepth = FLT_MAX;
			return;
		}
		
		// Depth buffer intersection
		tToDepthBuffer = length(depthWorldPosition - rayOrigin);

		// Exclude skybox to allow infinite distance
		tMax = depth == 0.0 ? tMax : min(tMax, tToDepthBuffer);

		// Set infinite distance value to float precision for reprojection, which is rendertarget precision
		tToDepthBuffer = depth == 0.0 ? FLT_MAX : tToDepthBuffer;
		
		const float marchingDistance = min(GetWeather().volumetric_clouds.maxMarchingDistance, tMax - tMin);
		tMax = tMin + marchingDistance;

		steps = MAX_STEP_COUNT * saturate((tMax - tMin) * (1.0 / GetWeather().volumetric_clouds.inverseDistanceStepCount));
		// Renegade sampling: bound distance between samples of the 3D density field.
        // Native scaling yields ~156m per sample even in a shallow layer.
        if (GetWeather().volumetric_clouds.layerFirst.padding0 >= 1 &&
            GetWeather().volumetric_clouds.layerFirst.padding0 <= 5)
            // Adaptive world-space sampling: preserve 48-m near-field density edges.
            // Distant rays permit wider steps, where perspective and temporal
            // integration resolve fine-scale structure without uniform 384 steps.
            steps = clamp(ceil((tMax - tMin) / (64.0 + 80.0 * saturate((tMin - 3000.0) / 10000.0))), 1.0, 384.0);
        stepSize = (tMax - tMin) / steps;
		
		//float offset = dither(DTid.xy + GetTemporalAASampleRotation());
		//float offset = InterleavedGradientNoise(DTid.xy, GetFrame().frame_count % 16);
		float offset = blue_noise(DTid.xy).x;
				
		//t = tMin + 0.5 * stepSize;
		t = tMin + offset * stepSize;
	}
	
	// Sample layers
	LayerParameters layerParametersFirst = SampleLayerParameters(GetWeather().volumetric_clouds.layerFirst);
	LayerParameters layerParametersSecond = SampleLayerParameters(GetWeather().volumetric_clouds.layerSecond);
	
	float3 sunIlluminance = GetSunColor();
	float3 sunDirection = GetSunDirection();
    float3 cloudLightDirection = sunDirection;
    float3 cloudLightIlluminance = sunIlluminance;
    RenegadeApplyMoonlightToClouds(cloudLightDirection, cloudLightIlluminance, GetWeather().moon_parameters, GetWeather().moon_orbit);
    const float2 moonLocality = RenegadeMoonCloudLocality(
        rayDirection, cloudLightDirection, sunDirection.y,
        GetWeather().moon_parameters);
    const float3 moonSoftFill = cloudLightIlluminance * moonLocality.y;
    cloudLightIlluminance *= moonLocality.x;
	
	float cosTheta = dot(rayDirection, cloudLightDirection);

	
	float3 luminance = 0.0;
	float3 transmittanceToView = 1.0;
	float depthWeightedSum = 0.0;
	float depthWeightsSum = 0.0;
	
	[loop]
	for (float i = 0.0; i < steps; i++)
	{
		float3 sampleWorldPosition = rayOrigin + rayDirection * t;

		float heightFraction = GetHeightFractionForPoint(atmosphere, sampleWorldPosition);
		if (heightFraction < 0.0 || heightFraction > 1.0)
		{
			break;
		}
		
		float3 weatherDataFirst = SampleWeather(texture_weatherMapFirst, sampleWorldPosition, heightFraction, layerParametersFirst);
		float3 weatherDataSecond = SampleWeather(texture_weatherMapSecond, sampleWorldPosition, heightFraction, layerParametersSecond);
		
		// We can guarantee that no clouds are here. This acts as a bounding box where we outside can take large steps
		if (!ValidCloudDensityLayers(heightFraction, weatherDataFirst, weatherDataSecond, layerParametersFirst, layerParametersSecond))
		{
			// We increment i every iteration, but for every additional step, we want to add that to the increment
			float emptyStep = layerParametersFirst.layer.padding0 >= 1 &&
                layerParametersFirst.layer.padding0 <= 5 ? 1.0 : GetWeather().volumetric_clouds.bigStepMarch;
            // Renegade conservative whole-body bounds: the spherical-height
            // coordinate map has a norm below 2. Never skip a secondary layer.
            if (layerParametersFirst.layer.padding0 == 1 &&
                layerParametersSecond.layer.coverageAmount <= 0 &&
                layerParametersSecond.layer.coverageMinimum <= 0)
                emptyStep = max(1.0, floor((-weatherDataFirst.r) / (2.0 * stepSize)));
            // Continuous weather potential: bounded single-step empty traversal.
            i += emptyStep - 1;
            t += emptyStep * stepSize;
			
			continue;
		}
		
		float tProgress = distance(rayOrigin, sampleWorldPosition);
		float lod = round(tProgress / max(GetWeather().volumetric_clouds.LODDistance, 0.00001));
		lod = clamp(lod, LOD_Min, LOD_Max);
		
		float cloudDensityFirst = SampleCloudDensity(texture_shapeNoise, texture_detailNoise, texture_curlNoise, sampleWorldPosition, heightFraction, layerParametersFirst, weatherDataFirst, lod, true);
		float cloudDensitySecond = SampleCloudDensity(texture_shapeNoise, texture_detailNoise, texture_curlNoise, sampleWorldPosition, heightFraction, layerParametersSecond, weatherDataSecond, lod, true);

		if (saturate(cloudDensityFirst + cloudDensitySecond) > CLOUD_DENSITY_THRESHOLD)
		{
			VolumetricCloudLighting(atmosphere, rayOrigin, sampleWorldPosition, cloudLightDirection, cloudLightIlluminance, cosTheta, stepSize, heightFraction, moonSoftFill,
				cloudDensityFirst, cloudDensitySecond, weatherDataFirst, weatherDataSecond,
				layerParametersFirst, layerParametersSecond, lod,
				luminance, transmittanceToView, depthWeightedSum, depthWeightsSum);
			
			if (all(transmittanceToView < GetWeather().volumetric_clouds.transmittanceThreshold))
			{
				break;
			}
		}

		t += stepSize;
	}
		
	
	float tDepth = depthWeightsSum == 0.0 ? tMax : depthWeightedSum / max(depthWeightsSum, 0.0000000001);
	float3 sampleWorldPosition = rayOrigin + rayDirection * tDepth;

	float approxTransmittance = dot(transmittanceToView.rgb, 1.0 / 3.0);
	float grayScaleTransmittance = approxTransmittance < GetWeather().volumetric_clouds.transmittanceThreshold ? 0.0 : approxTransmittance;
	
	// Apply aerial perspective if any clouds is detected (depthWeightsSum)
	if (depthWeightsSum > 0.0 && GetFrame().options & OPTION_BIT_REALISTIC_SKY_AERIAL_PERSPECTIVE)
	{
		float4 aerialPerspective = 0;
		
		if (GetFrame().options & OPTION_BIT_REALISTIC_SKY_HIGH_QUALITY)
		{
			float3 worldPosition = GetCameraPlanetPos(atmosphere, rayOrigin);
			float3 worldDirection = rayDirection;
		
			// Move to top atmosphere as the starting point for ray marching.
			// This is critical to be after the above to not disrupt above atmosphere tests and voxel selection.
			if (MoveToTopAtmosphere(worldPosition, worldDirection, atmosphere.topRadius))
			{
				const float sampleCountIni = 0.0;
				const bool variableSampleCount = true;
				const bool perPixelNoise = true;
				const bool opaque = true;
				const bool ground = false;
				const bool mieRayPhase = true;
				const bool multiScatteringApprox = true;
				const bool volumetricCloudShadow = GetFrame().options & OPTION_BIT_VOLUMETRICCLOUDS_CAST_SHADOW && GetFrame().options & OPTION_BIT_REALISTIC_SKY_RECEIVE_SHADOW;
				const bool opaqueShadow = GetFrame().options & OPTION_BIT_VOLUMETRICCLOUDS_RECEIVE_SHADOW && GetFrame().options & OPTION_BIT_REALISTIC_SKY_RECEIVE_SHADOW;
				const float opticalDepthScale = atmosphere.aerialPerspectiveScale;
				SingleScatteringResult ss = IntegrateScatteredLuminance(
				atmosphere, DTid.xy, worldPosition, worldDirection, sunDirection, sunIlluminance, tDepth * M_TO_SKY_UNIT, sampleCountIni, variableSampleCount,
				perPixelNoise, opaque, ground, mieRayPhase, multiScatteringApprox, volumetricCloudShadow, opaqueShadow, texture_transmittancelut, texture_multiscatteringlut, opticalDepthScale);
				
				float transmittance = 1.0 - dot(ss.transmittance, float3(1.0f / 3.0f, 1.0f / 3.0f, 1.0f / 3.0f));
				aerialPerspective = float4(ss.L, transmittance);
			}
		}
		else
		{
			aerialPerspective = GetAerialPerspectiveTransmittance(uv, sampleWorldPosition, rayOrigin, texture_cameravolumelut);
		}

		// Layer aerial perspective on top of luminance
		luminance = (1.0 - aerialPerspective.a) * luminance + aerialPerspective.rgb * (1.0 - approxTransmittance); // Need to apply 1.0 - approxTransmittance due to inverse alpha
		//luminance = aerialPerspective.rgb * (1.0 - approxTransmittance); // Debug
	}
	
	// Apply height fog if any clouds is detected (depthWeightsSum)
	if (depthWeightsSum > 0.0 && GetFrame().options & OPTION_BIT_HEIGHT_FOG)
	{
		// Layer fog on top of luminance
		float4 fog = GetFog(tDepth, rayOrigin, rayDirection);
		//luminance = (1.0 - fog.a) * luminance + fog.rgb * (1.0 - approxTransmittance); // premultilpied fog
		luminance = lerp(luminance, fog.rgb * (1.0 - approxTransmittance), fog.a); // non-premultiplied fog
	}

	float4 color = float4(luminance, 1.0 - grayScaleTransmittance);

	// Blend clouds with horizon
	if (depthWeightsSum > 0.0)
	{
		float atmosphereBlend = CalculateAtmosphereBlend(tDepth);
		color *= 1.0 - atmosphereBlend;
	}

	// Output
	cloudColor = color;
	cloudDepth = float2(tDepth, tToDepthBuffer); // Linear depth
}

#ifdef VOLUMETRICCLOUD_CAPTURE
[numthreads(POSTPROCESS_BLOCKSIZE, POSTPROCESS_BLOCKSIZE, 1)]
void main(uint3 DTid : SV_DispatchThreadID)
{
	const uint variance_idx = flatten2D(DTid.xy, (uint2)postprocess.resolution);
	Variance variance = variance_data[variance_idx].load();

	const uint unroll_count = volumetricclouds_frame == 0 ? 4 : 1;

	for (uint i = 0; i < unroll_count; ++i)
	{
		int subPixelIndex = uint(volumetricclouds_frame + i) % 4;
		int checkerBoardIndex = ComputeCheckerBoardIndex(DTid.xy, subPixelIndex);
		int2 halfResCoord = DTid.xy * 2 + halfResIndexToCoordinateOffset[checkerBoardIndex];
	
		const float2 uv = (halfResCoord + 0.5) * postprocess.params0.zw;
		const float3 N = decode_hemioct(uv * 2 - 1).xzy;
		const float depth = 0;

		float3 rayOrigin = GetCamera().position;
		float3 rayDirection = normalize(N);

		float4 cloudColor = 0;
		float2 cloudDepth = 0;
		RenderClouds(DTid, uv, depth, 0, rayOrigin, rayDirection, cloudColor, cloudDepth);

		float variance_amount = variance.update(cloudColor);
		variance_amount = saturate(variance_amount);
		variance_amount = 1 - pow4(1 - variance_amount);
		float blend = lerp(0.1, 0.05, variance_amount);
		blend = volumetricclouds_frame == 0 ? 1 : blend;
		
		cloudColor = lerp(texture_render[halfResCoord], cloudColor, blend);
		
		texture_render[halfResCoord] = cloudColor;
		//texture_render[halfResCoord] = variance_amount;
	}

	variance_data[variance_idx].store(variance);
}
#else
[numthreads(POSTPROCESS_BLOCKSIZE, POSTPROCESS_BLOCKSIZE, 1)]
void main(uint3 DTid : SV_DispatchThreadID)
{
	int subPixelIndex = uint(volumetricclouds_frame) % 4;
	int checkerBoardIndex = ComputeCheckerBoardIndex(DTid.xy, subPixelIndex);
	uint2 halfResCoord = DTid.xy * 2 + halfResIndexToCoordinateOffset[checkerBoardIndex];

	const float2 uv = (halfResCoord + 0.5) * postprocess.params0.zw;
	const float depth = texture_depth.SampleLevel(sampler_point_clamp, uv, 1).r;
	
	float2 screenPosition = uv_to_clipspace(uv);
	
	float4 unprojected = mul(GetCamera().inverse_view_projection, float4(screenPosition, 0, 1));
	unprojected.xyz /= unprojected.w;

	float3 depthWorldPosition = reconstruct_position(uv, depth);

	float3 rayOrigin = GetCamera().position;
	float3 rayDirection = normalize(unprojected.xyz - rayOrigin);
	
	float4 cloudColor = 0;
	float2 cloudDepth = 0;
	RenderClouds(DTid, uv, depth, depthWorldPosition, rayOrigin, rayDirection, cloudColor, cloudDepth);
	
	texture_render[DTid.xy] = cloudColor;
	texture_cloudDepth[DTid.xy] = cloudDepth;
}
#endif // VOLUMETRICCLOUD_CAPTURE
