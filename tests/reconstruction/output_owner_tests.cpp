#include <Windows.h>
#include <iostream>
#include <stdexcept>
#include "PresentationOwner.h"
int main(){
 HWND a=CreateWindowExW(0,L"STATIC",L"A",WS_OVERLAPPED,0,0,100,100,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
 HWND b=CreateWindowExW(0,L"STATIC",L"B",WS_OVERLAPPED,0,0,100,100,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
 auto require=[](bool x){if(!x)throw std::runtime_error("Output ownership failure");};
 try{require(a&&b);optishade::PresentationOwner owner;int ca,cb,other;
 require(owner.Accept(a,true,&ca));require(owner.Accept(b,true,&cb));
 const auto ga=owner.Generation(a,&ca),gb=owner.Generation(b,&cb);require(ga&&gb);
 require(!owner.Accept(a,true,&other));require(owner.Advance(&ca)>ga);require(owner.Generation(b,&cb)==gb);
 owner.Retire(a,&other);require(!owner.Accept(a,true,&other));owner.Retire(a,&ca);require(owner.Accept(a,true,&other));require(owner.Generation(b,&cb)==gb);
 require(owner.Accept(nullptr,true,&ca));require(owner.Accept(nullptr,true,&cb));require(owner.Generation(nullptr,&ca)!=owner.Generation(nullptr,&cb));
 DestroyWindow(a);DestroyWindow(b);std::cout<<"Independent native windows/windowless outputs: claim, conflict, generation and retirement passed.\n";return 0;
 }catch(const std::exception& e){DestroyWindow(a);DestroyWindow(b);std::cerr<<e.what();return 1;}}
#pragma comment(lib,"user32.lib")
