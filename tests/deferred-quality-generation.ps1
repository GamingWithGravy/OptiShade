$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
$source=[IO.File]::ReadAllText((Join-Path $root 'optiscaler/OptiScaler/shaders/dlssnr/DlssNr_DeferredSr.inl'))
$start=$source.IndexOf('const bool sameGenerationContract = current &&')
$finish=$source.IndexOf('retired.push_back(std::move(current));',$start)
if($start -lt 0 -or $finish -lt $start){throw 'Production generation-retirement block not found'}
$block=$source.Substring($start,$finish-$start+'retired.push_back(std::move(current));'.Length)
$fixture=@'
#include <windows.h>
#include <memory>
#include <vector>
#include <cassert>
#include <cstdio>
#include "DeferredSrQuality.h"
namespace optishade { void* ReShadeDeviceIdentity(void* p){return p;} }
struct Flag { bool value_or_default()const{return false;} };
struct Config { Flag DlssNrResidualFgApproxCamera; } cfg;
struct Device { unsigned releases=0;void Release(){++releases;} } deviceObject;
struct Extent { unsigned width=1920,height=1080; };
struct Desc { unsigned Width=1920,Height=1080; int Format=28; } inDesc,outDesc;
struct Generation {
 void* device=reinterpret_cast<void*>(1);void* queue=reinterpret_cast<void*>(2);
 unsigned w=1920,h=1080,outW=1920,outH=1080,flags=0;
 int inputFormat=28,outputFormat=28;
 NVSDK_NGX_PerfQuality_Value quality=NVSDK_NGX_PerfQuality_Value_MaxQuality;
 bool qualityAuthoritative=true;const void* qualityCaller=reinterpret_cast<void*>(3);
 bool halfRequested=false,sampleAndHold=false,approximateCamera=false,failed=true;
};
int main(){
 std::unique_ptr<Generation> current=std::make_unique<Generation>();
 std::vector<std::unique_ptr<Generation>> retired;
 void* deviceIdentity=current->device;void* ownerQueue=current->queue;
 Device* device=&deviceObject;const void* source=current->qualityCaller;
 auto active=std::make_unique<Extent>();unsigned flags=0;
 bool wantsHalf=false,sampleAndHold=false;
 unsigned sourceQuality=2;NVSDK_NGX_PerfQuality_Value effective=NVSDK_NGX_PerfQuality_Value_MaxPerf;
 bool rejected=false;auto rejectContract=[&](const char*){rejected=true;};
 auto retire=[&](){ __PRODUCTION__ effective=*privateQuality; };
 retire();assert(current&&retired.empty());
 // Creation-only quality may be absent on alternate evaluation maps. The
 // authoritative Quality contract must not oscillate with inferred DLAA.
 for(unsigned i=0;i<10000;++i){
  sourceQuality=i%2?2:optishade::deferred_quality::Unknown;
  retire();assert(current&&retired.empty()&&effective==NVSDK_NGX_PerfQuality_Value_MaxQuality);
 }
 // Same device, formats and dimensions: Quality -> DLAA must retire even a
 // failed old private feature so a fresh generation can be created.
 sourceQuality=5;
 retire();assert(!current&&retired.size()==1&&retired[0]->failed);
 current=std::make_unique<Generation>();current->quality=effective;
 retire();assert(current&&retired.size()==1);
 // Known DLAA -> absent creation quality at 1:1 keeps the same valid mode.
 sourceQuality=optishade::deferred_quality::Unknown;
 retire();assert(current&&retired.size()==1);
 // A later Quality request changes the generation again. Old objects are
 // retained in the production retirement list, never immediately destroyed.
 sourceQuality=2;
 retire();assert(!current&&retired.size()==2);
 // No previous authoritative mode may cross a changed extent or owner.
 current=std::make_unique<Generation>();sourceQuality=optishade::deferred_quality::Unknown;
 active->width=1280;active->height=720;
 retire();assert(!current&&retired.size()==3&&effective==NVSDK_NGX_PerfQuality_Value_MaxPerf);
 current=std::make_unique<Generation>();active->width=1920;active->height=1080;
 deviceIdentity=reinterpret_cast<void*>(11);
 retire();assert(!current&&retired.size()==4&&effective==NVSDK_NGX_PerfQuality_Value_DLAA);
 current=std::make_unique<Generation>();deviceIdentity=current->device;ownerQueue=reinterpret_cast<void*>(12);
 retire();assert(!current&&retired.size()==5&&effective==NVSDK_NGX_PerfQuality_Value_DLAA);
 current=std::make_unique<Generation>();ownerQueue=current->queue;source=reinterpret_cast<void*>(13);
 retire();assert(!current&&retired.size()==6&&effective==NVSDK_NGX_PerfQuality_Value_DLAA);
 // Initial/inferred modes do not acquire authority merely from dimensions.
 current=std::make_unique<Generation>();source=current->qualityCaller;current->qualityAuthoritative=false;
 retire();assert(!current&&retired.size()==7&&effective==NVSDK_NGX_PerfQuality_Value_DLAA);
 current=std::make_unique<Generation>();sourceQuality=77;
 retire();assert(rejected&&current&&retired.size()==7&&deviceObject.releases==1);
 puts("PASS: production predicate preserves omitted authoritative modes, changes true quality/owner/extents, retires failed generations and retains in-flight objects");
}
'@
$dir=Join-Path $root 'test-run/deferred-quality-generation'
[void][IO.Directory]::CreateDirectory($dir)
[IO.File]::WriteAllText((Join-Path $dir 'test.cpp'),$fixture.Replace('__PRODUCTION__',$block),[Text.UTF8Encoding]::new($false))
$command='@echo off'+"`r`n"+'call "'+$root+'\build-env.cmd" >nul'+"`r`n"+'if errorlevel 1 exit /b 1'+"`r`n"+
 'cl /nologo /std:c++17 /EHsc /W4 /I "'+$root+'\shared" /I "'+$root+'\optiscaler\external\nvngx_dlss_sdk" "'+$dir+'\test.cpp" /Fe:"'+$dir+'\test.exe" /Fo:"'+$dir+'\test.obj"'+"`r`n"+
 'if errorlevel 1 exit /b 1'+"`r`n"+'"'+$dir+'\test.exe"'+"`r`n"
$cmd=Join-Path $dir 'run.cmd';[IO.File]::WriteAllText($cmd,$command,[Text.Encoding]::ASCII)
& $cmd
if($LASTEXITCODE){throw 'Deferred quality-generation fixture failed'}
