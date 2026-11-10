#include "pch.h"
#include "../../../shared/PreparedOverlay.h"
#include "../../../shared/VulkanOverlayRetirement.h"
#include "../../../shared/XPlaneVulkanProcess.h"
#include "../../../shared/HardwareRenderGpu.h"
#include "menu_overlay_base.h"
#include "menu_overlay_vk.h"
#include "menu_common.h"
#include "input/input_system.h"

#include <Util.h>
#include <Config.h>
#include <SysUtils.h>
#include "../../../shared/VulkanOwner.h"
#include "../../../shared/VulkanSubmitObservation.h"

#include <imgui/imgui_impl_vulkan.h>
#include <imgui/imgui_impl_win32.h>
#include <imgui/imgui_internal.h>
#include <cstdint>
#include <vector>

extern "C" void OptiShadeVulkanNrQueueSubmitObserved(
    const optishade::vulkan_submit_observation::Snapshot* snapshot);

// Vulkan overlay code adopted from here:
// https://gist.github.com/mem99/0ec31ca302927457f86b1d6756aaa8c4
// Need to check resize & recreate fixes

static uint64_t _overlayDrawOwner=0;
static bool _isInited = false;

static bool _vulkanObjectsCreated = false;
static std::mutex _vkCleanMutex;
static std::mutex _vkPresentMutex;

// imgui stuff
struct ImGui_ImplVulkan_InitInfo _ImVulkan_Info = {};
struct ImGui_ImplVulkanH_Frame* _ImVulkan_Frames = VK_NULL_HANDLE;
static VkSemaphore* _ImVulkan_Semaphores = VK_NULL_HANDLE;
static VkRenderPass _vkRenderPass = VK_NULL_HANDLE;
static uint32_t _scImageCount;
static VkSwapchainKHR _overlaySwapchain = VK_NULL_HANDLE;
static ULONG64 _frameCount;
static VkExtent2D _renderExtent{};
static std::vector<uint8_t> _imagePresentedSuccessfully;
static std::vector<uint8_t> _pendingOverlaySubmission;
struct RetiredFrameResources {
    VkCommandPool CommandPool=VK_NULL_HANDLE;
    VkFence Fence=VK_NULL_HANDLE;
    ImGui_ImplVulkan_FrameRenderBuffers RenderBuffers{};
};
static std::vector<std::vector<RetiredFrameResources>> _retiredFrameResources;
static uint32_t _overlayQueueFamily=0;
struct MenuTraceSample { uint64_t frame=0,owner=0; bool pending=false; };
static std::vector<MenuTraceSample> _menuTraceSamples;
static uint32_t _menuTraceCount=0;

static void SetVkObjectName(VkDevice device, VkInstance instance, VkObjectType objectType, uint64_t objectHandle,
                            const char* name)
{
    static PFN_vkSetDebugUtilsObjectNameEXT vkSetDebugUtilsObjectNameEXT = nullptr;

    if (vkSetDebugUtilsObjectNameEXT == nullptr)
        vkSetDebugUtilsObjectNameEXT = reinterpret_cast<PFN_vkSetDebugUtilsObjectNameEXT>(
            vkGetInstanceProcAddr(instance, "vkSetDebugUtilsObjectNameEXT"));

    VkDebugUtilsObjectNameInfoEXT info {};
    info.sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_OBJECT_NAME_INFO_EXT;
    info.objectType = objectType;
    info.objectHandle = objectHandle;
    info.pObjectName = name;

    if(vkSetDebugUtilsObjectNameEXT)vkSetDebugUtilsObjectNameEXT(device, &info);
}

static bool CreateFrameCommandResources(VkDevice device,uint32_t queueFamily,
                                       ImGui_ImplVulkanH_Frame* frame,VkResult* failure)
{
    if(failure)*failure=VK_SUCCESS;
    if(!device||!frame){if(failure)*failure=VK_ERROR_INITIALIZATION_FAILED;return false;}
    VkCommandPool pool=VK_NULL_HANDLE;VkCommandBuffer command=VK_NULL_HANDLE;VkFence fence=VK_NULL_HANDLE;
    VkCommandPoolCreateInfo poolInfo{};poolInfo.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    poolInfo.flags=VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;poolInfo.queueFamilyIndex=queueFamily;
    VkResult result=vkCreateCommandPool(device,&poolInfo,nullptr,&pool);
    if(result!=VK_SUCCESS){if(failure)*failure=result;return false;}
    VkCommandBufferAllocateInfo allocInfo{};allocInfo.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    allocInfo.commandPool=pool;allocInfo.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY;allocInfo.commandBufferCount=1;
    result=vkAllocateCommandBuffers(device,&allocInfo,&command);
    if(result!=VK_SUCCESS){vkDestroyCommandPool(device,pool,nullptr);if(failure)*failure=result;return false;}
    VkFenceCreateInfo fenceInfo{};fenceInfo.sType=VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;fenceInfo.flags=VK_FENCE_CREATE_SIGNALED_BIT;
    result=vkCreateFence(device,&fenceInfo,nullptr,&fence);
    if(result!=VK_SUCCESS){vkDestroyCommandPool(device,pool,nullptr);if(failure)*failure=result;return false;}
    frame->CommandPool=pool;frame->CommandBuffer=command;frame->Fence=fence;
    return true;
}

static void ReapRetiredFrameResources()
{
    const auto device=_ImVulkan_Info.Device;if(!device)return;
    for(auto& imageResources:_retiredFrameResources){
        optishade::vkoverlay::ReapCompletedResources(imageResources,
            [device](const RetiredFrameResources& resources){
                const auto status=resources.Fence?vkGetFenceStatus(device,resources.Fence):VK_SUCCESS;
                return status==VK_SUCCESS?optishade::vkoverlay::FenceState::Signaled:
                    status==VK_NOT_READY?optishade::vkoverlay::FenceState::NotReady:
                    optishade::vkoverlay::FenceState::Error;
            },
            [device](RetiredFrameResources& resources){
                if(resources.Fence)vkDestroyFence(device,resources.Fence,nullptr);
                if(resources.CommandPool)vkDestroyCommandPool(device,resources.CommandPool,nullptr);
                ImGui_ImplVulkan_DestroyRetiredFrameRenderBuffers(device,&resources.RenderBuffers,_ImVulkan_Info.Allocator);
            });
    }
}

static bool RetireCurrentFrameResources(uint32_t image)
{
    if(image>=_scImageCount||image>=_retiredFrameResources.size()||
       _retiredFrameResources[image].size()>=optishade::vkoverlay::MaxRetiredFrameResources)return false;
    auto& frame=_ImVulkan_Frames[image];
    if(!frame.CommandPool||!frame.Fence)return false;
    ImGui_ImplVulkanH_Frame replacement{};VkResult result=VK_SUCCESS;
    if(!CreateFrameCommandResources(_ImVulkan_Info.Device,_overlayQueueFamily,&replacement,&result)){
        LOG_WARN("Could not replace busy Vulkan overlay frame resources for image={} VkResult={:X}",image,(UINT)result);
        return false;
    }
    ImGui_ImplVulkan_FrameRenderBuffers renderBuffers{};
    if(!ImGui_ImplVulkan_TakeFrameRenderBuffers(image,&renderBuffers)){
        if(replacement.Fence)vkDestroyFence(_ImVulkan_Info.Device,replacement.Fence,nullptr);
        if(replacement.CommandPool)vkDestroyCommandPool(_ImVulkan_Info.Device,replacement.CommandPool,nullptr);
        LOG_WARN("Could not detach ImGui upload buffers for busy Vulkan overlay image={}; draw deferred",image);
        return false;
    }
    _retiredFrameResources[image].push_back({frame.CommandPool,frame.Fence,renderBuffers});
    frame.CommandPool=replacement.CommandPool;frame.CommandBuffer=replacement.CommandBuffer;frame.Fence=replacement.Fence;
    LOG_INFO("Replaced busy Vulkan overlay frame resources for image {}; command and ImGui upload resources retained until their fence signals",image);
    return true;
}

static void CreateVulkanObjects(VkDevice device, VkPhysicalDevice pd, VkInstance instance, HWND hwnd,
                                const VkSwapchainCreateInfoKHR* pCreateInfo, VkSwapchainKHR* pSwapchain, VkQueue queue, uint32_t queueFamily)
{
    LOG_FUNC();

    if (!device || !pCreateInfo || !pSwapchain || !*pSwapchain) {
        LOG_WARN("Vulkan menu received invalid initialization arguments");
        return;
    }

    MenuOverlayVk::DestroyVulkanObjects(false);
    // Initialize ImGui
    if (!MenuOverlayBase::IsInited() || MenuOverlayBase::Handle() != hwnd)
    {
        if (MenuOverlayBase::IsInited())
            MenuOverlayBase::Shutdown();

        LOG_DEBUG("MenuOverlayBase::Init");
        MenuOverlayBase::Init(hwnd, false);
    }

    ImGuiIO& io = ImGui::GetIO();
    io.DisplaySize.x = static_cast<float>(pCreateInfo->imageExtent.width);
    io.DisplaySize.y = static_cast<float>(pCreateInfo->imageExtent.height);

    VkResult result;

    // Get swapchain image count.
    result = vkGetSwapchainImagesKHR(device, *pSwapchain, &_scImageCount, NULL);
    if (result != VK_SUCCESS)
    {
        LOG_ERROR("vkGetSwapchainImagesKHR error: {0:X}", (UINT) result);
        return;
    }

    if (!_scImageCount || _scImageCount > 64) return;
    std::vector<VkImage> images(_scImageCount);
    result = vkGetSwapchainImagesKHR(device, *pSwapchain, &_scImageCount, images.data());
    if (result != VK_SUCCESS)
    {
        LOG_ERROR("vkGetSwapchainImagesKHR error: {0:X}", (UINT) result);
        return;
    }

    // Alloc ImGui frame structure/semaphores for every image.
    // For convenience, I am using ImGui_ImplVulkanH_Frame in imgui_impl_vulkan.h
    if (!_vulkanObjectsCreated)
    {
        _ImVulkan_Frames = (ImGui_ImplVulkanH_Frame*) IM_ALLOC(sizeof(ImGui_ImplVulkanH_Frame) * _scImageCount);
        _ImVulkan_Semaphores = (VkSemaphore*) IM_ALLOC(sizeof(VkSemaphore) * _scImageCount);
    }

    // Queue and family were resolved from the actual present queue and the
    // device's requested queues, never an arbitrary first graphics family.
    _ImVulkan_Info.Device=device;
    _ImVulkan_Info.ImageCount=_scImageCount;
    _ImVulkan_Info.Queue=queue;
    _renderExtent=pCreateInfo->imageExtent;
    _ImVulkan_Info.LinearizeVertexColours=pCreateInfo->imageFormat==VK_FORMAT_R8G8B8A8_SRGB || pCreateInfo->imageFormat==VK_FORMAT_B8G8R8A8_SRGB || pCreateInfo->imageFormat==VK_FORMAT_A8B8G8R8_SRGB_PACK32;
    LOG_INFO("Vulkan UI surface: format={} colorSpace={} extent={}x{}",static_cast<unsigned>(pCreateInfo->imageFormat),static_cast<unsigned>(pCreateInfo->imageColorSpace),pCreateInfo->imageExtent.width,pCreateInfo->imageExtent.height);
    std::memset(_ImVulkan_Frames,0,sizeof(ImGui_ImplVulkanH_Frame)*_scImageCount);
    std::memset(_ImVulkan_Semaphores,0,sizeof(VkSemaphore)*_scImageCount);
    _imagePresentedSuccessfully.assign(_scImageCount, 0);
    _menuTraceSamples.assign(_scImageCount, {});
    _menuTraceCount=0;
    _pendingOverlaySubmission.assign(_scImageCount, 0);
    _retiredFrameResources.clear();_retiredFrameResources.resize(_scImageCount);
    for(auto& imageResources:_retiredFrameResources)
        imageResources.reserve(optishade::vkoverlay::MaxRetiredFrameResources);
    _overlayQueueFamily=queueFamily;
    struct PartialCleanup { bool complete=false; ~PartialCleanup(){if(!complete)MenuOverlayVk::DestroyVulkanObjects(false);} } cleanup;

    LOG_INFO("Vulkan UI initialization: descriptor pool");
    // Create the render pool
    VkDescriptorPool pool = VK_NULL_HANDLE;
    {
        VkDescriptorPoolSize sampler_pool_size = {};
        sampler_pool_size.type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        sampler_pool_size.descriptorCount = 8; // required by ImGui 1.92

        VkDescriptorPoolCreateInfo desc_pool_info = {};
        desc_pool_info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        desc_pool_info.flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;
        desc_pool_info.maxSets = 8;
        desc_pool_info.poolSizeCount = 1;
        desc_pool_info.pPoolSizes = &sampler_pool_size;

        result = vkCreateDescriptorPool(device, &desc_pool_info, NULL, &pool);
        if (result != VK_SUCCESS)
        {
            LOG_ERROR("vkCreateDescriptorPool error: {0:X}", (UINT) result);
            return;
        }
    }

    _ImVulkan_Info.DescriptorPool=pool;

    LOG_INFO("Vulkan UI initialization: render pass");
    // Create the render pass
    {
        VkAttachmentDescription attachment_desc = {};

        attachment_desc.format = pCreateInfo->imageFormat;
        attachment_desc.samples = VK_SAMPLE_COUNT_1_BIT;
        attachment_desc.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
        attachment_desc.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
        attachment_desc.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        attachment_desc.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
        attachment_desc.initialLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        attachment_desc.finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

        VkAttachmentReference color_attachment = {};
        color_attachment.attachment = 0;
        color_attachment.layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

        VkSubpassDescription subpass = {};
        subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &color_attachment;

        VkSubpassDependency dependency = {};
        dependency.srcSubpass = VK_SUBPASS_EXTERNAL;
        dependency.dstSubpass = 0;
        dependency.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dependency.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dependency.srcAccessMask = 0;
        dependency.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;

        VkRenderPassCreateInfo render_pass_info = {};
        render_pass_info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        render_pass_info.attachmentCount = 1;
        render_pass_info.pAttachments = &attachment_desc;
        render_pass_info.subpassCount = 1;
        render_pass_info.pSubpasses = &subpass;
        render_pass_info.dependencyCount = 1;
        render_pass_info.pDependencies = &dependency;

        result = vkCreateRenderPass(device, &render_pass_info, NULL, &_vkRenderPass);
        if (result != VK_SUCCESS)
        {
            LOG_ERROR("vkCreateRenderPass error: {0:X}", (UINT) result);
            return;
        }
    }

    LOG_INFO("Vulkan UI initialization: image views");
    // Create The Image Views
    {
        VkImageViewCreateInfo info = {};
        info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        info.viewType = VK_IMAGE_VIEW_TYPE_2D;

        info.format = pCreateInfo->imageFormat;
        info.components.r = VK_COMPONENT_SWIZZLE_R;
        info.components.g = VK_COMPONENT_SWIZZLE_G;
        info.components.b = VK_COMPONENT_SWIZZLE_B;
        info.components.a = VK_COMPONENT_SWIZZLE_A;

        VkImageSubresourceRange image_range = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
        info.subresourceRange = image_range;

        for (uint32_t i = 0; i < _scImageCount; i++)
        {
            ImGui_ImplVulkanH_Frame* fd = &_ImVulkan_Frames[i];
            fd->Backbuffer = images[i];
            info.image = fd->Backbuffer;

            result = vkCreateImageView(device, &info, NULL, &fd->BackbufferView);
            if (result != VK_SUCCESS)
            {
                LOG_ERROR("vkCreateImageView error: {0:X}", (UINT) result);
                return;
            }

#ifdef VULKAN_DEBUG_LAYER
            SetVkObjectName(device, instance, VK_OBJECT_TYPE_IMAGE_VIEW, (UINT64) fd->BackbufferView,
                            "ImGui Backbuffer View");
#endif
        }
    }

    LOG_INFO("Vulkan UI initialization: framebuffers");
    // Create frame Buffer
    {
        VkImageView attachment[1];
        VkFramebufferCreateInfo info = {};
        info.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        info.renderPass = _vkRenderPass;
        info.attachmentCount = 1;
        info.pAttachments = attachment;

        info.width = pCreateInfo->imageExtent.width;
        info.height = pCreateInfo->imageExtent.height;

        info.layers = 1;

        for (uint32_t i = 0; i < _scImageCount; i++)
        {
            ImGui_ImplVulkanH_Frame* fd = &_ImVulkan_Frames[i];
            attachment[0] = fd->BackbufferView;
            result = vkCreateFramebuffer(device, &info, NULL, &fd->Framebuffer);
            if (result != VK_SUCCESS)
            {
                LOG_ERROR("vkCreateFramebuffer error: {0:X}", (UINT) result);
                return;
            }

#ifdef VULKAN_DEBUG_LAYER
            SetVkObjectName(device, instance, VK_OBJECT_TYPE_FRAMEBUFFER, (UINT64) fd->Framebuffer,
                            "ImGui Backbuffer Framebuffer");
#endif
        }
    }

    LOG_INFO("Vulkan UI initialization: frame resources");
    // Create command pools, command buffers, fences, and semaphores for every image
    for (uint32_t i = 0; i < _scImageCount; i++)
    {
        ImGui_ImplVulkanH_Frame* fd = &_ImVulkan_Frames[i];
        VkSemaphore* fsd = &_ImVulkan_Semaphores[i];
        {
            VkCommandPoolCreateInfo info = {};
            info.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
            info.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
            info.queueFamilyIndex = queueFamily;
            result = vkCreateCommandPool(device, &info, NULL, &fd->CommandPool);
            if (result != VK_SUCCESS)
            {
                LOG_ERROR("vkCreateCommandPool error: {0:X}", (UINT) result);
                return;
            }

#ifdef VULKAN_DEBUG_LAYER
            SetVkObjectName(device, instance, VK_OBJECT_TYPE_COMMAND_POOL, (UINT64) fd->CommandPool,
                            "ImGui Backbuffer Command Pool");
#endif
        }

        {
            VkCommandBufferAllocateInfo info = {};
            info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
            info.commandPool = fd->CommandPool;
            info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
            info.commandBufferCount = 1;
            result = vkAllocateCommandBuffers(device, &info, &fd->CommandBuffer);
            if (result != VK_SUCCESS)
            {
                LOG_ERROR("vkAllocateCommandBuffers error: {0:X}", (UINT) result);
                return;
            }

#ifdef VULKAN_DEBUG_LAYER
            SetVkObjectName(device, instance, VK_OBJECT_TYPE_COMMAND_BUFFER, (UINT64) fd->CommandBuffer,
                            "ImGui Backbuffer Command Buffer");
#endif
        }

        {
            VkFenceCreateInfo info = {};
            info.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
            info.flags = VK_FENCE_CREATE_SIGNALED_BIT;
            result = vkCreateFence(device, &info, NULL, &fd->Fence);
            if (result != VK_SUCCESS)
            {
                LOG_ERROR("vkCreateFence error: {0:X}", (UINT) result);
                return;
            }

#ifdef VULKAN_DEBUG_LAYER
            SetVkObjectName(device, instance, VK_OBJECT_TYPE_FENCE, (UINT64) fd->Fence, "ImGui Backbuffer Fence");
#endif
        }

        {
            VkSemaphoreCreateInfo info = {};
            info.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
            result = vkCreateSemaphore(device, &info, NULL, fsd);
            if (result != VK_SUCCESS)
            {
                LOG_ERROR("vkCreateSemaphore error: {0:X}", (UINT) result);
                return;
            }

#ifdef VULKAN_DEBUG_LAYER
            SetVkObjectName(device, instance, VK_OBJECT_TYPE_SEMAPHORE, (UINT64) fsd, "ImGui Backbuffer Semaphore");
#endif
        }
    }

    // Initialize ImGui and upload fonts
    {
        _ImVulkan_Info.Instance = instance;
        VkPhysicalDeviceProperties monitorGpu{};vkGetPhysicalDeviceProperties(pd,&monitorGpu);
    optishade::hardware::SetRenderGpu(monitorGpu.vendorID,monitorGpu.deviceName);
    _ImVulkan_Info.PhysicalDevice = pd;
        _ImVulkan_Info.Device = device;
        _ImVulkan_Info.QueueFamily = queueFamily;
        _ImVulkan_Info.Queue = queue;
        _ImVulkan_Info.DescriptorPool = pool;
        _ImVulkan_Info.Subpass = 0;
        _ImVulkan_Info.MinImageCount = pCreateInfo->minImageCount;
        _ImVulkan_Info.ImageCount = _scImageCount;
        _ImVulkan_Info.Allocator = NULL;
        _ImVulkan_Info.RenderPass = _vkRenderPass;

        LOG_INFO("Vulkan UI initialization: ImGui backend/pipeline begin");
        bool initResult = ImGui_ImplVulkan_Init(&_ImVulkan_Info);
        LOG_INFO("ImGui_ImplVulkan_Init result: {}", initResult);

        if (!initResult)
            return;

        // Texture uploads are handled by ImGui when rendering. The old
        // startup block recorded no GPU operations, but submitted an empty
        // command buffer and waited for every simulator queue to become idle.
        LOG_INFO("Vulkan UI initialization complete: images={} queueFamily={}; no empty upload or global startup wait",_scImageCount,queueFamily);

    }

    cleanup.complete=true;
    _overlayDrawOwner=OptiInput::BeginMenuDrawOwner();
    OptiInput::RequireMenuPresentProgress(true);
    _vulkanObjectsCreated = true;
    State::Instance().menuOverlayIsVulkan = true;
    LOG_FUNC_RESULT(_vulkanObjectsCreated);
}


void MenuOverlayVk::DestroyVulkanObjects(bool shutdown)
{
    std::lock_guard lock(_vkCleanMutex);
    OptiInput::SetMenuVisible(false);
    OptiInput::RequireMenuPresentProgress(false);
    OptiInput::RequireMenuDrawSubmission(false);
    _vulkanObjectsCreated=false;
    _isInited=false;
    _overlaySwapchain=VK_NULL_HANDLE;
    State::Instance().menuOverlayIsVulkan=false;
    const auto device=_ImVulkan_Info.Device;
    if(device) {
        // Retirement only, never once per frame. Includes outstanding present
        // waits before destroying image-indexed completion semaphores.
        vkDeviceWaitIdle(device);
        if(ImGui::GetCurrentContext() && ImGui::GetIO().BackendRendererUserData)
            ImGui_ImplVulkan_Shutdown(false);
        if(_ImVulkan_Frames) for(uint32_t i=0;i<_scImageCount;++i) {
            auto& f=_ImVulkan_Frames[i];
            if(f.Fence)vkDestroyFence(device,f.Fence,nullptr);
            if(f.CommandPool)vkDestroyCommandPool(device,f.CommandPool,nullptr);
            if(f.Framebuffer)vkDestroyFramebuffer(device,f.Framebuffer,nullptr);
            if(f.BackbufferView)vkDestroyImageView(device,f.BackbufferView,nullptr);
            if(_ImVulkan_Semaphores && _ImVulkan_Semaphores[i])vkDestroySemaphore(device,_ImVulkan_Semaphores[i],nullptr);
        }
        for(auto& imageResources:_retiredFrameResources)for(auto& retired:imageResources){
            if(retired.Fence)vkDestroyFence(device,retired.Fence,nullptr);
            if(retired.CommandPool)vkDestroyCommandPool(device,retired.CommandPool,nullptr);
            ImGui_ImplVulkan_DestroyRetiredFrameRenderBuffers(device,&retired.RenderBuffers,_ImVulkan_Info.Allocator);
        }
        if(_vkRenderPass)vkDestroyRenderPass(device,_vkRenderPass,nullptr);
        if(_ImVulkan_Info.DescriptorPool)vkDestroyDescriptorPool(device,_ImVulkan_Info.DescriptorPool,nullptr);
    }
    IM_FREE(_ImVulkan_Frames);IM_FREE(_ImVulkan_Semaphores);
    _ImVulkan_Frames=nullptr;_ImVulkan_Semaphores=nullptr;
    _imagePresentedSuccessfully.clear();
    _menuTraceSamples.clear();
    _pendingOverlaySubmission.clear();_retiredFrameResources.clear();_overlayQueueFamily=0;
    _vkRenderPass=VK_NULL_HANDLE;_scImageCount=0;_ImVulkan_Info={};
    if(shutdown && MenuOverlayBase::IsInited())MenuOverlayBase::Shutdown();
}

bool MenuOverlayVk::CanDrawAfterEffects(VkQueue queue, const VkPresentInfoKHR* info)
{
    return info && optishade::vkowner::DrawContract(_vulkanObjectsCreated,
        (uint64_t)queue,(uint64_t)_ImVulkan_Info.Queue,_overlaySwapchain,
        info->swapchainCount,info->pSwapchains,info->pImageIndices,_scImageCount);
}

struct PreparedOverlay { VkQueue queue{}; VkSwapchainKHR swap{}; uint32_t image{}; VkCommandBuffer command{}; bool nonempty=false; bool interactive=false; uint64_t owner=0; bool deferred=false; };
static thread_local PreparedOverlay _preparedOverlay;

static bool HasVisibleInteractiveMenuDraw(const ImDrawData* draw)
{
    const auto* panelDrawList=MenuCommon::InteractivePanelDrawList();
    if(!draw||!panelDrawList||draw->CmdListsCount<=0||draw->DisplaySize.x<=0.f||draw->DisplaySize.y<=0.f||
       panelDrawList->VtxBuffer.Size<=0||panelDrawList->CmdBuffer.Size<=0)
        return false;
    for(int i=0;i<draw->CmdListsCount;++i)
        if(draw->CmdLists[i]==panelDrawList)
            return true;
    return false;
}

void MenuOverlayVk::PreparePresent(VkQueue queue, const VkPresentInfoKHR* pPresentInfo)
{
    LOG_FUNC();
    struct PreparationAdmission {
        bool owned=false;const char* reason="prepare: owner/queue/extent or initialization unavailable";
        ~PreparationAdmission(){if(owned&&!_preparedOverlay.command){if(_preparedOverlay.deferred)OptiInput::ReportMenuDrawDeferred(_overlayDrawOwner);else OptiInput::ReportMenuDrawSubmission(false,_overlayDrawOwner,reason);}}
    } admission;
    if(pPresentInfo&&pPresentInfo->pSwapchains&&_overlaySwapchain)
        for(uint32_t i=0;i<pPresentInfo->swapchainCount;++i)
            if(pPresentInfo->pSwapchains[i]==_overlaySwapchain)admission.owned=true;
    if(!admission.owned)return; // Another window cannot discard the owning preparation.
    _preparedOverlay = {};

    if (!CanDrawAfterEffects(queue,pPresentInfo))
        return;
    const auto ownerIndex=optishade::vkowner::PresentIndex(_overlaySwapchain,pPresentInfo->swapchainCount,
        pPresentInfo->pSwapchains,pPresentInfo->pImageIndices,_scImageCount);

    if (!MenuOverlayBase::IsInited() || _ImVulkan_Info.Device == VK_NULL_HANDLE)
        return;



    // std::lock_guard<std::mutex> lock(_vkPresentMutex);
    LOG_DEBUG("rendering menu, swapchain count: {0}", pPresentInfo->swapchainCount);

    ImGuiIO& io = ImGui::GetIO();
    (void) io;
    io.BackendFlags |= ImGuiBackendFlags_RendererHasTextures;

    _frameCount++;

    {
        // Reusing a semaphore by acquired image guarantees its previous present
        // wait has completed, unlike cycling independently of the acquired image.
        if (pPresentInfo->pImageIndices[ownerIndex] >= _scImageCount)
            return;
        ReapRetiredFrameResources();
        auto semaphoreIndex = pPresentInfo->pImageIndices[ownerIndex];
        const bool acquiredAfterSuccessfulPresent = _imagePresentedSuccessfully[semaphoreIndex] != 0;
        // A present wait is not necessarily complete when vkQueuePresentKHR
        // returns. Reacquiring this exact image is the retirement proof, so
        // consume it once and let the next successful present re-arm it.
        _imagePresentedSuccessfully[semaphoreIndex] = 0;

        ImGui_ImplVulkan_NewFrame();
        RECT client{};
        if(!GetClientRect(MenuOverlayBase::Handle(),&client) || client.right<=0 || client.bottom<=0)return;
        io.DisplayFramebufferScale=ImVec2(float(_renderExtent.width)/client.right,float(_renderExtent.height)/client.bottom);

        if (State::Instance().delayMenuRenderBy > 0)
            State::Instance().delayMenuRenderBy--;

        admission.reason="prepare: no requested ImGui frame";
        if (MenuOverlayBase::RenderMenu())
        {
            admission.reason="prepare: draw intentionally delayed";
            if (State::Instance().delayMenuRenderBy == 0)
            {
                admission.reason="prepare: command recording failed";
                uint32_t idx = pPresentInfo->pImageIndices[ownerIndex];
                ImGui_ImplVulkanH_Frame* fd = &_ImVulkan_Frames[idx];
                const bool trace=optishade::xplane_layer::ProcessRoute().xplane &&
                    MenuOverlayBase::IsVisible() && _menuTraceCount<12;
                if(trace){
                    ++_menuTraceCount;
                    _menuTraceSamples[idx]={_frameCount,_overlayDrawOwner,true};
                }

                // Never block the simulator's presentation thread on an
                // overlay fence. Without proof from a successful prior present
                // of this reacquired image, preserve the game's wait chain.
                const auto fenceStatus = vkGetFenceStatus(_ImVulkan_Info.Device, fd->Fence);
                const auto fenceState = fenceStatus == VK_SUCCESS
                    ? optishade::vkoverlay::FenceState::Signaled
                    : fenceStatus == VK_NOT_READY
                        ? optishade::vkoverlay::FenceState::NotReady
                        : optishade::vkoverlay::FenceState::Error;
                const auto retiredCount=idx<_retiredFrameResources.size()?_retiredFrameResources[idx].size():optishade::vkoverlay::MaxRetiredFrameResources;
                const auto fenceDecision = optishade::vkoverlay::DecideAcquiredImageFence(
                    fenceState, acquiredAfterSuccessfulPresent, retiredCount);
                if(trace)LOG_INFO("XP12 menu sample frame={} owner={} image={} HWND={:X} queue={:X} swapchain={:X} fence={:X} fenceStatus={} retired={} reacquired={} decision={} (bounded: first 12 visible frames per owner)",
                    _frameCount,_overlayDrawOwner,idx,(uint64_t)MenuOverlayBase::Handle(),(uint64_t)queue,(uint64_t)_overlaySwapchain,
                    (uint64_t)fd->Fence,int(fenceStatus),retiredCount,acquiredAfterSuccessfulPresent,int(fenceDecision));
                if (fenceDecision == optishade::vkoverlay::FenceDecision::Defer) {
                    ImGui::Render();
                    _preparedOverlay={queue,pPresentInfo->pSwapchains[ownerIndex],idx,VK_NULL_HANDLE,false,false,_overlayDrawOwner,true};
                    static ULONGLONG lastBusyLog=0;const auto now=GetTickCount64();
                    if(now-lastBusyLog>=5000){lastBusyLog=now;LOG_INFO("Vulkan menu draw deferred: image={} has no retired-resource slot or matching overlay presentation proof",idx);}
                    return;
                }
                if (fenceDecision == optishade::vkoverlay::FenceDecision::DisableOverlay) {
                    ImGui::Render();LOG_ERROR("Vulkan overlay fence status: {0:X}", (UINT)fenceStatus);
                    _vulkanObjectsCreated=false;return;
                }
                if (fenceDecision == optishade::vkoverlay::FenceDecision::ReplaceResources && !RetireCurrentFrameResources(idx)) {
                    ImGui::Render();
                    _preparedOverlay={queue,pPresentInfo->pSwapchains[ownerIndex],idx,VK_NULL_HANDLE,false,false,_overlayDrawOwner,true};
                    return;
                }

                {
                    const auto reset=vkResetCommandPool(_ImVulkan_Info.Device, fd->CommandPool, 0);
                    if(reset!=VK_SUCCESS){ImGui::Render();_vulkanObjectsCreated=false;LOG_ERROR("Menu command-pool reset failed: {}",int(reset));return;}
                    VkCommandBufferBeginInfo info = {};
                    info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
                    info.flags |= VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
                    const auto begin=vkBeginCommandBuffer(fd->CommandBuffer, &info);
                    if(begin!=VK_SUCCESS){ImGui::Render();_vulkanObjectsCreated=false;LOG_ERROR("Menu command begin failed: {}",int(begin));return;}
                }

                if(!ImGui_ImplVulkan_SetFrameRenderBufferIndex(idx)){
                    ImGui::Render();
                    vkEndCommandBuffer(fd->CommandBuffer);
                    admission.reason="prepare: ImGui upload-buffer slot does not match the acquired image";
                    LOG_ERROR("Could not select ImGui upload-buffer slot for Vulkan overlay image={}",idx);
                    _vulkanObjectsCreated=false;
                    return;
                }

                {
                    VkRenderPassBeginInfo info = {};
                    info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
                    info.renderPass = _vkRenderPass;
                    info.framebuffer = fd->Framebuffer;
                    info.renderArea.extent.width = _renderExtent.width;
                    info.renderArea.extent.height = _renderExtent.height;
                    vkCmdBeginRenderPass(fd->CommandBuffer, &info, VK_SUBPASS_CONTENTS_INLINE);
                }

                // A diagnostic-only marker uses this exact command buffer and
                // image. It distinguishes an off-screen panel from a missing
                // Vulkan draw; it is not enabled by the normal route.
                if(optishade::xplane_layer::CurrentRoute()==optishade::xplane_layer::GraphicsRoute::MenuOnly && MenuOverlayBase::IsVisible()){
                    auto* viewport=ImGui::GetMainViewport();
                    auto* marker=ImGui::GetForegroundDrawList(viewport);
                    const auto origin=ImVec2(viewport->Pos.x+12.f,viewport->Pos.y+12.f);
                    marker->AddRectFilled(origin,ImVec2(origin.x+12.f,origin.y+12.f),IM_COL32(255,0,255,255));
                    marker->AddText(ImVec2(origin.x+18.f,origin.y-2.f),IM_COL32(255,255,255,255),"OptiShade menu-only test");
                }
                ImGui::Render();
                ImGui_ImplVulkan_RenderDrawData(ImGui::GetDrawData(), fd->CommandBuffer);

                // Submit command buffer
                vkCmdEndRenderPass(fd->CommandBuffer);
                auto ecbResult = vkEndCommandBuffer(fd->CommandBuffer);
                if (ecbResult != VK_SUCCESS)
                {
                    _vulkanObjectsCreated=false;
                    LOG_ERROR("Menu command end failed: {0:X}", (UINT) ecbResult);
                    return;
                }

                const auto* draw=ImGui::GetDrawData();
                const bool hasVertices=draw&&draw->CmdListsCount>0&&draw->TotalVtxCount>0;
                const bool interactivePanel=HasVisibleInteractiveMenuDraw(draw);
                if(trace)LOG_INFO("XP12 menu draw frame={} owner={} image={} framebuffer={:X} vertices={} lists={} interactive={} displayPos={},{} display={}x{} scale={},{} extent={}x{}",
                    _frameCount,_overlayDrawOwner,idx,(uint64_t)fd->Framebuffer,draw?draw->TotalVtxCount:0,draw?draw->CmdListsCount:0,interactivePanel,
                    draw?draw->DisplayPos.x:0.f,draw?draw->DisplayPos.y:0.f,draw?draw->DisplaySize.x:0.f,draw?draw->DisplaySize.y:0.f,
                    draw?draw->FramebufferScale.x:0.f,draw?draw->FramebufferScale.y:0.f,_renderExtent.width,_renderExtent.height);
                if(MenuOverlayBase::IsVisible()&&!interactivePanel){
                    static ULONGLONG lastPanelEvidenceLog=0;const auto now=GetTickCount64();
                    if(now-lastPanelEvidenceLog>=5000){lastPanelEvidenceLog=now;
                        const auto* panel=MenuCommon::InteractivePanelDrawList();
                        LOG_WARN("Visible Vulkan menu panel was not present in the submitted ImGui draw data: panelList={} panelVertices={} panelCommands={} drawLists={} totalVertices={} display={}x{}",
                            panel!=nullptr,panel?panel->VtxBuffer.Size:0,panel?panel->CmdBuffer.Size:0,
                            draw?draw->CmdListsCount:0,draw?draw->TotalVtxCount:0,
                            draw?draw->DisplaySize.x:0.f,draw?draw->DisplaySize.y:0.f);
                    }
                }
                _preparedOverlay = {queue, pPresentInfo->pSwapchains[ownerIndex], idx, fd->CommandBuffer,
                    hasVertices,interactivePanel,_overlayDrawOwner};
                if(!hasVertices){
                    static ULONGLONG lastEmptyDrawLog=0;const auto now=GetTickCount64();
                    if(now-lastEmptyDrawLog>=5000){
                        lastEmptyDrawLog=now;
                        const bool menuVisible=MenuOverlayBase::IsVisible();
                        const auto inputState=OptiInput::GetDebugState();
                        if(menuVisible||inputState.MenuVisible){
                            LOG_WARN("Vulkan overlay has no drawable ImGui data: menuVisible={} inputVisible={} display={}x{} scale={}x{} drawLists={} vertices={} activeWindows={} renderWindows={} frame={} renderExtent={}x{}",
                                menuVisible,inputState.MenuVisible,draw?draw->DisplaySize.x:0.f,draw?draw->DisplaySize.y:0.f,
                                io.DisplayFramebufferScale.x,io.DisplayFramebufferScale.y,
                                draw?draw->CmdListsCount:0,draw?draw->TotalVtxCount:0,io.MetricsActiveWindows,io.MetricsRenderWindows,
                                ImGui::GetFrameCount(),
                                _renderExtent.width,_renderExtent.height);
                        }
                    }
                }
                static bool logged=false;
                if(!logged){logged=true;LOG_INFO("Vulkan menu prepared outside effects presentation; callback is submit-only");}
            }
            else ImGui::Render();
        }
    }
}

bool MenuOverlayVk::QueuePresent(VkQueue queue, VkPresentInfoKHR* pPresentInfo, PFN_vkQueueSubmit submit)
{
    // Never build UI, upload fonts or call effects controls from inside the
    // effects layer's presentation locks. Preparation ran before that call.
    const bool valid=CanDrawAfterEffects(queue,pPresentInfo);
    const auto ownerIndex=valid?optishade::vkowner::PresentIndex(_overlaySwapchain,pPresentInfo->swapchainCount,
        pPresentInfo->pSwapchains,pPresentInfo->pImageIndices,_scImageCount):optishade::vkowner::NoPresentIndex;
    auto transaction=optishade::overlay::TakePrepared(_preparedOverlay,queue,
        valid?pPresentInfo->pSwapchains[ownerIndex]:VK_NULL_HANDLE,
        valid?pPresentInfo->pImageIndices[ownerIndex]:0,_overlayDrawOwner,valid);
    if(!transaction)return true; // Preparation reports failure; duplicates cannot undo success.
    const auto prepared=*transaction;
    struct SubmissionAdmission {
        uint64_t owner=0; bool submitted=false; bool deferred=false; const char* reason="submit: prepared frame did not match callback";
        ~SubmissionAdmission(){if(owner){if(deferred)OptiInput::ReportMenuDrawDeferred(owner);else OptiInput::ReportMenuDrawSubmission(submitted,owner,reason);}}
    } admission;
    if(pPresentInfo&&pPresentInfo->pSwapchains)
        for(uint32_t i=0;i<pPresentInfo->swapchainCount;++i)
            if(pPresentInfo->pSwapchains[i]==_overlaySwapchain)admission.owner=_overlayDrawOwner;
    if (prepared.deferred && CanDrawAfterEffects(queue,pPresentInfo) &&
        prepared.owner==_overlayDrawOwner && prepared.queue==queue &&
        prepared.swap==pPresentInfo->pSwapchains[ownerIndex] && prepared.image==pPresentInfo->pImageIndices[ownerIndex]) {
        admission.deferred=true;return true;
    }
    if (!prepared.command || !CanDrawAfterEffects(queue,pPresentInfo) ||
        prepared.owner!=_overlayDrawOwner || prepared.queue != queue || prepared.swap != pPresentInfo->pSwapchains[ownerIndex] ||
        prepared.image != pPresentInfo->pImageIndices[ownerIndex]) return true;
    auto* fd = &_ImVulkan_Frames[prepared.image];
    if(fd->CommandBuffer != prepared.command) return true;
    if(!optishade::overlay::ShouldSubmitPreparedOverlay(prepared.command!=VK_NULL_HANDLE,prepared.nonempty)){
        admission.reason="submit: ImGui produced no vertices";
        return true; // Keep the simulator's original present semaphore chain.
    }
    std::vector<VkPipelineStageFlags> stages(pPresentInfo->waitSemaphoreCount, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT);
    VkSubmitInfo info{VK_STRUCTURE_TYPE_SUBMIT_INFO};
    info.commandBufferCount=1; info.pCommandBuffers=&prepared.command;
    info.waitSemaphoreCount=pPresentInfo->waitSemaphoreCount; info.pWaitSemaphores=pPresentInfo->pWaitSemaphores;
    info.pWaitDstStageMask=stages.data(); info.signalSemaphoreCount=1;
    info.pSignalSemaphores=&_ImVulkan_Semaphores[prepared.image];
    const auto reset=vkResetFences(_ImVulkan_Info.Device,1,&fd->Fence);
    if(reset!=VK_SUCCESS){LOG_ERROR("Vulkan menu fence reset failed: {}",int(reset));return false;}
    const auto result=(submit?submit:vkQueueSubmit)(queue,1,&info,fd->Fence);
    optishade::vulkan_submit_observation::Snapshot submitObservation{};
    optishade::vulkan_submit_observation::CaptureLegacy(queue,&info,1,fd->Fence,
        static_cast<int32_t>(result),optishade::vulkan_submit_observation::Source::OptiShadeMenu,submitObservation);
    OptiShadeVulkanNrQueueSubmitObserved(&submitObservation);
    if(prepared.image<_menuTraceSamples.size()){
        const auto& trace=_menuTraceSamples[prepared.image];
        if(trace.pending&&trace.owner==prepared.owner){
            LOG_INFO("XP12 menu submit frame={} owner={} image={} command={:X} waitCount={} signal={:X} fence={:X} result={}",
                trace.frame,prepared.owner,prepared.image,(uint64_t)prepared.command,info.waitSemaphoreCount,
                (uint64_t)_ImVulkan_Semaphores[prepared.image],(uint64_t)fd->Fence,int(result));
            for(uint32_t i=0;i<info.waitSemaphoreCount&&i<8;++i)
                LOG_INFO("XP12 menu wait frame={} index={} semaphore={:X}",trace.frame,i,(uint64_t)info.pWaitSemaphores[i]);
        }
    }
    if(result!=VK_SUCCESS){
        LOG_ERROR("Vulkan menu submit failed: {}",int(result));
        _vulkanObjectsCreated=false;
        MenuOverlayBase::HideMenu();
        return false;
    }
    if(prepared.image<_pendingOverlaySubmission.size())_pendingOverlaySubmission[prepared.image]=prepared.nonempty?1:0;
    admission.reason="submit: no visible interactive menu panel was drawn";
    admission.submitted=prepared.nonempty&&prepared.interactive;
    pPresentInfo->waitSemaphoreCount=1;
    pPresentInfo->pWaitSemaphores=&_ImVulkan_Semaphores[prepared.image];
    return true;
}

void MenuOverlayVk::CreateSwapchain(VkDevice device, VkPhysicalDevice pd, VkInstance instance, HWND hwnd,
                                    const VkSwapchainCreateInfoKHR* pCreateInfo,
                                    const VkAllocationCallbacks* pAllocator, VkSwapchainKHR* pSwapchain, VkQueue queue, uint32_t queueFamily)
{
    LOG_FUNC();

    CreateVulkanObjects(device, pd, instance, hwnd, pCreateInfo, pSwapchain, queue, queueFamily);

    if (_vulkanObjectsCreated)
    {
        _overlaySwapchain = *pSwapchain;
        _isInited = true;
        MenuOverlayBase::VulkanReady();
        LOG_DEBUG("Vulkan ready");
    }
}

uint64_t MenuOverlayVk::DrawOwner(){return _overlayDrawOwner;}
void MenuOverlayVk::PresentProgress(uint64_t owner,VkResult result,uint32_t image){
    if(image<_menuTraceSamples.size()){
        auto& trace=_menuTraceSamples[image];
        if(trace.pending&&trace.owner==owner){
            LOG_INFO("XP12 menu present frame={} owner={} image={} result={} submitted={} (present return is not scanout proof)",
                trace.frame,owner,image,int(result),image<_pendingOverlaySubmission.size()&&_pendingOverlaySubmission[image]!=0);
            trace.pending=false;
        }
    }
    if(_preparedOverlay.owner==owner){
        _preparedOverlay={};
        OptiInput::ReportMenuDrawSubmission(false,owner,"submit: owning Present returned without consuming prepared overlay");
    }
    bool overlayPresented=false;
    bool overlayWasSubmitted=false;
    if(owner==_overlayDrawOwner&&image<_imagePresentedSuccessfully.size()){
        const bool presentSucceeded=result==VK_SUCCESS||result==VK_SUBOPTIMAL_KHR;
        overlayWasSubmitted=image<_pendingOverlaySubmission.size()&&_pendingOverlaySubmission[image];
        overlayPresented=presentSucceeded&&overlayWasSubmitted;
        _imagePresentedSuccessfully[image]=overlayPresented?1:0;
        if(image<_pendingOverlaySubmission.size())_pendingOverlaySubmission[image]=0;
    }
    if(overlayWasSubmitted)
        OptiInput::ReportMenuPresentProgress(owner,overlayPresented);
}
