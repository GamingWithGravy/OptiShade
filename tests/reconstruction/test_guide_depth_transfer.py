"""Compile/execute the existing D3D10 relay depth prepass as software GLSL.

The source is the same production HLSL, with a strict syntax translation and
compute wrapper for Mesa. This checks sampling/conversion arithmetic, not the
Windows pixel-shader ABI, D24 sharing, NR, HDR, MSAA, XR or display qualification.
"""
import argparse
import importlib.util
import math
from pathlib import Path
import re
import struct

ROOT = Path(__file__).resolve().parents[2]
HEADER = ROOT / 'Beta/shared/GuideDepthTransfer.h'


def source_contract():
    source = HEADER.read_text()
    matches = re.findall(r'R"OSDEPTH\((.*?)\)OSDEPTH"', source, re.S)
    assert len(matches) == 1, 'Missing/ambiguous production HLSL'
    hlsl = matches[0]
    constants = re.findall(r'cbuffer Extent:register\(b0\)\s*\{(.*?)\};', hlsl, re.S)
    assert len(constants) == 1
    expected = ('uint width,height,sourceX,sourceY; '
                'uint sourceWidth,sourceHeight,flip,conversion; '
                'float nearZ,farZ,multiplier;uint reserved;')
    assert ' '.join(constants[0].split()) == expected, 'Production constant ABI changed'
    signature = 'float CopyPS(float4 position:SV_Position):SV_Target {'
    assert hlsl.count(signature) == 1
    body = hlsl[hlsl.index(signature) + len(signature):]
    assert body.rstrip().endswith('}')
    body = body.rstrip()[:-1]
    # These are syntax/API translations only; do not replace formulas or
    # simplify a production branch to make the numerical fixture pass.
    body = body.replace('uint2', 'uvec2')
    body = body.replace('if(flip)', 'if(flip!=0u)')
    body = body.replace('if(conversion)', 'if(conversion!=0u)')
    assert body.count('scene.Load(int3(samplePixel,0))') == 1
    body = body.replace('scene.Load(int3(samplePixel,0))',
                        'texelFetch(scene,ivec2(samplePixel),0).r')
    body = body.replace('!isfinite(d)', '(isnan(d)||isinf(d))')
    body = body.replace('asfloat(0x7fc00000u)', 'uintBitsToFloat(0x7fc00000u)')
    body = body.replace('saturate(d)', 'clamp(d,0.0,1.0)')
    assert not re.search(r'\.Load\(|\b(?:uint2|float4|isfinite|asfloat|saturate|SV_)', body)
    glsl = ('#version 430 core\n'
            'layout(local_size_x=8,local_size_y=8,local_size_z=1) in;\n'
            'layout(std140,binding=0) uniform Extent {' + constants[0] + '};\n'
            'layout(binding=0) uniform sampler2D scene;\n'
            'layout(r32f,binding=0) writeonly uniform image2D target;\n'
            'float CopyPS(vec4 position) {' + body + '}\n'
            'void main(){uvec2 p=gl_GlobalInvocationID.xy;'
            'if(p.x>=width||p.y>=height)return;'
            'imageStore(target,ivec2(p),vec4(CopyPS(vec4(vec2(p)+0.5,0,1)),0,0,0));}\n')
    # Direct integration check: the existing worker compiles this source and
    # its actual D3D10 frame consumes Prepare's constants before its old kernels.
    relay = (ROOT / 'Beta/legacy-nr/upstream/src/feed_d3d10_guides.h').read_text()
    assert 'const auto& copy=optishade::guides::depth_transfer::Hlsl;' in relay
    assert 'depth_transfer::Prepare(interpretation.depth,' in relay
    assert 'UpdateSubresource(core->copy_constants,0,nullptr,&transfer,0,0)' in relay
    assert 'sizeof(optishade::guides::depth_transfer::Constants)' in relay
    assert 'CoreGuideReason(interpretation.color,interpretation.depth,' in relay
    core = (ROOT / 'Beta/reshade/source/optishade_core_guides.inl').read_text()
    assert 'osformat::Inspect(cd,device->get_resource_view_desc(rtv),dd,' in core
    assert '!optishade::format_view::Same(c->interpretation,input.interpretation)' in core
    print('PASS: production depth transfer HLSL, 48-byte constants, strict software translation and live guide-owner consumers')
    return glsl


def execute(source):
    spec = importlib.util.spec_from_file_location('core_guide_gl', ROOT / 'tests/reconstruction/test_core_guides_glsl.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    gl = module.SoftwareGL()
    try:
        shader = gl.compile(source)
        aw, ah = 32, 24
        # Sharp boundaries make an accidental linear depth filter observable.
        values = [((x + 3*y) % 7)/6 for y in range(ah) for x in range(aw)]
        texture = gl.texture(aw, ah, 0x822E, 1, values)
        cases = [
            # output, source rectangle, flip, conversion, near/far/scale
            ((32, 24), (0, 0, 32, 24), 0, 0, (0., 0., 1.)),
            ((19, 11), (7, 5, 13, 9), 0, 0, (0., 0., 1.)),
            ((19, 11), (7, 5, 13, 9), 1, 0, (0., 0., 2.)),
            # Linear-depth tests are preparation references. Production
            # admission still rejects them until a real route is qualified.
            ((19, 11), (7, 5, 13, 9), 0, 1, (0.1, 1000., 1.)),
            ((19, 11), (7, 5, 13, 9), 1, 1, (0.1, 1000., 2.)),
            ((19, 11), (7, 5, 13, 9), 1, 2, (0.1, 0., 1.)),
        ]
        checks = 0
        for output, rect, flip, conversion, projection in cases:
            w, h = output
            sx, sy, sw, sh = rect
            near, far, multiplier = projection
            if conversion:
                data = [(-1., 0., 0.1, 0.25, 1., 10., 1000., 2000.)[(x+3*y) % 8]
                        for y in range(ah) for x in range(aw)]
            else:
                data = values
            gl.upload(texture, data)
            result = gl.texture(w, h, 0x822E, 1)
            raw = struct.pack('<8I3fI', w, h, sx, sy, sw, sh, flip, conversion, near, far, multiplier, 0)
            assert len(raw) == 48
            gl.run(shader, [texture], [result], raw, (w+7)//8, (h+7)//8)
            actual = gl.read(result)
            for y in range(h):
                for x in range(w):
                    px = sx + math.floor((x+0.5)*sw/w)
                    row = math.floor((y+0.5)*sh/h)
                    py = sy + (sh-1-row if flip else row)
                    expected = data[py*aw+px]
                    if conversion:
                        distance = expected*multiplier
                        if distance <= 0:
                            assert math.isnan(actual[y*w+x]), (conversion, x, y, actual[y*w+x])
                            checks += 1
                            continue
                        expected = (1-near/distance if conversion == 2 else
                                    far/(far-near)*(1-near/distance))
                        expected = max(0., min(1., expected))
                    assert abs(actual[y*w+x]-expected) < 2e-6, (conversion, flip, x, y, actual[y*w+x], expected)
                    checks += 1
        print(f'PASS: {checks} actual software GL samples on {gl.renderer}; production raw-depth preservation, '
              'odd/scaled subrect/vertical mapping and finite/infinite linear-depth preparation. '
              'No Windows/HDR/MSAA/XR/NR/display qualification.')
    finally:
        gl.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--software-gl', action='store_true')
    args = parser.parse_args()
    source = source_contract()
    if args.software_gl:
        execute(source)
