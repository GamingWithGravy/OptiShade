#pragma once
#include <d3d12.h>
#include <dxgi1_4.h>
#include <wrl/client.h>
#include "RenderingCapability.h"
namespace optishade {
// Measured on the supplied rendering device. Hardware eligibility is not runtime success.
struct D3D12Capabilities {
    LUID adapter{};
    UINT vendor = 0, device = 0;
    bool identified = false, software = false;
    HRESULT health = E_POINTER;
    Evidence native16 = Evidence::Unknown;
    Evidence waves = Evidence::Unknown;
};
inline D3D12Capabilities QueryD3D12Capabilities(ID3D12Device* device) {
    D3D12Capabilities result;
    if (!device) return result;
    result.adapter = device->GetAdapterLuid();
    result.health = device->GetDeviceRemovedReason();
    Microsoft::WRL::ComPtr<IDXGIFactory4> factory;
    Microsoft::WRL::ComPtr<IDXGIAdapter1> adapter;
    DXGI_ADAPTER_DESC1 desc{};
    if (SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))) &&
        SUCCEEDED(factory->EnumAdapterByLuid(result.adapter, IID_PPV_ARGS(&adapter))) &&
        SUCCEEDED(adapter->GetDesc1(&desc))) {
        result.identified = true; result.vendor = desc.VendorId; result.device = desc.DeviceId;
        result.software = (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0;
    }
    D3D12_FEATURE_DATA_D3D12_OPTIONS1 options1{};
    if (SUCCEEDED(device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS1, &options1, sizeof(options1))))
        result.waves = options1.WaveOps ? Evidence::Yes : Evidence::No;
    D3D12_FEATURE_DATA_D3D12_OPTIONS4 options4{};
    if (SUCCEEDED(device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS4, &options4, sizeof(options4))))
        result.native16 = options4.Native16BitShaderOpsSupported ? Evidence::Yes : Evidence::No;
    return result;
}
inline const char* NvidiaNeuralPreflight(const D3D12Capabilities& caps) {
    if (FAILED(caps.health)) return "Rendering device is unavailable or removed";
    if (!caps.identified) return "Rendering adapter could not be identified";
    if (caps.software) return "Software rendering is not supported by the NVIDIA neural backend";
    if (caps.vendor != 0x10de) return "No compatible neural backend is integrated for this adapter; FSR/XeSS and effects remain separate";
    return nullptr; // NGX and the model must still initialize successfully.
}
inline const char* EvidenceLabel(Evidence value) {
    return value == Evidence::Yes ? "Yes" : value == Evidence::No ? "No" : "Unknown";
}
}
