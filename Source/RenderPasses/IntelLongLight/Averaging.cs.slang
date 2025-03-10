cbuffer CB
{
    uint gHashTableSize;
    float gAccumEMACoeff;
}

// Energy Hash Grid
RWStructuredBuffer<float3> hashGridUnshot;
RWStructuredBuffer<float3> hashGridAccum;
RWStructuredBuffer<float3> hashGridAccumAvg;
// Importance Hash Grid
RWStructuredBuffer<float> hashGridUnshotImportance;
RWStructuredBuffer<float> hashGridAccumImportance;
RWStructuredBuffer<float> hashGridAccumAvgImportance;

[numthreads(128, 1, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    if (dispatchThreadId.x >= gHashTableSize) return; // Over the limit

    float3 newEnergyVal = hashGridAccum[dispatchThreadId.x]; // + hashGridUnshot[dispatchThreadId.x];

    hashGridAccumAvg[dispatchThreadId.x] = hashGridAccumAvg[dispatchThreadId.x] * (1 - gAccumEMACoeff) + gAccumEMACoeff * newEnergyVal;
    hashGridAccum[dispatchThreadId.x] = 0;

    float newImportanceVal = hashGridAccumImportance[dispatchThreadId.x]; // + hashGridUnshotImportance[dispatchThreadId.x];

    // hashGridAccumAvgImportance[dispatchThreadId.x] = hashGridUnshotImportance[dispatchThreadId.x];
    hashGridAccumAvgImportance[dispatchThreadId.x] = hashGridAccumAvgImportance[dispatchThreadId.x] * (1 - gAccumEMACoeff) + gAccumEMACoeff * newImportanceVal;
    hashGridAccumImportance[dispatchThreadId.x] = 0;
}
