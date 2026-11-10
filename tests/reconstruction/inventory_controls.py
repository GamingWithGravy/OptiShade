"""Inventory real native controls and NR bindings; not visual acceptance evidence."""
from pathlib import Path
import re

ROOT=Path(__file__).resolve().parents[2]
PROJECT=ROOT/'Beta/optiscaler/OptiScaler'
OUT=ROOT/'MDs/Reconstruction/CONTROL_INVENTORY.md'

def main():
 sources=[PROJECT/'menu/menu_common.cpp',PROJECT/'menu/optishade_effects_ui.inl',PROJECT/'dlssnr/DlssNr_Menu.cpp']
 replacements=[PROJECT/'menu/OptiShadePanel.inl',PROJECT/'menu/optishade_mfg_ui.inl',PROJECT/'menu/optishade_effects_ui.inl',PROJECT/'dlssnr/DlssNrPanel.inl',*sorted(PROJECT.glob('*/reconstruction/*.inl'))]
 contents={p:p.read_text(encoding='utf-8') for p in replacements if p.exists()}
 lines=['# Native control and binding inventory','',
 'Generated from the pinned legacy views and the active R1/R2 adapters. This is a source inventory, not proof that every control is visible, reachable or correctly laid out. Dynamic shader annotations remain owned by the existing FX backend; they are not replaced with invented controls.','',
 'The generated fragments remain transitional. Their build selection is verified in `test-results/compile-selection.json`; replacement with permanent modules still needs native render/configuration acceptance.','',
 '## NR persisted properties','',
 '| Property | Active adapter/fragment | Evidence |','|---|---|---|']
 old=sources[2].read_text(encoding='utf-8');old=old[old.index('void RenderMenu(Config* config, float menuResScale)'):]
 properties=sorted(set(re.findall(r'config->(\w+)',old)))
 for prop in properties:
  homes=[str(p.relative_to(ROOT)).replace('\\','/') for p,t in contents.items() if re.search(r'config->'+re.escape(prop)+r'\b',t)]
  lines.append('| `'+prop+'` | '+'; '.join('`'+p+'`' for p in homes)+' | Exact property retained; source regression. Native interaction pending |')
 lines+=['','## Original literal controls','',
 'Locations below identify the original owner/binding for review. A matching label is navigation evidence only; unmatched labels require semantic comparison (several master controls were deliberately consolidated). Helpers called by these views and dynamic labels still require their own interaction coverage.','',
 '| Original source | Widget / label | Active matching location |','|---|---|---|']
 pattern=re.compile(r'(?:ImGui::)?(Checkbox|Combo|Slider\w*|DeferredSlider|Button|SmallButton|Input\w*|CollapsingHeader|Selectable)\(\s*"([^"\n]+)"')
 count=0
 for source in sources:
  for n,line in enumerate(source.read_text(encoding='utf-8').splitlines(),1):
   for match in pattern.finditer(line):
    count+=1;label=match[2]
    homes=[str(p.relative_to(ROOT)).replace('\\','/') for p,t in contents.items() if '"'+label+'"' in t]
    lines.append('| `'+str(source.relative_to(ROOT)).replace('\\','/')+':'+str(n)+'` | '+match[1]+' / '+label.replace('|',' / ')+' | '+('; '.join('`'+p+'`' for p in homes) if homes else 'Semantic mapping/reachability review outstanding')+' |')
 lines+=['','## Remaining acceptance gaps','',
 '- Desktop manager remains the pre-v2 layout; its installer commands must be adapted without weakening ownership checks.',
 '- Exact main actions/preset ordering, paired hotswap placement, cross-tab review/undo and every search destination are not accepted yet.',
 '- NR bindings are source-preserved; runtime-safe writes, session reset and native screenshots still require the prescribed simulator matrix.',
 '- The new Colour search target opens its parent and target group and requests scroll/focus. Other search aliases still need full native interaction coverage.',
 '- No screenshot from the HTML prototype is evidence of the native implementation.','']
 OUT.write_text('\n'.join(lines),encoding='utf-8')
 print(f'{len(properties)} NR properties; {count} literal control occurrences inventoried')

if __name__=='__main__':main()
