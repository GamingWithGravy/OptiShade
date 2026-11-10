// OptiShade additions, GPL-3.0-or-later.
#pragma once
#include "MfgControl.h"
#include "NeuralModelPolicy.generated.h"

namespace optishade::neural_receipt {
inline bool EqualAscii(std::string_view a,std::string_view b){
    if(a.size()!=b.size())return false;
    for(size_t i=0;i<a.size();++i){const auto lower=[](char c){return c>='A'&&c<='Z'?char(c-'A'+'a'):c;};if(lower(a[i])!=lower(b[i]))return false;}
    return true;
}
inline bool Hash(std::string_view value){
    if(value.size()!=64)return false;
    for(char c:value)if(!((c>='0'&&c<='9')||(c>='a'&&c<='f')||(c>='A'&&c<='F')))return false;
    return true;
}
struct Facts {std::string executable,executableHash,architecture,modelHash;unsigned renderingFamily=0;};
struct Result {bool bound=false;const neural_policy::Model* model=nullptr;std::string reason;};
inline Result Validate(const mfg::Json& receipt,const Facts& facts){
    Result result;result.model=neural_policy::FindByHash(facts.modelHash);
    if(!result.model){result.reason="Selected model hash is outside the pinned catalog.";return result;}
    if(!neural_policy::AllowsFamily(*result.model,facts.renderingFamily)){
        result.reason="Selected model is not admitted for the measured rendering architecture.";return result;
    }
    uint32_t schema=0;std::string hash,exe,exeHash,architecture,variant,evidence;
    if(!mfg::U32(receipt,"schema",schema,1,1)||!mfg::String(receipt,"modelSha256",hash)||
       !mfg::String(receipt,"executable",exe)||!mfg::String(receipt,"executableSha256",exeHash)||
       !mfg::String(receipt,"architecture",architecture)||!mfg::String(receipt,"variant",variant)||
       !mfg::String(receipt,"evidence",evidence)||evidence!="inventory_candidate"||
       !Hash(hash)||!Hash(exeHash)||!Hash(facts.executableHash)||
       !EqualAscii(hash,facts.modelHash)||!EqualAscii(exeHash,facts.executableHash)||
       !EqualAscii(exe,facts.executable)||architecture!=facts.architecture||variant!=result.model->variant){
        result.reason="Model installation receipt does not match this executable, architecture and selected model.";return result;
    }
    // receipt.adapter is intentionally not runtime admission: LUIDs and game
    // GPU preferences can change after installation. The actual device wins.
    result.bound=true;result.reason="Pinned model and executable receipt matched; model creation and output remain runtime checks.";return result;
}
}
