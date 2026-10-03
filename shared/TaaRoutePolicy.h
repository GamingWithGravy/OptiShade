#pragma once
#include <array>
#include <cstdint>
namespace optishade::taa {
// Device/output-domain evidence, retained only for the short native-preference
// interval. Access is serialized by the existing NR mutex.
struct NativeInputs {
    struct Entry {uint64_t device=0;unsigned width=0,height=0;uint64_t time=0;};
    std::array<Entry,8> entries{};
    void observe(uint64_t device,unsigned width,unsigned height,uint64_t now) {
        if(!device||!width||!height)return;
        Entry* slot=&entries[0];
        for(auto& e:entries){if(e.device==device&&e.width==width&&e.height==height){slot=&e;break;}if(e.time<slot->time)slot=&e;}
        *slot={device,width,height,now};
    }
    bool recent(uint64_t device,unsigned width,unsigned height,uint64_t now) const {
        for(const auto& e:entries)if(e.device==device&&e.width==width&&e.height==height&&e.time&&now>=e.time&&now-e.time<2000)return true;
        return false;
    }
};
struct GuideReloadBudget {
    unsigned attempts=0;uint64_t last=0;
    bool request(uint64_t now){if(attempts>=3 || (last && now-last<1000))return false;++attempts;last=now;return true;}
};
}
