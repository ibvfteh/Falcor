//
// takes chains
// if chain is not initialized (bool value large step = 0)
// or just needs a large step (same criteria)
// perform a large step:
//      select random hash grid:
//          binary search in CDF
//          probability is value over count
//      random ray shooting
//      intersect geometry
//      write to hash CDF as explored point
//
// (step 2, for the first time not implement)
// else small
//      not so random shooting
// determine large or small is next

#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Scene;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Debug.PixelDebug;
import Utils.Math.MathHelpers;
import Rendering.Lights.EmissiveLightSamplerInterface;
import HashGrid;

cbuffer PerFrameCB
{
    uint gFrameCount;        // Frame count since scene was loaded.
    uint gMarkovChainsCount; // Number of active markov chains
}

// Hash Grid
RWStructuredBuffer<uint32_t> hashGridCDF;            ///< Accumulates energy per grid cell.
RWStructuredBuffer<uint32_t> hashGridCDFSum; ///< Accumulates energy per grid cell.

// looks into CDF to get a selected index of a grid
uint binarySearchHashGridCDFIndex(float searchValue, uint totalElements)
{
    // uint searchValue = (uint)(randomValue * totalElements);
    uint left = 0;
    uint right = totalElements - 1;
    while (left < right)
    {
        uint mid = (left + right) / 2;
        uint cdfValue = hashGridCDF[mid];
        // print("cdfValue", cdfValue);
        if (cdfValue < searchValue)
        {
            left = mid + 1;
        }
        else
        {
            right = mid;
        }
    }
    return left - 1;
}

// Find random ray origin point from a hash grid index, on geometry
float3 hashGridGetRandomPosition(uint index, float) {

}

[numthreads(128, 1, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    if (dispatchThreadId.x >= gMarkovChainsCount) return; // Over the limit

    // For Pixel Debug
    printSetPixel(uint2(dispatchThreadId.x, 0));
    // print("LightCount", gScene.getLightCount());
    // print("getActiveTriangleCount", gScene.lightCollection.getActiveTriangleCount());

    // Initialise sampler
    SampleGenerator sg = SampleGenerator(dispatchThreadId.xy, gFrameCount);

    // if large or small step

    // Randomly pick a hash grid from the researched ones
    float randomValue = sampleNext1D(sg);
    uint32_t totalHashCDFSum = hashGridCDFSum[0];
    float searchValue = randomValue * totalHashCDFSum;

    // print("totalHashCDFSum", totalHashCDFSum);
    // print("searchValue", searchValue);

    uint idx = binarySearchHashGridCDFIndex(searchValue, gHashTableSize);
    float pointPDF = (hashGridCDF[idx] - hashGridCDF[idx - 1]) / totalHashCDFSum;

    // print("idx", idx);

    // idea 1
    // sample random 3D point in hash grid
    // select a random direction
    // shoot two rays directly opposite to each other

    // idea 2
    // save N last intersection points
    // choose one from there
    randomValue = sampleNext1D(sg);

    // print("hashGridIntersectPointsCount", hashGridIntersectPointsCount[idx * 2 + 1]);
    uint intersectionPointIndex = (uint)(hashGridIntersectPointsCount[idx * 2 + 1] * randomValue);
    // print("intersectionPointIndex", intersectionPointIndex);
    float3 rayOrigin = hashGridIntersectPoints[idx * gMaxIntersectPointCount + intersectionPointIndex].pos;

    print("rayOrigin", rayOrigin);


    // Generate a random direction
    float3 normal = hashGridIntersectPoints[idx * gMaxIntersectPointCount + intersectionPointIndex].dir;

    print("rayNormal", normal);

    float cosinePDF;
    float3 localDir = sample_cosine_hemisphere_concentric(sampleNext2D(sg), cosinePDF);
    // Generate an orthonormal basis from the normal.
    float3 tangent, bitangent;
    branchlessONB(normal, tangent, bitangent);
    // Transform local sample to world space.
    float3 shootDir = tangent * localDir.x + bitangent * localDir.y + normal * localDir.z;

    print("shootDir", shootDir);
}
