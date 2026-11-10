"""Check the clean NR package's declared inputs and producer dependencies.

This is a package/source contract, not shader execution or a game-output test.
The old loose CC BY-NC helper must not silently become a mandatory NR dependency.
"""
from pathlib import Path
import json
import os

root = Path(os.environ.get('OPTISHADE_TEST_ROOT', Path(__file__).resolve().parents[2]))
channel = root / 'Beta'
definition = json.loads((channel / 'package-inputs.json').read_text(encoding='utf-8'))
entries = definition['Groups']['Effects']

def is_legacy_guide(path):
    value = str(path).replace('\\', '/').lower()
    return '/optishadetaa/' in '/' + value or value.endswith('/vort_bluenoise.png')

obsolete = [entry for entry in entries
            if is_legacy_guide(entry['Source']) or is_legacy_guide(entry['Target'])]
assert not obsolete, f'Obsolete loose guides remain in the clean package: {obsolete}'
assert len({entry['Target'].lower() for entry in entries}) == len(entries)

# Wiring, not GPU acceptance: the replacement runs before cosmetic early exits.
runtime = (channel / 'reshade/source/runtime.cpp').read_text(encoding='utf-8')
body = runtime[runtime.index('void reshade::runtime::render_effects('):]
assert body.index('osguide::Run(') < body.index('if(!osfx_impl::CanRender(')
assert body.index('osguide::Run(') < body.index('if(!_effects_enabled')
core = (channel / 'reshade/res/shaders/optishade_guides.hlsl').read_text(encoding='utf-8')
assert '#include' not in core and 'vort_' not in core
assert all(f'void {stage}(' in core for stage in ('Prepare', 'Estimate', 'Resolve'))

# The x86 feed ships its standard include independently of the removed payload.
feed = (channel / 'legacy-nr/upstream/shaders/DLSS5_Feed.fx').read_text(encoding='utf-8')
assert 'OptiShadeTaa/' not in feed and 'vort_BlueNoise.png' not in feed
package = (channel / 'package.ps1').read_text(encoding='utf-8')
assert '/legacy-nr/upstream/shaders/DLSS5_Feed.fx' in package
assert '/OptiShadeData/Shaders/LegacyNR/ReShade.fxh' in package

# Removal from a payload does not relicense the archived shader.
notice = 'installer/DefaultEffects/Licenses/OptiShade-TAA-THIRD-PARTY.txt'
assert any(entry['Source'] == notice for entry in entries)
assert 'CC BY-NC' in (channel / notice).read_text(encoding='utf-8')
policy = (channel / 'installer/component-policy.ps1').read_text(encoding='utf-8-sig')
assert 'OptiShadeTaa/' not in policy and 'vort_BlueNoise.png' not in policy
print('Core guide package contract passed: no obsolete loose guide/texture inputs; '
      'embedded producer and independent legacy feed dependencies retained. No GPU test.')
