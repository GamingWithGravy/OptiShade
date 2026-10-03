// OptiShade integration contract, GPL-3.0-or-later.
#pragma once
#ifndef OPTISHADE_SOURCE_MFG_API_H
#define OPTISHADE_SOURCE_MFG_API_H
#include <windows.h>
#include <cstdint>
namespace optishade::mfg::source {
inline constexpr uint32_t Abi=0x00020000;
// Family labels are explicit; these are NOT the legacy RTXMFG-v40 values.
struct Status {
 uint32_t size=sizeof(Status),abi=Abi,pid=0,family=0;
 uint64_t birth=0,tick=0,device=0,luid=0,deviceGeneration=0,feature=0;
 uint64_t requestRevision=0,acceptedRevision=0,lastAcceptedTick=0;
 uint32_t savedRevision=0,acceptedSavedRevision=0,maximum=0,minimum=2;
 uint32_t ready=0,gameFg=0,accepted=0,dynamicAvailable=0,restartRequired=0;
 uint32_t follow=1,dynamic=0,multiplier=2,target=0,overrideOff=0;
 uint32_t acceptedMultiplier=0,acceptedDynamic=0,framesObserved=0;
 uint64_t observationAge=UINT64_MAX;
 uint64_t routeGeneration=0,viewGeneration=0,presentationTarget=0,targetGeneration=0,ownerEpoch=0;
 uint32_t view=0,ownership=0;
 char reason[200]{};
};
using Query=BOOL(WINAPI*)(Status*,uint32_t);
using Start=BOOL(WINAPI*)();
}

#endif
