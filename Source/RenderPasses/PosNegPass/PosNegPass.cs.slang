import Utils.Color.ColorHelpers;
// For Pixel Debug
import Utils.Debug.PixelDebug;

Texture2D<float4> gTestImage;
Texture2D<float4> gReferenceImage;
RWTexture2D<float4> gOutputImage;

cbuffer PerFrameCB
{
    float gScaleFactor;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixelPos = dispatchThreadId.xy;

    // For Pixel Debug
    printSetPixel(pixelPos);


    float3 testColor = gTestImage[pixelPos].rgb;
    float3 referenceColor = gReferenceImage[pixelPos].rgb;

    // Compute luminance using the luminance function from ColorHelpers
    float testLuminance = testColor.r + testColor.g + testColor.b;
    float referenceLuminance = referenceColor.r + referenceColor.g + referenceColor.b;

    float luminanceDifference = (testLuminance - referenceLuminance) * gScaleFactor;

    print("testColor", testColor);
    print("referenceColor", referenceColor);

    // Set color: Green for positive, Red for negative differences
    float3 outputColor = (luminanceDifference > 0)
                         ? float3(0.0f, saturate(luminanceDifference), 0.0f)
                         : float3(saturate(abs(luminanceDifference)), 0.0f, 0.0f);

    gOutputImage[pixelPos] = float4(outputColor, 1.0f);
}
