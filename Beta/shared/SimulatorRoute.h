#pragma once
#include <cstdint>
#include <string_view>
namespace optishade::route {
enum class Simulator:uint32_t {Unknown=0,Msfs2024=1,Msfs2020=2,XPlane12=3};
enum class Api:uint32_t {Dx12=1,Vulkan=2};
constexpr uint32_t Abi=5;
inline Simulator Identify(std::wstring_view name) {
 auto equal=[&](std::wstring_view other){if(name.size()!=other.size())return false;for(size_t i=0;i<name.size();++i){auto c=name[i];if(c>=L'A'&&c<=L'Z')c+=L'a'-L'A';if(c!=other[i])return false;}return true;};
 if(equal(L"flightsimulator2024.exe"))return Simulator::Msfs2024;
 if(equal(L"flightsimulator.exe"))return Simulator::Msfs2020;
 if(equal(L"x-plane.exe"))return Simulator::XPlane12;
 return Simulator::Unknown;
}
struct Descriptor {uint32_t size=sizeof(Descriptor),abi=Abi;Simulator simulator{};Api api{};uint32_t externalFgObserver=0;};
// Borrowed handles are validated at the API-specific producer, never retained
// by the routing layer. No texture pointer is promoted to presentation ownership.
struct FrameContext {uint32_t size=sizeof(FrameContext),abi=Abi;Simulator simulator{};Api api{};
 uint64_t device=0,queue=0,colour=0,depth=0,motion=0,frameId=0,presentationOwner=0,presentationGeneration=0;
 uint32_t width=0,height=0;uint64_t command=0,window=0,submissionEpoch=0;};
using Query=bool(*)(Descriptor*,uint32_t);
using Validate=bool(*)(const FrameContext*,uint32_t);
enum class Event:uint32_t {Reset,Token,Constants,Present,Frame,Ambiguous};
struct FrameEventRequest{uint32_t size=sizeof(FrameEventRequest),abi=Abi;Event event{};uint32_t frame=0,view=0;uint64_t owner=0,device=0;};
using FrameEvent=bool(*)(const FrameEventRequest*,uint32_t,uint32_t*);
}

#include "VulkanOwner.h"
namespace optishade::route {
enum class VulkanEvent:uint32_t {Surface,Swapchain,Queue,Present,Lookup,FindQueue,FindSwapchainGeneration,EraseChain,EraseSurface,EraseDevice,EraseInstance};
struct VulkanRequest {uint32_t size=sizeof(VulkanRequest),abi=Abi;VulkanEvent event{};
 uint64_t a=0,b=0,c=0;uint32_t count=0,family=0,imageCount=0;bool eligible=false,alive=false,graphics=false;
 const uint64_t* chains=nullptr;const uint32_t* images=nullptr;};
struct VulkanResult {uint32_t size=sizeof(VulkanResult),abi=Abi;vkowner::Registry::Chain owner{};vkowner::Registry::Surface surface{};vkowner::Registry::Queue queue{};uint64_t generation=0;};
using VulkanCall=bool(*)(const VulkanRequest*,uint32_t,VulkanResult*,uint32_t);
}

namespace optishade::route {
enum class PresentationEvent:uint32_t {Accept,Generation,Advance,Retire};
struct PresentationRequest {uint32_t size=sizeof(PresentationRequest),abi=Abi;PresentationEvent event{};uint64_t window=0,swapchain=0;uint32_t claim=0;};
struct PresentationResult {uint32_t size=sizeof(PresentationResult),abi=Abi;uint64_t generation=0;uint32_t accepted=0;};
using PresentationCall=bool(*)(const PresentationRequest*,uint32_t,PresentationResult*,uint32_t);
}

namespace optishade::route {
enum class SubmissionEvent:uint32_t {Observe,Query,Clear,Recording,Reset,Close,Pin,Unpin};
enum class RecordingPhase:uint32_t {Unknown,Recording,Closed,Submitted,Abandoned};
struct SubmissionRequest {uint32_t size=sizeof(SubmissionRequest),abi=Abi;SubmissionEvent event{};uint64_t command=0,queue=0,generation=0;};
// Query owns references to queue and fence when nonzero. A recording has no
// execution queue until ExecuteCommandLists actually observes that generation.
struct SubmissionResult {uint32_t size=sizeof(SubmissionResult),abi=Abi;uint64_t command=0,device=0,queue=0,epoch=0;uint32_t completed=0;
 uint64_t generation=0,fence=0,fenceValue=0;RecordingPhase phase=RecordingPhase::Unknown;};
using SubmissionCall=bool(*)(const SubmissionRequest*,uint32_t,SubmissionResult*,uint32_t);
}

namespace optishade::route {
enum class ConstantEvent:uint32_t {Store,Read,Consume,Reset};
struct ConstantRequest {uint32_t size=sizeof(ConstantRequest),abi=Abi;ConstantEvent event{};uint32_t frame=0,view=0,payloadBytes=0;const void* payload=nullptr;uint64_t owner=0,device=0;};
using ConstantCall=bool(*)(const ConstantRequest*,uint32_t,void*,uint32_t);
}
