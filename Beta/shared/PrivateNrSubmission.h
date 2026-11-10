#pragma once
#include "D3D12FrameContext.h"
namespace optishade::nr {
// Only for our independently recorded NR lists. Never submit game lists here.
// Preserve the actual queue and device, without entering ReShade's queue mutex
// or flushing its unrelated immediate list while NR owns its state lock.
inline HRESULT ClosePrivateRecording(IUnknown* recording) {
 auto identity=ReShadeObjectIdentity(recording);
 Microsoft::WRL::ComPtr<ID3D12GraphicsCommandList> list;
 if(!identity || FAILED(identity.As(&list))) return E_NOINTERFACE;
 return list->Close();
}
inline HRESULT SubmitPrivateRecording(IUnknown* queueObject,IUnknown* recording) {
 auto queueIdentity=ReShadeObjectIdentity(queueObject);
 auto listIdentity=ReShadeObjectIdentity(recording);
 Microsoft::WRL::ComPtr<ID3D12CommandQueue> queue;
 Microsoft::WRL::ComPtr<ID3D12CommandList> list;
 if(!queueIdentity || !listIdentity || FAILED(queueIdentity.As(&queue)) || FAILED(listIdentity.As(&list))) return E_NOINTERFACE;
 if(queue->GetDesc().Type!=D3D12_COMMAND_LIST_TYPE_DIRECT || list->GetType()!=D3D12_COMMAND_LIST_TYPE_DIRECT) return E_INVALIDARG;
 Microsoft::WRL::ComPtr<ID3D12Device> qd,ld;
 if(FAILED(queue->GetDevice(IID_PPV_ARGS(&qd))) || FAILED(list->GetDevice(IID_PPV_ARGS(&ld))) || ReShadeDeviceIdentity(qd.Get())!=ReShadeDeviceIdentity(ld.Get())) return E_INVALIDARG;
 ID3D12CommandList* lists[]={list.Get()};queue->ExecuteCommandLists(1,lists);
 return S_OK; // submission call returned; GPU completion still requires its fence
}
}
