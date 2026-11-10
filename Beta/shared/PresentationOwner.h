#pragma once
#include <Windows.h>
#include <array>
#include <cstdint>
#include <mutex>
namespace optishade {
// One authority per output window (or explicit windowless swapchain). Borrowed
// identities are retired by the owning swapchain; no in-flight entry is evicted.
class PresentationOwner {
    struct Entry{HWND window=nullptr;const void* chain=nullptr;uint64_t generation=0;bool used=false;};
    std::array<Entry,16> outputs{};std::mutex mutex;uint64_t serial=0;
    void Prune(){for(auto& e:outputs)if(e.used&&e.window&&!IsWindow(e.window))e={};}
    Entry* Find(HWND window,const void* chain){for(auto& e:outputs)if(e.used&&e.window==window&&(window||e.chain==chain))return &e;return nullptr;}
public:
    bool Accept(HWND candidate,bool claim=false,const void* identity=nullptr){
        if(!candidate&&!identity)return true;
        std::lock_guard lock(mutex);Prune();
        auto* e=Find(candidate,identity);
        if(e){if(e->chain&&identity&&e->chain!=identity)return false;if(claim&&!e->chain&&identity){e->chain=identity;e->generation=++serial;}return true;}
        if(candidate){DWORD pid=0;GetWindowThreadProcessId(candidate,&pid);
            if(!IsWindow(candidate)||pid!=GetCurrentProcessId()||
               (GetWindowLongPtrW(candidate,GWL_EXSTYLE)&WS_EX_TOOLWINDOW))return false;
            // DXGI can present into a child or owned rendering HWND. A window
            // hint alone must not promote a helper, but an actual swapchain
            // identity may claim its own same-process output. Keep that HWND
            // (not its parent) as the ownership key.
            const bool child=(GetWindowLongPtrW(candidate,GWL_STYLE)&WS_CHILD)!=0;
            const HWND owner=GetWindow(candidate,GW_OWNER);
            if(child||owner){
                if(!identity)return false;
                const HWND host=child?GetAncestor(candidate,GA_ROOT):owner;
                DWORD hostPid=0;GetWindowThreadProcessId(host,&hostPid);
                if(!host||!IsWindow(host)||hostPid!=GetCurrentProcessId()||
                   (GetWindowLongPtrW(host,GWL_EXSTYLE)&WS_EX_TOOLWINDOW))return false;
            }
        }
        if(!claim)return true;
        for(auto& free:outputs)if(!free.used){free={candidate,identity,++serial,true};return true;}return false;
    }
    uint64_t Generation(HWND window,const void* chain){std::lock_guard lock(mutex);Prune();auto* e=Find(window,chain);return e&&(!e->chain||!chain||e->chain==chain)?e->generation:0;}
    uint64_t Advance(const void* chain){if(!chain)return 0;std::lock_guard lock(mutex);Prune();for(auto& e:outputs)if(e.used&&e.chain==chain)return e.generation=++serial;return 0;}
    void Retire(HWND window,const void* chain){std::lock_guard lock(mutex);auto* e=Find(window,chain);if(e&&e->chain==chain)*e={};}
};
}
