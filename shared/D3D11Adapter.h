#pragma once
#include <d3d11.h>
#include <dxgi.h>
#include <wrl/client.h>
#include <optional>

namespace optishade {
// Missing device/adapter evidence must never silently select the first inventory GPU.
inline std::optional<LUID> D3D11AdapterLuid(ID3D11Device* device) {
    if (!device) return std::nullopt;
    Microsoft::WRL::ComPtr<IDXGIDevice> dxgi;
    Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
    DXGI_ADAPTER_DESC desc{};
    if (FAILED(device->QueryInterface(IID_PPV_ARGS(&dxgi))) ||
        FAILED(dxgi->GetAdapter(&adapter)) || FAILED(adapter->GetDesc(&desc))) return std::nullopt;
    return desc.AdapterLuid;
}
}
