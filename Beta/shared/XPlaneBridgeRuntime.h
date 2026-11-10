#pragma once
#include "PrivateVulkanNrRing.h"
#include "VulkanBridgeRetry.h"
#include "SimulatorRouteHost.h"
#include <memory>
#include <mutex>
#include <string>
namespace optishade::vknr {
struct XPlaneBridgeRuntime {
 std::recursive_mutex mutex;
 std::unique_ptr<PrivateVulkanNrRing> transport;
 BridgeRetry initializationRetry;
 bool poisoned=false;
 uint64_t pendingPresentTicket=0;
 uint64_t owner=0,generation=0,runtime=0,guideGeneration=0;
 std::string reason="Waiting for primary Vulkan swapchain";
};
// XP12 allocates against the loaded route ABI. Keep other callers unchanged
// until their independent runtime paths have been qualified.
inline XPlaneBridgeRuntime* XPlaneBridge(){return (route::CurrentSimulator()==route::Simulator::XPlane12||route::CurrentSimulator()==route::Simulator::Unknown)?route::Backend<XPlaneBridgeRuntime,12>(route::Abi):nullptr;}
}
