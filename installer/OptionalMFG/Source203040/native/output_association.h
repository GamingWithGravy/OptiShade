// OptiShade D3D12 presentation evidence. GPL-3.0-or-later.
#pragma once
#include "output_owner.h"
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <atomic>
#include <mutex>
namespace optishade::mfg::output {
inline Owner& owner=*new Owner;inline std::mutex& mutex=*new std::mutex;
inline constexpr GUID lifetimeGuid={0x6c73562f,0x3fa3,0x4b8e,{0x83,0x62,0x3d,0x76,0xc2,0x6e,0xe2,0x91}};
inline std::atomic<uint64_t> serial{1};inline std::mutex identityMutex;
// A private-data object follows COM lifetime without retaining its host. Its
// destructor retires CPU evidence only; the provider owns all GPU resources.
class Lifetime final:public IUnknown {
 std::atomic<ULONG> refs{1};
public:
 const uint64_t id=serial++;const bool target;
 explicit Lifetime(bool t):target(t){}
 HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,void** out)override{if(!out)return E_POINTER;*out=nullptr;if(riid!=IID_IUnknown&&riid!=lifetimeGuid)return E_NOINTERFACE;*out=static_cast<IUnknown*>(this);AddRef();return S_OK;}
 ULONG STDMETHODCALLTYPE AddRef()override{return ++refs;}
 ULONG STDMETHODCALLTYPE Release()override{auto n=--refs;if(!n){if(target){std::lock_guard lock(mutex);owner.Destroy(id);}delete this;}return n;}
};
template<class T> uint64_t Identity(T* object,bool target=false){
 if(!object)return 0;std::lock_guard lock(identityMutex);IUnknown* value=nullptr;UINT size=sizeof(value);
 if(SUCCEEDED(object->GetPrivateData(lifetimeGuid,&size,&value))&&value){auto* token=static_cast<Lifetime*>(value);auto id=token->id;value->Release();return id;}
 auto* token=new Lifetime(target);auto id=token->id;auto hr=object->SetPrivateDataInterface(lifetimeGuid,token);token->Release();return SUCCEEDED(hr)?id:0;
}
inline uint64_t Device(ID3D12Resource* resource){ID3D12Device* d=nullptr;if(!resource||FAILED(resource->GetDevice(IID_PPV_ARGS(&d))))return 0;auto id=Identity(d);d->Release();return id;}
inline void Presented(IDXGISwapChain* swap){
 if(!swap)return;IDXGISwapChain3* s=nullptr;if(FAILED(swap->QueryInterface(IID_PPV_ARGS(&s))))return;
 DXGI_SWAP_CHAIN_DESC desc{};if(FAILED(s->GetDesc(&desc))||!desc.BufferCount||desc.BufferCount>16){s->Release();return;}
 auto target=Identity(s,true);std::vector<uint64_t> buffers;uint64_t device=0;
 for(UINT i=0;i<desc.BufferCount;++i){ID3D12Resource* r=nullptr;if(FAILED(s->GetBuffer(i,IID_PPV_ARGS(&r)))){buffers.clear();break;}auto d=Device(r);if(device&&d!=device){r->Release();buffers.clear();break;}device=d;buffers.push_back(Identity(r));r->Release();}
 // No references to buffers survive this callback, so ResizeBuffers and GPU
 // completion remain the host/provider's responsibility.
 s->Release();std::lock_guard lock(mutex);owner.Present(target,device,std::move(buffers),GetTickCount64());
}
inline Ticket Begin(Key key){std::lock_guard lock(mutex);return owner.Begin(key);}
inline Snapshot Read(){std::lock_guard lock(mutex);return owner.Read(GetTickCount64());}
inline bool Owns(const Ticket&t){std::lock_guard lock(mutex);return owner.Owns(t,GetTickCount64());}
}
