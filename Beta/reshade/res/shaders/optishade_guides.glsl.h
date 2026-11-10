// Original OptiShade core guide GLSL variants, GPL-3.0-or-later.
// Source-SHA256: 39ECD707B4557142BAEC35F980FE1F676D79DD9992B95420C8BF25ED0A8B1E20
// Generator-SHA256: 4196E1FBD9069626622855F0817DF81923F956BC5A1DD899312CF65655222676
#pragma once
namespace osguide::shaders {
inline constexpr char Prepare_glsl[] = R"OSGL(#version 430 core
// Same original OptiShade kernels and 32-byte constant contract as HLSL.
layout(local_size_x=8, local_size_y=8, local_size_z=1) in;
layout(std140, binding=0) uniform FrameConstants {
 uint width, height, warm, reversed;
 uint logarithmic; float depthMultiplier; uint depthWidth, depthHeight;
};
layout(binding=0) uniform sampler2D picture;
layout(binding=1) uniform sampler2D sceneDepth;
layout(binding=2) uniform sampler2D previous;
layout(binding=3) uniform sampler2D current;
layout(binding=4) uniform sampler2D coarseMotion;
layout(rgba16f, binding=0) writeonly uniform image2D next;
layout(rg16f, binding=1) writeonly uniform image2D estimated;
layout(r32f, binding=2) writeonly uniform image2D depthOut;
layout(rg16f, binding=3) writeonly uniform image2D motionOut;
ivec2 lowSize() { return ivec2((width+3)/4,(height+3)/4); }
float luminance(vec3 c) { return dot(c,vec3(0.2126,0.7152,0.0722)); }
void Prepare(uvec3 id) {
 if(any(greaterThanEqual(id.xy,uvec2(lowSize())))) return;
 float mean=0, square=0;
 for(uint y=0;y<4;y++) for(uint x=0;x<4;x++) {
  ivec2 p=ivec2(min(id.xy*4+uvec2(x,y),uvec2(width-1,height-1)));
  float l=luminance(texelFetch(picture,ivec2(p),0).rgb);mean+=l;square+=l*l;
 }
 imageStore(next,ivec2(id.xy),vec4(mean/16,square/16,0,1));
}
void Estimate(uvec3 id) {
 ivec2 size=lowSize(), p=ivec2(id.xy);if(any(greaterThanEqual(p,size)))return;
 // First frame has no temporal observation: caller must not submit it to NR.
 if(warm==0u){imageStore(estimated,ivec2(p),vec4(vec2(0),0.0,0.0));return;}
 float best=1e10,zeroCost=0;ivec2 offset=ivec2(0);
 for(int dy=-3;dy<=3;dy++) for(int dx=-3;dx<=3;dx++) {
  float cost=0;
  for(int y=-1;y<=1;y++) for(int x=-1;x<=1;x++) {
   ivec2 a=clamp(p+ivec2(x,y),ivec2(0),size-1),b=clamp(p+ivec2(x+dx,y+dy),ivec2(0),size-1);
   vec2 ca=texelFetch(current,ivec2(a),0).xy, cb=texelFetch(previous,ivec2(b),0).xy;
   cost+=abs(ca.x-cb.x)+0.25*abs(ca.y-cb.y);
  }
  if(dx==0&&dy==0)zeroCost=cost;
  // Deterministic zero-motion preference in flat/ambiguous regions.
  cost+=0.0001*(dx*dx+dy*dy);
  if(cost<best){best=cost;offset=ivec2(dx,dy);}
 }
 // Avoid jumping to a weak block match (noise, disocclusion or interpolated frames).
 // Keep clearly better matches; this is an attempted visual-stability repair,
 // not a claim that estimated vectors equal the game's motion vectors.
 if(best>0.45||zeroCost-best<max(0.001,zeroCost*0.05))offset=ivec2(0);
 imageStore(estimated,ivec2(p),vec4(vec2(vec2(offset)*4/vec2(width,height)),0.0,0.0));
}
void Resolve(uvec3 id) {
 if(id.x>=width||id.y>=height)return;
 uvec2 sourcePixel=min(((id.xy*2u+1u)*uvec2(depthWidth,depthHeight))/(uvec2(width,height)*2u),uvec2(depthWidth-1,depthHeight-1));
 if((logarithmic&2u)!=0u)sourcePixel.y=depthHeight-1u-sourcePixel.y;
 float d=texelFetch(sceneDepth,ivec2(sourcePixel),0).r*depthMultiplier;
 if((logarithmic&1u)!=0u)d=(exp(d*log(1.01))-1)/0.01;
 if(reversed!=0u)d=1-d;
 imageStore(depthOut,ivec2(id.xy),vec4(clamp(d,0.0,1.0),0.0,0.0,0.0));
 imageStore(motionOut,ivec2(id.xy),vec4(vec2(texelFetch(coarseMotion,ivec2(min(id.xy/4,uvec2(lowSize())-1)),0).rg),0.0,0.0));
}
void main() { Prepare(gl_GlobalInvocationID); }
)OSGL";
inline constexpr char Estimate_glsl[] = R"OSGL(#version 430 core
// Same original OptiShade kernels and 32-byte constant contract as HLSL.
layout(local_size_x=8, local_size_y=8, local_size_z=1) in;
layout(std140, binding=0) uniform FrameConstants {
 uint width, height, warm, reversed;
 uint logarithmic; float depthMultiplier; uint depthWidth, depthHeight;
};
layout(binding=0) uniform sampler2D picture;
layout(binding=1) uniform sampler2D sceneDepth;
layout(binding=2) uniform sampler2D previous;
layout(binding=3) uniform sampler2D current;
layout(binding=4) uniform sampler2D coarseMotion;
layout(rgba16f, binding=0) writeonly uniform image2D next;
layout(rg16f, binding=1) writeonly uniform image2D estimated;
layout(r32f, binding=2) writeonly uniform image2D depthOut;
layout(rg16f, binding=3) writeonly uniform image2D motionOut;
ivec2 lowSize() { return ivec2((width+3)/4,(height+3)/4); }
float luminance(vec3 c) { return dot(c,vec3(0.2126,0.7152,0.0722)); }
void Prepare(uvec3 id) {
 if(any(greaterThanEqual(id.xy,uvec2(lowSize())))) return;
 float mean=0, square=0;
 for(uint y=0;y<4;y++) for(uint x=0;x<4;x++) {
  ivec2 p=ivec2(min(id.xy*4+uvec2(x,y),uvec2(width-1,height-1)));
  float l=luminance(texelFetch(picture,ivec2(p),0).rgb);mean+=l;square+=l*l;
 }
 imageStore(next,ivec2(id.xy),vec4(mean/16,square/16,0,1));
}
void Estimate(uvec3 id) {
 ivec2 size=lowSize(), p=ivec2(id.xy);if(any(greaterThanEqual(p,size)))return;
 // First frame has no temporal observation: caller must not submit it to NR.
 if(warm==0u){imageStore(estimated,ivec2(p),vec4(vec2(0),0.0,0.0));return;}
 float best=1e10,zeroCost=0;ivec2 offset=ivec2(0);
 for(int dy=-3;dy<=3;dy++) for(int dx=-3;dx<=3;dx++) {
  float cost=0;
  for(int y=-1;y<=1;y++) for(int x=-1;x<=1;x++) {
   ivec2 a=clamp(p+ivec2(x,y),ivec2(0),size-1),b=clamp(p+ivec2(x+dx,y+dy),ivec2(0),size-1);
   vec2 ca=texelFetch(current,ivec2(a),0).xy, cb=texelFetch(previous,ivec2(b),0).xy;
   cost+=abs(ca.x-cb.x)+0.25*abs(ca.y-cb.y);
  }
  if(dx==0&&dy==0)zeroCost=cost;
  // Deterministic zero-motion preference in flat/ambiguous regions.
  cost+=0.0001*(dx*dx+dy*dy);
  if(cost<best){best=cost;offset=ivec2(dx,dy);}
 }
 // Avoid jumping to a weak block match (noise, disocclusion or interpolated frames).
 // Keep clearly better matches; this is an attempted visual-stability repair,
 // not a claim that estimated vectors equal the game's motion vectors.
 if(best>0.45||zeroCost-best<max(0.001,zeroCost*0.05))offset=ivec2(0);
 imageStore(estimated,ivec2(p),vec4(vec2(vec2(offset)*4/vec2(width,height)),0.0,0.0));
}
void Resolve(uvec3 id) {
 if(id.x>=width||id.y>=height)return;
 uvec2 sourcePixel=min(((id.xy*2u+1u)*uvec2(depthWidth,depthHeight))/(uvec2(width,height)*2u),uvec2(depthWidth-1,depthHeight-1));
 if((logarithmic&2u)!=0u)sourcePixel.y=depthHeight-1u-sourcePixel.y;
 float d=texelFetch(sceneDepth,ivec2(sourcePixel),0).r*depthMultiplier;
 if((logarithmic&1u)!=0u)d=(exp(d*log(1.01))-1)/0.01;
 if(reversed!=0u)d=1-d;
 imageStore(depthOut,ivec2(id.xy),vec4(clamp(d,0.0,1.0),0.0,0.0,0.0));
 imageStore(motionOut,ivec2(id.xy),vec4(vec2(texelFetch(coarseMotion,ivec2(min(id.xy/4,uvec2(lowSize())-1)),0).rg),0.0,0.0));
}
void main() { Estimate(gl_GlobalInvocationID); }
)OSGL";
inline constexpr char Resolve_glsl[] = R"OSGL(#version 430 core
// Same original OptiShade kernels and 32-byte constant contract as HLSL.
layout(local_size_x=8, local_size_y=8, local_size_z=1) in;
layout(std140, binding=0) uniform FrameConstants {
 uint width, height, warm, reversed;
 uint logarithmic; float depthMultiplier; uint depthWidth, depthHeight;
};
layout(binding=0) uniform sampler2D picture;
layout(binding=1) uniform sampler2D sceneDepth;
layout(binding=2) uniform sampler2D previous;
layout(binding=3) uniform sampler2D current;
layout(binding=4) uniform sampler2D coarseMotion;
layout(rgba16f, binding=0) writeonly uniform image2D next;
layout(rg16f, binding=1) writeonly uniform image2D estimated;
layout(r32f, binding=2) writeonly uniform image2D depthOut;
layout(rg16f, binding=3) writeonly uniform image2D motionOut;
ivec2 lowSize() { return ivec2((width+3)/4,(height+3)/4); }
float luminance(vec3 c) { return dot(c,vec3(0.2126,0.7152,0.0722)); }
void Prepare(uvec3 id) {
 if(any(greaterThanEqual(id.xy,uvec2(lowSize())))) return;
 float mean=0, square=0;
 for(uint y=0;y<4;y++) for(uint x=0;x<4;x++) {
  ivec2 p=ivec2(min(id.xy*4+uvec2(x,y),uvec2(width-1,height-1)));
  float l=luminance(texelFetch(picture,ivec2(p),0).rgb);mean+=l;square+=l*l;
 }
 imageStore(next,ivec2(id.xy),vec4(mean/16,square/16,0,1));
}
void Estimate(uvec3 id) {
 ivec2 size=lowSize(), p=ivec2(id.xy);if(any(greaterThanEqual(p,size)))return;
 // First frame has no temporal observation: caller must not submit it to NR.
 if(warm==0u){imageStore(estimated,ivec2(p),vec4(vec2(0),0.0,0.0));return;}
 float best=1e10,zeroCost=0;ivec2 offset=ivec2(0);
 for(int dy=-3;dy<=3;dy++) for(int dx=-3;dx<=3;dx++) {
  float cost=0;
  for(int y=-1;y<=1;y++) for(int x=-1;x<=1;x++) {
   ivec2 a=clamp(p+ivec2(x,y),ivec2(0),size-1),b=clamp(p+ivec2(x+dx,y+dy),ivec2(0),size-1);
   vec2 ca=texelFetch(current,ivec2(a),0).xy, cb=texelFetch(previous,ivec2(b),0).xy;
   cost+=abs(ca.x-cb.x)+0.25*abs(ca.y-cb.y);
  }
  if(dx==0&&dy==0)zeroCost=cost;
  // Deterministic zero-motion preference in flat/ambiguous regions.
  cost+=0.0001*(dx*dx+dy*dy);
  if(cost<best){best=cost;offset=ivec2(dx,dy);}
 }
 // Avoid jumping to a weak block match (noise, disocclusion or interpolated frames).
 // Keep clearly better matches; this is an attempted visual-stability repair,
 // not a claim that estimated vectors equal the game's motion vectors.
 if(best>0.45||zeroCost-best<max(0.001,zeroCost*0.05))offset=ivec2(0);
 imageStore(estimated,ivec2(p),vec4(vec2(vec2(offset)*4/vec2(width,height)),0.0,0.0));
}
void Resolve(uvec3 id) {
 if(id.x>=width||id.y>=height)return;
 uvec2 sourcePixel=min(((id.xy*2u+1u)*uvec2(depthWidth,depthHeight))/(uvec2(width,height)*2u),uvec2(depthWidth-1,depthHeight-1));
 if((logarithmic&2u)!=0u)sourcePixel.y=depthHeight-1u-sourcePixel.y;
 float d=texelFetch(sceneDepth,ivec2(sourcePixel),0).r*depthMultiplier;
 if((logarithmic&1u)!=0u)d=(exp(d*log(1.01))-1)/0.01;
 if(reversed!=0u)d=1-d;
 imageStore(depthOut,ivec2(id.xy),vec4(clamp(d,0.0,1.0),0.0,0.0,0.0));
 imageStore(motionOut,ivec2(id.xy),vec4(vec2(texelFetch(coarseMotion,ivec2(min(id.xy/4,uvec2(lowSize())-1)),0).rg),0.0,0.0));
}
void main() { Resolve(gl_GlobalInvocationID); }
)OSGL";
}
