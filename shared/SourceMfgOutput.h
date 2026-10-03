// Trusted source-backend callback published only after hash/receipt validation.
#pragma once
#include <atomic>
#include <windows.h>
struct IDXGISwapChain;
namespace optishade::mfg::source {
using Present=void(WINAPI*)(IDXGISwapChain*);
inline std::atomic<Present> observePresent{nullptr};
inline void ObservePresent(IDXGISwapChain* target){auto fn=observePresent.load(std::memory_order_acquire);if(fn)fn(target);}
}
