// OptiShade TAA guide adapter. Motion estimation: Jak0bW / Marty McFly / Vortigern,
// CC BY-NC 4.0; helper files have their own notices (see Includes and Licenses).
// No extra TAA or motion blur is applied: MSFS keeps its own TAA.
#define V_MV_MODE 1
#define V_MV_DEBUG 0
#define V_ENABLE_MOT_BLUR 0
#define V_ENABLE_TAA 0
#include "Includes/vort_MotionVectors.fxh"

texture2D OptiShadeTaaDepth { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = R32F; };
float PS_OptiShadeDepth(float4 position : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float depth = GetRawDepth(uv) * RESHADE_DEPTH_MULTIPLIER;
#if RESHADE_DEPTH_INPUT_IS_LOGARITHMIC
    depth = (exp(depth * log(1.01)) - 1.0) / 0.01;
#endif
#if RESHADE_DEPTH_INPUT_IS_REVERSED
    depth = 1.0 - depth;
#endif
    return saturate(depth);
}
technique OptiShade_TAA_Guides < ui_label = "TAA neural guides (experimental)"; ui_tooltip = "Enable TAA neural rendering in Performance. Put these guides before your look effects. Estimates motion; does not add blur or replace the game's TAA. Requires valid scene depth and SDR."; >
{
    PASS_MV
    pass { VertexShader = PostProcessVS; PixelShader = PS_OptiShadeDepth; RenderTarget = OptiShadeTaaDepth; }
}
