#!/usr/bin/env python3
"""Exercise the production native FG request, callback and Save/advanced UI bodies.

Windows graphics/provider calls, ImGui interaction and persistence are explicit
fixture seams. This is a CPU authority/migration regression, not a native UI,
detour, GPU or displayed-output qualification.
"""
from pathlib import Path
import argparse
import os
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent


def between(text, first, last):
    start = text.index(first)
    return text[start:text.index(last, start)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', default='g++')
    parser.add_argument('--root', type=Path, default=HERE.parents[1])
    args = parser.parse_args()
    root = args.root.resolve()
    compiler = shutil.which(args.compiler)
    if not compiler:
        raise SystemExit(f'Compiler unavailable: {args.compiler}')
    project = root / 'Beta/optiscaler/OptiScaler'
    hooks = (project / 'hooks/Streamline_Hooks.cpp').read_text(encoding='utf-8-sig')
    ui = (project / 'menu/optishade_mfg_ui.inl').read_text(encoding='utf-8-sig')
    menu = (project / 'menu/menu_common.cpp').read_text(encoding='utf-8-sig')
    config = (project / 'Config.cpp').read_text(encoding='utf-8-sig')
    config_header = (project / 'Config.h').read_text(encoding='utf-8-sig')
    # Caller/build wiring matters: the superseded direct setup and ratio editor
    # must not survive beside the qualified worker / shared staged controls.
    main_source = (project / 'dllmain.cpp').read_text(encoding='utf-8-sig')
    if 'AmpereMfgLoader::TrySetup();' in main_source:
        raise SystemExit('The obsolete startup provider setup caller remains active')
    if 'Override DLSSG Ratio' in menu:
        raise SystemExit('The superseded direct-config ratio editor remains active')
    bodies = {
        'external_options_body.inc': between(hooks, 'sl::Result StreamlineHooks::ExternalOptions(', '\nsl::Result StreamlineHooks::PassiveState('),
        'external_state_body.inc': between(hooks, 'sl::Result StreamlineHooks::ExternalState(', '\nvoid StreamlineHooks::ExternalPrepare('),
        'native_options_body.inc': between(hooks, 'sl::Result StreamlineHooks::hkslDLSSGSetOptions(', '\nsl::Result StreamlineHooks::hkslDLSSGGetState('),
        'native_ui_authority.inc': between(ui, 'static bool NativeOwnerAvailable(', '\nstatic bool OwnsFrameGeneration('),
        'native_ui_save.inc': between(ui, 'template<class Configuration> static bool SaveNative(', '\n}\n}'),
        'native_advanced_mode.inc': between(menu, '        // Fixed ratios use the main Frame generation tiles.', '\n        auto fgOutput = '),
        'native_gpu_selector.inc': between(menu, 'static GpuInformation RenderingGpu(', 'static bool OptionalMfgOwnsFrameGeneration('),
        'native_config_payload.inc': between(config_header, '    struct NativeMfgSave ', '    bool SaveIni('),
        'native_config_values.inc': between(config, '        ini.SetValue("DLSSG", "OverrideInterpolationCount",', '\n        ini.SetValue("DLSSG", "ForceDMFG",'),
        'native_config_write.inc': between(config, '    const bool saved=SaveOwnedIni(ini, absoluteFileName);', '\n}\n\nbool Config::SaveMenuSettings('),
    }
    # SaveNative's last brace is the first line of the end delimiter.
    bodies['native_ui_save.inc'] += '\n}\n'
    msvc = Path(compiler).name.lower() in ('cl', 'cl.exe', 'clang-cl', 'clang-cl.exe')
    with tempfile.TemporaryDirectory(prefix='optishade-native-control-authority-') as temporary:
        directory = Path(temporary)
        for name, text in bodies.items():
            (directory / name).write_text(text, encoding='utf-8')
        includes = [directory, root / 'Beta/shared', project / 'hooks',
                    root / 'Beta/optiscaler/external/nlohmann',
                    root / 'Beta/optiscaler/external/streamline']
        binary = directory / ('native-control-authority.exe' if os.name == 'nt' else 'native-control-authority')
        if msvc:
            command = [compiler, '/nologo', '/std:c++20', '/EHsc', '/utf-8', '/W4', '/Od',
                       *['/I' + str(path) for path in includes],
                       str(HERE / 'native_control_authority_tests.cpp'), '/Fe:' + str(binary)]
        else:
            command = [compiler, '-std=c++20', '-O0', '-Wall', '-Wextra', '-pthread',
                       *['-I' + str(path) for path in includes],
                       str(HERE / 'native_control_authority_tests.cpp'), '-o', str(binary)]
        subprocess.run(command, cwd=directory, check=True)
        subprocess.run([str(binary)], cwd=directory, check=True)


if __name__ == '__main__':
    main()
