#pragma once
#include <Windows.h>
#include <filesystem>
#include <map>
#include <string>
#include <mutex>
#include <fstream>
namespace optishade::session {
class Journal {
 std::mutex mutex;std::map<std::string,std::string> fields;std::filesystem::path path;
 uint64_t lastWrite=0,lastCriticalWrite=0,nrActivationCount=0,xp12BlockCount=0;std::string lastState,nrActivationHistory;bool lastPersistedProviderCallPending=false;
 bool xp12HasLatestBlock=false;std::string xp12LatestBlockReason,xp12LatestBlockApi;uint64_t xp12LatestBlockDevice=0,xp12LatestBlockOwner=0,xp12LatestBlockGeneration=0,xp12LatestBlockQueue=0;
 static std::string Quote(const std::string& value){std::string s="\"";for(unsigned char c:value){if(c=='\\'||c=='\"')s+='\\';if(c>=32)s+=char(c);}return s+'\"';}
 static std::string Utc(){SYSTEMTIME t{};GetSystemTime(&t);char b[40];sprintf_s(b,"%04u-%02u-%02uT%02u:%02u:%02u.%03uZ",t.wYear,t.wMonth,t.wDay,t.wHour,t.wMinute,t.wSecond,t.wMilliseconds);return b;}
 template<class Values> void PutImpl(const Values& values,bool critical,bool durable=false,bool resolveProviderCall=false){std::lock_guard lock(mutex);for(const auto& kv:values)fields[kv.first]=kv.second;
 if(path.empty())return;const auto now=GetTickCount64();const bool resolvingPending=resolveProviderCall&&lastPersistedProviderCallPending;if(!durable&&!resolvingPending){if(critical){if(lastCriticalWrite&&now-lastCriticalWrite<1000)return;}else if(lastWrite&&now-lastWrite<1000)return;}
  std::string state;for(const char* key:{"Requested","NRActivationAttemptCount","NRActivationHistory","NRActivationLastAction","NRActivationLastSource","NRActivationOutcome","XP12BridgeAdmissionStage","XP12BridgeFirstBlockReason","XP12BridgeLatestBlockReason","XP12BridgeLatestBlockUtc","XP12BridgeBlockCount","XP12BridgeBlockAPI","XP12BridgeBlockDevice","XP12BridgeBlockOwner","XP12BridgeBlockGeneration","XP12BridgeBlockQueue","API","Device","Generation","NRRoute","FGMode","FGControlPath","FGOptionsAcceptedMode","FGOptionsAcceptedAdditionalFrames","FGOptionsMaxAcceptedAdditionalFramesThisRun","FGSetOptionsObserved","FGSetOptionsCallCount","FGSetOptionsThreadId","FGSetOptionsViewport","FGSetOptionsInputStructVersion","FGSetOptionsInputMode","FGSetOptionsInputAdditionalFrames","FGSetOptionsForwardedMode","FGSetOptionsForwardedAdditionalFrames","FGSetOptionsProviderResult","FGSetOptionsExplicitRequest","FGSetOptionsRequestRevision","FGCapabilityProbe","FGProviderFunctionAvailable","FGProviderFunctionResult","FGProviderGraphicsApi","FGProviderMaxFramesPerStateIntervalThisRun","FGOutputVerification","FGStateQueryStage","FGStateResult","FGStateCallerModule","FGStateCallerModuleOffset","FGStateCallerThreadId","FGStateQueryCount","FGStateIntervalMs","FGStateAgeSincePresentMs","FGPresentSampleSource","FGPresentCallerThreadId","FGPresentSwapchainId","FGStateThreadMatchesLastPresent","FGPresentCallCount","FGPresentCallCountAtStateQuery","FGStateProviderFaulted","FGStateProviderExceptionCode","FGStateProviderExceptionAddress","FGStateProviderAccessOperation","FGStateProviderFaultAddress","XP12VulkanPresentQueue","XP12VulkanPresentDevice","XP12VulkanPresentWaitCount","XP12VulkanPresentWaitHandles","XP12VulkanPresentWaitHandlesCaptured","XP12VulkanPresentWaitHandlesTruncated","XP12VulkanPresentSwapchainCount","XP12VulkanPresentImages","XP12VulkanPresentGenerations","XP12VulkanPresentResults","XP12VulkanPresentGlobalResult","XP12VulkanPresentPerResultsKnown","XP12VulkanPresentHasPNext","XP12VulkanPresentTruncated","XP12VulkanPresentSnapshotValid","XP12VulkanAcquireApi","XP12VulkanAcquireResult","XP12VulkanAcquireDevice","XP12VulkanAcquireSwapchain","XP12VulkanAcquireSwapchainGeneration","XP12VulkanAcquireTimeout","XP12VulkanAcquireSemaphore","XP12VulkanAcquireFence","XP12VulkanAcquireDeviceMask","XP12VulkanAcquireHasPNext","XP12VulkanAcquireImageIndexValid","XP12VulkanAcquireImageIndex","TagMask","ContractStage","NRStage","SubmissionStage","GPUCompletion","XP12BridgeStage","LastFailure","NRStallState","NRStallReason","NRStallRepeatCount","NRStallDurationMs","NRStallFailedLatched","NRStallRetiredItems","NRStallSuccessfulDispatches","NRStallLastCompletedFrame","NRStallLastSubmittedFrame","NRStallCompletionAgeMs","NRStallFenceSignalFailed"})state+=fields[key]+"|";
 for(const char* key:{"XP12VulkanSubmitApi","XP12VulkanSubmitSource","XP12VulkanSubmitQueue","XP12VulkanSubmitFence","XP12VulkanSubmitResult","XP12VulkanSubmitBatchCount","XP12VulkanSubmitBatchesCaptured","XP12VulkanSubmitBatchSummary","XP12VulkanSubmitWaitCount","XP12VulkanSubmitWaitHandles","XP12VulkanSubmitWaitCaptured","XP12VulkanSubmitWaitDetails","XP12VulkanSubmitWaitDetailsTruncated","XP12VulkanSubmitSignalCount","XP12VulkanSubmitSignalHandles","XP12VulkanSubmitSignalCaptured","XP12VulkanSubmitSignalDetails","XP12VulkanSubmitSignalDetailsTruncated","XP12VulkanSubmitCommandCount","XP12VulkanSubmitCommandHandles","XP12VulkanSubmitCommandsCaptured","XP12VulkanSubmitHasPNext","XP12VulkanSubmitTruncated","XP12VulkanSubmitSnapshotValid","XP12VulkanSubmitObservedSinceWrite","XP12VulkanSubmitOmittedSinceWrite"})state+=fields[key]+"|";
 for(const char* key:{"XP12VulkanSyncEventSequence","XP12VulkanSyncEventsDropped","XP12VulkanSyncSemaphoreCreates","XP12VulkanSyncSemaphoreDestroys","XP12VulkanSyncFenceCreates","XP12VulkanSyncFenceDestroys","XP12VulkanSyncRecentEvents"})state+=fields[key]+"|";
 if(state==lastState&&lastWrite)return;
 fields["CapturedUtc"]=Utc();std::string json="{\n";bool first=true;for(const auto& kv:fields){if(!first)json+=",\n";first=false;json+=Quote(kv.first)+":"+Quote(kv.second);}json+="\n}\n";
 try{std::error_code ec;std::filesystem::create_directories(path.parent_path(),ec);auto temp=path;temp+=L".tmp";{std::ofstream out(temp,std::ios::binary|std::ios::trunc);out<<json;out.flush();if(!out)return;}if(MoveFileExW(temp.c_str(),path.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)){lastWrite=now;lastState=state;auto stage=fields.find("FGStateQueryStage");lastPersistedProviderCallPending=stage!=fields.end()&&stage->second=="Provider call pending";if(critical)lastCriticalWrite=now;}}catch(...){}
 }
public:
 void Configure(const std::filesystem::path& file,const std::string& simulator,const std::string& route){std::lock_guard lock(mutex);if(!path.empty())return;path=file;fields["Simulator"]=simulator;fields["RouteDLL"]=route;fields["PID"]=std::to_string(GetCurrentProcessId());FILETIME birth{},exit{},kernel{},user{};GetProcessTimes(GetCurrentProcess(),&birth,&exit,&kernel,&user);fields["ProcessBirthFileTime"]=std::to_string((uint64_t(birth.dwHighDateTime)<<32)|birth.dwLowDateTime);
  for(const char* key:{"API","Device","Generation","NRRoute","NRActivationAttemptCount","NRActivationHistory","NRActivationLastAction","NRActivationLastSource","NRActivationOutcome","XP12BridgeAdmissionStage","XP12BridgeFirstBlockReason","XP12BridgeLatestBlockReason","XP12BridgeLatestBlockUtc","XP12BridgeBlockCount","XP12BridgeBlockAPI","XP12BridgeBlockDevice","XP12BridgeBlockOwner","XP12BridgeBlockGeneration","XP12BridgeBlockQueue","FGMode","FGControlPath","FGOptionsAcceptedMode","FGOptionsAcceptedAdditionalFrames","FGOptionsMaxAcceptedAdditionalFramesThisRun","FGSetOptionsObserved","FGSetOptionsCallCount","FGSetOptionsThreadId","FGSetOptionsViewport","FGSetOptionsInputStructVersion","FGSetOptionsInputMode","FGSetOptionsInputAdditionalFrames","FGSetOptionsForwardedMode","FGSetOptionsForwardedAdditionalFrames","FGSetOptionsProviderResult","FGSetOptionsExplicitRequest","FGSetOptionsRequestRevision","FGCapabilityProbe","FGProviderFunctionAvailable","FGProviderFunctionResult","FGProviderObservedMaximum","FGProviderGraphicsApi","FGProviderMaxFramesPerStateIntervalThisRun","FGOutputVerification","FGStateQueryStage","FGStateResult","FGStateCallerModule","FGStateCallerModuleOffset","FGStateCallerThreadId","FGStateQueryCount","FGStateIntervalMs","FGStateAgeSincePresentMs","FGPresentSampleSource","FGPresentCallerThreadId","FGPresentSwapchainId","FGStateThreadMatchesLastPresent","FGPresentCallCount","FGPresentCallCountAtStateQuery","FGStateProviderFaulted","FGStateProviderExceptionCode","FGStateProviderExceptionAddress","FGStateProviderAccessOperation","FGStateProviderFaultAddress","XP12VulkanPresentQueue","XP12VulkanPresentDevice","XP12VulkanPresentWaitCount","XP12VulkanPresentWaitHandles","XP12VulkanPresentWaitHandlesCaptured","XP12VulkanPresentWaitHandlesTruncated","XP12VulkanPresentSwapchainCount","XP12VulkanPresentImages","XP12VulkanPresentGenerations","XP12VulkanPresentResults","XP12VulkanPresentGlobalResult","XP12VulkanPresentPerResultsKnown","XP12VulkanPresentHasPNext","XP12VulkanPresentTruncated","XP12VulkanPresentSnapshotValid","XP12VulkanAcquireApi","XP12VulkanAcquireResult","XP12VulkanAcquireDevice","XP12VulkanAcquireSwapchain","XP12VulkanAcquireSwapchainGeneration","XP12VulkanAcquireTimeout","XP12VulkanAcquireSemaphore","XP12VulkanAcquireFence","XP12VulkanAcquireDeviceMask","XP12VulkanAcquireHasPNext","XP12VulkanAcquireImageIndexValid","XP12VulkanAcquireImageIndex","LastStreamlineToken","LastPresentStartToken","TagMask","ContractStage","NRStage","SubmissionStage","GPUCompletion","XP12BridgeStage","LastFailure","LastSuccessfulTicket","NRStallState","NRStallReason","NRStallRepeatCount","NRStallDurationMs","NRStallFailedLatched","NRStallRetiredItems","NRStallSuccessfulDispatches","NRStallLastCompletedFrame","NRStallLastSubmittedFrame","NRStallCompletionAgeMs","NRStallFenceSignalFailed"})fields.try_emplace(key,"Not observed");
 for(const char* key:{"XP12VulkanSubmitApi","XP12VulkanSubmitSource","XP12VulkanSubmitQueue","XP12VulkanSubmitFence","XP12VulkanSubmitResult","XP12VulkanSubmitBatchCount","XP12VulkanSubmitBatchesCaptured","XP12VulkanSubmitBatchSummary","XP12VulkanSubmitWaitCount","XP12VulkanSubmitWaitHandles","XP12VulkanSubmitWaitCaptured","XP12VulkanSubmitWaitDetails","XP12VulkanSubmitWaitDetailsTruncated","XP12VulkanSubmitSignalCount","XP12VulkanSubmitSignalHandles","XP12VulkanSubmitSignalCaptured","XP12VulkanSubmitSignalDetails","XP12VulkanSubmitSignalDetailsTruncated","XP12VulkanSubmitCommandCount","XP12VulkanSubmitCommandHandles","XP12VulkanSubmitCommandsCaptured","XP12VulkanSubmitHasPNext","XP12VulkanSubmitTruncated","XP12VulkanSubmitSnapshotValid","XP12VulkanSubmitObservedSinceWrite","XP12VulkanSubmitOmittedSinceWrite"})fields.try_emplace(key,"Not observed");
 for(const char* key:{"XP12VulkanSyncEventSequence","XP12VulkanSyncEventsDropped","XP12VulkanSyncSemaphoreCreates","XP12VulkanSyncSemaphoreDestroys","XP12VulkanSyncFenceCreates","XP12VulkanSyncFenceDestroys","XP12VulkanSyncRecentEvents"})fields.try_emplace(key,"Not observed");}
 void Put(std::initializer_list<std::pair<const std::string,std::string>> values){PutImpl(values,false);}
 void Put(const std::map<std::string,std::string>& values){PutImpl(values,false);}
 // A normal callback completion supersedes a previously persisted pending
 // marker immediately. This closes the shutdown race where the session file
 // otherwise remained "pending" for up to the ordinary one-second write cap.
 void PutResolvedProviderCall(std::initializer_list<std::pair<const std::string,std::string>> values){PutImpl(values,false,false,true);}
 void PutResolvedProviderCall(const std::map<std::string,std::string>& values){PutImpl(values,false,false,true);}
 // Persist rare pre-provider anomalies immediately. Ordinary per-frame state
 // remains rate limited; critical snapshots are also capped at one per second.
 void PutCritical(std::initializer_list<std::pair<const std::string,std::string>> values){PutImpl(values,true);}
 void PutCritical(const std::map<std::string,std::string>& values){PutImpl(values,true);}
 void RecordNRActivation(bool enabled,const std::string& source,const std::string& outcome=""){
  std::map<std::string,std::string> event;
  {
   std::lock_guard lock(mutex);
   ++nrActivationCount;
   const std::string item=Utc()+" "+(enabled?"On":"Off")+" source="+source;
   if(!nrActivationHistory.empty())nrActivationHistory+="; ";
   nrActivationHistory+=item;
   while(nrActivationHistory.size()>1800){const auto split=nrActivationHistory.find("; ");if(split==std::string::npos){nrActivationHistory.erase(0,nrActivationHistory.size()-1800);break;}nrActivationHistory.erase(0,split+2);}
   fields["NRActivationAttemptCount"]=std::to_string(nrActivationCount);
   fields["NRActivationHistory"]=nrActivationHistory;
   fields["NRActivationLastAction"]=enabled?"On":"Off";
   fields["NRActivationLastSource"]=source;
   fields["NRActivationOutcome"]=outcome.empty()?(enabled?"Applied to runtime configuration; awaiting eligible NR processing":"Deactivation applied to runtime configuration"):outcome;
   event={{"NRActivationAttemptCount",fields["NRActivationAttemptCount"]},{"NRActivationHistory",nrActivationHistory},{"NRActivationLastAction",fields["NRActivationLastAction"]},{"NRActivationLastSource",source},{"NRActivationOutcome",fields["NRActivationOutcome"]}};
   if(fields["Simulator"]=="X-Plane.exe"){
    fields["XP12BridgeAdmissionStage"]=enabled?"NR enabled; waiting for XP12 Vulkan route admission":"NR disabled by latest explicit action";
    xp12BlockCount=0;fields["XP12BridgeFirstBlockReason"]="Not observed";fields["XP12BridgeLatestBlockReason"]="Not observed";fields["XP12BridgeLatestBlockUtc"]="Not observed";fields["XP12BridgeBlockCount"]="0";
    xp12HasLatestBlock=false;xp12LatestBlockReason.clear();xp12LatestBlockApi.clear();xp12LatestBlockDevice=xp12LatestBlockOwner=xp12LatestBlockGeneration=xp12LatestBlockQueue=0;
    fields["XP12BridgeBlockAPI"]="Not observed";fields["XP12BridgeBlockDevice"]="Not observed";
    fields["XP12BridgeBlockOwner"]="Not observed";fields["XP12BridgeBlockGeneration"]="Not observed";fields["XP12BridgeBlockQueue"]="Not observed";
    for(const char* key:{"XP12BridgeAdmissionStage","XP12BridgeFirstBlockReason","XP12BridgeLatestBlockReason","XP12BridgeLatestBlockUtc","XP12BridgeBlockCount","XP12BridgeBlockAPI","XP12BridgeBlockDevice","XP12BridgeBlockOwner","XP12BridgeBlockGeneration","XP12BridgeBlockQueue"})event[key]=fields[key];
   }
  }
  PutImpl(event,false,true);
 }
 bool RecordXP12BridgeBlock(const std::string& reason,const std::string& api,uint64_t device,uint64_t owner,uint64_t generation,uint64_t queue){
  std::map<std::string,std::string> event;bool first=false;
  {
   std::lock_guard lock(mutex);
   if(fields["Simulator"]!="X-Plane.exe"||fields["NRActivationLastAction"]!="On")return false;
   first=fields["XP12BridgeFirstBlockReason"]=="Not observed";
   if(first){fields["XP12BridgeAdmissionStage"]="Blocked before NR frame submission";fields["XP12BridgeFirstBlockReason"]=reason;}
   const bool changed=!xp12HasLatestBlock||xp12LatestBlockReason!=reason||xp12LatestBlockApi!=api||xp12LatestBlockDevice!=device||xp12LatestBlockOwner!=owner||xp12LatestBlockGeneration!=generation||xp12LatestBlockQueue!=queue;
   if(!changed)return false;
   xp12HasLatestBlock=true;xp12LatestBlockReason=reason;xp12LatestBlockApi=api;xp12LatestBlockDevice=device;xp12LatestBlockOwner=owner;xp12LatestBlockGeneration=generation;xp12LatestBlockQueue=queue;
   fields["XP12BridgeLatestBlockReason"]=reason;fields["XP12BridgeLatestBlockUtc"]=Utc();fields["XP12BridgeBlockCount"]=std::to_string(++xp12BlockCount);
   fields["XP12BridgeAdmissionStage"]="Blocked before NR frame submission";
   if(first){fields["XP12BridgeBlockAPI"]=api;fields["XP12BridgeBlockDevice"]=std::to_string(device);fields["XP12BridgeBlockOwner"]=std::to_string(owner);
    fields["XP12BridgeBlockGeneration"]=std::to_string(generation);fields["XP12BridgeBlockQueue"]=std::to_string(queue);}
   for(const char* key:{"XP12BridgeAdmissionStage","XP12BridgeFirstBlockReason","XP12BridgeLatestBlockReason","XP12BridgeLatestBlockUtc","XP12BridgeBlockCount","XP12BridgeBlockAPI","XP12BridgeBlockDevice","XP12BridgeBlockOwner","XP12BridgeBlockGeneration","XP12BridgeBlockQueue"})event[key]=fields[key];
  }
  PutImpl(event,true,true);return first;
 }
};
inline Journal& State(){static Journal journal;return journal;}
}
