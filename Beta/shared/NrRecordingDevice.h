#pragma once
#include "D3D12FrameContext.h"

namespace optishade {
// Canonical identity proves ownership, not interchangeability of proxy objects.
// Record with the same device interface that created the renderer's heaps.
inline Microsoft::WRL::ComPtr<ID3D12Device> NrRecordingDevice(
    ID3D12Device* presentation, ID3D12Device* renderer) {
    if (!presentation || !renderer) return {};
    const auto a = ReShadeDeviceIdentity(presentation);
    const auto b = ReShadeDeviceIdentity(renderer);
    if (!a || !b || a != b) return {};
    return Microsoft::WRL::ComPtr<ID3D12Device>(renderer);
}
}
