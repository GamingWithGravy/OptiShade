// OptiShade additions, GPL-3.0-or-later. Metadata/file verification only.
// The existing host remains the sole owner of the D3D12/NGX worker device.
#pragma once
#include "feed_ipc.h"
#include "../../../shared/VerifiedFileHashWin.h"
#include "../../../shared/NeuralRuntimeReceipt.h"
#include "../../../shared/RenderingGpuProbeWin.h"
#include "../../../shared/RenderingCapability.h"
#include <dxgi1_4.h>

namespace feed_preparation {
using namespace optishade;
namespace fs=std::filesystem;
struct Result {
    Evidence hardware=Evidence::Unknown,prepared=Evidence::Unknown;
    std::string modelIdentity,modelHash,driver,workerIdentity,workerHash,reason;
    unsigned family=0,major=0,minor=0;
    bool Ready()const{return hardware==Evidence::Yes&&prepared==Evidence::Yes;}
};
inline fs::path ProcessExecutable(HANDLE process,uint32_t expectedPid){
    if(!process||!expectedPid||GetProcessId(process)!=expectedPid)return {};
    std::wstring name(32768,L'\0');DWORD count=static_cast<DWORD>(name.size());
    if(!QueryFullProcessImageNameW(process,0,name.data(),&count)||!count||count>=name.size())return {};
    name.resize(count);
    mfg::file::Handle file(CreateFileW(name.c_str(),FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,
        nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr));
    return file?mfg::file::Final(file.value):fs::path{};
}
inline bool AdapterName(const FeedAdapterIdentity& expected,std::string& name){
    if(!FeedAdapterValid(expected)||!expected.luid)return false;
    wchar_t system[MAX_PATH]{};const auto length=GetSystemDirectoryW(system,MAX_PATH);
    if(!length||length>=MAX_PATH)return false;
    const auto library=LoadLibraryExW((std::wstring(system)+L"\\dxgi.dll").c_str(),nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);
    if(!library)return false;
    struct Unload {HMODULE value;~Unload(){FreeLibrary(value);}} unload{library};
    using Create=HRESULT(WINAPI*)(REFIID,void**);
    const auto create=reinterpret_cast<Create>(GetProcAddress(library,"CreateDXGIFactory1"));
    IDXGIFactory4* factory=nullptr;
    if(!create||FAILED(create(__uuidof(IDXGIFactory4),reinterpret_cast<void**>(&factory))))return false;
    struct ReleaseFactory{IDXGIFactory4* value;~ReleaseFactory(){value->Release();}} releaseFactory{factory};
    LUID luid{};std::memcpy(&luid,&expected.luid,sizeof(luid));IDXGIAdapter1* adapter=nullptr;
    if(FAILED(factory->EnumAdapterByLuid(luid,__uuidof(IDXGIAdapter1),reinterpret_cast<void**>(&adapter))))return false;
    struct ReleaseAdapter{IDXGIAdapter1* value;~ReleaseAdapter(){value->Release();}} releaseAdapter{adapter};
    DXGI_ADAPTER_DESC1 desc{};
    if(FAILED(adapter->GetDesc1(&desc))||desc.VendorId!=expected.vendor_id||desc.DeviceId!=expected.device_id||
       std::memcmp(&desc.AdapterLuid,&luid,sizeof(luid))!=0)return false;
    name=mfg::file::Utf8(fs::path(desc.Description));return !name.empty();
}
// Run on the existing host thread or the client's metadata worker, never the
// render/IPC thread. These handles remain owned until that verifier is retired:
// model/EXE replacement cannot inherit a successful earlier hash result.
class Verifier {
    neural_preparation::FileHash executable_,rootModel_,hostModel_,worker_;
public:
    Result Verify(HANDLE game,uint32_t pid,const FeedAdapterIdentity& adapter,const fs::path& hostDirectory,const FeedPrepareAck* qualified=nullptr){
        Result result;
        if(!FeedAdapterValid(adapter)||!adapter.luid){result.reason="Waiting for the actual game rendering adapter.";return result;}
        if(adapter.vendor_id!=0x10de){result.hardware=Evidence::No;result.reason="The pinned NR model catalog has no route for this rendering vendor.";return result;}
        if(qualified){
            // This copy is published by the existing rendering owner only while
            // its OS-verified x64 host and exact adapter generation are alive.
            if(!FeedPreparationValid(*qualified,adapter)){
                result.reason="The measured x64 worker preparation is not current for this rendering adapter.";return result;
            }
            result.family=qualified->family;result.major=qualified->compute_major;result.minor=qualified->compute_minor;
            result.driver=qualified->driver;
        }else{
            std::string name;
            if(!AdapterName(adapter,name)){result.reason="The current adapter does not match the game's complete LUID and PCI identity.";return result;}
            const auto gpu=gpu_probe::Query(adapter.luid,name);result.driver=gpu.driver;result.family=gpu.family;
            result.major=gpu.major;result.minor=gpu.minor;
            if(!gpu.known){result.reason="Exact-LUID compute capability is unavailable in this process; waiting for the x64 worker's measured preparation.";return result;}
            if(!gpu.family){result.hardware=Evidence::No;result.reason="The measured rendering architecture has no admitted pinned NR model family.";return result;}
        }
        result.hardware=Evidence::Yes;
        const auto executable=ProcessExecutable(game,pid);const auto root=executable.parent_path();BOOL wow=FALSE;
        if(executable.empty()||!IsWow64Process(game,&wow)||!wow||
           !mfg::file::Equal(hostDirectory,root/L"host64")){
            result.prepared=Evidence::No;result.reason="The worker directory and actual x86 game executable could not be bound.";return result;
        }
        const auto exeHash=executable_.Read(root,executable);
        const auto gameModelHash=rootModel_.Read(root,root/L"nvngx_dlssnr.dll");
        const auto hostModelHash=hostModel_.Read(root,hostDirectory/L"nvngx_dlssnr.dll");
        const auto workerHash=worker_.Read(root,hostDirectory/L"dlss5-feed-host64.exe");
        if(exeHash.empty()||gameModelHash.empty()||workerHash.empty()||hostModelHash!=gameModelHash||
           (qualified&&(!neural_receipt::EqualAscii(qualified->model_hash,hostModelHash)||
                        !neural_receipt::EqualAscii(qualified->worker_hash,workerHash)))){
            result.prepared=Evidence::No;result.reason="Original game, worker and both model copies must have stable matching file identities.";return result;
        }
        result.workerHash=workerHash;result.modelHash=hostModelHash;
        result.workerIdentity="legacy-host-file:"+workerHash;
        std::string text;mfg::Json receipt;
        if(mfg::file::Read(root,root/L"OptiShadeData"/L"Neural-runtime.json",8192,text)!=mfg::file::ReadResult::Okay||
           !mfg::Parse(text,8192,receipt)){
            result.prepared=Evidence::No;result.reason="Install or refresh the canonical game-bound NR model receipt.";return result;
        }
        const auto verified=neural_receipt::Validate(receipt,{mfg::file::Utf8(executable.filename()),exeHash,"x86",hostModelHash,result.family});
        result.prepared=verified.bound?Evidence::Yes:Evidence::No;result.reason=verified.reason;
        if(verified.model)result.modelIdentity=std::string(verified.model->id)+":"+hostModelHash;
        if(!verified.bound)return result;
        for(const auto file:{L"dxgi.dll",L"winmm.dll",L"nvngx.dll_dlssnr.dll",L"nvngx_dlss.dll"}){
            const auto attributes=GetFileAttributesW((hostDirectory/file).c_str());
            if(attributes==INVALID_FILE_ATTRIBUTES||(attributes&FILE_ATTRIBUTE_DIRECTORY)){
                result.prepared=Evidence::No;result.reason="A required legacy host dependency is missing; use desktop repair.";return result;
            }
        }
        return result;
    }
};
}
