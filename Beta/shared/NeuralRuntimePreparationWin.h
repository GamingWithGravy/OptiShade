// OptiShade additions, GPL-3.0-or-later. No model loading or inference here.
// The existing optional provider setup callback stays on this worker, never Present.
#pragma once
#include "BackgroundStatus.h"
#include "VerifiedFileHashWin.h"
#include "MfgControlWin.h"
#include "NeuralModelPath.h"
#include "NeuralRuntimeReceipt.h"
#include "RenderingGpuProbeWin.h"
#include "RuntimeRenderContext.h"

namespace optishade::neural_preparation {
struct Snapshot {
    uint64_t device=0,luid=0;
    Evidence hardware=Evidence::Unknown,prepared=Evidence::Unknown;
    std::string modelIdentity,driver,reason;
    std::string executable,executableHash,providerFileHash,providerIdentity,providerFilePath;
    uint64_t nativeProvider=0,nativeGeneration=0;
    bool providerImageHashed=false,fresh=false;
};
class Service {
    FileHash model_,executable_,provider_;
    std::filesystem::path component_;
    uint64_t measuredLuid_=0,measuredAt_=0;
    gpu_probe::Result gpu_;
    std::function<void()> deviceReady_;
    Snapshot Refresh(){
        const auto live=runtime_render::State().Read();Snapshot result;
        if(!live.Fresh(GetTickCount64())){result.reason="Waiting for the actual primary rendering device.";return result;}
        result.device=live.device.identity;result.luid=live.device.luid;
        const auto now=GetTickCount64();
        const auto root=mfg::file::ExecutableRoot();
        wchar_t exe[MAX_PATH*8]{};const auto bytes=GetModuleFileNameW(nullptr,exe,MAX_PATH*8);
        if(!bytes||bytes>=MAX_PATH*8){result.reason="Actual executable identity unavailable.";return result;}
        // Physical root handles account for an Xbox path alias; the loaded
        // executable's leaf remains the selected game, not a launcher receipt.
        const auto exePath=root/std::filesystem::path(exe).filename();
        result.executable=mfg::file::Utf8(exePath.filename());result.executableHash=executable_.Read(root,exePath);
        // A real game callback supplies the module identity. Lookup/loaded-DLL
        // presence alone never creates the positive capability sample.
        HMODULE provider=nullptr;
        if(live.native.provider&&live.native.sampledAt&&now>=live.native.sampledAt&&now-live.native.sampledAt<=3000&&
           GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,reinterpret_cast<LPCWSTR>(live.native.provider),&provider)){
            wchar_t path[32768]{};const auto count=GetModuleFileNameW(provider,path,32768);
            if(count&&count<32768&&_wcsicmp(std::filesystem::path(path).filename().c_str(),L"sl.dlss_g.dll")==0){
                mfg::file::Handle file(CreateFileW(path,FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr));
                const auto physical=file?mfg::file::Final(file.value):std::filesystem::path{};
                if(!physical.empty())result.providerFileHash=provider_.Read(physical.parent_path(),physical);
                if(!result.providerFileHash.empty()){
                    result.nativeProvider=live.native.provider;result.nativeGeneration=live.native.generation;result.providerImageHashed=true;
                    result.providerIdentity="streamline-dlssg-file:"+result.providerFileHash;
                    result.providerFilePath=mfg::file::Utf8(physical);
                }
            }
            FreeLibrary(provider);
        }
        if(live.device.vendor!=0x10de){result.hardware=Evidence::No;result.reason="This pinned NR model catalog has no route for the rendering vendor.";return result;}
        if(measuredLuid_!=live.device.luid||(!gpu_.known&&now>=measuredAt_&&now-measuredAt_>=5000)){
            gpu_=gpu_probe::Query(live.device.luid,live.device.name);measuredLuid_=live.device.luid;measuredAt_=now;
        }
        runtime_render::State().Compute(live.device.identity,live.device.luid,gpu_.known,gpu_.major,gpu_.minor,gpu_.family);
        result.driver=gpu_.driver;
        // The optional compatibility setup delegates to a D3D12 provider.
        // An observed Vulkan device must never make that loader path eligible.
        if(gpu_.known&&deviceReady_&&live.context.api=="d3d12")deviceReady_();
        if(!gpu_.known){result.reason="The system driver has not provided an exact-LUID compute capability.";return result;}
        if(!gpu_.family){result.hardware=Evidence::No;result.reason="Measured rendering architecture has no admitted NR model family.";return result;}
        result.hardware=Evidence::Yes;
        const auto selected=model_path::Select(root,component_);
        std::string receiptText;mfg::Json receipt;
        if(!selected||mfg::file::Read(root,root/L"OptiShadeData"/L"Neural-runtime.json",8192,receiptText)!=mfg::file::ReadResult::Okay||
           !mfg::Parse(receiptText,8192,receipt)){
            result.prepared=Evidence::No;result.reason="Install or refresh the selected NR model and its game-bound receipt.";return result;
        }
        const auto selectedRoot=mfg::file::Equal(selected->parent_path(),root)?root:component_;
        const auto modelHash=model_.Read(selectedRoot,*selected);
        const auto& exeHash=result.executableHash;
        if(modelHash.empty()||exeHash.empty()){result.prepared=Evidence::No;result.reason="Selected model or executable could not be hash-verified with stable file identity.";return result;}
        const auto verified=neural_receipt::Validate(receipt,{mfg::file::Utf8(exePath.filename()),exeHash,live.context.architecture,modelHash,gpu_.family});
        result.prepared=verified.bound?Evidence::Yes:Evidence::No;result.reason=verified.reason;
        if(verified.model)result.modelIdentity=std::string(verified.model->id)+":"+modelHash;
        return result;
    }
public:
    using Worker=BackgroundStatus<Snapshot,unsigned>;
    Worker worker;
    explicit Service(std::filesystem::path component,std::function<void()> deviceReady={}):
        component_(std::move(component)),deviceReady_(std::move(deviceReady)),
        worker([this]{return Refresh();},[](unsigned,std::string&){return false;},std::chrono::milliseconds(1000)){}
    Snapshot Read()const{
        const auto publication=worker.Peek();auto result=publication->state;const auto now=Worker::NowMs();
        result.fresh=publication->sampledAtMs&&now>=publication->sampledAtMs&&now-publication->sampledAtMs<=3000&&publication->readError.empty();
        if(!result.fresh){
            result.providerImageHashed=false;
            result.hardware=result.prepared=Evidence::Unknown;result.reason="NR preparation verification is pending or stale.";
        }
        return result;
    }
};
}
