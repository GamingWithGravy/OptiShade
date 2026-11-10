#!/usr/bin/env python3
"""Compile and run the Windows SEH boundary around Streamline GetState."""
from pathlib import Path
import argparse
import shutil
import subprocess
import tempfile

HERE=Path(__file__).resolve().parent

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--compiler',default='cl')
    parser.add_argument('--root',type=Path,default=HERE.parents[1])
    args=parser.parse_args()
    compiler=shutil.which(args.compiler)
    if not compiler:
        raise SystemExit(f'Compiler unavailable: {args.compiler}; SEH containment test not run')
    root=args.root.resolve()
    hooks=root/'Beta/optiscaler/OptiScaler/hooks'
    streamline=root/'Beta/optiscaler/external/streamline'
    with tempfile.TemporaryDirectory(prefix='optishade-safe-dlss-state-') as temporary:
        binary=Path(temporary)/'safe-dlss-state.exe'
        command=[compiler,'/nologo','/std:c++17','/EHsc','/W4','/I'+str(hooks),'/I'+str(streamline),
                 str(HERE/'safe_dlss_getstate_tests.cpp'),'/Fe:'+str(binary)]
        subprocess.run(command,cwd=temporary,check=True)
        subprocess.run([str(binary)],cwd=temporary,check=True)

if __name__=='__main__': main()
