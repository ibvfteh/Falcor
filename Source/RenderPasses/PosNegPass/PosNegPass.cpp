/***************************************************************************
 # Copyright (c) 2015-23, NVIDIA CORPORATION. All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without
 # modification, are permitted provided that the following conditions
 # are met:
 #  * Redistributions of source code must retain the above copyright
 #    notice, this list of conditions and the following disclaimer.
 #  * Redistributions in binary form must reproduce the above copyright
 #    notice, this list of conditions and the following disclaimer in the
 #    documentation and/or other materials provided with the distribution.
 #  * Neither the name of NVIDIA CORPORATION nor the names of its
 #    contributors may be used to endorse or promote products derived
 #    from this software without specific prior written permission.
 #
 # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS "AS IS" AND ANY
 # EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 # IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 # PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 # CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 # PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 # PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 # OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 # OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **************************************************************************/
#include "PosNegPass.h"

namespace
{
const char kShaderFile[] = "RenderPasses/PosNegPass/PosNegPass.cs.slang";
const char kTestImageInput[] = "testImage";
const char kReferenceImageInput[] = "referenceImage";
const char kOutputImage[] = "outputImage";
const char kOutputDisplayImage[] = "outputDisplayImage";
const char kScaleFactor[] = "scaleFactor";
}

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, PosNegPass>();
}

PosNegPass::PosNegPass(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    for (const auto& [key, value] : props)
    {
        if (key == kScaleFactor)
            mScaleFactor = value;
        else
            logWarning("Unknown property '{}' in PosNegPass properties.", key);
    }

    mpComputePass = ComputePass::create(mpDevice, kShaderFile, "main");
}

Properties PosNegPass::getProperties() const
{
    Properties props;
    props[kScaleFactor] = mScaleFactor;
    return props;
}

RenderPassReflection PosNegPass::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;
    reflector.addInput(kTestImageInput, "Test image");
    reflector.addInput(kReferenceImageInput, "Reference image");
    reflector.addOutput(kOutputImage, "Luminance difference output").format(ResourceFormat::RGBA32Float);
    reflector.addOutput(kOutputDisplayImage, "Display output").format(ResourceFormat::RGBA8UnormSrgb);
    return reflector;
}

void PosNegPass::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    auto pTestImage = renderData.getTexture(kTestImageInput);
    auto pReferenceImage = renderData.getTexture(kReferenceImageInput);
    auto pOutputImage = renderData.getTexture(kOutputImage);
    auto pOutputDisplayImage = renderData.getTexture(kOutputDisplayImage);

    if (!pTestImage || !pReferenceImage || !pOutputImage)
    {
        logWarning("PosNegPass::execute() - Missing required textures");
        return;
    }

    auto rootVar = mpComputePass->getRootVar();
    rootVar["gTestImage"] = pTestImage;
    rootVar["gReferenceImage"] = pReferenceImage;
    rootVar["gOutputImage"] = pOutputImage;
    rootVar["PerFrameCB"]["gScaleFactor"] = mScaleFactor;

    mpComputePass->execute(pRenderContext, uint3(pTestImage->getWidth(), pTestImage->getHeight(), 1));

    pRenderContext->blit(pOutputImage->getSRV(), pOutputDisplayImage->getRTV());
}

void PosNegPass::renderUI(Gui::Widgets& widget)
{
    widget.text("Computes luminance difference between test and reference images");
    widget.var("Scale Factor", mScaleFactor, 0.1f, 100.0f, 1.0f);
}
