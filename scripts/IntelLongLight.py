from falcor import *

def render_graph_IntelLongLight():
    g = RenderGraph("IntelLongLight")
    # AccumulatePass = createPass("AccumulatePass", {'enabled': True, 'precisionMode': 'Single'})
    # g.addPass(AccumulatePass, "AccumulatePass")
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
    return g

IntelLongLight = render_graph_IntelLongLight()
try: m.addGraph(IntelLongLight)
except NameError: None
