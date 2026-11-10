#include "OverlayInputAdmission.h"

#include <cassert>

int main()
{
    optishade::overlay::DrawProgress progress;
    optishade::overlay::InputAdmission admission;

    const auto owner = progress.Begin();
    admission.RequireSubmission(true);
    assert(!admission.Request(true));
    assert(!admission.AllowsInputBlock(false));
    assert(!progress.HasRecentSubmission(100));

    assert(progress.Submission(owner, 100));
    assert(progress.HasRecentSubmission(100));
    assert(progress.HasRecentSubmission(349));
    assert(!progress.HasRecentSubmission(350));
    assert(!progress.HasRecentSubmission(99));

    assert(admission.ReportSubmission(true));
    assert(admission.Admitted());
    assert(admission.AllowsInputBlock(progress.HasRecentSubmission(100)));
    assert(!admission.AllowsInputBlock(progress.HasRecentSubmission(350)));
    assert(!admission.ReportDeferred(progress.Deferred(owner, 351)));
    assert(!admission.Admitted());
    assert(!admission.AllowsInputBlock(progress.HasRecentSubmission(351)));

    optishade::overlay::InputAdmission presentedAdmission;
    presentedAdmission.RequireSubmission(true);
    presentedAdmission.RequirePresentation(true);
    assert(!presentedAdmission.Request(true));
    assert(!presentedAdmission.ReportSubmission(true));
    assert(!presentedAdmission.AllowsInputBlock(true, false));
    assert(presentedAdmission.ReportPresentation(true));
    assert(presentedAdmission.AllowsInputBlock(true, true));
    assert(!presentedAdmission.AllowsInputBlock(false, true));
    assert(!presentedAdmission.ReportPresentation(false));
    assert(!presentedAdmission.AllowsInputBlock(true, true));

    const auto nextOwner = progress.Begin();
    assert(!progress.HasRecentSubmission(400));
    assert(!progress.Submission(owner, 401));
    assert(progress.Submission(nextOwner, 401));
    assert(progress.HasRecentSubmission(402));
    assert(!progress.HasRecentPresentation(402));
    assert(progress.Present(nextOwner, 410, true));
    assert(progress.HasRecentPresentation(410));
    assert(progress.HasRecentPresentation(659));
    assert(!progress.HasRecentPresentation(660));
}
