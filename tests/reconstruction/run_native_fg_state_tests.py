#!/usr/bin/env python3
"""Compile the real dummy callback body plus production state-helper ABI tests."""
from pathlib import Path
import argparse
import os
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', default='g++')
    parser.add_argument('--root', type=Path, default=HERE.parents[1])
    parser.add_argument('--hook-source', type=Path, help='Optional preserved production hook for defect reproduction')
    args = parser.parse_args()
    root = args.root.resolve()
    compiler = shutil.which(args.compiler)
    if not compiler:
        raise SystemExit(f'Compiler unavailable: {args.compiler}; native FG tests not run')
    hook = args.hook_source or root/'Beta/optiscaler/OptiScaler/hooks/Streamline_Hooks.cpp'
    source = hook.read_text(encoding='utf-8')
    start = source.index('static sl::Result dummy_slDLSSGGetState(')
    end = source.index('\nstatic sl::Result dummy_slDLSSGSetOptions(', start)
    callback = source[start:end]
    msvc = Path(compiler).name.lower() in ('cl', 'cl.exe', 'clang-cl', 'clang-cl.exe')
    with tempfile.TemporaryDirectory(prefix='optishade-native-fg-state-') as temporary:
        directory = Path(temporary)
        body = directory/'native_fg_dummy_callback.inc'
        body.write_text(callback, encoding='utf-8')
        binary = directory/('native-fg-state.exe' if os.name=='nt' else 'native-fg-state')
        includes = [root/'Beta/shared', root/'Beta/optiscaler/OptiScaler', root/'Beta/optiscaler/external/streamline', directory]
        define = 'OPTISHADE_NATIVE_FG_CALLBACK_FILE="native_fg_dummy_callback.inc"'
        if msvc:
            command = [compiler, '/nologo', '/std:c++17', '/EHsc', '/W4', '/Od',
                       *['/I'+str(p) for p in includes], '/D'+define,
                       str(HERE/'native_fg_state_tests.cpp'), '/Fe:'+str(binary)]
        else:
            command = [compiler, '-std=c++17', '-O0', '-Wall', '-Wextra',
                       *['-I'+str(p) for p in includes], '-D'+define,
                       str(HERE/'native_fg_state_tests.cpp'), '-o', str(binary)]
        subprocess.run(command, cwd=directory, check=True)
        subprocess.run([str(binary)], cwd=directory, check=True)

if __name__ == '__main__':
    main()
