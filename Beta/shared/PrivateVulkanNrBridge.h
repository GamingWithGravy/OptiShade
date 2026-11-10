#pragma once
#include <d3d12.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_win32.h>
#include <array>
#include <cstring>
#include "VulkanNeuralBridge.h"
#include "VulkanSubmission.h"
#include "NrGpuLifetime.h"
// OptiShade's private XP12 interop transport. NVIDIA's model remains behind the
// existing D3D12 backend; this class owns only transport resources and GPU sync.
// API basis: VK_KHR_external_memory_win32, VK_KHR_external_semaphore_win32.
namespace optishade::vknr {
class PrivateD3D12Bridge {
 using MicrosoftComResource=Microsoft::WRL::ComPtr<ID3D12Resource>;
 struct Image {VkImage image=VK_NULL_HANDLE;VkDeviceMemory memory=VK_NULL_HANDLE;MicrosoftComResource dx;};
 VkPhysicalDevice physical=VK_NULL_HANDLE;VkDevice vk=VK_NULL_HANDLE;VkQueue queue=VK_NULL_HANDLE;uint32_t family=0,width=0,height=0;
 Microsoft::WRL::ComPtr<ID3D12Device> dx;
 Microsoft::WRL::ComPtr<ID3D12CommandQueue> dxQueue;
 Microsoft::WRL::ComPtr<ID3D12CommandAllocator> allocator;
 Microsoft::WRL::ComPtr<ID3D12GraphicsCommandList> commands;
 Microsoft::WRL::ComPtr<ID3D12Fence> timeline;
 VkSemaphore semaphore=VK_NULL_HANDLE;
 std::array<Image,3> images{};
 uint64_t value=0,retireValue=0;bool initialized=false,lost=false,submitted=false;
 const char* reason="not initialized";
 PFN_vkGetMemoryWin32HandlePropertiesKHR getMemory=nullptr;
 PFN_vkImportSemaphoreWin32HandleKHR importSemaphore=nullptr;
 static void DxBarrier(ID3D12GraphicsCommandList* cmd,ID3D12Resource* resource,D3D12_RESOURCE_STATES before,D3D12_RESOURCE_STATES after){if(before==after)return;D3D12_RESOURCE_BARRIER b{};b.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;b.Transition={resource,D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,before,after};cmd->ResourceBarrier(1,&b);}
 void VkBarrier(VkCommandBuffer cmd,VkImage image,VkImageLayout before,VkImageLayout after,VkAccessFlags src,VkAccessFlags dst,uint32_t sourceFamily=VK_QUEUE_FAMILY_IGNORED,uint32_t targetFamily=VK_QUEUE_FAMILY_IGNORED){
  VkImageMemoryBarrier b{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};b.oldLayout=before;b.newLayout=after;b.srcAccessMask=src;b.dstAccessMask=dst;b.srcQueueFamilyIndex=sourceFamily;b.dstQueueFamilyIndex=targetFamily;b.image=image;b.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};
  vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,0,0,nullptr,0,nullptr,1,&b);
 }
 bool MakeImage(Image& out,VkFormat format,DXGI_FORMAT dxFormat){
  VkPhysicalDeviceExternalImageFormatInfo external{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO};external.handleType=VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D12_RESOURCE_BIT;
  VkPhysicalDeviceImageFormatInfo2 query{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2};query.pNext=&external;query.format=format;query.type=VK_IMAGE_TYPE_2D;query.tiling=VK_IMAGE_TILING_OPTIMAL;query.usage=VK_IMAGE_USAGE_TRANSFER_SRC_BIT|VK_IMAGE_USAGE_TRANSFER_DST_BIT;
  VkExternalImageFormatProperties ext{VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES};VkImageFormatProperties2 properties{VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2};properties.pNext=&ext;
  if(vkGetPhysicalDeviceImageFormatProperties2(physical,&query,&properties)!=VK_SUCCESS||!(ext.externalMemoryProperties.externalMemoryFeatures&VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT)){reason="Vulkan device cannot import this D3D12 image format";return false;}
  D3D12_HEAP_PROPERTIES heap{};heap.Type=D3D12_HEAP_TYPE_DEFAULT;D3D12_RESOURCE_DESC d{};d.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;d.Width=width;d.Height=height;d.DepthOrArraySize=d.MipLevels=1;d.SampleDesc.Count=1;d.Format=dxFormat;d.Flags=D3D12_RESOURCE_FLAG_ALLOW_SIMULTANEOUS_ACCESS;
  if(FAILED(dx->CreateCommittedResource(&heap,D3D12_HEAP_FLAG_SHARED,&d,D3D12_RESOURCE_STATE_COMMON,nullptr,IID_PPV_ARGS(&out.dx)))){reason="D3D12 shared image creation failed";return false;}
  HANDLE handle=nullptr;if(FAILED(dx->CreateSharedHandle(out.dx.Get(),nullptr,GENERIC_ALL,nullptr,&handle))){reason="D3D12 shared image handle creation failed";return false;}
  VkExternalMemoryImageCreateInfo imageExternal{VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO};imageExternal.handleTypes=VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D12_RESOURCE_BIT;
  VkImageCreateInfo ci{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};ci.pNext=&imageExternal;ci.imageType=VK_IMAGE_TYPE_2D;ci.format=format;ci.extent={width,height,1};ci.mipLevels=ci.arrayLayers=1;ci.samples=VK_SAMPLE_COUNT_1_BIT;ci.tiling=VK_IMAGE_TILING_OPTIMAL;ci.usage=query.usage;ci.sharingMode=VK_SHARING_MODE_EXCLUSIVE;
  if(vkCreateImage(vk,&ci,nullptr,&out.image)!=VK_SUCCESS){reason="Vulkan external image creation failed";CloseHandle(handle);return false;}
  VkMemoryRequirements req{};vkGetImageMemoryRequirements(vk,out.image,&req);
  VkMemoryWin32HandlePropertiesKHR hp{VK_STRUCTURE_TYPE_MEMORY_WIN32_HANDLE_PROPERTIES_KHR};
  if(getMemory(vk,VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D12_RESOURCE_BIT,handle,&hp)!=VK_SUCCESS){reason="Vulkan shared image handle query failed";CloseHandle(handle);return false;}
  VkPhysicalDeviceMemoryProperties memory{};vkGetPhysicalDeviceMemoryProperties(physical,&memory);uint32_t type=UINT32_MAX;
  for(uint32_t i=0;i<memory.memoryTypeCount;++i)if((req.memoryTypeBits&hp.memoryTypeBits&(1u<<i))&&(memory.memoryTypes[i].propertyFlags&VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)){type=i;break;}
  VkMemoryDedicatedAllocateInfo dedicated{VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO};dedicated.image=out.image;
  VkImportMemoryWin32HandleInfoKHR import{VK_STRUCTURE_TYPE_IMPORT_MEMORY_WIN32_HANDLE_INFO_KHR};import.pNext=&dedicated;import.handleType=VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D12_RESOURCE_BIT;import.handle=handle;
  VkMemoryAllocateInfo ai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};ai.pNext=&import;ai.allocationSize=req.size;ai.memoryTypeIndex=type;
  const auto result=type!=UINT32_MAX?vkAllocateMemory(vk,&ai,nullptr,&out.memory):VK_ERROR_FEATURE_NOT_PRESENT;CloseHandle(handle);
  if(type==UINT32_MAX){reason="No compatible device-local memory type for shared image";return false;}
  if(result!=VK_SUCCESS){reason="Vulkan shared image memory import failed";return false;}
  if(vkBindImageMemory(vk,out.image,out.memory,0)!=VK_SUCCESS){reason="Vulkan shared image memory binding failed";return false;}
  return true;
 }
 bool SignalVk(uint64_t signal,VkFence completion=VK_NULL_HANDLE){
  VkD3D12FenceSubmitInfoKHR values{VK_STRUCTURE_TYPE_D3D12_FENCE_SUBMIT_INFO_KHR};values.signalSemaphoreValuesCount=1;values.pSignalSemaphoreValues=&signal;
  VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};submit.pNext=&values;submit.signalSemaphoreCount=1;submit.pSignalSemaphores=&semaphore;
  return vkQueueSubmit(queue,1,&submit,completion)==VK_SUCCESS;
 }
 bool WaitVk(uint64_t wait){
  VkD3D12FenceSubmitInfoKHR values{VK_STRUCTURE_TYPE_D3D12_FENCE_SUBMIT_INFO_KHR};values.waitSemaphoreValuesCount=1;values.pWaitSemaphoreValues=&wait;
  VkPipelineStageFlags stage=VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
  VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};submit.pNext=&values;submit.waitSemaphoreCount=1;submit.pWaitSemaphores=&semaphore;submit.pWaitDstStageMask=&stage;
  return vkQueueSubmit(queue,1,&submit,VK_NULL_HANDLE)==VK_SUCCESS;
 }
public:
 PrivateD3D12Bridge()=default;PrivateD3D12Bridge(const PrivateD3D12Bridge&)=delete;
 const char* Reason()const{return reason;}
 uint32_t Mismatch(VkDevice device,VkQueue q,uint32_t w,uint32_t h)const{return (vk!=device?1u:0u)|(queue!=q?2u:0u)|(width!=w?4u:0u)|(height!=h?8u:0u)|(!initialized?16u:0u);}
 bool ReadyToRetire()const{if(lost)return false;if(!retireValue)return true;auto completed=timeline->GetCompletedValue();return completed!=UINT64_MAX&&completed>=retireValue;}
 // The NR owner holds leases to private command-list generations until the
 // bridge is destroyed. Retire a list only after this bridge's completion
 // fence proves every Vulkan/D3D12 use has finished, so Shutdown can release
 // those leases before the bridge itself is destroyed.
 bool RetireCompletedRecording(){if(!ReadyToRetire())return false;nr_lifetime::RetirePrivate(commands.Get());return true;}
 bool Matches(VkDevice device,VkQueue q,uint32_t w,uint32_t h)const{return initialized&&vk==device&&queue==q&&width==w&&height==h;}
 bool Submitted()const{return submitted;}
 bool OwnsDevice(VkDevice device)const{return vk==device;}
 ID3D12Device* Device()const{return dx.Get();}
 ID3D12CommandQueue* Queue()const{return dxQueue.Get();}
 ID3D12GraphicsCommandList* Commands()const{return commands.Get();}
 bool Init(VkPhysicalDevice pd,VkDevice device,VkQueue q,uint32_t queueFamily,uint32_t w,uint32_t h,ID3D12Device* sharedDevice=nullptr,ID3D12CommandQueue* sharedQueue=nullptr){
  if(initialized||!pd||!device||!q||w<64||h<64)return false;physical=pd;vk=device;queue=q;family=queueFamily;width=w;height=h;
  getMemory=(PFN_vkGetMemoryWin32HandlePropertiesKHR)vkGetDeviceProcAddr(vk,"vkGetMemoryWin32HandlePropertiesKHR");importSemaphore=(PFN_vkImportSemaphoreWin32HandleKHR)vkGetDeviceProcAddr(vk,"vkImportSemaphoreWin32HandleKHR");
  if(!getMemory||!importSemaphore){reason="Vulkan external-memory/semaphore extensions were not enabled";return false;}
  VkPhysicalDeviceIDProperties id{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES};VkPhysicalDeviceProperties2 p{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2};p.pNext=&id;vkGetPhysicalDeviceProperties2(pd,&p);
  if(!id.deviceLUIDValid||p.properties.vendorID!=0x10de){reason="NVIDIA render-device LUID is unavailable";return false;}
  LUID luid{};memcpy(&luid,id.deviceLUID,sizeof(luid));Microsoft::WRL::ComPtr<IDXGIFactory4> factory;Microsoft::WRL::ComPtr<IDXGIAdapter1> adapter;
  if(sharedDevice&&sharedQueue){
   auto actual=sharedDevice->GetAdapterLuid();if(memcmp(&actual,&luid,sizeof(luid))){reason="Shared NR device does not match Vulkan adapter";return false;}
   dx=sharedDevice;dxQueue=sharedQueue;
  }else{
   if(FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))||FAILED(factory->EnumAdapterByLuid(luid,IID_PPV_ARGS(&adapter)))||FAILED(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_12_0,IID_PPV_ARGS(&dx)))){reason="Matching private D3D12 device creation failed";return false;}
   D3D12_COMMAND_QUEUE_DESC qd{};if(FAILED(dx->CreateCommandQueue(&qd,IID_PPV_ARGS(&dxQueue))))return false;
  }
  if(FAILED(dx->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&allocator)))||FAILED(dx->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,allocator.Get(),nullptr,IID_PPV_ARGS(&commands)))||FAILED(commands->Close())||FAILED(dx->CreateFence(0,D3D12_FENCE_FLAG_SHARED,IID_PPV_ARGS(&timeline))))return false;
  HANDLE handle=nullptr;if(FAILED(dx->CreateSharedHandle(timeline.Get(),nullptr,GENERIC_ALL,nullptr,&handle)))return false;
  VkSemaphoreCreateInfo sci{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};const auto created=vkCreateSemaphore(vk,&sci,nullptr,&semaphore);
  VkImportSemaphoreWin32HandleInfoKHR imported{VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_WIN32_HANDLE_INFO_KHR};imported.semaphore=semaphore;imported.handleType=VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_D3D12_FENCE_BIT;imported.handle=handle;
  const auto result=created==VK_SUCCESS?importSemaphore(vk,&imported):created;CloseHandle(handle);if(result!=VK_SUCCESS){reason="D3D12 fence import failed";return false;}
  if(!MakeImage(images[0],VK_FORMAT_B8G8R8A8_UNORM,DXGI_FORMAT_B8G8R8A8_UNORM)||!MakeImage(images[1],VK_FORMAT_R32_SFLOAT,DXGI_FORMAT_R32_FLOAT)||!MakeImage(images[2],VK_FORMAT_R16G16_SFLOAT,DXGI_FORMAT_R16G16_FLOAT))return false;
  initialized=true;reason="ready";return true;
 }
 using Evaluate=bool(*)(void*,ID3D12GraphicsCommandList*,ID3D12CommandQueue*,ID3D12Resource*,ID3D12Resource*,ID3D12Resource*,const osvtaa::Frame&);
 int Run(const osvtaa::Frame& f,Evaluate evaluate,void* context){
  submitted=false;
  if(!initialized||lost||!evaluate||!f.flush||!f.currentCommands||!Matches((VkDevice)f.device,(VkQueue)f.queue,f.width,f.height))return -2;
  if(!ReadyToRetire()){reason="previous interop frame has not completed";return 0;}
  // Reject a transient missing producer recording before opening the private
  // list. Otherwise the next retry resets a still-open D3D12 command list.
  auto cmd=(VkCommandBuffer)f.currentCommands(f.commandContext);if(!cmd){reason="No current Vulkan recording";return -2;}
  if(FAILED(allocator->Reset())||FAILED(commands->Reset(allocator.Get(),nullptr))){reason="private D3D12 command reset failed";lost=true;return -1;}
  // This private device can bypass the game's hooked D3D12 entry points.
  // Publish its actual lifecycle to the same NR lease service explicitly.
  nr_lifetime::Reset(commands.Get());
  const VkImage sources[]={(VkImage)f.color,(VkImage)f.depth,(VkImage)f.motion};
  const VkImageLayout layouts[]={static_cast<VkImageLayout>(f.colorLayout),VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
  VkImageCopy copy{};copy.srcSubresource=copy.dstSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1};copy.extent={width,height,1};
  for(unsigned i=0;i<3;++i){
   VkBarrier(cmd,sources[i],layouts[i],VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,VK_ACCESS_MEMORY_WRITE_BIT|VK_ACCESS_SHADER_READ_BIT,VK_ACCESS_TRANSFER_READ_BIT);
   VkBarrier(cmd,images[i].image,value?VK_IMAGE_LAYOUT_GENERAL:VK_IMAGE_LAYOUT_UNDEFINED,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,0,VK_ACCESS_TRANSFER_WRITE_BIT,value?VK_QUEUE_FAMILY_EXTERNAL:VK_QUEUE_FAMILY_IGNORED,value?family:VK_QUEUE_FAMILY_IGNORED);
   vkCmdCopyImage(cmd,sources[i],VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,images[i].image,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,1,&copy);
   VkBarrier(cmd,sources[i],VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,layouts[i],VK_ACCESS_TRANSFER_READ_BIT,VK_ACCESS_MEMORY_READ_BIT|VK_ACCESS_MEMORY_WRITE_BIT);
   VkBarrier(cmd,images[i].image,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,VK_IMAGE_LAYOUT_GENERAL,VK_ACCESS_TRANSFER_WRITE_BIT,0,family,VK_QUEUE_FAMILY_EXTERNAL);
  }
  if(!FlushSubmitted(f,reinterpret_cast<uint64_t>(cmd))){reason="Vulkan recording submission was not observed; restart before retrying";lost=true;return -1;}
  const uint64_t produced=value+1,processed=value+2,returned=value+3;
  if(!SignalVk(produced)||FAILED(dxQueue->Wait(timeline.Get(),produced))){reason="producer-to-NR GPU synchronization failed";lost=true;return -1;}
  for(auto& image:images)DxBarrier(commands.Get(),image.dx.Get(),D3D12_RESOURCE_STATE_COMMON,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
  bool applied=false,providerException=false;
  try{applied=evaluate(context,commands.Get(),dxQueue.Get(),images[0].dx.Get(),images[1].dx.Get(),images[2].dx.Get(),f);}catch(...){providerException=true;}
  for(auto& image:images)DxBarrier(commands.Get(),image.dx.Get(),D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_COMMON);
  if(FAILED(commands->Close())){reason="private NR command close failed";lost=true;return -1;}
  nr_lifetime::Closed(commands.Get());
  ID3D12CommandList* list[]={commands.Get()};dxQueue->ExecuteCommandLists(1,list);submitted=true;
  nr_lifetime::Submitted(dxQueue.Get(),commands.Get());
  if(FAILED(dxQueue->Signal(timeline.Get(),processed))||!WaitVk(processed)){reason="NR-to-Vulkan GPU synchronization failed";lost=true;return -1;}
  cmd=(VkCommandBuffer)f.currentCommands(f.commandContext);if(!cmd){lost=true;return -1;}
  VkBarrier(cmd,images[0].image,VK_IMAGE_LAYOUT_GENERAL,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,0,VK_ACCESS_TRANSFER_READ_BIT,VK_QUEUE_FAMILY_EXTERNAL,family);
  if(applied){VkBarrier(cmd,sources[0],layouts[0],VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,VK_ACCESS_MEMORY_READ_BIT|VK_ACCESS_MEMORY_WRITE_BIT,VK_ACCESS_TRANSFER_WRITE_BIT);vkCmdCopyImage(cmd,images[0].image,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,sources[0],VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,1,&copy);VkBarrier(cmd,sources[0],VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,layouts[0],VK_ACCESS_TRANSFER_WRITE_BIT,VK_ACCESS_MEMORY_READ_BIT|VK_ACCESS_MEMORY_WRITE_BIT);}
  VkBarrier(cmd,images[0].image,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,VK_IMAGE_LAYOUT_GENERAL,VK_ACCESS_TRANSFER_READ_BIT,0,family,VK_QUEUE_FAMILY_EXTERNAL);
  if(!FlushSubmitted(f,reinterpret_cast<uint64_t>(cmd))){reason="Vulkan recording submission was not observed; restart before retrying";lost=true;return -1;}
  if(!SignalVk(returned)){reason="Vulkan copy-back completion signal failed";lost=true;return -1;}
  value=retireValue=returned;reason=providerException?"Neural provider exception; original image preserved":applied?"NR output returned to Vulkan":"NR backend warm-up submitted";return applied?1:0;
 }
 ~PrivateD3D12Bridge(){
  // Owner must wait for ReadyToRetire before destruction. No vkDeviceWaitIdle,
  // sleep, guessed frame age or destruction of resources still in GPU use.
  if(!ReadyToRetire()){
   for(auto& image:images)image.dx.Detach();dx.Detach();dxQueue.Detach();allocator.Detach();commands.Detach();timeline.Detach();return;
  }
  nr_lifetime::RetirePrivate(commands.Get());
  for(auto& image:images){if(image.image)vkDestroyImage(vk,image.image,nullptr);if(image.memory)vkFreeMemory(vk,image.memory,nullptr);}
  if(semaphore)vkDestroySemaphore(vk,semaphore,nullptr);
 }
};
}
