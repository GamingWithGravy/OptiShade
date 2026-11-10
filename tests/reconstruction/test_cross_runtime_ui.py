from pathlib import Path
import os

root=Path(os.environ.get('OPTISHADE_TEST_ROOT',Path(__file__).resolve().parents[2]))
gui=(root/'Beta/reshade/source/runtime_gui.cpp').read_text(encoding='utf-8')
manager=(root/'Beta/installer/manager.ps1').read_text(encoding='utf-8')
settings=(root/'Beta/installer/menu-settings.ps1').read_text(encoding='utf-8')
package=(root/'Beta/package.ps1').read_text(encoding='utf-8')

start=gui.index('void reshade::runtime::draw_gui_optishade()')
end=gui.index('void reshade::runtime::draw_gui()',start)
panel=gui[start:end]
for tab in ('Performance','Neural rendering','Image effects','Settings & status'):
    assert f'"{tab}"' in panel, f'missing x86 OptiShade page: {tab}'
assert 'draw_gui_home();' in panel, 'x86 Image Effects must use ReShade’s real preset/effect view'
assert 'draw_gui_settings();' in panel, 'x86 Settings must use ReShade’s real settings view'
assert 'OptiShade Legacy NR' in panel and 'addon_loaded_info' in panel and 'widget.callback(this)' in panel, 'x86 Neural Rendering must embed the loaded Legacy NR controls through the supported ReShade add-on API'
assert 'DirectX 9 needs a configured D3D11 wrapper' in panel, 'the x86 panel must state the D3D9 NR limitation'
assert '#if defined(_WIN64)' in gui and 'draw_gui_optishade();' in gui, 'the branded ReShade UI must be selected only for the x86 overlay route'
assert 'info.name.find("OptiShade Legacy NR")' in gui, 'the Legacy NR callback must not also open in a detached duplicate window'
assert '_overlay_key_data[0] = 0x2D' in gui, 'ReShade default menu must match OptiShade Manager Insert'
assert 'GetAsyncKeyState(static_cast<int>(_overlay_key_data[0]))' in gui, 'x86 overlay must recover the configured key when old games consume the window key edge'
assert '_imgui_context->ActiveId == 0' not in gui, 'a stale active ImGui widget must not prevent the menu shortcut from opening'
assert 'OptiShade ReShade overlay %s through %s input.' in gui, 'ReShade diagnostics must report when the legacy overlay is opened or closed'
open_overlay_start=gui.index('bool reshade::runtime::open_overlay(')
open_overlay_end=gui.index('\n}',open_overlay_start)
open_overlay=gui[open_overlay_start:open_overlay_end]
assert '#if defined(_WIN64)' in open_overlay and 'if (open)\n\t\treturn false;' in open_overlay, 'only the 64-bit runtime may suppress ReShade overlay opens; x86 needs this panel as its UI host'
assert 'const bool overlay_state_changed = open_overlay(show_overlay, show_overlay_source);' in gui and 'if (overlay_state_changed)' in gui, 'keyboard diagnostics must not claim the x86 menu opened when the runtime rejected the request'
assert 'KeyOverlay=45,0,0,0' in package, 'fresh ReShade config must store the Insert binding'
assert 'EffectSearchPaths=.\\OptiShadeData\\Shaders\\**,.\\reshade-shaders\\Shaders\\**' in package, 'game ReShade must retain legacy standard-shaders search path beside OptiShadeData'
assert 'TextureSearchPaths=.\\OptiShadeData\\Textures\\**,.\\reshade-shaders\\Textures\\**' in package, 'game ReShade must retain legacy standard-texture search path beside OptiShadeData'
assert 'EffectSearchPaths=.' in package and 'TextureSearchPaths=.' in package, 'isolated NR host must keep its own local search paths'
assert 'SetReShadeOverlayKey $reshadeIni $Primary' in settings, 'manager shortcut writes must reach ReShade32 configuration'
assert 'SupportsOptiScalerShortcuts' in manager, 'unsupported x86 OptiScaler shortcuts must be disabled in the manager'
assert 'panel::BeginSidebarPage(page)' in panel and 'panel::ShellHeader' in panel, 'legacy games must use the shared current OptiShade shell'
assert 'if (editor)' in panel and 'Active effects' in panel, 'keep detailed shader editing behind the effects page'
print('Cross-runtime OptiShade UI contract passed.')
