#!/usr/bin/env python3
"""Compile the actual FrameCapture implementation against explicit GPU/lease doubles."""
from pathlib import Path
import argparse
import os
import shutil
import subprocess
import tempfile

HERE=Path(__file__).resolve().parent

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler',default='g++')
    parser.add_argument('--root',type=Path,default=HERE.parents[1])
    args=parser.parse_args()
    compiler=shutil.which(args.compiler)
    if not compiler:
        raise SystemExit(f'Compiler unavailable: {args.compiler}; capture tests not run')
    source=(args.root/'Beta/optiscaler/OptiScaler/dlssnr/DlssNr_Capture.h').read_text(encoding='utf-8')
    for line in ['#include <windows.h>\n','#include <d3d12.h>\n','#include "../../../shared/NrGpuLifetime.h"\n']:
        if source.count(line)!=1:
            raise SystemExit(f'FrameCapture dependency seam changed: {line.strip()}')
        source=source.replace(line,'',1)
    msvc=Path(compiler).name.lower() in ('cl','cl.exe','clang-cl','clang-cl.exe')
    with tempfile.TemporaryDirectory(prefix='optishade-nr-capture-') as temporary:
        directory=Path(temporary)
        (directory/'DlssNr_Capture.h').write_text('#include "nr_capture_test_gpu.h"\n'+source,encoding='utf-8')
        binary=directory/('nr-capture.exe' if os.name=='nt' else 'nr-capture')
        includes=[directory,HERE]
        if msvc:
            command=[compiler,'/nologo','/std:c++20','/EHsc','/W4','/Od',*['/I'+str(p) for p in includes],str(HERE/'nr_capture_tests.cpp'),'/Fe:'+str(binary)]
        else:
            command=[compiler,'-std=c++20','-O0','-Wall','-Wextra',*['-I'+str(p) for p in includes],str(HERE/'nr_capture_tests.cpp'),'-o',str(binary)]
        subprocess.run(command,cwd=directory,check=True)
        subprocess.run([str(binary)],cwd=directory,check=True)

if __name__=='__main__':
    main()
