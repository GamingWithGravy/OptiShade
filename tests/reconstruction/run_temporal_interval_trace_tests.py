#!/usr/bin/env python3
"""Compile and exercise the actual bounded NGX temporal trace writer."""
from pathlib import Path
import argparse
import os
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', default='cl')
    parser.add_argument('--root', type=Path, default=HERE.parents[1])
    args = parser.parse_args()
    compiler = shutil.which(args.compiler)
    if not compiler:
        raise SystemExit(f'Compiler unavailable: {args.compiler}; trace test not run')
    root = args.root.resolve()
    sdk = root / 'Beta/optiscaler/external/nvngx_dlss_sdk'
    msvc = Path(compiler).name.lower() in ('cl', 'cl.exe')
    if not msvc:
        raise SystemExit('The trace writer test requires MSVC on Windows')
    with tempfile.TemporaryDirectory(prefix='optishade-temporal-trace-') as temporary:
        directory = Path(temporary)
        sources = (
            ('upstream', root / 'Beta/optiscaler/external/RTX40MFG-Unlock/source/native'),
            ('packaged', root / 'Beta/installer/OptionalMFG/Source203040/native'),
        )
        for name, source in sources:
            if not (source / 'temporal_interval_trace.cpp').is_file():
                raise SystemExit(f'Missing {name} MFG trace implementation: {source}')
            target = directory / name
            target.mkdir()
            binary = target / 'temporal-interval-trace-tests.exe'
            command = [compiler, '/nologo', '/std:c++17', '/EHsc', '/W4', '/Od',
                       '/I' + str(source), '/I' + str(sdk),
                       str(HERE / 'temporal_interval_trace_tests.cpp'),
                       str(source / 'temporal_interval_trace.cpp'),
                       '/Fe:' + str(binary)]
            subprocess.run(command, cwd=target, check=True)
            output = target / 'trace'
            subprocess.run([str(binary), str(output)], cwd=target, check=True)


if __name__ == '__main__':
    main()
