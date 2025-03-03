// #include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"
#include "Utils/NVAPI.slangh"

import Scene.Scene;
import Utils.Debug.PixelDebug;
import Utils.Math.MathHelpers;
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

struct GaussianArea
{
    float3 mean_normal;
    float3 mean_point;
    float var_x;
    float var_y;
    uint count;
};

// Hash Grid
// RWStructuredBuffer<float3> hashGridUnshot;                // Stores light energy in hash cells
RWStructuredBuffer<uint> hashFingerprints;          // Stores fingerprints for collision prevention

RWStructuredBuffer<Itersect> hashGridIntersectPoints;     // Stores intersection points in hash cells.
// RWBuffer<PackedHitInfo> hashGridIntersectPoints;     // other variation
RWStructuredBuffer<uint32_t> hashGridIntersectPointsCount; // Number of intersection points
RWByteAddressBuffer hashGridUnshot;

// Buffer for Locking mechanism
RWByteAddressBuffer lockBuffer;

// Area estimations
RWByteAddressBuffer hashTotalAreaBuffer; // Sum of all computed areas
RWByteAddressBuffer hashCountBuffer;     // Counts how many areas have been added
RWByteAddressBuffer hashAreaLockBuffer;      // Lock for synchronization

// // GAUSS TODO:
// RWByteAddressBuffer hashGridMeanBuffer;        // Stores mean_point and mean_normal
// RWByteAddressBuffer hashGridVarBuffer;         // Stores var_x and var_y
// RWByteAddressBuffer hashGridCountBuffer;       // Stores count

// NO, because energy will be zeroed out, but intersection points will stay
// RWStructuredBuffer<HashCell> hashGrid;                    // Stores light energy in hash cells

// Random Sampling Seed
static const uint kSeed = 42;
static const uint maxTries = 10; // Maximum attempts to resolve a collision
static const uint stride = 1;    // Linear probing step

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
uint hash(uint3 idx, uint seed)
{
    return hash(idx.x ^ hash(idx.y ^ hash(idx.z ^ hash(seed))));
}

uint encodeDirection(float3 dir)
{
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
uint hashGridGetIndex(float3 position, float3 direction)
{
    const int3 idx_ = int3(floor(position / gHashGridScale));
    const uint baseIdx = hash(idx_, kSeed);
    const uint fingerprint = hash(idx_, 175649571);
    const uint startIdx = (baseIdx * 6 + encodeDirection(direction)) % gHashTableSize;

    for (uint i = 0; i < maxTries; i++) {
        uint idx = (startIdx + stride * i) % gHashTableSize;
        uint originalFingerprint = 0;

        // Atomic operation to check if the slot is free or already taken
        InterlockedCompareExchange(hashFingerprints[idx], 0, fingerprint, originalFingerprint);

        if (originalFingerprint == 0 || originalFingerprint == fingerprint) {
            return idx; // Found a free slot or the same fingerprint exists
        }
    }
    return 0;
}

void addIntersectionPoint(uint index, float3 position, float3 normal)
{
    uint pointNum;

    // Atomically increment the count and retrieve the previous value
    InterlockedAdd(hashGridIntersectPointsCount[index * 2], 1, pointNum);

    // Ensure the count wraps around correctly
    uint newCount = (pointNum + 1) % gMaxIntersectPointCount;

    // Use InterlockedMax to ensure we keep track of the highest value
    InterlockedMax(hashGridIntersectPointsCount[index * 2 + 1], newCount);

    // Safely write position and normal to the corresponding index
    uint writeIndex = index * gMaxIntersectPointCount + (pointNum % gMaxIntersectPointCount);
    hashGridIntersectPoints[writeIndex].pos = position;
    hashGridIntersectPoints[writeIndex].dir = normal;
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

float3 projectOntoPlane(float3 point, float3 planePoint, float3 normal) {
    float3 v = point - planePoint;
    float dist = dot(v, normal);
    return point - dist * normal;
}

float computeBoundingRectangleArea(uint index)
{
    uint pointCount = hashGridIntersectPointsCount[index * 2 + 1];

    if (pointCount == 0) return 0.0; // No valid points

    // Read normal from the first point
    float3 normal = hashGridIntersectPoints[index * gMaxIntersectPointCount].dir;

    // Compute ONB for the plane
    float3 u, v;
    branchlessONB(normal, u, v);

    // Reference point for projection
    float3 planePoint = hashGridIntersectPoints[index * gMaxIntersectPointCount].pos;

    // Transform points into 2D space
    float2 minVal = float2(FLT_MAX, FLT_MAX);
    float2 maxVal = float2(-FLT_MAX, -FLT_MAX);

    for (uint i = 0; i < pointCount; i++) {
        float3 projected = projectOntoPlane(hashGridIntersectPoints[index * gMaxIntersectPointCount + i].pos, planePoint, normal);
        float2 transformed = float2(dot(projected, u), dot(projected, v));

        minVal = min(minVal, transformed);
        maxVal = max(maxVal, transformed);
    }

    // Compute bounding rectangle dimensions
    float width = maxVal.x - minVal.x;
    float height = maxVal.y - minVal.y;

    // Return rectangle area
    return width * height;
}

float getArea(uint index)
{
    float area = asfloat(hashTotalAreaBuffer.Load(index * 4));

    // Try to acquire lock
    uint expected = 0;
    uint desired = 1;
    uint original;
    hashAreaLockBuffer.InterlockedCompareExchange(index, expected, desired, original);

    if (original == 0) { // Lock acquired
        float newArea = computeBoundingRectangleArea(index);

        // Increment count
        uint count;
        hashCountBuffer.InterlockedAdd(index * 4, 1, count);

        // Read and update total area
        hashTotalAreaBuffer.InterlockedAddF32(index * 4, (newArea - area) / (count + 1));

        // Release lock
        hashAreaLockBuffer.InterlockedExchange(index, 0, original);
    }

    return 1.56 * area;
    // return 1.388 * area;
}

// GAUSS TODO:
// void update_estimator(uint index, float3 point, float3 normal)
// {
//     uint baseOffset = index * 24; // 6 floats * 4 bytes each (mean_point + mean_normal)
//     uint varOffset = index * 8;   // 2 floats * 4 bytes each (var_x, var_y)
//     uint countOffset = index * 4; // 1 uint * 4 bytes

//     // Retrieve the previous count before incrementing
//     uint count = hashGridCountBuffer.Load(countOffset);

//     print("count", count);

//     // First entry case
//     if (count == 0)
//     {
//         hashGridMeanBuffer.Store(baseOffset, point.x);
//         hashGridMeanBuffer.Store(baseOffset + 4, point.y);
//         hashGridMeanBuffer.Store(baseOffset + 8, point.z);

//         hashGridMeanBuffer.Store(baseOffset + 12, normal.x);
//         hashGridMeanBuffer.Store(baseOffset + 16, normal.y);
//         hashGridMeanBuffer.Store(baseOffset + 20, normal.z);

//         float initialVar = 0;                               //(gHashGridScale * gHashGridScale) / 36;
//         hashGridVarBuffer.Store(varOffset, initialVar);     // Store var_x
//         hashGridVarBuffer.Store(varOffset + 4, initialVar); // Store var_y
//         hashGridCountBuffer.Store(countOffset, 1);          // Store var_y
//         return;
//     }

//     hashGridCountBuffer.InterlockedAdd(countOffset, 1);
//     count++; // The updated count for this thread

//     float a = 1.0f / count;

//     // Retrieve old mean values
//     float3 mean_point = asfloat(hashGridMeanBuffer.Load3(baseOffset));

//     // Atomic updates to mean point
//     hashGridMeanBuffer.Store(baseOffset, mean_point.x + a * (point.x - mean_point.x));
//     hashGridMeanBuffer.Store(baseOffset + 4, mean_point.y + a * (point.y - mean_point.x));
//     hashGridMeanBuffer.Store(baseOffset + 8, mean_point.z + a * (point.z - mean_point.x));
//     // hashGridMeanBuffer.InterlockedAddF32(baseOffset, a * (point.x - mean_point.x));
//     // hashGridMeanBuffer.InterlockedAddF32(baseOffset + 4, a * (point.y - mean_point.y));
//     // hashGridMeanBuffer.InterlockedAddF32(baseOffset + 8, a * (point.z - mean_point.z));

//     float3 mean_normal = asfloat(hashGridMeanBuffer.Load3(baseOffset + 12));
//     // Atomic updates to mean normal
//     hashGridMeanBuffer.Store(baseOffset + 12, mean_normal.x + a * (normal.x - mean_normal.x));
//     hashGridMeanBuffer.Store(baseOffset + 16, mean_normal.y + a * (normal.y - mean_normal.x));
//     hashGridMeanBuffer.Store(baseOffset + 20, mean_normal.z + a * (normal.z - mean_normal.x));
//     // hashGridMeanBuffer.InterlockedAddF32(baseOffset + 12, a * (normal.x - mean_normal.x));
//     // hashGridMeanBuffer.InterlockedAddF32(baseOffset + 16, a * (normal.y - mean_normal.y));
//     // hashGridMeanBuffer.InterlockedAddF32(baseOffset + 20, a * (normal.z - mean_normal.z));

//     print("mean_point", mean_point);
//     print("mean_normal", mean_normal);

//     // Normalize mean normal after all updates
//     mean_normal = normalize(asfloat(hashGridMeanBuffer.Load3(baseOffset + 12)));

//     // Generate ONB
//     float3 tangent, bitangent;
//     branchlessONB(mean_normal, tangent, bitangent);

//     // Compute projection
//     float3 delta = point - mean_point; // asfloat(hashGridMeanBuffer.Load3(baseOffset));

//     print("point", point);
//     print("mean_point", mean_point);
//     print("hashGridMean", asfloat(hashGridMeanBuffer.Load3(baseOffset)));
//     print("delta", delta);

//     float x = dot(tangent, delta);
//     float y = dot(bitangent, delta);

//     print("x", x);
//     print("y", y);

//     // Retrieve old variance
//     float var_x = asfloat(hashGridVarBuffer.Load(varOffset));
//     float var_y = asfloat(hashGridVarBuffer.Load(varOffset + 4));

//     print("vvx", var_x);
//     print("vvy", var_y);

//     // Atomic updates for variance (Welford's method)
//     // hashGridVarBuffer.InterlockedAddF32(varOffset, (x * x - var_x) * a);
//     // hashGridVarBuffer.InterlockedAddF32(varOffset + 4, (y * y - var_y) * a);

//     hashGridVarBuffer.Store(varOffset, var_x + (x * x - var_x) * a);
//     hashGridVarBuffer.Store(varOffset + 4, var_y + (y * y - var_y) * a);

//     print("vx", sqrt(asfloat(hashGridVarBuffer.Load(varOffset))));
//     print("vy", sqrt(asfloat(hashGridVarBuffer.Load(varOffset + 4))));
// }

// float estimate_area(uint index)
// {
//     uint varOffset = index * 8;
//     float sigma_x = sqrt(asfloat(hashGridVarBuffer.Load(varOffset)));
//     float sigma_y = sqrt(asfloat(hashGridVarBuffer.Load(varOffset + 4)));

//     // 3 sigma square area
//     return 12 * sigma_x * sigma_y;
// }
