#pragma once
#include <cstddef>
#include <cstdint>
// OptiShade's private, versioned C ABI. No ImGui objects or runtime pointers cross DLLs.
namespace osfx {
constexpr uint32_t Version=15, MaxTechniques=4096, MaxUniforms=512, EditAckCapacity=64;
enum Kind:uint32_t { Effects=1, Reload, Preset, Technique, Uniform, Save, Load, Inspect, SaveAs, Discard, PerformanceMode, HotSwapPreset, TakeSnapshot, LinkVR };
enum UiKind:uint32_t { UiDefault=0, UiSlider, UiDrag, UiCombo, UiList, UiRadio, UiColor, UiButton };
enum EditResult:uint32_t { EditResultNone=0, EditResultApplied, EditResultPerformanceMode, EditResultMissingTarget, EditResultInvalidShape, EditResultInvalidValue, EditResultLimit, EditResultRuntimeChanged, EditResultUnsupported };
struct EditAck {uint64_t sequence=0,request=0;uint32_t result=EditResultNone,reserved=0;char effect[128]{},name[128]{};};
struct EditAckJournal {
 uint64_t sequence=0;EditAck entries[EditAckCapacity]{};
 static void copy(char* destination,std::size_t capacity,const char* source){
  if(!destination||!capacity)return;std::size_t i=0;if(source)for(;i+1<capacity&&source[i];++i)destination[i]=source[i];destination[i]=0;
 }
 void record(uint64_t request,EditResult result,const char* effect,const char* name){
  const uint64_t next=sequence+1;auto& ack=entries[next%EditAckCapacity];ack={};ack.sequence=next;ack.request=request;ack.result=result;
  copy(ack.effect,sizeof(ack.effect),effect);copy(ack.name,sizeof(ack.name),name);
  sequence=next;
 }
};
struct TechniqueInfo {char effect[128],name[128];uint32_t enabled;};
struct UniformInfo {char effect[128],name[128],label[128];uint32_t type,count;float value[16];uint32_t hasRange;float minimum,maximum;uint32_t arrayIndex,arrayCount;int32_t signedValue[16];uint32_t unsignedValue[16];char tooltip[512];uint32_t uiKind,itemsSize;char items[512];};
struct Delivery {uint64_t generation,selected,applied,frames,completed;uint32_t state;};
struct Snapshot {uint32_t version,connected,loading,compileOK,enabled,techniques,uniforms,truncated;uint64_t generation,frames,effectFrames,applied,rejected,saveSerial;uint32_t saveOK,dirty,performanceMode;
 uint64_t snapshotSerial; uint32_t snapshotOK; char snapshotPath[1024];char savePath[1024];char preset[1024];TechniqueInfo technique[MaxTechniques];UniformInfo uniform[MaxUniforms];EditAckJournal editAcks;
 uint32_t presetState,presetRequested,presetApplied,presetMissing;char presetReport[2048];Delivery desktop,headset;uint32_t uniformPage,uniformTotal;uint64_t inspectSerial;char inspectedEffect[128];char inspectedDescription[512];};
struct Command {uint32_t version,kind;uint64_t generation;char effect[128],name[128],path[1024];uint32_t enabled,count;float value[16];uint64_t inspectSerial;uint32_t arrayIndex,type;int32_t signedValue[16];uint32_t unsignedValue[16];uint64_t editRequest;};
using Read=bool(*)(Snapshot*,uint32_t);
using Send=bool(*)(const Command*,uint32_t);
}
