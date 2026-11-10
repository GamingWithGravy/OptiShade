// Trusted source-backend callback published only after hash/receipt validation.
#pragma once
#include <atomic>
#include <windows.h>
#include <dxgi.h>
#include <d3d12.h>
#include <wrl/client.h>
#include <mutex>
#include "D3D12FrameContext.h"
namespace optishade::mfg::source {
using RegisterDevice=BOOL(WINAPI*)(ID3D12Device*);
inline std::atomic<RegisterDevice> registerDevice{nullptr};
// Metadata for Auto admission only. The existing callback owner below keeps
// the COM reference and remains the sole registration/lifetime authority.
inline std::atomic<uint64_t> registeredDeviceIdentity{0};
inline bool BoundToDevice(uint64_t identity){return identity&&registeredDeviceIdentity.load(std::memory_order_acquire)==identity;}
using Present=void(WINAPI*)(IDXGISwapChain*);
inline std::atomic<Present> observePresent{nullptr};
using AcceptedTags=void(WINAPI*)(uint32_t,const void*,uint32_t);
inline std::atomic<AcceptedTags> acceptedTags{nullptr};
inline void ObserveAcceptedTags(uint32_t view,const void* tags,uint32_t count,bool accepted){
 auto fn=acceptedTags.load(std::memory_order_acquire);
 if(fn&&accepted&&tags&&count&&count<=1024)fn(view,tags,count);
}
// Accepted Streamline device is authoritative; registering arbitrary auxiliary
// D3D12 devices would falsely claim a rendering-device replacement.
inline void ObserveDevice(IUnknown* supplied,bool authoritative=false){
 auto registration=registerDevice.load(std::memory_order_acquire);if(!registration||!supplied)return;
 auto identity=optishade::ReShadeObjectIdentity(supplied);Microsoft::WRL::ComPtr<ID3D12Device> device;
 if(!identity||FAILED(identity.As(&device)))return;
 static std::mutex mutex;static Microsoft::WRL::ComPtr<IUnknown> registered;static RegisterDevice callback=nullptr;static Microsoft::WRL::ComPtr<IUnknown> selected;static bool accepted=false;static uint64_t attempted=0;
 std::lock_guard<std::mutex> lock(mutex);
 if(authoritative)selected=identity;else if(selected&&selected!=identity)return;
 const auto now=GetTickCount64();bool changed=registered!=identity||callback!=registration;
 if(changed||(!accepted&&now>=attempted&&now-attempted>=2000)){registeredDeviceIdentity.store(0,std::memory_order_release);accepted=registration(device.Get())!=FALSE;registered=identity;callback=registration;attempted=now;
  if(accepted)registeredDeviceIdentity.store(reinterpret_cast<uint64_t>(identity.Get()),std::memory_order_release);}
}
inline void ObservePresent(IDXGISwapChain* target){
 auto fn=observePresent.load(std::memory_order_acquire);if(!fn||!target)return;
 Microsoft::WRL::ComPtr<ID3D12Device> device;
 if(SUCCEEDED(target->GetDevice(IID_PPV_ARGS(&device))))ObserveDevice(device.Get());
 fn(target);
}
}
