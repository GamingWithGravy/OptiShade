// Original OptiShade core guide provider v1, GPL-3.0-or-later.
// Block matching estimates backward image motion. This is not game motion.
// No external effect, include, noise texture or vendor kernel is used.
struct FrameData { uint width, height, warm, reversed; uint logarithmic; float depthMultiplier; uint pad0, pad1; };
#ifdef SPIRV
#define BIND(n,s) [[vk::binding(n,s)]]
#define FORMAT(f) [[vk::image_format(f)]]
[[vk::push_constant]]
#else
#define BIND(n,s)
#define FORMAT(f)
#endif
ConstantBuffer<FrameData> frame : register(b0);
#define width frame.width
#define height frame.height
#define warm frame.warm
#define reversed frame.reversed
#define logarithmic frame.logarithmic
#define depthMultiplier frame.depthMultiplier
BIND(0,0) Texture2D<float4> picture : register(t0);
BIND(1,0) Texture2D<float> sceneDepth : register(t1);
BIND(2,0) Texture2D<float4> previous : register(t2);
BIND(3,0) Texture2D<float4> current : register(t3);
BIND(4,0) Texture2D<float2> coarseMotion : register(t4);
BIND(5,0) FORMAT("rgba16f") RWTexture2D<float4> next : register(u0);
BIND(6,0) FORMAT("rg16f") RWTexture2D<float2> estimated : register(u1);
BIND(7,0) FORMAT("r32f") RWTexture2D<float> depthOut : register(u2);
BIND(8,0) FORMAT("rg16f") RWTexture2D<float2> motionOut : register(u3);
int2 lowSize() { return int2((width+3)/4,(height+3)/4); }
float luminance(float3 c) { return dot(c,float3(0.2126,0.7152,0.0722)); }
[numthreads(8,8,1)] void Prepare(uint3 id:SV_DispatchThreadID) {
 if(any(id.xy >= (uint2)lowSize())) return;
 float mean=0, square=0;
 [unroll] for(uint y=0;y<4;y++) [unroll] for(uint x=0;x<4;x++) {
  int2 p=min(id.xy*4+uint2(x,y),uint2(width-1,height-1));
  float l=luminance(picture.Load(int3(p,0)).rgb);mean+=l;square+=l*l;
 }
 next[id.xy]=float4(mean/16,square/16,0,1);
}
[numthreads(8,8,1)] void Estimate(uint3 id:SV_DispatchThreadID) {
 int2 size=lowSize(), p=id.xy;if(any(p>=size))return;
 // First frame has no temporal observation: caller must not submit it to NR.
 if(!warm){estimated[p]=0;return;}
 float best=1e10,zeroCost=0;int2 offset=0;
 [loop] for(int dy=-3;dy<=3;dy++) [loop] for(int dx=-3;dx<=3;dx++) {
  float cost=0;
  [unroll] for(int y=-1;y<=1;y++) [unroll] for(int x=-1;x<=1;x++) {
   int2 a=clamp(p+int2(x,y),0,size-1),b=clamp(p+int2(x+dx,y+dy),0,size-1);
   float2 ca=current.Load(int3(a,0)).xy, cb=previous.Load(int3(b,0)).xy;
   cost+=abs(ca.x-cb.x)+0.25*abs(ca.y-cb.y);
  }
  if(dx==0&&dy==0)zeroCost=cost;
  // Deterministic zero-motion preference in flat/ambiguous regions.
  cost+=0.0001*(dx*dx+dy*dy);
  if(cost<best){best=cost;offset=int2(dx,dy);}
 }
 // Avoid jumping to a weak block match (noise, disocclusion or interpolated frames).
 // Keep clearly better matches; this is an attempted visual-stability repair,
 // not a claim that estimated vectors equal the game's motion vectors.
 if(best>0.45||zeroCost-best<max(0.001,zeroCost*0.05))offset=0;
 estimated[p]=float2(offset)*4/float2(width,height);
}
[numthreads(8,8,1)] void Resolve(uint3 id:SV_DispatchThreadID) {
 if(id.x>=width||id.y>=height)return;
 float d=sceneDepth.Load(int3(id.xy,0))*depthMultiplier;
 if(logarithmic)d=(exp(d*log(1.01))-1)/0.01;
 if(reversed)d=1-d;
 depthOut[id.xy]=saturate(d);
 motionOut[id.xy]=coarseMotion.Load(int3(min(id.xy/4,(uint2)lowSize()-1),0));
}

