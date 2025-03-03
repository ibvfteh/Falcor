cbuffer CB
{
    uint gHashTableSize;
    float gAccumEMACoeff;
}

// Hash Grid
RWStructuredBuffer<float3> hashGridAccum;
RWStructuredBuffer<float3> hashGridAccumAvg;

[numthreads(128, 1, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    if (dispatchThreadId.x >= gHashTableSize) return; // Over the limit

    hashGridAccumAvg[dispatchThreadId.x] = hashGridAccumAvg[dispatchThreadId.x] * (1 - gAccumEMACoeff) + gAccumEMACoeff * hashGridAccum[dispatchThreadId.x];
    hashGridAccum[dispatchThreadId.x] = 0;
}
