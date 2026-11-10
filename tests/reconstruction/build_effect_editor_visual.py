from pathlib import Path
import subprocess
r=Path.cwd();im=r/'Beta/optiscaler/OptiScaler/include/imgui'
s=(r/'Beta/optiscaler/OptiScaler/menu/optishade_effects_ui.inl').read_text()
start=s.index(' static optishade::effects_ui::EditorCache cache;');end=s.index(' }ImGui::EndDisabled();',start)
body=s[start:end].replace('auto send=module?(osfx::Send)GetProcAddress(module,"OptiShadeEffectsSend"):nullptr;','auto send=&MockSend;')
base=(r/'tests/reconstruction/native_visual.cpp').read_text()
pre=r'''
#include "EffectEditorCache.h"
#include "EffectReadiness.h"
#include <filesystem>
#include <unordered_set>
#include <map>
static osfx::Snapshot fx{};
static char feedback[8192]="Fixture transport - values are not being sent to a game";
static std::map<std::string,optishade::fxready::Request> preparing;
static std::vector<std::filesystem::path> library{"Bloom.fx","ColourGrade.fx","LumaSharpen.fx"};
static bool Send(osfx::Command){return true;}
static bool MockSend(const osfx::Command* c,uint32_t){
 fx.inspectSerial=c->inspectSerial;fx.uniformPage=c->enabled;strcpy_s(fx.inspectedEffect,c->effect);
 fx.uniformTotal=fx.uniforms=2;
 for(unsigned i=0;i<2;i++){auto& u=fx.uniform[i];u={};strcpy_s(u.effect,c->effect);strcpy_s(u.name,i?"Threshold":"Strength");strcpy_s(u.label,u.name);u.count=1;u.hasRange=1;u.maximum=2;u.value[0]=i?.015f:.15f;}
 return true;
}
'''
# Extract the production switch and editor rendering verbatim; mock only transport.
a=s.index('static bool EffectSwitch(');b=s.index('static void RememberMainPreset',a)
pre+=s[a:b]+'\nstatic void RenderEditor(){\n'+body+'\n}\n'
base=base.replace('int main(',pre+'\nint main(')
base=base.replace('frame<4','frame<20')
a=base.index('  using namespace optishade::panel;');b=base.index('ImGui::Render();',a)
base=base[:a]+r'''
  using namespace optishade::panel;
  fx.generation=1;fx.enabled=1;fx.dirty=1;fx.techniques=3;fx.compileOK=1;
  for(unsigned i=0;i<3;i++){strcpy_s(fx.technique[i].effect,library[i].filename().string().c_str());fx.technique[i].enabled=1;}
  PageTitle("Look editor","Toggle shaders, type exact values and preview your look.");ImGui::Button("Back to Image effects");
  ImGui::BeginChild("Shader editor content",ImVec2(0,-ImGui::GetFontSize()*3.5f),ImGuiChildFlags_AlwaysUseWindowPadding);
  for(const auto& p:library){ImGui::PushID(p.string().c_str());ImGui::GetStateStorage()->SetInt(ImGui::GetID(p.filename().string().c_str()),1);ImGui::PopID();}
  if(selectedPage==9&&frame>15)ImGui::SetScrollY(320);
  RenderEditor();ImGui::EndChild();ImGui::Separator();ImGui::Button("Save look");ImGui::SameLine();ImGui::Button("Discard changes");
  ImGui::PopFontSize();ImGui::End();'''+base[b:]
out=r/'test-results/r22-editor-visual.cpp';out.write_text(base)
c=['cl','/nologo','/std:c++17','/EHsc','/utf-8','/DIMGUI_USER_CONFIG="test_imgui_config.h"',*['/I'+str(r/p) for p in ['Beta/shared','Beta/optiscaler/OptiScaler/include','tests/reconstruction']],'/I'+str(im),str(out),*[str(im/n) for n in ['imgui.cpp','imgui_draw.cpp','imgui_tables.cpp','imgui_widgets.cpp','imgui_impl_dx11.cpp']],'/Fe:'+str(r/'test-results/r22-editor-visual.exe'),'/Fo:'+str(r/'test-results')+'\\','/link','d3d11.lib','d3dcompiler.lib']
subprocess.run(c,check=True)
for w,h,page in [(1100,850,2),(760,650,9)]:subprocess.run([str(r/'test-results/r22-editor-visual.exe'),str(r/f'test-results/r22-editor-{w}.bmp'),str(w),str(h),str(page)],check=True)
