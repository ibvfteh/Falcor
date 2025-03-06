from falcor import *

def render_graph_IntelLongLight():
    g = RenderGraph("IntelLongLight")
    AccumulatePass = createPass("AccumulatePass", {'enabled': False, 'precisionMode': 'Single'})
    g.addPass(AccumulatePass, "AccumulatePass")
    # ToneMapper = createPass("ToneMapper", {'autoExposure': False, 'exposureCompensation': 0.0})
    # g.addPass(ToneMapper, "ToneMapper")
    IntelLongLight = createPass("IntelLongLight", {'maxBounces': 3})
    g.addPass(IntelLongLight, "IntelLongLight")
    VBufferRT = createPass("VBufferRT", {'samplePattern': 'Stratified', 'sampleCount': 16})
    g.addPass(VBufferRT, "VBufferRT")
    g.addEdge("VBufferRT.vbuffer", "IntelLongLight.vbuffer")
    g.addEdge("VBufferRT.viewW", "IntelLongLight.viewW")

    ## Add accumulation
    if False:
        # g.addEdge("IntelLongLight.color", "ToneMapper.src")
        # g.markOutput("ToneMapper.dst")
        g.markOutput("IntelLongLight.color")
    else:
        g.addEdge("IntelLongLight.color", "AccumulatePass.input")
        # g.addEdge("AccumulatePass.output", "ToneMapper.src")
        # g.markOutput("ToneMapper.dst")
        g.markOutput("AccumulatePass.output")


    ## GT
    AccumulatePass = createPass("AccumulatePass", {'enabled': True, 'precisionMode': 'Single'})
    g.addPass(AccumulatePass, "AccumulatePassGT")
    # ToneMapper = createPass("ToneMapper", {'autoExposure': False, 'exposureCompensation': 0.0})
    # g.addPass(ToneMapper, "ToneMapper")
    MinimalPathTracer = createPass("MinimalPathTracer", {'maxBounces': 6})
    g.addPass(MinimalPathTracer, "MinimalPathTracer")
    # g.addEdge("AccumulatePass.output", "ToneMapper.src")
    g.addEdge("VBufferRT.vbuffer", "MinimalPathTracer.vbuffer")
    g.addEdge("VBufferRT.viewW", "MinimalPathTracer.viewW")
    g.addEdge("MinimalPathTracer.color", "AccumulatePassGT.input")
    g.markOutput("AccumulatePassGT.output")


    # gt_path = "C:\\Users\\Dmitrii\\Documents\\intel-llp\\renders\\GT.ToneMapper.dst.22802.png"
    # gt_path = "C:\\Users\\Dmitrii\\Documents\\intel-llp\\renders\\GT_direct.ToneMapper.dst.30854.png"
    # gt_path = "C:\\Users\\Dmitrii\\Documents\\intel-llp\\renders\\Mogwai.AccumulatePass.output.10581.exr"


    # ImageLoader = createPass("ImageLoader", {'filename': gt_path, 'mips': False, 'srgb': True})
    Flip = createPass("FLIPPass")
    ErrorMeasure = createPass("ErrorMeasurePass", {"ComputeSquaredDifference": False, "SelectedOutputId" : "Difference"})
    PosNeg = createPass("PosNegPass")

    # g.addPass(ImageLoader, "ImageLoader")
    g.addPass(Flip, "FLIP")
    g.addPass(ErrorMeasure, "ErrorMeasure")
    g.addPass(PosNeg, "PosNeg")

    g.addEdge("AccumulatePassGT.output", "FLIP.referenceImage")
    g.addEdge("AccumulatePass.output", "FLIP.testImage")
    g.addEdge("AccumulatePassGT.output", "ErrorMeasure.Reference")
    g.addEdge("AccumulatePass.output", "ErrorMeasure.Source")
    g.addEdge("AccumulatePassGT.output", "PosNeg.referenceImage")
    g.addEdge("AccumulatePass.output", "PosNeg.testImage")

    g.markOutput("FLIP.errorMapDisplay")
    g.markOutput("ErrorMeasure.Output")
    g.markOutput("PosNeg.outputDisplayImage")

    return g

IntelLongLight = render_graph_IntelLongLight()
try: m.addGraph(IntelLongLight)
except NameError: None
