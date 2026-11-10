#include <sl.h>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <map>
#include <mutex>
#include <set>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include "../../Beta/shared/ExternalFgTelemetry.h"

// Only platform/provider boundaries are fake. The runner includes the exact
// production installer, cleanup, readiness and tag callback method bodies.
using PVOID=void*;using HMODULE=void*;using HANDLE=void*;using LPCWSTR=const wchar_t*;
using LONG=long;using HRESULT=long;using UINT=unsigned;using DWORD=unsigned long;
using FARPROC=void(*)();
constexpr LONG NO_ERROR=0,ERROR_NOT_ENOUGH_MEMORY=8;
constexpr unsigned MAX_PATH=260,GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS=4,GET_MODULE_HANDLE_EX_FLAG_PIN=1;
constexpr unsigned D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE=64,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE=128,D3D12_RESOURCE_STATE_UNORDERED_ACCESS=8;
#define SUCCEEDED(x) ((x)>=0)
#define IID_PPV_ARGS(x) (x)
#define LOG_FUNC(...) ((void)0)
#define LOG_WARN(...) ((void)0)
#define LOG_TRACE(...) ((void)0)
#define LOG_ERROR(...) ((void)0)
#define LOG_INFO(...) ((void)0)
#define LOG_DEBUG(...) ((void)0)
#define OPTISHADE_VERSION_TEXT L"test"
using BufferType=uint64_t;
namespace magic_enum {template<class T> const char* enum_name(T){return "fixture";}}

static unsigned checks=0;
#define CHECK(x) do{++checks;if(!(x))throw std::runtime_error(std::string(#x)+" @"+std::to_string(__LINE__));}while(false)
struct ID3D12Device;
struct IUnknown {
    ID3D12Device* d3d12{};
    HRESULT QueryInterface(ID3D12Device** out){*out=d3d12;return d3d12?0:-1;}
};
struct ID3D12Device:IUnknown{ID3D12Device(){d3d12=this;}};
struct ID3D12GraphicsCommandList{};
struct DXGI_SWAP_CHAIN_DESC{int Windowed=1;unsigned Flags=0;};
struct IDXGISwapChain{HRESULT GetDesc(DXGI_SWAP_CHAIN_DESC*){return 0;}};
namespace Microsoft::WRL {
template<class T> struct ComPtr {
    T* value{};T** operator&(){return &value;}T* Get()const{return value;}
};
}

enum class FGInput{NoFG,DLSSG,NvngxFG};
enum class FGOutput{NoFG,DLSSG};
enum class GameQuirk{IgnoreTagsWithoutHudlessForFG,CyberpunkHudlessState};
struct Quirks{bool operator[](GameQuirk)const{return false;}bool operator&(GameQuirk)const{return false;}};
struct version_t{unsigned major=2,minor=14,patch=1;};
struct State {
    bool externalFrameGeneration=true;
    FGInput activeFgInput=FGInput::NoFG;FGOutput activeFgOutput=FGOutput::NoFG;
    Quirks gameQuirks;version_t streamlineVersion;
    struct Inputs{template<class... T>void reportResource(T...){}}slFGInputs;
    static State& Instance(){static State value;return value;}
    static inline bool checksDisabled=false;
    static int GetOwner(){return 1;}
    static void DisableChecks(int,const char*){checksDisabled=true;}
    static void EnableChecks(int){checksDisabled=false;}
};
static bool routeObserver=true,nativeObserver=true,pinSucceeds=true,canRemoveBoundary=true;
static unsigned moduleVersion=2,boundaryInstalls=0,beginFailure=0,updateFailure=0,commitFailure=0,processLifetimePins=0;
static std::string failAttach,failDetach;
static std::set<std::string> absentExports;
static std::map<std::string,PVOID> exports;
static std::vector<std::string> attachNames,detachNames;
struct Patch{PVOID* slot;PVOID hook;PVOID original;bool remove=false;};
static std::vector<Patch> pending;
static std::map<PVOID*,Patch> installed;
static bool transactionActive=false;
static std::atomic<bool> transactionGate{false};
static std::atomic<unsigned> overlappingTransactions{0};
static unsigned invalidDetaches=0;
static std::string ExportName(PVOID pointer){
    for(const auto& entry:exports)if(entry.second==pointer)return entry.first;
    return "unknown";
}
static void* GetCurrentThread(){return nullptr;}
static int CloseHandle(HANDLE){return 1;}
static LONG DetourTransactionBegin(){
    if(beginFailure){--beginFailure;return 100;}
    bool expected=false;
    if(!transactionGate.compare_exchange_strong(expected,true,std::memory_order_acq_rel)){
        overlappingTransactions.fetch_add(1,std::memory_order_relaxed);return 106;
    }
    CHECK(!transactionActive);transactionActive=true;pending.clear();return 0;
}
static LONG DetourUpdateThread(void*){if(updateFailure){--updateFailure;return 101;}return 0;}
template<class H> static LONG DetourAttach(PVOID* slot,H replacement){
    CHECK(transactionActive);auto name=ExportName(*slot);attachNames.push_back(name);
    if(name==failAttach)return 102;
    pending.push_back({slot,reinterpret_cast<PVOID>(replacement),*slot,false});return 0;
}
template<class H> static LONG DetourDetach(PVOID* slot,H replacement){
    CHECK(transactionActive);auto found=installed.find(slot);
    if(found==installed.end()||found->second.hook!=reinterpret_cast<PVOID>(replacement)){
        ++invalidDetaches;return 103;
    }
    const auto name=ExportName(found->second.original);detachNames.push_back(name);
    if(name==failDetach)return 104;
    auto operation=found->second;operation.remove=true;pending.push_back(operation);return 0;
}
static LONG DetourTransactionAbort(){pending.clear();transactionActive=false;transactionGate.store(false,std::memory_order_release);return 0;}
static LONG DetourTransactionCommit(){
    CHECK(transactionActive);transactionActive=false;
    if(commitFailure){--commitFailure;pending.clear();transactionGate.store(false,std::memory_order_release);return 105;}
    for(const auto& patch:pending){
        if(patch.remove){*patch.slot=patch.original;installed.erase(patch.slot);}
        else{installed[patch.slot]=patch;*patch.slot=reinterpret_cast<PVOID>(reinterpret_cast<uintptr_t>(patch.original)+0x100000);}
    }
    pending.clear();transactionGate.store(false,std::memory_order_release);return 0;
}
static uint64_t GetTickCount64(){return 40000;}
static DWORD GetCurrentThreadId(){return 23;}
static DWORD GetModuleFileNameA(HMODULE,char* out,DWORD){std::strcpy(out,"sl.interposer.dll");return 17;}
static std::wstring GetModulePath(HMODULE){return L"sl.interposer.dll";}
static std::wstring string_to_wstring(const char* value){return std::filesystem::path(value).wstring();}
static bool GetModuleHandleExW(unsigned flags,LPCWSTR pointer,HMODULE* out){if(flags&GET_MODULE_HANDLE_EX_FLAG_PIN)++processLifetimePins;*out=const_cast<wchar_t*>(pointer);return pinSucceeds;}
namespace Util {
static std::filesystem::path ExePath(){return "FlightSimulator2024.exe";}
static void GetFileVersion(const std::wstring&,version_t* value){value->major=moduleVersion;}
}
struct KernelBaseProxy {
    static FARPROC Resolve(HMODULE,const char* name){
        if(absentExports.count(name))return nullptr;
        auto it=exports.find(name);
        if(it==exports.end())it=exports.emplace(name,reinterpret_cast<void*>(0x1000+exports.size()*0x100)).first;
        return reinterpret_cast<FARPROC>(it->second);
    }
    static auto GetProcAddress_(){return &Resolve;}
};
namespace sl1 {bool slInit(...);void slSetTag(...);bool slSetConstants(...);bool slEvaluateFeature(...);}
static bool IsSL1AndFGActive(){return State::Instance().activeFgInput==FGInput::DLSSG;}
namespace optishade {
namespace route {static bool ExternalFgObserver(){return routeObserver;}}
namespace taa {
static bool NativeMsfsObserver(const std::wstring&,const wchar_t*){return nativeObserver;}
static bool AttachTaaTags(bool fg,bool native,bool passive){return !passive&&(fg||native);}
static std::array<sl::ResourceTag,2> ReplacementInputTags(const sl::ResourceTag*){return {};}
}
namespace external_fg {template<class F> bool Install(bool observer,bool route,F callback){return observer&&route&&callback();}}
// Production skips modules owned by the XP12 provider bridge; no XP12 provider here.
namespace xp12_provider {template<class T> static bool Owned(T){return false;}}
namespace native_fg_boundary {
static std::atomic<bool> ready{false};
static bool Remove(){return canRemoveBoundary;}
template<class... T> void Install(HMODULE,T...){++boundaryInstalls;}
}
namespace session {
struct Store {unsigned writes{};void Put(std::initializer_list<std::pair<std::string,std::string>>){++writes;}};
static Store& State(){static Store value;return value;}
}
namespace actual_gpu {static int Metadata(ID3D12Device*,int){return 1;}}
namespace runtime_render {
struct Store {int device{};void StreamlineDevice(int value){device=value;}};
static Store& State(){static Store value;return value;}
}
namespace mfg::source {
static unsigned presents=0,devices=0,acceptedTags=0;
static void ObservePresent(IDXGISwapChain*){++presents;}
static void ObserveDevice(IUnknown*,bool){++devices;}
static void ObserveAcceptedTags(uint32_t,const void*,uint32_t,bool accepted){if(accepted)++acceptedTags;}
}
}
struct IdentifyGpu{static int getGpuForDevice(ID3D12Device*){return 1;}};
namespace DlssNr {
static unsigned invalidates=0,legacyTags=0,frameTags=0,prepare=0,providerPrepare=0,commits=0,presentResults=0,acceptedReplacements=0;
static bool replacementReady=false,lastLegacy=false;
static unsigned resets=0;static IDXGISwapChain* providerSwap=nullptr;
static void TaaFgReset(){++resets;replacementReady=false;}
static void TaaFgInvalidate(uint32_t){++invalidates;}
static void TaaFgTraceStop(){}
static void TaaFgLegacyTags(ID3D12GraphicsCommandList*,const sl::ResourceTag*,uint32_t,uint32_t){++legacyTags;}
static void TaaFgBeforeTags(ID3D12GraphicsCommandList*,const sl::ResourceTag*,uint32_t,uint32_t,uint32_t){++frameTags;}
static bool TaaFgPrepare(uint32_t,bool legacy,sl::ResourceTag*,uint32_t&,uint32_t&){++prepare;lastLegacy=legacy;return replacementReady;}
static bool TaaFgProviderPrepare(IDXGISwapChain* swap,sl::ResourceTag*,uint32_t&,uint32_t&){++providerPrepare;if(providerSwap)return false;providerSwap=swap;return replacementReady;}
static void TaaFgTagsAccepted(uint32_t,uint32_t,bool accepted){if(accepted)++acceptedReplacements;}
static void TaaFgProviderCommit(IDXGISwapChain*){++commits;}
static void TaaFgPresentResult(IDXGISwapChain* swap,HRESULT){++presentResults;if(providerSwap==swap)providerSwap=nullptr;}
}

static std::atomic<bool> passiveInterposer{false};
class StreamlineHooks {
public:
    static void hookInterposer(HMODULE);static void unhookInterposer();static bool isInterposerHooked();
    static void clearInterposerPointers();
    static void ExternalPrepare(const sl::FrameToken&);
    static void NativeProviderPresentBegin(IDXGISwapChain*);static void NativeProviderPresentEnd(IDXGISwapChain*,HRESULT);
    static sl::Result hkslSetTag(const sl::ViewportHandle&,const sl::ResourceTag*,uint32_t,sl::CommandBuffer*);
    static sl::Result hkslSetTagForFrame(const sl::FrameToken&,const sl::ViewportHandle&,const sl::ResourceTag*,uint32_t,sl::CommandBuffer*);
    static sl::Result hkslSetD3DDevice(void*);
    static inline sl::RenderAPI renderApi=sl::RenderAPI::eCount;
    static inline HMODULE hookedInterposerModule=nullptr;
    static inline bool nativeFrameTokenHooked=false;
#define PTR(name) static inline decltype(&name) o_##name=nullptr
    PTR(slInit);PTR(slSetTag);PTR(slSetTagForFrame);PTR(slEvaluateFeature);
    PTR(slAllocateResources);PTR(slFreeResources);PTR(slSetConstants);
    PTR(slGetNativeInterface);PTR(slSetD3DDevice);PTR(slGetNewFrameToken);
    PTR(slIsFeatureSupported);PTR(slIsFeatureLoaded);PTR(slGetFeatureRequirements);
    PTR(slGetFeatureVersion);PTR(slGetFeatureFunction);PTR(slSetFeatureLoaded);
#undef PTR
    static inline decltype(&sl1::slInit) o_slInit_sl1=nullptr;
    static inline decltype(&sl1::slSetTag) o_slSetTag_sl1=nullptr;
    static inline decltype(&sl1::slSetConstants) o_slSetConstants_interposer_sl1=nullptr;
    static inline decltype(&sl1::slEvaluateFeature) o_slEvaluateFeature_sl1=nullptr;
    static inline void(*o_logCallback)()=nullptr;static inline void(*o_logCallback_sl1)()=nullptr;
#define HANDLER(name) static sl::Result name(...){return sl::Result::eOk;}
    HANDLER(hkslInit) HANDLER(hkslEvaluateFeature) HANDLER(hkslSetConstants)
    HANDLER(hkslGetNewFrameToken) HANDLER(hkslGetFeatureFunction)
    HANDLER(hkslIsFeatureSupported) HANDLER(hkslIsFeatureLoaded) HANDLER(hkslGetFeatureRequirements)
    HANDLER(hkslGetFeatureVersion) HANDLER(hkslSetFeatureLoaded)
    HANDLER(hkslAllocateResources) HANDLER(hkslFreeResources)
    HANDLER(hkslInit_sl1) HANDLER(hkslSetTag_sl1) HANDLER(hkslSetConstants_sl1) HANDLER(hkslEvaluateFeature_sl1)
#undef HANDLER
};

#include OPTISHADE_INIT_PRODUCTION_FILE

struct Token:sl::FrameToken{operator uint32_t()const override{return 17;}};
static sl::Result nextTagResult=sl::Result::eOk,nextDeviceResult=sl::Result::eOk;
static const void* expectedTags=nullptr;static unsigned nativeTagCalls=0,wrongPackets=0,deviceCalls=0;
static sl::Result NativeTag(const sl::ViewportHandle&,const sl::ResourceTag* tags,uint32_t,sl::CommandBuffer*){
    ++nativeTagCalls;if(expectedTags&&expectedTags!=tags)++wrongPackets;return nextTagResult;
}
static sl::Result NativeFrameTag(const sl::FrameToken&,const sl::ViewportHandle& view,const sl::ResourceTag* tags,uint32_t count,sl::CommandBuffer* commands){return NativeTag(view,tags,count,commands);}
static sl::Result NativeDevice(void*){++deviceCalls;return nextDeviceResult;}
static HMODULE Module(){return reinterpret_cast<HMODULE>(0xA000);}
static bool Attached(const char* name){for(const auto& entry:installed)if(ExportName(entry.second.original)==name)return true;return false;}
static void Reset(){
    installed.clear();pending.clear();transactionActive=false;transactionGate.store(false,std::memory_order_release);overlappingTransactions.store(0,std::memory_order_relaxed);exports.clear();absentExports.clear();attachNames.clear();detachNames.clear();
    beginFailure=updateFailure=commitFailure=0;failAttach.clear();failDetach.clear();invalidDetaches=0;
    State::Instance()=State{};State::checksDisabled=false;routeObserver=nativeObserver=pinSucceeds=canRemoveBoundary=true;
    moduleVersion=2;boundaryInstalls=0;processLifetimePins=0;passiveInterposer=false;
#if OPTISHADE_INIT_TRACKED
    StreamlineHooks::clearInterposerPointers();
#else
    StreamlineHooks::hookedInterposerModule=nullptr;StreamlineHooks::renderApi=sl::RenderAPI::eCount;
    g_frameBasedResourceTagging=false;featureFunctionHooked=false;
#define ZERO(name) StreamlineHooks::o_##name=nullptr
    ZERO(slInit);ZERO(slSetTag);ZERO(slSetTagForFrame);ZERO(slEvaluateFeature);ZERO(slAllocateResources);ZERO(slFreeResources);
    ZERO(slSetConstants);ZERO(slGetNativeInterface);ZERO(slSetD3DDevice);ZERO(slGetNewFrameToken);ZERO(slIsFeatureSupported);
    ZERO(slIsFeatureLoaded);ZERO(slGetFeatureRequirements);ZERO(slGetFeatureVersion);ZERO(slGetFeatureFunction);ZERO(slSetFeatureLoaded);
    ZERO(slInit_sl1);ZERO(slSetTag_sl1);ZERO(slSetConstants_interposer_sl1);ZERO(slEvaluateFeature_sl1);
#undef ZERO
#endif
    nextTagResult=nextDeviceResult=sl::Result::eOk;expectedTags=nullptr;nativeTagCalls=wrongPackets=deviceCalls=0;
    DlssNr::invalidates=DlssNr::legacyTags=DlssNr::frameTags=DlssNr::prepare=DlssNr::providerPrepare=DlssNr::commits=DlssNr::presentResults=DlssNr::acceptedReplacements=0;
    DlssNr::replacementReady=false;optishade::native_fg_boundary::ready=false;
    DlssNr::resets=0;DlssNr::providerSwap=nullptr;
    optishade::session::State().writes=0;optishade::runtime_render::State().device=0;
    optishade::mfg::source::presents=optishade::mfg::source::devices=optishade::mfg::source::acceptedTags=0;
}
static void DataCallbacks(){
    StreamlineHooks::o_slSetTag=&NativeTag;StreamlineHooks::o_slSetTagForFrame=&NativeFrameTag;StreamlineHooks::o_slSetD3DDevice=&NativeDevice;
}
static void External(){
    Reset();StreamlineHooks::hookInterposer(Module());
    CHECK(StreamlineHooks::isInterposerHooked());CHECK(!State::checksDisabled);CHECK(processLifetimePins==1);
    CHECK(!Attached("slInit"));CHECK(StreamlineHooks::o_slInit==nullptr);
    // Observer-only mode keeps feature lookup observation but leaves device
    // selection native: detouring slSetD3DDevice caused recursive re-entry on
    // MSFS R250 and a startup stack overflow.
    CHECK(!Attached("slSetD3DDevice"));
    CHECK(Attached("slGetFeatureFunction"));
    for(const auto* entry:{"slSetTag","slSetTagForFrame","slSetConstants","slGetNewFrameToken"})CHECK(Attached(entry));
    for(const auto* entry:{"slEvaluateFeature","slIsFeatureSupported","slIsFeatureLoaded","slGetFeatureRequirements","slGetFeatureVersion","slAllocateResources","slFreeResources"})CHECK(!Attached(entry));
    CHECK(boundaryInstalls==1);const auto count=installed.size();
    StreamlineHooks::hookInterposer(Module());CHECK(installed.size()==count);CHECK(boundaryInstalls==1);
    StreamlineHooks::unhookInterposer();CHECK(installed.size()==count);CHECK(invalidDetaches==0);CHECK(StreamlineHooks::isInterposerHooked());
    // A missing slInit export cannot block external device/data observation.
    Reset();absentExports.insert("slInit");StreamlineHooks::hookInterposer(Module());CHECK(StreamlineHooks::isInterposerHooked());CHECK(Attached("slGetFeatureFunction"));CHECK(!Attached("slSetD3DDevice"));
    Reset();routeObserver=false;StreamlineHooks::hookInterposer(Module());CHECK(installed.size()==1);CHECK(!Attached("slInit"));CHECK(!Attached("slSetD3DDevice"));CHECK(Attached("slGetFeatureFunction"));CHECK(boundaryInstalls==0);
    StreamlineHooks::unhookInterposer();CHECK(installed.size()==1);CHECK(StreamlineHooks::isInterposerHooked());
    Reset();pinSucceeds=false;StreamlineHooks::hookInterposer(Module());CHECK(installed.empty());CHECK(!StreamlineHooks::isInterposerHooked());CHECK(!State::checksDisabled);CHECK(StreamlineHooks::hookedInterposerModule==nullptr);
}
static void Lifecycle(){
    Reset();absentExports.insert("slGetFeatureFunction");StreamlineHooks::hookInterposer(Module());CHECK(!StreamlineHooks::isInterposerHooked());CHECK(installed.empty());CHECK(!State::checksDisabled);CHECK(StreamlineHooks::hookedInterposerModule==nullptr);
    Reset();absentExports.insert("slSetD3DDevice");StreamlineHooks::hookInterposer(Module());CHECK(StreamlineHooks::isInterposerHooked());CHECK(Attached("slGetFeatureFunction"));CHECK(!Attached("slSetD3DDevice"));
    Reset();StreamlineHooks::hookInterposer(Module());CHECK(StreamlineHooks::isInterposerHooked());
    Reset();moduleVersion=1;StreamlineHooks::hookInterposer(Module());CHECK(!StreamlineHooks::isInterposerHooked());CHECK(!State::checksDisabled);CHECK(StreamlineHooks::hookedInterposerModule==nullptr);
    moduleVersion=2;StreamlineHooks::hookInterposer(Module());CHECK(StreamlineHooks::isInterposerHooked());
    for(unsigned failure=0;failure<4;++failure){
        Reset();if(failure==0)beginFailure=1;else if(failure==1)updateFailure=1;else if(failure==2)failAttach="slSetTagForFrame";else commitFailure=1;
        StreamlineHooks::hookInterposer(Module());CHECK(installed.empty());CHECK(!transactionActive);CHECK(!StreamlineHooks::isInterposerHooked());CHECK(!State::checksDisabled);CHECK(boundaryInstalls==0);CHECK(StreamlineHooks::o_slSetD3DDevice==nullptr);
        failAttach.clear();StreamlineHooks::hookInterposer(Module());CHECK(StreamlineHooks::isInterposerHooked());CHECK(Attached("slSetTagForFrame"));
    }
    Reset();nativeObserver=false;StreamlineHooks::hookInterposer(Module());CHECK(installed.size()==1);CHECK(Attached("slGetFeatureFunction"));CHECK(!Attached("slSetD3DDevice"));CHECK(boundaryInstalls==0);
    {const auto count=installed.size();StreamlineHooks::unhookInterposer();CHECK(installed.size()==count);CHECK(invalidDetaches==0);CHECK(StreamlineHooks::isInterposerHooked());}
    Reset();StreamlineHooks::hookInterposer(Module());const auto count=installed.size();
    StreamlineHooks::unhookInterposer();CHECK(installed.size()==count);CHECK(StreamlineHooks::isInterposerHooked());CHECK(!transactionActive);
    StreamlineHooks::unhookInterposer();CHECK(installed.size()==count);CHECK(StreamlineHooks::isInterposerHooked());CHECK(invalidDetaches==0);
}
static void Tags(){
    Reset();DataCallbacks();ID3D12Device device;Token frame;IDXGISwapChain swap;const sl::ViewportHandle view(1);
    CHECK(StreamlineHooks::hkslSetD3DDevice(&device)==sl::Result::eOk);
    // Even an eager test provider cannot make a Present imply a tag contract.
    DlssNr::replacementReady=true;StreamlineHooks::ExternalPrepare(frame);
    const auto presentCountBefore=optishade::external_fg_telemetry::Session().Read().presentCallCount;
    StreamlineHooks::NativeProviderPresentBegin(&swap);
    const auto presentTelemetry=optishade::external_fg_telemetry::Session().Read();
    CHECK(presentTelemetry.presentCallCount==presentCountBefore+1&&presentTelemetry.lastPresentThreadId==23);
    StreamlineHooks::NativeProviderPresentEnd(&swap,0);
    CHECK(DlssNr::prepare==0&&DlssNr::providerPrepare==0&&DlssNr::presentResults==0);CHECK(optishade::session::State().writes==0);CHECK(optishade::mfg::source::presents==1);
    sl::Resource resource;resource.native=&device;sl::ResourceTag tag(&resource,sl::kBufferTypeHUDLessColor,sl::eValidUntilPresent);expectedTags=&tag;
    nextTagResult=sl::Result::eErrorInvalidState;CHECK(StreamlineHooks::hkslSetTag(view,&tag,1,nullptr)==nextTagResult);CHECK(DlssNr::legacyTags==0);
    StreamlineHooks::NativeProviderPresentBegin(&swap);CHECK(DlssNr::providerPrepare==0);
    nextTagResult=sl::Result::eOk;CHECK(StreamlineHooks::hkslSetTag(view,&tag,1,nullptr)==nextTagResult);CHECK(DlssNr::legacyTags==0);CHECK(wrongPackets==0);
    CHECK(StreamlineHooks::hkslSetTag(view,&tag,1,nullptr)==nextTagResult);CHECK(DlssNr::legacyTags==1);
    expectedTags=nullptr;StreamlineHooks::ExternalPrepare(frame);CHECK(DlssNr::prepare==1&&DlssNr::lastLegacy);CHECK(DlssNr::acceptedReplacements==1);
    optishade::native_fg_boundary::ready=true;StreamlineHooks::ExternalPrepare(frame);CHECK(DlssNr::prepare==1);
    StreamlineHooks::NativeProviderPresentBegin(&swap);StreamlineHooks::NativeProviderPresentEnd(&swap,0);CHECK(DlssNr::providerPrepare==1&&DlssNr::commits==1&&DlssNr::presentResults==1);
    // Rejected frame APIs cannot switch an accepted legacy contract.
    nextTagResult=sl::Result::eErrorInvalidState;StreamlineHooks::hkslSetTagForFrame(frame,view,&tag,1,nullptr);CHECK(DlssNr::frameTags==0);
    StreamlineHooks::NativeProviderPresentBegin(&swap);CHECK(DlssNr::providerPrepare==2);
    nextTagResult=sl::Result::eOk;const auto invalidated=DlssNr::invalidates;StreamlineHooks::hkslSetTagForFrame(frame,view,&tag,1,nullptr);CHECK(DlssNr::frameTags==0);CHECK(DlssNr::invalidates==invalidated+1);
    StreamlineHooks::hkslSetTagForFrame(frame,view,&tag,1,nullptr);CHECK(DlssNr::frameTags==1);
    StreamlineHooks::ExternalPrepare(frame);CHECK(DlssNr::prepare==2&&!DlssNr::lastLegacy);
    StreamlineHooks::NativeProviderPresentEnd(&swap,0);CHECK(DlssNr::presentResults==2&&DlssNr::providerSwap==nullptr); // accepted Legacy->Frame still completes the earlier Begin
    StreamlineHooks::NativeProviderPresentBegin(&swap);StreamlineHooks::NativeProviderPresentEnd(&swap,0);CHECK(DlssNr::providerPrepare==2&&DlssNr::presentResults==2);
    const auto legacy=DlssNr::legacyTags;StreamlineHooks::hkslSetTag(view,&tag,1,nullptr);CHECK(DlssNr::legacyTags==legacy);StreamlineHooks::ExternalPrepare(frame);CHECK(!DlssNr::lastLegacy);
    Reset();DataCallbacks();StreamlineHooks::hkslSetD3DDevice(&device);nextTagResult=sl::Result::eErrorInvalidState;
    StreamlineHooks::hkslSetTagForFrame(frame,view,&tag,1,nullptr);StreamlineHooks::ExternalPrepare(frame);CHECK(DlssNr::prepare==0&&DlssNr::frameTags==0);
    nextTagResult=sl::Result::eOk;StreamlineHooks::hkslSetTagForFrame(frame,view,&tag,1,nullptr);CHECK(DlssNr::frameTags==0);
    StreamlineHooks::hkslSetTagForFrame(frame,view,&tag,1,nullptr);CHECK(DlssNr::frameTags==1);
    // Null-resource clearing is forwarded and may identify an accepted API,
    // but it supplies no input frame to NR.
    Reset();DataCallbacks();StreamlineHooks::hkslSetD3DDevice(&device);StreamlineHooks::hkslSetTag(view,nullptr,0,nullptr);CHECK(nativeTagCalls==1&&DlssNr::legacyTags==0&&DlssNr::invalidates==1);
}
static void Device(){
    Reset();DataCallbacks();ID3D12Device device;IUnknown other;Token frame;IDXGISwapChain swap;const sl::ViewportHandle view(1);
    nextDeviceResult=sl::Result::eErrorInvalidState;CHECK(StreamlineHooks::hkslSetD3DDevice(&device)==nextDeviceResult);CHECK(StreamlineHooks::renderApi==sl::RenderAPI::eCount);CHECK(optishade::mfg::source::devices==0);
    nextDeviceResult=sl::Result::eOk;CHECK(StreamlineHooks::hkslSetD3DDevice(&device)==nextDeviceResult);CHECK(StreamlineHooks::renderApi==sl::RenderAPI::eD3D12);CHECK(optishade::mfg::source::devices==1);
    StreamlineHooks::hkslSetTag(view,nullptr,0,nullptr);DlssNr::replacementReady=true;
    nextDeviceResult=sl::Result::eErrorInvalidState;StreamlineHooks::hkslSetD3DDevice(&other);CHECK(StreamlineHooks::renderApi==sl::RenderAPI::eD3D12);
    nextDeviceResult=sl::Result::eOk;StreamlineHooks::hkslSetD3DDevice(&other);CHECK(StreamlineHooks::renderApi==sl::RenderAPI::eCount);CHECK(optishade::runtime_render::State().device==0);
    StreamlineHooks::ExternalPrepare(frame);StreamlineHooks::NativeProviderPresentBegin(&swap);CHECK(DlssNr::prepare==0&&DlssNr::providerPrepare==0);
    StreamlineHooks::hkslSetD3DDevice(&device);StreamlineHooks::ExternalPrepare(frame);CHECK(DlssNr::prepare==0); // new device needs new accepted tags
    StreamlineHooks::hkslSetTag(view,nullptr,0,nullptr);StreamlineHooks::hkslSetD3DDevice(nullptr);CHECK(StreamlineHooks::renderApi==sl::RenderAPI::eCount);
    StreamlineHooks::NativeProviderPresentBegin(&swap);CHECK(DlssNr::providerPrepare==0);
    CHECK(DlssNr::resets==4); // failed device calls do not reset the last accepted input contract
    // Failed preparation can still bind the existing native completion owner.
    // An accepted device change during Present must not strand providerSwap.
    Reset();DataCallbacks();StreamlineHooks::hkslSetD3DDevice(&device);StreamlineHooks::hkslSetTag(view,nullptr,0,nullptr);
    StreamlineHooks::NativeProviderPresentBegin(&swap);CHECK(DlssNr::providerSwap==&swap&&DlssNr::commits==0);
    StreamlineHooks::hkslSetD3DDevice(&other);StreamlineHooks::NativeProviderPresentEnd(&swap,0);
    CHECK(DlssNr::providerSwap==nullptr&&DlssNr::presentResults==1);
    StreamlineHooks::NativeProviderPresentEnd(&swap,0);CHECK(DlssNr::presentResults==1);
    // A same-device accepted reinitialization also withdraws stale input data.
    StreamlineHooks::hkslSetD3DDevice(&device);StreamlineHooks::hkslSetTag(view,nullptr,0,nullptr);DlssNr::replacementReady=true;
    StreamlineHooks::hkslSetD3DDevice(&device);CHECK(!DlssNr::replacementReady);
    StreamlineHooks::hkslSetTag(view,nullptr,0,nullptr);StreamlineHooks::NativeProviderPresentBegin(&swap);CHECK(DlssNr::commits==0);
    IDXGISwapChain otherSwap;StreamlineHooks::NativeProviderPresentEnd(&otherSwap,0);CHECK(DlssNr::providerSwap==&swap);
    StreamlineHooks::NativeProviderPresentEnd(&swap,0);CHECK(DlssNr::providerSwap==nullptr);
}
static void Managed(){
    Reset();State::Instance().externalFrameGeneration=false;State::Instance().activeFgInput=FGInput::DLSSG;
    StreamlineHooks::hookInterposer(Module());CHECK(StreamlineHooks::isInterposerHooked());CHECK(Attached("slInit"));CHECK(Attached("slEvaluateFeature"));
    for(const auto* entry:{"slSetTag","slSetTagForFrame","slSetConstants","slGetFeatureFunction","slIsFeatureSupported","slIsFeatureLoaded","slGetFeatureRequirements","slGetFeatureVersion","slAllocateResources","slFreeResources"})CHECK(Attached(entry));
    {const auto count=installed.size();StreamlineHooks::unhookInterposer();CHECK(installed.size()==count);CHECK(StreamlineHooks::isInterposerHooked());CHECK(invalidDetaches==0);}
    Reset();moduleVersion=1;State::Instance().externalFrameGeneration=false;State::Instance().activeFgInput=FGInput::DLSSG;
    StreamlineHooks::hookInterposer(Module());CHECK(StreamlineHooks::isInterposerHooked());CHECK(installed.size()==4);
    {const auto count=installed.size();StreamlineHooks::unhookInterposer();CHECK(installed.size()==count);CHECK(StreamlineHooks::isInterposerHooked());CHECK(!State::checksDisabled);CHECK(invalidDetaches==0);}
}
static void Transactions(){
    Reset();constexpr unsigned workers=12,iterations=20;std::atomic<bool> start{false};
    std::vector<LONG> results(workers*iterations,ERROR_NOT_ENOUGH_MEMORY);std::vector<std::thread> threads;threads.reserve(workers);
    for(unsigned worker=0;worker<workers;++worker)threads.emplace_back([&,worker]{
        while(!start.load(std::memory_order_acquire))std::this_thread::yield();
        for(unsigned iteration=0;iteration<iterations;++iteration){
            const auto index=worker*iterations+iteration;
            results[index]=OptiShade::Detours::WithProcessDetourTransaction([]()->LONG{
                std::this_thread::sleep_for(std::chrono::milliseconds(1));return NO_ERROR;
            });
        }
    });
    start.store(true,std::memory_order_release);for(auto& thread:threads)thread.join();
    CHECK(overlappingTransactions.load(std::memory_order_relaxed)==0);
    for(const auto result:results)CHECK(result==NO_ERROR);
}
int main(int argc,char** argv){
    const std::string selected=argc>1?argv[1]:"all";unsigned failures=0;
    const std::pair<const char*,void(*)()> cases[]={{"external",External},{"lifecycle",Lifecycle},{"tags",Tags},{"device",Device},{"managed",Managed},{"transactions",Transactions}};
    for(const auto& entry:cases)if(selected=="all"||selected==entry.first){
        try{entry.second();std::cout<<"PASS "<<entry.first<<'\n';}
        catch(const std::exception& error){++failures;std::cerr<<"FAIL "<<entry.first<<": "<<error.what()<<'\n';}
    }
    std::cout<<checks<<" production-fragment ownership/readiness checks; failures="<<failures<<"; no Windows detour, GPU or game-output qualification\n";
    return failures?1:0;
}
