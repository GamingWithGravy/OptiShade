// CPU-only doubles for executing the real ProducerDependencies decision code.
// These deliberately do NOT simulate GPU execution, COM lifetime or a driver.
#pragma once
#include <cstdint>
#include <utility>
#define FAILED(x) ((x)<0)
#define IID_PPV_ARGS(x) (x)
constexpr int D3D12_COMMAND_LIST_TYPE_DIRECT=0;
struct ID3D12Device {};
struct ID3D12CommandList {};
struct ID3D12Fence {uint64_t completed=0;uint64_t GetCompletedValue(){return completed;}};
struct ID3D12CommandQueue {
 struct Desc{int Type=0;};ID3D12Device* device=nullptr;int waits=0;int waitResult=0;
 Desc GetDesc(){return {};}
 int GetDevice(ID3D12Device** out){*out=device;return device?0:-1;}
 int Wait(ID3D12Fence*,uint64_t){++waits;return waitResult;}
};
namespace Microsoft::WRL {template<class T> class ComPtr {T* value=nullptr;public:
 ComPtr()=default;ComPtr(T* p):value(p){};T* Get()const{return value;}T** operator&(){return &value;}T* operator->()const{return value;}explicit operator bool()const{return value!=nullptr;}void Attach(T* p){value=p;}
 bool operator==(const ComPtr& b)const{return value==b.value;}bool operator!=(const ComPtr& b)const{return value!=b.value;}
};}
namespace optishade {
inline Microsoft::WRL::ComPtr<ID3D12Device> ReShadeDeviceIdentity(ID3D12Device* d){return d;}
template<class T> T* ReShadeObjectIdentity(T* p){return p;}
namespace route {
enum class RecordingPhase:uint32_t{Recording,Closed,Submitted,Abandoned};enum class SubmissionEvent {Query};
struct SubmissionRequest {SubmissionEvent event{};uint64_t command=0,generation=0;};
struct SubmissionResult {uint64_t queue=0,fence=0,device=0,generation=0,epoch=0,fenceValue=0;RecordingPhase phase{};};
using SubmissionCall=bool(*)(const SubmissionRequest*,uint32_t,SubmissionResult*,uint32_t);
}}
