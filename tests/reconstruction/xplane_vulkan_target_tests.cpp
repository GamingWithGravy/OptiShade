#include "XPlaneVulkanTarget.h"
#include "VulkanNrLifecycle.h"

#include <cassert>
#include <filesystem>

int main()
{
    {
        optishade::vknr::Lifecycle life;
        optishade::vknr::HistoryIdentity identity{};
        assert(life.observe(identity));
        assert(!life.observe(identity));
        uint64_t effectRevision = 0;
        life.change(effectRevision);
        assert(effectRevision == 1);
        identity.effects = effectRevision;
        assert(life.observe(identity));
        assert(!life.observe(identity));
    }

    using optishade::xplane_layer::IsXPlaneProcessName;
    using optishade::xplane_layer::ShouldDisableReShadeGraphicsHooks;

    assert(IsXPlaneProcessName(L"X-Plane.exe"));
    assert(IsXPlaneProcessName(L"x-plane.EXE"));
    assert(IsXPlaneProcessName(std::filesystem::path(L"C:/Games/X-Plane 12/X-Plane.exe").filename().wstring()));
    assert(!IsXPlaneProcessName(L"GTA5_Enhanced.exe"));
    assert(!IsXPlaneProcessName(L"FlightSimulator2024.exe"));
    assert(!IsXPlaneProcessName(L"X-Plane.exe.bak"));
    assert(!IsXPlaneProcessName(L"X-Plane 12.exe"));
    assert(!IsXPlaneProcessName(L"C:/Games/X-Plane 12/X-Plane.exe"));

    assert(ShouldDisableReShadeGraphicsHooks(L"X-Plane.exe"));
    assert(ShouldDisableReShadeGraphicsHooks(L"x-plane.EXE"));
    assert(!ShouldDisableReShadeGraphicsHooks(L"GTA5_Enhanced.exe"));
    assert(!ShouldDisableReShadeGraphicsHooks(L"FlightSimulator2024.exe"));
}
