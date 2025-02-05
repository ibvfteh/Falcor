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

/**
 * Samples a random emissive light source and deposits its energy into the hash grid.
 */
[numthreads(128, 1, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    if (dispatchThreadId.x >= gInstanceCount) return; // Over the limit

    // For Pixel Debug
    printSetPixel(uint2(dispatchThreadId.x, 0));
    // print("LightCount", gScene.getLightCount());
    print("gScene.lightCollection.getActiveTriangleCount()", gScene.lightCollection.getActiveTriangleCount());

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

    // uint gridIndex = 40782;

    // // Divide energy by the number of instances for normalization
    // float3 depositedEnergy = ls.Li / float(gInstanceCount);
    float3 depositedEnergy = 0.01f;

    // Atomically accumulate into the hash grid
    // TODO: change to InterlockedAddF32
    // InterlockedAdd(hashGrid[gridIndex].x, depositedEnergy.x);
    // InterlockedAdd(hashGrid[gridIndex].y, depositedEnergy.y);
    // InterlockedAdd(hashGrid[gridIndex].z, depositedEnergy.z);
    hashGrid[gridIndex] += depositedEnergy; //depositedEnergy;
}
