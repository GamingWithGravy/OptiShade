#pragma once
#include "HardwareTelemetry.h"
namespace optishade::hardware {
enum class Detail { Simple=0, Normal=1, Advanced=2 };
inline Detail ClampDetail(unsigned value){return value<=2?static_cast<Detail>(value):Detail::Simple;}
inline bool ShowReading(const Reading& row,Detail detail,unsigned vendor=0){
 const auto& key=row.label;
 if(key.rfind("NVIDIA GPU",0)==0&&vendor!=0x10de)return false;
 if(key.rfind("AMD GPU",0)==0&&vendor!=0x1002)return false;
 // This legacy counter aggregates adapters, so never label it as the main GPU.
 if(key=="Windows GPU busiest engine")return false;
 if(key.find("GPU name")!=std::string::npos)return false;
 if(detail==Detail::Advanced)return true;
 if(key=="CPU temperature"||key=="CPU usage"||key=="CPU reported clock"||key=="RAM usage"||
    key.find("GPU temperature")!=std::string::npos||key.find("GPU usage")!=std::string::npos||
    key.find("GPU core clock")!=std::string::npos)return true;
 return detail==Detail::Normal&&row.available&&(key=="RAM used"||key=="RAM total"||key.find(" VRAM ")!=std::string::npos);
}
}
