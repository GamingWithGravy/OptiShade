// OptiShade additions, GPL-3.0-or-later. Presentation only; no renderer commands.
#pragma once
#ifndef IMGUI_VERSION
#include <imgui/imgui.h>
#endif
#include <algorithm>
#include <array>
#include <cctype>
#include <cstring>
#include <cmath>
#include <string>

namespace optishade::panel {
// The worker host and ReShade use different 1.92 revisions of Dear ImGui.
inline void PushTextSize(float size) {
#if IMGUI_VERSION_NUM >= 19250
    ImGui::PushFont(ImGui::GetFont(), size);
#else
    ImGui::PushFontSize(size);
#endif
}
inline void PopTextSize() {
#if IMGUI_VERSION_NUM >= 19250
    ImGui::PopFont();
#else
    ImGui::PopFontSize();
#endif
}

inline bool& CompactHelp(){static bool compact=false;return compact;}
// Owner-approved 13 October desktop-matched V3 palette; callers decide whether the user selected the default theme.
inline void ApplyDefaultTheme(ImGuiStyle& style,float alpha){
    style.WindowRounding=10;style.ChildRounding=9;style.FrameRounding=6;style.GrabRounding=8;style.FrameBorderSize=1;style.WindowBorderSize=1;
    auto rgb=[](unsigned hex,float a=1.f){return ImVec4(((hex>>16)&255)/255.f,((hex>>8)&255)/255.f,(hex&255)/255.f,a);};
    auto& c=style.Colors;
    c[ImGuiCol_WindowBg]=rgb(0x100F1C,alpha);c[ImGuiCol_ChildBg]=rgb(0x161422);
    c[ImGuiCol_PopupBg]=rgb(0x161422);c[ImGuiCol_FrameBg]=rgb(0x15111E);
    c[ImGuiCol_Border]=rgb(0x604477);c[ImGuiCol_Text]=rgb(0xF3EFFB);c[ImGuiCol_TextDisabled]=rgb(0xBDB0D8);
    c[ImGuiCol_Button]=rgb(0x261E35);c[ImGuiCol_ButtonHovered]=rgb(0x493075);c[ImGuiCol_ButtonActive]=rgb(0x882FFF);
    c[ImGuiCol_Header]=rgb(0x261E35);c[ImGuiCol_HeaderHovered]=rgb(0x493075);c[ImGuiCol_HeaderActive]=rgb(0x882FFF);
    c[ImGuiCol_CheckMark]=c[ImGuiCol_SliderGrab]=rgb(0x882FFF);c[ImGuiCol_SliderGrabActive]=rgb(0xB685FF);
}
// Rounded native gradient surfaces; no textures, web UI or extra rendering hook.
inline void Glass(ImDrawList* d,ImVec2 lo,ImVec2 hi,ImVec4 colour,float rounding=7.f,bool border=true){
 int first=d->VtxBuffer.Size;d->AddRectFilled(lo,hi,ImGui::ColorConvertFloat4ToU32(colour),rounding);
 for(int i=first;i<d->VtxBuffer.Size;++i){auto& v=d->VtxBuffer[i];float t=std::clamp((v.pos.x-lo.x+v.pos.y-lo.y)/(hi.x-lo.x+hi.y-lo.y),0.f,1.f);auto c=colour;c.x=std::min(1.f,c.x+(1-t)*.045f);c.y=std::min(1.f,c.y+(1-t)*.025f);c.z=std::min(1.f,c.z+(1-t)*.075f);v.col=ImGui::ColorConvertFloat4ToU32(c);}
 if(border)d->AddRect(lo,hi,ImGui::GetColorU32(ImGuiCol_Border),rounding);
}
// Vector icons keep text crisp at every DPI and require no icon-font installation.
inline void Icon(ImDrawList* d,ImVec2 c,float r,int kind,ImU32 col){
 const float w=1.6f;
 if(kind==10){d->AddRect(ImVec2(c.x-r,c.y-r*.8f),ImVec2(c.x+r,c.y+r*.55f),col,2,0,w);d->AddLine(ImVec2(c.x,c.y+r*.55f),ImVec2(c.x,c.y+r),col,w);d->AddLine(ImVec2(c.x-r*.5f,c.y+r),ImVec2(c.x+r*.5f,c.y+r),col,w);return;}
 if(kind==11){for(int i=0;i<3;++i){float x=c.x-r+i*r*.75f;d->AddRect(ImVec2(x,c.y+r-(i+1)*r*.65f),ImVec2(x+r*.4f,c.y+r),col,1,0,w);}return;}

 if(kind==8){const ImVec2 pts[]={{c.x+r*.15f,c.y-r},{c.x-r*.8f,c.y+r*.15f},{c.x-r*.1f,c.y+r*.15f},{c.x-r*.25f,c.y+r},{c.x+r*.85f,c.y-r*.25f},{c.x+r*.1f,c.y-r*.25f}};d->AddPolyline(pts,6,col,ImDrawFlags_Closed,w);return;}
 if(kind==9){d->AddLine(ImVec2(c.x-r*.8f,c.y+r*.8f),ImVec2(c.x+r*.15f,c.y-r*.15f),col,w*2);d->PathArcTo(ImVec2(c.x+r*.4f,c.y-r*.4f),r*.6f,-.1f,4.6f,20);d->PathStroke(col,0,w);d->AddLine(ImVec2(c.x+r*.35f,c.y-r),ImVec2(c.x+r*.1f,c.y-r*.45f),col,w);d->AddLine(ImVec2(c.x+r*.1f,c.y-r*.45f),ImVec2(c.x+r*.6f,c.y-r*.1f),col,w);return;}
 if(kind==4){d->PathArcTo(c,r,-.85f,3.99f,24);d->PathStroke(col,0,w);d->AddLine(ImVec2(c.x,c.y-r*1.15f),ImVec2(c.x,c.y),col,w);return;}
 if(kind==5){for(int j=-1;j<=1;++j){float y=c.y+j*r*.7f;d->AddLine(ImVec2(c.x-r,y),ImVec2(c.x+r,y),col,w);d->AddCircleFilled(ImVec2(c.x+(j==0?.4f:-.35f)*r,y),r*.18f,col);}return;}
 if(kind==6){for(int j=0;j<3;++j){float y=c.y-r*.5f+j*r*.5f;d->AddLine(ImVec2(c.x-r,y),ImVec2(c.x,y+r*.5f),col,w);d->AddLine(ImVec2(c.x,y+r*.5f),ImVec2(c.x+r,y),col,w);}d->AddLine(ImVec2(c.x-r,c.y-r*.5f),ImVec2(c.x,c.y-r),col,w);d->AddLine(ImVec2(c.x,c.y-r),ImVec2(c.x+r,c.y-r*.5f),col,w);return;}
 if(kind==7){d->AddCircle(c,r,col,24,w);d->AddLine(ImVec2(c.x,c.y-r*.15f),ImVec2(c.x,c.y+r*.6f),col,w);d->AddCircleFilled(ImVec2(c.x,c.y-r*.55f),1.7f,col);return;}

 if(kind==0){d->AddCircle(c,r,col,24,w);d->AddLine(c,ImVec2(c.x+r*.55f,c.y-r*.55f),col,w);d->AddCircleFilled(c,2,col);}
 else if(kind==1){d->AddLine(ImVec2(c.x-r,c.y),ImVec2(c.x+r,c.y),col,w);d->AddLine(ImVec2(c.x,c.y-r),ImVec2(c.x,c.y+r),col,w);d->AddQuad(ImVec2(c.x,c.y-r),ImVec2(c.x+r*.5f,c.y),ImVec2(c.x,c.y+r),ImVec2(c.x-r*.5f,c.y),col,w);}
 else if(kind==2){d->AddRect(ImVec2(c.x-r,c.y-r),ImVec2(c.x+r,c.y+r),col,2,0,w);d->AddLine(ImVec2(c.x-r*.8f,c.y+r*.6f),ImVec2(c.x,c.y-r*.2f),col,w);d->AddLine(ImVec2(c.x,c.y-r*.2f),ImVec2(c.x+r*.8f,c.y+r*.6f),col,w);d->AddCircleFilled(ImVec2(c.x+r*.4f,c.y-r*.5f),r*.15f,col);}
 else {d->AddCircle(c,r*.65f,col,16,w);d->AddCircle(c,r*.23f,col,12,w);for(int i=0;i<8;++i){float a=i*3.14159265f/4;d->AddLine(ImVec2(c.x+cosf(a)*r*.65f,c.y+sinf(a)*r*.65f),ImVec2(c.x+cosf(a)*r,c.y+sinf(a)*r),col,w);}}
}
// Resolve the heading face from this context's atlas. Never retain a font pointer across graphics contexts.
inline ImFont* HeadingFont(){
 for(auto* font:ImGui::GetIO().Fonts->Fonts)if(std::strcmp(font->GetDebugName(),"OptiShade Semibold")==0)return font;
 return ImGui::GetFont();
}
inline void PushHeading() {
#if IMGUI_VERSION_NUM >= 19250
    ImGui::PushFont(HeadingFont(), ImGui::GetFontSize());
#else
    ImGui::PushFont(HeadingFont());
#endif
}
inline void PageHelp(const char* title);
inline void PageTitle(const char* title,const char* subtitle,const char* badge=nullptr){
 const auto origin=ImGui::GetCursorScreenPos();const float available=ImGui::GetContentRegionAvail().x;
 PushHeading();PushTextSize(ImGui::GetFontSize()*1.85f);ImGui::TextUnformatted(title);PopTextSize();ImGui::PopFont();
 if(!badge){ImGui::SameLine(ImGui::GetWindowWidth()-ImGui::GetStyle().WindowPadding.x-ImGui::GetFontSize()*2.f);PageHelp(title);}
 if(badge){const float u=ImGui::GetFontSize(),w=ImGui::CalcTextSize(badge).x+u;const ImVec2 lo(origin.x+available-w,origin.y+u*.6f),hi(lo.x+w,lo.y+u*1.65f);auto*d=ImGui::GetWindowDrawList();d->AddRectFilled(lo,hi,IM_COL32(62,44,28,220),u);d->AddRect(lo,hi,IM_COL32(199,144,60,255),u);d->AddText(ImVec2(lo.x+u*.5f,lo.y+u*.25f),IM_COL32(255,196,98,255),badge);}
 ImGui::PushStyleColor(ImGuiCol_Text,ImGui::GetStyleColorVec4(ImGuiCol_TextDisabled));ImGui::TextWrapped("%s",subtitle);ImGui::PopStyleColor();ImGui::Spacing();
}
// Native card heading with a vector icon, matching the approved V3 hierarchy.
inline void CardHeading(const char* title,const char* subtitle,int kind=3){
 std::string upper=title;for(auto&c:upper)c=char(std::toupper((unsigned char)c));
 ImGui::PushStyleColor(ImGuiCol_Text,ImGui::GetStyleColorVec4(ImGuiCol_TextDisabled));PushHeading();ImGui::TextUnformatted(upper.c_str());ImGui::PopFont();ImGui::PopStyleColor();
 if(subtitle&&*subtitle&&!CompactHelp()){ImGui::PushStyleColor(ImGuiCol_Text,ImGui::GetStyleColorVec4(ImGuiCol_TextDisabled));ImGui::TextWrapped("%s",subtitle);ImGui::PopStyleColor();}
 ImGui::Spacing();
}
inline void Signature(){
 const float u=ImGui::GetFontSize();const auto p=ImGui::GetCursorScreenPos();const float w=ImGui::GetContentRegionAvail().x;
 auto* d=ImGui::GetWindowDrawList();d->AddText(ImGui::GetFont(),u*.6f,ImVec2(p.x,p.y+u),ImGui::GetColorU32(ImGuiCol_TextDisabled),"A  B E T T E R  V I E W\nA  B R I G H T E R  F L I G H T");
 for(int j=0;j<14;++j){ImVec2 last{};for(int k=0;k<=90;++k){float t=k/90.f;float envelope=sinf(t*3.14159265f);ImVec2 q(p.x+w*.45f+w*.58f*t,p.y+u*(1.4f-1.15f*sinf(t*6.28f)+j*.065f*envelope));if(k)d->AddLine(last,q,ImGui::GetColorU32(ImVec4(.55f,.16f,1.f,(.55f-j*.032f)*envelope)),.7f);last=q;}}
 ImGui::Dummy(ImVec2(w,u*3));
}
inline void Brand(){
 const float u=ImGui::GetFontSize(),size=u*1.85f;const auto p=ImGui::GetCursorScreenPos();auto* font=HeadingFont();auto* draw=ImGui::GetWindowDrawList();
 const float first=font->CalcTextSizeA(size,10000,0,"O").x;
 draw->AddText(font,size,ImVec2(p.x,p.y),ImGui::GetColorU32(ImGuiCol_CheckMark),"O");
 draw->AddText(font,size,ImVec2(p.x+first,p.y),ImGui::GetColorU32(ImGuiCol_Text),"ptiShade");
 ImGui::Dummy(ImVec2(font->CalcTextSizeA(size,10000,0,"OptiShade").x,u*1.5f));
}
inline void Keycap(const char* label){
 const auto p=ImGui::GetCursorScreenPos();const float u=ImGui::GetFontSize();const ImVec2 size(ImGui::CalcTextSize(label).x+u, u*1.45f);
 Glass(ImGui::GetWindowDrawList(),p,ImVec2(p.x+size.x,p.y+size.y),ImGui::GetStyleColorVec4(ImGuiCol_Button),6);
 ImGui::GetWindowDrawList()->AddText(ImVec2(p.x+u*.5f,p.y+u*.22f),ImGui::GetColorU32(ImGuiCol_Text),label);ImGui::Dummy(size);
}
enum class Section { None, Quality, Compatibility, Experimental, Colour, Troubleshooting, NrTechnical, EffectsTools, PresetSwitch, Menu, Status, Cockpit };
enum class DetailMode { None, Explain, Search, Help, Review, FxReview };
struct Detail {
    DetailMode mode=DetailMode::None;
    Section open=Section::None;
    std::string title,text;
    ImGuiID returnFocus=0;
    bool restoreFocus=false;
    bool resetScroll=false;
    char query[128]{};
};
inline Detail& Details(){static Detail value;return value;}
inline void Open(const char* title,const char* text,DetailMode mode=DetailMode::Explain){
    auto& d=Details();d.title=title;d.text=text;d.mode=mode;d.returnFocus=ImGui::GetItemID();d.restoreFocus=false;
}
inline void CloseDetail(){auto& d=Details();d.mode=DetailMode::None;d.restoreFocus=true;}
inline void RestoreLastItemFocus(){auto& d=Details();if(d.restoreFocus&&d.returnFocus==ImGui::GetItemID()){
    ImGui::SetKeyboardFocusHere(-1);d.restoreFocus=false;
}}
inline void PageHelp(const char* title){
 ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding,20.f);if(ImGui::SmallButton("?"))Open(title,"Use the controls on this page to adjust this part of OptiShade. Rendering changes are separate from image-effects presets. Open Help for symptom-specific guidance.");RestoreLastItemFocus();ImGui::PopStyleVar();
}
inline void HelpMarker(const char* text){
    if(ImGui::GetItemRectMax().x+ImGui::GetFontSize()*3 < ImGui::GetWindowPos().x+(ImGui::GetWindowSize().x-ImGui::GetStyle().WindowPadding.x))ImGui::SameLine();ImGui::PushID(text);
    ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding,ImGui::GetFontSize());if(ImGui::Button("?",ImVec2(ImGui::GetFontSize()*1.5f,ImGui::GetFontSize()*1.5f)))Open("About this setting",text);ImGui::PopStyleVar();
    RestoreLastItemFocus();ImGui::PopID();
}
inline bool Toggle(const char* label,bool* value,const char* help=nullptr){
 const float u=ImGui::GetFontSize(),h=u*1.9f,width=ImGui::GetContentRegionAvail().x,tw=u*3.8f;
 const auto pos=ImGui::GetCursorScreenPos();ImGui::PushID(label);ImGui::BeginGroup();
 auto* d=ImGui::GetWindowDrawList();const float labelSize=u*1.12f;
 const char* visibleEnd=std::strstr(label,"##");if(!visibleEnd)visibleEnd=label+std::strlen(label);
 d->AddText(HeadingFont(),labelSize,ImVec2(pos.x,pos.y+(h-labelSize)*.35f),ImGui::GetColorU32(ImGuiCol_Text),label,visibleEnd);
 if(help){const float labelWidth=HeadingFont()->CalcTextSizeA(labelSize,10000,0,label,visibleEnd).x;
  ImGui::SetCursorScreenPos(ImVec2(pos.x+labelWidth+u*.65f,pos.y+u*.2f));ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding,u);
  if(ImGui::Button("?",ImVec2(u*1.4f,u*1.4f)))Open(visibleEnd==label?"About this setting":std::string(label,visibleEnd).c_str(),help);RestoreLastItemFocus();ImGui::PopStyleVar();}
 ImGui::SetCursorScreenPos(ImVec2(pos.x+width-tw,pos.y));
 const bool clicked=ImGui::InvisibleButton("##toggle",ImVec2(tw,h),ImGuiButtonFlags_EnableNav);if(clicked)*value=!*value;
 const ImVec2 lo(pos.x+width-tw,pos.y+u*.3f),hi(pos.x+width,pos.y+h-u*.3f);
 Glass(d,lo,hi,ImGui::GetStyleColorVec4(*value?ImGuiCol_CheckMark:ImGuiCol_Button),h*.5f);
 d->AddCircleFilled(ImVec2(*value?hi.x-u:lo.x+u,pos.y+h*.5f),u*.6f,ImGui::GetColorU32(ImGuiCol_Text));
 if(ImGui::IsItemFocused())d->AddRect(lo,hi,ImGui::GetColorU32(ImGuiCol_TextDisabled),h*.5f);
 ImGui::EndGroup();ImGui::PopID();return clicked;
}
inline bool Group(const char* title,Section section,const char* summary=nullptr){
    if(CompactHelp())summary=nullptr;
    auto& d=Details();const bool target=d.open==section&&section!=Section::None;
    const bool parent=((d.open==Section::Colour||d.open==Section::Experimental)&&section==Section::Compatibility) || (d.open==Section::NrTechnical&&section==Section::Troubleshooting);
    if(target||parent)ImGui::SetNextItemOpen(true,ImGuiCond_Always);
    const float unit=ImGui::GetFontSize();
    const auto pos=ImGui::GetCursorScreenPos();
    ImGui::PushStyleVar(ImGuiStyleVar_FramePadding,ImVec2(unit*.65f,summary&&*summary?unit*1.3f:unit*.8f));
    ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding,unit*.4f);
    ImGui::PushID(title);
    const bool expanded=ImGui::CollapsingHeader("##group");
    auto* draw=ImGui::GetWindowDrawList();
    Glass(draw,pos,ImGui::GetItemRectMax(),ImGui::GetStyleColorVec4(ImGui::IsItemHovered()?ImGuiCol_HeaderHovered:ImGuiCol_FrameBg));
    draw->AddText(HeadingFont(),unit*1.25f,ImVec2(pos.x+unit,pos.y+unit*.6f),ImGui::GetColorU32(ImGuiCol_Text),title);
    const auto edge=ImGui::GetItemRectMax();float cx=edge.x-unit*1.4f,cy=(pos.y+edge.y)*.5f;
    draw->AddLine(ImVec2(cx-4,cy+(expanded?2:-2)),ImVec2(cx,cy+(expanded?-2:2)),ImGui::GetColorU32(ImGuiCol_Text),1.5f);
    draw->AddLine(ImVec2(cx,cy+(expanded?-2:2)),ImVec2(cx+4,cy+(expanded?2:-2)),ImGui::GetColorU32(ImGuiCol_Text),1.5f);
    if(summary&&*summary){
        draw->PushClipRect(pos,ImVec2(edge.x-unit*3,edge.y),true);
        draw->AddText(ImVec2(pos.x+unit,pos.y+unit*1.85f),ImGui::GetColorU32(ImGuiCol_TextDisabled),summary);draw->PopClipRect();
        if(ImGui::IsItemHovered())ImGui::SetTooltip("%s",summary);
    }
    ImGui::PopID();ImGui::PopStyleVar(2);

    if(target){ImGui::SetScrollHereY(.2f);ImGui::SetKeyboardFocusHere(-1);d.open=Section::None;d.restoreFocus=false;}
    return expanded;
}
template<class Draw> inline void Card(const char* id,Draw draw){
    const auto& style=ImGui::GetStyle();
    const auto cardColour=style.Colors[ImGuiCol_FrameBg];
    ImGui::PushStyleColor(ImGuiCol_ChildBg,cardColour);
    ImGui::PushStyleVar(ImGuiStyleVar_ChildRounding,ImGui::GetFontSize()*.5f);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding,ImVec2(ImGui::GetFontSize()*1.25f,ImGui::GetFontSize()*.65f));
    if(ImGui::BeginChild(id,ImVec2(0,0),ImGuiChildFlags_Borders|ImGuiChildFlags_AutoResizeY|ImGuiChildFlags_AlwaysUseWindowPadding)){const auto p=ImGui::GetWindowPos(),z=ImGui::GetWindowSize();Glass(ImGui::GetWindowDrawList(),ImVec2(p.x+1,p.y+1),ImVec2(p.x+z.x-1,p.y+z.y-1),cardColour,ImGui::GetStyle().ChildRounding-1,false);draw();}
    ImGui::EndChild();ImGui::PopStyleVar(2);ImGui::PopStyleColor();ImGui::Spacing();
}
inline void HeaderActions(){
    const float u=ImGui::GetFontSize(),h=u*1.8f;
    for(int i=0;i<2;++i){if(i)ImGui::SameLine();ImGui::PushID(i);const auto p=ImGui::GetCursorScreenPos();
        if(ImGui::Button("##header-action",ImVec2(h,h)))Open(i?"Help and reports":"Find a control","",i?DetailMode::Help:DetailMode::Search);
        auto* d=ImGui::GetWindowDrawList();const ImVec2 c(p.x+h*.48f,p.y+h*.46f);const auto col=ImGui::GetColorU32(ImGuiCol_TextDisabled);
        d->AddCircle(c,u*.45f,col,24,1.3f);
        if(!i)d->AddLine(ImVec2(c.x+u*.3f,c.y+u*.3f),ImVec2(c.x+u*.7f,c.y+u*.7f),col,1.5f);
        else {d->AddCircle(c,u*.22f,col,20,1.3f);for(int j=0;j<4;++j){float a=j*1.5707963f+.785398f;d->AddLine(ImVec2(c.x+cosf(a)*u*.22f,c.y+sinf(a)*u*.22f),ImVec2(c.x+cosf(a)*u*.45f,c.y+sinf(a)*u*.45f),col,1.5f);}}
        if(ImGui::IsItemHovered())ImGui::SetTooltip("%s",i?"Help and troubleshooting":"Find a control");RestoreLastItemFocus();ImGui::PopID();
    }
}
inline bool Tabs(int& page,float scale=1.f){
    const char* labels[]={"Performance","Neural rendering","Image effects","Settings & status"};
    const char* compact[]={"Performance","Neural rendering","Image effects","Settings & status"};
    const float width=(ImGui::GetContentRegionAvail().x-3*ImGui::GetStyle().ItemSpacing.x)/4;
    float longest=1;for(int i=0;i<4;++i)longest=std::max(longest,ImGui::CalcTextSize(labels[i]).x);
    const float font=ImGui::GetFontSize()*std::min(1.f,std::max(1.f,width-10.f)/longest);
    PushTextSize(font);bool changed=false;
    for(int i=0;i<4;++i){if(i)ImGui::SameLine();ImGui::PushID(i);
        ImGui::PushStyleColor(ImGuiCol_Button,ImGui::GetStyleColorVec4(page==i?ImGuiCol_ButtonActive:ImGuiCol_Button));
        auto p=ImGui::GetCursorScreenPos();
        if(ImGui::Button("##tab",ImVec2(width,36*scale))){page=i;CloseDetail();changed=true;}
        auto* draw=ImGui::GetWindowDrawList();Glass(draw,p,ImGui::GetItemRectMax(),ImGui::GetStyleColorVec4(page==i?ImGuiCol_ButtonActive:ImGuiCol_Button));const auto colour=ImGui::GetColorU32(ImGuiCol_Text);
        const auto text=ImGui::CalcTextSize(compact[i]);draw->AddText(ImVec2(p.x+(width-text.x)*.5f,p.y+(36*scale-text.y)*.5f),colour,compact[i]);
        ImGui::PopStyleColor();ImGui::PopID();
    }
    PopTextSize();return changed;
}
// A single shell is shared by the game host and the native visual harness.
inline void ShellHeader(const char* build,const char* runtime,bool& visible,int& page,float scale=1.f){
 const float u=ImGui::GetFontSize(),right=ImGui::GetWindowWidth()-ImGui::GetStyle().WindowPadding.x;
 Brand();ImGui::SameLine();ImGui::PushStyleColor(ImGuiCol_Text,ImGui::GetStyleColorVec4(ImGuiCol_TextDisabled));PushTextSize(u*.72f);ImGui::TextUnformatted(build);PopTextSize();ImGui::PopStyleColor();
 ImGui::SameLine(right-u*4.8f);if(ImGui::Button("Close",ImVec2(u*4.8f,u*1.8f)))visible=false;
 ImGui::TextColored(ImVec4(.73f,.49f,1.f,1.f),"powered by fusion engine");ImGui::SameLine();ImGui::TextDisabled(" .  created by gravy");
 ImGui::Separator();
 ImGui::AlignTextToFramePadding();ImGui::TextDisabled("%s",runtime);
 ImGui::SameLine(right-u*4.9f);HeaderActions();
 ImGui::Separator();
}
// Pair with EndSidebarPage after the footer. All page actions remain in one host.
inline void BeginSidebarPage(int& page,[[maybe_unused]] bool showOptiMfg=false){
 if(page==6)page=0; // Migrate the former OptiMFG tab to Performance.
 const float u=ImGui::GetFontSize(),width=std::min(u*12.f,ImGui::GetContentRegionAvail().x*.28f);
 ImGui::BeginChild("Navigation",ImVec2(width,0),ImGuiChildFlags_Borders);
 const char* labels[]={"Performance","Neural rendering","Image effects","Glass cockpit","Monitoring","Settings & status"};
 const int pages[]={0,1,2,4,5,3},icons[]={0,1,2,10,11,3};
 const int count=6;
 for(int i=0;i<count;++i){const int item=i;ImGui::PushID(i);auto p=ImGui::GetCursorScreenPos();
  ImGui::PushStyleColor(ImGuiCol_Button,ImGui::GetStyleColorVec4(page==pages[item]?ImGuiCol_ButtonActive:ImGuiCol_ChildBg));
  if(ImGui::Button("##page",ImVec2(-1,u*3.f))){page=pages[item];CloseDetail();}
  auto* d=ImGui::GetWindowDrawList();Icon(d,ImVec2(p.x+u,p.y+u*1.5f),u*.55f,icons[item],ImGui::GetColorU32(ImGuiCol_TextDisabled));
  if(width>=u*10.5f)d->AddText(ImVec2(p.x+u*2.2f,p.y+u),ImGui::GetColorU32(ImGuiCol_Text),labels[item]);
  else if(ImGui::IsItemHovered())ImGui::SetTooltip("%s",labels[item]);
  ImGui::PopStyleColor();ImGui::PopID();
 }
 ImGui::EndChild();ImGui::SameLine();
 ImGui::BeginChild("Page and actions",ImVec2(0,0),ImGuiChildFlags_AlwaysUseWindowPadding);
}
inline void EndSidebarPage(){ImGui::EndChild();}
inline void StatusRow(const char* label,const char* value,int icon=7){
 const float u=ImGui::GetFontSize();auto p=ImGui::GetCursorScreenPos();
 Icon(ImGui::GetWindowDrawList(),ImVec2(p.x+u*.6f,p.y+u*.65f),u*.55f,icon,ImGui::GetColorU32(ImGuiCol_TextDisabled));
 ImGui::SetCursorPosX(ImGui::GetCursorPosX()+u*2.5f);ImGui::TextUnformatted(label);
 ImGui::SameLine(ImGui::GetWindowWidth()*.56f);ImGui::PushTextWrapPos(0);ImGui::TextUnformatted(value);ImGui::PopTextWrapPos();ImGui::Spacing();ImGui::Separator();
}
template<class Control> inline void SettingRow(const char* label,const char* help,Control control,float fraction=.40f){
 const float w=ImGui::GetContentRegionAvail().x;ImGui::BeginGroup();
 ImGui::AlignTextToFramePadding();PushHeading();ImGui::TextUnformatted(label);ImGui::PopFont();
 ImGui::SameLine(ImGui::GetCursorPosX()+w*(1-fraction));ImGui::SetNextItemWidth(-1);control();
 if(help&&*help&&!CompactHelp()){ImGui::PushStyleColor(ImGuiCol_Text,ImGui::GetStyleColorVec4(ImGuiCol_TextDisabled));ImGui::TextWrapped("%s",help);ImGui::PopStyleColor();}
 ImGui::EndGroup();ImGui::Spacing();
}
template<class Discard,class Review,class Undo> inline void ShellFooter(const char* status,bool pending,bool actionable,bool canUndo,const char* menu,const char* recovery,Discard discard,Review review,Undo undo,const char* saveLabel="Save"){
 const float u=ImGui::GetFontSize(),right=ImGui::GetWindowWidth()-ImGui::GetStyle().WindowPadding.x;
 ImGui::Separator();ImGui::AlignTextToFramePadding();ImGui::TextColored(pending?ImVec4(1,.7f,.2f,1):ImVec4(.4f,.95f,.75f,1),"%s",status);
 ImGui::SameLine(std::max(ImGui::GetCursorPosX(),right-u*15.3f));ImGui::BeginDisabled(!actionable);
 if(ImGui::Button("Discard",ImVec2(u*5.5f,u*1.85f)))discard();ImGui::SameLine();
  ImGui::PushStyleColor(ImGuiCol_Button,ImGui::GetStyleColorVec4(ImGuiCol_ButtonActive));if(ImGui::Button(saveLabel,ImVec2(u*9.f,u*1.85f)))review();ImGui::PopStyleColor();RestoreLastItemFocus();ImGui::EndDisabled();
 ImGui::Separator();Keycap(menu);ImGui::SameLine();ImGui::TextDisabled("menu .");ImGui::SameLine();Keycap(recovery);ImGui::SameLine();ImGui::TextDisabled("recovery");
 ImGui::SameLine(std::max(ImGui::GetCursorPosX(),right-ImGui::CalcTextSize("Undo last apply").x-u));ImGui::BeginDisabled(!canUndo);ImGui::PushStyleColor(ImGuiCol_Button,ImVec4(0,0,0,0));if(ImGui::SmallButton("Undo last apply"))undo();ImGui::PopStyleColor();RestoreLastItemFocus();ImGui::EndDisabled();
}
inline bool StrengthTrack(const char* label,float* value,float mn,float mx){
 ImGui::PushStyleColor(ImGuiCol_FrameBg,ImVec4(0,0,0,0));ImGui::PushStyleColor(ImGuiCol_FrameBgHovered,ImVec4(0,0,0,0));ImGui::PushStyleColor(ImGuiCol_FrameBgActive,ImVec4(0,0,0,0));ImGui::PushStyleColor(ImGuiCol_SliderGrab,ImVec4(0,0,0,0));ImGui::PushStyleColor(ImGuiCol_SliderGrabActive,ImVec4(0,0,0,0));ImGui::PushStyleVar(ImGuiStyleVar_FrameBorderSize,0.f);
 const bool changed=ImGui::SliderFloat(label,value,mn,mx,"");ImGui::PopStyleVar();ImGui::PopStyleColor(5);
 const auto lo=ImGui::GetItemRectMin(),hi=ImGui::GetItemRectMax();auto* d=ImGui::GetWindowDrawList();const float y=(lo.y+hi.y)*.5f,radius=ImGui::GetFontSize()*.6f,left=lo.x+radius,right=hi.x-radius,x=left+(right-left)*std::clamp((*value-mn)/(mx-mn),0.f,1.f);
 d->AddLine(ImVec2(left,y),ImVec2(right,y),ImGui::GetColorU32(ImGuiCol_Border),7);d->AddLine(ImVec2(left,y),ImVec2(x,y),ImGui::GetColorU32(ImGuiCol_CheckMark),7);d->AddCircleFilled(ImVec2(x,y),radius,ImGui::GetColorU32(ImGuiCol_CheckMark));d->AddCircle(ImVec2(x,y),radius,IM_COL32(196,130,255,255),24,1.5f);
 return changed;
}
// Production settings presentation also rendered by the offline visual harness.
template<class Theme,class Opacity,class Compact>
inline void SettingsAppearance(Theme theme,Opacity opacity,Compact compact){
 Card("Overlay appearance",[&]{CardHeading("OVERLAY SETTINGS","");
 SettingRow("Theme accent","Choose the accent for highlights and active elements.",theme,.32f);ImGui::Separator();
 SettingRow("Menu opacity","Adjust the panel transparency (in game).",opacity,.47f);ImGui::Separator();
 compact();if(!CompactHelp())ImGui::TextDisabled("Show shorter helper text throughout the menu.");
 });
}
inline void SettingsStatus(const char* connection,const char* api,const char* channel,const char* build){
 Card("Session summary",[&]{CardHeading("STATUS","");
 StatusRow("Upscaler connection",connection,0);StatusRow("Graphics API",api,2);
 StatusRow("Update channel",channel,6);StatusRow("Build",build,7);
 StatusRow("Diagnostics","Available in manager",4);
 });
}
template<class Look,class Strength> inline void Appearance(Look look,Strength strength){
    const float u=ImGui::GetFontSize();
    ImGui::AlignTextToFramePadding();PushHeading();ImGui::TextUnformatted("NR look");ImGui::PopFont();HelpMarker("Changes the neural rendering style, not your saved image-effects preset.");
    ImGui::SameLine(ImGui::GetContentRegionAvail().x*.60f);ImGui::SetNextItemWidth(-1);look();
    if(!CompactHelp())ImGui::TextDisabled("Changes the neural style, not your saved INI.");
    ImGui::Separator();
    PushHeading();ImGui::TextUnformatted("Strength");ImGui::PopFont();HelpMarker("Blend the neural result with the original image. Lower values reduce its contribution.");
    ImGui::SetNextItemWidth(std::max(80.f,ImGui::GetContentRegionAvail().x-u*4.75f));strength();
    if(!CompactHelp())ImGui::TextDisabled("Lower values blend in less of the neural result.");
}
struct SearchItem {const char* title;const char* terms;int page;Section section;};
inline constexpr SearchItem searchItems[]={
    {"Upscaling and sharpness","sr dlss dlaa fsr xess resolution taa",0,Section::None},
    {"Neural rendering enable, look and strength","nr model lighting intensity style",1,Section::None},
    {"Quality & speed","nr model passes 1 2 3 4 5 scale resolution performance placement",1,Section::Quality},
    {"Native / TAA input and precision","nr compatibility fp8 nvfp4 hybrid input",1,Section::Compatibility},
    {"Ray reconstruction and split processing","rr pre-sr post-sr residual carry accumulation alternate approximate guides",1,Section::Experimental},
    {"Colour, masks and exposure","skin tone highlight paperwhite hdr exposure luminance scan",1,Section::Colour},
    { "NR troubleshooting", "bypass memory vram override failure flicker",1,Section::Troubleshooting},
    {"NR technical details and comparison","compare hold debug gpu timings",1,Section::NrTechnical},
    {"Saved image-effects presets","fx look ini import browse save copy",2,Section::None},
    {"Preset switching","hotswap preset 1 2 shortcut",2,Section::PresetSwitch},
    {"Shader tools","fx recompile rescan performance mode optimize",2,Section::EffectsTools},
    {"Menu preferences and shortcuts","size dpi colour keybind input insert home screenshot snapshot",3,Section::Menu},
    {"Glass cockpit correction","glass cockpit screens ghosting tint smoothing",4,Section::Cockpit},
    {"Technical status and diagnostics","report crash frozen stuck readiness fence provider",3,Section::Status}
};
inline bool Contains(const char* haystack,const char* needle){
    return !*needle||std::search(haystack,haystack+std::strlen(haystack),needle,needle+std::strlen(needle),
        [](unsigned char a,unsigned char b){return std::tolower(a)==std::tolower(b);})!=haystack+std::strlen(haystack);
}
// Called instead of normal page content, inside the SAME scrolling child.
inline void DrawDetail(int& page){
    auto& d=Details();
    if(ImGui::Button("Back")||ImGui::IsKeyPressed(ImGuiKey_Escape,false)){CloseDetail();return;}
    ImGui::SeparatorText(d.title.c_str());
    if(d.mode==DetailMode::Explain){ImGui::TextWrapped("%s",d.text.c_str());return;}
    if(d.mode==DetailMode::Search){
        ImGui::SetNextItemWidth(-1);ImGui::InputTextWithHint("##panel-find","Search NR, presets, memory...",d.query,sizeof(d.query));
        bool found=false;
        for(const auto& item:searchItems){
            if(!Contains(item.title,d.query)&&!Contains(item.terms,d.query))continue;
            found=true;
            if(ImGui::Selectable(item.title)){page=item.page;d.open=item.section;d.resetScroll=item.section==Section::None;CloseDetail();}
        }
        if(!found)ImGui::TextWrapped("No matching group. Try the feature name or its technical abbreviation.");
        return;
    }
    ImGui::TextWrapped("Change one feature at a time. A saved setting, a loaded DLL and visible output are different checkpoints.");
    if(ImGui::CollapsingHeader("Flickering, trails or changing brightness"))ImGui::TextWrapped("Compare Image effects and NR separately. Record camera/view changes and the actual AA mode. Compare one pass against the requested multipass stack and include the report. A failed stack stays paused until Retry.");
    if(ImGui::CollapsingHeader("Cockpit displays are still blurred"))ImGui::TextWrapped("Open Glass cockpit for the bundled fix's live controls, diagnostic tint and report. Its runtime checks determine whether the current upscaler and screens are eligible; loading the file alone does not prove correction.");
    if(ImGui::CollapsingHeader("Menu or input stopped responding"))ImGui::TextWrapped("Use the configured backup menu shortcut. After closing the simulator, collect diagnostics in the desktop manager. Do not replace runtime files while the game is running.");
    if(ImGui::CollapsingHeader("Create a useful support report"))ImGui::TextWrapped("Use the desktop manager's diagnostic/troubleshooter tools. Include reproduction steps, aircraft/scene, GPU and driver, AA/FG settings, active provider and whether the install was clean or upgraded. Settings & status can copy exact readiness-check evidence for the same session.");
    ImGui::TextWrapped("Install, repair and removal stay in the desktop manager. Reports use graphics/runtime evidence and your reproduction notes.");
}
struct NrModel {bool requested=false;const char* state="Not checked";const char* reason="";const char* quality="";};
template<class Enable,class Look,class Quality,class Compatibility,class Troubleshooting>
inline void DrawNr(const NrModel& model,Enable enable,Look look,Quality quality,Compatibility compatibility,Troubleshooting troubleshooting){
    PageTitle("Neural rendering","Neural image enhancement. Separate from your effects preset.","Experimental");
    Card("NR session",[&]{
        bool requested=model.requested;
        const float u=ImGui::GetFontSize();
        if(Toggle("Enable for this session",&requested,"Starts off for each launch. Enabling is reviewed before submission; switching off stops NR immediately. Your saved image-effects look remains separate."))enable(requested);
        if(ImGui::IsItemHovered())ImGui::SetTooltip("Enabling is reviewed before submission. Switching off stops NR immediately. Output status is reported below.");
        ImGui::TextDisabled("Starts off each time you launch the game.");
        ImGui::Separator();
        const auto status=ImGui::GetCursorScreenPos();Icon(ImGui::GetWindowDrawList(),ImVec2(status.x+u*.5f,status.y+u*.55f),u*.5f,7,ImGui::GetColorU32(ImGuiCol_TextDisabled));
        ImGui::SetCursorPosX(ImGui::GetCursorPosX()+u*1.6f);ImGui::TextWrapped("%s",model.state);
        if(model.reason&&*model.reason){ImGui::Indent(u*1.6f);ImGui::TextWrapped("%s",model.reason);ImGui::Unindent(u*1.6f);}
    });
    Card("NR appearance",[&]{CardHeading("ADJUST THE IMAGE","",5);look();});
    if(Group("Quality & speed",Section::Quality,model.quality))quality();
    ImGui::Spacing();
    if(Group("Compatibility",Section::Compatibility,"Input connection, model and experimental routing"))compatibility();
    ImGui::Spacing();
    if(Group("Troubleshooting",Section::Troubleshooting,"Diagnostic bypass, memory protection and details"))troubleshooting();
    ImGui::Spacing();
    ImGui::Separator();ImGui::AlignTextToFramePadding();ImGui::TextDisabled("Seeing flicker or no change?");
    ImGui::SameLine(std::max(ImGui::GetCursorPosX(),(ImGui::GetWindowWidth()-ImGui::GetStyle().WindowPadding.x)-ImGui::GetFontSize()*6.5f));
    if(ImGui::SmallButton("Get help  >"))Open("Help and reports","",DetailMode::Help);
    RestoreLastItemFocus();
}
}
