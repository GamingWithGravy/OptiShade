// OptiShade additions, GPL-3.0-or-later.
#pragma once
#include <string_view>
#include <string>
namespace optishade::gpu_policy {
// Matches the manager's invariant VS_FIXEDFILEINFO tuple for system nvcuda.dll.
// CUDA API level alone cannot distinguish driver patch revisions.
inline std::string DriverFileIdentity(unsigned major,unsigned minor,unsigned build,unsigned privatePart){
    if(major>65535||minor>65535||build>65535||privatePart>65535||!(major||minor||build||privatePart))return {};
    return "nvcuda-file:"+std::to_string(major)+"."+std::to_string(minor)+"."+
        std::to_string(build)+"."+std::to_string(privatePart);
}
inline bool RtxProduct(std::string_view name){
    const auto word=[](char c){return (c>='A'&&c<='Z')||(c>='a'&&c<='z')||(c>='0'&&c<='9')||c=='_';};
    for(size_t i=0;i+3<=name.size();++i){const auto upper=[](char c){return c>='a'&&c<='z'?char(c-'a'+'A'):c;};
        if(upper(name[i])=='R'&&upper(name[i+1])=='T'&&upper(name[i+2])=='X'&&
           (!i||!word(name[i-1]))&&(i+3==name.size()||!word(name[i+3])))return true;}
    return false;
}
inline unsigned Family(std::string_view name,unsigned major,unsigned minor){
    // Names exclude GTX/non-RTX products; numeric product names never choose
    // an architecture. The supplied compute capability must be LUID matched.
    if(!RtxProduct(name))return 0;
    return major==7&&minor==5?20:major==8&&minor==6?30:
        major==8&&minor==9?40:major==12&&minor==0?50:0;
}
}
