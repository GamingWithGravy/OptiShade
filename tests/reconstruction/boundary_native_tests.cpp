#include "NativeFgPresentBoundary.h"
#include <thread>
#include <vector>
#include <iostream>
using namespace optishade::native_fg_boundary;
static std::atomic<unsigned> originals{0},begins{0},ends{0};
__declspec(noinline) static HRESULT STDMETHODCALLTYPE Original(IDXGISwapChain*,UINT interval,UINT flags){
 originals.fetch_add(1);return interval==123?E_FAIL:S_OK;
}
static void Begin(IDXGISwapChain*){begins.fetch_add(1);}
static void End(IDXGISwapChain*,HRESULT){ends.fetch_add(1);}
int main(){
 provider=GetModuleHandleW(nullptr);before=Begin;after=End;
 if(!Attach(present,reinterpret_cast<void*>(Original),reinterpret_cast<void*>(Present)))return 1;
 using Fn=HRESULT(STDMETHODCALLTYPE*)(IDXGISwapChain*,UINT,UINT);
 Fn volatile target=Original;
 std::vector<std::thread> workers;
 for(unsigned t=0;t<4;++t)workers.emplace_back([&]{for(unsigned n=0;n<10000;++n)target(nullptr,0,0);});
 bool rejected=true;for(unsigned n=0;n<10000;++n)if(Remove())rejected=false;
 for(auto& worker:workers)worker.join();
 if(!rejected||originals!=40000||begins!=40000||ends!=40000)return 2;
 if(target(nullptr,123,DXGI_PRESENT_TEST)!=E_FAIL||originals!=40001||begins!=40000||ends!=40000)return 3;
 std::cout<<"Real pinned Detours x64 trampoline: 40,000 concurrent callback calls, live-removal rejection and HRESULT/test-present passthrough passed. No simulator.\n";
 return 0;
}
