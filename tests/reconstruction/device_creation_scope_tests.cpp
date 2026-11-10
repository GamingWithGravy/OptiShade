#include "D3D12CreateDeviceScope.h"

#include <cassert>
#include <thread>

int main()
{
    using optishade::d3d12::CreateDeviceScope;
    using optishade::d3d12::CreatingD3DDeviceScope;
    using optishade::d3d12::IsCreatingDevice;
    using optishade::d3d12::IsCreatingD3DDevice;

    assert(!IsCreatingDevice());
    assert(!IsCreatingD3DDevice());
    {
        CreateDeviceScope outer;
        CreatingD3DDeviceScope creatingDevice;
        assert(IsCreatingDevice());
        assert(IsCreatingD3DDevice());
        {
            CreateDeviceScope nested;
            CreatingD3DDeviceScope nestedCreatingDevice;
            assert(IsCreatingDevice());
            assert(IsCreatingD3DDevice());
        }
        assert(IsCreatingDevice());
        assert(IsCreatingD3DDevice());

        std::thread otherAdapter([] {
            assert(!IsCreatingDevice());
            assert(!IsCreatingD3DDevice());
            CreateDeviceScope otherThread;
            CreatingD3DDeviceScope creatingOnOtherThread;
            assert(IsCreatingDevice());
            assert(IsCreatingD3DDevice());
        });
        otherAdapter.join();
        assert(IsCreatingDevice());
        assert(IsCreatingD3DDevice());
    }
    assert(!IsCreatingDevice());
    assert(!IsCreatingD3DDevice());
}
