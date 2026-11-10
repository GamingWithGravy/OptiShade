// OptiShade additions, GPL-3.0-or-later.
#pragma once
#include "MfgControlWin.h"
#include "BackgroundStatus.h"
#include <limits>
namespace optishade::mfg {
struct UiRequest {Settings settings;Snapshot baseline;};
class StatusService {
    Bridge backend_; // Accessed by the status worker, never the UI thread.
public:
    using Worker=optishade::BackgroundStatus<Snapshot,UiRequest>;
    Worker worker;
    StatusService():worker([this]{return backend_.Refresh();},[this](const UiRequest& r,std::string& reason){
        const auto current=backend_.Refresh();
        if(!MatchesSaveBaseline(r.baseline,current,current.settings)){
            reason="The provider or saved settings changed. Review the current state before retrying.";return false;
        }
        // SaveNow retains trusted paths, current capability checks, ownership,
        // revisions, file verification and the existing atomic replacement rules.
        // It rechecks the exact settings baseline after reading the write target.
        return backend_.SaveNow(r.settings,r.baseline,reason);
    }) {}
    // The caller retains one immutable publication for status AND save results.
    // Reading twice can pair a completed request with an older provider state.
    Snapshot Read(const Worker::Pointer& value)const {
        auto result=value->state;const auto now=Worker::NowMs();
        const bool fresh=value->sampledAtMs&&now>=value->sampledAtMs&&now-value->sampledAtMs<=1000&&value->readError.empty();
        if(!fresh){result.live=result.editable=false;result.message=worker.Started()?
            "MFG status is waiting or stale; controls do not confirm current output.":"MFG status worker has not started.";
            result.status.realFpsMilli=result.status.outputFpsMilli=0;result.status.fpsAgeMs=UINT64_MAX;
        }else if(result.status.fpsAgeMs<=UINT64_MAX-(now-value->sampledAtMs)){
            result.status.fpsAgeMs+=now-value->sampledAtMs;
        }else result.status.fpsAgeMs=UINT64_MAX;
        return result;
    }
    uint64_t Save(const Settings& request,const Snapshot& baseline) {
        if(!baseline.live||!baseline.editable||!baseline.verified||!baseline.owned)return 0;
        return worker.Queue({request,baseline});
    }
};
inline StatusService& UiStatus(){static auto* service=new StatusService;return *service;}
// Called by getGpuInfo after DllMain returned, not by opening a menu.
inline void StartUiStatus() noexcept {try{UiStatus().worker.Start();}catch(...){/* Read reports unavailable; no provider is activated here. */}}
}
