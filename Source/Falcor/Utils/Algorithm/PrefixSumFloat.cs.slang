#include "Utils/NVAPI.slangh"

cbuffer CB
{
    uint gNumGroups;      ///< Number of groups we'll process.
    uint gTotalNumElems;  ///< Total number of elements.
    uint gIter;           ///< Current iteration number.
};

RWByteAddressBuffer gData;            ///< Data buffer (floats stored as 4-byte values).
RWByteAddressBuffer gPrefixGroupSums; ///< Stores sum of all elements in each group.
RWByteAddressBuffer gTotalSum;        ///< Stores total sum of the entire dataset.
ByteAddressBuffer gPrevTotalSum;      ///< Stores previous iteration's total sum.

groupshared float gSharedData[2 * GROUP_SIZE]; ///< Temporary shared memory buffer.

/**
 * Parallel prefix sum in shared memory over consecutive groups of 2N elements.
 */
[numthreads(GROUP_SIZE, 1, 1)]
void groupScanFloat(uint3 groupID: SV_GroupID, uint3 groupThreadID: SV_GroupThreadID)
{
    const uint thid = groupThreadID.x;
    const uint groupIdx = groupID.x;

    const float prevSum = asfloat(gPrevTotalSum.Load(0));
    const uint idx = 2 * GROUP_SIZE * GROUP_SIZE * gIter + groupIdx * (2 * GROUP_SIZE) + thid;

    gSharedData[thid] = (idx < gTotalNumElems ? asfloat(gData.Load(idx * 4)) : 0.0f);
    gSharedData[thid + GROUP_SIZE] = ((idx + GROUP_SIZE) < gTotalNumElems ? asfloat(gData.Load((idx + GROUP_SIZE) * 4)) : 0.0f);

    // Reduction phase
    uint offset = 1;
    for (uint d = GROUP_SIZE; d > 0; d >>= 1)
    {
        GroupMemoryBarrierWithGroupSync();

        if (thid < d)
        {
            uint ai = offset * (2 * thid + 1) - 1;
            uint bi = ai + offset;
            gSharedData[bi] += gSharedData[ai];
        }
        offset *= 2;
    }

    GroupMemoryBarrierWithGroupSync();

    if (thid >= groupIdx && thid < gNumGroups)
    {
        float sum = gSharedData[2 * GROUP_SIZE - 1];
        gPrefixGroupSums.InterlockedAddF32(thid * 4, sum);

        if (thid == gNumGroups - 1)
        {
            gTotalSum.InterlockedAddF32(0, sum);
        }
    }

    GroupMemoryBarrierWithGroupSync();

    if (thid == 0)
        gSharedData[2 * GROUP_SIZE - 1] = 0.0f;

    // Down-sweep phase
    for (uint d = 1; d <= GROUP_SIZE; d *= 2)
    {
        offset >>= 1;
        GroupMemoryBarrierWithGroupSync();

        if (thid < d)
        {
            uint ai = offset * (2 * thid + 1) - 1;
            uint bi = ai + offset;

            float tmp = gSharedData[ai];
            gSharedData[ai] = gSharedData[bi];
            gSharedData[bi] += tmp;
        }
    }

    GroupMemoryBarrierWithGroupSync();

    if (idx < gTotalNumElems)
        gData.Store(idx * 4, asuint(gSharedData[thid] + prevSum));
    if ((idx + GROUP_SIZE) < gTotalNumElems)
        gData.Store((idx + GROUP_SIZE) * 4, asuint(gSharedData[thid + GROUP_SIZE] + prevSum));
}

/**
 * Finalizes prefix sum by adding per-group sums to the output.
 */
[numthreads(GROUP_SIZE, 1, 1)]
void finalizeGroupsFloat(uint3 groupID: SV_GroupID, uint3 groupThreadID: SV_GroupThreadID)
{
    const uint thid = groupThreadID.x;
    const uint groupIdx = groupID.x;

    float sum = asfloat(gPrefixGroupSums.Load((groupIdx >> 1) * 4));
    uint globalIdx = (groupIdx * GROUP_SIZE) + thid + 2 * GROUP_SIZE * (1 + GROUP_SIZE * gIter);

    if (globalIdx < gTotalNumElems)
    {
        uint addr = globalIdx * 4;
        float elem = asfloat(gData.Load(addr));
        gData.Store(addr, asuint(elem + sum));
    }
}
