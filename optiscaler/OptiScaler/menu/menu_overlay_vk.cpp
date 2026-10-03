#include "pch.h"
#include "menu_overlay_base.h"
#include "menu_overlay_vk.h"

#include <Util.h>
#include <Config.h>
#include <SysUtils.h>
#include "../../../shared/VulkanOwner.h"

#include <imgui/imgui_impl_vulkan.h>
#include <imgui/imgui_impl_win32.h>

// Vulkan overlay code adopted from here:
// https://gist.github.com/mem99/0ec31ca302927457f86b1d6756aaa8c4
// Need to check resize & recreate fixes

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

    vkSetDebugUtilsObjectNameEXT(device, &info);
}

static void CreateVulkanObjects(VkDevice device, VkPhysicalDevice pd, VkInstance instance, HWND hwnd,
                                const VkSwapchainCreateInfoKHR* pCreateInfo, VkSwapchainKHR* pSwapchain, VkQueue queue, uint32_t queueFamily)
{
    LOG_FUNC();

    if (device == VK_NULL_HANDLE || pCreateInfo == nullptr || *pSwapchain == VK_NULL_HANDLE)
    {
        LOG_WARN(
            "device({0:X}) == VK_NULL_HANDLE || pCreateInfo({1:X}) == nullptr || *pSwapchain({2:X}) == VK_NULL_HANDLE",
            (UINT64) device, (UINT64) pCreateInfo, (UINT64) *pSwapchain);
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
    std::memset(_ImVulkan_Frames,0,sizeof(ImGui_ImplVulkanH_Frame)*_scImageCount);
    std::memset(_ImVulkan_Semaphores,0,sizeof(VkSemaphore)*_scImageCount);
    struct PartialCleanup { bool complete=false; ~PartialCleanup(){if(!complete)MenuOverlayVk::DestroyVulkanObjects(false);} } cleanup;

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

        bool initResult = ImGui_ImplVulkan_Init(&_ImVulkan_Info);
        LOG_DEBUG("ImGui_ImplVulkan_Init result: {}", initResult);

        if (!initResult)
            return;

        // Upload Fonts
        // Use any command queue
        VkCommandPool command_pool = _ImVulkan_Frames[0].CommandPool;
        VkCommandBuffer command_buffer = _ImVulkan_Frames[0].CommandBuffer;
        result = vkResetCommandPool(device, command_pool, 0);
        if (result != VK_SUCCESS)
        {
            LOG_ERROR("vkBeginCommandBuffer error: {0:X}", (UINT) result);
            return;
        }

        VkCommandBufferBeginInfo begin_info = {};
        begin_info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin_info.flags |= VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        result = vkBeginCommandBuffer(command_buffer, &begin_info);
        if (result != VK_SUCCESS)
        {
            LOG_ERROR("vkBeginCommandBuffer error: {0:X}", (UINT) result);
            return;
        }

        // initResult = ImGui_ImplVulkan_CreateFontsTexture();
        // LOG_DEBUG("ImGui_ImplVulkan_CreateFontsTexture result: {}", initResult);

        VkSubmitInfo end_info = {};
        end_info.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        end_info.commandBufferCount = 1;
        end_info.pCommandBuffers = &command_buffer;

        result = vkEndCommandBuffer(command_buffer);
        if (result != VK_SUCCESS)
        {
            LOG_ERROR("vkEndCommandBuffer error: {0:X}", (UINT) result);
            return;
        }

        result = vkQueueSubmit(queue, 1, &end_info, VK_NULL_HANDLE);
        if (result != VK_SUCCESS)
        {
            LOG_ERROR("vkQueueSubmit error: {0:X}", (UINT) result);
            return;
        }

        result = vkDeviceWaitIdle(device);
        if (result != VK_SUCCESS)
        {
            LOG_ERROR("vkDeviceWaitIdle error: {0:X}", (UINT) result);
            return;
        }
    }

    cleanup.complete=true;
    _vulkanObjectsCreated = true;
    State::Instance().menuOverlayIsVulkan = true;
    LOG_FUNC_RESULT(_vulkanObjectsCreated);
}

void MenuOverlayVk::DestroyVulkanObjects(bool shutdown)
{
    std::lock_guard lock(_vkCleanMutex);
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
        if(_vkRenderPass)vkDestroyRenderPass(device,_vkRenderPass,nullptr);
        if(_ImVulkan_Info.DescriptorPool)vkDestroyDescriptorPool(device,_ImVulkan_Info.DescriptorPool,nullptr);
    }
    IM_FREE(_ImVulkan_Frames);IM_FREE(_ImVulkan_Semaphores);
    _ImVulkan_Frames=nullptr;_ImVulkan_Semaphores=nullptr;
    _vkRenderPass=VK_NULL_HANDLE;_scImageCount=0;_ImVulkan_Info={};
    if(shutdown && MenuOverlayBase::IsInited())MenuOverlayBase::Shutdown();
}

bool MenuOverlayVk::CanDrawAfterEffects(VkQueue queue, const VkPresentInfoKHR* info)
{
    return info && info->pSwapchains && info->pImageIndices &&
        optishade::vkowner::DrawContract(_vulkanObjectsCreated,(uint64_t)queue,(uint64_t)_ImVulkan_Info.Queue,
            info->swapchainCount ? (uint64_t)info->pSwapchains[0] : 0,(uint64_t)_overlaySwapchain,
            info->swapchainCount,info->swapchainCount ? info->pImageIndices[0] : 0,_scImageCount);
}

bool MenuOverlayVk::QueuePresent(VkQueue queue, VkPresentInfoKHR* pPresentInfo, PFN_vkQueueSubmit submit)
{
    LOG_FUNC();

    if (!CanDrawAfterEffects(queue,pPresentInfo))
        return true;

    if (!MenuOverlayBase::IsInited() || _ImVulkan_Info.Device == VK_NULL_HANDLE)
        return true;



    // std::lock_guard<std::mutex> lock(_vkPresentMutex);
    LOG_DEBUG("rendering menu, swapchain count: {0}", pPresentInfo->swapchainCount);

    ImGuiIO& io = ImGui::GetIO();
    (void) io;
    io.BackendFlags |= ImGuiBackendFlags_RendererHasTextures;

    _frameCount++;

    {
        // Reusing a semaphore by acquired image guarantees its previous present
        // wait has completed, unlike cycling independently of the acquired image.
        if (pPresentInfo->pImageIndices[0] >= _scImageCount)
            return false;
        auto semaphoreIndex = pPresentInfo->pImageIndices[0];

        ImGui_ImplVulkan_NewFrame();
        RECT client{};
        if(!GetClientRect(MenuOverlayBase::Handle(),&client) || client.right<=0 || client.bottom<=0)return true;
        io.DisplayFramebufferScale=ImVec2(float(_renderExtent.width)/client.right,float(_renderExtent.height)/client.bottom);

        if (State::Instance().delayMenuRenderBy > 0)
            State::Instance().delayMenuRenderBy--;

        if (MenuOverlayBase::RenderMenu())
        {
            if (State::Instance().delayMenuRenderBy == 0)
            {
                uint32_t idx = pPresentInfo->pImageIndices[0];
                ImGui_ImplVulkanH_Frame* fd = &_ImVulkan_Frames[idx];

                vkWaitForFences(_ImVulkan_Info.Device, 1, &fd->Fence, VK_TRUE, UINT64_MAX);


                {
                    vkResetCommandPool(_ImVulkan_Info.Device, fd->CommandPool, 0);
                    VkCommandBufferBeginInfo info = {};
                    info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
                    info.flags |= VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
                    vkBeginCommandBuffer(fd->CommandBuffer, &info);
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

                ImGui::Render();
                ImGui_ImplVulkan_RenderDrawData(ImGui::GetDrawData(), fd->CommandBuffer);

                // Submit command buffer
                vkCmdEndRenderPass(fd->CommandBuffer);
                auto ecbResult = vkEndCommandBuffer(fd->CommandBuffer);
                if (ecbResult != VK_SUCCESS)
                {
                    LOG_ERROR("vkQueueSubmit error: {0:X}", (UINT) ecbResult);
                    return false;
                }

                // Submit queue and semaphores
                LOG_DEBUG("waitSemaphoreCount: {0}", pPresentInfo->waitSemaphoreCount);
                std::vector<VkPipelineStageFlags> waitStages(pPresentInfo->waitSemaphoreCount,
                                                           VK_PIPELINE_STAGE_ALL_COMMANDS_BIT);

                VkSubmitInfo submit_info = {};
                submit_info.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
                submit_info.commandBufferCount = 1;
                submit_info.pCommandBuffers = &fd->CommandBuffer;
                submit_info.pWaitDstStageMask = waitStages.data();
                submit_info.waitSemaphoreCount = pPresentInfo->waitSemaphoreCount;
                submit_info.pWaitSemaphores = pPresentInfo->pWaitSemaphores;
                submit_info.signalSemaphoreCount = 1;
                submit_info.pSignalSemaphores = &_ImVulkan_Semaphores[semaphoreIndex];

                // The effects layer supplies its downstream submit while holding
                // queue synchronization, avoiding another effects/add-on flush.
                vkResetFences(_ImVulkan_Info.Device,1,&fd->Fence);
                auto qResult = (submit ? submit : vkQueueSubmit)(_ImVulkan_Info.Queue, 1, &submit_info, fd->Fence);
                if (qResult != VK_SUCCESS)
                {
                    LOG_ERROR("vkQueueSubmit error: {0:X}", (UINT) qResult);
                    _vulkanObjectsCreated=false; // Do not wait on an unsignalled failed-submit fence next frame.
                    return false;
                }

                pPresentInfo->waitSemaphoreCount = 1;
                pPresentInfo->pWaitSemaphores = &_ImVulkan_Semaphores[semaphoreIndex];
            }
            else
            {
                // To make RenderMenu happy as it expects this
                ImGui::Render();
            }
        }
    }

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
