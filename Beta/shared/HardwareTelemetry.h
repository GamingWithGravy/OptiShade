#pragma once
#include <string>
#include <vector>
#include <cmath>
#include <charconv>
#include <cstdint>
namespace optishade::hardware {
struct Reading { std::string label; float temperature; bool available; std::string unit="C"; std::string text; };
class Stream {
    std::string pending; std::vector<Reading> frame; bool active=false;
public:
    std::vector<Reading> readings; uint64_t updated=0; std::string providerStatus;
    void Reset(){pending.clear();frame.clear();readings.clear();active=false;updated=0;providerStatus.clear();}
    bool Fresh(uint64_t now)const{return updated&&now>=updated&&now-updated<=6000;}
    void Feed(const char* bytes,size_t length,uint64_t now){
        if(pending.size()+length>8192){Reset();return;}
        pending.append(bytes,length);size_t end;
        while((end=pending.find('\n'))!=std::string::npos){
            auto line=pending.substr(0,end);pending.erase(0,end+1);
            if(!line.empty()&&line.back()=='\r')line.pop_back();
            if(line.rfind("STATUS\t",0)==0){auto status=line.substr(7);bool clean=status.size()<=160;for(unsigned char c:status)if(c<32)clean=false;if(clean)providerStatus=status;continue;}
            if(line=="BEGIN"){frame.clear();active=true;continue;}
            if(line=="END"){if(active&&!frame.empty()){readings=frame;updated=now;}active=false;continue;}
            if(!active)continue;
            auto tab=line.find('\t');
            if(tab==std::string::npos||tab==0||tab>160||frame.size()>=64){active=false;continue;}
            auto label=line.substr(0,tab),value=line.substr(tab+1);std::string unit="C";
            auto unitTab=value.find('\t');if(unitTab!=std::string::npos){unit=value.substr(unitTab+1);value.resize(unitTab);}
            if(unit=="text"){bool clean=!value.empty()&&value.size()<=160;for(unsigned char c:value)if(c<32)clean=false;for(unsigned char c:label)if(c<32)clean=false;if(!clean){active=false;continue;}frame.push_back({label,0,false,unit,value});continue;}
            if(unit!="C"&&unit!="%"&&unit!="MHz"&&unit!="GB"&&unit!="GiB"&&unit!="W"&&unit!="RPM"){active=false;continue;}
            float maximum=unit=="C"?150.f:unit=="%"?100.f:1000000.f;
            bool validLabel=true;for(unsigned char c:label)if(c<32)validLabel=false;
            if(!validLabel){active=false;continue;}
            if(value=="-"){frame.push_back({label,0,false});continue;}
            float number=0;auto parsed=std::from_chars(value.data(),value.data()+value.size(),number);
            if(value.empty()||parsed.ec!=std::errc()||parsed.ptr!=value.data()+value.size()||!std::isfinite(number)||number<0||number>maximum){active=false;continue;}
            frame.push_back({label,number,true,unit});
        }
    }
};
}

