#include "structures.fxh"
#include "scene.fxh"
#include "hash.fxh"

Texture2D g_Albedo;
Texture2D g_Normal;
Texture2D g_Emissive;
Texture2D g_Depth;

RWTexture2D<float4 /*format = rgba32f*/> g_Radiance;

cbuffer cbConstants
{
    ShaderConstants g_Constants;
}

#ifndef THREAD_GROUP_SIZE
#   define THREAD_GROUP_SIZE 8
#endif

// https://github.com/TheRealMJP/DXRPathTracer (MIT)
// Returns a random cosine-weighted direction on the hemisphere around z = 1
float3 SampleDirectionCosineHemisphere(float2 UV)
{
    // [0, 1] -> [-1, +1]
    UV = UV * 2.0 - 1.0;

    // Square -> disk
    if (any(NotEqual(UV, float2(0.0, 0.0))))
    {
        // Normalize by the maximum diagonal length
        float2 scale = abs(UV);
        scale /= max(scale.x, scale.y);
        UV /= length(scale);
    }

    // Project samples on the disk to the hemisphere to get a
    // cosine-weighted distribution
    float3 Dir;
    Dir.xy = UV;
    Dir.z  = sqrt(max(1.0 - dot(Dir.xy, Dir.xy), 0.0));

    return Dir;
}

// Returns a random cosine-weighted direction on the hemisphere around N
float3 SampleDirectionCosineHemisphere(float3 N, float2 UV)
{
	float3 T = normalize(cross(N, abs(N.y) > 0.5 ? float3(1, 0, 0) : float3(0, 1, 0)));
	float3 B = cross(T, N);
    float3 Dir = SampleDirectionCosineHemisphere(UV);
    return normalize(Dir.x * T + Dir.y * B + Dir.z * N);
}



[numthreads(THREAD_GROUP_SIZE, THREAD_GROUP_SIZE, 1)]
void main(uint3 ThreadId : SV_DispatchThreadID)
{
    if (ThreadId.x >= g_Constants.uScreenWidth || ThreadId.y >= g_Constants.uScreenHeight)
        return; // Outside of the screen

    float fDepth = g_Depth.Load(int3(ThreadId.xy, 0)).x;
    if (fDepth == 1.0)
    {
        // Background
        g_Radiance[ThreadId.xy] = float4(0.0, 0.0, 0.0, 0.0);
        return;
    }

    float2 f2ScreenSize = float2(g_Constants.fScreenWidth, g_Constants.fScreenHeight);
    float3 f3SamplePos0 = ScreenToWorld(float2(ThreadId.xy) + float2(0.5, 0.5), fDepth, f2ScreenSize, g_Constants.ViewProjInvMat);
    // Read the starting sample attributes from the G-buffer
    float3 f3Albedo0 = g_Albedo.Load(int3(ThreadId.xy, 0)).xyz;
    float3 f3Normal0 = normalize(g_Normal.Load(int3(ThreadId.xy, 0)).xyz * 2.0 - 1.0);

    float3 f3Emissive = g_Emissive.Load(int3(ThreadId.xy, 0)).xyz;
    float3 f3Radiance = float3(0.0, 0.0, 0.0);

    float fLightArea = g_Constants.f2LightSizeXZ.x * g_Constants.f2LightSizeXZ.y * 2.0;

    uint2 Seed = ThreadId.xy + uint2(g_Constants.uFrameSeed1, g_Constants.uFrameSeed2);
    for (int i = 0; i < g_Constants.iNumSamplesPerFrame; ++i)
    {
        // The first sample is always the G-buffer
        float3 f3SamplePos = f3SamplePos0;
        float3 f3Albedo    = f3Albedo0;
        float3 f3Normal    = f3Normal0;

        // Total contribution of this path
        float3 f3PathContrib = float3(0.0, 0.0, 0.0);
        // Bounce attenutation
        float3 f3Attenuation = float3(1.0, 1.0, 1.0);
        for (int j = 0; j < g_Constants.iNumBounces; ++j)
        {
            if (g_Constants.iShowOnlyLastBounce != 0)
                f3PathContrib = float3(0.0, 0.0, 0.0);

            if (all(Equal(f3Normal, float3(0, 0, 0))))
                break;

            // Get the random sample on the light source.
            // Note that a more accurate way to sample the light source is to use the projected
            // solid angle. For this example however just taking a random sample in the rectanlge
            // is OK.
            float2 rnd2 = hash22(Seed);
            float3 f3LightSample = SampleLight(g_Constants.f2LightPosXZ, g_Constants.f2LightSizeXZ, rnd2);
            float3 f3DirToLight  = f3LightSample - f3SamplePos;
            float fDistToLightSqr = dot(f3DirToLight, f3DirToLight);
            f3DirToLight /= sqrt(fDistToLightSqr);

            // The ray towards the light sample
            RayInfo ShadowRay;
            ShadowRay.Origin = f3SamplePos;
            ShadowRay.Dir    = f3DirToLight;

            f3Attenuation *= f3Albedo;
            f3PathContrib +=
                f3Attenuation
                * TestShadow(ShadowRay)
                * max(dot(f3DirToLight, f3Normal), 0.0)
                * g_Constants.f4LightIntensity.rgb * g_Constants.f4LightIntensity.a
                * max(f3DirToLight.y, 0.0)
                * fLightArea
                / (PI * fDistToLightSqr);

            // Update the seed
            Seed += uint2(17, 123);

            if (j == g_Constants.iNumBounces-1)
            {
                // Last bounce - complete the loop
                break; 
            }

            // Sample the BRDF - in our case this is a cosine-weighted hemispherical distribution.
            RayInfo Ray;
            Ray.Origin = f3SamplePos;
            Ray.Dir    = SampleDirectionCosineHemisphere(f3Normal, rnd2);

            // Trace the scene in the selected direction
            HitInfo Hit = IntersectScene(Ray, g_Constants.f2LightPosXZ, g_Constants.f2LightSizeXZ);
            if (Hit.Type != HIT_TYPE_LAMBERTIAN)
            {
                // Stop the loop if we hit the light or missed the scene
                if (g_Constants.iShowOnlyLastBounce != 0)
                    f3PathContrib = float3(0.0, 0.0, 0.0);
                break;
            }

            // Update current sample properties
            f3SamplePos = Ray.Origin + Ray.Dir * Hit.Distance;
            f3Albedo    = Hit.Color;
            f3Normal    = Hit.Normal;
        }

        // Combine path contribution and emissive component for this sample
        f3Radiance += f3PathContrib + f3Emissive;
    }

    // Add the total radiance to the accumulation buffer
    if (g_Constants.fLastSampleCount > 0)
        f3Radiance += g_Radiance[ThreadId.xy].rgb;
    g_Radiance[ThreadId.xy] = float4(f3Radiance, 0.0);
}
