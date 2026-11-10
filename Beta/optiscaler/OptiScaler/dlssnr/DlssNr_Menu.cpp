#include "pch.h"
#include "DlssNrFeature_Vk.h"
#include "DlssNrFeature_Dx12.h"

#include "DlssNr.h"
#include "DlssNr_ExposureScan.h"
#include "DlssNrNative.h"
#include "NrObservationConfig.h"
#include "SelfHelp.h"


#include <Config.h>
#include <Util.h>
#include <menu/menu_common.h>
#include <upscalers/IFeature_Dx11wDx12.h>

#include <imgui/imgui.h>
#include "../../../shared/PanelUi.h"
#include "../../../shared/SettingsReview.h"

#include <string>
#include <unordered_map>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>

namespace DlssNr
{

// The "(?)" marker every control carries, matching the rest of the menu.
static void HelpMarker(const char* tip){optishade::panel::HelpMarker(tip);}

// A slider that only writes its value when the handle is released.
//
// Some controls -- intensity, the structure and tone strengths -- are read by the model once, when
// the feature is built, so changing one rebuilds the whole feature. Writing on every pixel of a drag
// meant a rebuild per frame, felt as the picture hitching while you scrub. The slider still tracks
// live under the cursor; only the commit that triggers the rebuild waits for release. Cheap controls
// that are just shader constants (detail, colour, paper white) do not use this -- they can afford to
// apply live.
template <typename Option>
static bool DeferredSlider(const char* label, Option* opt, float mn, float mx,
                           float def, const char* fmt = "%.2f", bool inheritReset = false)
{
    static std::unordered_map<ImGuiID, float> pending;
    const ImGuiID id = ImGui::GetID(label);

    auto it = pending.find(id);
    float value = it != pending.end() ? it->second : (opt->has_value() ? opt->value() : def);
    bool changed = false;

    const bool appearance=std::strcmp(label,"##NR strength")==0;
    if (appearance ? optishade::panel::StrengthTrack(label,&value,mn,mx)
                   : ImGui::SliderFloat(label,&value,mn,mx,fmt)) pending[id] = value;

    if (ImGui::IsItemDeactivatedAfterEdit())
    {
        auto committed = pending.find(id);

        if (committed != pending.end())
        {
            *opt = std::clamp(committed->second, mn, mx);
            pending.erase(committed);
            changed = true;
        }
    }

    ImGui::SameLine();

    char displayed[32]{};std::snprintf(displayed,sizeof(displayed),"%.2f",value);
    const std::string resetId = std::string(appearance?displayed:"Reset") + "##" + label;
    if (appearance ? ImGui::Button(resetId.c_str(),ImVec2(ImGui::GetFontSize()*3.25f,ImGui::GetFrameHeight())) : ImGui::SmallButton(resetId.c_str()))
    {
        if (inheritReset)
            *opt = std::optional<float> {};
        else
            *opt = def;
        pending.erase(id);
        changed = true;
    }

    if(appearance&&ImGui::IsItemHovered())ImGui::SetTooltip("Reset strength to the default value");
    if (std::strcmp(label, "Intensity") == 0)
        HelpMarker("Overall enhancement strength for this pass. 1 = default; results depend on the profile.\nValues above 1 are experimental; the runtime may clamp or ignore them.");
    else if (std::strcmp(label, "Local structure") == 0)
        HelpMarker("Fine detail and local contrast requested from the model (high-frequency structure).\n1 = default; values above 1 are experimental.");
    else if (std::strcmp(label, "Local tone") == 0)
        HelpMarker("Broad brightness and lighting changes requested from the model (low-frequency tone).\nLater passes default to 0. Values above 1 are experimental.");
    else if (std::strcmp(label, "Skin structure") == 0)
        HelpMarker("Fine detail for pixels the model identifies as skin. -1 follows Local structure; 0 reduces skin detail.\nSkin colour is controlled separately. Values above 1 are experimental.");
    return changed;
}

// An absent later-pass setting inherits pass 1. The first combo item represents that absence; the
// remaining items map directly to the model's zero-based profile values.
static bool InheritedProfileCombo(const char* label, CustomOptional<uint32_t, NoDefault>* opt,
                                  const char* const* names, int nameCount)
{
    int selected = 0;

    if (opt->has_value())
        selected = std::clamp((int) opt->value(), 0, nameCount - 2) + 1;

    if (!ImGui::Combo(label, &selected, names, nameCount))
        return false;

    if (selected == 0)
        *opt = std::optional<uint32_t> {};
    else
        *opt = (uint32_t) (selected - 1);

    return true;
}

#include "NrSettingsDraft.h"
#include "DlssNrPanel.inl"

} // namespace DlssNr


