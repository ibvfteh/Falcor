// #include "Scene/SceneDefines.slangh"
// #include "Utils/Math/MathConstants.slangh"

import Scene.Scene;
import Utils.Debug.PixelDebug;
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
RWStructuredBuffer<uint32_t> hashGridIntersectPointsCount; // Number of intersection points
RWByteAddressBuffer hashGridbuff;

// Buffer for Locking mechanism
RWByteAddressBuffer lockBuffer;

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

bool lock (uint index)
{
    uint expected = 0;
    uint desired = 1;
    uint original;

    // Spinlock: Try to set lockBuffer[index] to 1 if it is currently 0
    int i = 0;
    do {
        lockBuffer.InterlockedCompareExchange(index, expected, desired, original);
        if (i++ > 10000) return false;
    } while (original != expected);
    return true;
}

void unlock(uint index)
{
    uint original;
    lockBuffer.InterlockedExchange(index, 0, original);
}

uint encodeDirection(float3 dir) {
    // Compute absolute values to find the dominant axis
    float3 absDir = abs(dir);

    // Find the axis with the maximum value
    if (absDir.x > absDir.y && absDir.x > absDir.z)
    {
        return (dir.x > 0) ? 0 : 1; // Right (0) or Left (1)
    }
    else if (absDir.y > absDir.x && absDir.y > absDir.z)
    {
        return (dir.y > 0) ? 2 : 3; // Up (2) or Down (3)
    }
    else
    {
        return (dir.z > 0) ? 4 : 5; // Forward (4) or Backward (5)
    }
}

/**
 * Computes the hash grid index for a given position.
 */
uint hashGridGetIndex(float3 position, float3 direction) {
    uint numStructs, stride;
    hashGrid.GetDimensions(numStructs, stride);
    const int3 idx_ = int3(floor(position / gHashGridScale));

    // const uint idx = hash(idx_, kSeed) % numStructs;
    const uint idx = (hash(idx_, kSeed) * 6 + encodeDirection(direction)) % numStructs;
    return idx;
}
