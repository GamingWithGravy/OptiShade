// OptiShade additions, GPL-3.0-or-later. POD boundary; no ImGui objects cross DLLs.
#pragma once
#include <cstdint>
namespace optishade::cockpit {
inline constexpr uint32_t Version=1;
enum Field : uint32_t { Enabled=1, Tint=2, Flipped=4, Smoothing=8, Glass=16, All=31 };
struct Snapshot {
 uint32_t version=Version, available=0, fields=0, enabled=0,tint=0,flipped=0,smoothing=35,glass=100;
 uint64_t generation=0, applied=0;
 char report[4096]{};
};
struct Command {uint32_t version=Version,field=0,value=0,reserved=0;uint64_t generation=0,sequence=0;};
inline bool Valid(const Command& c){return c.version==Version&&c.reserved==0&&c.sequence&&c.generation&&
 ((c.field==Enabled||c.field==Tint||c.field==Flipped)?c.value<=1:c.field==Smoothing?c.value<=50:c.field==Glass&&c.value<=100);}
using Read=bool(*)(Snapshot*,uint32_t);
using Send=bool(*)(const Command*,uint32_t);
}
