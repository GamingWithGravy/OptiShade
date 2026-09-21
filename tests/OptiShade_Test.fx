uniform float Gain < ui_label = "Brightness"; ui_min = 0.0; ui_max = 4.0; > = 2.0;
texture BackBuffer : COLOR;
sampler BackBufferSampler { Texture = BackBuffer; };
void VS(uint id : SV_VertexID, out float4 position : SV_Position, out float2 uv : TEXCOORD) {
 uv = float2((id << 1) & 2, id & 2); position = float4(uv * float2(2,-2) + float2(-1,1), 0, 1);
}
float4 PS(float4 position : SV_Position, float2 uv : TEXCOORD) : SV_Target {return tex2D(BackBufferSampler,uv)*float4(Gain,Gain,Gain,1);}
technique OptiShade_Test { pass { VertexShader = VS; PixelShader = PS; } }

