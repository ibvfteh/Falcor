// #include "Scene/SceneDefines.slangh"
// #include "Utils/Math/MathConstants.slangh"

// import Scene.Scene;
// import Utils.Sampling.SampleGenerator;
// import Rendering.Lights.LightHelpers;
// import Utils.Geometry.GeometryHelpers;
// import Utils.Debug.PixelDebug;

cbuffer HashGridCB
{
    uint gHashGridScale; ///< Scale of the hash grid.
}

// Hash Grid
RWStructuredBuffer<float3> hashGrid; ///< Accumulates energy per grid cell.

// Random Sampling Seed
static const uint kSeed = 42;

// Shader Constants
static const float kGridSpacing = 0.1; ///< Spatial discretization step.

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
    const int3 idx_ = int3(floor(position / kGridSpacing));

    const uint idx = hash(idx_, kSeed) % numStructs;
    return idx;
}
