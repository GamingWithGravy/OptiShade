// OptiShade additions, GPL-3.0-or-later.
#pragma once
#include "MfgControl.h"
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

class Bridge {
    std::mutex mutex;
    Snapshot cached;
    uint64_t lastRead=0;
    HMODULE module=nullptr;
    file::Handle moduleFile;
    std::filesystem::path root,config,status,statusTransport;
    Settings desired;
    Json desiredSeed;
    bool OwnsBackend(){
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
    Bridge()=default;Bridge(const Bridge&)=delete;Bridge& operator=(const Bridge&)=delete;
    ~Bridge(){if(module)FreeLibrary(module);}
    Snapshot Refresh(){std::lock_guard lock(mutex);if(lastRead&&GetTickCount64()-lastRead<250)return cached;try{return RefreshLocked();}catch(...){cached.live=cached.editable=false;cached.message="MFG status could not be read safely.";return cached;}}
    bool Save(const Settings& requested,std::string& error){
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
            if(!MergeSettings(document,current,requested,cached.status,error))return false;
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
