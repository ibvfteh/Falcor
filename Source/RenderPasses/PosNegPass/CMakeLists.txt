add_plugin(PosNegPass)

target_sources(PosNegPass PRIVATE
    PosNegPass.cpp
    PosNegPass.h
)

target_source_group(PosNegPass "RenderPasses")
