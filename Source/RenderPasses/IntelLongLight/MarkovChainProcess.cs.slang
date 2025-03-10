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
    uint gIterationCount;        // Frame count since scene was loaded.
    uint gMarkovChainsCount; // Number of active markov chains
}

// Hash Grid
// RWStructuredBuffer<uint32_t> hashGridExplored;
// RWStructuredBuffer<uint32_t> hashGridCDF; ///< Accumulates energy per grid cell.
// RWStructuredBuffer<uint32_t> hashGridCDFSum;
RWByteAddressBuffer hashGridExplored;
RWByteAddressBuffer hashGridCDF;    ///< Accumulates energy per grid cell.
RWByteAddressBuffer hashGridCDFSum; ///< Accumulates energy per grid cell.
// Importance
RWByteAddressBuffer hashGridImportanceCDF;    ///< Accumulates energy per grid cell.
RWByteAddressBuffer hashGridImportanceCDFSum; ///< Accumulates energy per grid cell.

RWByteAddressBuffer hashGridAccum;

RWByteAddressBuffer hashGridUnshotImportance;
RWByteAddressBuffer hashGridAccumImportance;

struct MarkovChainState
{
    float3 point1;
    float3 normal1;
    float3 point2;
    float3 normal2;
    uint init;
};

RWStructuredBuffer<MarkovChainState> markovChainStates;

// Function to optimize
float optimisationFunction(uint index)
{
    return asfloat(hashGridAccumImportance.Load(index * 4)) * (asfloat(hashGridAccum.Load(index * 12)) + asfloat(hashGridAccum.Load(index * 12 + 4)) + asfloat(hashGridAccum.Load(index * 12 + 8)));
}

// looks into CDF to get a selected index of a grid
uint binarySearchHashGridCDFIndex(float searchValue, uint totalElements)
{
    // uint searchValue = (uint)(randomValue * totalElements);
    uint left = 0;
    uint right = totalElements - 1;
    while (left < right)
    {
        uint mid = (left + right) / 2;
        // print("hashGridCDF.mid", asfloat(hashGridCDF.Load(mid * 12)));
        // print("hashGridCDFsum", asfloat(hashGridCDFSum.Load(0)));

        // print("hashGridImportanceCDF.mid", asfloat(hashGridImportanceCDF.Load(mid * 4)));
        // print("hashGridImportanceCDFsum", asfloat(hashGridImportanceCDFSum.Load(0)));

        float energyCDFValue = asfloat(hashGridCDF.Load(mid * 12)) / (asfloat(hashGridCDFSum.Load(0)) + FLT_EPSILON);
        float importanceCDFValue = asfloat(hashGridImportanceCDF.Load(mid * 4)) / (asfloat(hashGridImportanceCDFSum.Load(0)) + FLT_EPSILON);
        float cdfValue = (energyCDFValue + importanceCDFValue) / 2;
        // float cdfValue = importanceCDFValue;
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

[numthreads(128, 1, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    if (dispatchThreadId.x >= gMarkovChainsCount) return; // Over the limit

    // For Pixel Debug
    printSetPixel(uint2(dispatchThreadId.x, 0));
    // printSetPixel(uint2(0, 0));
    // print("LightCount", gScene.getLightCount());
    // print("getActiveTriangleCount", gScene.lightCollection.getActiveTriangleCount());

    // Initialise sampler
    SampleGenerator sg = SampleGenerator(dispatchThreadId.xy, gFrameCount);

    // if large or small step

    // Randomly pick a hash grid from the researched ones
    float randomValue = sampleNext1D(sg);
    // uint32_t totalHashCDFSum = hashGridCDFSum[0];

    // print("totalHashCDFSum", totalHashCDFSum);
    // print("searchValue", searchValue);

    print("r", randomValue);

    uint shootGridIndex = binarySearchHashGridCDFIndex(randomValue, gHashTableSize);

    print("shootGridIndex", shootGridIndex);

    float pointPDF = (hashGridCDF.Load(shootGridIndex * 4) - hashGridCDF.Load((shootGridIndex - 1) * 4)) / asfloat(hashGridCDFSum.Load(0));
    // float pointPDF = (hashGridCDF[shootGridIndex] - hashGridCDF[shootGridIndex - 1]) / totalHashCDFSum;

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
    uint intersectionPointIndex = (uint)(hashGridIntersectPointsCount[shootGridIndex * 2 + 1] * randomValue);
    // print("intersectionPointIndex", intersectionPointIndex);
    float3 primaryRayOrigin = hashGridIntersectPoints[shootGridIndex * gMaxIntersectPointCount + intersectionPointIndex].pos;

    // print("rayOrigin", primaryRayOrigin);

    // Generate a random direction
    float3 shotNormal = hashGridIntersectPoints[shootGridIndex * gMaxIntersectPointCount + intersectionPointIndex].dir;

    // print("rayNormal", shotNormal);

    float cosinePDF;
    float3 localDir = sample_cosine_hemisphere_concentric(sampleNext2D(sg), cosinePDF);
    // float cosinePDF = 1 / (2 * M_PI);
    // float3 localDir = sample_hemisphere(sampleNext2D(sg));
    // Generate an orthonormal basis from the normal.
    float3 tangent, bitangent;
    branchlessONB(shotNormal, tangent, bitangent);
    // Transform local sample to world space.
    float3 primaryRayDir = tangent * localDir.x +  bitangent * localDir.y + shotNormal * localDir.z;

    // print("shootDir", primaryRayDir);

    // float energyx = asfloat(hashGrid.Load(shootGridIndex * 12));
    // float energyy = asfloat(hashGrid.Load(shootGridIndex * 12 + 4));
    // float energyz = asfloat(hashGrid.Load(shootGridIndex * 12 + 8));
    // float3 energy = float3(energyx, energyy, energyz);
    // hashGrid.InterlockedAddF32(shootGridIndex * 12, -energy.x);
    // hashGrid.InterlockedAddF32(shootGridIndex * 12 + 4, -energy.y);
    // hashGrid.InterlockedAddF32(shootGridIndex * 12 + 8, -energy.z);

    // print("hashGrid[shootGridIndex]", hashGrid[shootGridIndex]);

    // Define and trace the ray
    const Ray ray = Ray(primaryRayOrigin, primaryRayDir, 0.001f, 1000.0f);
    SceneRayQuery<1> rayQuery;
    float hitT;
    HitInfo hit = rayQuery.traceRay(ray, hitT, RAY_FLAG_NONE, 0xff);

    // print("localDir", localDir);
    // print("primaryRayDir", primaryRayDir);

    float3 energy;

    float energy_devidor = 10.0f;

    // Subtract energy from hashgrid
    float originalRed;
    float value = asfloat(hashGridUnshot.Load(shootGridIndex * 12));
    if (value < 0.0f)
        return;
    energy.x = value / energy_devidor;
    hashGridUnshot.InterlockedAddF32(shootGridIndex * 12, -energy.x, originalRed);
    if (originalRed - energy.x < 0)
    {
        hashGridUnshot.InterlockedAddF32(shootGridIndex * 12, energy.x);
        return;
    }

    float originalGreen;
    value = asfloat(hashGridUnshot.Load(shootGridIndex * 12 + 4));
    if (value < 0.0f)
    {
        hashGridUnshot.InterlockedAddF32(shootGridIndex * 12, energy.x);
        return;
    }
    energy.y = value / energy_devidor;
    hashGridUnshot.InterlockedAddF32(shootGridIndex * 12 + 4, -energy.y, originalGreen);
    if (originalGreen - energy.y < 0)
    {
        hashGridUnshot.InterlockedAddF32(shootGridIndex * 12, energy.x);
        hashGridUnshot.InterlockedAddF32(shootGridIndex * 12 + 4, energy.y);
        return;
    }

    float originalBlue;
    value = asfloat(hashGridUnshot.Load(shootGridIndex * 12 + 8));
    if (value < 0.0f)
    {
        hashGridUnshot.InterlockedAddF32(shootGridIndex * 12, energy.x);
        hashGridUnshot.InterlockedAddF32(shootGridIndex * 12 + 4, energy.y);
        return;
    }
    energy.z = value / energy_devidor;
    hashGridUnshot.InterlockedAddF32(shootGridIndex * 12 + 8, -energy.z, originalBlue);
    if (originalBlue - energy.z < 0)
    {
        hashGridUnshot.InterlockedAddF32(shootGridIndex * 12, energy.x);
        hashGridUnshot.InterlockedAddF32(shootGridIndex * 12 + 4, energy.y);
        hashGridUnshot.InterlockedAddF32(shootGridIndex * 12 + 8, energy.z);
        return;
    }

    hashGridAccum.InterlockedAddF32(shootGridIndex * 12, energy.x);
    hashGridAccum.InterlockedAddF32(shootGridIndex * 12 + 4, energy.y);
    hashGridAccum.InterlockedAddF32(shootGridIndex * 12 + 8, energy.z);


    // if (lock (shootGridIndex))
    // {
    //     if (all(hashGrid[shootGridIndex] <= float3(0.0f, 0.0f, 0.0f)))
    //     {
    //         unlock(shootGridIndex);
    //         return;
    //     }
    //     energy = hashGrid[shootGridIndex] / 1;
    //     hashGrid[shootGridIndex] -= energy;
    //     hashGridAccum[shootGridIndex] += energy;
    //     unlock(shootGridIndex);


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

        float3 hitNormal = sd.getOrientedFaceNormal();

        // Get hash index
        uint hitGridIndex = hashGridGetIndex(hitOrigin, hitNormal);

        // print("markovChainStates.init", markovChainStates[dispatchThreadId.x].init);

        // add new point for random selection
        // hashGridExplored[hitGridIndex] = 1;
        hashGridExplored.Store(hitGridIndex * 4, 1.0f);
        addIntersectionPoint(hitGridIndex, hitOrigin, hitNormal);

        // No previous stae
        if (true)
        // if (markovChainStates[dispatchThreadId.x].init == 0)
        {
            float cosi_curr = dot(hitNormal, -primaryRayDir);
            float cosj_curr = dot(shotNormal, primaryRayDir);

            let lod = ExplicitLodTextureSampler(0.f);
            let mi = gScene.materials.getMaterialInstance(sd, lod);

            BSDFProperties bsdf = mi.getProperties(sd);
            // TODO:
            // float3 weight = mi.eval(sd, shotNormal, sg);

            // float F = max(cosi_curr * cosj_curr, 0) / (M_PI);

            float3 f_y = energy * bsdf.diffuseReflectionAlbedo;

            // float F = max(cosi_curr * cosj_curr, 0) / (M_PI);

            // float3 f_y = energy * bsdf.diffuseReflectionAlbedo * cosj_curr;

            // if (lock (hitGridIndex))
            // {
            //     hashGrid[hitGridIndex] += f_y;
            // }
            // unlock(hitGridIndex);
            hashGridUnshot.InterlockedAddF32(hitGridIndex * 12, f_y.x);
            hashGridUnshot.InterlockedAddF32(hitGridIndex * 12 + 4, f_y.y);
            hashGridUnshot.InterlockedAddF32(hitGridIndex * 12 + 8, f_y.z);

            // hashGridAccum.InterlockedAddF32(hitGridIndex * 12, f_y.x);
            // hashGridAccum.InterlockedAddF32(hitGridIndex * 12 + 4, f_y.y);
            // hashGridAccum.InterlockedAddF32(hitGridIndex * 12 + 8, f_y.z);


            // Propogate Importance
            float originalImportance;
            value = asfloat(hashGridUnshotImportance.Load(shootGridIndex * 4));
            if (value > 0.0f)
            {
                float importance = value / energy_devidor;
                hashGridUnshotImportance.InterlockedAddF32(shootGridIndex * 4, -importance, originalImportance);
                hashGridAccumImportance.InterlockedAddF32(shootGridIndex * 4, importance);
                if (originalImportance - importance < 0)
                    hashGridUnshotImportance.InterlockedAddF32(shootGridIndex * 4, importance);
                else
                {
                    float I = 0.5 * importance;
                    hashGridUnshotImportance.InterlockedAddF32(hitGridIndex * 4, I);
                }

            }
            value = asfloat(hashGridUnshotImportance.Load(hitGridIndex * 4));
            if (value > 0.0f)
            {
                float importance = value / energy_devidor;
                hashGridUnshotImportance.InterlockedAddF32(hitGridIndex * 4, -importance, originalImportance);
                hashGridAccumImportance.InterlockedAddF32(hitGridIndex * 4, importance);
                if (originalImportance - importance < 0)
                    hashGridUnshotImportance.InterlockedAddF32(hitGridIndex * 4, importance);
                else
                {
                    float I = 0.5 * importance;
                    hashGridUnshotImportance.InterlockedAddF32(shootGridIndex * 4, I);
                }
            }

            // Save State
            markovChainStates[dispatchThreadId.x].init = 1;
            markovChainStates[dispatchThreadId.x].point1 = hitOrigin;
            markovChainStates[dispatchThreadId.x].normal1 = hitNormal;
            markovChainStates[dispatchThreadId.x].point2 = primaryRayOrigin;
            markovChainStates[dispatchThreadId.x].normal2 = shotNormal;
        }
        else
        {
            float cosi_curr = dot(hitNormal, -primaryRayDir);
            float cosj_curr = dot(shotNormal, primaryRayDir);
            float eps = 1e-18;
            float G_curr = max(cosi_curr * cosj_curr, 0) / (M_PI * hitT * hitT + eps);

            float jacobian_curr = max(cosi_curr, 0) / (hitT * hitT + eps);
            float T_curr = cosinePDF * jacobian_curr;

            // Load prevoius state
            float3 prevPoint1 = markovChainStates[dispatchThreadId.x].point1;
            float3 prevPoint2 = markovChainStates[dispatchThreadId.x].point2;
            float3 prevNormal1 = markovChainStates[dispatchThreadId.x].normal1;
            float3 prevNormal2 = markovChainStates[dispatchThreadId.x].normal2;
            float prevDist = distance(prevPoint2, prevPoint1);
            float3 prevRayDir = normalize(prevPoint1 - prevPoint2);

            float cosi_prev = dot(prevNormal1, -prevRayDir);
            float cosj_prev = dot(prevNormal2, prevRayDir);
            float G_prev = max(cosi_prev * cosj_prev, 0) / (M_PI * prevDist * prevDist + eps);

            float jacobian_prev = cosi_prev / (prevDist * prevDist + eps);
            float pdf_prev = cosj_prev / M_PI;
            float T_prev = pdf_prev * jacobian_prev;

            // Importance
            float g_y = 1 * jacobian_curr;
            float g_x = 1 * jacobian_prev;

            print("T_prev", T_prev);
            print("T_curr", T_curr);

            // Acceptance
            float acceptance_prob = min(1.0, g_y * T_prev / (g_x * T_curr + eps));

            print("accept", acceptance_prob);

            if (sampleNext1D(sg) < acceptance_prob)
            {
                // Create material instance.
                let lod = ExplicitLodTextureSampler(0.f);
                let mi = gScene.materials.getMaterialInstance(sd, lod);

                BSDFProperties bsdf = mi.getProperties(sd);

                float3 f_y = energy * bsdf.diffuseReflectionAlbedo * G_curr;

                print("f_y", f_y);

                // hashGridUnshot[hitGridIndex] += f_y / g_y;
                hashGridUnshot.InterlockedAddF32(hitGridIndex * 12, f_y.x / g_y);
                hashGridUnshot.InterlockedAddF32(hitGridIndex * 12 + 4, f_y.y / g_y);
                hashGridUnshot.InterlockedAddF32(hitGridIndex * 12 + 8, f_y.z / g_y);

                // Save State
                markovChainStates[dispatchThreadId.x].init = 1;
                markovChainStates[dispatchThreadId.x].point1 = hitOrigin;
                markovChainStates[dispatchThreadId.x].normal1 = hitNormal;
                markovChainStates[dispatchThreadId.x].point2 = primaryRayOrigin;
                markovChainStates[dispatchThreadId.x].normal2 = shotNormal;
            }
        }
    }
    // }
    // unlock(shootGridIndex);
}
