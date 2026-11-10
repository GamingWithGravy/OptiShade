#!/usr/bin/env python3
"""Read-only native-view wiring/binding checks. No legacy source regeneration."""
from pathlib import Path
import argparse
import json
import re
import xml.etree.ElementTree as ET


def verify(channel):
    channel=Path(channel).resolve();project=channel/'optiscaler/OptiScaler'
    contract=json.loads((channel/'reconstruction/native-view-contract.json').read_text(encoding='utf-8-sig'))
    def read(name):
        p=project/name
        if p.is_symlink() or not p.resolve().is_relative_to(project.resolve()):
            raise ValueError('native source escapes project: '+name)
        return p.read_text(encoding='utf-8-sig')
    for record in contract['files']:
        text=read(record['source'])
        if '.generated.inl' in text or '.reconstruction.generated.' in text:
            raise ValueError('obsolete generated include: '+record['source'])
    nr=read('dlssnr/DlssNrPanel.inl')+''.join(read(r['source']) for r in contract['files'] if r['source'].startswith('dlssnr/reconstruction/'))
    fields=set(re.findall(r'config->(\w+)',nr))
    missing=set(contract['nr_required_fields'])-fields
    if missing:raise ValueError('missing native NR bindings: '+','.join(sorted(missing)))
    startup=read('dllmain.cpp')
    for call in ('optishade::mfg::StartUiStatus();','optishade::control::StartRuntimeControl(sourceMfgReserved);'):
        if startup.count(call)!=1:raise ValueError('runtime startup binding count: '+call)
    ns={'m':'http://schemas.microsoft.com/developer/msbuild/2003'}
    tree=ET.parse(project/'OptiScaler.vcxproj')
    compiled=[n.attrib['Include'].replace('\\','/') for n in tree.findall('.//m:ClCompile',ns) if 'Include' in n.attrib]
    for source in ('menu/menu_common.cpp','dlssnr/DlssNr_Menu.cpp','dllmain.cpp'):
        if compiled.count(source)!=1:raise ValueError('native compile count: '+source)
    targets=(channel/'reconstruction/OptiShade.Reconstruction.targets').read_text(encoding='utf-8-sig')
    if 'generate_views.py' in targets or 'reconstruction.generated' in targets or '<ClCompile Remove=' in targets:
        raise ValueError('legacy build replacement remains')
    return {'native_sources':len(contract['files']),'required_nr_bindings':len(contract['nr_required_fields']),
            'legacy_generation':False,'scope':'source/build binding only, not simulator acceptance'}


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--channel',type=Path,default=Path(__file__).resolve().parents[1])
    args=parser.parse_args()
    try:print(json.dumps(verify(args.channel),indent=2))
    except (OSError,ValueError) as error:raise SystemExit('Native view verification failed: '+str(error))
