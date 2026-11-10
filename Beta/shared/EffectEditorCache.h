#pragma once
#include "EffectsBridge.h"
#include <algorithm>
#include <cstring>
#include <map>
#include <string>
#include <vector>

namespace optishade::effects_ui {
// UI-owned copies, never ReShade pointers. Inspect requests are serialized and
// acknowledged by exact generation/effect/page/serial, including empty pages.
class EditorCache {
    uint64_t generation=0,serial=0,pending=0,started=0;
    std::string requested,last;
    unsigned requestedPage=0;
public:
    struct Effect { bool known=false; unsigned total=0,next=0; std::string description; std::map<unsigned,std::vector<osfx::UniformInfo>> pages; };
    std::map<std::string,Effect> effects;
    bool exhausted=false;
    static constexpr size_t MaxCachedPages=64;
    void Sync(uint64_t value) { if(generation!=value){generation=value;effects.clear();pending=0;last.clear();exhausted=false;} }
    bool SetOpen(const std::string& name,bool open) {
        if(!open){effects.erase(name);return false;}
        return effects.try_emplace(name).second;
    }
    void CancelRequest(){pending=0;}
    bool Accept(const osfx::Snapshot& snapshot) {
        if(!pending||snapshot.generation!=generation||snapshot.inspectSerial!=pending||
           snapshot.inspectedEffect!=requested||snapshot.uniformPage!=requestedPage||snapshot.loading)return false;
        pending=0;
        auto found=effects.find(requested);if(found==effects.end())return false;
        auto& effect=found->second;
        size_t pages=0;for(const auto& item:effects)pages+=item.second.pages.size();
        if(!effect.pages.count(requestedPage)&&pages>=MaxCachedPages){exhausted=true;return false;}
        if(snapshot.uniforms>osfx::MaxUniforms)return false;
        for(uint32_t i=0;i<snapshot.uniforms;++i)if(snapshot.uniform[i].effect!=requested)return false;
        effect.known=true;effect.total=snapshot.uniformTotal;
        if(snapshot.inspectedDescription[0])effect.description=snapshot.inspectedDescription;
        auto& page=effect.pages[requestedPage];page.assign(snapshot.uniform,snapshot.uniform+snapshot.uniforms);
        const unsigned count=std::max(1u,(effect.total+osfx::MaxUniforms-1)/osfx::MaxUniforms);
        for(auto it=effect.pages.lower_bound(count);it!=effect.pages.end();)it=effect.pages.erase(it);
        effect.next=(requestedPage+1)%count;
        exhausted=false;return true;
    }
    bool Next(uint64_t now,osfx::Command& command) {
        if(pending&&now>=started&&now-started<2000)return false;
        if(effects.empty()){pending=0;return false;}
        auto it=effects.upper_bound(last);if(it==effects.end())it=effects.begin();
        last=requested=it->first;requestedPage=it->second.next;
        pending=++serial;started=now;
        command={};command.kind=osfx::Inspect;command.inspectSerial=pending;command.enabled=requestedPage;
        std::strncpy(command.effect,requested.c_str(),sizeof(command.effect)-1);
        return true;
    }
};
}
