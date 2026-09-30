#include "../shared/MfgControlWin.h"
#include <cassert>
#include <iostream>
#include <fstream>
using namespace optishade::mfg;
Json Status(){
    return Json{{"product","RTXMFG"},{"version",40},{"pid",123},{"processBirth",456},{"heartbeat",1000},
        {"gpuFamily",1},{"safeMaximumMultiplier",6},{"bridgeReady",true},{"gameFrameGenerationOn",true},
        {"appliedFrameGenerationOn",true},{"activeWrapperObserved",true},{"dynamicMfgSupportKnown",true},
        {"dynamicMfgSupported",true},{"numFramesToGenerateMax",5},{"applied",true},{"pending",false},
        {"setOptionsAccepted",true},{"requestRevision",3},{"appliedRevision",3},{"appliedMultiplier",2},
        {"appliedMode","fixed"},{"reflexControlAvailable",true},{"dlssgPresetSelectionFrozen",true},
        {"dlssgPresetRestartRequired",false},{"dlssgPresetLatched",2},{"dlssgPresetObservedValid",true},
        {"dlssgPresetObserved",2},{"followGame",true},{"mode","follow"},{"multiplier",2},
        {"dynamicTargetFrameRate",0},{"dlssgPresetRequested",2},{"vsyncMode",0},{"reflexFrameLimitFps",0},
        {"generatedOnlyDebug",false},{"intervalLoggingEnabled",true},{"dynamicExperimental56",false},
        {"actualFramesPresented",2},{"fpsSampleAgeMs",1},{"realFpsMilli",40000},{"dlssFpsMilli",80000}};
}
int main(){
    const std::filesystem::path unicodePath(L"C:\\games\\\u6e38\u620f\\\u00e9\\RTXMFG-Universal.json");
    assert(file::Utf8(unicodePath)=="C:\\games\\\xE6\xB8\xB8\xE6\x88\x8F\\\xC3\xA9\\RTXMFG-Universal.json");
    Json document;Settings settings;Live live;
    assert(Parse(R"({"followGame":true,"mode":"follow","multiplier":2,"author":{"setting":7},"intervalLogging":false})",4096,document));
    assert(ReadSettings(document,settings)&&settings.followGame&&settings.preset==2);
    assert(!Parse(R"({"multiplier":2,"multiplier":6})",4096,document));
    assert(!Parse(R"({"multiplier":2,"nested":{"x":1,"x":2}})",4096,document));
    assert(!Parse(std::string(4097,' '),4096,document));
    assert(!Parse("[]",4096,document));
    assert(!Parse(std::string(40,'[')+"0"+std::string(40,']'),4096,document));
    assert(!ReadSettings(Json{{"multiplier",2.5}},settings));
    assert(!ReadSettings(Json{{"multiplier",-1}},settings));
    assert(!ReadSettings(Json{{"multiplier",2},{"followGame",1}},settings));
    assert(!ReadSettings(Json{{"multiplier",2},{"mode","follow"}},settings));
    assert(ReadSettings(Json{{"multiplier",3}},settings)&&!settings.followGame&&settings.multiplier==3);
    settings=Settings{};
    auto status=Status();assert(ReadLive(status,123,456,1000,settings,live)&&live.canDynamic&&live.canReflex&&live.savedRequestObserved);
    for(const char* key:{"product","version","pid","processBirth","heartbeat","safeMaximumMultiplier","bridgeReady","dynamicMfgSupportKnown","requestRevision","reflexControlAvailable"}){
        auto missing=status;missing.erase(key);assert(!ReadLive(missing,123,456,1000,settings,live));
    }
    assert(!ReadLive(status,124,456,1000,settings,live));assert(!ReadLive(status,123,457,1000,settings,live));
    assert(!ReadLive(status,123,456,1006,settings,live));assert(!ReadLive(status,123,456,999,settings,live));
    auto wrong=status;wrong["version"]=39;assert(!ReadLive(wrong,123,456,1000,settings,live));
    wrong=status;wrong["gpuFamily"]=3;assert(!ReadLive(wrong,123,456,1000,settings,live));
    wrong=status;wrong["dynamicMfgSupported"]=false;assert(ReadLive(wrong,123,456,1000,settings,live)&&!live.canDynamic);
    wrong=status;wrong["numFramesToGenerateMax"]=6;assert(ReadLive(wrong,123,456,1000,settings,live)&&!live.canDynamic);
    auto saved=settings;saved.followGame=false;saved.multiplier=4;
    assert(ReadLive(status,123,456,1000,saved,live)&&live.applied&&!live.savedRequestObserved);
    wrong=status;wrong["appliedMode"]="dynamic";assert(ReadLive(wrong,123,456,1000,settings,live)&&!live.canReflex);
    wrong=status;wrong["fpsSampleAgeMs"]=5001;assert(ReadLive(wrong,123,456,1000,settings,live)&&live.outputFpsMilli==0);
    assert(ReadLive(status,123,456,1000,settings,live));
    // Missing config may still have an active request from the process environment
    // or an earlier config. A preset-only save must retain that fresh baseline.
    auto activeStatus=status;activeStatus["followGame"]=false;activeStatus["mode"]="fixed";
    activeStatus["multiplier"]=4;activeStatus["dynamicTargetFrameRate"]=120;
    activeStatus["reflexFrameLimitFps"]=90;activeStatus["generatedOnlyDebug"]=true;
    Settings activeSettings;Json recovered;
    assert(ReadDesired(activeStatus,activeSettings,&recovered));
    assert(ReadLive(activeStatus,123,456,1000,activeSettings,live)&&live.savedRequestObserved);
    auto presetOnly=activeSettings;presetOnly.preset=1;std::string recoveryError;
    assert(MergeSettings(recovered,activeSettings,presetOnly,live,recoveryError));
    assert(recovered["multiplier"]==4&&recovered["mode"]=="fixed"&&recovered["dynamicTargetFrameRate"]==120&&
        recovered["reflexFrameLimitFps"]==90&&recovered["generatedOnlyDebug"]==true&&recovered["dlssgPreset"]==1);
    auto incomplete=activeStatus;incomplete.erase("reflexFrameLimitFps");assert(!ReadDesired(incomplete,activeSettings));
    assert(!ReadLive(activeStatus,123,456,1006,activeSettings,live)); // Never seed from stale evidence.
    assert(ReadLive(status,123,456,1000,settings,live));
    document={{"multiplier",2},{"followGame",true},{"mode","follow"},{"author",{{"setting",7}}},{"generatedOnlyDebug",false},{"intervalLogging",false}};
    std::string error;auto request=settings;request.followGame=false;request.multiplier=4;
    assert(MergeSettings(document,settings,request,live,error));
    assert(document["author"]["setting"]==7&&document["intervalLogging"]==false&&document["multiplier"]==4);
    Settings reread;assert(ReadSettings(document,reread)&&SameRequest(request,reread));
    request.multiplier=1;assert(!MergeSettings(document,settings,request,live,error));
    live.maxMultiplier=3;request.multiplier=4;assert(!MergeSettings(document,settings,request,live,error));
    request.multiplier=3;request.dynamic=true;live.canDynamic=false;assert(!MergeSettings(document,settings,request,live,error));
    // Preset-only changes preserve a temporarily unsupported saved Dynamic mode.
    auto dynamic=settings;dynamic.followGame=false;dynamic.dynamic=true;dynamic.multiplier=4;
    request=dynamic;request.preset=1;assert(MergeSettings(document,dynamic,request,live,error));
    live.legacyPreset=true;assert(!MergeSettings(document,dynamic,request,live,error));live.legacyPreset=false;
    request=settings;request.reflexLimit=60;live.canReflex=false;assert(!MergeSettings(document,settings,request,live,error));

    const auto root=std::filesystem::current_path()/L"test-run"/(L"mfg-control-"+std::to_wstring(GetCurrentProcessId()));
    std::filesystem::create_directories(root);const auto config=root/L"RTXMFG-Universal.json";
    assert(file::Within(root,config)&&!file::Within(root,root.parent_path()/L"outside.json"));
    const std::string content="{\"multiplier\":2}\n";
    assert(file::Atomic(root,config,content));std::string read;
    assert(file::Read(root,config,4096,read)==file::ReadResult::Okay&&read==content);
    assert(file::Atomic(root,config,"{\"multiplier\":3}\n"));
    assert(file::Read(root,root/L"missing.json",4096,read)==file::ReadResult::Missing);
    assert(!file::Atomic(root,root.parent_path()/L"outside.json",content));
    auto hard=root/L"hard.json";assert(CreateHardLinkW(hard.c_str(),config.c_str(),nullptr));
    assert(file::Read(root,hard,4096,read)==file::ReadResult::Failed);
    assert(!file::Atomic(root,hard,content));
    assert(DeleteFileW(hard.c_str()));
    file::Handle locked(CreateFileW(config.c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr));assert(locked);
    assert(!file::Atomic(root,config,content));locked=file::Handle{};
    // Concurrent edits must not be silently replaced using an older snapshot.
    std::string original;assert(file::Read(root,config,4096,original)==file::ReadResult::Okay);
    const file::Expected beforeEdit{file::ReadResult::Okay,original};bool changed=false;
    const std::string external="{\"multiplier\":5,\"externalPreference\":true}\n";
    assert(file::Atomic(root,config,external));
    assert(!file::Atomic(root,config,content,&beforeEdit,&changed)&&changed);
    assert(file::Read(root,config,4096,read)==file::ReadResult::Okay&&read==external);
    const file::Expected missing{file::ReadResult::Missing,{}};
    assert(!file::Atomic(root,config,content,&missing,&changed)&&changed);
    assert(file::Read(root,config,4096,read)==file::ReadResult::Okay&&read==external);
    assert(DeleteFileW(config.c_str()));
    assert(!file::Atomic(root,config,content,&beforeEdit,&changed)&&changed);
    assert(file::Read(root,config,4096,read)==file::ReadResult::Missing);
    assert(file::Atomic(root,config,content,&missing,&changed)&&!changed);
    auto abc=root/L"abc.txt";{std::ofstream out(abc,std::ios::binary);out<<"abc";}
    file::Handle input(CreateFileW(abc.c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr));
    assert(input&&file::Hash(input.value)=="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    const auto payload=std::filesystem::current_path()/L"installer"/L"OptionalMFG"/L"RTXMFG.dll";
    file::Handle pinned(CreateFileW(payload.c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr));
    assert(pinned&&file::Hash(pinned.value)==kExpectedDllSha256);
    // Exercise the actual bounded shared-memory wire layout without claiming a
    // synthetic status document proves real generated frames.
    auto transport=root/L"test.status.json";
    uint64_t pathHash=14695981039346656037ull;
    for(wchar_t ch:transport.wstring()){if(ch==L'/')ch=L'\\';if(ch>=L'A'&&ch<=L'Z')ch+=L'a'-L'A';pathHash^=uint16_t(ch);pathHash*=1099511628211ull;}
    wchar_t name[128]{};swprintf_s(name,L"Local\\RTXMFG-Status-%lu-%016llX-%016llX",GetCurrentProcessId(),static_cast<unsigned long long>(file::Birth()),static_cast<unsigned long long>(pathHash));
    file::Handle memoryMutex(CreateMutexW(nullptr,FALSE,(std::wstring(name)+L"-Lock").c_str()));assert(memoryMutex);
    struct Wire{uint32_t magic,pid;uint64_t birth;uint32_t bytes;char text[1024*1024];};
    file::Handle mapping(CreateFileMappingW(INVALID_HANDLE_VALUE,nullptr,PAGE_READWRITE,0,sizeof(Wire),name));assert(mapping);
    auto* wire=static_cast<Wire*>(MapViewOfFile(mapping.value,FILE_MAP_ALL_ACCESS,0,0,sizeof(Wire)));assert(wire);
    wire->magic=0x5354464d;wire->pid=GetCurrentProcessId();wire->birth=file::Birth();wire->bytes=static_cast<uint32_t>(content.size());memcpy(wire->text,content.data(),content.size());
    assert(file::ReadMemory(transport,read)&&read==content);
    ++wire->birth;assert(!file::ReadMemory(transport,read));--wire->birth;
    ++wire->pid;assert(!file::ReadMemory(transport,read));--wire->pid;
    wire->bytes=1024*1024+1;assert(!file::ReadMemory(transport,read));
    UnmapViewOfFile(wire);
    // A file on disk is not a loaded verified module; Refresh never loads it.
    Bridge bridge;auto absent=bridge.Refresh();assert(!absent.verified&&!absent.editable);
    assert(!bridge.Save(settings,error));
    std::cout<<"MFG control protocol, session identity, capability limits, stale acknowledgement, settings preservation and guarded file IO: PASS\n";
}
