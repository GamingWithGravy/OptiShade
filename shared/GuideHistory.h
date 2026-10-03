#pragma once
#include <cstdint>
#include <cmath>
namespace optishade::guides {
struct History {
    bool seen=false,reversed=false,logarithmic=false;
    float multiplier=1;uint64_t last=0,frameGeneration=0;
    bool Observe(bool reverse,bool logarithm,float scale,uint64_t fg,uint64_t now){
        const bool reset=!seen||reverse!=reversed||logarithm!=logarithmic||scale!=multiplier||fg!=frameGeneration||now<last||now-last>500;
        seen=true;reversed=reverse;logarithmic=logarithm;multiplier=scale;frameGeneration=fg;last=now;return reset;
    }
};
}
