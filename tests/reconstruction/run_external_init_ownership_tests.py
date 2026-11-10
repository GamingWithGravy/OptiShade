#!/usr/bin/env python3
"""Exercise actual interposer installer, cleanup, device and tag callback bodies.

Windows Detours, COM and NR execution are instrumented boundaries. This tests
production control flow; it does not execute DLL bytes or qualify game output.
"""
from pathlib import Path
import argparse
import os
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent

def body(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    # These selected functions contain no unmatched braces in comments/strings.
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end] + '\n'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', default='g++')
    parser.add_argument('--root', type=Path, default=HERE.parents[1])
    parser.add_argument('--hook-source', type=Path,
                        help='Preserved production source for defect reproduction')
    parser.add_argument('--case', default='all',
                        choices=['all', 'external', 'lifecycle', 'tags', 'device', 'managed', 'transactions'])
    args = parser.parse_args()
    root = args.root.resolve()
    compiler = shutil.which(args.compiler)
    if not compiler:
        raise SystemExit(f'Compiler unavailable: {args.compiler}; ownership tests not run')
    hook = args.hook_source or root/'Beta/optiscaler/OptiScaler/hooks/Streamline_Hooks.cpp'
    source = hook.read_text(encoding='utf-8')
    detour_source = (root/'Beta/optiscaler/OptiScaler/hooks/ProcessDetourTransaction.h').read_text(encoding='utf-8')
    modern = 'enum class InterposerTagMode' in source
    marker = 'enum class InterposerTagMode' if modern else 'static std::atomic<bool> g_frameBasedResourceTagging'
    helpers = source[source.index(marker):source.index('static bool HasNullTaaFgResource')]
    methods = [
        'void StreamlineHooks::unhookInterposer()',
        'void StreamlineHooks::hookInterposer(',
        'bool StreamlineHooks::isInterposerHooked()',
        'void StreamlineHooks::ExternalPrepare(',
        'void StreamlineHooks::NativeProviderPresentBegin(',
        'void StreamlineHooks::NativeProviderPresentEnd(',
        'sl::Result StreamlineHooks::hkslSetTag(',
        'sl::Result StreamlineHooks::hkslSetTagForFrame(',
        'sl::Result StreamlineHooks::hkslSetD3DDevice(',
    ]
    if modern:
        methods.insert(0, 'void StreamlineHooks::clearInterposerPointers()')
    # Keep the production transaction/queue logic under test while replacing
    # only the Win32 thread snapshot boundary with an empty deterministic set.
    # Thread enumeration itself is covered by source contract checks because
    # this harness also runs on non-Windows hosts.
    transaction_helpers = '\nnamespace OptiShade::Detours {\n'
    transaction_helpers += body(detour_source, 'inline std::mutex& ProcessDetourTransactionMutex(')
    transaction_helpers += 'inline LONG EnlistCurrentProcessThreads(std::vector<HANDLE>&) { return NO_ERROR; }\n'
    transaction_helpers += body(detour_source, 'inline LONG QueueProcessDetour(')
    transaction_helpers += 'template <typename Action>\n' + body(detour_source, 'LONG WithProcessDetourTransaction(')
    transaction_helpers += '} // namespace OptiShade::Detours\n'
    extracted = transaction_helpers + helpers + body(source, 'static bool HasNullTaaFgResource(')
    extracted += '\n'.join(body(source, name) for name in methods)
    msvc = Path(compiler).name.lower() in ('cl', 'cl.exe', 'clang-cl', 'clang-cl.exe')
    with tempfile.TemporaryDirectory(prefix='optishade-external-init-') as temporary:
        directory = Path(temporary)
        (directory/'external_init_production.inc').write_text(extracted, encoding='utf-8')
        binary = directory/('external-init.exe' if os.name == 'nt' else 'external-init')
        includes = [root/'Beta/optiscaler/external/streamline', directory]
        definitions = ['OPTISHADE_INIT_PRODUCTION_FILE="external_init_production.inc"',
                       f'OPTISHADE_INIT_TRACKED={int(modern)}']
        if msvc:
            command = [compiler, '/nologo', '/std:c++17', '/EHsc', '/W4', '/Od',
                       *['/I'+str(p) for p in includes], *['/D'+d for d in definitions],
                       str(HERE/'external_init_ownership_tests.cpp'), '/Fe:'+str(binary)]
        else:
            command = [compiler, '-std=c++17', '-O0', '-Wall', '-Wextra',
                       *['-I'+str(p) for p in includes], *['-D'+d for d in definitions],
                       str(HERE/'external_init_ownership_tests.cpp'), '-o', str(binary)]
        subprocess.run(command, cwd=directory, check=True)
        result = subprocess.run([str(binary), args.case], cwd=directory)
        raise SystemExit(result.returncode)

if __name__ == '__main__':
    main()
