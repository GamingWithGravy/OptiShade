// Generated from shared/provider-policy.json; do not edit.
#pragma once
#include <string_view>
namespace optishade::policy {
inline constexpr unsigned Version=1;
inline const char* Select(std::string_view channel,unsigned family,bool sourceReceipt,bool legacyReceipt,bool supportedGame,bool ambiguous,bool sourceAvailable,bool legacyAvailable,bool sm86Available=true,bool sm86Receipt=false){
if(!supportedGame)return "unsupported_game";
if(ambiguous)return "ambiguous_adapter";
if((sourceReceipt&&legacyReceipt)||(sm86Receipt&&(sourceReceipt||legacyReceipt)))return "conflicting_receipts";
if(sm86Receipt)return (family==20||family==30)?(sm86Available?"sm86":"payload_missing"):"receipt_adapter_mismatch";
if(legacyReceipt&&channel=="beta"&&family==40)return sourceAvailable?"source":"payload_missing";
if(sourceReceipt){if(!(family==20||family==30||family==40))return "receipt_adapter_mismatch";
if(channel=="beta"&&family==20)return sm86Available?"sm86":"payload_missing";
if(channel=="beta"&&family==30)return sm86Available?"sm86":"payload_missing";
if(channel=="stable"&&family==20)return sm86Available?"sm86":"payload_missing";
if(channel=="stable"&&family==30)return sm86Available?"sm86":"payload_missing";
return sourceAvailable?"source":"payload_missing";}
if(legacyReceipt)return (family==40)?(legacyAvailable?"legacy":"payload_missing"):"receipt_adapter_mismatch";
if(channel=="beta"){
if(family==20)return (sm86Available?"sm86":"payload_missing");
if(family==30)return (sm86Available?"sm86":"payload_missing");
if(family==40)return (sourceAvailable?"source":"payload_missing");
if(family==50)return "native";
return "none";}
if(channel=="stable"){
if(family==20)return (sm86Available?"sm86":"payload_missing");
if(family==30)return (sm86Available?"sm86":"payload_missing");
if(family==40)return (legacyAvailable?"legacy":"payload_missing");
if(family==50)return "native";
return "none";}
return "unsupported_channel";}
inline bool AllowsSourceFamily(unsigned family){return family==20||family==30||family==40;}
}
