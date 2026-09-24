#pragma once
#include <cstdint>
// OptiShade's private, versioned C ABI. No ImGui objects or runtime pointers cross DLLs.
namespace osfx {
constexpr uint32_t Version=7, MaxTechniques=4096, MaxUniforms=512;
enum Kind:uint32_t { Effects=1, Reload, Preset, Technique, Uniform, Save, Load, Inspect, SaveAs, Discard, PerformanceMode, HotSwapPreset };
struct TechniqueInfo {char effect[128],name[128];uint32_t enabled;};
struct UniformInfo {char effect[128],name[128],label[128];uint32_t type,count;float value[16];uint32_t hasRange;float minimum,maximum;};
struct Snapshot {uint32_t version,connected,loading,compileOK,enabled,techniques,uniforms,truncated;uint64_t generation,frames,effectFrames,applied,rejected,saveSerial;uint32_t saveOK,dirty,performanceMode;char savePath[1024];char preset[1024];TechniqueInfo technique[MaxTechniques];UniformInfo uniform[MaxUniforms];};
struct Command {uint32_t version,kind;uint64_t generation;char effect[128],name[128],path[1024];uint32_t enabled,count;float value[16];};
using Read=bool(*)(Snapshot*,uint32_t);
using Send=bool(*)(const Command*,uint32_t);
}
