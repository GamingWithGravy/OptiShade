#pragma once
#include <imgui/imgui.h>
#include <algorithm>
#include <cmath>
#include <unordered_map>
#include <limits>
#include <cstdint>
#include <type_traits>

namespace optishade::effects_ui {
template<class T> inline bool Integer(const char* id,T& value,bool ranged,float minimum,float maximum){
    ImGui::PushID(id);const auto type=std::is_signed_v<T>?ImGuiDataType_S32:ImGuiDataType_U32;
    const char* format=std::is_signed_v<T>?"%d":"%u";
    const double low=std::max(double(std::numeric_limits<T>::lowest()),double(minimum));
    const double high=std::min(double(std::numeric_limits<T>::max()),double(maximum));
    ranged=ranged&&low<high;T mn=ranged?T(std::ceil(low)):0,mx=ranged?T(std::floor(high)):0;
    const float width=ImGui::GetContentRegionAvail().x,field=std::min(width,ImGui::GetFontSize()*8.f);
    bool changed=false;
    // ImGui integer sliders require a half-range; full 32-bit values remain typeable.
    if(ranged&&double(mn)>=double(std::numeric_limits<T>::lowest())/2&&double(mx)<=double(std::numeric_limits<T>::max())/2&&width>field+ImGui::GetFontSize()*6.f){
        ImGui::SetNextItemWidth(width-field-ImGui::GetStyle().ItemSpacing.x);
        changed=ImGui::SliderScalar("##slider",type,&value,&mn,&mx,format,ImGuiSliderFlags_AlwaysClamp);ImGui::SameLine();
    }
    struct Edit{T typed=0;bool active=false;};static std::unordered_map<ImGuiID,Edit> edits;
    auto& edit=edits[ImGui::GetID("##exact-value")];if(!edit.active)edit.typed=value;
    ImGui::SetNextItemWidth(ranged?field:width);ImGui::InputScalar("##exact-value",type,&edit.typed,nullptr,nullptr,format);
    const bool commit=(ImGui::IsItemActive()&&ImGui::IsKeyPressed(ImGuiKey_Enter,false))||ImGui::IsItemDeactivatedAfterEdit();edit.active=ImGui::IsItemActive();
    if(commit){const T v=ranged?std::clamp(edit.typed,mn,mx):edit.typed;changed|=v!=value;value=v;}
    if(ImGui::IsItemHovered())ImGui::SetTooltip("Type an exact value. Press Enter or click elsewhere to apply.");
    ImGui::PopID();return changed;
}
// A visible text field is always available: no Ctrl-click discovery is required.
// ImGui owns the active text buffer; intermediate strings never reach the shader.
inline bool Numeric(const char* id, float& value, bool integer, bool ranged, float minimum, float maximum) {
    ImGui::PushID(id);
    const float width=ImGui::GetContentRegionAvail().x;
    const float field=std::min(width,ImGui::GetFontSize()*8.f);
    bool changed=false;
    if(ranged&&width>field+ImGui::GetFontSize()*6.f){
        ImGui::SetNextItemWidth(width-field-ImGui::GetStyle().ItemSpacing.x);
        changed=ImGui::SliderFloat("##slider",&value,minimum,maximum,integer?"%.0f":"%.4g",ImGuiSliderFlags_AlwaysClamp);
        ImGui::SameLine();
    }
    ImGui::SetNextItemWidth(ranged?field:width);
    struct Edit { float typed=0; bool active=false; };
    static std::unordered_map<ImGuiID,Edit> edits;
    auto& edit=edits[ImGui::GetID("##exact-value")];
    if(!edit.active)edit.typed=value;
    ImGui::InputFloat("##exact-value",&edit.typed,0,0,integer?"%.0f":"%.7g");
    const bool committed=(ImGui::IsItemActive()&&ImGui::IsKeyPressed(ImGuiKey_Enter,false))||ImGui::IsItemDeactivatedAfterEdit();
    edit.active=ImGui::IsItemActive();
    float typed=edit.typed;
    if(committed&&std::isfinite(typed)){
        if(integer)typed=std::round(typed);
        if(ranged)typed=std::clamp(typed,minimum,maximum);
        changed|=typed!=value;value=typed;
    }
    if(ImGui::IsItemHovered())ImGui::SetTooltip("Type an exact value. Press Enter or click elsewhere to apply.");
    ImGui::PopID();return changed;
}
}
