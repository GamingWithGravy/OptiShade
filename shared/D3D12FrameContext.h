#pragma once
#include <d3d12.h>
#include <wrl/client.h>
namespace optishade {
inline constexpr GUID ReShadeUnwrappedObject = {0x7f2c9a11,0x3b4e,0x4d6a,{0x81,0x2f,0x5e,0x9c,0xd3,0x7a,0x1b,0x42}};
// ReShade's explicit QueryInterface contract for its underlying COM object.
// Used only by the independent guide-input path, never an adapter-ID shortcut.
inline Microsoft::WRL::ComPtr<IUnknown> ReShadeDeviceIdentity(ID3D12Device* device) {
    Microsoft::WRL::ComPtr<IUnknown> object;
    if (!device || FAILED(device->QueryInterface(IID_PPV_ARGS(&object)))) return {};
    for (unsigned i = 0; i < 4; ++i) {
        Microsoft::WRL::ComPtr<IUnknown> original, identity;
        if (FAILED(object->QueryInterface(ReShadeUnwrappedObject, reinterpret_cast<void**>(original.GetAddressOf())))) break;
        if (!original || FAILED(original.As(&identity))) return {};
        if (identity == object) break;
        object = identity;
    }
    return object;
}
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

    const char* ValidateDeviceIdentity(ID3D12Device* backendDevice = nullptr, bool unwrapReShade = false) const {
        if (!commands || !colour || !depth || !motion || !output) return "required frame input is missing";
        Microsoft::WRL::ComPtr<ID3D12Device> device;
        if (FAILED(commands->GetDevice(IID_PPV_ARGS(&device)))) return "command list device is unavailable";
        Microsoft::WRL::ComPtr<IUnknown> identity;
        if (FAILED(device.As(&identity))) return "command list device identity is unavailable";
        if (unwrapReShade) identity = ReShadeDeviceIdentity(device.Get());
        if (!identity) return "command list device identity is unavailable";
        if (backendDevice) {
            Microsoft::WRL::ComPtr<IUnknown> backendIdentity;
            if (unwrapReShade) backendIdentity = ReShadeDeviceIdentity(backendDevice);
            else backendDevice->QueryInterface(IID_PPV_ARGS(&backendIdentity));
            if (!backendIdentity ||
                backendIdentity.Get() != identity.Get()) return "frame device differs from the backend device";
        }
        ID3D12DeviceChild* inputs[] = {colour, depth, motion, output, exposure, queue};
        for (auto* input : inputs) {
            if (!input) continue;
            Microsoft::WRL::ComPtr<ID3D12Device> owner;
            Microsoft::WRL::ComPtr<IUnknown> ownerIdentity;
            if (FAILED(input->GetDevice(IID_PPV_ARGS(&owner))) || FAILED(owner.As(&ownerIdentity)))
                return "frame input device is unavailable";
            if (unwrapReShade) ownerIdentity = ReShadeDeviceIdentity(owner.Get());
            if (ownerIdentity.Get() != identity.Get()) return "frame resources or queue belong to another D3D12 device";
        }
        return nullptr;
    }
};
}
