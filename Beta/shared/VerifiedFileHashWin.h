// OptiShade additions, GPL-3.0-or-later. Stable worker-only file verification.
#pragma once
#include "MfgControlWin.h"

namespace optishade::neural_preparation {
// Large model and executable hashes are computed by this dedicated worker,
// never by Present or an IPC callback. Successful verification retains read
// handles without write/delete sharing, so a replaced path cannot reuse proof.
class FileHash {
    mfg::file::Handle handle_;
    mfg::file::Parents parents_;
    std::filesystem::path path_;
    std::string hash_;
public:
    std::string Read(const std::filesystem::path& root,const std::filesystem::path& path){
        if(handle_&&mfg::file::Equal(path,path_))return hash_;
        handle_={};parents_={};path_.clear();hash_.clear();
        if(!parents_.Open(root,path))return {};
        mfg::file::Handle file(CreateFileW(path.c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,nullptr));
        LARGE_INTEGER size{};
        if(!file||!mfg::file::Regular(file.value)||!mfg::file::Equal(mfg::file::Final(file.value),path)||
           !GetFileSizeEx(file.value,&size)||size.QuadPart<=0||uint64_t(size.QuadPart)>8ull*1024*1024*1024)return {};
        BCRYPT_ALG_HANDLE algorithm=nullptr;BCRYPT_HASH_HANDLE hash=nullptr;bool okay=false;
        if(BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,nullptr,0)<0)return {};
        if(BCryptCreateHash(algorithm,&hash,nullptr,0,nullptr,0,0)>=0){
            char buffer[65536];DWORD got=0;uint64_t total=0;okay=true;
            for(;;){if(!ReadFile(file.value,buffer,sizeof(buffer),&got,nullptr)){okay=false;break;}if(!got)break;
                total+=got;if(total>uint64_t(size.QuadPart)||BCryptHashData(hash,reinterpret_cast<PUCHAR>(buffer),got,0)<0){okay=false;break;}}
            UCHAR digest[32]{};okay=okay&&total==uint64_t(size.QuadPart)&&BCryptFinishHash(hash,digest,sizeof(digest),0)>=0;
            if(okay){const char* hex="0123456789ABCDEF";for(auto byte:digest){hash_+=hex[byte>>4];hash_+=hex[byte&15];}}
            BCryptDestroyHash(hash);
        }
        BCryptCloseAlgorithmProvider(algorithm,0);
        if(!okay){hash_.clear();return {};}
        path_=path;handle_=std::move(file);return hash_;
    }
};
}
