#include "hooks/NativeFgStateQueryLock.h"
#include "NativeFgCapabilityCache.h"
#include <array>
#include <cstring>
#include <iostream>
#include <atomic>
#include <new>
#include <stdexcept>
#include <thread>
#include <chrono>
#ifdef _WIN32
#include <windows.h>
#else
#include <sys/mman.h>
#include <unistd.h>
#endif

// The runner extracts this exact callback body from the production hook file.
// This is an ABI/callback-body test, not a detour, driver or game-output test.
#include OPTISHADE_NATIVE_FG_CALLBACK_FILE

static unsigned checks=0;
#define CHECK(x) do { ++checks; if(!(x))throw std::runtime_error(std::string(#x)+" @"+std::to_string(__LINE__)); } while(false)
using namespace optishade::native_mfg;

struct StateV1 : sl::BaseStructure {
    StateV1():BaseStructure(sl::DLSSGState::s_structType,1){}
    uint64_t estimatedVRAMUsageInBytes{};
    sl::DLSSGStatus status{};
    uint32_t minWidthOrHeight{},numFramesActuallyPresented{};
};
struct StateV2 : sl::BaseStructure {
    StateV2():BaseStructure(sl::DLSSGState::s_structType,2){}
    uint64_t estimatedVRAMUsageInBytes{};
    sl::DLSSGStatus status{};
    uint32_t minWidthOrHeight{},numFramesActuallyPresented{},numFramesToGenerateMax{};
    sl::Boolean bReserved4{},bIsVsyncSupportAvailable{};
};
struct StateV3 : sl::BaseStructure {
    StateV3():BaseStructure(sl::DLSSGState::s_structType,3){}
    uint64_t estimatedVRAMUsageInBytes{};
    sl::DLSSGStatus status{};
    uint32_t minWidthOrHeight{},numFramesActuallyPresented{},numFramesToGenerateMax{};
    sl::Boolean bReserved4{},bIsVsyncSupportAvailable{};
    void* inputsProcessingCompletionFence{};
    uint64_t lastPresentInputsProcessingCompletionFenceValue{};
};
template<class T> struct Bounded {
    alignas(T) std::array<unsigned char,sizeof(T)+32> bytes;
    Bounded(){bytes.fill(0xa5);new(bytes.data())T;}
    T& value(){return *reinterpret_cast<T*>(bytes.data());}
    sl::DLSSGState& caller(){return *reinterpret_cast<sl::DLSSGState*>(bytes.data());}
    bool intact()const{for(size_t i=sizeof(T);i<bytes.size();++i)if(bytes[i]!=0xa5)return false;return true;}
};
template<class T> void GuardPageDummy(){
#ifdef _WIN32
    SYSTEM_INFO info{};GetSystemInfo(&info);const size_t page=info.dwPageSize;
    auto* memory=static_cast<unsigned char*>(VirtualAlloc(nullptr,page*2,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE));
    CHECK(memory);DWORD old=0;CHECK(VirtualProtect(memory+page,page,PAGE_NOACCESS,&old));
#else
    const auto page=static_cast<size_t>(sysconf(_SC_PAGESIZE));
    auto* memory=static_cast<unsigned char*>(mmap(nullptr,page*2,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0));
    CHECK(memory!=MAP_FAILED);CHECK(mprotect(memory+page,page,PROT_NONE)==0);
#endif
    auto* caller=new(memory+page-sizeof(T))T;
    CHECK(dummy_slDLSSGGetState(sl::ViewportHandle(7),*reinterpret_cast<sl::DLSSGState*>(caller),nullptr)==sl::Result::eOk);
    CHECK(caller->numFramesActuallyPresented==1);
#ifdef _WIN32
    CHECK(VirtualFree(memory,0,MEM_RELEASE));
#else
    CHECK(munmap(memory,page*2)==0);
#endif
}

template<class T> void GuardPageStateQuery(){
#ifdef _WIN32
    SYSTEM_INFO info{};GetSystemInfo(&info);const size_t page=info.dwPageSize;
    auto* memory=static_cast<unsigned char*>(VirtualAlloc(nullptr,page*2,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE));
    CHECK(memory);DWORD old=0;CHECK(VirtualProtect(memory+page,page,PAGE_NOACCESS,&old));
#else
    const auto page=static_cast<size_t>(sysconf(_SC_PAGESIZE));
    auto* memory=static_cast<unsigned char*>(mmap(nullptr,page*2,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0));
    CHECK(memory!=MAP_FAILED);CHECK(mprotect(memory+page,page,PROT_NONE)==0);
#endif
    auto* storage=new(memory+page-sizeof(T))T;
    auto& caller=*reinterpret_cast<sl::DLSSGState*>(storage);
    const sl::ViewportHandle view(7);sl::DLSSGOptions options{};int calls=0;StateQueryEvidence evidence;
    auto provider=[&](const sl::ViewportHandle& receivedView,sl::DLSSGState& receivedState,const sl::DLSSGOptions* receivedOptions){
        ++calls;CHECK(static_cast<uint32_t>(receivedView)==static_cast<uint32_t>(view)&&
                      &receivedState==&caller&&receivedOptions==&options);
        receivedState.numFramesActuallyPresented=2;return sl::Result::eOk;
    };
    CHECK(QueryNativeStateOnce(provider,true,view,caller,&options,evidence,4)==sl::Result::eOk);
    CHECK(calls==1&&storage->numFramesActuallyPresented==2&&evidence.stateKnown);
#ifdef _WIN32
    CHECK(VirtualFree(memory,0,MEM_RELEASE));
#else
    CHECK(munmap(memory,page*2)==0);
#endif
}

int main(){try{
    CapabilityCache capabilityCache;
    auto capability=capabilityCache.Read();
    CHECK(!capability.known&&capability.maximum==1&&!capability.dynamicKnown);
    CHECK(capabilityCache.Observe(5,7,true,true));
    capability=capabilityCache.Read();
    CHECK(capability.known&&capability.maximum==5&&capability.viewport==7&&capability.dynamicKnown&&capability.dynamicSupported);
    CHECK(!capabilityCache.Observe(0,7,true,true));
    capability=capabilityCache.Read();
    CHECK(!capability.known&&capability.maximum==1&&!capability.dynamicSupported);
    CHECK(capabilityCache.Observe(2,7,false,true));
    capability=capabilityCache.Read();
    CHECK(capability.known&&capability.maximum==2&&!capability.dynamicKnown&&!capability.dynamicSupported);
    capabilityCache.Reset();
    CHECK(!capabilityCache.Read().known);
    // Provider state can be observed before the output swapchain is created.
    // A process-lifetime cache preserves it for the later output object.
    CapabilityCache processCapabilities;
    CHECK(processCapabilities.Observe(4,7,true,true));
    const auto preOutputObservation=processCapabilities.Read();
    CHECK(preOutputObservation.known&&preOutputObservation.maximum==4&&preOutputObservation.dynamicSupported);
    // Swapchain recreation must not reset provider knowledge; only Streamline
    // reinitialization starts a new observation epoch.
    CHECK(processCapabilities.Read().known&&processCapabilities.Read().maximum==4);
    sl::DLSSGState menuState{};menuState.structVersion=4;menuState.next=reinterpret_cast<sl::BaseStructure*>(uintptr_t(0x1234));
    menuState.numFramesActuallyPresented=99;menuState.inputsProcessingCompletionFence=reinterpret_cast<void*>(uintptr_t(0x5678));
    menuState.lastPresentInputsProcessingCompletionFenceValue=42;
    CHECK(PopulateCachedCapabilityState(menuState,preOutputObservation,7));
    CHECK(menuState.numFramesToGenerateMax==4&&menuState.bIsDynamicMFGSupported==sl::eTrue);
    CHECK(menuState.numFramesActuallyPresented==0&&menuState.inputsProcessingCompletionFence==nullptr&&
          menuState.lastPresentInputsProcessingCompletionFenceValue==0&&menuState.next==reinterpret_cast<sl::BaseStructure*>(uintptr_t(0x1234)));
    CHECK(!PopulateCachedCapabilityState(menuState,preOutputObservation,8));
    sl::DLSSGState legacyMenuState{};legacyMenuState.structVersion=1;
    CHECK(!PopulateCachedCapabilityState(legacyMenuState,preOutputObservation,7));
    Bounded<StateV2> menuV2;
    menuV2.value().numFramesActuallyPresented=71;
    CHECK(PopulateCachedCapabilityState(menuV2.caller(),preOutputObservation,7));
    CHECK(menuV2.value().numFramesToGenerateMax==4&&menuV2.value().numFramesActuallyPresented==0&&menuV2.intact());
    Bounded<StateV3> menuV3;
    menuV3.value().numFramesActuallyPresented=72;
    menuV3.value().inputsProcessingCompletionFence=reinterpret_cast<void*>(uintptr_t(0x7777));
    menuV3.value().lastPresentInputsProcessingCompletionFenceValue=73;
    CHECK(PopulateCachedCapabilityState(menuV3.caller(),preOutputObservation,7));
    CHECK(menuV3.value().numFramesToGenerateMax==4&&menuV3.value().numFramesActuallyPresented==0&&
          menuV3.value().inputsProcessingCompletionFence==nullptr&&
          menuV3.value().lastPresentInputsProcessingCompletionFenceValue==0&&menuV3.intact());
    using namespace optishade::native_mfg;
    const sl::ViewportHandle view(7);
    // A real 56-byte v1 object, not an 88-byte v4 object with a changed version.
    static_assert(sizeof(void*)==8,"The production native DLSS-G hook is x64");
    static_assert(sizeof(StateV1)==56,"Verify the historical SDK allocation");
    Bounded<StateV1> one;
    sl::DLSSGState extension{};one.value().next=&extension;
    CHECK(dummy_slDLSSGGetState(view,one.caller(),nullptr)==sl::Result::eOk);
    CHECK(one.intact());CHECK(one.value().next==&extension);CHECK(one.value().structVersion==1);
    CHECK(one.value().numFramesActuallyPresented==1);
    GuardPageDummy<StateV1>();GuardPageDummy<StateV2>();GuardPageDummy<StateV3>();GuardPageDummy<sl::DLSSGState>();
    GuardPageStateQuery<StateV1>();GuardPageStateQuery<StateV2>();GuardPageStateQuery<StateV3>();GuardPageStateQuery<sl::DLSSGState>();
    for(unsigned version=1;version<=4;++version){
        sl::DLSSGState value{};value.structVersion=version;value.next=&extension;
        CHECK(dummy_slDLSSGGetState(view,value,nullptr)==sl::Result::eOk);
        CHECK(value.next==&extension&&value.structVersion==version&&value.structType==sl::DLSSGState::s_structType);
        if(version>=2)CHECK(value.numFramesToGenerateMax==1);
    }
    for(unsigned version:{0u,5u}){
        sl::DLSSGState value{};value.structVersion=version;auto before=value;
        CHECK(dummy_slDLSSGGetState(view,value,nullptr)==sl::Result::eErrorInvalidParameter);
        CHECK(std::memcmp(&value,&before,sizeof(value))==0);
    }
    sl::DLSSGState wrong{};wrong.structType.data1=0;auto savedWrong=wrong;
    CHECK(dummy_slDLSSGGetState(view,wrong,nullptr)==sl::Result::eErrorInvalidParameter);
    CHECK(std::memcmp(&wrong,&savedWrong,sizeof(wrong))==0);

    StateQueryEvidence evidence;int calls=0,successes=0;uint32_t pending=9;
    auto modernExactAbi=[&](const sl::ViewportHandle&,sl::DLSSGState& out,const sl::DLSSGOptions*){
        ++calls;CHECK(&out==&one.caller()&&out.structVersion==1);++successes;
        out.numFramesActuallyPresented=pending;pending=0;
        return sl::Result::eOk;
    };
    one.value().next=nullptr;
    CHECK(QueryNativeState(modernExactAbi,true,view,one.caller(),nullptr,evidence,4)==sl::Result::eOk);
    CHECK(calls==1&&successes==1&&!evidence.promoted&&evidence.maximum==0);
    CHECK(one.intact()&&one.value().structVersion==1&&one.value().numFramesActuallyPresented==9);
    CHECK(evidence.providerFramesPresented==9&&!evidence.dynamicKnown);
    StateV2 managedState;managedState.estimatedVRAMUsageInBytes=0x123456789ull;
    managedState.numFramesActuallyPresented=7;managedState.numFramesToGenerateMax=1;
    CHECK(ExposeProviderMfgMaximum(*reinterpret_cast<sl::DLSSGState*>(&managedState),5));
    CHECK(managedState.numFramesActuallyPresented==7&&managedState.estimatedVRAMUsageInBytes==0x123456789ull);
    CHECK(managedState.numFramesToGenerateMax==5);
    StateV1 managedV1;managedV1.numFramesActuallyPresented=8;
    CHECK(!ExposeProviderMfgMaximum(*reinterpret_cast<sl::DLSSGState*>(&managedV1),5));
    CHECK(managedV1.numFramesActuallyPresented==8);
    calls=successes=0;
    auto old=[&](const sl::ViewportHandle&,sl::DLSSGState& out,const sl::DLSSGOptions*){
        ++calls;if(out.structVersion!=1)return sl::Result::eErrorUnsupportedInterface;
        ++successes;out.numFramesActuallyPresented=4;return sl::Result::eOk;
    };
    CHECK(QueryNativeState(old,true,view,one.caller(),nullptr,evidence,4)==sl::Result::eOk);
    CHECK(calls==1&&successes==1&&!evidence.promoted&&evidence.maximum==0&&one.intact());
    CHECK(one.value().numFramesActuallyPresented==4&&!evidence.dynamicKnown);
    calls=0;auto externalAbiReject=[&](const sl::ViewportHandle&,sl::DLSSGState& out,const sl::DLSSGOptions*){
        ++calls;CHECK(&out==&one.caller()&&out.structVersion==1&&out.next==nullptr);
        return sl::Result::eErrorUnsupportedInterface;
    };
    CHECK(QueryNativeState(externalAbiReject,true,view,one.caller(),nullptr,evidence,1)==sl::Result::eErrorUnsupportedInterface);
    CHECK(calls==1&&!evidence.promoted&&!evidence.stateKnown&&one.intact());
    calls=0;auto externalExactAbi=[&](const sl::ViewportHandle&,sl::DLSSGState& out,const sl::DLSSGOptions*){
        ++calls;CHECK(&out==&one.caller()&&out.structVersion==1&&out.next==nullptr);
        out.numFramesActuallyPresented=6;return sl::Result::eOk;
    };
    CHECK(QueryNativeState(externalExactAbi,true,view,one.caller(),nullptr,evidence,1)==sl::Result::eOk);
    CHECK(calls==1&&!evidence.promoted&&evidence.stateKnown&&evidence.providerFramesPresented==6&&one.intact());
    for(auto error:{sl::Result::eErrorDeviceNotCreated,sl::Result::eErrorFeatureMissing}){
        calls=0;auto failing=[&](const sl::ViewportHandle&,sl::DLSSGState&,const sl::DLSSGOptions*){++calls;return error;};
        CHECK(QueryNativeState(failing,true,view,one.caller(),nullptr,evidence,4)==error);
        CHECK(calls==1&&!evidence.stateKnown&&evidence.maximum==0&&one.intact());
    }
    one.value().estimatedVRAMUsageInBytes=1234;one.value().numFramesActuallyPresented=7;calls=0;
    auto partialFailure=[&](const sl::ViewportHandle&,sl::DLSSGState& out,const sl::DLSSGOptions*){
        ++calls;out.estimatedVRAMUsageInBytes=9999;out.numFramesActuallyPresented=99;
        out.structVersion=4;out.next=nullptr;
        return sl::Result::eErrorExceptionHandler;
    };
    CHECK(QueryNativeState(partialFailure,true,view,one.caller(),nullptr,evidence,1)==sl::Result::eErrorExceptionHandler);
    CHECK(calls==1&&one.intact()&&one.value().estimatedVRAMUsageInBytes==1234&&
          one.value().numFramesActuallyPresented==7);
    one.value().next=&extension;calls=0;
    auto extended=[&](const sl::ViewportHandle&,sl::DLSSGState& out,const sl::DLSSGOptions*){
        ++calls;CHECK(&out==&one.caller()&&out.next==&extension&&out.structVersion==1);
        out.numFramesActuallyPresented=5;out.next=nullptr;out.structVersion=4;return sl::Result::eOk;
    };
    CHECK(QueryNativeState(extended,true,view,one.caller(),nullptr,evidence,4)==sl::Result::eOk);
    CHECK(calls==1&&one.intact()&&one.value().next==&extension&&one.value().structVersion==1);
    CHECK(evidence.stateKnown&&evidence.maximum==0&&!evidence.dynamicKnown);
    for(unsigned version:{2u,3u,4u,5u}){
        sl::DLSSGState value{};value.structVersion=version;value.next=&extension;calls=0;
        auto passthrough=[&](const sl::ViewportHandle&,sl::DLSSGState& out,const sl::DLSSGOptions*){
            ++calls;CHECK(&out==&value&&out.structVersion==version&&out.next==&extension);
            if(version<=4){out.numFramesToGenerateMax=3;out.numFramesActuallyPresented=8;}
            return sl::Result::eOk;
        };
        CHECK(QueryNativeState(passthrough,true,view,value,nullptr,evidence,4)==sl::Result::eOk);
        CHECK(calls==1&&!evidence.promoted&&value.structVersion==version&&value.next==&extension);
        CHECK(evidence.stateKnown==(version<=4));
    }
    calls=0;auto unknown=[&](const sl::ViewportHandle&,sl::DLSSGState& out,const sl::DLSSGOptions*){++calls;CHECK(&out==&wrong);return sl::Result::eErrorInvalidParameter;};
    CHECK(QueryNativeState(unknown,true,view,wrong,nullptr,evidence,4)==sl::Result::eErrorInvalidParameter);
    CHECK(calls==1&&!evidence.stateKnown&&std::memcmp(&wrong,&savedWrong,sizeof(wrong))==0);
    std::atomic<int> activeQueries{0},maxConcurrentQueries{0};
    auto concurrentProvider=[&](const sl::ViewportHandle&,sl::DLSSGState&,const sl::DLSSGOptions*){
        const int active=++activeQueries;int observed=maxConcurrentQueries.load();
        while(active>observed&&!maxConcurrentQueries.compare_exchange_weak(observed,active)){}
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        --activeQueries;return sl::Result::eErrorFeatureMissing;
    };
    std::atomic<bool> threadedQueriesPassed{true};
    auto callRouteA=[&](const sl::ViewportHandle& v,sl::DLSSGState& state,const sl::DLSSGOptions* options){return concurrentProvider(v,state,options);};
    auto queryOnThread=[&](auto& route){sl::DLSSGState state{};StateQueryEvidence threadEvidence;
        if(QueryNativeStateOnce(route,true,view,state,nullptr,threadEvidence,4)!=sl::Result::eErrorFeatureMissing)
            threadedQueriesPassed=false;};
    std::thread firstQuery([&]{queryOnThread(callRouteA);});
    // The wrapper must not invent synchronization that cannot include the
    // provider's internal Present thread; it forwards on each caller thread.
    sl::DLSSGState concurrentState{};
    std::thread concurrentSetOptions([&]{
        if(InvokeProviderCallDirect([&]{return concurrentProvider(view,concurrentState,nullptr);})!=sl::Result::eErrorFeatureMissing)
            threadedQueriesPassed=false;});
    firstQuery.join();concurrentSetOptions.join();
    CHECK(threadedQueriesPassed&&maxConcurrentQueries==2);
    bool nested=false;int nestedCalls=0;
    auto nestedProvider=[&](const sl::ViewportHandle&,sl::DLSSGState&,const sl::DLSSGOptions*){
        ++nestedCalls;return sl::Result::eErrorFeatureMissing;
    };
    auto hookedProvider=[&](const sl::ViewportHandle&,sl::DLSSGState&,const sl::DLSSGOptions*){
        if(!nested){nested=true;sl::DLSSGState innerState{};StateQueryEvidence innerEvidence;
            QueryNativeState(nestedProvider,true,view,innerState,nullptr,innerEvidence,4);}
        return sl::Result::eErrorFeatureMissing;
    };
    sl::DLSSGState hookedState{};StateQueryEvidence hookedEvidence;
    CHECK(QueryNativeStateOnce(hookedProvider,true,view,hookedState,nullptr,hookedEvidence,4)==sl::Result::eErrorFeatureMissing);
    CHECK(nested&&nestedCalls==1);
    std::cout<<checks<<" native FG state ABI/callback-body checks passed; callbacks remain synchronous and un-serialized; no driver/game output tested\n";return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
