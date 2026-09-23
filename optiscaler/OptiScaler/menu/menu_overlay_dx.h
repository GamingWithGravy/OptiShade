#pragma once

#include "SysUtils.h"
#include <d3d11_4.h>
#include <d3d12.h>
#include <dxgi1_6.h>

namespace MenuOverlayDx
{
bool IsPrimaryWindow(HWND window,bool claim=false);
bool IsPrimarySwapchain(HWND window, IDXGISwapChain* swapchain, bool claim=false);
void RetireSwapchain(HWND window, IDXGISwapChain* swapchain);
ID3D12GraphicsCommandList* MenuCommandList();
void CleanupRenderTarget(bool clearQueue, HWND hWnd);
void Present(IDXGISwapChain* pSwapChain, UINT SyncInterval, UINT Flags,
             const DXGI_PRESENT_PARAMETERS* pPresentParameters, IUnknown* pDevice, HWND hWnd, bool isUWP);
} // namespace MenuOverlayDx
