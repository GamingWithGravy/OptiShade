#pragma once
// OptiMFG controller IPC v1. This channel belongs to the external EXE, not the
// injected helper. All writes and snapshots use a nonblocking named mutex.
#include <Windows.h>
#include <sddl.h>
#include <string>
#include <vector>
#include <cstdint>
namespace omfg::controller {
constexpr DWORD Magic=0x4f4d4354, Version=1, LeaseMs=2000;
struct State {
    DWORD magic=Magic,version=Version,size=sizeof(State),gamePid{},controllerPid{},heartbeat{};
    LONG connected{},maximumGenerated{-1},stateCalls{},status{-1},effectiveCount{},lastResult{};
    LONG activeRequest{-1},request{-1},commandSequence{},receivedSequence{},appliedSequence{},commandResult{};
};
inline bool Fresh(const State& s,DWORD pid,DWORD now=GetTickCount()) {
    return s.magic==Magic&&s.version==Version&&s.size==sizeof(State)&&s.gamePid==pid&&s.controllerPid&&
        static_cast<DWORD>(now-s.heartbeat)<LeaseMs;
}
class Channel {
    HANDLE mapping_{},mutex_{};State* state_{};DWORD pid_{};bool owner_{};
public:
    Channel()=default;Channel(const Channel&)=delete;Channel& operator=(const Channel&)=delete;
    ~Channel(){Close();}
    void Close(){if(state_)UnmapViewOfFile(state_);if(mapping_)CloseHandle(mapping_);if(mutex_)CloseHandle(mutex_);state_=nullptr;mapping_=mutex_=nullptr;pid_=0;owner_=false;}
    bool Lock(){if(!mutex_)return false;auto r=WaitForSingleObject(mutex_,0);return r==WAIT_OBJECT_0||r==WAIT_ABANDONED;}
    void Unlock(){ReleaseMutex(mutex_);}
    bool Open(DWORD pid,bool owner=false){
        if(state_&&pid_==pid&&owner_==owner)return true;
        Close();pid_=pid;owner_=owner;
        auto name=L"Local\\OptiMFG.Controller.v1."+std::to_wstring(pid);
        PSECURITY_DESCRIPTOR descriptor{};SECURITY_ATTRIBUTES attributes{sizeof(attributes),nullptr,FALSE};
        if(owner){
            HANDLE token{};DWORD size{};
            if(!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&token))return false;
            GetTokenInformation(token,TokenUser,nullptr,0,&size);std::vector<BYTE> data(size);
            bool ok=GetTokenInformation(token,TokenUser,data.data(),size,&size)!=FALSE;CloseHandle(token);if(!ok)return false;
            LPWSTR sid{};if(!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(data.data())->User.Sid,&sid))return false;
            auto sddl=L"D:P(A;;GA;;;SY)(A;;GA;;;"+std::wstring(sid)+L")S:(ML;;NW;;;ME)";LocalFree(sid);
            if(!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(),SDDL_REVISION_1,&descriptor,nullptr))return false;
            attributes.lpSecurityDescriptor=descriptor;
        }
        mutex_=owner?CreateMutexW(&attributes,FALSE,(name+L".Lock").c_str()):OpenMutexW(SYNCHRONIZE|MUTEX_MODIFY_STATE,FALSE,(name+L".Lock").c_str());
        mapping_=owner?CreateFileMappingW(INVALID_HANDLE_VALUE,&attributes,PAGE_READWRITE,0,sizeof(State),name.c_str()):OpenFileMappingW(FILE_MAP_ALL_ACCESS,FALSE,name.c_str());
        if(descriptor)LocalFree(descriptor);
        if(mapping_)state_=static_cast<State*>(MapViewOfFile(mapping_,FILE_MAP_ALL_ACCESS,0,0,sizeof(State)));
        if(!state_||!mutex_){Close();return false;}
        if(owner){
            if(!Lock()){Close();return false;}
            // Do not steal a live controller. A dead owner may leave a mapping
            // alive in the game's handle table; reclaim only after its lease.
            if(Fresh(*state_,pid)&&state_->controllerPid!=GetCurrentProcessId()){Unlock();Close();return false;}
            *state_=State{};state_->gamePid=pid;state_->controllerPid=GetCurrentProcessId();state_->heartbeat=GetTickCount();Unlock();
        }
        return true;
    }
    bool Snapshot(State& out){if(!Lock())return false;out=*state_;Unlock();return Fresh(out,pid_);}
    bool Request(LONG value){
        if(value!=-1&&value!=0&&(value<2||value>6))return false;
        if(!Lock())return false;
        bool ok=Fresh(*state_,pid_)&&state_->connected&&state_->receivedSequence==state_->commandSequence;
        if(ok){state_->request=value;state_->commandSequence=static_cast<LONG>(static_cast<DWORD>(state_->commandSequence)+1u);state_->commandResult=0;}
        Unlock();return ok;
    }
    template<class F> bool Update(F fn){if(!owner_||!Lock())return false;fn(*state_);state_->heartbeat=GetTickCount();Unlock();return true;}
};
}
