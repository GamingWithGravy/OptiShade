#include "VulkanOwner.h"
#include "PreparedOverlay.h"
#include <cassert>
#include <algorithm>

int main() {
    using namespace optishade::vkowner;
    Registry registry;
    registry.surface(1,2,3);
    assert(registry.swapchain(4,2,10,true,false));
    const auto firstRegistrationGeneration = registry.owner.generation;
    assert(firstRegistrationGeneration != 0);
    assert(registry.swapchain(4,2,10,true,true)); // ReShade and OptiScaler may both observe this exact lifetime.
    assert(registry.chains.size() == 1);
    assert(registry.owner.generation == firstRegistrationGeneration);
    registry.queue(4,5,0,true);
    registry.queue(6,7,0,true);
    registry.queue(4,8,1,false);
    const auto originalGeneration=FindSwapchainGeneration(4,10,registry.chains);
    assert(originalGeneration!=0);
    assert(FindSwapchainGeneration(6,10,registry.chains)==0);
    assert(FindSwapchainGeneration(4,99,registry.chains)==0);
    assert(FindQueueDevice(5,registry.queues)==4);
    assert(FindQueueDevice(99,registry.queues)==0);
    auto duplicateChains=registry.chains;
    duplicateChains.push_back(duplicateChains.front());
    assert(FindSwapchainGeneration(4,10,duplicateChains)==0);
    Handle chains[]{10,20,30};
    uint32_t images[]{2,0,1};
    for(uint32_t ownerIndex=0;ownerIndex<3;++ownerIndex) {
        assert(PresentIndex(Handle{10},3,chains,images,3)==ownerIndex);
        assert(registry.present(5,3,chains,images,3));
        assert(DrawContract(true,5,5,Handle{10},3,chains,images,3));
        assert(!DrawContract(false,5,5,Handle{10},3,chains,images,3));
        assert(!DrawContract(true,5,7,Handle{10},3,chains,images,3));
        assert(!registry.present(7,3,chains,images,3));
        assert(!registry.present(8,3,chains,images,3));
        const auto saved=images[ownerIndex];
        images[ownerIndex]=3;
        assert(!registry.present(5,3,chains,images,3));
        images[ownerIndex]=saved;
        if(ownerIndex<2)std::swap(chains[ownerIndex],chains[ownerIndex+1]);
    }
    assert(PresentIndex(Handle{10},0,chains,images,3)==NoPresentIndex);
    assert(PresentIndex(Handle{10},3,static_cast<Handle*>(nullptr),images,3)==NoPresentIndex);
    assert(PresentIndex(Handle{10},3,chains,nullptr,3)==NoPresentIndex);
    assert(!registry.present(5,2,chains,images,3)); // owner is third
    chains[0]=10;
    assert(!registry.present(5,3,chains,images,3)); // duplicate owner
    assert(registry.present(5,1,chains,images,3)); // original one-window path
    // An auxiliary surface failure must not invalidate the main window.
    int results[]{-1000001004,0,1000001003};
    assert(PresentResult(-1000001004,true,results,1,3)==0);
    assert(PresentResult(-1000001004,true,results,0,3)==-1000001004);
    assert(PresentResult(-4,false,results,1,3)==-4); // device lost is global
    assert(PresentResult(-1000001004,true,static_cast<int*>(nullptr),1,3)==-1000001004);
    assert(PresentResult(-4,true,results,NoPresentIndex,3)==-4);
    // A callback for an auxiliary window cannot consume the owner transaction;
    // a duplicate callback must not submit/wait on its binary semaphores twice.
    struct Prepared { Handle queue,swap; unsigned image; Handle owner,command; bool deferred; };
    Prepared pending{5,10,2,99,100,false};
    assert(!optishade::overlay::TakePrepared(pending,Handle{5},Handle{20},0,99,true));
    assert(pending.command==100);
    assert(!optishade::overlay::TakePrepared(pending,Handle{7},Handle{10},2,99,true));
    assert(!optishade::overlay::TakePrepared(pending,Handle{5},Handle{10},1,99,true));
    auto prepared=optishade::overlay::TakePrepared(pending,Handle{5},Handle{10},2,99,true);
    assert(prepared && prepared->command==100 && pending.command==0);
    assert(!optishade::overlay::TakePrepared(pending,Handle{5},Handle{10},2,99,true));
    registry.eraseChain(10);
    assert(FindSwapchainGeneration(4,10,registry.chains)==0);
    assert(registry.swapchain(4,2,10,true,false)); // Vulkan reuses the handle after destruction.
    const auto recreatedGeneration=FindSwapchainGeneration(4,10,registry.chains);
    assert(recreatedGeneration!=0 && recreatedGeneration!=originalGeneration);
    registry.eraseDevice(4);
    assert(!registry.present(5,1,chains,images,3));
}
