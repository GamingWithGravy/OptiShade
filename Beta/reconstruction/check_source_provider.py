#!/usr/bin/env python3
"""Reject source-built MFG payloads that do not match their recorded inputs.
Read-only check. No SDK acquisition, binary patching, receipt rewriting or launch.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re

HEX=re.compile(r"^[0-9a-fA-F]{64}$")
def digest(path: Path) -> str:
    with path.open('rb') as stream:
        value=hashlib.sha256()
        for block in iter(lambda:stream.read(1024*1024),b''):value.update(block)
    return value.hexdigest()

def object_no_duplicates(pairs):
    result={}
    for key,value in pairs:
        if key in result:raise ValueError(f'Duplicate manifest key: {key}')
        result[key]=value
    return result

def contained(root: Path,name: str) -> Path:
    rel=PurePosixPath(name)
    if not name or '\\' in name or ':' in name or rel.is_absolute() or '..' in rel.parts:
        raise ValueError(f'Invalid recorded source path: {name}')
    path=root.joinpath(*rel.parts)
    if not path.resolve().is_relative_to(root.resolve()):raise ValueError(f'Path escapes source root: {name}')
    if path.is_symlink():raise ValueError(f'Source must not be a symbolic link: {name}')
    return path

def verify_runtime_group(channel: Path, manifest: dict) -> dict:
    group=manifest.get('RuntimeGroup')
    if not isinstance(group,dict):raise ValueError('MFG runtime compatibility-group receipt is missing')
    streamline=json.loads((channel/'installer/streamline-files.json').read_text(encoding='utf-8-sig'),object_pairs_hook=object_no_duplicates)
    nvidia=json.loads((channel/'installer/nvidia-files.json').read_text(encoding='utf-8-sig'),object_pairs_hook=object_no_duplicates)
    dlssg=[item for item in nvidia if isinstance(item,dict) and item.get('Name','').casefold()=='nvngx_dlssg.dll']
    if len(dlssg)!=1:raise ValueError('Bundled DLSS-G runtime identity is ambiguous')
    expected={'streamlineVersion':str(streamline.get('version','')),
              'streamlineArchiveSha256':str(streamline.get('archiveSha256','')),
              'dlssgVersion':str(dlssg[0].get('Version','')),
              'dlssgSha256':str(dlssg[0].get('SHA256',''))}
    for key,value in expected.items():
        if not value or group.get(key)!=value:raise ValueError(f'MFG/runtime compatibility group mismatch: {key}')
    return expected

def verify(channel: Path,symbols: Path|None=None,sdk_root: Path|None=None) -> dict:
    root=channel/'installer/OptionalMFG'
    manifest=json.loads((root/'source-build.json').read_text(encoding='utf-8-sig'),object_pairs_hook=object_no_duplicates)
    if manifest.get('schema')!=1 or manifest.get('abi')!=131072:
        raise ValueError('Unknown source-MFG manifest/ABI; do not guess the contract')
    runtime_group=verify_runtime_group(channel,manifest)
    expected=manifest.get('sha256','')
    if not isinstance(expected,str) or not HEX.fullmatch(expected):raise ValueError('Invalid provider DLL hash')
    if digest(root/'OptiShadeMFG.dll').lower()!=expected.lower():raise ValueError('Provider DLL differs from source-build.json')
    inputs=manifest.get('SourceFiles')
    if not isinstance(inputs,dict) or not inputs:raise ValueError('Source input inventory is missing')
    source=root/'Source203040'
    for name,value in inputs.items():
        if not isinstance(value,str) or not HEX.fullmatch(value):raise ValueError(f'Invalid source hash: {name}')
        if digest(contained(source,name)).lower()!=value.lower():raise ValueError(f'Stale MFG payload: source changed: {name}')
    actual={path.relative_to(source).as_posix() for path in source.rglob('*') if path.is_file()}
    if actual!=set(inputs):raise ValueError('MFG source inventory changed; rebuild the provider before packaging')
    header=(channel/'shared/SourceMfgIdentity.h').read_text(encoding='utf-8-sig')
    pin=re.findall(r'kSourceDllSha256\[\]\s*=\s*"([0-9a-fA-F]{64})"',header)
    if len(pin)!=1 or pin[0].lower()!=expected.lower():raise ValueError('Runtime/provider DLL pin mismatch')
    installer=(channel/'installer/mfg.ps1').read_text(encoding='utf-8-sig')
    pin=re.findall(r'\$script:SourceMfgSha256\s*=\s*"([0-9a-fA-F]{64})"',installer)
    if len(pin)!=1 or pin[0].lower()!=expected.lower():raise ValueError('Installer/provider DLL pin mismatch')
    declared_symbols=manifest.get('SymbolsSHA256','')
    if not isinstance(declared_symbols,str) or not HEX.fullmatch(declared_symbols):raise ValueError('Matching-symbol identity is not recorded')
    symbol_result='identity recorded; PDB bytes not supplied to this check'
    if symbols:
        if digest(symbols).lower()!=declared_symbols.lower():raise ValueError('PDB does not match provider build receipt')
        symbol_result='matching PDB bytes verified'
    sdk_result='recorded SDK hashes retained; SDK tree not supplied to this check'
    if sdk_root:
        headers=manifest.get('SdkHeaders',{})
        if not headers:raise ValueError('SDK input inventory missing')
        for name,value in headers.items():
            if digest(contained(sdk_root,name)).lower()!=str(value).lower():raise ValueError(f'SDK header changed: {name}')
        sdk_result='recorded SDK header bytes verified'
    return {'source_files_verified':len(inputs),'dll_sha256':expected.lower(),'runtime_group':runtime_group,'symbols':symbol_result,'sdk':sdk_result,
            'hardware_validation':'not performed by a source identity check'}

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--channel',type=Path,default=Path(__file__).resolve().parents[1])
    parser.add_argument('--symbols',type=Path)
    parser.add_argument('--sdk-root',type=Path)
    args=parser.parse_args()
    print(json.dumps(verify(args.channel,args.symbols,args.sdk_root),indent=2))
if __name__=='__main__':
    try:main()
    except (OSError,ValueError,TypeError) as error:
        raise SystemExit(f'MFG identity check failed: {error}\nRebuild with installer/OptionalMFG/build-source203040.ps1 and the approved SDK, then rebuild the candidate. No files were changed.')
