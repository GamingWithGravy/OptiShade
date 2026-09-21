
uniform float Strength < ui_type="slider"; ui_label="Overall strength"; ui_min=0.0; ui_max=1.0; > = 1.0;
uniform float ShadowFill < ui_type="slider"; ui_label="Light in shaded areas"; ui_tooltip="Lift dark surfaces while keeping black black."; ui_min=0.0; ui_max=0.35; > = 0.12;
uniform float HighlightSoftness < ui_type="slider"; ui_label="Soften bright paint and sky"; ui_min=0.0; ui_max=0.6; > = 0.20;
uniform float Contrast < ui_type="slider"; ui_label="Gentle contrast"; ui_min=0.0; ui_max=0.3; > = 0.04;
uniform float Warmth < ui_type="slider"; ui_label="Warm light"; ui_tooltip="A small warm tint in brighter areas."; ui_min=-0.1; ui_max=0.1; > = 0.012;
uniform float YellowToPeach < ui_type="slider"; ui_label="Yellow light towards peach"; ui_tooltip="Affects yellow colours, including paint and markings. Keep modest."; ui_min=0.0; ui_max=0.6; > = 0.16;
uniform float Colour < ui_type="slider"; ui_label="Colour richness"; ui_min=0.75; ui_max=1.25; > = 1.02;
uniform float Tint < ui_type="slider"; ui_label="Green / magenta balance"; ui_tooltip="Zero is neutral. Positive adds magenta."; ui_min=-0.05; ui_max=0.05; > = 0.0;

texture Scene : COLOR;
sampler SceneSampler { Texture=Scene; };

void CinemaVS(uint id : SV_VertexID, out float4 position : SV_Position, out float2 uv : TEXCOORD)
{
    uv=float2((id==2)?2.0:0.0,(id==1)?2.0:0.0);
    position=float4(uv*float2(2.0,-2.0)+float2(-1.0,1.0),0.0,1.0);
}

float4 CinemaPS(float4 position : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float4 source=tex2D(SceneSampler,uv);
    float3 c=max(source.rgb,0.0);
    const float3 luma=float3(0.2126,0.7152,0.0722);
    float y=dot(c,luma);
    // Zero lift at black; smoothly diminish lift approaching bright midtones.
    float fill=ShadowFill*4.0*y*(1.0-saturate(y))*(1.0-smoothstep(0.12,0.55,y));
    float shoulder=HighlightSoftness*smoothstep(0.50,1.0,y)*max(y-0.50,0.0);
    float target=max(y+fill-shoulder,0.0);
    target=lerp(target,target*target*(3.0-2.0*target),Contrast);
    c*=target/max(y,0.0001);
    float high=max(c.r,max(c.g,c.b));
    float low=min(c.r,min(c.g,c.b));
    float chroma=high-low;
    // Select yellow, excluding green-dominant foliage and neutral whites.
    float yellow=smoothstep(0.025,0.20,min(c.r,c.g)-c.b);
    yellow*=smoothstep(0.90,1.03,c.r/max(c.g,0.001));
    float peach=YellowToPeach*yellow*chroma;
    c+=float3(0.12,-0.16,0.30)*peach;
    float light=smoothstep(0.20,0.85,target)*target*(1.0-saturate(target));
    c+=Warmth*light*float3(1.0,0.15,-0.60);
    c+=Tint*target*(1.0-saturate(target))*float3(0.5,-0.5,0.5);
    float cy=dot(c,luma);
    c=lerp(float3(cy,cy,cy),c,Colour);
    return float4(lerp(source.rgb,saturate(c),Strength),source.a);
}

technique Gravy_FusionCinema < ui_label="Fusion Cinema"; ui_tooltip="SDR colour and light finishing. Created for gravy."; >
{
    pass { VertexShader=CinemaVS; PixelShader=CinemaPS; }
}
