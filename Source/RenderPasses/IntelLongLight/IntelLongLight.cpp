#include "IntelLongLight.h"
#include "Scene/HitInfo.h"
#include "RenderGraph/RenderPassHelpers.h"
#include "RenderGraph/RenderPassStandardFlags.h"

extern "C" FALCOR_API_EXPORT void registerPlugin(Falcor::PluginRegistry& registry)
{
    registry.registerClass<RenderPass, IntelLongLight>();
}

namespace
{
const char kShaderFile[] = "RenderPasses/IntelLongLight/IntelLongLight.rt.slang";

// Compute Shader file for Light Deposit
const char kLightDepositShaderFile[] = "RenderPasses/IntelLongLight/LightDeposit.slang";
const char kMarkovChainShaderFile[] = "RenderPasses/IntelLongLight/MarkovChainProcess.cs.slang";
const char kAveragingShaderFile[] = "RenderPasses/IntelLongLight/Averaging.cs.slang";

// Ray tracing settings that affect the traversal stack size.
// These should be set as small as possible.
const uint32_t kMaxPayloadSizeBytes = 72u;
const uint32_t kMaxRecursionDepth = 2u;

const char kInputViewDir[] = "viewW";

const ChannelList kInputChannels = {
    // clang-format off
    { "vbuffer",        "gVBuffer",     "Visibility buffer in packed format" },
    { kInputViewDir,    "gViewW",       "World-space view direction (xyz float format)", true /* optional */ },
    // clang-format on
};

const ChannelList kOutputChannels = {
    // clang-format off
    { "color",          "gOutputColor", "Output color", false, ResourceFormat::RGBA32Float },
    // clang-format on
};

const char kMaxBounces[] = "maxBounces";
const char kComputeDirect[] = "computeDirect";
const char kUseImportanceSampling[] = "useImportanceSampling";
//MY
const char kPauseMarkovChainIterations[] = "PauseMarkovChainIterations";
const char kDisplayImportance[] = "DisplayImportance";
const char kHashTableScale[] = "HashTableScale";
const char kLightDepositSampleCount[] = "LightDepositSampleCount";
const char kMarkovChainsCount[] = "MarkovChainsCount";
const char kMarkovChainsIterationsCount[] = "MarkovChainsIterationsCount";
const char kAccumEMACoeff[] = "AccumEMACoeff";
} // namespace

IntelLongLight::IntelLongLight(ref<Device> pDevice, const Properties& props) : RenderPass(pDevice)
{
    parseProperties(props);

    // Create a sample generator.
    mpSampleGenerator = SampleGenerator::create(mpDevice, SAMPLE_GENERATOR_UNIFORM);

    FALCOR_ASSERT(mpSampleGenerator);

    // For Pixel Debug
    mpPixelDebug = std::make_unique<PixelDebug>(mpDevice);
    mpPixelDebug->enable();

    // Create a prefix sum pass
    mpPrefixSumPass = std::make_unique<PrefixSum>(mpDevice, true);
    mpImportancePrefixSumPass = std::make_unique<PrefixSum>(mpDevice, true);
}

void IntelLongLight::parseProperties(const Properties& props)
{
    for (const auto& [key, value] : props)
    {
        if (key == kMaxBounces) mMaxBounces = value;
        else if (key == kComputeDirect) mComputeDirect = value;
        else if (key == kUseImportanceSampling) mUseImportanceSampling = value;
        else if (key == kPauseMarkovChainIterations) mPauseMarkovChainIterations = value;
        else if (key == kDisplayImportance) mDisplayImportance = value;
        else if (key == kHashTableScale) mHashTableScale = value;
        else if (key == kLightDepositSampleCount) mLightDepositSampleCount = value;
        else if (key == kMarkovChainsCount) mMarkovChainsCount = value;
        else if (key == kMarkovChainsIterationsCount) mMarcovChainsIterationsCount = value;
        else if (key == kAccumEMACoeff) mAccumEMACoeff = value;
        else logWarning("Unknown property '{}' in IntelLongLight properties.", key);
    }
}

Properties IntelLongLight::getProperties() const
{
    Properties props;
    props[kMaxBounces] = mMaxBounces;
    props[kComputeDirect] = mComputeDirect;
    props[kUseImportanceSampling] = mUseImportanceSampling;
    props[kPauseMarkovChainIterations] = mPauseMarkovChainIterations;
    props[kDisplayImportance] = mDisplayImportance;
    props[kHashTableScale] = mHashTableScale;
    props[kLightDepositSampleCount] = mLightDepositSampleCount;
    props[kMarkovChainsCount] = mMarkovChainsCount;
    props[kMarkovChainsIterationsCount] = mMarcovChainsIterationsCount;
    props[kAccumEMACoeff] = mAccumEMACoeff;
    return props;
}

RenderPassReflection IntelLongLight::reflect(const CompileData& compileData)
{
    // Define the required resources here
    RenderPassReflection reflector;
    // reflector.addOutput("dst");
    // reflector.addInput("src");

    // Define our input/output channels.
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);

    return reflector;
}

void IntelLongLight::executeMarkovChainShader(RenderContext* pRenderContext, uint iteration)
{
    if (!mpMarkovChainPass) return;

    auto var = mpMarkovChainPass->getRootVar();
    // Main buffers
    var["hashGridUnshot"] = mpHashGridUnshotBuffer;
    var["hashFingerprints"] = mpHashGridFingerprintsBuffer;
    var["hashGridAccum"] = mpHashGridAccumBuffer;
    var["lockBuffer"] = mpHashGridLockBuffer;
    // Importance buffers
    var["hashGridUnshotImportance"] = mpHashGridUnshotImportanceBuffer;
    var["hashGridAccumImportance"] = mpHashGridAccumImportanceBuffer;
    // Explored cells
    var["hashGridExplored"] = mpHashGridExploredBuffer;
    // CDF
    var["hashGridCDF"] = mpHashGridCDFBuffer;
    var["hashGridCDFSum"] = mpHashGridCDFSumBuffer;
    // Importance CDF
    var["hashGridImportanceCDF"] = mpHashGridImportanceCDFBuffer;
    var["hashGridImportanceCDFSum"] = mpHashGridImportanceCDFSumBuffer;
    // Intersections
    var["hashGridIntersectPoints"] = mpHashGridIntersectPoints;
    var["hashGridIntersectPointsCount"] = mpHashGridIntersectPointCount;
    // Chains
    var["markovChainStates"] = mpMarkovChainStatesBuffer;
    // GAUSS TODO:
    // var["hashGridMeanBuffer"] = mpHashGridMeanBuffer;
    // var["hashGridVarBuffer"] = mpHashGridVarBuffer;
    // var["hashGridCountBuffer"] = mpHashGridCountBuffer;

    // Constants
    var["HashGridCB"]["gHashGridScale"] = mHashTableScale;
    var["HashGridCB"]["gMaxIntersectPointCount"] = mMaxIntersectPointCount;
    var["HashGridCB"]["gHashTableSize"] = mHashTableSize;
    var["PerFrameCB"]["gFrameCount"] = mFrameCount;
    var["PerFrameCB"]["gIterationCount"] = iteration;
    var["PerFrameCB"]["gMarkovChainsCount"] = mMarkovChainsCount;

    mpScene->bindShaderData(var["gScene"]);

    mpPixelDebug->prepareProgram(mpMarkovChainPass->getProgram(), var);

    mpMarkovChainPass->execute(pRenderContext, mMarkovChainsCount, 1, 1);
}

void IntelLongLight::executeLightDepositShader(RenderContext* pRenderContext)
{
    if (!mpLightDepositPass) return;

    auto var = mpLightDepositPass->getRootVar();
    var["hashGridUnshot"] = mpHashGridUnshotBuffer;
    var["hashFingerprints"] = mpHashGridFingerprintsBuffer;
    // GAUSS TODO:
    // var["hashGridMeanBuffer"] = mpHashGridMeanBuffer;
    // var["hashGridVarBuffer"] = mpHashGridVarBuffer;
    // var["hashGridCountBuffer"] = mpHashGridCountBuffer;

    // Explored cells
    var["hashGridExplored"] = mpHashGridExploredBuffer;
    // Intersections
    var["hashGridIntersectPoints"] = mpHashGridIntersectPoints;
    var["hashGridIntersectPointsCount"] = mpHashGridIntersectPointCount;

    var["lockBuffer"] = mpHashGridLockBuffer;
    var["HashGridCB"]["gHashGridScale"] = mHashTableScale;
    var["HashGridCB"]["gMaxIntersectPointCount"] = mMaxIntersectPointCount;
    var["PerFrameCB"]["gFrameCount"] = mFrameCount;
    var["PerFrameCB"]["gInstanceCount"] = mLightDepositSampleCount;
    var["HashGridCB"]["gHashTableSize"] = mHashTableSize;

    mpScene->bindShaderData(var["gScene"]);

    mpPixelDebug->prepareProgram(mpLightDepositPass->getProgram(), var);

    mpLightDepositPass->execute(pRenderContext, mLightDepositSampleCount, 1, 1);
}

void IntelLongLight::executeAveragingShader(RenderContext* pRenderContext)
{
    if (!mpAveragingPass) return;

    auto var = mpAveragingPass->getRootVar();
    // Light energy
    var["hashGridUnshot"] = mpHashGridUnshotBuffer;
    var["hashGridAccum"] = mpHashGridAccumBuffer;
    var["hashGridAccumAvg"] = mpHashGridAccumAverageBuffer;
    // Importance
    var["hashGridUnshotImportance"] = mpHashGridUnshotImportanceBuffer;
    var["hashGridAccumImportance"] = mpHashGridAccumImportanceBuffer;
    var["hashGridAccumAvgImportance"] = mpHashGridAccumAverageImportanceBuffer;

    var["CB"]["gHashTableSize"] = mHashTableSize;
    var["CB"]["gAccumEMACoeff"] = mAccumEMACoeff;

    mpAveragingPass->execute(pRenderContext, mHashTableSize, 1, 1);
}

void IntelLongLight::executeHashGridCDFShader(RenderContext* pRenderContext)
{
    // Energy
    pRenderContext->copyBufferRegion(mpHashGridCDFBuffer.get(), 0, mpHashGridUnshotBuffer.get(), 0, mHashTableSize * sizeof(float) * 3);
    mpPrefixSumPass->execute(pRenderContext, mpHashGridCDFBuffer, mHashTableSize * 3, nullptr, mpHashGridCDFSumBuffer);
    // Importance
    pRenderContext->copyBufferRegion(mpHashGridImportanceCDFBuffer.get(), 0, mpHashGridAccumAverageImportanceBuffer.get(), 0, mHashTableSize * sizeof(float));
    mpImportancePrefixSumPass->execute(pRenderContext, mpHashGridImportanceCDFBuffer, mHashTableSize, nullptr, mpHashGridImportanceCDFSumBuffer);
}


void IntelLongLight::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    // renderData holds the requested resources
    // auto& pTexture = renderData.getTexture("src");

    // Update refresh flag if options that affect the output have changed.
    auto& dict = renderData.getDictionary();
    if (mOptionsChanged)
    {
        auto flags = dict.getValue(kRenderPassRefreshFlags, RenderPassRefreshFlags::None);
        dict[Falcor::kRenderPassRefreshFlags] = flags | Falcor::RenderPassRefreshFlags::RenderOptionsChanged;
        mOptionsChanged = false;
    }
    if(mUpdateHash)
    {
        zeroOutHashBuffers(pRenderContext);
        mUpdateHash = false;
    }

    // If we have no scene, just clear the outputs and return.
    if (!mpScene)
    {
        for (auto it : kOutputChannels)
        {
            Texture* pDst = renderData.getTexture(it.name).get();
            if (pDst)
                pRenderContext->clearTexture(pDst);
        }
        return;
    }

    // Set resources.
    // Create buffer if doesnt exist yet
    if (!mpHashGridUnshotBuffer)
    {
        // mpHashGridUnshotBuffer = mpDevice->createBuffer(
        //     3 * sizeof(float) * mHashTableSize, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, nullptr
        // );
        mpHashGridUnshotBuffer = mpDevice->createStructuredBuffer(
            sizeof(float3), mHashTableSize, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, nullptr, false
        );
        mpHashGridAccumBuffer = mpDevice->createStructuredBuffer(
            sizeof(float3), mHashTableSize, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, nullptr, false
        );
        mpHashGridAccumAverageBuffer = mpDevice->createStructuredBuffer(
            sizeof(float3), mHashTableSize, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, nullptr, false
        );
        mpHashGridFingerprintsBuffer = mpDevice->createStructuredBuffer(
            sizeof(uint), mHashTableSize, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, nullptr, false
        );
        mpHashGridUnshotImportanceBuffer = mpDevice->createStructuredBuffer(
            sizeof(float), mHashTableSize, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, nullptr, false
        );
        mpHashGridAccumImportanceBuffer = mpDevice->createStructuredBuffer(
            sizeof(float), mHashTableSize, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, nullptr, false
        );
        mpHashGridAccumAverageImportanceBuffer = mpDevice->createStructuredBuffer(
            sizeof(float), mHashTableSize, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, nullptr, false
        );
        mpHashGridLockBuffer = mpDevice->createBuffer(
            sizeof(uint) * mHashTableSize, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, nullptr
        );
        // GAUSS TODO:
        // mpHashGridMeanBuffer = mpDevice->createStructuredBuffer(
        //     6 * sizeof(float), mHashTableSize, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, nullptr, false
        // );
        // mpHashGridVarBuffer = mpDevice->createStructuredBuffer(
        //     2 * sizeof(float), mHashTableSize, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, nullptr, false
        // );
        // mpHashGridCountBuffer = mpDevice->createStructuredBuffer(
        //     sizeof(uint), mHashTableSize, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, nullptr, false
        // );
        mpHashTotalAreaBuffer = mpDevice->createStructuredBuffer(
            sizeof(float), mHashTableSize, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, nullptr, false
        );
        mpHashCountBuffer = mpDevice->createStructuredBuffer(
            sizeof(uint), mHashTableSize, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, nullptr, false
        );
        mpHashAreaLockBuffer = mpDevice->createStructuredBuffer(
            sizeof(uint), mHashTableSize, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, nullptr, false
        );
    }

    if (!mpHashGridCDFBuffer)
    {
        mpHashGridImportanceCDFBuffer = mpDevice->createStructuredBuffer(
            sizeof(float), mHashTableSize, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, nullptr, false
        );
        mpHashGridImportanceCDFSumBuffer = mpDevice->createBuffer(
            sizeof(float), ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, nullptr
        );
        mpHashGridCDFBuffer = mpDevice->createStructuredBuffer(
            sizeof(float) * 3, mHashTableSize, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, nullptr, false
        );
        mpHashGridExploredBuffer = mpDevice->createStructuredBuffer(
            sizeof(float), mHashTableSize, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, nullptr, false
        );
        mpHashGridCDFSumBuffer = mpDevice->createBuffer(
            sizeof(float), ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, nullptr
        );

    }

    if(!mpMarkovChainStatesBuffer)
    {
        mpMarkovChainStatesBuffer = mpDevice->createStructuredBuffer(
            sizeof(MarkovChainState), mMarkovChainsCount, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, nullptr, false
        );
    }

    if(!mpHashGridIntersectPoints)
    {
        mpHashGridIntersectPoints = mpDevice->createStructuredBuffer(
            2 * sizeof(float3), mHashTableSize * mMaxIntersectPointCount, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, nullptr
        );
        mpHashGridIntersectPointCount = mpDevice->createStructuredBuffer(
            sizeof(uint32_t), 2 * mHashTableSize, ResourceBindFlags::ShaderResource | ResourceBindFlags::UnorderedAccess, MemoryType::DeviceLocal, nullptr
        );
    }

    // Taken from MinimalPathTracer
    if (is_set(mpScene->getUpdates(), IScene::UpdateFlags::RecompileNeeded) ||
        is_set(mpScene->getUpdates(), IScene::UpdateFlags::GeometryChanged))
    {
        FALCOR_THROW("This render pass does not support scene changes that require shader recompilation.");
    }

    // Request the light collection if emissive lights are enabled.
    if (mpScene->getRenderSettings().useEmissiveLights)
    {
        mpScene->getLightCollection(pRenderContext);
    }

    // Configure depth-of-field.
    const bool useDOF = mpScene->getCamera()->getApertureRadius() > 0.f;
    if (useDOF && renderData[kInputViewDir] == nullptr)
    {
        logWarning("Depth-of-field requires the '{}' input. Expect incorrect shading.", kInputViewDir);
    }

    // Specialize program.
    // These defines should not modify the program vars. Do not trigger program vars re-creation.
    mTracer.pProgram->addDefine("MAX_BOUNCES", std::to_string(mMaxBounces));
    mTracer.pProgram->addDefine("COMPUTE_DIRECT", mComputeDirect ? "1" : "0");
    mTracer.pProgram->addDefine("USE_IMPORTANCE_SAMPLING", mUseImportanceSampling ? "1" : "0");
    mTracer.pProgram->addDefine("USE_ANALYTIC_LIGHTS", mpScene->useAnalyticLights() ? "1" : "0");
    mTracer.pProgram->addDefine("USE_EMISSIVE_LIGHTS", mpScene->useEmissiveLights() ? "1" : "0");
    mTracer.pProgram->addDefine("USE_ENV_LIGHT", mpScene->useEnvLight() ? "1" : "0");
    mTracer.pProgram->addDefine("USE_ENV_BACKGROUND", mpScene->useEnvBackground() ? "1" : "0");
    // MY
    mTracer.pProgram->addDefine("DISPLAY_IMPORTANCE", mDisplayImportance ? "1" : "0");

    // For optional I/O resources, set 'is_valid_<name>' defines to inform the program of which ones it can access.
    mTracer.pProgram->addDefines(getValidResourceDefines(kInputChannels, renderData));
    mTracer.pProgram->addDefines(getValidResourceDefines(kOutputChannels, renderData));

    // Prepare program vars. This may trigger shader compilation.
    // The program should have all necessary defines set at this point.
    if (!mTracer.pVars)
        prepareVars();
    FALCOR_ASSERT(mTracer.pVars);

    // Set constants.
    auto var = mTracer.pVars->getRootVar();
    var["CB"]["gFrameCount"] = mFrameCount;
    var["CB"]["gPRNGDimension"] = dict.keyExists(kRenderPassPRNGDimension) ? dict[kRenderPassPRNGDimension] : 0u;
    // TODO: add slider ImGUI
    var["HashGridCB"]["gHashGridScale"] = mHashTableScale;
    var["HashGridCB"]["gMaxIntersectPointCount"] = mMaxIntersectPointCount;
    var["HashGridCB"]["gHashTableSize"] = mHashTableSize;

    // Bind  buffers
    // var["hashGridUnshotStr"] = mpHashGridUnshotBuffer;
    var["hashFingerprints"] = mpHashGridFingerprintsBuffer;
    var["hashGridAccumAvg"] = mpHashGridAccumAverageBuffer;
    // Importance
    var["hashGridUnshotImportance"] = mpHashGridUnshotImportanceBuffer;
    var["hashGridAccumImportance"] = mpHashGridAccumImportanceBuffer;
    var["hashGridAccumAvgImportance"] = mpHashGridAccumAverageImportanceBuffer;

    // Area Calculations
    var["hashTotalAreaBuffer"] = mpHashTotalAreaBuffer;
    var["hashCountBuffer"] = mpHashCountBuffer;
    var["hashAreaLockBuffer"] = mpHashAreaLockBuffer;
    // GAUSS TODO:
    // var["hashGridMeanBuffer"] = mpHashGridMeanBuffer;
    // var["hashGridVarBuffer"] = mpHashGridVarBuffer;
    // var["hashGridCountBuffer"] = mpHashGridCountBuffer;

    // Intersections
    var["hashGridIntersectPoints"] = mpHashGridIntersectPoints;
    var["hashGridIntersectPointsCount"] = mpHashGridIntersectPointCount;

    // Bind I/O buffers. These needs to be done per-frame as the buffers may change anytime.
    auto bind = [&](const ChannelDesc& desc)
    {
        if (!desc.texname.empty())
        {
            var[desc.texname] = renderData.getTexture(desc.name);
        }
    };
    for (auto channel : kInputChannels)
        bind(channel);
    for (auto channel : kOutputChannels)
        bind(channel);

    // Get dimensions of ray dispatch.
    const uint2 targetDim = renderData.getDefaultTextureDims();
    FALCOR_ASSERT(targetDim.x > 0 && targetDim.y > 0);

    // For Pixel Debug
    mpPixelDebug->beginFrame(pRenderContext, targetDim);
    mpPixelDebug->prepareProgram(mTracer.pProgram, var);

    if (!mPauseMarkovChainIterations)
        for (uint i = 0; i < mMarcovChainsIterationsCount; i++)
        {
            // Deposit Flux from the light sources Pass
            executeLightDepositShader(pRenderContext);
            // Collect a CDF over all explored patches
            executeHashGridCDFShader(pRenderContext);
            // Do a markov chain iteration
            executeMarkovChainShader(pRenderContext, i);
            // Average out the accumulated radiance
            executeAveragingShader(pRenderContext);
            // Clear Accumulated buffer of this iteration
            pRenderContext->clearUAV(mpHashGridAccumBuffer->getUAV().get(), uint4(0));
        }

    // Spawn the rays.
    mpScene->raytrace(pRenderContext, mTracer.pProgram.get(), mTracer.pVars, uint3(targetDim, 1));

    // For Pixel Debug
    mpPixelDebug->endFrame(pRenderContext);

    // Reset unshot
    // pRenderContext->clearUAV(mpHashGridUnshotBuffer->getUAV().get(), uint4(0));
    // pRenderContext->clearUAV(mpHashGridUnshotImportanceBuffer->getUAV().get(), uint4(0));
    // pRenderContext->clearUAV(mpHashGridExploredBuffer->getUAV().get(), uint4(0));

    // Clear MCstates for now
    // pRenderContext->clearUAV(mpMarkovChainStatesBuffer->getUAV().get(), uint4(0));

    mFrameCount++;
}

void IntelLongLight::renderUI(Gui::Widgets& widget)
{
    bool dirty = false;

    // dirty |= widget.var("Max bounces", mMaxBounces, 0u, 16u);
    // widget.tooltip("Maximum path length for indirect illumination.\n0 = direct only\n1 = one indirect bounce etc.", true);

    // dirty |= widget.checkbox("Evaluate direct illumination", mComputeDirect);
    // dirty |= widget.checkbox("Use importance sampling", mUseImportanceSampling);

    // Configurable parameters
    dirty |= widget.checkbox("Pause", mPauseMarkovChainIterations);
    if (widget.var("Hash Table Scale", mHashTableScale, 0.001f, 1.0f, 0.001f)) {
        mUpdateHash = true;
        dirty = true;
    }
    if (widget.var("Light Deposit Sample Count", mLightDepositSampleCount, 10000u, 1000000u)) {
        dirty = true;
    }
    if (widget.var("Markov Chains Count", mMarkovChainsCount, 10000u, 1000000u)) {
        dirty = true;
    }
    if (widget.var("Markov Chains Iterations", mMarcovChainsIterationsCount, 1u, 100u)) {
        dirty = true;
    }
    if (widget.var("Accumulation EMA Coefficient", mAccumEMACoeff, 0.0001f, 1.0f, 0.0001f)) {
        dirty = true;
    }
    dirty |= widget.checkbox("Display Importance", mDisplayImportance);

    // For Pixel Debug
    if (Gui::Group debug_group = widget.group("Debug"))
    {
        ImGui::Separator();
        mpPixelDebug->renderUI(debug_group);
    }

    if (dirty) {
        mOptionsChanged = true;
    }
}

void IntelLongLight::zeroOutHashBuffers(RenderContext* pRenderContext)
{
    if (!mpDevice) return;

    auto clearBuffer = [&](ref<Buffer>& buffer) {
        if (buffer) {
            pRenderContext->clearUAV(buffer->getUAV().get(), uint4(0));
        }
    };

    clearBuffer(mpHashGridUnshotBuffer);
    clearBuffer(mpHashGridAccumBuffer);
    clearBuffer(mpHashGridAccumAverageBuffer);
    clearBuffer(mpHashGridFingerprintsBuffer);
    clearBuffer(mpHashGridLockBuffer);
    clearBuffer(mpHashGridExploredBuffer);
    clearBuffer(mpHashGridCDFBuffer);
    clearBuffer(mpHashGridCDFSumBuffer);
    clearBuffer(mpHashGridIntersectPoints);
    clearBuffer(mpHashGridIntersectPointCount);
    clearBuffer(mpHashTotalAreaBuffer);
    clearBuffer(mpHashCountBuffer);
    clearBuffer(mpHashAreaLockBuffer);
}

void IntelLongLight::setScene(RenderContext* pRenderContext, const ref<Scene>& pScene)
{
    // Clear data for previous scene.
    // After changing scene, the raytracing program should to be recreated.
    mTracer.pProgram = nullptr;
    mTracer.pBindingTable = nullptr;
    mTracer.pVars = nullptr;
    mFrameCount = 0;

    // Set new scene.
    mpScene = pScene;

    if (mpScene)
    {
        if (pScene->hasGeometryType(Scene::GeometryType::Custom))
        {
            logWarning("IntelLongLight: This render pass does not support custom primitives.");
        }

        // Create ray tracing program.
        ProgramDesc desc;
        desc.addShaderModules(mpScene->getShaderModules());
        desc.addShaderLibrary(kShaderFile);
        desc.setMaxPayloadSize(kMaxPayloadSizeBytes);
        desc.setMaxAttributeSize(mpScene->getRaytracingMaxAttributeSize());
        desc.setMaxTraceRecursionDepth(kMaxRecursionDepth);

        mTracer.pBindingTable = RtBindingTable::create(2, 2, mpScene->getGeometryCount());
        auto& sbt = mTracer.pBindingTable;
        sbt->setRayGen(desc.addRayGen("rayGen"));
        sbt->setMiss(0, desc.addMiss("scatterMiss"));
        sbt->setMiss(1, desc.addMiss("shadowMiss"));

        if (mpScene->hasGeometryType(Scene::GeometryType::TriangleMesh))
        {
            sbt->setHitGroup(
                0,
                mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh),
                desc.addHitGroup("scatterTriangleMeshClosestHit", "scatterTriangleMeshAnyHit")
            );
            sbt->setHitGroup(
                1, mpScene->getGeometryIDs(Scene::GeometryType::TriangleMesh), desc.addHitGroup("", "shadowTriangleMeshAnyHit")
            );
        }

        if (mpScene->hasGeometryType(Scene::GeometryType::DisplacedTriangleMesh))
        {
            sbt->setHitGroup(
                0,
                mpScene->getGeometryIDs(Scene::GeometryType::DisplacedTriangleMesh),
                desc.addHitGroup("scatterDisplacedTriangleMeshClosestHit", "", "displacedTriangleMeshIntersection")
            );
            sbt->setHitGroup(
                1,
                mpScene->getGeometryIDs(Scene::GeometryType::DisplacedTriangleMesh),
                desc.addHitGroup("", "", "displacedTriangleMeshIntersection")
            );
        }

        if (mpScene->hasGeometryType(Scene::GeometryType::Curve))
        {
            sbt->setHitGroup(
                0, mpScene->getGeometryIDs(Scene::GeometryType::Curve), desc.addHitGroup("scatterCurveClosestHit", "", "curveIntersection")
            );
            sbt->setHitGroup(1, mpScene->getGeometryIDs(Scene::GeometryType::Curve), desc.addHitGroup("", "", "curveIntersection"));
        }

        if (mpScene->hasGeometryType(Scene::GeometryType::SDFGrid))
        {
            sbt->setHitGroup(
                0,
                mpScene->getGeometryIDs(Scene::GeometryType::SDFGrid),
                desc.addHitGroup("scatterSdfGridClosestHit", "", "sdfGridIntersection")
            );
            sbt->setHitGroup(1, mpScene->getGeometryIDs(Scene::GeometryType::SDFGrid), desc.addHitGroup("", "", "sdfGridIntersection"));
        }

        mTracer.pProgram = Program::create(mpDevice, desc, mpScene->getSceneDefines());

        // create Compute Pass file for Light Deposit
        DefineList defineList = {};
        defineList.add(mpScene->getSceneDefines());
        defineList.add(mpSampleGenerator->getDefines());
        mpLightDepositPass = ComputePass::create(mpDevice, kLightDepositShaderFile, "main", defineList);

        // create Compute Pass file for Markov Chains
        DefineList MarkovChainDefineList = {};
        MarkovChainDefineList.add(mpScene->getSceneDefines());
        MarkovChainDefineList.add(mpSampleGenerator->getDefines());

        ProgramDesc MarkovChainDesc;
        MarkovChainDesc.addShaderModules(mpScene->getShaderModules());
        MarkovChainDesc.addShaderLibrary(kMarkovChainShaderFile).csEntry("main");
        MarkovChainDesc.addTypeConformances(mpScene->getTypeConformances());

        mpMarkovChainPass = ComputePass::create(mpDevice, MarkovChainDesc, MarkovChainDefineList);

        // create Compute Pass file for Averaging
        mpAveragingPass = ComputePass::create(mpDevice, kAveragingShaderFile, "main");
    }
}

void IntelLongLight::prepareVars()
{
    FALCOR_ASSERT(mpScene);
    FALCOR_ASSERT(mTracer.pProgram);

    // Configure program.
    mTracer.pProgram->addDefines(mpSampleGenerator->getDefines());
    mTracer.pProgram->setTypeConformances(mpScene->getTypeConformances());

    // Create program variables for the current program.
    // This may trigger shader compilation. If it fails, throw an exception to abort rendering.
    mTracer.pVars = RtProgramVars::create(mpDevice, mTracer.pProgram, mTracer.pBindingTable);

    // Bind utility classes into shared data.
    auto var = mTracer.pVars->getRootVar();
    mpSampleGenerator->bindShaderData(var);
}
