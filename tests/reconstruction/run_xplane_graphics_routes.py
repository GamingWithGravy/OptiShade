"""Compile/run route policy and Windows process-environment fixtures locally.

The fixture named X-Plane.exe is OUR tiny test executable, created in a fresh
temporary directory. It does not load Vulkan, ReShade, or any simulator.
"""
from pathlib import Path
import argparse
import os
import shutil
import subprocess
import tempfile

root=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser()
parser.add_argument('--compiler',default='cl')
args=parser.parse_args()
compiler=shutil.which(args.compiler)
if not compiler: raise SystemExit('Compiler not available; use a developer command prompt.')

def run(command,cwd):
    subprocess.run(list(map(str,command)),cwd=cwd,check=True)

with tempfile.TemporaryDirectory(prefix='optishade-xplane-route-test-') as folder:
    temp=Path(folder)
    shared=root/'Beta/shared'
    msvc=Path(compiler).name.lower() in ('cl','cl.exe','clang-cl','clang-cl.exe')
    def build(source,output):
        includes=[shared,root/'Beta/optiscaler/external/nlohmann']
        if msvc:
            command=[compiler,'/nologo','/std:c++17','/EHsc','/W4','/Od','/utf-8',
                *['/I'+str(p) for p in includes],root/'tests/reconstruction'/source,'/Fe:'+str(output)]
        else:
            command=[compiler,'-std=c++17','-Wall','-Wextra','-O0',
                *['-I'+str(p) for p in includes],root/'tests/reconstruction'/source,'-o',output]
        run(command,temp)
    policy=temp/('policy.exe' if os.name=='nt' else 'policy')
    build('xplane_graphics_route_tests.cpp',policy)
    run([policy],temp)
    if os.name=='nt':
        fixture=temp/'X-Plane.exe'
        build('xplane_graphics_process_tests.cpp',fixture)
        (temp/'OptiShadeData').mkdir()
        config=temp/'OptiShadeData/XPlane-compatibility.ini'
        for route in ('missing','native-vulkan','menu-only','legacy-dxgi','invalid'):
            if config.exists():config.unlink()
            if route!='missing':config.write_text('[XPlane]\nGraphicsRoute='+route+'\nUnrelated=preserved\n',encoding='ascii')
            run([fixture,route],temp)
        other=temp/'OtherGame.exe'
        shutil.copy2(fixture,other)
        config.write_text('[XPlane]\nGraphicsRoute=menu-only\n',encoding='ascii')
        run([other,'other'],temp)
print('XP12 graphics route policy/process fixtures PASS; no simulator/GPU test performed.')
