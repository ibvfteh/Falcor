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
RWStructuredBuffer<uint32_t> hashGridExplored; ///< Accumulates energy per grid cell.

/**
 * Samples a random emissive light source and deposits its energy into the hash grid.
 */
[numthreads(128, 1, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    if (dispatchThreadId.x >= gInstanceCount) return; // Over the limit

    // // For Pixel Debug
    printSetPixel(uint2(dispatchThreadId.x, 0));
    // printSetPixel(uint2(0, 0));
    // print("index", dispatchThreadId.x);
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

    // Get origin with offset applied in direction of the geometry normal to avoid self-intersection.
    const float3 rayOrigin = computeRayOrigin(posW, tri.normal);

    float area = tri.area;

    // // Compute hash grid index for sampled light position
    uint gridIndex = hashGridGetIndex(rayOrigin, tri.normal);

    // float sampleArea = tri.area / (float(gInstanceCount) / triangleCount);

    // // Divide energy by the number of instances for normalization
    float2 uv = tri.getTexCoord(barycentrics);
    float3 Le = gScene.materials.evalEmissive(tri.materialID, uv);

    // Compute Radiance
    float3 Be = Le * M_PI; // / (float(gInstanceCount) / triangleCount) / (gHashGridScale * gHashGridScale);
    // Compute Flux
    float3 Phie = Be * tri.area;

    // Flux for one sample
    float3 samplePhie = Phie / (float(gInstanceCount) / triangleCount);

    // float3 depositedEnergy = Be / float(gInstanceCount);
    // float3 Be = Le * M_PI;
    // float3 depositedEnergy = Be;

    // Accumulate into the hash grid
    hashGridUnshot.InterlockedAddF32(gridIndex * 12, samplePhie.x);
    hashGridUnshot.InterlockedAddF32(gridIndex * 12 + 4, samplePhie.y);
    hashGridUnshot.InterlockedAddF32(gridIndex * 12 + 8, samplePhie.z);
    // hashGrid[gridIndex] += depositedEnergy;
    // if (lock(gridIndex))
    // {
    //     hashGrid[gridIndex] = hashGrid[gridIndex] + samplePhie;
    //     unlock(gridIndex);
    // }
    // else
    //     print("no luck", samplePhie);

    // unlock(gridIndex);
    // unlock(gridIndex);

    // print("posW", posW);
    // print("tri.normal", tri.normal);

    // print("samplePhie", samplePhie);
    // print("gridIndex", gridIndex);
    // print("hashGrid[gridIndex]", hashGrid[gridIndex]);

    // add new point for random selection
    hashGridExplored[gridIndex] = 1;
    addIntersectionPoint(gridIndex, rayOrigin, tri.normal);
}
