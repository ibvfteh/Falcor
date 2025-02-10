// #include "Scene/SceneDefines.slangh"
// #include "Utils/Math/MathConstants.slangh"

import Scene.Scene;
// import Utils.Sampling.SampleGenerator;
// import Rendering.Lights.LightHelpers;
// import Utils.Geometry.GeometryHelpers;
// import Utils.Debug.PixelDebug;

// struct HashCell
// {
//     float3 light;
//     float3 intersections[10];
//     uint intersectionCount;
// };

cbuffer HashGridCB
{
    float gHashGridScale;               // Hash Grid spatial discretization step.
    // uint gHashGridIntersectPointsCount; // Max number of points that were hit inside the hash cell
    uint gMaxIntersectPointCount;
    uint gHashTableSize;
}

struct Itersect
{
    float3 pos;
    float3 dir;
};

// Hash Grid
RWStructuredBuffer<float3> hashGrid;                  // Stores light energy in hash cells
RWStructuredBuffer<Itersect> hashGridIntersectPoints;     // Stores intersection points in hash cells.
// RWBuffer<PackedHitInfo> hashGridIntersectPoints;     // other variation
RWStructuredBuffer<uint32_t> hashGridIntersectPointsCount;  // Number of intersection points

// NO, because energy will be zeroed out, but intersection points will stay
// RWStructuredBuffer<HashCell> hashGrid;                    // Stores light energy in hash cells

// Random Sampling Seed
static const uint kSeed = 42;

/**
 * Hash function for single value.
 */
uint hash(uint a) {
    a = (a ^ 61) ^ (a >> 16);
    a = a + (a << 3);
    a = a ^ (a >> 4);
    a = a * 0x27d4eb2d;
    a = a ^ (a >> 15);
    return a;
}

/**
 * Hash function for spatial indexing.
 * TODO: jenkinsHash? from Utils.HashUtils
 */
uint hash(uint3 idx, uint seed) {
    return hash(idx.x ^ hash(idx.y ^ hash(idx.z ^ hash(seed))));
}

/**
 * Computes the hash grid index for a given position.
 */
uint hashGridGetIndex(float3 position) {
    uint numStructs, stride;
    hashGrid.GetDimensions(numStructs, stride);
    const int3 idx_ = int3(floor(position / gHashGridScale));

    const uint idx = hash(idx_, kSeed) % numStructs;
    return idx;
}
