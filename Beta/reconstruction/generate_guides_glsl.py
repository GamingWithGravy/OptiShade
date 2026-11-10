"""Generate OpenGL variants of the original core guide kernels, not a second producer.

This intentionally small translation accepts the current HLSL dialect only.
Unexpected syntax fails rather than silently emitting a different algorithm.
Run without arguments to update the checked-in header, or --check at build time.
"""
from __future__ import annotations
import argparse
import hashlib
import re
from pathlib import Path

BETA = Path(__file__).resolve().parents[1]
SOURCE = BETA / 'reshade/res/shaders/optishade_guides.hlsl'
HEADER = BETA / 'reshade/res/shaders/optishade_guides.glsl.h'
ENTRIES = ('Prepare', 'Estimate', 'Resolve')

PREAMBLE = '''#version 430 core
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
'''

def normalized_text_bytes(data: bytes) -> bytes:
    """Normalize text line endings before hashing generated-source provenance."""
    return data.replace(b'\r\n', b'\n').replace(b'\r', b'\n')

def translate(source: str) -> str:
    required = 'struct FrameData { uint width, height, warm, reversed; uint logarithmic; float depthMultiplier; uint depthWidth, depthHeight; };'
    if required not in source or source.count('int2 lowSize()') != 1:
        raise ValueError('Core guide constant/source contract changed; update the GLSL translator explicitly')
    body = source[source.index('int2 lowSize()'):].strip()
    for name in ENTRIES:
        signature = f'[numthreads(8,8,1)] void {name}(uint3 id:SV_DispatchThreadID)'
        if body.count(signature) != 1:
            raise ValueError(f'Unexpected {name} entry contract')
        body = body.replace(signature, f'void {name}(uvec3 id)')
    body = body.replace('[unroll] ', '').replace('[loop] ', '')
    for hlsl, glsl in (('float4','vec4'),('float3','vec3'),('float2','vec2'),('int2','ivec2'),('uint2','uvec2')):
        body = re.sub(r'\b'+hlsl+r'\b', glsl, body)
    body = body.replace('(uvec2)lowSize()', 'uvec2(lowSize())')
    body = re.sub(r'(picture|sceneDepth|previous|current|coarseMotion)\.Load\(int3\((.*?),0\)\)',
        lambda m: f'texelFetch({m[1]},ivec2({m[2]}),0)' + ('.r' if m[1]=='sceneDepth' else '.rg' if m[1]=='coarseMotion' else ''), body)
    body = body.replace('any(id.xy >= uvec2(lowSize()))', 'any(greaterThanEqual(id.xy,uvec2(lowSize())))')
    body = body.replace('ivec2 p=min(id.xy*4+uvec2(x,y),uvec2(width-1,height-1));',
                        'ivec2 p=ivec2(min(id.xy*4+uvec2(x,y),uvec2(width-1,height-1)));')
    body = body.replace('p=id.xy;if(any(p>=size))', 'p=ivec2(id.xy);if(any(greaterThanEqual(p,size)))')
    body = body.replace('if(!warm)', 'if(warm==0u)').replace('if(logarithmic)', 'if((logarithmic&1u)!=0u)').replace('if(reversed)', 'if(reversed!=0u)')
    body = body.replace('offset=0', 'offset=ivec2(0)')
    body = body.replace('),0,size-1)', '),ivec2(0),size-1)')
    body = body.replace('saturate(d)', 'clamp(d,0.0,1.0)')
    # OpenGL depth orientation is a platform binding transform, not an optical
    # flow variant. Bit 1 is used only by this GLSL backend; bit 0 remains log.
    body = body.replace('float d=texelFetch(sceneDepth,',
        'if((logarithmic&2u)!=0u)sourcePixel.y=depthHeight-1u-sourcePixel.y;\n float d=texelFetch(sceneDepth,')
    def store(m: re.Match) -> str:
        target, pixel, value = m.groups()
        if target in ('estimated','motionOut'):
            value = f'vec4(vec2({value}),0.0,0.0)'
        elif target == 'depthOut':
            value = f'vec4({value},0.0,0.0,0.0)'
        return f'imageStore({target},ivec2({pixel}),{value});'
    body = re.sub(r'\b(next|estimated|depthOut|motionOut)\[([^\]]+)\]\s*=\s*([^;]+);', store, body)
    if re.search(r'\.Load\(|\b(?:float[234]|int[234]|uint[234]|saturate|SV_DispatchThreadID)\b|\[(?:unroll|loop|numthreads)', body):
        raise ValueError('Untranslated HLSL syntax; no header written')
    if len(re.findall(r'\bimageStore\(', body)) != 5:
        raise ValueError('Core guide output contract changed')
    return PREAMBLE + body + '\n'

def shaders(source: bytes) -> dict[str,str]:
    body = translate(source.decode('utf-8-sig').replace('\r\n','\n'))
    return {name: body + f'void main() {{ {name}(gl_GlobalInvocationID); }}\n' for name in ENTRIES}

def generated(source: bytes) -> bytes:
    source_sha = hashlib.sha256(normalized_text_bytes(source)).hexdigest().upper()
    generator_sha = hashlib.sha256(normalized_text_bytes(Path(__file__).read_bytes())).hexdigest().upper()
    lines = ['// Original OptiShade core guide GLSL variants, GPL-3.0-or-later.',
             '// Source-SHA256: '+source_sha, '// Generator-SHA256: '+generator_sha,
             '#pragma once', 'namespace osguide::shaders {']
    for name, code in shaders(source).items():
        lines.extend([f'inline constexpr char {name}_glsl[] = R"OSGL({code})OSGL";'])
    lines.append('}')
    return ('\n'.join(lines)+'\n').encode('utf-8')

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    expected = generated(SOURCE.read_bytes())
    if args.check:
        if not HEADER.is_file() or HEADER.read_bytes() != expected:
            raise SystemExit('GLSL core guide header differs from its original HLSL source/translator; regenerate it')
        print('PASS: GLSL variants match the original HLSL and deterministic translator')
    else:
        HEADER.write_bytes(expected)
        print(HEADER)

if __name__ == '__main__':
    main()
