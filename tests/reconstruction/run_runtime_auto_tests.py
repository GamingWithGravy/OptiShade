#!/usr/bin/env python3
"""Execute the production native Auto bridge with bounded platform/provider seams.

The production RuntimeAuto class, primary-output metadata publisher, controller,
native request owner, NR ticket tracker, receipt validator and endpoint are used
unchanged. Only Windows I/O, the existing owner callbacks and worker publications
are supplied by the fixture. This is not a Windows build or a GPU/output test.
"""
from pathlib import Path
import argparse
import os
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent


def once(source, old, new):
    if source.count(old) != 1:
        raise SystemExit(f'Production Auto platform seam changed: {old[:120]!r}')
    return source.replace(old, new, 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', default='g++')
    parser.add_argument('--root', type=Path, default=HERE.parents[1])
    args = parser.parse_args()
    root = args.root.resolve()
    compiler = shutil.which(args.compiler)
    if not compiler:
        raise SystemExit(f'Compiler unavailable: {args.compiler}; runtime Auto tests not run')
    shared = root / 'Beta/shared'
    production = (shared / 'RuntimeControlWin.h').read_text(encoding='utf-8')
    begin = production.index('namespace optishade::control {\nclass RuntimeAuto {')
    end = production.index('\ninline Json NrSnapshot()', begin)
    body = production[begin:end] + '\n}\n'
    preparation = (shared / 'NeuralRuntimePreparationWin.h').read_text(encoding='utf-8')
    start = preparation.index('struct Snapshot {')
    finish = preparation.index('\n};', start) + len('\n};')
    preparation_snapshot = preparation[start:finish]
    tracker = (shared / 'NrObservation.h').read_text(encoding='utf-8')
    tracker = once(tracker, '#include "SimulatorRouteHost.h"\n', '')
    tracker = once(tracker, '#include "LastSession.h"\n', '')
    tracker = once(tracker, 'inline Tracker& State(){return optishade::route::Owned<Tracker,15>();}',
                   'inline Tracker& State(){static Tracker tracker;return tracker;}')
    journal = '''#include <string>
#include <map>
#include <initializer_list>
#include <utility>
namespace optishade::session {
struct Journal {
 std::map<std::string,std::string> values,critical;
 void Put(std::initializer_list<std::pair<const std::string,std::string>> items) {for(const auto& item:items)values[item.first]=item.second;}
 void PutCritical(std::initializer_list<std::pair<const std::string,std::string>> items) {for(const auto& item:items){values[item.first]=item.second;critical[item.first]=item.second;}}
};
inline Journal& State(){static Journal journal;return journal;}
}
'''
    # The real game-owned passive callback is compiled as well. The resolver's
    # module pin/file identity is the only Windows-specific callback seam.
    hook = (root / 'Beta/optiscaler/OptiScaler/hooks/Streamline_Hooks.cpp').read_text(encoding='utf-8')
    start = hook.index('sl::Result StreamlineHooks::PassiveState(')
    finish = hook.index('\nsl::Result StreamlineHooks::ExternalState(', start)
    passive = hook[start:finish]
    passive = passive.replace('DlssgCallerSite(_ReturnAddress())', 'DlssgCallerSite(nullptr)')
    msvc = Path(compiler).name.lower() in ('cl', 'cl.exe', 'clang-cl', 'clang-cl.exe')
    with tempfile.TemporaryDirectory(prefix='optishade-runtime-auto-') as temporary:
        directory = Path(temporary)
        (directory / 'runtime_auto_body.inc').write_text(body, encoding='utf-8')
        (directory / 'preparation_snapshot.inc').write_text(preparation_snapshot, encoding='utf-8')
        (directory / 'NrObservation.h').write_text(journal + tracker, encoding='utf-8')
        (directory / 'passive_fg_body.inc').write_text(passive, encoding='utf-8')
        includes = [directory, shared, root / 'Beta/optiscaler/OptiScaler/hooks', root / 'Beta/optiscaler/external/nlohmann',
                    root / 'Beta/optiscaler/external/streamline']
        for name in ('runtime_auto_tests', 'nr_session_tests'):
            binary = directory / (name + ('.exe' if os.name == 'nt' else ''))
            if msvc:
                command = [compiler, '/nologo', '/std:c++20', '/EHsc', '/W4', '/Od',
                           *['/I' + str(path) for path in includes], str(HERE / (name + '.cpp')),
                           '/Fe:' + str(binary)]
            else:
                command = [compiler, '-std=c++20', '-O0', '-Wall', '-Wextra', '-pthread',
                           *['-I' + str(path) for path in includes], str(HERE / (name + '.cpp')),
                           '-o', str(binary)]
            subprocess.run(command, cwd=directory, check=True)
            subprocess.run([str(binary)], cwd=directory, check=True)


if __name__ == '__main__':
    main()
