#pragma once
#include <Windows.h>
#include <atomic>
namespace optishade {
class PresentationOwner {
    std::atomic<HWND> window{nullptr};
public:
    bool Accept(HWND candidate,bool claim=false){
        if(!candidate)return true; // Preserve windowless/VR paths.
        HWND owner=window.load();
        if(owner&&!IsWindow(owner)){window.compare_exchange_strong(owner,nullptr);owner=window.load();}
        if(!owner&&claim){
            if(GetWindowLongPtrW(candidate,GWL_STYLE)&WS_CHILD)return false;
            HWND empty=nullptr;window.compare_exchange_strong(empty,candidate);owner=window.load();
        }
        return !owner||owner==candidate;
    }
};
}
