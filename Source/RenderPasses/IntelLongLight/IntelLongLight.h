#pragma once
#include "Falcor.h"
#include "RenderGraph/RenderPass.h"
#include "Utils/Algorithm/PrefixSum.h"
// For Pixel Debug
#include "Utils/Debug/PixelDebug.h"

using namespace Falcor;

struct MarkovChainState
{
    float3 point1;
    float3 normal1;
    float3 point2;
    float3 normal2;
    uint init;
};

class IntelLongLight : public RenderPass
{
public:
    FALCOR_PLUGIN_CLASS(IntelLongLight, "IntelLongLight", "Insert pass description here.");

    static ref<IntelLongLight> create(ref<Device> pDevice, const Properties& props)
    {
        return make_ref<IntelLongLight>(pDevice, props);
    }

    IntelLongLight(ref<Device> pDevice, const Properties& props);

    virtual Properties getProperties() const override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void compile(RenderContext* pRenderContext, const CompileData& compileData) override {}
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void setScene(RenderContext* pRenderContext, const ref<Scene>& pScene) override;
    // For Pixel Debug
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override { return mpPixelDebug->onMouseEvent(mouseEvent); }
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }

private:
    void parseProperties(const Properties& props);
    void prepareVars();
    void zeroOutHashBuffers(RenderContext* pRenderContext);
    void executeLightDepositShader(RenderContext* pRenderContext);
    void executeHashGridCDFShader(RenderContext* pRenderContext);
    void executeMarkovChainShader(RenderContext* pRenderContext, uint iteration);
    void executeAveragingShader(RenderContext* pRenderContext);

    // Internal state

    /// Current scene.
    ref<Scene> mpScene;
    /// GPU sample generator.
    ref<SampleGenerator> mpSampleGenerator;

    // For Pixel Debug
    std::unique_ptr<PixelDebug> mpPixelDebug;

    // Configuration

    /// Max number of indirect bounces (0 = none).
    uint mMaxBounces = 0;
    /// Compute direct illumination (otherwise indirect only).
    bool mComputeDirect = true;
    /// Use importance sampling for materials.
    bool mUseImportanceSampling = true;


    bool mUpdateHash = false;
    uint mHashTableSize = 10000000;
    float mHashTableScale = 0.05f;
    /// Buffer for hash grid.
    // TODO: change to two buffers
    ref<Buffer> mpHashGridUnshotBuffer;    // mpHashGridUnshotBuffer;
    ref<Buffer> mpHashGridAccumBuffer; // Buffer for accumulated radiosity
    ref<Buffer> mpHashGridAccumAverageBuffer; // Result Buffer with averaging over frames

    ref<Buffer> mpHashGridFingerprintsBuffer;
    ref<Buffer> mpHashGridLockBuffer;
    /// Buffer for building CDF of a hash grid.
    ref<Buffer> mpHashGridExploredBuffer;
    ref<Buffer> mpHashGridCDFBuffer;
    ref<Buffer> mpHashGridCDFSumBuffer;
    // Buffer that has number of known intersetcion points for every cache cell
    uint mMaxIntersectPointCount = 10;
    ref<Buffer> mpHashGridIntersectPoints;
    ref<Buffer> mpHashGridIntersectPointCount;

    ref<Buffer> mpMarkovChainStatesBuffer;

    // Area calculations
    ref<Buffer> mpHashTotalAreaBuffer;
    ref<Buffer> mpHashCountBuffer;
    ref<Buffer> mpHashAreaLockBuffer;

    // GAUSS TODO:
    // ref<Buffer> mpHashGridMeanBuffer;
    // ref<Buffer> mpHashGridVarBuffer;
    // ref<Buffer> mpHashGridCountBuffer;

    // Runtime data

    /// Frame count since scene was loaded.
    uint mFrameCount = 0;
    bool mOptionsChanged = false;

    // Ray tracing program.
    struct
    {
        ref<Program> pProgram;
        ref<RtBindingTable> pBindingTable;
        ref<RtProgramVars> pVars;
    } mTracer;

    // Light Deposit Compute Pass
    uint mLightDepositSampleCount = 100000; //256 * 400;
    ref<ComputePass> mpLightDepositPass;

    // Compute passes used to build the CDF of hash grid to select samples.
    std::unique_ptr<PrefixSum> mpPrefixSumPass;

    // Marcov Chain Monte CarloPass
    uint mMarkovChainsCount = 400000;
    uint mMarcovChainsIterationsCount = 1;
    ref<ComputePass> mpMarkovChainPass;

    // Hash grid averaging Pass
    float mAccumEMACoeff = 0.001f;
    ref<ComputePass> mpAveragingPass;
};
