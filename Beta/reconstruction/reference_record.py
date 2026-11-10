#!/usr/bin/env python3
"""WP0: bind a manually observed reference run to exact files, without changing a game.

This does not diagnose a failure or certify live output. Unknown fields stay unknown;
the result lists missing gate evidence. Loaded modules require a process-bound capture,
not an installer inventory. No recursive disk scan, upload or simulator launch occurs.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
from datetime import datetime, timezone

REQUIRED = ('simulator.version', 'simulator.api', 'gpu.rendering_luid', 'gpu.device_id',
            'gpu.driver', 'display.mode', 'display.resolution', 'display.hdr',
            'display.refresh_hz', 'display.vrr', 'providers.game_aa',
            'providers.sr', 'providers.fg', 'nr.requested', 'nr.effective_passes',
            'nr.configured_passes', 'deployment.channel', 'deployment.kind',
            'deployment.previous_build', 'deployment.policy', 'scene.aircraft',
            'scene.location', 'scene.weather', 'result.reproduction')
STEPS = ('load', 'stationary_cockpit', 'camera_pan', 'cockpit_exterior',
         'menu_open_close', 'preset_change', 'return_to_menu')
HASH = re.compile(r'^[a-fA-F0-9]{64}$')

def get(data, key):
    for part in key.split('.'):
        if not isinstance(data, dict): return None
        data = data.get(part)
    return data

def hash_file(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024*1024), b''):
            digest.update(block)
    return digest.hexdigest()

def record(scenario, root):
    if scenario.get('schema') != 1: raise ValueError('Unknown scenario schema')
    def unknown(value):
        return value is None or (isinstance(value,str) and value.strip().lower() in ('','unknown'))
    missing = [key for key in REQUIRED if unknown(get(scenario,key))]
    kind = get(scenario,'deployment.kind')
    if kind not in ('clean','upgrade','channel-migration','legacy-receipt','unknown'):
        raise ValueError('Deployment kind must identify clean/upgrade/migration/legacy explicitly')
    if get(scenario,'result.reproduction') not in ('reproduced','not-reproduced','not-run'):
        raise ValueError('Record reproduced, not-reproduced or not-run; no inferred pass')
    if kind == 'clean' and get(scenario,'deployment.previous_build') != 'none':
        raise ValueError('Clean install must explicitly record previous_build=none')
    files=[]
    for item in scenario.get('files',[]):
        name=item['path']; path=(root/name).resolve()
        if not path.is_relative_to(root.resolve()): raise ValueError('Artifact path escapes the supplied evidence root')
        expected=item.get('expected_sha256')
        if not isinstance(expected,str) or not HASH.fullmatch(expected): raise ValueError('Every artifact needs a pinned expected SHA256')
        actual=hash_file(path)
        files.append({'role':item['role'],'path':name,'sha256':actual,'bytes':path.stat().st_size,
                      'expected_sha256':expected.lower(),'matches':actual==expected.lower()})
        if actual!=expected.lower(): missing.append('artifact mismatch: '+name)
    roles={f['role'] for f in files}
    for role in ('installer','runtime','provider','symbols','addon','configuration','loaded_modules'):
        if role not in roles: missing.append('file role: '+role)
    process=scenario.get('process',{})
    if not process.get('pid') or not process.get('started_utc') or not process.get('captured_utc'):
        missing.append('process-bound loaded module capture')
    for step in STEPS:
        observed=scenario.get('sequence',{}).get(step,{})
        if observed.get('outcome') not in ('reproduced','not-reproduced') or not observed.get('evidence'):
            missing.append('sequence: '+step)
    if get(scenario,'result.reproduction') == 'not-run': missing.append('reference scenario not run')
    return {'schema':1,'created_utc':datetime.now(timezone.utc).isoformat(),
            'scope':'Reference identification/reproduction evidence only; not a stability certificate',
            'scenario':scenario,'artifacts':files,'missing_evidence':missing,
            'identification_gate':'incomplete' if missing else 'recorded; review the cited evidence',
            'simulator_pass':False}

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scenario',type=Path,required=True)
    parser.add_argument('--evidence-root',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    result=record(json.loads(args.scenario.read_text(encoding='utf-8-sig')),args.evidence_root)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    # Never replace a previous run's evidence.
    with args.output.open('x',encoding='utf-8') as output: json.dump(result,output,indent=2)
    print(f"{result['identification_gate']}: {len(result['missing_evidence'])} missing items; {args.output}")
if __name__ == '__main__': main()
