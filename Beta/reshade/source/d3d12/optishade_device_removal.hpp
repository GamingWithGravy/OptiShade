/*
 * OptiShade: name the cause when a D3D12 device is removed.
 *
 * A fence signalled with UINT64_MAX fires only on device removal, however the
 * removal is noticed (the game, a provider or ReShade). Its callback logs the
 * removal reason and, when ReShade.ini [OPTISHADE] GpuCrashBreadcrumbs=1 enabled
 * DRED before device creation, the unfinished command lists' current operation
 * and the page-fault allocation. Lines start with "OptiShade GPU removal" so the
 * troubleshooter can quote them.
 */
#pragma once

#include <d3d12.h>
#include <atomic>
#include <string>
#include "dll_log.hpp"
#include "ini_file.hpp"

namespace optishade::device_removal
{
	inline std::atomic<bool> g_breadcrumbs_enabled { false };

	// Must run before the first D3D12CreateDevice of the process to take effect.
	template <typename GetDebugInterface>
	inline void enable_breadcrumbs_if_requested(GetDebugInterface get_debug_interface)
	{
		static std::atomic<bool> attempted { false };
		if (attempted.exchange(true))
			return;
		bool requested = false;
		reshade::global_config().get("OPTISHADE", "GpuCrashBreadcrumbs", requested);
		if (!requested)
			return;
		ID3D12DeviceRemovedExtendedDataSettings *settings = nullptr;
		if (SUCCEEDED(get_debug_interface(__uuidof(ID3D12DeviceRemovedExtendedDataSettings), reinterpret_cast<void **>(&settings))) && settings != nullptr)
		{
			settings->SetAutoBreadcrumbsEnablement(D3D12_DRED_ENABLEMENT_FORCED_ON);
			settings->SetPageFaultEnablement(D3D12_DRED_ENABLEMENT_FORCED_ON);
			settings->Release();
			g_breadcrumbs_enabled = true;
			reshade::log::message(reshade::log::level::info, "OptiShade GPU removal: DRED breadcrumbs and page-fault tracking enabled (GpuCrashBreadcrumbs=1).");
		}
		else
		{
			reshade::log::message(reshade::log::level::warning, "OptiShade GPU removal: GpuCrashBreadcrumbs=1 was requested but DRED settings are unavailable on this system.");
		}
	}

	inline const char *op_name(D3D12_AUTO_BREADCRUMB_OP op)
	{
		static const char *const names[] = {
			"SetMarker", "BeginEvent", "EndEvent", "DrawInstanced", "DrawIndexedInstanced", "ExecuteIndirect", "Dispatch",
			"CopyBufferRegion", "CopyTextureRegion", "CopyResource", "CopyTiles", "ResolveSubresource", "ClearRenderTargetView",
			"ClearUnorderedAccessView", "ClearDepthStencilView", "ResourceBarrier", "ExecuteBundle", "Present", "ResolveQueryData",
			"BeginSubmission", "EndSubmission", "DecodeFrame", "ProcessFrames", "AtomicCopyBufferUint", "AtomicCopyBufferUint64",
			"ResolveSubresourceRegion", "WriteBufferImmediate", "DecodeFrame1", "SetProtectedResourceSession", "DecodeFrame2",
			"ProcessFrames1", "BuildRaytracingAccelerationStructure", "EmitRaytracingAccelerationStructurePostbuildInfo",
			"CopyRaytracingAccelerationStructure", "DispatchRays", "InitializeMetaCommand", "ExecuteMetaCommand", "EstimateMotion",
			"ResolveMotionVectorHeap", "SetPipelineState1", "InitializeExtensionCommand", "ExecuteExtensionCommand" };
		const auto index = static_cast<size_t>(op);
		return index < std::size(names) ? names[index] : "Unknown";
	}

	inline std::string narrow_name(const char *a, const wchar_t *w)
	{
		if (a != nullptr && a[0] != '\0')
			return a;
		if (w != nullptr && w[0] != L'\0')
		{
			std::string out;
			for (const wchar_t *c = w; *c != L'\0' && out.size() < 120; ++c)
				out.push_back(*c < 128 ? static_cast<char>(*c) : '?');
			return out;
		}
		return "unnamed";
	}

	inline void log_removal(ID3D12Device *device)
	{
		const HRESULT reason = device->GetDeviceRemovedReason();
		reshade::log::message(reshade::log::level::error, "OptiShade GPU removal: device removed, reason %s.", reshade::log::hr_to_string(reason).c_str());

		ID3D12DeviceRemovedExtendedData *dred = nullptr;
		if (FAILED(device->QueryInterface(IID_PPV_ARGS(&dred))) || dred == nullptr)
		{
			reshade::log::message(reshade::log::level::error, "OptiShade GPU removal: no DRED data. Set [OPTISHADE] GpuCrashBreadcrumbs=1 in ReShade.ini and reproduce to record the failing GPU operation.");
			return;
		}

		D3D12_DRED_AUTO_BREADCRUMBS_OUTPUT breadcrumbs = {};
		if (SUCCEEDED(dred->GetAutoBreadcrumbsOutput(&breadcrumbs)))
		{
			unsigned int logged = 0, nodes = 0;
			for (const D3D12_AUTO_BREADCRUMB_NODE *node = breadcrumbs.pHeadAutoBreadcrumbNode; node != nullptr && nodes < 4096; node = node->pNext, ++nodes)
			{
				if (node->pLastBreadcrumbValue == nullptr || node->pCommandHistory == nullptr || node->BreadcrumbCount == 0)
					continue;
				const UINT32 completed = *node->pLastBreadcrumbValue;
				if (completed >= node->BreadcrumbCount)
					continue; // This command list finished; it is not where the GPU stopped.
				if (logged++ >= 8)
					break;
				const D3D12_AUTO_BREADCRUMB_OP current = node->pCommandHistory[completed];
				const D3D12_AUTO_BREADCRUMB_OP previous = completed > 0 ? node->pCommandHistory[completed - 1] : current;
				reshade::log::message(reshade::log::level::error,
					"OptiShade GPU removal: unfinished command list '%s' on queue '%s' (list %p): completed %u of %u operations; stopped at %s (after %s).",
					narrow_name(node->pCommandListDebugNameA, node->pCommandListDebugNameW).c_str(),
					narrow_name(node->pCommandQueueDebugNameA, node->pCommandQueueDebugNameW).c_str(),
					static_cast<void *>(node->pCommandList), completed, node->BreadcrumbCount, op_name(current), op_name(previous));
			}
			if (logged == 0)
				reshade::log::message(reshade::log::level::error, "OptiShade GPU removal: DRED recorded no unfinished command list%s.", g_breadcrumbs_enabled ? "" : " (breadcrumbs were not enabled; set GpuCrashBreadcrumbs=1)");
		}

		D3D12_DRED_PAGE_FAULT_OUTPUT fault = {};
		if (SUCCEEDED(dred->GetPageFaultAllocationOutput(&fault)) && fault.PageFaultVA != 0)
		{
			std::string existing, freed;
			unsigned int count = 0;
			for (const D3D12_DRED_ALLOCATION_NODE *node = fault.pHeadExistingAllocationNode; node != nullptr && count < 6; node = node->pNext, ++count)
				existing += (existing.empty() ? "" : ", ") + narrow_name(node->ObjectNameA, node->ObjectNameW);
			count = 0;
			for (const D3D12_DRED_ALLOCATION_NODE *node = fault.pHeadRecentFreedAllocationNode; node != nullptr && count < 6; node = node->pNext, ++count)
				freed += (freed.empty() ? "" : ", ") + narrow_name(node->ObjectNameA, node->ObjectNameW);
			reshade::log::message(reshade::log::level::error,
				"OptiShade GPU removal: page fault at GPU VA 0x%llx; live allocations there: %s; recently freed there: %s.",
				static_cast<unsigned long long>(fault.PageFaultVA), existing.empty() ? "none" : existing.c_str(), freed.empty() ? "none" : freed.c_str());
		}
		dred->Release();
	}

	struct watcher
	{
		ID3D12Device *device = nullptr; // borrowed; the fence keeps the device alive
		ID3D12Fence *fence = nullptr;
		HANDLE event = nullptr;
		HANDLE wait = nullptr;
	};

	inline void CALLBACK on_removed(void *context, BOOLEAN)
	{
		auto *const w = static_cast<watcher *>(context);
		log_removal(w->device);
	}

	inline watcher *start(ID3D12Device *device)
	{
		auto *const w = new watcher();
		w->device = device;
		w->event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
		if (w->event != nullptr &&
			SUCCEEDED(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&w->fence))) &&
			SUCCEEDED(w->fence->SetEventOnCompletion(UINT64_MAX, w->event)) &&
			RegisterWaitForSingleObject(&w->wait, w->event, &on_removed, w, INFINITE, WT_EXECUTEONLYONCE))
			return w;
		if (w->fence != nullptr)
			w->fence->Release();
		if (w->event != nullptr)
			CloseHandle(w->event);
		delete w;
		reshade::log::message(reshade::log::level::warning, "OptiShade GPU removal: device-removal watcher could not be started.");
		return nullptr;
	}

	inline void stop(watcher *w)
	{
		if (w == nullptr)
			return;
		if (w->wait != nullptr)
			UnregisterWaitEx(w->wait, INVALID_HANDLE_VALUE); // waits for a running callback
		if (w->fence != nullptr)
			w->fence->Release();
		if (w->event != nullptr)
			CloseHandle(w->event);
		delete w;
	}
}
