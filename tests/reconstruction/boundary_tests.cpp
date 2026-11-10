#include "NativeFgPresentBoundary.h"
#include <iostream>
#include <stdexcept>
#include <thread>
#include <chrono>
#define CHECK(x) do {if(!(x))throw std::runtime_error(#x);} while(0)
using namespace optishade::native_fg_boundary;
static int begins=0,ends=0,inspects=0,presents=0;
static std::atomic<bool> block{false},entered{false};
static HRESULT STDMETHODCALLTYPE Original(IDXGISwapChain*,UINT,UINT){++presents;return S_OK;}
static void Begin(IDXGISwapChain*){++begins;entered=true;while(block.load())std::this_thread::yield();}
static void End(IDXGISwapChain*,HRESULT){++ends;}
static void InspectFrame(IDXGISwapChain*,UINT,UINT){++inspects;}
int main(){try{
 CHECK(Remove());provider=GetModuleHandleW(nullptr);before=Begin;after=End;inspect=InspectFrame;
 atCommit=[] {
  CHECK(pendingTrampoline==&present.call); // Must not be a stack-local candidate.
  CHECK(present.call!=nullptr);CHECK(Present(nullptr,0,0)==S_OK);
 };
 CHECK(Attach(present,reinterpret_cast<void*>(Original),reinterpret_cast<void*>(Present)));
 atCommit=nullptr;CHECK(begins==1&&ends==1&&inspects==1&&presents==1);
 CHECK(!Remove());CHECK(present.call!=nullptr);CHECK(provider!=nullptr);
 Install(provider,nullptr,nullptr);CHECK(before==Begin&&after==End&&inspect==InspectFrame);
 CHECK(Present(nullptr,0,DXGI_PRESENT_TEST)==S_OK);CHECK(begins==1&&presents==2);
 CHECK(Present(nullptr,0,0)==S_OK);CHECK(begins==2&&ends==2&&inspects==2&&presents==3);
 entered=false;block=true;std::thread active([]{Present(nullptr,0,0);});
 const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(2);
 while(!entered&&std::chrono::steady_clock::now()<deadline)std::this_thread::yield();
 const bool observed=entered.load();const bool refused=!Remove();block=false;active.join();
 CHECK(observed&&refused);CHECK(begins==3&&ends==3&&presents==4);
 std::cout<<"Boundary transaction-double: publication, immutable callbacks, live-detach rejection and passthrough passed.\n";return 0;
 }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
