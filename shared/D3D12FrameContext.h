#pragma once
#include <d3d12.h>
#include <wrl/client.h>
namespace optishade {
// Borrowed inputs. Validation never transitions, retains, or submits game resources.
// Capture adapters remain responsible for their documented arrival/return states.
struct D3D12FrameContext {
    ID3D12GraphicsCommandList* commands = nullptr;
    ID3D12Resource* colour = nullptr;
    ID3D12Resource* depth = nullptr;
    ID3D12Resource* motion = nullptr;
    ID3D12Resource* output = nullptr;
    ID3D12Resource* exposure = nullptr; // optional
    ID3D12CommandQueue* queue = nullptr; // optional, for timing/submission only

    const char* ValidateDeviceIdentity(ID3D12Device* backendDevice = nullptr) const {
        if (!commands || !colour || !depth || !motion || !output) return "required frame input is missing";
        Microsoft::WRL::ComPtr<ID3D12Device> device;
        if (FAILED(commands->GetDevice(IID_PPV_ARGS(&device)))) return "command list device is unavailable";
        Microsoft::WRL::ComPtr<IUnknown> identity;
        if (FAILED(device.As(&identity))) return "command list device identity is unavailable";
        if (backendDevice) {
            Microsoft::WRL::ComPtr<IUnknown> backendIdentity;
            if (FAILED(backendDevice->QueryInterface(IID_PPV_ARGS(&backendIdentity))) ||
                backendIdentity.Get() != identity.Get()) return "frame device differs from the backend device";
        }
        ID3D12DeviceChild* inputs[] = {colour, depth, motion, output, exposure, queue};
        for (auto* input : inputs) {
            if (!input) continue;
            Microsoft::WRL::ComPtr<ID3D12Device> owner;
            Microsoft::WRL::ComPtr<IUnknown> ownerIdentity;
            if (FAILED(input->GetDevice(IID_PPV_ARGS(&owner))) || FAILED(owner.As(&ownerIdentity)))
                return "frame input device is unavailable";
            if (ownerIdentity.Get() != identity.Get()) return "frame resources or queue belong to another D3D12 device";
        }
        return nullptr;
    }
};
}
