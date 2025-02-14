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
import Scene.RaytracingInline;
import Scene.Material.ShadingUtils;
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
RWStructuredBuffer<uint32_t> hashGridExplored;
RWStructuredBuffer<uint32_t> hashGridCDF;            ///< Accumulates energy per grid cell.
RWStructuredBuffer<uint32_t> hashGridCDFSum;         ///< Accumulates energy per grid cell.

RWByteAddressBuffer lockBuffer;

RWStructuredBuffer<float3> hashGridAccum;

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

/**
 * Setup ShadingData based on loaded vertex/material attributes for a hit point.
 * @param[in] hit Hit information.
 * @param[in] rayOrigin Ray origin.
 * @param[in] rayDir Normalized ray direction.
 * @return ShadingData struct.
 */
ShadingData loadShadingData(const HitInfo hit, const float3 rayOrigin, const float3 rayDir)
{
    VertexData v = {};
    uint materialID = {};

#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_TRIANGLE_MESH)
    if (hit.getType() == HitType::Triangle)
    {
        const TriangleHit triangleHit = hit.getTriangleHit();
        v = gScene.getVertexData(triangleHit);
        materialID = gScene.getMaterialID(triangleHit.instanceID);
    }
#endif
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_DISPLACED_TRIANGLE_MESH)
    if (hit.getType() == HitType::DisplacedTriangle)
    {
        const DisplacedTriangleHit displacedTriangleHit = hit.getDisplacedTriangleHit();
        v = gScene.getVertexData(displacedTriangleHit, -rayDir);
        materialID = gScene.getMaterialID(displacedTriangleHit.instanceID);
    }
#endif
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_CURVE)
    if (hit.getType() == HitType::Curve)
    {
        const CurveHit curveHit = hit.getCurveHit();
        v = gScene.getVertexDataFromCurve(curveHit);
        materialID = gScene.getMaterialID(curveHit.instanceID);
    }
#endif
#if SCENE_HAS_GEOMETRY_TYPE(GEOMETRY_TYPE_SDF_GRID)
    if (hit.getType() == HitType::SDFGrid)
    {
        const SDFGridHit sdfGridHit = hit.getSDFGridHit();
        v = gScene.getVertexDataFromSDFGrid(sdfGridHit, rayOrigin, rayDir);
        materialID = gScene.getMaterialID(sdfGridHit.instanceID);
    }
#endif

    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir);

    return sd;
}

void lock(uint index)
{
    uint expected = 0;
    uint desired = 1;
    uint original;

    // Spinlock: Try to set lockBuffer[index] to 1 if it is currently 0
    int i = 0;
    do {
        lockBuffer.InterlockedCompareExchange(index, expected, desired, original);
        if (i++ > 1000) return;
    } while (original != expected);
}

void unlock(uint index)
{
    uint original;
    lockBuffer.InterlockedExchange(index, 0, original);
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

    uint shootIndex = binarySearchHashGridCDFIndex(searchValue, gHashTableSize);
    float pointPDF = (hashGridCDF[shootIndex] - hashGridCDF[shootIndex - 1]) / totalHashCDFSum;

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
    uint intersectionPointIndex = (uint)(hashGridIntersectPointsCount[shootIndex * 2 + 1] * randomValue);
    // print("intersectionPointIndex", intersectionPointIndex);
    float3 primaryRayOrigin = hashGridIntersectPoints[shootIndex * gMaxIntersectPointCount + intersectionPointIndex].pos;

    // print("rayOrigin", primaryRayOrigin);

    // Generate a random direction
    float3 normal = hashGridIntersectPoints[shootIndex * gMaxIntersectPointCount + intersectionPointIndex].dir;

    // print("rayNormal", normal);

    float cosinePDF;
    float3 localDir = sample_cosine_hemisphere_concentric(sampleNext2D(sg), cosinePDF);
    // float cosinePDF = 1 / M_2_PI;
    // float3 localDir = sample_hemisphere(sampleNext2D(sg));
    // Generate an orthonormal basis from the normal.
    float3 tangent, bitangent;
    branchlessONB(normal, tangent, bitangent);
    // Transform local sample to world space.
    float3 primaryRayDir = tangent * localDir.x +  bitangent * localDir.y + normal * localDir.z;

    // print("shootDir", primaryRayDir);

    // float energyx = asfloat(hashGrid.Load(shootIndex * 12));
    // float energyy = asfloat(hashGrid.Load(shootIndex * 12 + 4));
    // float energyz = asfloat(hashGrid.Load(shootIndex * 12 + 8));
    // float3 energy = float3(energyx, energyy, energyz);
    // hashGrid.InterlockedAddF32(shootIndex * 12, -energy.x);
    // hashGrid.InterlockedAddF32(shootIndex * 12 + 4, -energy.y);
    // hashGrid.InterlockedAddF32(shootIndex * 12 + 8, -energy.z);

    print("hashGrid[shootIndex]", hashGrid[shootIndex]);

    float3 energy = hashGrid[shootIndex] / 4;

    // Define and trace the ray
    const Ray ray = Ray(primaryRayOrigin, primaryRayDir, 0.001f, 1000.0f);
    SceneRayQuery<1> rayQuery;
    float hitT;
    HitInfo hit = rayQuery.traceRay(ray, hitT, RAY_FLAG_NONE, 0xff);

    // print("localDir", localDir);
    // print("primaryRayDir", primaryRayDir);

    lock (shootIndex);
    if (all(hashGrid[shootIndex] > float3(0.0f, 0.0f, 0.0f)))
        hashGrid[shootIndex] -= energy;
        hashGridAccum[shootIndex] += energy;
    unlock(shootIndex);


    if (hit.isValid())
    {
        const bool isCurveHit = hit.getType() == HitType::Curve;

        // Load shading data.
        ShadingData sd = loadShadingData(hit, primaryRayOrigin, primaryRayDir);

        // Compute ray origin for new rays spawned from the hit.
        float3 hitOrigin;
        if (isCurveHit)
        {
            // For curves, we set the new origin at the sphere center.
            hitOrigin = sd.posW - sd.curveRadius * sd.frame.N;
        }
        else
        {
            hitOrigin = sd.computeRayOrigin();
        }

        // Get hash index
        uint gridIndex = hashGridGetIndex(hitOrigin);

        float3 hitNormal = sd.getOrientedFaceNormal();

        float cosi_curr = dot(hitNormal, -primaryRayDir);
        float cosj_curr = dot(normal, primaryRayDir);
        float eps = 1e-18;
        float G_curr = max(cosi_curr * cosj_curr, 0) / (M_PI * hitT * hitT + eps);

        // print("sd.frame.N", sd.faceN);
        // print("hitOrigin", hitOrigin);
        // print("primaryRayOrigin", primaryRayOrigin);
        // // print("cosi_curr", cosi_curr);
        // print("hitT", hitT);

        float jacobian_curr = max(cosi_curr, 0) / (hitT * hitT + eps);
        float pdf_curr = cosinePDF * jacobian_curr;
        // float T_curr = cosinePDF * curr_jacobian;
        // float g_y = hashGrid[gridIndex].x; // Assuming importance is stored in x component

        print("cosj_curr", cosj_curr);
        print("GGGGGGGGG", G_curr / pdf_curr);

        // Create material instance.

        let lod = ExplicitLodTextureSampler(0.f);
        let mi = gScene.materials.getMaterialInstance(sd, lod);

        // print("kek", mi.getProperties(sd).emission);

        BSDFProperties bsdf = mi.getProperties(sd);

        float3 f_y = energy * bsdf.diffuseReflectionAlbedo * cosj_curr;
        hashGrid[gridIndex] = f_y;


        // print("energy", energy);
        // print("bsdf", bsdf.diffuseReflectionAlbedo);
        // // print("G_curr", G_curr);
        // // print("pdf_curr", pdf_curr);
        // print("f_y", f_y);

        // hashGrid[gridIndex] = max(primaryRayDir, float3(0.0, 0.0, 0.0));
        // hashGrid.InterlockedAddF32(shootIndex * 12, -f_y.x);
        // hashGrid.InterlockedAddF32(shootIndex * 12 + 4, -f_y.y);
        // hashGrid.InterlockedAddF32(shootIndex * 12 + 8, -f_y.z);

        // float acceptance_prob = min(1.0, g_y * T_curr / (g_y + eps));

        // if (sampleNext1D(sg) < acceptance_prob)
        // {
        //     hashGrid[gridIndex] += ;
        // }

        // add new point for random selection
        hashGridExplored[gridIndex] = 1;
        uint pointNum = hashGridIntersectPointsCount[gridIndex * 2];
        hashGridIntersectPointsCount[gridIndex * 2] = (pointNum + 1) % 10;
        hashGridIntersectPointsCount[gridIndex * 2 + 1] = max(hashGridIntersectPointsCount[gridIndex * 2 + 1], pointNum + 1);
        hashGridIntersectPoints[gridIndex * gMaxIntersectPointCount + pointNum].pos = hitOrigin;
        hashGridIntersectPoints[gridIndex * gMaxIntersectPointCount + pointNum].dir = sd.faceN;
    }
}
