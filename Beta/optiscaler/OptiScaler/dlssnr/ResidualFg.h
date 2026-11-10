#pragma once

// Direct NVIDIA NGX resource-output FG, separate from presentation-managed FG.
// The owner serializes NGX calls and keeps this object and all inputs alive until
// GPU completion. Create must be submitted before Evaluate. No DLL loading here.
#include <nvsdk_ngx.h>
#include <d3d12.h>
#include <cmath>
#include <initializer_list>

namespace DlssNr
{
struct ResidualFgApi
{
    decltype(&NVSDK_NGX_D3D12_GetCapabilityParameters) capabilities = nullptr;
    decltype(&NVSDK_NGX_D3D12_AllocateParameters) allocate = nullptr;
    decltype(&NVSDK_NGX_D3D12_DestroyParameters) destroy = nullptr;
    decltype(&NVSDK_NGX_D3D12_CreateFeature) create = nullptr;
    decltype(&NVSDK_NGX_D3D12_EvaluateFeature) evaluate = nullptr;
    decltype(&NVSDK_NGX_D3D12_ReleaseFeature) release = nullptr;
};

struct ResidualFgCamera
{
    float viewToClip[16] {}, clipToView[16] {}, clipToPrevious[16] {}, previousToClip[16] {};
    float position[3] {}, up[3] {}, right[3] {}, forward[3] {};
    float nearPlane = 0, farPlane = 0, fov = 0, aspect = 0;
    bool orthographic = false;
    // Must refer to the SAME interval as the two NR anchors and composed MVs.
    // A caller cannot silently substitute stationary-camera transforms.
    bool valid = false;
    bool IsValid() const
    {
        if (!valid || !(aspect > 0) || !std::isfinite(aspect) || !std::isfinite(fov) ||
            !std::isfinite(nearPlane) || !std::isfinite(farPlane)) return false;
        for (auto matrix : { viewToClip, clipToView, clipToPrevious, previousToClip })
            for (unsigned i = 0; i < 16; ++i) if (!std::isfinite(matrix[i])) return false;
        for (auto vector : { position, up, right, forward })
            for (unsigned i = 0; i < 3; ++i) if (!std::isfinite(vector[i])) return false;
        return true;
    }
};

class ResidualFg
{
    ResidualFgApi api;
    NVSDK_NGX_Parameter* parameters = nullptr;
    NVSDK_NGX_Handle* handle = nullptr;
    unsigned width = 0, height = 0, guideWidth = 0, guideHeight = 0;
    float identity[16] {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
    // Pointer-valued NGX camera parameters must not refer to a caller's stack.
    ResidualFgCamera camera;

public:
    explicit ResidualFg(ResidualFgApi functions) : api(functions) {}
    ResidualFg(const ResidualFg&) = delete;
    ResidualFg& operator=(const ResidualFg&) = delete;
    ~ResidualFg()
    {
        if (handle) api.release(handle);
        if (parameters) api.destroy(parameters);
    }

    NVSDK_NGX_Result Create(ID3D12GraphicsCommandList* cmd, unsigned w, unsigned h,
                            unsigned gw, unsigned gh)
    {
        if (handle || parameters || !cmd || !w || !h || !gw || !gh || !api.capabilities ||
            !api.allocate || !api.destroy || !api.create || !api.evaluate || !api.release)
            return NVSDK_NGX_Result_FAIL_InvalidParameter;
        NVSDK_NGX_Parameter* caps = nullptr;
        auto result = api.capabilities(&caps);
        if (result != NVSDK_NGX_Result_Success || !caps) return result;
        int available = 0;
        result = caps->Get("FrameGeneration.Available", &available);
        api.destroy(caps);
        if (result != NVSDK_NGX_Result_Success || !available)
            return NVSDK_NGX_Result_FAIL_FeatureNotSupported;
        result = api.allocate(&parameters);
        if (result != NVSDK_NGX_Result_Success || !parameters) return result;
        width=w; height=h; guideWidth=gw; guideHeight=gh;
        parameters->Set(NVSDK_NGX_Parameter_CreationNodeMask, 1u);
        parameters->Set(NVSDK_NGX_Parameter_VisibilityNodeMask, 1u);
        parameters->Set(NVSDK_NGX_Parameter_Width, w);
        parameters->Set(NVSDK_NGX_Parameter_Height, h);
        parameters->Set("DLSSG.BackbufferFormat", (unsigned)DXGI_FORMAT_R16G16B16A16_FLOAT);
        parameters->Set("DLSSG.InternalWidth", gw);
        parameters->Set("DLSSG.InternalHeight", gh);
        parameters->Set("DLSSG.DynamicResolution", 0u);
        return api.create(cmd, NVSDK_NGX_Feature_FrameGeneration, parameters, &handle);
    }

    // normalizedMotion contains current -> previous ANCHOR displacements in UV
    // units. Depth and motion must describe the same active guide rectangle.
    // suppression is an application-owned UAV buffer >= 4 bytes. A nonzero first
    // byte means the generated output must not be presented (cuts/invalid history).
    NVSDK_NGX_Result Evaluate(ID3D12GraphicsCommandList* cmd, ID3D12Resource* carrier,
                              ID3D12Resource* depth, ID3D12Resource* normalizedMotion,
                              ID3D12Resource* output, ID3D12Resource* suppression,
                              const ResidualFgCamera& data, bool invertedDepth, bool reset,
                              unsigned long long anchorId)
    {
        if (!handle || !cmd || !carrier || !depth || !normalizedMotion || !output || !suppression ||
            carrier == output || !data.IsValid()) return NVSDK_NGX_Result_FAIL_InvalidParameter;
        auto inputDesc = carrier->GetDesc(), outputDesc = output->GetDesc();
        if (inputDesc.Width != width || inputDesc.Height != height ||
            inputDesc.Format != DXGI_FORMAT_R16G16B16A16_FLOAT || outputDesc.Width != width ||
            outputDesc.Height != height || outputDesc.Format != inputDesc.Format)
            return NVSDK_NGX_Result_FAIL_InvalidParameter;
        camera = data;
        auto* p = parameters;
        p->Set("DLSSG.Backbuffer", carrier); p->Set("DLSSG.Depth", depth);
        p->Set("DLSSG.MVecs", normalizedMotion); p->Set("DLSSG.OutputInterpolated", output);
        p->Set("DLSSG.OutputDisableInterpolation", suppression);
        p->Set("DLSSG.MultiFrameCount", 1u); p->Set("DLSSG.MultiFrameIndex", 1u);
        p->Set("DLSSG.BackbufferFrameID", anchorId);
        p->Set("DLSSG.CameraViewToClip", (void*)camera.viewToClip);
        p->Set("DLSSG.ClipToCameraView", (void*)camera.clipToView);
        p->Set("DLSSG.ClipToPrevClip", (void*)camera.clipToPrevious);
        p->Set("DLSSG.PrevClipToClip", (void*)camera.previousToClip);
        p->Set("DLSSG.ClipToLensClip", (void*)identity);
        p->Set("DLSSG.CameraNear", camera.nearPlane); p->Set("DLSSG.CameraFar", camera.farPlane);
        p->Set("DLSSG.CameraFOV", camera.fov); p->Set("DLSSG.CameraAspectRatio", camera.aspect);
        p->Set("DLSSG.OrthoProjection", (unsigned)camera.orthographic);
        p->Set("DLSSG.CameraPosX", camera.position[0]); p->Set("DLSSG.CameraPosY", camera.position[1]);
        p->Set("DLSSG.CameraPosZ", camera.position[2]);
        p->Set("DLSSG.CameraUpX", camera.up[0]); p->Set("DLSSG.CameraUpY", camera.up[1]);
        p->Set("DLSSG.CameraUpZ", camera.up[2]);
        p->Set("DLSSG.CameraRightX", camera.right[0]); p->Set("DLSSG.CameraRightY", camera.right[1]);
        p->Set("DLSSG.CameraRightZ", camera.right[2]);
        p->Set("DLSSG.CameraFwdX", camera.forward[0]); p->Set("DLSSG.CameraFwdY", camera.forward[1]);
        p->Set("DLSSG.CameraFwdZ", camera.forward[2]);
        p->Set("DLSSG.MvecScaleX", 1.0f); p->Set("DLSSG.MvecScaleY", 1.0f);
        p->Set("DLSSG.MvecInvalidValue", 65504.0f);
        p->Set("DLSSG.CameraMotionIncluded", 1u); p->Set("DLSSG.MvecDilated", 0u);
        p->Set("DLSSG.MvecJittered", 0u); p->Set("DLSSG.ColorBuffersHDR", 0u);
        p->Set("DLSSG.DepthInverted", (unsigned)invertedDepth); p->Set("DLSSG.Reset", (unsigned)reset);
        p->Set("DLSSG.JitterOffsetX", 0.0f); p->Set("DLSSG.JitterOffsetY", 0.0f);
        p->Set("DLSSG.CameraPinholeOffsetX", 0.0f); p->Set("DLSSG.CameraPinholeOffsetY", 0.0f);
        p->Set("DLSSG.MenuDetectionEnabled", 0u); p->Set("DLSSG.NotRenderingGameFrames", 0u);
        p->Set("DLSSG.AutomodeOverrideReset", 0u);
        p->Set("DLSSG.MVecsSubrectBaseX", 0u); p->Set("DLSSG.MVecsSubrectBaseY", 0u);
        p->Set("DLSSG.MVecsSubrectWidth", guideWidth); p->Set("DLSSG.MVecsSubrectHeight", guideHeight);
        p->Set("DLSSG.DepthSubrectBaseX", 0u); p->Set("DLSSG.DepthSubrectBaseY", 0u);
        p->Set("DLSSG.DepthSubrectWidth", guideWidth); p->Set("DLSSG.DepthSubrectHeight", guideHeight);
        return api.evaluate(cmd, handle, p, nullptr);
    }
};
}
