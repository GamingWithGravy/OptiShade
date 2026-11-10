#pragma once
#include <Windows.h>
#include <sl.h>
#include <sl_dlss_g.h>
#include <sl_pcl.h>
#include <cwchar>
namespace optishade::external_fg {
inline bool NativeProviderObserver(bool external,bool observer,bool managedInput){return external||(observer&&!managedInput);}
inline thread_local unsigned markerDepth=0;
inline bool PublicObserver(bool external,bool observer){return external&&observer;}
template<class Attach> bool Install(bool external,bool observer,Attach attach){if(!PublicObserver(external,observer))return false;return attach();}
inline bool PluginDetours(bool external){return !external;}
inline bool ManagedSwapchain(bool external){return !external;}
using Resolver=sl::Result(*)(sl::Feature,const char*,void*&);
// Resolve through the current interposer on every invocation. Never cache a
// plugin-local target. Pin its containing module for the duration of this call.
template<class F> class Target {
 HMODULE pin=nullptr;
public:
 F function=nullptr;
 Target(Resolver resolve,sl::Feature feature,const char* name){void* raw=nullptr;
  if(resolve&&resolve(feature,name,raw)==sl::Result::eOk&&raw&&GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,reinterpret_cast<LPCWSTR>(raw),&pin)){void* current=nullptr;if(resolve(feature,name,current)==sl::Result::eOk&&current==raw)function=reinterpret_cast<F>(raw);}
 }
 ~Target(){if(pin)FreeLibrary(pin);}
 uint64_t NativeIdentity() const {
  wchar_t path[32768]{};if(!function||!pin||!GetModuleFileNameW(pin,path,32768))return 0;
  const auto* name=wcsrchr(path,L'\\');name=name?name+1:path;
  // Compatibility wrappers retain their own control transport. This lane
  // only controls the resolved native Streamline DLSS-G plugin.
  return _wcsicmp(name,L"sl.dlss_g.dll")==0?reinterpret_cast<uint64_t>(pin):0;
 }
 Target(const Target&)=delete;Target& operator=(const Target&)=delete;
};
template<class Observe> sl::Result SetOptions(Resolver resolve,const sl::ViewportHandle& view,const sl::DLSSGOptions& options,Observe observe){
 Target<decltype(&slDLSSGSetOptions)> target(resolve,sl::kFeatureDLSS_G,"slDLSSGSetOptions");
 if(!target.function)return sl::Result::eErrorFeatureMissing;
 auto result=target.function(view,options);if(result==sl::Result::eOk)observe(view,options);return result;
}
template<class Observe> sl::Result GetState(Resolver resolve,const sl::ViewportHandle& view,sl::DLSSGState& state,const sl::DLSSGOptions* options,Observe observe){
 Target<decltype(&slDLSSGGetState)> target(resolve,sl::kFeatureDLSS_G,"slDLSSGGetState");
 if(!target.function)return sl::Result::eErrorFeatureMissing;
 auto result=target.function(view,state,options);if(result==sl::Result::eOk)observe(view,state);return result;
}
template<class Call,class Before,class After> sl::Result DispatchMarker(sl::PCLMarker marker,const sl::FrameToken& frame,Call call,Before before,After after){
 struct Guard {Guard(){++markerDepth;}~Guard(){--markerDepth;}} guard;
 const bool outer=markerDepth==1;
 if(outer&&marker==sl::PCLMarker::ePresentStart)before(frame);
 auto result=call(marker,frame);
 if(outer&&marker==sl::PCLMarker::ePresentEnd)after(frame,result);
 return result;
}
template<class Before,class After> sl::Result Marker(Resolver resolve,sl::Feature feature,const char* name,sl::PCLMarker marker,const sl::FrameToken& frame,Before before,After after){
 Target<decltype(&slPCLSetMarker)> target(resolve,feature,name);
 if(!target.function)return sl::Result::eErrorFeatureMissing;
 return DispatchMarker(marker,frame,target.function,before,after);
}
}
