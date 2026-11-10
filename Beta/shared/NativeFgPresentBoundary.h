#pragma once
#include <windows.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <mutex>
#include <atomic>
#include <sl.h>
#include "detours/detours.h"
namespace optishade::native_fg_boundary {
using Before=void(*)(IDXGISwapChain*);using After=void(*)(IDXGISwapChain*,HRESULT);
using Inspect=void(*)(IDXGISwapChain*,UINT,UINT);inline Inspect inspect=nullptr;
inline Before before=nullptr;inline After after=nullptr;inline HMODULE provider=nullptr;
inline std::recursive_mutex mutex;inline std::atomic<bool> ready=false;
struct Hook {void* target=nullptr;void* call=nullptr;void* replacement=nullptr;std::atomic<void*> invoke{nullptr};};
inline Hook factory0,factory1,factory2,upgrade,create0,createHwnd,createCore,createComposition,present,present1;
inline bool Installed(){for(auto* h:{&factory0,&factory1,&factory2,&upgrade,&create0,&createHwnd,&createCore,&createComposition,&present,&present1})if(h->target)return true;return false;}
inline bool PinModule(const void* address){HMODULE held=nullptr;return address&&GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_PIN,reinterpret_cast<LPCWSTR>(address),&held);}
inline bool Attach(Hook& h,void* address,void* replacement){
 if(!address)return false;std::lock_guard guard(mutex);
 if(h.target)return h.target==address;
 HMODULE module=nullptr;GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,reinterpret_cast<LPCWSTR>(address),&module);
 if(module!=provider)return false; // Never detour an unrelated native/overlay implementation.
 // Both sides of a live trampoline remain valid for the process lifetime.
 // Removal is refused until a separate, fully quiescent teardown is available.
 if(!PinModule(address)||!PinModule(replacement))return false;
 if(DetourTransactionBegin()!=NO_ERROR)return false;
 h.call=address;
 if(DetourUpdateThread(GetCurrentThread())!=NO_ERROR){DetourTransactionAbort();h.call=nullptr;return false;}
 // Publish the prepared x64 trampoline before Commit patches the entry.
 // Readers never take the installation/loader lock or wait for publication.
 PDETOUR_TRAMPOLINE trampoline=nullptr;
 auto result=DetourAttachEx(&h.call,replacement,&trampoline,nullptr,nullptr);
 if(result!=NO_ERROR){DetourTransactionAbort();h.call=nullptr;return false;}
 h.invoke.store(reinterpret_cast<void*>(trampoline),std::memory_order_release);
 if(DetourTransactionCommit()!=NO_ERROR){h.invoke.store(nullptr,std::memory_order_release);h.call=nullptr;return false;}
 h.target=address;h.replacement=replacement;return true;
}
inline void* Call(const Hook& hook){return hook.invoke.load(std::memory_order_acquire);}
inline thread_local unsigned depth=0;
struct Scope {bool outer;Scope():outer(++depth==1){}~Scope(){--depth;}};
inline HRESULT STDMETHODCALLTYPE Present(IDXGISwapChain* s,UINT interval,UINT flags){
 auto call=Call(present);
 Scope scope;const bool run=scope.outer&&!(flags&DXGI_PRESENT_TEST);
 if(run&&inspect)inspect(s,interval,flags);
 if(run&&before)before(s);
 auto hr=reinterpret_cast<HRESULT(STDMETHODCALLTYPE*)(IDXGISwapChain*,UINT,UINT)>(call)(s,interval,flags);
 if(run&&after)after(s,hr);return hr;
}
inline HRESULT STDMETHODCALLTYPE Present1(IDXGISwapChain1* s,UINT interval,UINT flags,const DXGI_PRESENT_PARAMETERS* parameters){
 auto call=Call(present1);
 Scope scope;const bool run=scope.outer&&!(flags&DXGI_PRESENT_TEST);
 if(run&&inspect)inspect(s,interval,flags);
 if(run&&before)before(s);
 auto hr=reinterpret_cast<HRESULT(STDMETHODCALLTYPE*)(IDXGISwapChain1*,UINT,UINT,const DXGI_PRESENT_PARAMETERS*)>(call)(s,interval,flags,parameters);
 if(run&&after)after(s,hr);return hr;
}
inline void Swap(IUnknown* object){
 if(!object)return;Microsoft::WRL::ComPtr<IDXGISwapChain1> s;
 if(FAILED(object->QueryInterface(IID_PPV_ARGS(&s))))return;
 auto table=*reinterpret_cast<void***>(s.Get());
 bool a=Attach(present,table[8],reinterpret_cast<void*>(Present));
 bool b=Attach(present1,table[22],reinterpret_cast<void*>(Present1));
 if(a&&b)ready.store(true,std::memory_order_release);
}
inline HRESULT STDMETHODCALLTYPE Create0(IDXGIFactory* f,IUnknown* d,DXGI_SWAP_CHAIN_DESC* desc,IDXGISwapChain** out){
 auto hr=reinterpret_cast<HRESULT(STDMETHODCALLTYPE*)(IDXGIFactory*,IUnknown*,DXGI_SWAP_CHAIN_DESC*,IDXGISwapChain**)>(Call(create0))(f,d,desc,out);if(SUCCEEDED(hr)&&out)Swap(*out);return hr;
}
inline HRESULT STDMETHODCALLTYPE CreateHwnd(IDXGIFactory2* f,IUnknown* d,HWND w,const DXGI_SWAP_CHAIN_DESC1* desc,const DXGI_SWAP_CHAIN_FULLSCREEN_DESC* full,IDXGIOutput* restrictOutput,IDXGISwapChain1** out){
 auto hr=reinterpret_cast<HRESULT(STDMETHODCALLTYPE*)(IDXGIFactory2*,IUnknown*,HWND,const DXGI_SWAP_CHAIN_DESC1*,const DXGI_SWAP_CHAIN_FULLSCREEN_DESC*,IDXGIOutput*,IDXGISwapChain1**)>(Call(createHwnd))(f,d,w,desc,full,restrictOutput,out);if(SUCCEEDED(hr)&&out)Swap(*out);return hr;
}
inline HRESULT STDMETHODCALLTYPE CreateCore(IDXGIFactory2* f,IUnknown* d,IUnknown* w,const DXGI_SWAP_CHAIN_DESC1* desc,IDXGIOutput* restrictOutput,IDXGISwapChain1** out){
 auto hr=reinterpret_cast<HRESULT(STDMETHODCALLTYPE*)(IDXGIFactory2*,IUnknown*,IUnknown*,const DXGI_SWAP_CHAIN_DESC1*,IDXGIOutput*,IDXGISwapChain1**)>(Call(createCore))(f,d,w,desc,restrictOutput,out);if(SUCCEEDED(hr)&&out)Swap(*out);return hr;
}
inline HRESULT STDMETHODCALLTYPE CreateComposition(IDXGIFactory2* f,IUnknown* d,const DXGI_SWAP_CHAIN_DESC1* desc,IDXGIOutput* restrictOutput,IDXGISwapChain1** out){
 auto hr=reinterpret_cast<HRESULT(STDMETHODCALLTYPE*)(IDXGIFactory2*,IUnknown*,const DXGI_SWAP_CHAIN_DESC1*,IDXGIOutput*,IDXGISwapChain1**)>(Call(createComposition))(f,d,desc,restrictOutput,out);if(SUCCEEDED(hr)&&out)Swap(*out);return hr;
}
inline void Factory(IUnknown* object){
 if(!object)return;Microsoft::WRL::ComPtr<IDXGIFactory2> f;if(FAILED(object->QueryInterface(IID_PPV_ARGS(&f))))return;
 auto table=*reinterpret_cast<void***>(f.Get());Attach(create0,table[10],reinterpret_cast<void*>(Create0));Attach(createHwnd,table[15],reinterpret_cast<void*>(CreateHwnd));Attach(createCore,table[16],reinterpret_cast<void*>(CreateCore));Attach(createComposition,table[24],reinterpret_cast<void*>(CreateComposition));
}
inline HRESULT WINAPI Factory0(REFIID id,void** out){auto hr=reinterpret_cast<HRESULT(WINAPI*)(REFIID,void**)>(Call(factory0))(id,out);if(SUCCEEDED(hr)&&out)Factory(static_cast<IUnknown*>(*out));return hr;}
inline HRESULT WINAPI Factory1(REFIID id,void** out){auto hr=reinterpret_cast<HRESULT(WINAPI*)(REFIID,void**)>(Call(factory1))(id,out);if(SUCCEEDED(hr)&&out)Factory(static_cast<IUnknown*>(*out));return hr;}
inline HRESULT WINAPI Factory2(UINT flags,REFIID id,void** out){auto hr=reinterpret_cast<HRESULT(WINAPI*)(UINT,REFIID,void**)>(Call(factory2))(flags,id,out);if(SUCCEEDED(hr)&&out)Factory(static_cast<IUnknown*>(*out));return hr;}
inline sl::Result Upgrade(void** out){auto result=reinterpret_cast<sl::Result(*)(void**)>(Call(upgrade))(out);if(result==sl::Result::eOk&&out&&*out){Factory(static_cast<IUnknown*>(*out));Swap(static_cast<IUnknown*>(*out));}return result;}
inline void Install(HMODULE module,Before b,After a,Inspect info=nullptr){
 std::lock_guard guard(mutex);if(provider&&(provider!=module||Installed()))return;provider=module;before=b;after=a;inspect=info;
 Attach(factory0,reinterpret_cast<void*>(GetProcAddress(module,"CreateDXGIFactory")),reinterpret_cast<void*>(Factory0));
 Attach(factory1,reinterpret_cast<void*>(GetProcAddress(module,"CreateDXGIFactory1")),reinterpret_cast<void*>(Factory1));
 Attach(factory2,reinterpret_cast<void*>(GetProcAddress(module,"CreateDXGIFactory2")),reinterpret_cast<void*>(Factory2));
 Attach(upgrade,reinterpret_cast<void*>(GetProcAddress(module,"slUpgradeInterface")),reinterpret_cast<void*>(Upgrade));
}
inline bool Remove(){
 std::lock_guard guard(mutex);
 // Enlisting only the caller cannot prove that another thread has returned
 // from Present (or a factory trampoline). Do not release those functions or
 // switch interposer state beneath it. A live provider change needs restart.
 if(Installed())return false;
 provider=nullptr;before=nullptr;after=nullptr;inspect=nullptr;ready=false;return true;
}
}
