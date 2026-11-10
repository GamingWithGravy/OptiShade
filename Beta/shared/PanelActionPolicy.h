#pragma once

namespace optishade::panel {

enum class FooterActionKind { None, Menu, Effects, FrameGeneration, Neural };

struct FooterActionInputs {
    int page=0;
    bool menuPending=false;
    bool neuralPending=false;
    bool frameGenerationPending=false;
    bool effectsPending=false;
    bool legacyFrameGeneration=false;
    bool frameGenerationAwaiting=false;
    bool frameGenerationConflict=false;
    bool nativeFrameGenerationCanSave=false;
    bool effectsLoading=false;
};

struct FooterAction {
    FooterActionKind kind=FooterActionKind::None;
    bool actionable=false;
    const char* saveLabel="Save";
};

// Keep footer status, enabled state, label and callback routing on one chosen
// action. In particular, pending frame-generation edits must not relabel an
// Image Effects save as "Save & Go" while the click still saves the preset.
inline FooterAction ChooseFooterAction(const FooterActionInputs& input) {
    if(input.menuPending&&(input.page==3||(!input.neuralPending&&!input.frameGenerationPending&&!input.effectsPending)))
        return {FooterActionKind::Menu,true,"Save"};
    if(input.page==2&&input.effectsPending)
        return {FooterActionKind::Effects,!input.effectsLoading,"Save"};
    if(input.frameGenerationPending&&(input.page==0||!input.neuralPending)) {
        const bool canSave=input.legacyFrameGeneration
            ? !input.frameGenerationAwaiting&&!input.frameGenerationConflict
            : input.nativeFrameGenerationCanSave;
        return {FooterActionKind::FrameGeneration,canSave,"Save & Go"};
    }
    if(input.neuralPending)return {FooterActionKind::Neural,true,"Save"};
    return {};
}

}
