#ifndef NOMINMAX
#define NOMINMAX
#endif
// Native ImGui/WARP visual fixture. Uses production NR presentation, no simulator or installation.
#include "PanelUi.h"
#include "EffectNumericUi.h"
#include <imgui/imgui_impl_dx11.h>
#include <d3d11.h>
#include <wrl/client.h>
#include <fstream>
#include <stdexcept>
#include <iostream>
using Microsoft::WRL::ComPtr;
static void Check(HRESULT hr){if(FAILED(hr))throw std::runtime_error("D3D11 fixture failed");}
int main(int argc,char**argv){try{
 if(argc<2)return 2;int width=argc>2?atoi(argv[2]):560,height=argc>3?atoi(argv[3]):1100;int selectedPage=argc>4?atoi(argv[4]):1;
 ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> context;
 Check(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_WARP,nullptr,0,nullptr,0,D3D11_SDK_VERSION,&device,nullptr,&context));
 D3D11_TEXTURE2D_DESC desc{};desc.Width=width;desc.Height=height;desc.MipLevels=desc.ArraySize=1;desc.Format=DXGI_FORMAT_B8G8R8A8_UNORM;desc.SampleDesc.Count=1;desc.Usage=D3D11_USAGE_DEFAULT;desc.BindFlags=D3D11_BIND_RENDER_TARGET;
 ComPtr<ID3D11Texture2D> texture;Check(device->CreateTexture2D(&desc,nullptr,&texture));ComPtr<ID3D11RenderTargetView> target;Check(device->CreateRenderTargetView(texture.Get(),nullptr,&target));
 ImGui::CreateContext();auto& io=ImGui::GetIO();io.DisplaySize={(float)width,(float)height};io.DeltaTime=1.f/60;io.IniFilename=io.LogFilename=nullptr;
 io.Fonts->AddFontFromFileTTF("C:/Windows/Fonts/segoeui.ttf",18.f);auto& style=ImGui::GetStyle();optishade::panel::ApplyDefaultTheme(style,1.f);style.WindowPadding={18,16};style.FramePadding={10,7};style.ItemSpacing={10,9};style.WindowRounding=14;style.FrameRounding=7;
 ImFontConfig headingConfig;strcpy_s(headingConfig.Name,"OptiShade Semibold");io.Fonts->AddFontFromFileTTF("C:/Windows/Fonts/seguisb.ttf",18.f,&headingConfig);
 if(!ImGui_ImplDX11_Init(device.Get(),context.Get()))throw std::runtime_error("ImGui D3D11 initialization failed");
 for(int frame=0;frame<4;++frame){
  ImGui_ImplDX11_NewFrame();ImGui::NewFrame();ImGui::SetNextWindowPos({0,0});ImGui::SetNextWindowSize({(float)width,(float)height});
  ImGui::Begin("Native visual fixture",nullptr,ImGuiWindowFlags_NoTitleBar|ImGuiWindowFlags_NoResize);ImGui::PushFontSize(18.f);if(frame==3)std::cout<<"font-size="<<ImGui::GetFontSize()<<" scale="<<io.FontGlobalScale<<"\n";
  using namespace optishade::panel;bool visible=true;int page=selectedPage;ShellHeader("NATIVE UI FIXTURE","DirectX 11 WARP . no simulator",visible,page);BeginSidebarPage(page);
  ImGui::PushStyleColor(ImGuiCol_ChildBg,ImVec4(0,0,0,0));ImGui::BeginChild("Content",{0,-99});
  if(page==1)DrawNr({false,"Off for this session","Your tuning is kept. Your look and frame generation are unchanged.","1 pass . automatic placement"},[](bool){},[]{Appearance([]{int look=1;const char* looks[]={"Standard","Natural","Cinematic"};ImGui::Combo("##NR look",&look,looks,3);},[]{float strength=1;StrengthTrack("##NR strength",&strength,0,2);ImGui::SameLine();ImGui::Button("1.00",ImVec2(50,ImGui::GetFrameHeight()));});},[]{},[]{},[]{});
  if(page==0){PageTitle("Performance","Upscaling and smoother motion. Neural rendering has its own tab.");Card("Upscaling card",[]{CardHeading("IMAGE UPSCALING","");SettingRow("Control","Leave the game in charge, or request an override.",[]{int value=0;const char* choices[]={"Game settings"};ImGui::Combo("##upscale-control",&value,choices,1);});ImGui::Separator();ImGui::TextWrapped("Reconstructs a larger picture from a smaller one. Fine text can look different.");});Card("Frame generation card",[]{CardHeading("FRAME GENERATION","");SettingRow("Control","Extra frames can make movement look smoother.",[]{int value=0;const char* choices[]={"Follow game"};ImGui::Combo("##fg-mode",&value,choices,1);});ImGui::Separator();ImGui::TextUnformatted("Output multiplier");for(int n=2;n<=6;++n){if(n>2)ImGui::SameLine();ImGui::BeginDisabled();ImGui::Button((std::to_string(n)+"x").c_str(),{84,35});ImGui::EndDisabled();}ImGui::TextWrapped("No provider connected in this UI fixture.");ImGui::Separator();if(ImGui::BeginTable("Frame rate cards",2,ImGuiTableFlags_SizingStretchSame)){ImGui::TableNextColumn();Card("Game FPS",[]{ImGui::TextDisabled("GAME FRAME RATE");ImGui::TextUnformatted("Not observed");});ImGui::TableNextColumn();Card("Presented FPS",[]{ImGui::TextDisabled("DISPLAYED FRAME RATE");ImGui::TextUnformatted("Not observed");});ImGui::EndTable();}});Group("Advanced performance",Section::Quality,"Tuning, diagnostics and experimental options");}
  if(page==2){PageTitle("Image effects","Choose a saved look or open the editor to create your own.");Card("Saved look card",[]{CardHeading("SAVED LOOK","");bool enabled=false;Toggle("Image effects enabled",&enabled);ImGui::TextDisabled("Applies your saved look and active shaders.");ImGui::Separator();SettingRow("Preset","Your image effects preset is separate from neural rendering.",[]{int v=0;const char* choices[]={"No runtime connected"};ImGui::Combo("##Look presets",&v,choices,1);},.65f);ImGui::TextWrapped("Choose a saved look here. Open the editor to browse shaders, toggle effects and type exact values.");ImGui::Button("Open look editor",ImVec2(-1,ImGui::GetFrameHeight()*1.5f));});}
  if(page==5){PageTitle("Monitoring","Keep frame rates and hardware readings visible while you play.");Card("Hardware monitor controls",[]{CardHeading("HARDWARE MONITOR","");bool enabled=false;Toggle("Show hardware monitor",&enabled);SettingRow("Detail level","Choose how much information to show.",[]{int v=0;const char* labels[]={"Simple","Normal","Advanced"};ImGui::Combo("##detail",&v,labels,3);});ImGui::TextWrapped("No sensor provider connected in this fixture.");});Card("FPS overlay controls",[]{CardHeading("FPS OVERLAY","");bool enabled=false;Toggle("Show FPS overlay",&enabled);ImGui::Button("Save monitoring settings");});}
  if(page==3){PageTitle("Settings & status","Menu preferences, shortcuts and health.");SettingsAppearance([]{int a=0;const char* names[]={"Purple","Blue","Teal"};ImGui::Combo("##theme-accent",&a,names,3);},[]{float a=85;ImGui::SetNextItemWidth(std::max(50.f,ImGui::GetContentRegionAvail().x-ImGui::GetFontSize()*4.f));StrengthTrack("##menu-opacity",&a,20,100);ImGui::SameLine();Keycap("85%");},[]{bool compact=false;Toggle("Compact helper text",&compact);});SettingsShortcuts("Insert","Ctrl+Shift+O","Not set",[]{});SettingsStatus("Not observed","D3D11 WARP","Beta","Native UI fixture");Group("Help, updates & troubleshooting",Section::Status,"Menu sizing, shortcuts, diagnostics and support");}
  ImGui::EndChild();ImGui::PopStyleColor();ShellFooter("No pending changes",false,false,false,"Insert","Ctrl+Shift+O",[]{},[]{},[]{});
  EndSidebarPage();ImGui::PopFontSize();ImGui::End();ImGui::Render();
  auto* rtv=target.Get();context->OMSetRenderTargets(1,&rtv,nullptr);float clear[4]={0,0,0,1};context->ClearRenderTargetView(rtv,clear);ImGui_ImplDX11_RenderDrawData(ImGui::GetDrawData());
 }
 desc.BindFlags=0;desc.Usage=D3D11_USAGE_STAGING;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;ComPtr<ID3D11Texture2D> staging;Check(device->CreateTexture2D(&desc,nullptr,&staging));context->CopyResource(staging.Get(),texture.Get());
 D3D11_MAPPED_SUBRESOURCE mapped{};Check(context->Map(staging.Get(),0,D3D11_MAP_READ,0,&mapped));BITMAPFILEHEADER file{};BITMAPINFOHEADER info{};file.bfType=0x4D42;file.bfOffBits=sizeof(file)+sizeof(info);file.bfSize=file.bfOffBits+width*height*4;info.biSize=sizeof(info);info.biWidth=width;info.biHeight=-height;info.biPlanes=1;info.biBitCount=32;info.biCompression=BI_RGB;
 std::ofstream out(argv[1],std::ios::binary);out.write((char*)&file,sizeof(file));out.write((char*)&info,sizeof(info));for(int y=0;y<height;++y)out.write((char*)mapped.pData+y*mapped.RowPitch,width*4);context->Unmap(staging.Get(),0);if(!out)throw std::runtime_error("Cannot save fixture bitmap");
 ImGui_ImplDX11_Shutdown();ImGui::DestroyContext();std::cout<<"Native WARP presentation captured; no simulator/runtime validation\n";
}catch(const std::exception&e){std::cerr<<e.what();return 1;}}
