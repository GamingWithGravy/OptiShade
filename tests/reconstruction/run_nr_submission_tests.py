#!/usr/bin/env python3
"""Exercise the production NR ticket tracker and transport callback classifier."""
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
    args = parser.parse_args()
    root = args.root.resolve()
    shared = root/'Beta/shared'
    compiler = shutil.which(args.compiler)
    if not compiler:
        raise SystemExit(f'Compiler unavailable: {args.compiler}; NR submission tests not run')
    msvc = Path(compiler).name.lower() in ('cl', 'cl.exe', 'clang-cl', 'clang-cl.exe')
    with tempfile.TemporaryDirectory(prefix='optishade-nr-submission-') as temporary:
        directory = Path(temporary)
        if os.name != 'nt':
            # Compile the actual tracker body on portable CI. Only the Windows
            # route-owned singleton accessor and journal sink are substituted;
            # ticket creation, invalidation and all stage transitions are intact.
            source = (shared/'NrObservation.h').read_text(encoding='utf-8')
            for line in ['#include "SimulatorRouteHost.h"\n', '#include "LastSession.h"\n',
                         'inline Tracker& State(){return optishade::route::Owned<Tracker,15>();}\n']:
                if source.count(line) != 1:
                    raise SystemExit(f'NR tracker platform seam changed: {line.strip()}')
                source = source.replace(line, '', 1)
            stub = '''#include <string>
#include <initializer_list>
#include <utility>
namespace optishade::session {
struct Journal { void Put(std::initializer_list<std::pair<const std::string,std::string>>) {} };
inline Journal& State(){static Journal journal;return journal;}
}
'''
            (directory/'NrObservation.h').write_text(stub+source, encoding='utf-8')
        includes = [directory, shared]
        for test in ['nr_observation_tests', 'nr_submission_tests']:
            binary = directory/(test+('.exe' if os.name=='nt' else ''))
            if msvc:
                command = [compiler, '/nologo', '/std:c++20', '/EHsc', '/W4', '/Od',
                           *['/I'+str(p) for p in includes], str(HERE/(test+'.cpp')), '/Fe:'+str(binary)]
            else:
                command = [compiler, '-std=c++20', '-O0', '-Wall', '-Wextra',
                           *['-I'+str(p) for p in includes], str(HERE/(test+'.cpp')), '-o', str(binary)]
            subprocess.run(command, cwd=directory, check=True)
            subprocess.run([str(binary)], cwd=directory, check=True)

if __name__ == '__main__':
    main()
