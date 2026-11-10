#pragma once
#include "SimulatorRoute.h"
#include "VulkanPresentObservation.h"
#include "VulkanSubmitObservation.h"
#include "VulkanSyncObservation.h"
#include <psapi.h>
#include <atomic>
// Discover a game-local Vulkan consumer by its bound simulator/API contract,
// not by a DXGI proxy name. Never use a system DLL or another simulator adapter.
inline HMODULE OptiShadeVulkanConsumer(){
 wchar_t exe[32768]{};if(!GetModuleFileNameW(nullptr,exe,32768))return nullptr;
 auto* slash=wcsrchr(exe,L'\\');if(!slash)return nullptr;*slash=0;
 HMODULE modules[1024]{};DWORD needed=0;
 if(!K32EnumProcessModules(GetCurrentProcess(),modules,sizeof(modules),&needed)||needed>sizeof(modules))return nullptr;
 for(DWORD i=0;i<needed/sizeof(HMODULE);++i){
  auto query=reinterpret_cast<optishade::route::Query>(GetProcAddress(modules[i],"OptiShadeCoreSimulatorRoute"));
  if(!query)continue;
  wchar_t path[32768]{};if(!GetModuleFileNameW(modules[i],path,32768))continue;
  auto* end=wcsrchr(path,L'\\');if(!end)continue;*end=0;if(_wcsicmp(path,exe)!=0)continue;
  optishade::route::Descriptor d;
  if(query(&d,sizeof(d))&&d.size==sizeof(d)&&d.abi==optishade::route::Abi&&((d.simulator==optishade::route::Simulator::XPlane12&&d.api==optishade::route::Api::Vulkan)||(d.simulator==optishade::route::Simulator::Unknown&&d.api==optishade::route::Api::Dx12))&&GetProcAddress(modules[i],"OptiShadeVulkanNrRequested")&&GetProcAddress(modules[i],"OptiShadeVulkanOwnsWindow"))return modules[i];
 }
 return nullptr;
}
inline bool OptiShadeIsOwnedVulkanWindow(void* hwnd){
 auto module=OptiShadeVulkanConsumer();
 auto owns=module?reinterpret_cast<bool(*)(uint64_t)>(GetProcAddress(module,"OptiShadeVulkanOwnsWindow")):nullptr;
 return owns&&owns(reinterpret_cast<uint64_t>(hwnd));
}
inline optishade::vulkan_present_observation::Observer OptiShadeVulkanPresentObserver(){
 using Observer=optishade::vulkan_present_observation::Observer;
 static std::atomic<Observer> observer{nullptr};
 static std::atomic<ULONGLONG> retryAt{0};
 if(auto callback=observer.load(std::memory_order_acquire))return callback;
 const auto now=GetTickCount64();auto retry=retryAt.load(std::memory_order_relaxed);
 if(now<retry||!retryAt.compare_exchange_strong(retry,now+1000,std::memory_order_relaxed))return nullptr;
 const auto module=OptiShadeVulkanConsumer();
 auto callback=module?reinterpret_cast<Observer>(GetProcAddress(module,"OptiShadeVulkanNrPresentObserved")):nullptr;
 if(callback)observer.store(callback,std::memory_order_release);
 return callback;
}
inline void OptiShadeVulkanNotifyPresent(const optishade::vulkan_present_observation::Snapshot& snapshot){
 if(auto observer=OptiShadeVulkanPresentObserver())observer(&snapshot);
}
inline optishade::vulkan_submit_observation::Observer OptiShadeVulkanSubmitObserver(){
 using Observer=optishade::vulkan_submit_observation::Observer;
 static std::atomic<Observer> observer{nullptr};
 static std::atomic<ULONGLONG> retryAt{0};
 if(auto callback=observer.load(std::memory_order_acquire))return callback;
 const auto now=GetTickCount64();auto retry=retryAt.load(std::memory_order_relaxed);
 if(now<retry||!retryAt.compare_exchange_strong(retry,now+1000,std::memory_order_relaxed))return nullptr;
 const auto module=OptiShadeVulkanConsumer();
 auto callback=module?reinterpret_cast<Observer>(GetProcAddress(module,"OptiShadeVulkanNrQueueSubmitObserved")):nullptr;
 if(callback)observer.store(callback,std::memory_order_release);
 return callback;
}
inline void OptiShadeVulkanNotifySubmit(const optishade::vulkan_submit_observation::Snapshot& snapshot){
 if(auto observer=OptiShadeVulkanSubmitObserver())observer(&snapshot);
}
inline optishade::vulkan_sync_observation::Observer OptiShadeVulkanSyncObserver(){
 using Observer=optishade::vulkan_sync_observation::Observer;
 static std::atomic<Observer> observer{nullptr};
 static std::atomic<ULONGLONG> retryAt{0};
 if(auto callback=observer.load(std::memory_order_acquire))return callback;
 const auto now=GetTickCount64();auto retry=retryAt.load(std::memory_order_relaxed);
 if(now<retry||!retryAt.compare_exchange_strong(retry,now+1000,std::memory_order_relaxed))return nullptr;
 const auto module=OptiShadeVulkanConsumer();
 auto callback=module?reinterpret_cast<Observer>(GetProcAddress(module,"OptiShadeVulkanNrSyncObjectObserved")):nullptr;
 if(callback)observer.store(callback,std::memory_order_release);
 return callback;
}
inline void OptiShadeVulkanNotifySync(const optishade::vulkan_sync_observation::Event& event){
 if(auto observer=OptiShadeVulkanSyncObserver())observer(&event);
}
