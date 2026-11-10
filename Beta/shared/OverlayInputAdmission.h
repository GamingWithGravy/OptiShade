#pragma once
#include <cstdint>

// A request to open a menu is not evidence that its draw was submitted.
// Call only while holding the input-state mutex. This policy is independent
// of Win32/Vulkan so all request/submission transitions can be exercised.
namespace optishade::overlay {
class InputAdmission {
    bool requiresSubmission_ = false;
    bool requiresPresentation_ = false;
    bool requested_ = false;
    bool admitted_ = false;
    bool submissionReady_ = false;
public:
    bool RequireSubmission(bool required) noexcept {
        if (requiresSubmission_ != required) {
            requiresSubmission_ = required;
            submissionReady_ = !required;
            admitted_ = requested_ && !required && !requiresPresentation_;
        }
        return admitted_;
    }
    bool RequirePresentation(bool required) noexcept {
        if (requiresPresentation_ != required) {
            requiresPresentation_ = required;
            if (required) {
                submissionReady_ = false;
                admitted_ = false;
            } else {
                admitted_ = requested_ && (!requiresSubmission_ || submissionReady_);
            }
        }
        return admitted_;
    }
    bool Request(bool visible) noexcept {
        requested_ = visible;
        if (!visible) { admitted_ = false; submissionReady_ = false; }
        else if (!requiresSubmission_ && !requiresPresentation_) admitted_ = true;
        return admitted_;
    }
    bool ReportSubmission(bool submitted) noexcept {
        submissionReady_ = submitted;
        if (requiresSubmission_) {
            if (!submitted) admitted_ = false;
            else if (!requiresPresentation_) admitted_ = requested_;
        }
        return admitted_;
    }
    bool ReportPresentation(bool presented) noexcept {
        if (requiresPresentation_) admitted_ = requested_ && submissionReady_ && presented;
        return admitted_;
    }
    bool ReportDeferred(bool recentPresentation) noexcept {
        if (requiresSubmission_) admitted_ = requested_ && admitted_ && recentPresentation;
        return admitted_;
    }
    bool AllowsInputBlock(bool recentSubmittedFrame, bool recentPresentedFrame) const noexcept {
        return requested_ && admitted_ && (!requiresSubmission_ || recentSubmittedFrame) &&
               (!requiresPresentation_ || recentPresentedFrame);
    }
    // DirectX overlays do not currently report presentation progress separately.
    bool AllowsInputBlock(bool recentSubmittedFrame) const noexcept {
        return AllowsInputBlock(recentSubmittedFrame, false);
    }
    bool Requested() const noexcept { return requested_; }
    bool Admitted() const noexcept { return admitted_; }
    bool RequiresSubmission() const noexcept { return requiresSubmission_; }
    bool RequiresPresentation() const noexcept { return requiresPresentation_; }
};
}

namespace optishade::overlay {
// Present progress, not a change to menu contents: static menus keep refreshing.
// Access under the input mutex. Generation changes reject late callbacks.
class DrawProgress {
 uint64_t generation_=0, progress_=0, present_=0;
 bool started_=false;
 uint64_t draw_=0; bool drawn_=false, presented_=false;
public:
 uint64_t Begin(){++generation_;progress_=0;present_=0;started_=false;draw_=0;drawn_=false;presented_=false;return generation_;}
 bool Matches(uint64_t owner)const{return owner&&owner==generation_;}
 bool Submission(uint64_t owner,uint64_t now){if(!Matches(owner))return false;if(!started_){progress_=now;started_=true;}if(Expired(now))return false;draw_=now;drawn_=true;return true;}
 bool Present(uint64_t owner,uint64_t now,bool success){if(!Matches(owner))return false;if(success){progress_=now;present_=now;started_=true;presented_=true;}return true;}
 bool Deferred(uint64_t owner,uint64_t now)const{return Matches(owner)&&drawn_&&now>=draw_&&now-draw_<250&&!Expired(now);}
 bool HasRecentSubmission(uint64_t now,uint64_t maxAge=250)const{return drawn_&&now>=draw_&&now-draw_<maxAge;}
 bool HasRecentPresentation(uint64_t now,uint64_t maxAge=250)const{return presented_&&now>=present_&&now-present_<maxAge;}
 bool Expired(uint64_t now)const{return started_&&(now<progress_||now-progress_>=2000);}
};
}
