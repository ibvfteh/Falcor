from falcor import *

def render_graph_IntelLongLight():
    g = RenderGraph("IntelLongLight")
    AccumulatePass = createPass("AccumulatePass", {'enabled': False, 'precisionMode': 'Single'})
    g.addPass(AccumulatePass, "AccumulatePass")
    ToneMapper = createPass("ToneMapper", {'autoExposure': False, 'exposureCompensation': 0.0})
    g.addPass(ToneMapper, "ToneMapper")
    IntelLongLight = createPass("IntelLongLight", {'maxBounces': 3})
    g.addPass(IntelLongLight, "IntelLongLight")
    VBufferRT = createPass("VBufferRT", {'samplePattern': 'Stratified', 'sampleCount': 16})
    g.addPass(VBufferRT, "VBufferRT")
    # g.addEdge("AccumulatePass.output", "ToneMapper.src")
    g.addEdge("VBufferRT.vbuffer", "IntelLongLight.vbuffer")
    g.addEdge("VBufferRT.viewW", "IntelLongLight.viewW")
    # g.addEdge("IntelLongLight.color", "AccumulatePass.input")
    g.addEdge("IntelLongLight.color", "ToneMapper.src")
    g.markOutput("ToneMapper.dst")

    gt_path = "C:\\Users\\Dmitrii\\Documents\\intel-llp\\renders\\GT.ToneMapper.dst.22802.png"

    ImageLoader = createPass("ImageLoader", {'filename': gt_path, 'mips': False, 'srgb': True})
    Flip = createPass("FLIPPass")
    ErrorMeasure = createPass("ErrorMeasurePass", {"ComputeSquaredDifference": False, "SelectedOutputId" : "Difference"})

    g.addPass(ImageLoader, "ImageLoader")
    g.addPass(Flip, "FLIP")
    g.addPass(ErrorMeasure, "ErrorMeasure")
    g.addEdge("ImageLoader.dst", "FLIP.referenceImage")
    g.addEdge("ToneMapper.dst", "FLIP.testImage")
    g.addEdge("ImageLoader.dst", "ErrorMeasure.Reference")
    g.addEdge("ToneMapper.dst", "ErrorMeasure.Source")

    g.markOutput("FLIP.errorMapDisplay")
    g.markOutput("ErrorMeasure.Output")
    return g

IntelLongLight = render_graph_IntelLongLight()
try: m.addGraph(IntelLongLight)
except NameError: None
