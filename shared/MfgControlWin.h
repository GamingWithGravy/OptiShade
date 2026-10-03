// OptiShade additions, GPL-3.0-or-later.
#pragma once
#include "SourceMfgOutput.h"
#include "MfgControl.h"
#include "OptiShadeMfgApi.h"
#include "SourceMfgIdentity.h"
#include <thread>
#include <condition_variable>
#include <windows.h>
#include <bcrypt.h>
#include <filesystem>
#include <vector>
#include <mutex>
#include <cstring>
#include <atomic>
#pragma comment(lib,"bcrypt.lib")

namespace optishade::mfg {
namespace file {
namespace fs = std::filesystem;
inline std::string Utf8(const fs::path& path){
    const auto bytes=path.u8string();
    // C++17 returns string; C++20 returns u8string. Both expose UTF-8 bytes.
    return std::string(reinterpret_cast<const char*>(bytes.data()),bytes.size());
}
struct Handle {
    HANDLE value = INVALID_HANDLE_VALUE;
    Handle() = default; explicit Handle(HANDLE h):value(h){}
    ~Handle(){ if(value != INVALID_HANDLE_VALUE && value != nullptr) CloseHandle(value); }
    Handle(const Handle&) = delete; Handle& operator=(const Handle&) = delete;
    Handle(Handle&& other) noexcept:value(other.value){other.value=INVALID_HANDLE_VALUE;}
    Handle& operator=(Handle&& other) noexcept { if(this!=&other){if(value!=INVALID_HANDLE_VALUE&&value)CloseHandle(value);value=other.value;other.value=INVALID_HANDLE_VALUE;}return *this;}
    explicit operator bool() const {return value && value != INVALID_HANDLE_VALUE;}
};
inline fs::path Final(HANDLE h) {
    std::wstring text(32768,L'\0'); const auto count=GetFinalPathNameByHandleW(h,text.data(),static_cast<DWORD>(text.size()),FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);
    if(!count||count>=text.size())return {};text.resize(count);
    if(text.compare(0,8,L"\\\\?\\UNC\\")==0)text=L"\\\\"+text.substr(8);
    else if(text.compare(0,4,L"\\\\?\\")==0)text=text.substr(4);
    return fs::path(text).lexically_normal();
}
inline bool Equal(const fs::path& a,const fs::path& b){return _wcsicmp(a.c_str(),b.c_str())==0;}
inline bool Regular(HANDLE h) {
    BY_HANDLE_FILE_INFORMATION info{}; return GetFileInformationByHandle(h,&info) &&
        !(info.dwFileAttributes&(FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_REPARSE_POINT)) && info.nNumberOfLinks==1;
}
inline uint64_t Birth(){FILETIME created{},exit{},kernel{},user{};return GetProcessTimes(GetCurrentProcess(),&created,&exit,&kernel,&user)?(uint64_t(created.dwHighDateTime)<<32)|created.dwLowDateTime:0;}
inline uint64_t Now(){FILETIME time{};GetSystemTimeAsFileTime(&time);return (((uint64_t(time.dwHighDateTime)<<32)|time.dwLowDateTime)/10000000ull)-11644473600ull;}
inline fs::path ExecutableRoot(){
    std::wstring name(32768,L'\0');const auto size=GetModuleFileNameW(nullptr,name.data(),static_cast<DWORD>(name.size()));
    if(!size||size>=name.size())return {};name.resize(size);
    Handle h(CreateFileW(name.c_str(),FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr));
    return h?Final(h.value).parent_path():fs::path{};
}
inline std::wstring Environment(const wchar_t* key){std::wstring s(32768,L'\0');const auto n=GetEnvironmentVariableW(key,s.data(),static_cast<DWORD>(s.size()));if(!n||n>=s.size())return {};s.resize(n);return s;}
inline fs::path ReportedRoot(){std::wstring s(32768,L'\0');const auto n=GetModuleFileNameW(nullptr,s.data(),static_cast<DWORD>(s.size()));if(!n||n>=s.size())return {};s.resize(n);return fs::path(s).parent_path();}
inline bool Within(const fs::path& root,const fs::path& path){
    if(root.empty()||!path.is_absolute()||path!=path.lexically_normal())return false;
    auto r=root.begin(), p=path.begin();for(;r!=root.end();++r,++p)if(p==path.end()||_wcsicmp(r->c_str(),p->c_str()))return false;
    return p!=path.end();
}
// Hold each physical parent without delete-sharing for the operation. Existing
// Xbox aliases are resolved at the trusted executable boundary, not accepted as
// arbitrary writable junctions beneath the game directory.
struct Parents {
    std::vector<Handle> locks;
    bool Open(const fs::path& root,const fs::path& path){
        if(!Within(root,path))return false;
        auto current=path.parent_path();
        for(;;){
            Handle h(CreateFileW(current.c_str(),FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,nullptr));
            BY_HANDLE_FILE_INFORMATION info{};
            if(!h||!GetFileInformationByHandle(h.value,&info)||!(info.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)||
                (info.dwFileAttributes&FILE_ATTRIBUTE_REPARSE_POINT)||!Equal(Final(h.value),current))return false;
            locks.push_back(std::move(h));if(Equal(current,root))return true;
            const auto parent=current.parent_path();if(parent==current)return false;current=parent;
        }
    }
};
enum class ReadResult {Okay,Missing,Failed};
inline ReadResult Read(const fs::path& root,const fs::path& path,size_t limit,std::string& out){
    Parents parents;if(!parents.Open(root,path))return ReadResult::Failed;
    Handle h(CreateFileW(path.c_str(),GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,nullptr));
    if(!h)return GetLastError()==ERROR_FILE_NOT_FOUND?ReadResult::Missing:ReadResult::Failed;
    LARGE_INTEGER size{};if(!Regular(h.value)||!Equal(Final(h.value),path)||!GetFileSizeEx(h.value,&size)||size.QuadPart<=0||uint64_t(size.QuadPart)>limit)return ReadResult::Failed;
    std::string text(static_cast<size_t>(size.QuadPart),'\0');DWORD got=0;
    if(!ReadFile(h.value,text.data(),static_cast<DWORD>(text.size()),&got,nullptr)||got!=text.size())return ReadResult::Failed;
    char extra;DWORD tail=0;if(!ReadFile(h.value,&extra,1,&tail,nullptr)||tail)return ReadResult::Failed;
    out=std::move(text);return ReadResult::Okay;
}
struct Expected {ReadResult state=ReadResult::Failed;std::string bytes;};
inline bool Atomic(const fs::path& root,const fs::path& path,const std::string& content,const Expected* expected=nullptr,bool* changed=nullptr){
    if(changed)*changed=false;
    if(content.empty()||content.size()>4096)return false;
    Parents parents;if(!parents.Open(root,path))return false;
    {Handle existing(CreateFileW(path.c_str(),FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,nullptr));
     if(existing){if(!Regular(existing.value)||!Equal(Final(existing.value),path))return false;}
     else if(GetLastError()!=ERROR_FILE_NOT_FOUND)return false;}
    static std::atomic<uint64_t> sequence{0};
    const auto temporary=fs::path(path.wstring()+L".optishade-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64())+L"-"+std::to_wstring(++sequence)+L".tmp");
    Handle h(CreateFileW(temporary.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_OPEN_REPARSE_POINT,nullptr));if(!h)return false;
    DWORD written=0;const bool okay=Regular(h.value)&&WriteFile(h.value,content.data(),static_cast<DWORD>(content.size()),&written,nullptr)&&written==content.size()&&FlushFileBuffers(h.value);
    h=Handle{};
    bool unchanged=true;
    if(okay&&expected){
        std::string latest;const auto current=Read(root,path,4096,latest);
        unchanged=expected->state==current&&(current==ReadResult::Missing||(current==ReadResult::Okay&&latest==expected->bytes));
        if(changed)*changed=!unchanged;
    }
    // New-file creation is atomic and never overwrites a competing creation.
    // Existing-file replacement checks the captured bytes immediately before
    // renaming. Arbitrary external writers have no shared transactional protocol,
    // so this does not claim cross-process compare-and-swap guarantees.
    const DWORD replace=expected&&expected->state==ReadResult::Missing?0:MOVEFILE_REPLACE_EXISTING;
    if(okay&&unchanged&&MoveFileExW(temporary.c_str(),path.c_str(),replace|MOVEFILE_WRITE_THROUGH))return true;
    DeleteFileW(temporary.c_str());return false;
}
inline std::string Hash(HANDLE file){
    LARGE_INTEGER size{},zero{};if(!GetFileSizeEx(file,&size)||size.QuadPart<=0||size.QuadPart>64*1024*1024||!SetFilePointerEx(file,zero,nullptr,FILE_BEGIN))return {};
    BCRYPT_ALG_HANDLE algorithm=nullptr;BCRYPT_HASH_HANDLE hash=nullptr;std::string result;
    if(BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,nullptr,0)<0)return {};
    if(BCryptCreateHash(algorithm,&hash,nullptr,0,nullptr,0,0)>=0){
        char buffer[65536];bool okay=true;DWORD got=0;uint64_t total=0;
        for(;;){if(!ReadFile(file,buffer,sizeof(buffer),&got,nullptr)){okay=false;break;}if(!got)break;total+=got;if(BCryptHashData(hash,reinterpret_cast<PUCHAR>(buffer),got,0)<0){okay=false;break;}}
        UCHAR digest[32]{};if(okay&&total==uint64_t(size.QuadPart)&&BCryptFinishHash(hash,digest,sizeof(digest),0)>=0){const char* hex="0123456789abcdef";for(auto b:digest){result+=hex[b>>4];result+=hex[b&15];}}
        BCryptDestroyHash(hash);
    }BCryptCloseAlgorithmProvider(algorithm,0);return result;
}
// Read the pinned backend's documented status transport when the primary file
// is sharing/access blocked. This opens only existing read-only shared memory.
inline bool ReadMemory(const fs::path& transportPath,std::string& out){
    uint64_t hash=14695981039346656037ull;
    for(wchar_t ch:transportPath.wstring()){if(ch==L'/')ch=L'\\';if(ch>=L'A'&&ch<=L'Z')ch+=L'a'-L'A';hash^=uint16_t(ch);hash*=1099511628211ull;}
    const auto birth=Birth();if(!birth)return false;
    wchar_t name[128]{};swprintf_s(name,L"Local\\RTXMFG-Status-%lu-%016llX-%016llX",GetCurrentProcessId(),static_cast<unsigned long long>(birth),static_cast<unsigned long long>(hash));
    Handle mutex(OpenMutexW(SYNCHRONIZE|MUTEX_MODIFY_STATE,FALSE,(std::wstring(name)+L"-Lock").c_str()));if(!mutex)return false;
    const auto acquired=WaitForSingleObject(mutex.value,0);if(acquired!=WAIT_OBJECT_0&&acquired!=WAIT_ABANDONED)return false;
    struct Unlock{HANDLE h;~Unlock(){ReleaseMutex(h);}} unlock{mutex.value};
    struct Memory{uint32_t magic,pid;uint64_t birth;uint32_t bytes;char text[1024*1024];};
    Handle mapping(OpenFileMappingW(FILE_MAP_READ,FALSE,name));if(!mapping)return false;
    const auto* memory=static_cast<const Memory*>(MapViewOfFile(mapping.value,FILE_MAP_READ,0,0,sizeof(Memory)));if(!memory)return false;
    struct Unmap{const void* p;~Unmap(){UnmapViewOfFile(p);}} unmap{memory};
    if(memory->magic!=0x5354464d||memory->pid!=GetCurrentProcessId()||memory->birth!=birth||!memory->bytes||memory->bytes>sizeof(memory->text))return false;
    out.assign(memory->text,memory->bytes);return true;
}
}

// Called by the existing post-DllMain startup worker, never by opening the menu.
// An installed owned source provider reserves the session even if startup fails.
inline bool StartSourceBackend(){
 const auto root=file::ExecutableRoot();std::string text;Json receipt;
 const auto record=root/L"OptiShadeData"/L"MFG"/L"source-backend.json";
 std::error_code absence;const bool exists=std::filesystem::exists(record,absence);if(!exists&&!absence)return false;
 if(file::Read(root,record,4096,text)==file::ReadResult::Missing)return false;
 if(!Parse(text,4096,receipt)||receipt.value("sha256",std::string{})!=kSourceDllSha256||receipt.value("abi",0u)!=source::Abi)return true;
 // An owned migration must retire the old executable path before activation.
 for(const wchar_t* name:{L"version.dll",L"RTXMFG.dll",L"RTX40MFGCore.dll",L"RTX40MFG.asi",L"RTX40MFG-UI.addon64"})if(std::filesystem::exists(root/name))return true;
 const auto path=root/L"OptiShadeData"/L"MFG"/L"OptiShadeMFG.dll";
 static file::Handle held;static HMODULE loaded=nullptr;
 if(loaded)return true;
 file::Parents parents;if(!parents.Open(root,path))return true;
 file::Handle h(CreateFileW(path.c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,nullptr));
 if(!h||!file::Regular(h.value)||!file::Equal(file::Final(h.value),path)||file::Hash(h.value)!=kSourceDllSha256)return true;
 loaded=LoadLibraryExW(path.c_str(),nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_SYSTEM32);
 if(!loaded)return true;held=std::move(h);
 auto query=reinterpret_cast<source::Query>(GetProcAddress(loaded,"OptiShadeMfgQuery"));auto start=reinterpret_cast<source::Start>(GetProcAddress(loaded,"OptiShadeMfgStart"));
 source::Status status;if(!query||!start||!query(&status,sizeof(status))||status.abi!=source::Abi)return true;
 if(start())source::observePresent.store(reinterpret_cast<source::Present>(GetProcAddress(loaded,"OptiShadeMfgObservePresent")),std::memory_order_release);return true;
}

class Bridge {
    std::mutex mutex;
    Snapshot cached;
    uint64_t lastRead=0;
    HMODULE module=nullptr;
    file::Handle moduleFile;
    std::filesystem::path root,config,status,statusTransport;
    Settings desired;
    Json desiredSeed;
    bool sourceBackend=false;
    source::Query sourceQuery=nullptr;
    bool OwnsBackend(){
        if(sourceBackend)return true;
        // Pinned export supports its original 64-byte prefix as well as the
        // newer 120-byte diagnostic struct; no private backend ABI is invoked.
        struct Query {uint32_t size=64,version=0,owner=0,duplicate=0,unused[6]{};uint64_t frames[3]{};};
        static_assert(sizeof(Query)==64);
        const auto fn=reinterpret_cast<BOOL(WINAPI*)(Query*)>(GetProcAddress(module,"MfgUnlockSingleModuleQuery"));
        Query q;return fn&&fn(&q)&&q.version==1&&q.owner==1&&q.duplicate==0;
    }
    bool Trust(){
        if(module&&moduleFile)return true;
        root=file::ExecutableRoot();if(root.empty())return false;
        HMODULE sourceModule=nullptr;
        if(GetModuleHandleExW(0,L"OptiShadeMFG.dll",&sourceModule)){
            std::string recordText;Json record;
            if(file::Read(root,root/L"OptiShadeData"/L"MFG"/L"source-backend.json",4096,recordText)!=file::ReadResult::Okay||!Parse(recordText,4096,record)||record.value("sha256",std::string{})!=kSourceDllSha256||record.value("abi",0u)!=source::Abi){FreeLibrary(sourceModule);return false;}
            const auto path=root/L"OptiShadeData"/L"MFG"/L"OptiShadeMFG.dll";
            wchar_t loadedPath[32768]{};GetModuleFileNameW(sourceModule,loadedPath,32768);
            file::Handle h(CreateFileW(path.c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,nullptr));
            auto query=reinterpret_cast<source::Query>(GetProcAddress(sourceModule,"OptiShadeMfgQuery"));source::Status v;
            if(h&&file::Regular(h.value)&&file::Equal(file::Final(h.value),path)&&file::Equal(path,loadedPath)&&file::Hash(h.value)==kSourceDllSha256&&query&&query(&v,sizeof(v))&&v.abi==source::Abi){module=sourceModule;moduleFile=std::move(h);sourceBackend=true;sourceQuery=query;return true;}
            FreeLibrary(sourceModule);cached.detected=true;return false;
        }
        for(const wchar_t* name:{L"version.dll",L"RTXMFG.dll"}){
            HMODULE loaded=nullptr;
            if(!GetModuleHandleExW(0,name,&loaded))continue; // Existing module only, never load a DLL.
            const auto query=GetProcAddress(loaded,"MfgUnlockSingleModuleQuery");
            if(!query){FreeLibrary(loaded);continue;}cached.detected=true;
            std::wstring path(32768,L'\0');const auto count=GetModuleFileNameW(loaded,path.data(),static_cast<DWORD>(path.size()));
            if(!count||count>=path.size()){FreeLibrary(loaded);continue;}path.resize(count);
            file::Handle dll(CreateFileW(path.c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,nullptr));
            if(!dll||!file::Regular(dll.value)||!file::Equal(file::Final(dll.value),root/name)||file::Hash(dll.value)!=kExpectedDllSha256){FreeLibrary(loaded);continue;}
            // Keep a reference and a non-writable file handle for this bridge's
            // lifetime; a disk replacement cannot change the trusted identity.
            module=loaded;moduleFile=std::move(dll);return true;
        }return false;
    }
    bool Paths(){
        const auto c=file::Environment(L"RTX_MFG_CONFIG_PATH"),s=file::Environment(L"RTX_MFG_STATUS_PATH");
        const auto reported=file::ReportedRoot();if(reported.empty())return false;
        const auto backendConfig=(reported/(c.empty()?std::filesystem::path(L"RTXMFG-Universal.json"):std::filesystem::path(c))).lexically_normal();
        statusTransport=s.empty()?backendConfig.parent_path()/L"RTXMFG-Universal.status.json":(reported/std::filesystem::path(s)).lexically_normal();
        auto physical=[&](const std::filesystem::path& p){return file::Within(reported,p)?(root/p.lexically_relative(reported)).lexically_normal():p;};
        config=physical(backendConfig);status=physical(statusTransport);
        return file::Within(root,config)&&file::Within(root,status)&&!file::Equal(config,status);
    }
    Snapshot RefreshLocked(){
        cached=Snapshot{};desiredSeed=Json{};lastRead=GetTickCount64();
        if(!Trust()){cached.message=cached.detected?"The loaded MFG module could not be verified.":"MFG is not loaded in this game session.";return cached;}
        cached.detected=cached.verified=true;
        cached.owned=OwnsBackend();
        if(!cached.owned){cached.message="The MFG module is loaded but does not own the active backend.";return cached;}
        if(!Paths()){cached.message="MFG control paths must remain inside the physical game installation.";return cached;}
        cached.identity=file::Utf8(config);
        std::string text;Json saved;
        const auto read=file::Read(root,config,4096,text);
        if(read==file::ReadResult::Failed||(read==file::ReadResult::Okay&&(!Parse(text,4096,saved)||!ReadSettings(saved,cached.settings)))){
            cached.message="The MFG settings file cannot be read safely; existing settings have been kept.";return cached;
        }
        if(sourceBackend){
            source::Status v;if(!sourceQuery||!sourceQuery(&v,sizeof(v))||v.size!=sizeof(v)||v.abi!=source::Abi||v.pid!=GetCurrentProcessId()||v.birth!=file::Birth()||v.tick>GetTickCount64()||GetTickCount64()-v.tick>1000){cached.message="Source MFG contract/session unavailable.";return cached;}
            cached.sourceBuilt=true;cached.live=true;cached.editable=v.family==20||v.family==30||v.family==40;
            auto& l=cached.status;l.gpuFamily=v.family;l.bridgeReady=v.ready;l.maxMultiplier=v.maximum;l.minMultiplier=v.minimum;l.canDynamic=v.dynamicAvailable;l.legacyPreset=true;
            l.gameFgOn=v.gameFg;l.setOptionsAccepted=v.accepted;l.requestRevision=v.requestRevision;l.appliedRevision=v.acceptedRevision;
            l.applied=v.accepted&&v.gameFg;l.pending=v.requestRevision!=v.acceptedRevision;l.appliedMultiplier=v.acceptedMultiplier;l.appliedDynamic=v.acceptedDynamic;
            l.savedRequestObserved=read==file::ReadResult::Missing||saved.value("optishadeRevision",0u)==v.savedRevision;
            desired.followGame=v.follow;desired.dynamic=v.dynamic;desired.multiplier=v.multiplier;desired.targetFps=v.target;desired.overrideOff=v.overrideOff;
            desiredSeed=Json{{"followGame",desired.followGame},{"mode",desired.followGame?"follow":desired.dynamic?"dynamic":"fixed"},{"multiplier",desired.multiplier},{"dynamicTargetFrameRate",desired.targetFps},{"overrideOff",desired.overrideOff},{"optishadeRevision",v.savedRevision}};
            if(read==file::ReadResult::Missing)cached.settings=desired;
            cached.message=v.reason;return cached;
        }
        Json live;auto validStatus=[&]{
            Settings active;Json seed;
            if(!Parse(text,1024*1024,live)||!ReadDesired(live,active,&seed))return false;
            const auto baseline=read==file::ReadResult::Missing?active:cached.settings;
            if(!ReadLive(live,GetCurrentProcessId(),file::Birth(),file::Now(),baseline,cached.status))return false;
            cached.settings=baseline;desired=active;desiredSeed=std::move(seed);return true;
        };
        const bool diskValid=file::Read(root,status,1024*1024,text)==file::ReadResult::Okay&&validStatus();
        if(!diskValid&&(!file::ReadMemory(statusTransport,text)||!validStatus())){
            cached.message="MFG status is missing, stale or belongs to another session.";return cached;
        }
        cached.live=cached.editable=true;
        cached.message=cached.status.bridgeReady?"MFG backend connected.":"Waiting for the game's DLSS frame generation pipeline.";
        return cached;
    }
public:
    std::mutex queueMutex;std::condition_variable wake;std::thread writer;bool stop=false,queued=false,busy=false;Settings queuedSettings;std::string saveResult;
    Bridge()=default;
    void StartWriter(){if(writer.joinable())return;writer=std::thread([this]{for(;;){Settings request;{std::unique_lock lock(queueMutex);wake.wait(lock,[&]{return stop||queued;});if(stop)return;request=queuedSettings;queued=false;busy=true;}std::string error;const bool ok=SaveNow(request,error);{std::lock_guard lock(queueMutex);saveResult=ok?"MFG settings saved; waiting for backend acknowledgement.":error;busy=false;}}});}Bridge(const Bridge&)=delete;Bridge& operator=(const Bridge&)=delete;
    ~Bridge(){{std::lock_guard lock(queueMutex);stop=true;}wake.notify_one();if(writer.joinable())writer.join();if(module)FreeLibrary(module);}
    bool Save(const Settings& requested,std::string& error){{std::lock_guard stateLock(mutex);if(!cached.verified||!cached.live||!cached.editable){error=cached.message.empty()?"No verified MFG session is available.":cached.message;return false;}}std::lock_guard lock(queueMutex);if(queued||busy){error="Previous MFG save is still running.";return false;}StartWriter();queuedSettings=requested;queued=true;saveResult="MFG save queued.";wake.notify_one();error.clear();return true;}
    std::string SaveResult(){std::lock_guard lock(queueMutex);return saveResult;}
    Snapshot Refresh(){std::lock_guard lock(mutex);if(lastRead&&GetTickCount64()-lastRead<250)return cached;try{return RefreshLocked();}catch(...){cached.live=cached.editable=false;cached.message="MFG status could not be read safely.";return cached;}}
    bool SaveNow(const Settings& requested,std::string& error){
        std::lock_guard lock(mutex);
        try{
            RefreshLocked();if(!cached.verified||!cached.live||!cached.editable){error=cached.message;return false;}
            std::string original;Json document;Settings current;
            const auto read=file::Read(root,config,4096,original);
            if(read==file::ReadResult::Failed||(read==file::ReadResult::Okay&&(!Parse(original,4096,document)||!ReadSettings(document,current)))){error="The current MFG settings could not be read; nothing was changed.";return false;}
            // An absent file does not reset the backend's active request. It can
            // be running from an environment choice or a subsequently removed
            // config. Recover only known fields from this freshly trusted status.
            if(read==file::ReadResult::Missing){document=desiredSeed;current=desired;if(!document.is_object()){error="Current MFG settings are unavailable.";return false;}}
            if(!MergeAdapterSettings(sourceBackend,document,current,requested,cached.status,error))return false;
            if(sourceBackend){
                if(requested.preset!=current.preset||requested.reflexLimit!=current.reflexLimit||requested.vsyncMode!=current.vsyncMode){error="This source backend does not implement preset/Reflex/VSync controls.";return false;}
                const auto revision=document.value("optishadeRevision",0u);if(revision==UINT32_MAX){error="MFG revision limit reached.";return false;}document["optishadeRevision"]=revision+1;
            }
            const auto content=document.dump()+"\n";
            const file::Expected expected{read,original};bool changed=false;
            if(content.size()>4096||!file::Atomic(root,config,content,&expected,&changed)){
                error=changed?"MFG settings changed while saving. Refresh the controls and try again.":"The MFG settings could not be saved; check access to the game folder.";return false;
            }
            RefreshLocked();error.clear();return true;
        }catch(...){error="The MFG settings could not be saved safely.";return false;}
    }
};
}
