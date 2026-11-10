#!/usr/bin/env python3
"""Bind an extracted/verified installer to native outputs and private symbols.

No installer is launched here, no game is inspected, and no qualification is granted.
Run after TestOptiShadeFinalPackage. The receipt is immutable: choose a new output.
"""
import argparse
import hashlib
import json
import subprocess
import os
from pathlib import Path
from datetime import datetime, timezone

from symbol_identity import verify


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest().upper()


def same_build_time(left, right):
    """Compare equivalent UTC timestamps across .NET's 7-digit and Python's 6-digit ISO formats."""
    try:
        def parse(value):
            if not isinstance(value, str) or 'T' not in value:
                return None
            return datetime.fromisoformat(value.replace('Z', '+00:00')).astimezone(timezone.utc)
        a, b = parse(left), parse(right)
        if a is None or b is None:
            return left == right
        return a == b
    except (ValueError, OverflowError):
        return False


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def contained(root, relative):
    path = (root / relative).resolve()
    if not path.is_relative_to(root.resolve()):
        raise ValueError('Artifact escapes source root: ' + relative)
    return path


def verified_repack_identity(root):
    # Re-run the same allowlist, current-source and native-hash checks as packaging.
    command = "$ErrorActionPreference='Stop'; $r=$env:OPTISHADE_RECEIPT_ROOT; . (Join-Path $r 'build-identity.ps1'); AssertOptiShadeCandidateBuild $r -ManagerOnlyRepack | ConvertTo-Json -Depth 8 -Compress"
    env = dict(os.environ, OPTISHADE_RECEIPT_ROOT=str(root))
    # Toolchain bootstrap scripts can replace PSModulePath with a reduced
    # mirror. Ensure the child Windows PowerShell can import the standard
    # Microsoft.PowerShell.Utility module that provides Get-FileHash.
    module_paths = []
    user_profile = env.get('USERPROFILE')
    program_files = env.get('ProgramFiles')
    windir = env.get('WINDIR')
    if user_profile:
        module_paths.append(str(Path(user_profile) / 'Documents/WindowsPowerShell/Modules'))
    if program_files:
        module_paths.append(str(Path(program_files) / 'WindowsPowerShell/Modules'))
    if windir:
        module_paths.append(str(Path(windir) / 'System32/WindowsPowerShell/v1.0/Modules'))
    env['PSModulePath'] = os.pathsep.join(module_paths)
    result = subprocess.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', command],
                            env=env, capture_output=True, text=True, check=True)
    return json.loads(result.stdout)


def create(root, executable):
    native_path = root / 'test-run/native-build.json'
    verification_path = Path(str(executable) + '.verification.json')
    native, checked = read(native_path), read(verification_path)
    build = checked['Build']
    if checked.get('Passed') is not True or checked.get('ExecutableSHA256', '').upper() != sha256(executable):
        raise ValueError('Installer verification is failed or belongs to another executable')
    identity = native
    if build.get('BuildMode') == 'ManagerOnlyRepackVerifiedRuntime':
        identity = verified_repack_identity(root)
        for key in ('BuildMode', 'NativeBuildSourceSHA256', 'ManagerOnlyChanges'):
            if not identity.get(key) or build.get(key) != identity[key]:
                raise ValueError('Repack identity mismatch: ' + key)
    for key in ('SourceSHA256', 'BuildInputsSHA256', 'SourceHead'):
        if not identity.get(key) or build.get(key) != identity[key]:
            raise ValueError('Embedded/native identity mismatch: ' + key)
    if not native.get('BuiltUtc') or not same_build_time(build.get('BuiltUtc'), native['BuiltUtc']):
        raise ValueError('Embedded/native identity mismatch: BuiltUtc')
    if build.get('NativeBinaries') != native.get('Binaries') or not native.get('Binaries'):
        raise ValueError('Embedded/native artifact inventory mismatch')
    artifacts = []
    symbols = []
    for name, expected in sorted(native['Binaries'].items()):
        path = contained(root, name)
        actual = sha256(path)
        if actual != expected.upper():
            raise ValueError('Native artifact changed after build: ' + name)
        artifacts.append({'Path': name, 'SHA256': actual, 'Bytes': path.stat().st_size})
        if name.endswith('.pdb'):
            binary_name = name[:-4] + '.dll'
            if binary_name not in native['Binaries']:
                raise ValueError('No stamped binary for symbols: ' + name)
            identity = verify(contained(root, binary_name), path)
            symbols.append({'Binary': binary_name, 'Symbols': name, **identity})
    if not symbols:
        raise ValueError('No verified native symbol pairs')
    result = {
        'Schema': 1, 'CreatedUtc': datetime.now(timezone.utc).isoformat(),
        'Scope': 'Owner/tester candidate identity only; game, physical output, VR and HDR qualification remain pending',
        'Executable': {'Name': executable.name, 'SHA256': sha256(executable), 'Bytes': executable.stat().st_size},
        'Build': build, 'NativeArtifacts': artifacts, 'MatchingSymbols': symbols,
        'Evidence': [
            {'Role': 'Final executable extraction verification', 'Name': verification_path.name, 'SHA256': sha256(verification_path)},
            {'Role': 'Native build receipt', 'Name': 'test-run/native-build.json', 'SHA256': sha256(native_path)},
        ],
        'GameQualification': 'Not run by packaging',
        'TestInstructions': 'reconstruction/TESTER_CANDIDATE_CHECKLIST.md',
    }
    checklist = root / result['TestInstructions']
    result['Evidence'].append({'Role': 'Owner test sequence', 'Name': result['TestInstructions'], 'SHA256': sha256(checklist)})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--executable', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = create(args.root.resolve(), args.executable.resolve())
    with args.output.open('x', encoding='utf-8') as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')
    print('Candidate receipt verified:', args.output)


if __name__ == '__main__':
    main()
