#pragma once

namespace optishade::d3d12 {

// D3D12CreateDevice may re-enter the device-factory hook on the same thread.
// Keep this recursion marker thread-local: another adapter can be initialized
// concurrently without accidentally bypassing its own hook path.
inline thread_local unsigned createDeviceDepth = 0;
inline thread_local bool creatingD3DDevice = false;

class CreateDeviceScope {
public:
    CreateDeviceScope() noexcept { ++createDeviceDepth; }
    ~CreateDeviceScope() noexcept { --createDeviceDepth; }

    CreateDeviceScope(const CreateDeviceScope&) = delete;
    CreateDeviceScope& operator=(const CreateDeviceScope&) = delete;
};

inline bool IsCreatingDevice() noexcept { return createDeviceDepth != 0; }

class CreatingD3DDeviceScope {
    bool previousState;

public:
    CreatingD3DDeviceScope() noexcept : previousState(creatingD3DDevice) { creatingD3DDevice = true; }
    ~CreatingD3DDeviceScope() noexcept { creatingD3DDevice = previousState; }

    CreatingD3DDeviceScope(const CreatingD3DDeviceScope&) = delete;
    CreatingD3DDeviceScope& operator=(const CreatingD3DDeviceScope&) = delete;
};

inline bool IsCreatingD3DDevice() noexcept { return creatingD3DDevice; }

} // namespace optishade::d3d12
