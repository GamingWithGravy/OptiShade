#pragma once
#include <windows.h>
#include <d3d12.h>
#include <wrl/client.h>
#include <array>
#include <algorithm>
#include <cstdint>
namespace optishade {
// Command allocator and ImGui upload-ring lifetimes are different domains.
// Both must retire before a recording slot is reused, including repeated presents
// of the same backbuffer under frame generation.
template<size_t Capacity> class OverlayCompletion {
    Microsoft::WRL::ComPtr<ID3D12Device> device;
    Microsoft::WRL::ComPtr<ID3D12CommandQueue> queue;
    Microsoft::WRL::ComPtr<ID3D12Fence> fence;
    HANDLE event=nullptr;
    std::array<uint64_t,Capacity> buffers{},uploads{};
    uint64_t sequence=0;size_t submission=0;bool needsSignal=false;
public:
    ~OverlayCompletion(){if(event)CloseHandle(event);}
    bool Removed()const{return device&&FAILED(device->GetDeviceRemovedReason());}
    bool Wait(uint64_t value,DWORD timeout=2000){
        if(!value)return true;
        if(!fence||!queue||Removed())return false;
        if(needsSignal){if(FAILED(queue->Signal(fence.Get(),sequence)))return false;needsSignal=false;}
        if(fence->GetCompletedValue()>=value)return fence->GetCompletedValue()!=UINT64_MAX;
        if(!event)event=CreateEventW(nullptr,FALSE,FALSE,nullptr);
        if(!event||FAILED(fence->SetEventOnCompletion(value,event)))return false;
        auto start=GetTickCount64();
        for(;;){
            auto completed=fence->GetCompletedValue();if(completed==UINT64_MAX||Removed())return false;if(completed>=value)return true;
            auto elapsed=GetTickCount64()-start;if(elapsed>=timeout)return false;
            if(WaitForSingleObject(event,static_cast<DWORD>(std::min<uint64_t>(50,timeout-elapsed)))==WAIT_FAILED)return false;
        }
    }
    bool Drain(){return !sequence||Removed()||Wait(sequence);}
    void Reset(){buffers={};uploads={};sequence=0;submission=0;needsSignal=false;fence.Reset();queue.Reset();device.Reset();}
    bool Prepare(ID3D12Device* d,ID3D12CommandQueue* q,size_t buffer,DWORD timeout=2000){
        if(!d||!q||buffer>=Capacity)return false;
        if(queue&&queue.Get()!=q){if(!Drain())return false;Reset();}
        if(!fence){if(FAILED(d->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&fence))))return false;device=d;queue=q;}
        return !Removed()&&Wait(std::max(buffers[buffer],uploads[submission%Capacity]),timeout);
    }
    bool Submitted(size_t buffer){
        if(!queue||!fence||buffer>=Capacity)return false;
        buffers[buffer]=uploads[submission++%Capacity]=++sequence;
        needsSignal=FAILED(queue->Signal(fence.Get(),sequence));return !needsSignal;
    }
};
}
