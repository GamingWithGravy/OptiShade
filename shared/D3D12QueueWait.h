#pragma once
#include <d3d12.h>
#include <cstdint>
#include <dxgi.h>
#include <wrl/client.h>
namespace optishade {
// A fence belongs to this queue's actual device, never a global adapter selection.
// Polling avoids leaving a pending event notification behind on the timeout path.
inline HRESULT WaitForQueueIdle(IUnknown* object, DWORD timeoutMs = 5000) {
    if (!object) return E_POINTER;
    Microsoft::WRL::ComPtr<ID3D12CommandQueue> queue;
    HRESULT result = object->QueryInterface(IID_PPV_ARGS(&queue));
    if (result == E_NOINTERFACE) return S_FALSE; // D3D11: no D3D12 queue to drain.
    if (FAILED(result)) return result;
    Microsoft::WRL::ComPtr<ID3D12Device> device;
    result = queue->GetDevice(IID_PPV_ARGS(&device));
    if (FAILED(result)) return result;
    Microsoft::WRL::ComPtr<ID3D12Fence> fence;
    result = device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence));
    if (FAILED(result)) return result;
    result = queue->Signal(fence.Get(), 1);
    if (FAILED(result)) return result;
    const ULONGLONG start = GetTickCount64();
    for (;;) {
        const UINT64 completed = fence->GetCompletedValue();
        if (completed == UINT64_MAX) {
            result = device->GetDeviceRemovedReason();
            return FAILED(result) ? result : DXGI_ERROR_DEVICE_REMOVED;
        }
        if (completed >= 1) return S_OK;
        result = device->GetDeviceRemovedReason();
        if (FAILED(result)) return result;
        if (GetTickCount64() - start >= timeoutMs) return DXGI_ERROR_WAS_STILL_DRAWING;
        Sleep(1);
    }
}
}
