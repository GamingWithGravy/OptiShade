#pragma once
#include "D3D12FrameContext.h"
namespace optishade::nr {
// A frame counter is not evidence of creation-command submission. Retain the
// exact command identity and require a real post-Execute GPU fence completion.
class CreationCompletion {
    Microsoft::WRL::ComPtr<IUnknown> command;
    Microsoft::WRL::ComPtr<ID3D12Fence> fence;
    bool submitted=false, failed=false;
public:
    bool Arm(ID3D12GraphicsCommandList* commands) {
        command=ReShadeObjectIdentity(commands);fence.Reset();submitted=false;failed=false;
        Microsoft::WRL::ComPtr<ID3D12Device> device;
        if(!command || FAILED(commands->GetDevice(IID_PPV_ARGS(&device))) ||
           FAILED(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&fence)))) failed=true;
        return !failed;
    }
    void Submitted(ID3D12CommandQueue* queue,UINT count,ID3D12CommandList*const* lists) {
        if(!command || submitted || failed)return;
        for(UINT i=0;i<count;++i)if(ReShadeObjectIdentity(lists[i])==command) {
            submitted=true;failed=FAILED(queue->Signal(fence.Get(),1));return;
        }
    }
    void Abandoned(ID3D12CommandList* commands) {
        if(command && !submitted && ReShadeObjectIdentity(commands)==command)failed=true;
    }
    bool Failed()const {return failed || (fence && fence->GetCompletedValue()==UINT64_MAX);}
    bool Ready()const {return submitted && !Failed() && fence && fence->GetCompletedValue()>=1;}
};
}
