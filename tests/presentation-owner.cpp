#include "../shared/PresentationOwner.h"
#include <cassert>
int main(){
    optishade::PresentationOwner owner;
    HWND main=CreateWindowExW(0,L"STATIC",L"main",WS_OVERLAPPED,0,0,800,600,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
    HWND secondary=CreateWindowExW(0,L"STATIC",L"secondary",WS_OVERLAPPED,0,0,400,300,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
    HWND child=CreateWindowExW(0,L"STATIC",L"child",WS_CHILD,0,0,100,100,main,nullptr,GetModuleHandleW(nullptr),nullptr);
    assert(main&&secondary&&child);
    assert(owner.Accept(nullptr,true));
    assert(!owner.Accept(child,true));
    assert(owner.Accept(main,true));
    for(int i=0;i<100;i++){assert(!owner.Accept(secondary,true));assert(!owner.Accept(secondary));assert(owner.Accept(main));}
    DestroyWindow(main);
    assert(owner.Accept(secondary,true));
    assert(owner.Accept(nullptr));
    DestroyWindow(secondary);
}
