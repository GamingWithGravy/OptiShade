#include "ViewFamily.h"
#include "OutputDomain.h"
#include "BackgroundStatus.h"
#include "ReadinessTrace.h"
#include "MenuGeometry.h"
#include "NativeFgLifetime.h"
#include "NrMemoryBudget.h"
#include "EffectsSyncPolicy.h"
#include "MfgDraft.h"
#include "NativeMfgControl.h"
#include "NativeFgStateQuery.h"
#include "../../Beta/shared/BackendSelection.h"
#include "../../Beta/reshade/source/optishade_cockpit_controls.hpp"
#include "../../Beta/optiscaler/OptiScaler/hooks/StreamlineOptionsSnapshot.h"
#include "../../Beta/optiscaler/OptiScaler/fsr4/FSR4PresetPolicy.h"
#include "../../Beta/optiscaler/OptiScaler/upscalers/fsr31/FSR31DefaultTuning.h"
#include <cstdio>
#include <iostream>
#include <stdexcept>
#include <atomic>
#include <condition_variable>
#include <vector>
#include <cmath>
static unsigned checks=0;
#define CHECK(x) do{++checks;if(!(x))throw std::runtime_error(std::string(#x)+" @"+std::to_string(__LINE__));}while(0)
template<class F> void until(F f){for(unsigned n=0;n<3000;++n){if(f())return;std::this_thread::sleep_for(std::chrono::milliseconds(1));}throw std::runtime_error("test deadline");}
int main(){try{
 {using optishade::fsr4::CorrectPreset;
  CHECK(CorrectPreset(0,1289,1000,false,4)==0);
  CHECK(CorrectPreset(0,1290,1000,false,4)==1);
  CHECK(CorrectPreset(0,1490,1000,false,4)==1);
  CHECK(CorrectPreset(1,2000,1000,false,4)==1);
  CHECK(CorrectPreset(3,2000,1000,false,4)==3);
  CHECK(CorrectPreset(0,0,1000,false,4)==0);
  CHECK(CorrectPreset(0,2000,0,false,4)==0);
  CHECK(CorrectPreset(0,1000,1000,true,4)==4);
 }
 {using optishade::fsr31::DefaultTuning;using optishade::fsr31::TryCalculateDefaultTuning;
  DefaultTuning tuning{};
  CHECK(TryCalculateDefaultTuning(3840,2160,2560,1440,tuning));
  CHECK(std::abs(tuning.velocity-0.5f)<0.0001f);
  CHECK(std::abs(tuning.reactiveScale-0.25f)<0.0001f);
  CHECK(std::abs(tuning.shadingScale-(0.5f/1.5f))<0.0001f);
  CHECK(std::abs(tuning.accumulationPerFrame-0.15f)<0.0001f);
  CHECK(std::abs(tuning.minimumDisocclusionAccumulation-0.075f)<0.0001f);
  CHECK(TryCalculateDefaultTuning(3840,1600,2560,1440,tuning));
  CHECK(std::abs(tuning.shadingScale-(0.5f/1.5f))<0.0001f);
  CHECK(!TryCalculateDefaultTuning(3840,2160,0,1440,tuning));
  CHECK(!TryCalculateDefaultTuning(0,2160,2560,1440,tuning));
  CHECK(std::abs(tuning.shadingScale-(0.5f/1.5f))<0.0001f);
 }
 {struct Adapter{unsigned vendor;bool dlssCapable;};
  const Adapter hybrid[]={{0x1002,false},{0x10de,true}};
  const Adapter amdOnly[]={{0x1002,false}};
  const Adapter unsupportedNvidia[]={{0x10de,false}};
  auto eligible=[](const Adapter& a){return a.vendor==0x10de&&a.dlssCapable;};
  CHECK(optishade::HasEligibleAdapter(hybrid,eligible));CHECK(!optishade::HasEligibleAdapter(amdOnly,eligible));
  CHECK(!optishade::HasEligibleAdapter(unsupportedNvidia,eligible));
  auto nvidia=[](const Adapter& a){return a.vendor==0x10de;};
  CHECK(!optishade::ShouldSubstituteFakeNvApi(true,hybrid,nvidia));
  CHECK(optishade::ShouldSubstituteFakeNvApi(true,amdOnly,nvidia));
  CHECK(!optishade::ShouldSubstituteFakeNvApi(true,unsupportedNvidia,nvidia));
  CHECK(!optishade::ShouldSubstituteFakeNvApi(true,std::vector<Adapter>{},nvidia));
  CHECK(!optishade::ShouldSubstituteFakeNvApi(false,amdOnly,nvidia));
 }
 {struct Luid{int HighPart;unsigned LowPart;};struct Adapter{Luid luid;unsigned vendor;bool dlssCapable;};
  const std::vector<Adapter> hybrid={{Luid{1,0},0x1002,false},{Luid{2,0},0x10de,true}};
  const Luid renderingLuid{2,0};
  const auto* renderer=optishade::FindRenderingAdapter(hybrid,renderingLuid);
  CHECK(renderer&&renderer->vendor==0x10de&&renderer->dlssCapable);
  CHECK(optishade::FindRenderingAdapter(hybrid,Luid{3,0})==nullptr);
 }
 using namespace optishade;
 {views::View family[]={{1,200,100,1,0,0,0,80,100},{1,200,100,1,0,80,0,200,100}};views::Layout layout;
 CHECK(views::Build(family,2,layout)&&layout.direct);CHECK(layout.packed[0].right==80&&layout.packed[1].left==80&&layout.packed[1].right==200);
 family[1].left=79;CHECK(!views::Build(family,2,layout));family[1]={1,200,100,2,1,0,0,200,100};family[0]={1,200,100,2,0,0,0,200,100};
 CHECK(views::Build(family,2,layout)&&!layout.direct&&layout.width==400);family[1].layer=2;CHECK(!views::Build(family,2,layout));
 CHECK(!views::Build(family,17,layout));
 }

 {route::OutputDirectory directory;route::OutputStorage<int> values;
 auto a=directory.FindOrAdd({1,10,2,0,1});auto eye=directory.FindOrAdd({1,10,2,1,1});
 auto otherDevice=directory.FindOrAdd({2,10,2,0,1});auto recreated=directory.FindOrAdd({1,10,3,0,1});
 CHECK(a!=eye&&a!=otherDevice&&a==recreated);values.Get(a)=42;values.Get(eye)=7;
 CHECK(values.Get(a)==42&&values.Get(eye)==7&&values.Get(recreated)==42);
 CHECK(directory.FindOrAdd({1,10,2,0,1})==route::OutputDirectory::Capacity);
 CHECK(directory.FindOrAdd({0,10,2,0,1})==route::OutputDirectory::Capacity);
 for(unsigned i=0;i<route::OutputDirectory::Capacity*2;++i)directory.FindOrAdd({1,100+i,1,0,1});
 CHECK(directory.FindOrAdd({1,999,1,0,1})==route::OutputDirectory::Capacity);
 CHECK(directory.FindOrAdd({1,10,3,0,1})==a&&values.Get(a)==42);
 }

 {
  sl::DLSSGState caller{};caller.structVersion=1;
  // Sentinel in the first member beyond v1 catches accidental full-object copy.
  caller.numFramesToGenerateMax=0xdeadbeef;
  native_mfg::StateQueryEvidence evidence;int calls=0;
  auto modern=[&](const sl::ViewportHandle&,sl::DLSSGState& out,const sl::DLSSGOptions*){
   ++calls;CHECK(out.structVersion==1||out.structVersion==2);
   if(out.structVersion>=2)out.numFramesToGenerateMax=3;
   out.numFramesActuallyPresented=9;out.estimatedVRAMUsageInBytes=128;return sl::Result::eOk;
  };
  CHECK(native_mfg::QueryNativeState(modern,true,sl::ViewportHandle(7),caller,nullptr,evidence)==sl::Result::eOk);
  CHECK(calls==1&&!evidence.promoted&&evidence.maximum==0);
  CHECK(caller.structVersion==1&&caller.numFramesActuallyPresented==9&&caller.estimatedVRAMUsageInBytes==128);
  CHECK(caller.numFramesToGenerateMax==0xdeadbeef);
  calls=0;
  auto old=[&](const sl::ViewportHandle&,sl::DLSSGState& out,const sl::DLSSGOptions*){
   ++calls;if(out.structVersion==2)return sl::Result::eErrorUnsupportedInterface;
   CHECK(out.structVersion==1);out.numFramesActuallyPresented=2;return sl::Result::eOk;
  };
  CHECK(native_mfg::QueryNativeState(old,true,sl::ViewportHandle(7),caller,nullptr,evidence)==sl::Result::eOk);
  CHECK(calls==1&&!evidence.promoted&&evidence.maximum==0&&caller.numFramesActuallyPresented==2);
  calls=0;
  auto failing=[&](const sl::ViewportHandle&,sl::DLSSGState&,const sl::DLSSGOptions*){++calls;return sl::Result::eErrorDeviceNotCreated;};
  CHECK(native_mfg::QueryNativeState(failing,true,sl::ViewportHandle(7),caller,nullptr,evidence)==sl::Result::eErrorDeviceNotCreated);
  CHECK(calls==1&&evidence.maximum==0);
  calls=0;CHECK(native_mfg::QueryNativeState(old,false,sl::ViewportHandle(7),caller,nullptr,evidence)==sl::Result::eOk);CHECK(calls==1);
  sl::DLSSGState extension{};caller.next=&extension;calls=0;
  CHECK(native_mfg::QueryNativeState(old,true,sl::ViewportHandle(7),caller,nullptr,evidence)==sl::Result::eOk);
  CHECK(calls==1&&caller.next==&extension&&!evidence.promoted);
  caller.next=nullptr;caller.structVersion=2;calls=0;
  CHECK(native_mfg::QueryNativeState(modern,true,sl::ViewportHandle(7),caller,nullptr,evidence)==sl::Result::eOk);
  CHECK(calls==1&&!evidence.promoted&&evidence.maximum==3);
 }

 {
  native_mfg::CapabilitySnapshot cached{5,7,true,false,true};
  sl::DLSSGState caller{};caller.structVersion=4;
  caller.numFramesActuallyPresented=99;
  caller.inputsProcessingCompletionFence=reinterpret_cast<void*>(uintptr_t(0x1234));
  caller.lastPresentInputsProcessingCompletionFenceValue=55;
  CHECK(native_mfg::PopulateCachedCapabilityState(caller,cached,7));
  CHECK(caller.status==sl::DLSSGStatus::eOk&&caller.numFramesToGenerateMax==5);
  CHECK(caller.numFramesActuallyPresented==0&&caller.inputsProcessingCompletionFence==nullptr);
  CHECK(caller.lastPresentInputsProcessingCompletionFenceValue==0);
  CHECK(caller.bIsDynamicMFGSupported==sl::eFalse);
  auto otherViewport=caller;CHECK(!native_mfg::PopulateCachedCapabilityState(otherViewport,cached,8));
  cached.known=false;CHECK(!native_mfg::PopulateCachedCapabilityState(caller,cached,7));
 }

 {native_mfg::Control control;CHECK(!control.Request(control.Read(),3));
 CHECK(native_mfg::ClassifyAvailability(false,false,native_mfg::GraphicsApi::Unknown,0)==native_mfg::AvailabilityReason::GraphicsApiUnknown);
 CHECK(native_mfg::ClassifyAvailability(false,false,native_mfg::GraphicsApi::Direct3D11,0)==native_mfg::AvailabilityReason::NoNativeProviderOnDirect3D11);
 CHECK(native_mfg::ClassifyAvailability(false,false,native_mfg::GraphicsApi::Direct3D12,0)==native_mfg::AvailabilityReason::NoNativeProviderOnDirect3D12);
 CHECK(native_mfg::ClassifyAvailability(false,false,native_mfg::GraphicsApi::Vulkan,0)==native_mfg::AvailabilityReason::NoNativeProviderOnVulkan);
 CHECK(native_mfg::ClassifyAvailability(true,true,native_mfg::GraphicsApi::Direct3D12,5)==native_mfg::AvailabilityReason::CompatibilityProviderOwns);
 CHECK(native_mfg::ClassifyAvailability(true,false,native_mfg::GraphicsApi::Direct3D12,1)==native_mfg::AvailabilityReason::TwoXOnly);
 CHECK(native_mfg::ClassifyAvailability(true,false,native_mfg::GraphicsApi::Direct3D12,5)==native_mfg::AvailabilityReason::Ready);
 CHECK(native_mfg::DynamicSupported(native_mfg::GraphicsApi::Direct3D12,true,true));
 CHECK(!native_mfg::DynamicSupported(native_mfg::GraphicsApi::Vulkan,true,true));
 CHECK(!native_mfg::DynamicSupported(native_mfg::GraphicsApi::Direct3D11,true,true));
 CHECK(!native_mfg::DynamicSupported(native_mfg::GraphicsApi::Unknown,true,true));
 CHECK(!native_mfg::DynamicSupported(native_mfg::GraphicsApi::Direct3D12,false,true));
 CHECK(!native_mfg::DynamicSupported(native_mfg::GraphicsApi::Direct3D12,true,false));
 CHECK(!native_mfg::ToggleEnabled(false,false,-1));CHECK(!native_mfg::ToggleEnabled(false,true,3));
 CHECK(!native_mfg::ToggleEnabled(true,false,3));CHECK(!native_mfg::ToggleEnabled(true,true,0));
 CHECK(!native_mfg::ToggleEnabled(true,true,-1));CHECK(native_mfg::ToggleEnabled(true,true,-1,1));CHECK(native_mfg::ToggleEnabled(true,true,3));
 control.Observe(123,7,3);auto baseline=control.Read();CHECK(control.Request(baseline,3));
 CHECK(!control.Request(baseline,1));CHECK(!control.Request(control.Read(),4));
 auto request=control.ForCall(123,7);CHECK(request.desired==3);
 control.Complete(request,3,38);CHECK(control.Read().pending);CHECK(control.Read().acceptedRevision==0);
 control.Complete(request,0,0);CHECK(control.Read().pending); // game Off cannot become accepted MFG
 control.Complete(request,3,0);CHECK(!control.Read().pending);CHECK(control.Read().acceptedGenerated==3);
 control.Complete(control.ForCall(999,7),5,0);CHECK(control.Read().acceptedGenerated==3);
 control.Observe(123,7,1);CHECK(control.Read().desired==-1);CHECK(control.Read().pending);CHECK(control.Read().withdrawn==3);
 baseline=control.Read();control.Observe(456,7,5);CHECK(!control.Request(baseline,1));
 CHECK(control.Read().desired==-1);CHECK(control.Read().acceptedGenerated==0);
 CHECK(control.Request(control.Read(),5)); // 6x only when reported, never by GPU name
 control.Observe(456,8,5);CHECK(control.Read().desired==-1); // separate viewport never inherits request
 CHECK(control.Request(control.Read(),3));
 control.Observe(456,8,0);CHECK(!control.Read().known&&control.Read().desired==-1&&control.Read().withdrawn==3);
 CHECK(control.ForCall(456,8).provider==0);CHECK(!control.Request(control.Read(),1));
 control.Observe(456,8,99);CHECK(!control.Read().known&&control.Read().maximum==0);
 control.Observe(456,8,3);CHECK(control.Read().desired==-1);CHECK(control.Request(control.Read(),2));CHECK(control.Read().withdrawn==-1);
 }

 {native_mfg::Control control;native_mfg::UiDraft draft;control.Observe(700,1,5);auto live=control.Read();draft.Observe(live);
 CHECK(draft.Stage(live,3));CHECK(draft.Submit(control,live));auto oldRequest=control.ForCall(700,1);CHECK(oldRequest.desired==3);
 auto expired=oldRequest;expired.pending=false;expired.sampledAt=native_mfg::Control::Now()-3001;
 CHECK(!native_mfg::Control::BoundToCall(expired,700,1,native_mfg::Control::Now()));expired.pending=true;
 CHECK(native_mfg::Control::BoundToCall(expired,700,1,native_mfg::Control::Now()));
 control.Observe(701,1,5);auto replacement=control.Read();CHECK(replacement.supersededPending&&replacement.supersededDesired==3);
 draft.Observe(replacement);CHECK(draft.conflict&&!draft.awaiting);
 draft.Discard(replacement);CHECK(!draft.conflict&&!draft.awaiting&&draft.generation==replacement.generation);
 control.Complete(oldRequest,3,0);CHECK(control.Read().acceptedRevision==0);
 }

 {CHECK(oscockpit::SupportedReport("Glass Cockpit DLSS Fix 0.8.0\nready"));
  CHECK(oscockpit::SupportedReport("Glass Cockpit DLSS Fix 0.8.3\nready"));
  CHECK(oscockpit::SupportedReport("Glass Cockpit DLSS Fix 0.8.4\nready"));
  CHECK(oscockpit::SupportedReport("Glass Cockpit DLSS Fix 0.8.30\nready"));
  CHECK(oscockpit::SupportedReport("Glass Cockpit DLSS Fix 1.0.3\nready"));
  CHECK(oscockpit::SupportedReport("Glass Cockpit DLSS Fix 1.0.4\nready"));
  CHECK(oscockpit::SupportedReport("Glass Cockpit DLSS Fix 99.12.100\nready"));
  CHECK(!oscockpit::SupportedReport("Other addon 1.0.4\nready"));
  CHECK(!oscockpit::SupportedReport("Glass Cockpit DLSS Fix \nready"));
  CHECK(!oscockpit::SupportedReport("Glass Cockpit DLSS Fix 1.0.4garbage\nready"));
 }

 {sl::DLSSGOptions source{},copy{};sl::DLSSGState extension{};source.next=&extension;
  for(size_t version=1;version<=5;++version){
   source.structVersion=version;source.mode=sl::DLSSGMode::eOn;source.numFramesToGenerate=3;
   CHECK(optishade::streamline_options::DlssgOptionsPrefixBytes(version)<=sizeof(source));
   CHECK(optishade::streamline_options::CopyKnownDlssgOptions(source,copy));
   CHECK(copy.structVersion==version&&copy.mode==sl::DLSSGMode::eOn&&copy.numFramesToGenerate==3&&copy.next==&extension);
  }
  source.structVersion=6;CHECK(!optishade::streamline_options::CopyKnownDlssgOptions(source,copy));
  source.structVersion=5;source.structType={};CHECK(!optishade::streamline_options::CopyKnownDlssgOptions(source,copy));
 }

 {sl::DLSSGOptions options{};options.mode=sl::DLSSGMode::eAuto;options.numFramesToGenerate=0;
  CHECK(!optishade::streamline_options::ApplyObservedMinimumFrameCount(options,0));
  CHECK(options.mode==sl::DLSSGMode::eAuto&&options.numFramesToGenerate==0);
  CHECK(optishade::streamline_options::ApplyObservedMinimumFrameCount(options,1));
  CHECK(options.mode==sl::DLSSGMode::eAuto&&options.numFramesToGenerate==1);
  options.mode=sl::DLSSGMode::eOn;options.numFramesToGenerate=0;
  CHECK(optishade::streamline_options::ApplyObservedMinimumFrameCount(options,3));
  CHECK(options.mode==sl::DLSSGMode::eOn&&options.numFramesToGenerate==1);
  options.numFramesToGenerate=2;CHECK(!optishade::streamline_options::ApplyObservedMinimumFrameCount(options,3));
  options.mode=sl::DLSSGMode::eOff;options.numFramesToGenerate=0;
  CHECK(optishade::streamline_options::ApplyObservedMinimumFrameCount(options,0));
  CHECK(options.mode==sl::DLSSGMode::eOff&&options.numFramesToGenerate==1);
  options.numFramesToGenerate=0;
  CHECK(optishade::streamline_options::ApplyObservedMinimumFrameCount(options,3));
  CHECK(options.mode==sl::DLSSGMode::eOff&&options.numFramesToGenerate==1);
  options.numFramesToGenerate=1;
  CHECK(!optishade::streamline_options::ApplyObservedMinimumFrameCount(options,3));
  options.mode=sl::DLSSGMode::eDynamic;
  CHECK(!optishade::streamline_options::ApplyObservedMinimumFrameCount(options,3));
  options.mode=sl::DLSSGMode::eOff;
  CHECK(optishade::streamline_options::IsRedundantDisabledOptions(options,sl::DLSSGMode::eOff));
  CHECK(!optishade::streamline_options::IsRedundantDisabledOptions(options,sl::DLSSGMode::eOn));
  options.mode=sl::DLSSGMode::eOn;
  CHECK(!optishade::streamline_options::IsRedundantDisabledOptions(options,sl::DLSSGMode::eOff));
 }

 {nr::BudgetRecovery recovery;constexpr uint64_t mib=1024ull*1024;
  CHECK(recovery.due(1000));CHECK(!recovery.due(1500));CHECK(recovery.due(2000));
  CHECK(!recovery.observe(2000,true,7005*mib,7120*mib));
  CHECK(!recovery.observe(3000,true,7005*mib,6997*mib));
  CHECK(!recovery.observe(4000,true,7005*mib,6800*mib));
  CHECK(!recovery.observe(6000,true,7005*mib,6800*mib));
  CHECK(recovery.observe(7000,true,7005*mib,6800*mib));
  CHECK(!recovery.observe(8000,false,7005*mib,6800*mib));
  CHECK(!recovery.observe(9000,true,7005*mib,6800*mib));
  recovery.reset();CHECK(recovery.due(9001));
  CHECK(!recovery.observe(9001,true,7005*mib,6800*mib));
  CHECK(!recovery.observe(9002,true,0,0));
 }
 {nr::BudgetCheck check;nr::AllocationPlan plan;plan.adapter=7;plan.width=3840;plan.height=2160;
  plan.workWidth=1920;plan.workHeight=1080;plan.precision=16;plan.passes=1;
  CHECK(check.due(1000,plan,true));CHECK(!check.due(1100,plan,true));
  auto changed=plan;changed.workWidth=1600;CHECK(check.due(1200,changed,true));CHECK(!check.due(1300,changed,true));
  CHECK(!check.due(2100,changed,false));CHECK(check.due(2201,changed,false));
  check.invalidate();CHECK(check.due(2202,changed,false));
 }

 {readiness::Journal journal;readiness::Capture c(journal);auto* d=c.Add(77,12);d->required=9;d->completedAtCheck=3;d->completionSampled=true;
 CHECK(!c.Finish(readiness::Outcome::Deadline,false));d->completedAtCheck=9;
 readiness::Snapshot out;CHECK(journal.Read(out));CHECK(out.firstFailure.dependencies[0].completedAtCheck==3);CHECK(readiness::Report(out).find("completedAtCheck=3")!=std::string::npos);
 for(int i=0;i<40;++i){readiness::Capture x(journal);CHECK(x.Finish(readiness::Outcome::Ready,true));}
 CHECK(journal.Read(out));CHECK(out.count==32);CHECK(out.overwritten==9);CHECK(out.hasFirstFailure);CHECK(out.firstFailure.sequence==1);CHECK(out.sequence==41);
 readiness::Capture overflow(journal);for(int i=0;i<20;++i)overflow.Add(i,i+1);CHECK(overflow.value.captured==8);CHECK(overflow.value.dependencyCount==20);
 CHECK(!readiness::Failed(readiness::Outcome::SameQueueOrdered));CHECK(readiness::Name(readiness::Outcome::WaitEnqueued)==std::string("queue waits enqueued (not completion)"));}
 {CHECK(!taa::InputsReleased(true,false,false));CHECK(taa::InputsReleased(true,true,false));CHECK(taa::InputsReleased(true,false,true));CHECK(taa::InputsReleased(false,false,false));}
 {osfx::sync::Policy look;look.seed("test.ini",true,false);
 osfx::Command first{};first.kind=osfx::Uniform;first.type=2;first.count=1;first.unsignedValue[0]=4294967295u;first.arrayIndex=0;
 std::snprintf(first.effect,sizeof(first.effect),"%s","test.fx");std::snprintf(first.name,sizeof(first.name),"%s","Samples");look.commit(first);
 auto second=first;second.arrayIndex=1;second.unsignedValue[0]=16777217u;look.commit(second);
 CHECK(look.look.edits.size()==2);CHECK(look.look.edits[0].unsignedValue[0]==4294967295u);CHECK(look.look.edits[1].unsignedValue[0]==16777217u);
 second.unsignedValue[0]=37;look.commit(second);CHECK(look.look.edits.size()==2);CHECK(look.look.edits[0].unsignedValue[0]==4294967295u);CHECK(look.look.edits[1].unsignedValue[0]==37);
 }
 {using namespace menu_geometry;State geometry;Rect shown;CHECK(geometry.Prepare({1920,1080},1,shown));CHECK(shown.width==1060&&shown.height==800);
 Geometry saved{{180,100,980,740},{1920,1080},1};geometry.Load(saved);CHECK(geometry.Prepare({1920,1080},1,shown));CHECK(Same(shown,saved.rect));
 CHECK(geometry.Prepare({320,240},1,shown));CHECK(shown.width<=290&&shown.height<=210);geometry.Observe(shown,false,500);CHECK(Same(geometry.Preferred()->rect,saved.rect));
 CHECK(geometry.Prepare({1920,1080},1,shown));CHECK(Same(shown,saved.rect));CHECK(!geometry.Prepare({0,0},1,shown));
 CHECK(Parse(Serialize(saved)).has_value());CHECK(!Parse("nan 1 1 1 1 1 1"));CHECK(!Parse("1 1 1 1 1920 1080 1 trailing"));
 CHECK(!ValidContext("../foo"));CHECK(ValidContext("msfs2024.dx12.0"));
 auto big=Fit(saved,{3840,2160},2);CHECK(big.width==980*2); geometry.Reset({3840,2160},1.25f);CHECK(geometry.Preferred()->rect.width==1325);CHECK(geometry.Prepare({3840,2160},1.25f,shown));CHECK(shown.height==1000);CHECK(geometry.Due(1000,false)); // preserved scale then maximum width guard
 }
 {using namespace menu_geometry;State geometry;Rect shown;CHECK(geometry.Prepare({1920,1080},1,shown));
  geometry.Observe({-1200,-800,900,700},true,100);CHECK(geometry.Prepare({1920,1080},1,shown));
  CHECK(shown.x==15&&shown.y==15&&shown.width==900&&shown.height==700);
  CHECK(!geometry.Prepare({1920,1080},1,shown));
 }
 {std::atomic<int> reads{0},writes{0};std::atomic<bool> shouldFail{false};
 BackgroundStatus<int,int> worker([&]{++reads;if(shouldFail)throw std::runtime_error("disk offline");return 17;},[&](const int& value,std::string& note){++writes;note="deliberate rejection";return value==1;},std::chrono::milliseconds(10));
 CHECK(worker.Peek()->sampledAtMs==0);CHECK(worker.Queue(1)==0);CHECK(reads==0);worker.Start();worker.Start();until([&]{return worker.Peek()->sampledAtMs!=0;});CHECK(worker.Peek()->state==17);
 const auto retained=worker.Peek();
 // Queue deliberately uses try_lock: a worker publication can briefly reject
 // admission even with no pending command. Retry admission, never duplicate it.
 uint64_t id=0;until([&]{id=worker.Queue(0);return id!=0;});CHECK(id!=0);until([&]{return worker.Peek()->completedRequest==id;});CHECK(worker.Peek()->save==SaveProgress::Failed);CHECK(writes==1);
 CHECK(retained->completedRequest==0);CHECK(retained->save==SaveProgress::None);CHECK(retained->state==17);
 shouldFail=true;until([&]{return !worker.Peek()->readError.empty();});const auto previous=worker.Peek()->sampledAtMs;std::this_thread::sleep_for(std::chrono::milliseconds(30));CHECK(worker.Peek()->sampledAtMs==previous);
 worker.Stop();CHECK(worker.Queue(1)==0);
 }
 {std::mutex mutex;std::condition_variable condition;bool unblock=false;std::atomic<bool> entered{false};std::thread::id reader;
 BackgroundStatus<int,int> worker([&]{reader=std::this_thread::get_id();entered=true;std::unique_lock<std::mutex> lock(mutex);condition.wait(lock,[&]{return unblock;});return 4;},[](const int&,std::string&){return true;});
 worker.Start();until([&]{return entered.load();});auto start=std::chrono::steady_clock::now();for(int i=0;i<10000;++i)(void)worker.Peek();auto elapsed=std::chrono::steady_clock::now()-start;
 const bool fast=elapsed<std::chrono::seconds(1);const bool separate=reader!=std::this_thread::get_id();auto a=worker.Queue(1),b=worker.Queue(2);
 {std::lock_guard<std::mutex> lock(mutex);unblock=true;}condition.notify_all();until([&]{return worker.Peek()->completedRequest==a;});worker.Stop();CHECK(fast);CHECK(separate);CHECK(a!=0&&b==0);
 }
 {using namespace mfg;Snapshot state;state.verified=true;state.identity="undo-provider";state.settings.followGame=false;
 Draft d;d.Observe(state);d.value.multiplier=4;d.dirty=true;d.Submitted(1);state.settings.multiplier=4;
 d.Complete(1,SaveProgress::Saved,"saved",state);CHECK(d.CanUndo(state));
 d.value.targetFps=120;CHECK(d.StageUndo(state));CHECK(d.value.multiplier==2&&d.value.targetFps==120&&d.review);
 d.Discard(state);state.settings.multiplier=3;CHECK(!d.CanUndo(state));
 state.settings.multiplier=4;state.identity="other-provider";CHECK(!d.CanUndo(state));
 }
 {using namespace mfg;Snapshot live;live.verified=live.owned=live.live=live.editable=true;live.identity="source-A";live.settings.multiplier=2;live.settings.followGame=false;Draft draft;draft.Observe(live);CHECK(draft.initialized);
 draft.value.multiplier=4;draft.dirty=true;Snapshot disconnected;draft.Observe(disconnected);CHECK(draft.value.multiplier==4&&draft.dirty);
 draft.Submitted(7);draft.Discard(live);CHECK(draft.awaiting==7&&draft.value.multiplier==4);draft.Complete(8,SaveProgress::Saved,"wrong id",live);CHECK(draft.awaiting==7);
 draft.Complete(7,SaveProgress::Failed,"busy",live);CHECK(draft.awaiting==0&&draft.dirty&&draft.value.multiplier==4);
 auto replacement=live;replacement.identity="source-B";draft.Observe(replacement);CHECK(draft.conflict&&draft.value.multiplier==4);draft.Discard(replacement);CHECK(!draft.conflict&&draft.value.multiplier==2);
 draft.value.multiplier=4;draft.dirty=true;auto changed=replacement;changed.settings.multiplier=3;draft.Observe(changed);CHECK(draft.conflict&&draft.value.multiplier==4);draft.Discard(changed);CHECK(!draft.conflict&&draft.value.multiplier==3);
 CHECK(!CurrentAcknowledgement(live));auto& s=live.status;s.savedRequestObserved=s.applied=s.setOptionsAccepted=true;s.requestRevision=s.appliedRevision=1;CHECK(CurrentAcknowledgement(live));s.pending=true;CHECK(!CurrentAcknowledgement(live));s.pending=false;s.appliedRevision=0;CHECK(!CurrentAcknowledgement(live));
 s.realFpsMilli=30000;s.outputFpsMilli=60000;s.actualFramesPresented=2;s.fpsAgeMs=100;CHECK(RecentTiming(live));s.fpsAgeMs=2500;CHECK(!RecentTiming(live));live.live=false;s.fpsAgeMs=10;CHECK(!RecentTiming(live));
 Json duplicate;CHECK(!Parse("{\"multiplier\":2,\"multiplier\":4}",4096,duplicate));CHECK(Parse("{\"multiplier\":2}",4096,duplicate));
 }
 {using namespace mfg;Live status;status.gpuFamily=40;status.minMultiplier=2;status.maxMultiplier=6;status.bridgeReady=false;
  Settings current;current.followGame=true;Settings requested=current;requested.followGame=false;requested.multiplier=5;
  Json document=Json::object();std::string error;CHECK(CanPreconfigureFixed(true,status));
  CHECK(MergeAdapterSettings(true,document,current,requested,status,error));CHECK(document["mode"]=="fixed"&&document["multiplier"]==5);
  Json external=Json::object();CHECK(!MergeAdapterSettings(false,external,current,requested,status,error));
  status.maxMultiplier=0;CHECK(!CanPreconfigureFixed(true,status));CHECK(!MergeAdapterSettings(true,document,current,requested,status,error));
  status.maxMultiplier=6;status.canDynamic=false;requested.dynamic=true;CHECK(!MergeAdapterSettings(true,document,current,requested,status,error));
 }
 std::cout<<checks<<" core assertions passed (CPU policy/worker only)\n";return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
