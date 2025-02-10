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
    uint gFrameCount;    // Frame count since scene was loaded.
    uint gInstanceCount; ///< Number of instances for energy division.
}

// Hash Grid
RWStructuredBuffer<uint32_t> hashGridCDF; ///< Accumulates energy per grid cell.

/**
 * Samples a random emissive light source and deposits its energy into the hash grid.
 */
[numthreads(128, 1, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    if (dispatchThreadId.x >= gInstanceCount) return; // Over the limit

    // // For Pixel Debug
    // printSetPixel(uint2(dispatchThreadId.x, 0));
    // // print("LightCount", gScene.getLightCount());
    // print("getActiveTriangleCount", gScene.lightCollection.getActiveTriangleCount());

    // Initialise sampler
    SampleGenerator sg = SampleGenerator(dispatchThreadId.xy, gFrameCount);

    // Randomly pick a triangle out of the global list of active triangles with uniform probability.
    float uLight = sampleNext1D(sg);
    uint triangleCount = gScene.lightCollection.getActiveTriangleCount();
    uint idx = min((uint)(uLight * triangleCount), triangleCount - 1); // Safety precaution as the result of the multiplication may be rounded to triangleCount even if uLight < 1.0 when triangleCount is large.
    uint triangleIndex = gScene.lightCollection.activeTriangles[idx];
    float triangleSelectionPdf = 1.f / (float)triangleCount;

    // Sample the triangle uniformly.
    float2 u = sampleNext2D(sg);
    const EmissiveTriangle tri = gScene.lightCollection.getTriangle(triangleIndex);

    // Sample the triangle uniformly.
    const float3 barycentrics = sample_triangle(u);
    float3 posW = tri.getPosition(barycentrics);

    // // Compute hash grid index for sampled light position
    uint gridIndex = hashGridGetIndex(posW);

    // // Divide energy by the number of instances for normalization
    float2 uv = tri.getTexCoord(barycentrics);
    float3 Le = gScene.materials.evalEmissive(tri.materialID, uv);

    // TODO: check if correct
    float3 Be = Le / (M_PI * gHashGridScale * gHashGridScale);
    float3 depositedEnergy = Be / float(gInstanceCount);

    // print("Le", Le);
    // print("Be", Be);
    // print("gHashGridScale", gHashGridScale);
    // print("kSeed", kSeed);
    // print("depositedEnergy", depositedEnergy);

    // Atomically accumulate into the hash grid
    // TODO: change to InterlockedAddF32
    // InterlockedAdd(hashGrid[gridIndex].x, depositedEnergy.x);
    // InterlockedAdd(hashGrid[gridIndex].y, depositedEnergy.y);
    // InterlockedAdd(hashGrid[gridIndex].z, depositedEnergy.z);
    hashGrid[gridIndex] += depositedEnergy;
    hashGridCDF[gridIndex] = 1;
    uint pointNum = hashGridIntersectPointsCount[gridIndex * 2];
    hashGridIntersectPointsCount[gridIndex * 2] = (pointNum + 1) % 10;
    hashGridIntersectPointsCount[gridIndex * 2 + 1] = max(hashGridIntersectPointsCount[gridIndex * 2 + 1], pointNum + 1);
    hashGridIntersectPoints[gridIndex * gMaxIntersectPointCount + pointNum].pos = posW;
    hashGridIntersectPoints[gridIndex * gMaxIntersectPointCount + pointNum].dir = tri.normal;
}
