
#ifndef GROUP_SIZE
#   define GROUP_SIZE 32
#endif

#ifdef VULKAN
#   define float2   vec2
#   define float4   vec4
#   define uint4    uvec4
#   define float4x4 mat4x4
#endif

struct DrawTask
{
    float2 BasePos; // read-only
    float  Scale;   // read-only
    float  Time;    // read-write
};

struct CubeData
{
    float4 SphereRadius;
    float4 Positions[24];
    float4 UVs[24];
    uint4  Indices[36 / 3]; // 3 indices per element
};

struct Constants
{
    float4x4 ViewMat;
    float4x4 ViewProjMat;
    float4   Frustum[6];
    float    CoTanHalfFov;
    float    ElapsedTime;
    bool     FrustumCulling;
    bool     Animate;
};

#ifndef VULKAN

// Payload size must be less than 16kb.
struct Payload
{
    float PosX[GROUP_SIZE];
    float PosY[GROUP_SIZE];
    float PosZ[GROUP_SIZE];
    float Scale[GROUP_SIZE];
    float LODs[GROUP_SIZE];
};

#endif
