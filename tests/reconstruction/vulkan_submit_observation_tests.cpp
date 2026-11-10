#include "VulkanSubmitObservation.h"
#include <vulkan/vulkan.h>
#include <cassert>
#include <cstdint>

using namespace optishade::vulkan_submit_observation;

int main() {
    const auto queue = reinterpret_cast<VkQueue>(uintptr_t{1});
    const auto fence = reinterpret_cast<VkFence>(uintptr_t{2});
    const auto waitSemaphore = reinterpret_cast<VkSemaphore>(uintptr_t{10});
    const auto signalSemaphore = reinterpret_cast<VkSemaphore>(uintptr_t{11});
    const auto command = reinterpret_cast<VkCommandBuffer>(uintptr_t{12});
    VkSemaphore waits[]{waitSemaphore};
    VkPipelineStageFlags stages[]{VK_PIPELINE_STAGE_ALL_COMMANDS_BIT};
    VkSemaphore signals[]{signalSemaphore};
    VkCommandBuffer commands[]{command};
    VkSubmitInfo legacy{VK_STRUCTURE_TYPE_SUBMIT_INFO};
    legacy.waitSemaphoreCount=1;legacy.pWaitSemaphores=waits;legacy.pWaitDstStageMask=stages;
    legacy.signalSemaphoreCount=1;legacy.pSignalSemaphores=signals;
    legacy.commandBufferCount=1;legacy.pCommandBuffers=commands;
    Snapshot snapshot;
    assert(CaptureLegacy(queue,&legacy,1,fence,VK_SUCCESS,Source::Application,snapshot));
    assert(snapshot.api==static_cast<uint32_t>(Api::Legacy));
    assert(snapshot.source==static_cast<uint32_t>(Source::Application));
    assert(snapshot.queue==HandleValue(queue)&&snapshot.fence==HandleValue(fence));
    assert(snapshot.waitCount==1&&snapshot.signalCount==1&&snapshot.commandCount==1);
    assert(snapshot.waits[0].handle==HandleValue(waitSemaphore));
    assert(snapshot.waits[0].stageMask==VK_PIPELINE_STAGE_ALL_COMMANDS_BIT);
    assert(snapshot.signals[0].handle==HandleValue(signalSemaphore));
    assert(snapshot.commands[0]==HandleValue(command));

    assert(CaptureLegacy(queue,&legacy,1,fence,VK_SUCCESS,Source::OptiShadeMenu,snapshot));
    assert(snapshot.source==static_cast<uint32_t>(Source::OptiShadeMenu));

    VkSemaphoreSubmitInfo wait2{VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO};
    wait2.semaphore=waitSemaphore;wait2.value=7;wait2.stageMask=VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT;wait2.deviceIndex=2;
    VkSemaphoreSubmitInfo signal2{VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO};
    signal2.semaphore=signalSemaphore;signal2.value=9;signal2.stageMask=VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT;
    VkCommandBufferSubmitInfo command2{VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO};command2.commandBuffer=command;command2.deviceMask=3;
    VkSubmitInfo2 sync2{VK_STRUCTURE_TYPE_SUBMIT_INFO_2};
    sync2.waitSemaphoreInfoCount=1;sync2.pWaitSemaphoreInfos=&wait2;
    sync2.signalSemaphoreInfoCount=1;sync2.pSignalSemaphoreInfos=&signal2;
    sync2.commandBufferInfoCount=1;sync2.pCommandBufferInfos=&command2;
    assert(CaptureSubmit2(queue,&sync2,1,fence,VK_SUBOPTIMAL_KHR,Source::ReShadeImmediate,snapshot));
    assert(snapshot.api==static_cast<uint32_t>(Api::Synchronization2));
    assert(snapshot.result==VK_SUBOPTIMAL_KHR&&snapshot.source==static_cast<uint32_t>(Source::ReShadeImmediate));
    assert(snapshot.waits[0].value==7&&snapshot.waits[0].stageMask==VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT);
    assert(snapshot.waits[0].deviceIndex==2&&snapshot.signals[0].value==9);

    VkSemaphore many[MaxSemaphores+1]{};
    VkPipelineStageFlags manyStages[MaxSemaphores+1]{};
    legacy.waitSemaphoreCount=static_cast<uint32_t>(MaxSemaphores+1);legacy.pWaitSemaphores=many;legacy.pWaitDstStageMask=manyStages;
    assert(CaptureLegacy(queue,&legacy,1,fence,VK_SUCCESS,Source::ReShadeQueueHelper,snapshot));
    assert(snapshot.truncated&&snapshot.waitCount==MaxSemaphores+1&&snapshot.capturedWaitCount==MaxSemaphores);

    VkSubmitInfo tooManyBatches[MaxBatches+1]{};
    assert(CaptureLegacy(queue,tooManyBatches,static_cast<uint32_t>(MaxBatches+1),fence,VK_SUCCESS,Source::Application,snapshot));
    assert(snapshot.truncated&&snapshot.submitCount==MaxBatches+1&&snapshot.batchCount==MaxBatches);

    legacy.waitSemaphoreCount=1;legacy.pWaitSemaphores=nullptr;
    assert(!CaptureLegacy(queue,&legacy,1,fence,VK_ERROR_DEVICE_LOST,Source::Application,snapshot));
    assert(!snapshot.valid);
}
