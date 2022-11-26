#include "structures.fxh"
#include "scene.fxh"
#include "hash.fxh"
#include "PBR_Common.fxh"

Texture2D g_BaseColor;
Texture2D g_Normal;
Texture2D g_Emittance;
Texture2D g_PhysDesc;
Texture2D g_Depth;

RWTexture2D<float4 /*format = rgba32f*/> g_Radiance;

cbuffer cbConstants
{
    ShaderConstants g_Constants;
}

#ifndef THREAD_GROUP_SIZE
#   define THREAD_GROUP_SIZE 8
#endif

// Returns a random cosine-weighted direction on the hemisphere around z = 1.
void SampleDirectionCosineHemisphere(in  float2 UV,  // Normal random variables
                                     out float3 Dir, // Direction
                                     out float  Prob // Probability of the generated direction
                                     )
{
    Dir.x = cos(2.0 * PI * UV.x) * sqrt(1.0 - UV.y);
    Dir.y = sin(2.0 * PI * UV.x) * sqrt(1.0 - UV.y);
    Dir.z = sqrt(UV.y);

    // Avoid zero probability
    Prob = max(Dir.z, 1e-6) / PI;
}

// Returns a random cosine-weighted direction on the hemisphere around N.
void SampleDirectionCosineHemisphere(in  float3 N,   // Normal
                                     in  float2 UV,  // Normal random variables
                                     out float3 Dir, // Direction
                                     out float  Prob // Probability of the generated direction
                                    )
{
    float3 T = normalize(cross(N, abs(N.y) > 0.5 ? float3(1, 0, 0) : float3(0, 1, 0)));
    float3 B = cross(T, N);
    SampleDirectionCosineHemisphere(UV, Dir, Prob);
    Dir = normalize(Dir.x * T + Dir.y * B + Dir.z * N);
}

SurfaceReflectanceInfo GetReflectanceInfo(Material Mat)
{
    float3 f0 = float3(0.04, 0.04, 0.04);

    SurfaceReflectanceInfo SrfInfo;
    SrfInfo.PerceptualRoughness = Mat.Roughness;
    SrfInfo.DiffuseColor        = Mat.BaseColor.rgb * (float3(1.0, 1.0, 1.0) - f0) * (1.0 - Mat.Metallic);
    SrfInfo.Reflectance0        = lerp(f0, Mat.BaseColor.rgb, Mat.Metallic);

    float reflectance = max(max(SrfInfo.Reflectance0.r, SrfInfo.Reflectance0.g), SrfInfo.Reflectance0.b);
    // Anything less than 2% is physically impossible and is instead considered to be shadowing. Compare to "Real-Time-Rendering" 4th editon on page 325.
    SrfInfo.Reflectance90 = clamp(reflectance * 50.0, 0.0, 1.0) * float3(1.0, 1.0, 1.0);

    return SrfInfo;
}

float3 BRDF(HitInfo Hit, float3 OutDir, float3 InDir)
{
    SurfaceReflectanceInfo SrfInfo = GetReflectanceInfo(Hit.Mat);

    float3 DiffuseContrib;
    float3 SpecContrib;
    float  NdotL;
    SmithGGX_BRDF(OutDir,
                  Hit.Normal,
                  InDir, // To light
                  SrfInfo,
                  DiffuseContrib,
                  SpecContrib,
                  NdotL
    );

    return DiffuseContrib + SpecContrib;
}

void ImportanceSampleSmithGGX(HitInfo Hit, float3 View, float3 rnd3, out float3 Dir, out float3 Reflectance, out float Prob)
{
    SurfaceReflectanceInfo SrfInfo = GetReflectanceInfo(Hit.Mat);

    Reflectance = float3(0.0, 0.0, 0.0);
    Prob = 0.0;

    float DiffuseProb = 0.5;
    if (rnd3.z < DiffuseProb)
    {
        SampleDirectionCosineHemisphere(Hit.Normal, rnd3.xy, Dir, Prob);
        Prob *= DiffuseProb;

        float3 H     = normalize(View + Dir);
        float  HdotV = dot(H, View);
        float3 F     = SchlickReflection(HdotV, SrfInfo.Reflectance0, SrfInfo.Reflectance90);

        // BRDF        = DiffuseColor / PI
        // DirProb     = CosTheta / PI
        // Reflectance = (1.0 - F) * BRDF * CosTheta / (DirProb * DiffuseProb)
#if 1
        Reflectance = (1.0 - F) * SrfInfo.DiffuseColor / DiffuseProb;
#else
        float CosTheta = dot(Hit.Normal, Dir);
        Reflectance = (1.0 - F) * LambertianDiffuse(SrfInfo.DiffuseColor) * CosTheta / Prob;
#endif
    }
    else
    {
        // https://schuttejoe.github.io/post/ggximportancesamplingpart2/
        // https://jcgt.org/published/0007/04/01/
        // https://github.com/TheRealMJP/DXRPathTracer/blob/master/DXRPathTracer/RayTrace.hlsl

        // Construct tangent-space basis
        float3 N = Hit.Normal;
        float3 T = normalize(cross(N, abs(N.y) > 0.5 ? float3(1, 0, 0) : float3(0, 1, 0)));
        float3 B = cross(T, N);
        float3x3 TangentToWorld = MatrixFromRows(T, B, N);

        float AlphaRoughness = SrfInfo.PerceptualRoughness * SrfInfo.PerceptualRoughness;

        // Transform normal from world to tangent space
        float3 ViewDirTS     = normalize(mul(View, transpose(TangentToWorld)));
        // Get GGX sampling micronormal in tangent space
        float3 MicroNormalTS = SmithGGXSampleVisibleNormal(ViewDirTS, AlphaRoughness, AlphaRoughness, rnd3.x, rnd3.y);
        // Reflect view direction off the micronormal to get the sampling direction
        float3 SampleDirTS   = reflect(-ViewDirTS, MicroNormalTS);
        float3 NormalTS      = float3(0, 0, 1);

        // Transform tangent space normal to world space
        Dir = normalize(mul(SampleDirTS, TangentToWorld));
        // Get probability of sampling direction
        Prob = SmithGGXSampleDirectionPDF(ViewDirTS, NormalTS, SampleDirTS, AlphaRoughness) * (1.0 - DiffuseProb);

        // Micro normal is the halfway vector
        float HdotV = dot(MicroNormalTS, ViewDirTS);
        // Tangent-space normal is (0, 0, 1)
        float NdotL = SampleDirTS.z;
        float NdotV = ViewDirTS.z;
        if (NdotL > 0 && NdotV > 0)
        {
            float3 F = SchlickReflection(HdotV, SrfInfo.Reflectance0, SrfInfo.Reflectance90);
            float G1 = SmithGGXMasking(NdotV, AlphaRoughness);
            float G2 = SmithGGXShadowMasking(NdotL, NdotV, AlphaRoughness);
#if 1
            Reflectance = F * (G2 / G1) / (1.0 - DiffuseProb);
#else
            // Simplified reflectance formulation above is equivalent to the following
            // standard Monte-Carlo estimator:
            float3 DiffuseContrib, SpecContrib;
            SmithGGX_BRDF(Dir, // To light
                          Hit.Normal,
                          View,
                          SrfInfo,
                          DiffuseContrib,
                          SpecContrib,
                          NdotL
            );
            Reflectance = SpecContrib * NdotL / Prob;
#endif
        }
    }
}

void SampleBRDFDirection(HitInfo Hit, float3 View, float3 rnd3, out float3 Dir, out float3 Reflectance, out float Prob)
{
#if BRDF_SAMPLING_MODE == BRDF_SAMPLING_MODE_COS_WEIGHTED
    SampleDirectionCosineHemisphere(Hit.Normal, rnd3.xy, Dir, Prob);
    // Reflectance = BRDF * CosTheta / Prob
    // Prob = CosTheta / PI
    // Thus:
    Reflectance = BRDF(Hit, View, Dir) * PI;
#elif BRDF_SAMPLING_MODE == BRDF_SAMPLING_MODE_IMPORTANCE_SAMPLING
    ImportanceSampleSmithGGX(Hit, View, rnd3, Dir, Reflectance, Prob);
#endif
}

float BRDFSampleDirection_PDF(HitInfo Hit, float3 V, float3 L)
{
    float3 N = Hit.Normal;

    float NdotV = dot(V, N);
    float NdotL = dot(L, N);
    if (NdotL <= 0.0 || NdotV <= 0.0)
        return 0.0;

    float DiffuseProb = 0.5;
    // Diffuse component
    float Prob = NdotL / PI * DiffuseProb;

    // Specular component
    float AlphaRoughness = Hit.Mat.Roughness * Hit.Mat.Roughness;
    float VNDF = SmithGGXSampleDirectionPDF(V, N, L, AlphaRoughness);
    Prob += VNDF * (1.0 - DiffuseProb);

    return Prob;
}


// Reconstructs primary ray from the G-buffer
void GetPrimaryRay(in    uint2   ScreenXY,
                   out   HitInfo Hit,
                   out   RayInfo Ray)
{
    float  fDepth         = g_Depth.Load(int3(ScreenXY, 0)).r;
    float4 f4BaseCol_Type = g_BaseColor.Load(int3(ScreenXY, 0));
    float4 f4Emittance    = g_Emittance.Load(int3(ScreenXY, 0));
    float4 f4Normal_IOR   = g_Normal.Load(int3(ScreenXY, 0));
    float2 f2PhysDesc     = g_PhysDesc.Load(int3(ScreenXY, 0)).rg;


    float3 HitPos = ScreenToWorld(float2(ScreenXY) + float2(0.5, 0.5),
                                  fDepth, 
                                  g_Constants.f2ScreenSize,
                                  g_Constants.ViewProjInvMat);

    Ray.Origin = g_Constants.CameraPos.xyz;
    float3 RayDir = HitPos - Ray.Origin;
    float  RayLen = length(RayDir);
    Ray.Dir = RayDir / RayLen;

    Hit.Mat.BaseColor = float4(f4BaseCol_Type.rgb, 0.0);
    Hit.Mat.Emittance = f4Emittance;
    Hit.Mat.Metallic  = f2PhysDesc.x;
    Hit.Mat.Roughness = f2PhysDesc.y;
    Hit.Mat.Type      = int(f4BaseCol_Type.a * 255.0);
    Hit.Mat.IOR       = max(f4Normal_IOR.w * 5.0, 1.0);

    Hit.Normal   = normalize(f4Normal_IOR.xyz * 2.0 - 1.0);
    Hit.Distance = RayLen;
}

void SampleLight(LightAttribs Light, float2 rnd2, float3 f3HitPos, out float3 f3LightRadiance, out float3 f3DirToLight, out float Prob)
{
    float  fLightArea       = (Light.f2SizeXZ.x * 2.0) * (Light.f2SizeXZ.y * 2.0);
    float3 f3LightIntensity = Light.f4Intensity.rgb * Light.f4Intensity.a;
    float3 f3LightNormal    = Light.f4Normal.xyz;

    float3 f3LightSample = GetLightSamplePos(Light, rnd2);
    f3DirToLight  = f3LightSample - f3HitPos;
    float fDistToLightSqr = dot(f3DirToLight, f3DirToLight);
    f3DirToLight /= sqrt(fDistToLightSqr);

    // Trace shadow ray towards the light sample
    RayInfo ShadowRay;
    ShadowRay.Origin = f3HitPos;
    ShadowRay.Dir    = f3DirToLight;
    float fLightVisibility = TestShadow(g_Constants.Scene, ShadowRay);

    // In Monte-Carlo integration, we pretend that each sample speaks for the full light
    // source surface, so we project the entire light surface area onto the hemisphere
    // around the shaded point and see how much solid angle it covers.
    float fLightProjectedArea = fLightArea * max(dot(-f3DirToLight, f3LightNormal), 0.0) / fDistToLightSqr;
    // Notice that when not using NEE, we randomly sample the hemisphere and will
    // eventually cover the same solid angle.

    Prob = fLightProjectedArea > 0.0 ? 1.0 / fLightProjectedArea : 0.0;
    f3LightRadiance = fLightProjectedArea * f3LightIntensity * fLightVisibility;
}

float LightDirPDF(LightAttribs Light, float3 f3HitPos, float3 f3DirToLight)
{
    HitInfo Hit = NullHit();
    RayInfo Ray;
    Ray.Origin = f3HitPos;
    Ray.Dir    = f3DirToLight;
    IntersectLight(Ray, Light, Hit);
    if (Hit.Mat.Type != MAT_TYPE_DIFFUSE_LIGHT)
        return 0.0;

    if (max(Hit.Mat.Emittance.x, max(Hit.Mat.Emittance.y, Hit.Mat.Emittance.z)) == 0.0)
        return 0.0;

    float fLightArea = (Light.f2SizeXZ.x * 2.0) * (Light.f2SizeXZ.y * 2.0);
    float fDistToLightSqr = Hit.Distance * Hit.Distance;
    float fLightProjectedArea = fLightArea * max(dot(-f3DirToLight, Light.f4Normal.xyz), 0.0) / fDistToLightSqr;

    return fLightProjectedArea > 0 ? 1.0 / fLightProjectedArea : 0.0;
}


void Reflect(HitInfo Hit, float3 f3HitPos, inout RayInfo Ray, inout float3 f3Througput)
{
    Ray.Origin = f3HitPos;
    Ray.Dir    = reflect(Ray.Dir, Hit.Normal);
    f3Througput *= Hit.Mat.BaseColor.rgb;
}


// Fresnel term
// https://en.wikipedia.org/wiki/Fresnel_equations
//
//             cosThetaI
//           |      .'
//           |    .'
//           |  .'      Ri
//   ________|.'__________    eta = Ri/Rt
//          /|
//         / |          Rt
//        /  |
//       /   |
//  cosThetaT
//
float Fresnel(float eta, float cosThetaI)
{
    cosThetaI = clamp(cosThetaI, -1.0, 1.0);
    if (cosThetaI < 0.0)
    {
        eta = 1.0 / eta;
        cosThetaI = -cosThetaI;
    }

    // Snell's law:
    // Ri * sin(ThetaI) = Rt * sin(ThetaT)
    float sinThetaTSq = eta * eta * (1.0 - cosThetaI * cosThetaI);
    if (sinThetaTSq >= 1.0)
    {
        // Total internal reflection
        return 1.0;
    }

    float cosThetaT = sqrt(1.0 - sinThetaTSq);

    float Rs = (eta * cosThetaI - cosThetaT) / (eta * cosThetaI + cosThetaT);
    float Rp = (eta * cosThetaT - cosThetaI) / (eta * cosThetaT + cosThetaI);

    return 0.5 * (Rs * Rs + Rp * Rp);
}

void Refract(HitInfo Hit, float3 f3HitPos, inout RayInfo Ray, inout float3 f3Througput, float rnd)
{
    // Compute fresnel term
    float AirIOR    = 1.0;
    float GlassIOR  = Hit.Mat.IOR;
    float relIOR    = AirIOR / GlassIOR;
    float cosThetaI = dot(-Ray.Dir, Hit.Normal);
    if (cosThetaI < 0.0)
    {
        Hit.Normal *= -1.0;
        cosThetaI  *= -1.0;
        relIOR = 1.0 / relIOR;
    }
    float F = Fresnel(relIOR, cosThetaI);

    if (rnd <= F)
    {
        // Note that technically we need to multiply throughput by F,
        // but also by 1/P, but since P==F they cancel out.
        Reflect(Hit, f3HitPos, Ray, f3Througput);
    }
    else
    {
        Ray.Origin = f3HitPos;
        Ray.Dir    = refract(Ray.Dir, Hit.Normal, relIOR);

        // Note that refraction also changes the differential solid angle of the flux
        f3Througput /= relIOR * relIOR;
    }
}

[numthreads(THREAD_GROUP_SIZE, THREAD_GROUP_SIZE, 1)]
void main(uint3 ThreadId : SV_DispatchThreadID)
{
    if (ThreadId.x >= g_Constants.u2ScreenSize.x ||
        ThreadId.y >= g_Constants.u2ScreenSize.y)
        return; // Outside of the screen

    HitInfo Hit0;
    RayInfo Ray0;
    GetPrimaryRay(ThreadId.xy, Hit0, Ray0);

    if (Hit0.Mat.Type == MAT_TYPE_NONE)
    {
        // Background
        g_Radiance[ThreadId.xy] = float4(0.0, 0.0, 0.0, 0.0);
        return;
    }

    float3 f3Radiance = float3(0.0, 0.0, 0.0);

    // Rendering equation
    //
    //   L(x->v)         L(x<-w)
    //      '.           .'
    //        '.       .'
    //        v '.   .' w
    //            '.'
    //             x
    //
    //      L(x->v) = E(x) + Integral{ BRDF(x, v, w) * L(x<-w) * (n, w) * dw }
    //
    // Monte-Carlo integration:
    //
    //   L(x1->v)         x2
    //       .           .'.
    //        '.       .'   '.
    //        v '.   .' w1    '.w2
    //            '.'           '. 
    //             x1             x3
    //
    //      L(x1->v) = 1/N * Sum{ E(x1) + BRDF(x1, v1, w1) * [E(x2) + BRDF(x2, -w1, w2) * (...) * (n2, w2) * 1/p(w2)]  * (n1, w1) * 1/p(w1) }
    //
    //  This can be rewritten as
    //
    //      L(x1->v) = 1/N * { T0 * E(x1) + T1 * E(x2) + T2 * E(x3) + ... }
    //
    //  where Ti is the throughput after i bounces:
    //
    //      T0 = 1
    //      Ti = Ti-1 * BRDF(xi, vi, wi) * (ni, wi) / p(wi)

    // Make sure the seed is unique for each sample
    uint2 Seed = ThreadId.xy * uint2(11417, 7801) + uint2(g_Constants.uFrameSeed1, g_Constants.uFrameSeed2);
    for (int i = 0; i < g_Constants.iNumSamplesPerFrame; ++i)
    {
        // Each path starts with the primary camera ray
        HitInfo Hit = Hit0;
        RayInfo Ray = Ray0;

        // Total contribution of this path
        float3 f3PathContrib = float3(0.0, 0.0, 0.0);
        if (g_Constants.iUseNEE != 0)
        {
            // We need to add emittance from the first hit, which is like performing
            // light source sampling for the primary ray origin (aka "0-th" hit).
            f3PathContrib += Hit0.Mat.Emittance.rgb;
        }

        // Path throughput, or the maximum possible remaining contribution after all bounces so far.
        float3 f3Throughput = float3(1.0, 1.0, 1.0);
        // Note that when using next event estimation, we sample light source at each bounce.
        // To compensate for that, we add extra bounce when not using NEE.
        for (int j = 0; j < g_Constants.iNumBounces + (1 - g_Constants.iUseNEE); ++j)
        {
            if (g_Constants.iShowOnlyLastBounce != 0)
                f3PathContrib = float3(0.0, 0.0, 0.0);

            if (Hit.Mat.Type == MAT_TYPE_NONE)
                break;

            if (max(f3Throughput.x, max(f3Throughput.y, f3Throughput.z)) == 0.0)
                break;

            float3 f3HitPos = Ray.Origin + Ray.Dir * Hit.Distance;

            // Get random sample on the light source surface.
            float3 rnd3 = hash32(Seed);
            // Update the seed
            Seed += uint2(129, 1725);

            if (Hit.Mat.Type == MAT_TYPE_MIRROR)
            {
                Reflect(Hit, f3HitPos, Ray, f3Throughput);
                // Note: if NEE is enabled, we need to perform light sampling here.
                //       However, since we need to sample the light in the same reflected direction,
                //       we will add its contribution later when we find the next hit point.
            }
            else if (Hit.Mat.Type == MAT_TYPE_GLASS)
            {
                Refract(Hit, f3HitPos, Ray, f3Throughput, rnd3.x);
                // As with mirror, we will perform light sampling later
            }
            else
            {
                if (g_Constants.iUseNEE != 0)
                {
                    // Sample light source
                    #if NEE_MODE == NEE_MODE_LIGHT || NEE_MODE == NEE_MODE_MIS || NEE_MODE == NEE_MODE_MIS_LIGHT
                    {
                        float3 f3LightEmittance;
                        float3 f3DirToLight;
                        float  Prob;
                        SampleLight(g_Constants.Scene.Light, rnd3.xy, f3HitPos, f3LightEmittance, f3DirToLight, Prob);
                        float NdotL = max(dot(f3DirToLight, Hit.Normal), 0.0);

                        float CombinedProb = Prob;
                        #if NEE_MODE == NEE_MODE_MIS || NEE_MODE == NEE_MODE_MIS_LIGHT
                            CombinedProb += BRDFSampleDirection_PDF(Hit, -Ray.Dir, f3DirToLight);
                        #endif
                        if (CombinedProb > 0)
                        {
                            float Weight = Prob / CombinedProb;
                            float3 fLightContrib = 
                                BRDF(Hit, -Ray.Dir, f3DirToLight)
                                * NdotL
                                * f3LightEmittance
                                * Weight;
                            f3PathContrib += fLightContrib * f3Throughput;
                        }
                    }
                    #endif

                    // Sample BRDF
                    #if NEE_MODE == NEE_MODE_BRDF || NEE_MODE == NEE_MODE_MIS || NEE_MODE == NEE_MODE_MIS_BRDF
                    {
                        // Sample the BRDF
                        float3 Reflectance;
                        float3 f3DirToLight;
                        float  Prob;
                        SampleBRDFDirection(Hit, -Ray.Dir, rnd3.zxy, f3DirToLight, Reflectance, Prob);
                        HitInfo LightHit = NullHit();
                        RayInfo LightRay;
                        LightRay.Origin = f3HitPos;
                        LightRay.Dir    = f3DirToLight;
                        IntersectLight(LightRay, g_Constants.Scene.Light, LightHit);
                        if (LightHit.Mat.Type == MAT_TYPE_DIFFUSE_LIGHT)
                        {
                            float fLightVisibility = TestShadow(g_Constants.Scene, LightRay);
                            if (fLightVisibility > 0)
                            {
                                float CombinedProb = Prob;
                                #if NEE_MODE == NEE_MODE_MIS || NEE_MODE == NEE_MODE_MIS_BRDF
                                    CombinedProb += LightDirPDF(g_Constants.Scene.Light, f3HitPos, f3DirToLight);
                                #endif
                                float NdotL = dot(f3DirToLight, Hit.Normal);
                                if (CombinedProb > 0 && NdotL > 0)
                                {
                                    float MISWeight = Prob / CombinedProb;
                                    f3PathContrib +=
                                        f3Throughput
                                        * Reflectance
                                        * LightHit.Mat.Emittance.rgb
                                        * fLightVisibility
                                        * MISWeight;
                                }
                            }
                        }
                    }
                    #endif
                }
                else
                {
                    f3PathContrib += f3Throughput * Hit.Mat.Emittance.rgb;
                }

                // NEE effectively performs one additional bounce
                if (j == g_Constants.iNumBounces - g_Constants.iUseNEE)
                {
                    // Last bounce - complete the loop
                    break; 
                }

                // Sample the BRDF
                float3 Reflectance;
                float3 Dir;
                float  Prob;
                SampleBRDFDirection(Hit, -Ray.Dir, rnd3, Dir, Reflectance, Prob);

                f3Throughput *= Reflectance;

                Ray.Origin = f3HitPos;
                Ray.Dir    = Dir;
            }

            // We did not perform next event estimation for the mirror surface and
            // we need to add emittance of the next hit point.
            bool AddEmittance = (g_Constants.iUseNEE != 0) && (Hit.Mat.Type == MAT_TYPE_MIRROR || Hit.Mat.Type == MAT_TYPE_GLASS);

            // Trace the scene in the selected direction
            Hit = IntersectScene(Ray, g_Constants.Scene);

            if (AddEmittance)
                f3PathContrib += f3Throughput * Hit.Mat.Emittance.rgb;
        }

        // Combine contributions
        f3Radiance += f3PathContrib;
    }

    // Add the total radiance to the accumulation buffer
    if (g_Constants.fLastSampleCount > 0)
        f3Radiance += g_Radiance[ThreadId.xy].rgb;
    g_Radiance[ThreadId.xy] = float4(f3Radiance, 0.0);
}
