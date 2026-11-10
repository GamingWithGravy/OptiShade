// Native FG inputs are assembled by producer token and consumed at Reflex's
// PresentStart boundary, before Streamline consumes that frame. NR owns its
// recording/queue; no neural commands are inserted into a game's recording.
namespace NativeTaaFg {
using Microsoft::WRL::ComPtr;
using namespace optishade::route;
struct Frame {
 unsigned prepareAttempts=0;
 optishade::taa::NativeFgReadinessBudget readinessBudget;
 ProducerIdentity id{};ProducerFrame contract{};
 std::array<sl::Resource,4> resources{};
 std::array<sl::ResourceTag,4> tags{};
 std::vector<ComPtr<ID3D12Resource>> retained;
 std::vector<std::pair<ComPtr<ID3D12CommandList>,uint64_t>> producers;
 // All leases above remain until GPU-safe cleanup. Only each resource's latest
 // tag recording is a dependency of the current assembled input contract.
 std::array<std::pair<ComPtr<ID3D12CommandList>,uint64_t>,4> activeProducers{};
 ComPtr<ID3D12CommandAllocator> allocator;
 ComPtr<ID3D12GraphicsCommandList> commands,commit;
 ComPtr<ID3D12Fence> done,fgDone,traceFence;
 uint64_t traceValue=0;
 ComPtr<ID3D12Resource> colour,residual,encoded;
 uint64_t fgValue=0,queueIdleValue=0;bool sealed=false,submitted=false,retagged=false,retired=false,failed=false,presentReturned=false,presentReturnedAtResizeBegin=false;
 bool paired=false,outputPending=false,outputSubmitted=false,presentOrdered=false;
 ComPtr<ID3D12Fence> queueIdleFence;
 uint32_t mask=0;sl::Extent outputExtent{};bool outputExtentTagged=false;
 ~Frame(){
  optishade::nr_lifetime::RetirePrivate(commands.Get());
  optishade::nr_lifetime::RetirePrivate(commit.Get());
  for(const auto& p:producers){SubmissionRequest q;q.event=SubmissionEvent::Unpin;q.command=reinterpret_cast<uint64_t>(p.first.Get());q.generation=p.second;SubmissionResult out;Submission(q,out);}
  NativeFgAssembly::Release(contract);
 }
};
struct Context {
optishade::GpuProgressTrace trace{[](const std::string& text){LOG_INFO("FGTRACE {}",text);}};
void TracePoint(Frame& f,const char* stage){
 if(!queue)return;
 if(!f.traceFence){ComPtr<ID3D12Device> d;if(FAILED(queue->GetDevice(IID_PPV_ARGS(&d)))||FAILED(d->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&f.traceFence)))){trace.Record(f.id.frame,"checkpoint fence unavailable");return;}}
 const auto value=++f.traceValue;
 trace.Record(f.id.frame,std::format("{} enqueue queue={:X}",stage,reinterpret_cast<uintptr_t>(queue.Get())));
 const auto hr=queue->Signal(f.traceFence.Get(),value);
 trace.Record(f.id.frame,std::format("{} signal hr={:08X}",stage,unsigned(hr)),f.traceFence.Get(),value);
}

optishade::route::ConstantWindow<sl::Constants> gate;
optishade::route::LegacyWindow legacy;
ComPtr<IDXGISwapChain> swapchain;
bool providerBoundaryObserved=false;
IDXGISwapChain* providerSwap=nullptr; // Borrowed only during the outer provider Present call.
ComPtr<ID3D12CommandQueue> queue;
std::array<std::unique_ptr<Frame>,16> frames;
optishade::nr_admission::Reasons reasons;
std::map<uint32_t,uint32_t> lastFrames;bool haveOutputCommitLog=false,nativeModeObserved=false,nativeSelected=false;
 unsigned resizeDepth=0;bool resizePending=false;
std::optional<ProducerIdentity> pendingPresent;
std::optional<ProducerIdentity> legacyTagged;
// Why Find() created no frame for the last tags (OSD-HAV3: tags observed, but
// no frame was ever assembled and nothing said why).
std::string lastFindFailure;
// Accepted constants seen by this output and the last viewport they named, so a
// tag that cannot be matched says why (OSD-N94F waited with no detail).
uint64_t constantsSeen=0;uint32_t constantsView=UINT32_MAX;
 bool MatchesQueue(ID3D12CommandQueue* candidate)const{
  return candidate&&queue&&optishade::ReShadeObjectIdentity(candidate)==optishade::ReShadeObjectIdentity(queue.Get());
 }
void Say(const char* text,uint32_t view=0){
 optishade::session::State().Put({{"ContractStage",text},{"LastFailure",text}});
 Taa::Instance().nativeFgStatus=text;Taa::Instance().nativeFgStatusAt=GetTickCount64();Taa::Instance().status=text;Taa::Instance().lastCall=Taa::Instance().nativeFgStatusAt;
 uint64_t suppressed=0;if(reasons.Permit(optishade::nr_admission::ReasonKey(text),view,0,Taa::Instance().lastCall,suppressed)){
  LOG_WARN("TAA native FG: {}; viewport={}; repeated={}",text,view,suppressed);
  for(const auto& f:frames)if(f&&f->id.view==view&&!f->retired){
   AssemblyRequest r;r.event=AssemblyEvent::Health;r.ticket=f->contract.ticket;ProducerFrame health{};
   if(NativeFrame(r,&health))LOG_INFO("RouteHealth waiting: ticket={} frame={} view={} owner={} generation={} resourceMask={} observedMask={} failedMask={} reason={}",f->contract.ticket,f->id.frame,view,f->id.owner,f->id.generation,f->mask,health.health.observed,health.health.failed,text);
  }
 }
}
void Stage(Frame& f,OutputStage stage,int64_t result=0,bool success=true){
 AssemblyRequest r;r.event=AssemblyEvent::Observe;r.ticket=f.contract.ticket;r.stage=stage;r.result=result;r.success=success;NativeFrame(r);
 r.event=AssemblyEvent::Health;ProducerFrame state{};
 if(NativeFrame(r,&state)&&(f.id.frame%300==0||!success))LOG_INFO("RouteHealth output: ticket={} frame={} view={} generation={} observedMask={} failedMask={} lastStage={} result={}; generated/presented are not inferred from completion",f.contract.ticket,f.id.frame,f.id.view,f.id.generation,state.health.observed,state.health.failed,unsigned(stage),result);
}
bool Completed(ID3D12Fence* fence,uint64_t value){if(!fence)return false;auto c=fence->GetCompletedValue();return c!=UINT64_MAX&&c>=value;}
void Collect(){
 for(auto& f:frames){if(!f)continue;
  if(f->submitted&&Completed(f->done.Get(),f->outputSubmitted?2:1))Stage(*f,OutputStage::GpuCompleted);
  // NR completion precedes provider consumption. Streamline orders D3D12 work
  // against the presenting queue; a post-Present signal or a completed resize
  // drain on that exact queue covers those waits. No guessed age or queue wait
  // is used to release provider inputs.
  const bool queueCompletedAfterPresent=(f->presentOrdered&&Completed(f->done.Get(),3))||
      Completed(f->queueIdleFence.Get(),f->queueIdleValue);
  const bool consumed=optishade::taa::InputsReleased(f->retagged,
      queueCompletedAfterPresent,Completed(f->fgDone.Get(),f->fgValue));
  bool safe=f->submitted&&Completed(f->done.Get(),f->outputSubmitted?2:1)&&consumed&&(!f->outputPending||f->retired);
  if(!f->submitted&&(f->failed||f->retired)&&consumed)safe=true;
  if(safe){
   // Superseded producer snapshots still own resources until their own GPU completion.
   for(const auto& producer:f->producers){
    SubmissionRequest q;q.event=SubmissionEvent::Query;q.command=reinterpret_cast<uint64_t>(producer.first.Get());q.generation=producer.second;SubmissionResult r;
    if(!Submission(q,r)){safe=false;break;}
    ComPtr<ID3D12CommandQueue> pq;pq.Attach(reinterpret_cast<ID3D12CommandQueue*>(r.queue));
    ComPtr<ID3D12Fence> pf;pf.Attach(reinterpret_cast<ID3D12Fence*>(r.fence));
    if(r.phase!=RecordingPhase::Abandoned&&!r.completed){safe=false;break;}
   }
  }
  if(!safe)continue;
  trace.Record(f->id.frame,std::format("release frame retagged={} presentReturned={} retired={} outputSubmitted={} resizeQueueIdle={}",f->retagged,f->presentReturned,f->retired,f->outputSubmitted,Completed(f->queueIdleFence.Get(),f->queueIdleValue)),f->submitted?f->done.Get():nullptr,f->outputSubmitted?2:1);
  AssemblyRequest r;r.event=AssemblyEvent::Retire;r.identity=f->id;NativeFrame(r);f.reset();
 }
}
Frame* Find(uint32_t frame,uint32_t view,bool create){
 lastFindFailure.clear();
 if(!swapchain||!queue){lastFindFailure="Native FG has no bound presentation swapchain for these tags.";return nullptr;}
 DXGI_SWAP_CHAIN_DESC desc{};if(FAILED(swapchain->GetDesc(&desc))){lastFindFailure="Native FG could not read the bound presentation swapchain.";return nullptr;}
 const auto generation=MenuOverlayDx::PrimarySwapchainGeneration(desc.OutputWindow,swapchain.Get());
 if(!generation){lastFindFailure="Native FG tags arrived while the bound swapchain is not the game's primary presentation window.";return nullptr;}
 ComPtr<ID3D12Device> d;if(FAILED(queue->GetDevice(IID_PPV_ARGS(&d)))){lastFindFailure="Native FG could not read the presentation queue's device.";return nullptr;}
 ProducerIdentity id{optishade::taa::SwapchainIdentity(swapchain.Get()),generation,reinterpret_cast<uint64_t>(optishade::ReShadeDeviceIdentity(d.Get()).Get()),frame,view};
 for(auto& f:frames)if(f&&f->id==id)return f.get();
 if(!create)return nullptr;
 // The game tags every frame, but only TaaFgPrepare retired frames, and only
 // once it had accepted one. Frames tagged while it was waiting (or while the
 // game's FG was off) were never retired, filled the route's assembly slots
 // within a second and every later frame was refused, so TAA NR never ran
 // before frame generation (OSD-3RRK/HAV3). An older frame of this viewport
 // that was never sealed cannot be presented any more: retire it, and Collect
 // releases its slot once its producer work has completed.
 for(auto& f:frames)if(f&&!f->sealed&&f->id.owner==id.owner&&f->id.view==view&&static_cast<int32_t>(frame-f->id.frame)>0)f->retired=true;
 Collect();
 for(auto& f:frames)if(!f){f=std::make_unique<Frame>();f->id=id;AssemblyRequest request;request.event=AssemblyEvent::Begin;request.identity=id;if(!NativeFrame(request,&f->contract)){f.reset();lastFindFailure="Native FG frame assembly refused a new frame for these tags.";return nullptr;}return f.get();}
 Say("Native FG input slots are still owned by pending GPU/presentation work; no resources were reused.",view);return nullptr;
}
bool Put(Frame& f,unsigned index,ID3D12Resource* resource,uint32_t state,uint32_t life,const sl::Extent& extent,ID3D12CommandList* cmd=nullptr,uint64_t recording=0){
 AssemblyRequest r;r.event=AssemblyEvent::Resource;r.identity=f.id;r.index=index;
 r.resource={resource,cmd,recording,state,life,extent.left,extent.top,extent.width,extent.height};
 if(!NativeFrame(r))return false;
 f.activeProducers[index]={cmd,recording};
 f.resources[index]=sl::Resource(sl::ResourceType::eTex2d,resource,state);
 const sl::BufferType types[]={sl::kBufferTypeHUDLessColor,sl::kBufferTypeBackbuffer,sl::kBufferTypeDepth,sl::kBufferTypeMotionVectors};
 f.tags[index]=sl::ResourceTag(&f.resources[index],types[index],sl::eValidUntilPresent,&extent);f.mask|=1u<<index;return true;
}
bool WaitProducers(Frame& f,unsigned budgetUs){
 TracePoint(f,"before-producer-waits");
 const auto active=ActiveProducerRecordings(f.activeProducers);
 trace.Record(f.id.frame,std::format("producer contracts active={} retained={}",active.size(),f.producers.size()));
 for(const auto& p:active){SubmissionRequest q;q.event=SubmissionEvent::Query;q.command=reinterpret_cast<uint64_t>(p.first.Get());q.generation=p.second;SubmissionResult result;
 if(Submission(q,result)){ComPtr<ID3D12CommandQueue> pq;pq.Attach(reinterpret_cast<ID3D12CommandQueue*>(result.queue));ComPtr<ID3D12Fence> pf;pf.Attach(reinterpret_cast<ID3D12Fence*>(result.fence));trace.Record(f.id.frame,std::format("producer dependency cmd={:X} epoch={} queue={:X} phase={}",q.command,q.generation,result.queue,unsigned(result.phase)),pf.Get(),result.fenceValue);}}
 const auto readinessStart=std::chrono::steady_clock::now();
 const bool ok=OrderProducerRecordings(queue.Get(),f.id.device,active,Current().submission,true,budgetUs);
 const auto readinessUs=std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-readinessStart).count();
 trace.Record(f.id.frame,std::format("producer readiness ready={} elapsedUs={} budgetUs={} noGpuWait=true",ok,readinessUs,budgetUs));
 trace.Record(f.id.frame,std::format("producer waits returned {}",ok));TracePoint(f,"after-producer-waits");return ok;
}

// Any recent native upscaler input on the presentation queue's device, at any
// extent: the exact-extent check in TaaFgPrepare still decides ownership.
bool DlssRouteOwnsDevice(){
 if(!queue)return false;
 ComPtr<ID3D12Device> d;if(FAILED(queue->GetDevice(IID_PPV_ARGS(&d))))return false;
 const auto device=reinterpret_cast<uint64_t>(optishade::ReShadeDeviceIdentity(d.Get()).Get());const auto now=GetTickCount64();
 for(const auto& e:g_nativeNrInputs.entries)if(e.device==device&&e.time&&now>=e.time&&now-e.time<2000)return true;
 return false;
}
void TaaFgNewFrameToken(uint32_t frame){auto lock = g_nrEvents.Lock();legacy.Begin(frame,0);optishade::session::State().Put({{"LastStreamlineToken",std::to_string(frame)}});}
void TaaFgLegacyPresent(){auto lock = g_nrEvents.Lock();legacy.Present();}
void TaaFgBindOutput(IDXGISwapChain* swap,ID3D12CommandQueue* queue){
 auto lock = g_nrEvents.Lock();
 if(!swap||!queue||!optishade::route::ExternalFgObserver())return;
 if(swapchain.Get()!=swap||this->queue.Get()!=queue)providerBoundaryObserved=false;
 swapchain=swap;this->queue=queue;
}
void TaaFgBeginResize(ID3D12CommandQueue* candidate){
 auto lock=g_nrEvents.Lock();if(!MatchesQueue(candidate))return;
 if(resizeDepth++!=0)return;
 resizePending=true;providerBoundaryObserved=false;legacy.Reset();gate.Reset();lastFrames.clear();pendingPresent.reset();legacyTagged.reset();
 for(auto& f:frames)if(f){f->presentReturnedAtResizeBegin=f->presentReturned;f->retired=true;}
 Collect();Late::Instance().CancelPairedTaaFg();Taa::Instance().lastRun=0;
}
void TaaFgEndResize(ID3D12CommandQueue* candidate){
 auto lock=g_nrEvents.Lock();if(!MatchesQueue(candidate)||!resizeDepth)return;
 resizePending=--resizeDepth!=0;
}
void TaaFgReset(){
 auto lock = g_nrEvents.Lock();
 providerBoundaryObserved=false;
 legacy.Reset();gate.Reset();lastFrames.clear();pendingPresent.reset();legacyTagged.reset();
 // Outstanding GPU/Streamline references are deliberately retained. They are
 // retired only by the fence belonging to their own frame, never by resize age.
 for(auto& f:frames)if(f)f->retired=true;
 Collect();Late::Instance().CancelPairedTaaFg();Taa::Instance().lastRun=0;
}
void TaaFgQueueIdleCompleted(ID3D12CommandQueue* completedQueue,ID3D12Fence* fence,uint64_t value){
 if(!resizePending||!completedQueue||!fence||!value||!Completed(fence,value)||!queue||
    optishade::ReShadeObjectIdentity(completedQueue)!=optishade::ReShadeObjectIdentity(queue.Get()))return;
 unsigned matched=0;
 for(auto& f:frames)if(f&&f->retagged&&f->presentReturnedAtResizeBegin){
  f->queueIdleFence=fence;f->queueIdleValue=value;++matched;
 }
 if(matched)LOG_INFO("Native FG retirement: completed resize fence on the exact presenting queue covers {} returned input frame(s).",matched);
 Collect();
}
// Release the presentation owner before the game creates its replacement.
// Keeping this ComPtr alive after the wrapper's final Release prevents DXGI
// from replacing a flip-model swapchain on the same HWND (E_ACCESSDENIED).
void TaaFgReleaseOutput(IDXGISwapChain* retiring){
 auto lock = g_nrEvents.Lock();
 if(!retiring||swapchain.Get()!=retiring)return;
 TaaFgReset();swapchain.Reset();queue.Reset();
}
void TaaFgInvalidate(uint32_t view){
 auto lock = g_nrEvents.Lock();
 // Resource removal is not a new Streamline session. Tokens can already have
 // been issued and constants accepted before the engine clears old FG tags.
 // Retire only this viewport's resource contracts; keep the accepted clock.
 for(auto& f:frames)if(f&&f->id.view==view)f->retired=true;
 if(pendingPresent&&pendingPresent->view==view)pendingPresent.reset();
 if(legacyTagged&&legacyTagged->view==view)legacyTagged.reset();
 lastFrames.clear();
 Collect();
 Say("Native FG cleared this viewport's resources; accepted frame constants retained.",view);
}
void TaaFgAcceptedConstants(const sl::Constants& value,uint32_t frame,uint32_t view){
 auto lock = g_nrEvents.Lock();legacy.Constants(frame,view,0);
 // Bounded: an engine alternating viewports every frame must not flood the log.
 static unsigned constantLogs=0;
 if((constantsSeen++<4||view!=constantsView)&&constantLogs<32){++constantLogs;LOG_INFO("TAA pre-FG constants: frame={} viewport={} seen={}",frame,view,constantsSeen);}
 constantsView=view;
 if(OptiShadeTaaRequested())gate.AcceptedConstants(frame,view,&value);
}
void TaaFgLegacyTags(ID3D12GraphicsCommandList* cmd,const sl::ResourceTag* tags,uint32_t count,uint32_t view){
 auto lock = g_nrEvents.Lock();uint32_t frame=0;
 if(resizePending)return;
 if(!OptiShadeTaaRequested())return;
 if(!legacy.Frame(view,0,frame)){
  Say(!constantsSeen?"Waiting: no frame constants from the game have reached the pre-FG route yet.":
      legacy.Ambiguous()?"Waiting: the game sent frame constants for more than one viewport on the same frame.":
      constantsView!=view?"Waiting: frame constants name a different viewport than these tags.":
      "Waiting for a unique accepted producer token and viewport.",view);
  return;
 }
 TaaFgBeforeTags(cmd,tags,count,frame,view);
 // slSetTag has no frame argument. Its producer is the accepted constants
 // captured above, not a later simulation token carried by a PCL marker.
 if(auto* f=Find(frame,view,false);f&&!f->failed&&!f->retired&&!f->sealed)
  legacyTagged=f->id;
}
// Which gate keeps TAA NR from running before frame generation, logged when it
// changes. OSD-22P4: TAA NR with FG never started and the log did not say why.
void PreFgGate(const char* gate){
 static const char* last=nullptr;static unsigned changes=0;
 // Bounded: a gate that flips every frame must not flood the log.
 if(gate==last||changes>=64)return;
 last=gate;++changes;
 const auto& s=State::Instance();
 LOG_INFO("TAA pre-FG gate: {}; signature={:X} optiMfgController={} externalFG={} activeFgInput={}",gate,
  s.dlssgTemporalSignature.load(std::memory_order_relaxed),s.optiMfgExternalController,s.externalFrameGeneration,static_cast<int>(s.activeFgInput));
}
void TaaFgBeforeTags(ID3D12GraphicsCommandList* cmd,const sl::ResourceTag* tags,uint32_t count,uint32_t frame,uint32_t view){
 using namespace NativeTaaFg;
 auto lock = g_nrEvents.Lock();
 if(resizePending)return;
 RefreshUnobservedFgSignature();
 if(!optishade::taa::NativeCompositionAllowed(State::Instance().dlssgTemporalSignature.load(std::memory_order_relaxed))){PreFgGate("tags: frame generation not confirmed as generating");return;}
 if(!OptiShadeTaaRequested()){PreFgGate("tags: TAA NR not requested");return;}
 if(!optishade::route::ExternalFgObserver()||
    !optishade::external_fg::NativeProviderObserver(State::Instance().externalFrameGeneration,true,State::Instance().activeFgInput==FGInput::DLSSG)){PreFgGate("tags: frame-generation observer not active");return;}
 if(!tags||count>64){PreFgGate("tags: no usable tag list");return;}
 // DLSS NR (before SR) owns this device's output: TaaFgPrepare would stand
 // aside anyway, so do not pin producers or snapshot volatile tags each frame.
 if(DlssRouteOwnsDevice()){PreFgGate("tags: DLSS NR owns this device");return;}
 PreFgGate("tags: observed");
 unsigned observedMask=0;for(uint32_t i=0;i<count;++i){const auto type=tags[i].type;if(type==sl::kBufferTypeHUDLessColor)observedMask|=1;else if(type==sl::kBufferTypeBackbuffer)observedMask|=2;else if(type==sl::kBufferTypeDepth)observedMask|=4;else if(type==sl::kBufferTypeMotionVectors)observedMask|=8;}
 optishade::session::State().Put({{"LastTagFrame",std::to_string(frame)},{"LastTagViewport",std::to_string(view)},{"ObservedTagMask",std::to_string(observedMask)}});
 auto* f=Find(frame,view,true);
 if(!f){if(!lastFindFailure.empty())Say(lastFindFailure.c_str(),view);return;}
 if(f->sealed||f->retired){Say("Native FG tags arrived for a frame that was already presented or retired.",view);return;}
 ComPtr<ID3D12Device> device;if(FAILED(queue->GetDevice(IID_PPV_ARGS(&device)))){Say("Native FG could not read the presentation queue's device.",view);return;}
 static constexpr const char* inputNames[]={"HUD-less colour","backbuffer","depth","motion vector"};
 for(uint32_t i=0;i<count;++i){
  const auto& tag=tags[i];unsigned index=4;
  if(tag.type==sl::kBufferTypeHUDLessColor)index=0;else if(tag.type==sl::kBufferTypeBackbuffer)index=1;else if(tag.type==sl::kBufferTypeDepth)index=2;else if(tag.type==sl::kBufferTypeMotionVectors)index=3;
  if(index==4)continue;
  // Backbuffer's resource may legally be null: only its subrect is tagged.
  if(index==1){f->outputExtent=tag.extent;f->outputExtentTagged=true;if(!tag.resource||!tag.resource->native)continue;}
  if(!tag.resource||!tag.resource->native||tag.resource->type!=sl::ResourceType::eTex2d||tag.resource->state==UINT32_MAX||tag.next||tag.resource->next){Say("Native FG tag has no supported resource/state contract.",view);f->failed=true;return;}
  auto* resource=static_cast<ID3D12Resource*>(tag.resource->native);
  ComPtr<ID3D12Device> rd;if(FAILED(resource->GetDevice(IID_PPV_ARGS(&rd)))||optishade::ReShadeDeviceIdentity(rd.Get())!=optishade::ReShadeDeviceIdentity(device.Get())){f->failed=true;Say("Native FG split tag belongs to another device.",view);return;}
  uint64_t recording=0;
  if(cmd){SubmissionRequest r;r.event=SubmissionEvent::Recording;r.command=reinterpret_cast<uint64_t>(cmd);SubmissionResult out;
   if(!Submission(r,out)||out.device!=f->id.device){Say("Native FG tag command list is not in an observed recording.",view);f->failed=true;return;}recording=out.generation;
   const auto existing=std::find_if(f->producers.begin(),f->producers.end(),[&](const auto& p){return p.first.Get()==cmd&&p.second==recording;});
   if(existing==f->producers.end()){
    r.event=SubmissionEvent::Pin;r.generation=recording;
    if(!Submission(r,out)){f->failed=true;Say("Native FG could not retain its producer completion evidence.",view);return;}
    f->producers.emplace_back(cmd,recording);
   }
  }
  uint32_t state=tag.resource->state;
  if(tag.lifecycle!=sl::eValidUntilPresent){
   if(!cmd||!recording){Say("Volatile native FG input needs its producer command list.",view);f->failed=true;return;}
   const auto d=resource->GetDesc();
   if(d.Dimension!=D3D12_RESOURCE_DIMENSION_TEXTURE2D||d.SampleDesc.Count!=1||d.DepthOrArraySize!=1){
    const auto text=std::format("Native FG volatile {} input is not a single-sample 2D texture (dimension {}, samples {}, array size {}).",inputNames[index],static_cast<int>(d.Dimension),d.SampleDesc.Count,d.DepthOrArraySize);
    f->failed=true;Say(text.c_str(),view);return;
   }
   ComPtr<ID3D12Resource> copy;
   if(const HRESULT hr=optishade::taa::CreateBaseMipCopy(device.Get(),resource,index<2,&copy);FAILED(hr)){
    const auto text=std::format("Native FG could not snapshot the volatile {} input (DXGI format {}, flags {:X}, HRESULT {:08X}).",inputNames[index],static_cast<int>(d.Format),static_cast<unsigned>(d.Flags),static_cast<unsigned>(hr));
    f->failed=true;Say(text.c_str(),view);return;
   }
   // Snapshot while eOnlyValidNow/eValidUntilEvaluate is valid, on that exact
   // recording. Both source and copy survive through its actual submission.
   f->retained.emplace_back(resource);f->retained.push_back(copy);
   optishade::taa::CopyBaseMip(cmd,resource,copy.Get(),static_cast<D3D12_RESOURCE_STATES>(state));
   resource=copy.Get();state=D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
  }
  if(!Put(*f,index,resource,state,static_cast<uint32_t>(tag.lifecycle),tag.extent,cmd,recording)){f->failed=true;Say("Native FG route rejected the split resource contract.",view);return;}
 }
}
// Called with the real Streamline frame token's numeric identity at PresentStart.
// Returned tags point into the retained frame, not stack-local resource wrappers.
bool TaaFgPrepare(uint32_t marker,bool legacyApi,sl::ResourceTag* out,uint32_t& view,uint32_t& producer){
 using namespace NativeTaaFg;
 auto lock = g_nrEvents.Lock();
 if(resizePending)return false;
 if(!OptiShadeTaaRequested()||!out)return false;
 RefreshUnobservedFgSignature();
 if(!optishade::taa::NativeCompositionAllowed(State::Instance().dlssgTemporalSignature.load(std::memory_order_relaxed)))PreFgGate("present: frame generation not confirmed as generating");
 // The provider keeps presenting and tagging while FG is eOff (pause/settings).
  // Those callbacks must not compete with the estimated one-pass fallback for
  // the same NR model state. The fallback yields only after a frame contract is validated.
 if(!optishade::taa::NativeCompositionAllowed(State::Instance().dlssgTemporalSignature.load(std::memory_order_relaxed))){
   if(nativeModeObserved){
    nativeModeObserved=false;nativeSelected=false;lastFrames.clear();pendingPresent.reset();legacyTagged.reset();
   for(auto& f:frames)if(f)f->retired=true;
   trace.Record(0,"native FG off: yielding NR ownership to fallback; retaining unfinished GPU work");
   LOG_INFO("TAA NR ownership: native FG off; fallback owns model dispatch until accepted FG enable");
  }
  Collect();return false;
 }
  if(!nativeModeObserved){nativeModeObserved=true;lastFrames.clear();LOG_INFO("TAA NR ownership: native FG mode accepted; fallback remains available until a valid frame contract is received");}

 if(!queue||!swapchain){Say("Waiting for presentation generation");return false;}
 uint32_t frame=marker;
 if(legacyApi){
  if(!legacyTagged){Say("Waiting for legacy FG tags with accepted frame constants");return false;}
  frame=legacyTagged->frame;
 }
 producer=frame;
 for(auto& candidate:frames)if(candidate&&static_cast<int32_t>(frame-candidate->id.frame)>0)candidate->retired=true;
 Collect();
 Frame* f=nullptr;for(auto& candidate:frames)if(candidate&&candidate->id.frame==frame&&!candidate->retired&&!candidate->sealed&&Find(frame,candidate->id.view,false)==candidate.get()){if(f){Say("Several FG viewports have the same frame; no primary viewport contract was selected.");return false;}f=candidate.get();}
 if(!f){Say("No unconsumed FG input frame matches this presentation owner and producer token");return false;}if(f->failed)return false;view=f->id.view;
 optishade::route::OutputScope outputScope(optishade::route::OutputKey{f->id.device,f->id.owner,f->id.generation,f->id.view,2});
 if(!outputScope){Say("NR output capacity reached; existing GPU histories are retained safely.",view);return false;}
 optishade::session::State().Put({{"LastPresentStartToken",std::to_string(frame)},{"TagMask",std::to_string(f->mask)},{"Generation",std::to_string(f->id.generation)}});
 if(!optishade::taa::AllowNativeFgPreparation(pendingPresent,f->id,providerSwap!=nullptr,f->prepareAttempts,f->sealed,f->submitted,f->retired,f->failed)){Say("Native FG presentation boundary is still pending; frame identity was not reassigned.",view);return false;}
 const bool retry=f->prepareAttempts++!=0;
 pendingPresent=f->id;
 if(retry)trace.Record(frame,"retry exact unconsumed frame at provider Present; remaining per-frame readiness allowance only");
 sl::Constants constants;if(!gate.Constants(frame,view,constants)){Say("Native FG frame is waiting for matching constants.",view);return false;}
 if(!(f->mask&1)){Say("Waiting for HUD-less colour",view);return false;}
 if(!(f->mask&4)){Say("Waiting for depth",view);return false;}
 if(!(f->mask&8)){Say("Waiting for motion vectors",view);return false;}
 ComPtr<IDXGISwapChain3> swap;ComPtr<ID3D12Resource> output;ComPtr<ID3D12Device> device;
 auto* imageOwner=providerSwap?providerSwap:swapchain.Get();
 if(FAILED(imageOwner->QueryInterface(IID_PPV_ARGS(&swap)))||FAILED(swap->GetBuffer(swap->GetCurrentBackBufferIndex(),IID_PPV_ARGS(&output)))||FAILED(queue->GetDevice(IID_PPV_ARGS(&device))))return false;
 // Automatic routing must not run the native upscaler path and this TAA path
 // on the same output. This is the same device/extent preference used by the
 // ReShade fallback; tag availability by itself does not prove TAA is selected.
 const auto outputDesc=output->GetDesc();
 if(g_nativeNrInputs.recent(reinterpret_cast<uint64_t>(optishade::ReShadeDeviceIdentity(device.Get()).Get()),
     static_cast<unsigned>(outputDesc.Width),outputDesc.Height,GetTickCount64())){
  lastFrames.erase(view);Say("Matching native upscaler inputs detected; native-FG TAA compatibility is standing aside.",view);return false;
 }
 if(f->mask&2){if(!optishade::taa::IsCurrentNativeFgOutput(imageOwner,static_cast<ID3D12Resource*>(f->resources[1].native))){Say("Native FG output does not match this frame's swapchain buffer.",view);return false;}}
 if(!Put(*f,1,output.Get(),D3D12_RESOURCE_STATE_PRESENT,sl::eValidUntilPresent,f->outputExtentTagged?f->outputExtent:f->tags[0].extent))return false;
 trace.Record(f->id.frame,std::format("resources owner={:X} provider={:X} output={:X} hudless={:X} depth={:X} motion={:X} states={},{},{},{}",f->id.owner,reinterpret_cast<uintptr_t>(providerSwap),reinterpret_cast<uintptr_t>(output.Get()),reinterpret_cast<uintptr_t>(f->resources[0].native),reinterpret_cast<uintptr_t>(f->resources[2].native),reinterpret_cast<uintptr_t>(f->resources[3].native),f->resources[0].state,f->resources[1].state,f->resources[2].state,f->resources[3].state));
 if(!WaitProducers(*f,f->readinessBudget.Take(providerBoundaryObserved,providerSwap!=nullptr))){Say("Native FG producer is not ready; original FG inputs retained to avoid a cross-queue wait.",view);return false;}
 if(!g_compose)g_compose=std::make_unique<DlssNr_Dx12>("MSFS2024 producer NR",device.Get());
 device=optishade::NrRecordingDevice(device.Get(),g_compose->Device());
 if(!device){f->failed=true;Say("Native FG renderer and presentation devices differ.",view);return false;}
 if(FAILED(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&f->allocator)))||FAILED(device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,f->allocator.Get(),nullptr,IID_PPV_ARGS(&f->commands)))||FAILED(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&f->done))))return false;
 optishade::taa::NativeFgInputs input;
 if(const auto* why=optishade::taa::NativeFgContract(f->commands.Get(),f->tags.data(),4,constants,input)){Say(why,view);f->failed=true;return false;}
  if(!nativeSelected){nativeSelected=true;LOG_INFO("TAA NR ownership: validated native FG frame contract; native path owns the matching output frame");}
 AssemblyRequest request;request.identity=f->id;request.event=AssemblyEvent::Constants;request.constants=&constants;request.constantBytes=sizeof(constants);
 if(!NativeFrame(request))return false;request.event=AssemblyEvent::Publish;
 if(!NativeFrame(request,&f->contract))return false;f->sealed=true;gate.Consume(view,frame);
 auto* cmd=f->commands.Get();const auto desc=input.color->GetDesc();
 if(FAILED(optishade::taa::CreateBaseMipCopy(device.Get(),input.color,true,&f->colour))){f->failed=true;return false;}
 optishade::taa::CopyBaseMip(cmd,input.color,f->colour.Get(),input.colorState);
 if(optishade::D3D12FrameContext{cmd,f->colour.Get(),input.depth,input.motion,f->colour.Get(),nullptr,queue.Get()}.ValidateDeviceIdentity(g_compose->Device(),true)){f->failed=true;return false;}
 const auto read=D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
 Barrier(cmd,input.depth,input.depthState,read);Barrier(cmd,input.motion,input.motionState,read);
 DlssNrFrameInfo info{};info.NativeFgProducer=true;info.FinishedPicture=true;info.IndependentCommands=true;info.OutputArrivalState=read;info.ColourIsLinearHdr=false;
 info.ObservationOwner=f->id.owner;info.ObservationGeneration=f->id.generation;info.ObservationView=view;info.SubmissionEpoch=uint64_t(frame)+1;
 info.OutputWidth=static_cast<unsigned>(desc.Width);info.OutputHeight=desc.Height;info.RenderSubrectWidth=info.OutputWidth;info.RenderSubrectHeight=info.OutputHeight;
 info.DepthInverted=constants.depthInverted==sl::eTrue;info.MvScaleX=constants.mvecScale.x*info.OutputWidth;info.MvScaleY=constants.mvecScale.y*info.OutputHeight;
 const auto prior=lastFrames.find(view);
 info.Reset=constants.reset==sl::eTrue||prior==lastFrames.end()||frame!=prior->second+1;
 const auto before=g_nr.successfulDispatches;g_compose->Dispatch(cmd,f->colour.Get(),input.depth,input.motion,f->colour.Get(),info,queue.Get());
 bool evaluated=g_nr.successfulDispatches>before&&Config::Instance()->DlssNrApplyModel.value_or_default();
 Barrier(cmd,input.motion,read,input.motionState);Barrier(cmd,input.depth,read,input.depthState);
 if(evaluated&&input.pairedOutput){
  f->residual.Attach(CreateScratch(device.Get(),DXGI_FORMAT_R16G16B16A16_FLOAT,info.OutputWidth,info.OutputHeight));
  f->encoded.Attach(CreateScratch(device.Get(),desc.Format,info.OutputWidth,info.OutputHeight));
  if(!f->residual||!f->encoded||!g_nr.hdrCopy)evaluated=false;
  else {
   Barrier(cmd,g_nr.hdrCopy,D3D12_RESOURCE_STATE_UNORDERED_ACCESS,read);
   DlssNrConstants encode{};encode.Mode=5;encode.Width=info.OutputWidth;encode.Height=info.OutputHeight;encode.WhitePoint=1.0f;encode.MaxRatio=std::clamp(Config::Instance()->DlssNrMaxRatio.value_or_default(),1.0f,8.0f);
   evaluated=g_compose->DispatchResidualPass(cmd,encode,g_nr.hdrCopy,f->colour.Get(),nullptr,nullptr,f->residual.Get(),true);
   Barrier(cmd,g_nr.hdrCopy,read,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
   if(evaluated){
    Barrier(cmd,f->residual.Get(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,read);
    f->paired=true;
   }
  }
 }
 // Creation-only recordings are preparation, not a failed evaluation.
 if(evaluated)Stage(*f,OutputStage::NrRecorded,1,true);
 else if(g_nr.failed)Stage(*f,OutputStage::NrRecorded,0,false);
 trace.Record(frame,"private NR Close begin");
 const HRESULT closeResult=optishade::nr::ClosePrivateRecording(cmd);
 trace.Record(frame,std::format("private NR Close returned hr={:08X}",static_cast<unsigned>(closeResult)));
 if(FAILED(closeResult)){
  FinishedPictureCommandListFailed(cmd);
  f->failed=true;Stage(*f,OutputStage::NrRecorded,closeResult,false);
  LOG_ERROR("Native FG NR Close failed: hr={:08X}; frame={} view={}; command was not submitted",static_cast<unsigned>(closeResult),frame,view);
  for(unsigned index=0;index<4;++index){
   if(!f->resources[index].native)continue;
   const auto detail=static_cast<ID3D12Resource*>(f->resources[index].native)->GetDesc();
   LOG_ERROR("Native FG rejected input {}: format={} flags={:X} state={:X} width={} height={} mips={} samples={}",index,unsigned(detail.Format),unsigned(detail.Flags),f->resources[index].state,detail.Width,detail.Height,detail.MipLevels,detail.SampleDesc.Count);
  }
  Say("Native FG NR recording failed validation; see diagnostics for HRESULT.",view);return false;
 }
 if(g_nr.failed){f->failed=true;Say(g_nr.reason&&*g_nr.reason?g_nr.reason:"Neural recording failed; original FG tags remain active.",view);return false;}
 const bool modelEvaluated=evaluated;
 if(evaluated){
  evaluated=SUCCEEDED(device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,f->allocator.Get(),nullptr,IID_PPV_ARGS(&f->commit)));
  if(evaluated){auto* commit=f->commit.Get();
   if(f->paired){
    // Record now, submit only at this frame's actual swapchain Present. The
    // game's final colour/HUD writes may be queued after its PCL PresentStart.
    Barrier(commit,output.Get(),D3D12_RESOURCE_STATE_PRESENT,read);
    DlssNrConstants apply{};apply.Mode=2;apply.Width=info.OutputWidth;apply.Height=info.OutputHeight;
    apply.WhitePoint=1.0f;apply.MaxRatio=std::clamp(Config::Instance()->DlssNrMaxRatio.value_or_default(),1.0f,8.0f);
    evaluated=g_compose->DispatchResidualPass(commit,apply,output.Get(),nullptr,f->residual.Get(),nullptr,f->encoded.Get(),true);
    Barrier(commit,output.Get(),read,D3D12_RESOURCE_STATE_COPY_DEST);
    Barrier(commit,f->encoded.Get(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_COPY_SOURCE);
    if(evaluated)commit->CopyResource(output.Get(),f->encoded.Get());
    Barrier(commit,output.Get(),D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_PRESENT);
   }else{
    optishade::taa::ReturnBaseMip(commit,f->colour.Get(),output.Get(),D3D12_RESOURCE_STATE_PRESENT);
    optishade::taa::MipZeroBarrier(commit,f->colour.Get(),D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
   }
   const auto closed=optishade::nr::ClosePrivateRecording(commit);evaluated=evaluated&&SUCCEEDED(closed);
  }
 }
 if(!evaluated){
  ID3D12CommandList* lists[]={cmd};trace.Record(frame,"private NR warmup submit begin");
  const auto submitted=optishade::nr::SubmitPrivateRecording(queue.Get(),cmd);
  trace.Record(frame,std::format("private NR warmup submit returned hr={:08X}",static_cast<unsigned>(submitted)));
  if(FAILED(submitted)){f->failed=true;FinishedPictureCommandListFailed(cmd);Say("Private NR submission rejected its queue/list contract.",view);return false;}
  FinishedPictureSubmitted(queue.Get(),1,lists);f->submitted=true;Stage(*f,OutputStage::Submitted);
  if(FAILED(queue->Signal(f->done.Get(),1)))f->failed=true;
 TracePoint(*f,"after-NR");
  if(modelEvaluated){Stage(*f,OutputStage::NrRecorded,-1,false);Say("Native FG output-commit recording failed; original FG tags remain active.",view);}
  else Say(g_nr.failed&&g_nr.reason&&*g_nr.reason?g_nr.reason:"Native FG neural backend is preparing; original FG tags remain active.",view);return false;
 }
 f->resources[0]=sl::Resource(sl::ResourceType::eTex2d,f->colour.Get(),read);f->tags[0].resource=&f->resources[0];
 for(unsigned i=0;i<4;++i)out[i]=f->tags[i];
 if(frame%300==0)LOG_INFO("RouteHealth native FG: ticket={} frame={} view={} owner={} generation={} stages=requested,contract,recorded queue={}; awaiting tag acceptance and submission",f->contract.ticket,frame,view,f->id.owner,f->id.generation,reinterpret_cast<uint64_t>(queue.Get()));
 return true;
}
void TaaFgTagsAccepted(uint32_t frame,uint32_t view,bool accepted){
 auto lock = g_nrEvents.Lock();auto* f=Find(frame,view,false);if(!f||f->submitted)return;f->retagged=accepted;Stage(*f,optishade::route::OutputStage::FgAccepted,accepted?0:-1,accepted);
 // Both recordings were closed before exposing processed tags. Submit NR
 // now; the real-output commit belongs to the matching swapchain Present.
 ID3D12CommandList* lists[]={f->commands.Get()};const UINT count=1;f->outputPending=accepted;
 trace.Record(frame,"private NR accepted submit begin");
  const auto submitted=optishade::nr::SubmitPrivateRecording(queue.Get(),f->commands.Get());
  trace.Record(frame,std::format("private NR accepted submit returned hr={:08X}",static_cast<unsigned>(submitted)));
  if(FAILED(submitted)){f->failed=true;FinishedPictureCommandListFailed(f->commands.Get());Say("Private NR submission rejected its queue/list contract.",view);return;}
  FinishedPictureSubmitted(queue.Get(),count,lists);f->submitted=true;Stage(*f,optishade::route::OutputStage::Submitted);
 if(FAILED(queue->Signal(f->done.Get(),1)))f->failed=true;
 TracePoint(*f,"after-NR");
 if(accepted){if(lastFrames.size()<16||lastFrames.count(view))lastFrames[view]=frame;}else{f->failed=true;lastFrames.erase(view);}

 Say(accepted?"NR submitted before native FG; awaiting GPU and presentation evidence.":"Streamline rejected the processed frame tags.",view);
}
void TaaFgInputsConsumed(uint32_t view,ID3D12Fence* fence,uint64_t value){
 auto lock = g_nrEvents.Lock();if(!fence||!value)return;
 for(auto& f:frames)if(f&&f->id.view==view&&f->retagged&&f->presentReturned&&!f->fgDone){f->fgDone=fence;f->fgValue=value;}
 Collect();
}

void TaaFgBeforePresent(IDXGISwapChain* swap,ID3D12CommandQueue* presentingQueue){
 auto lock=g_nrEvents.Lock();
 if(providerSwap&&swap!=providerSwap)return;
 auto* identityOwner=providerSwap?swapchain.Get():swap;
 if(!pendingPresent||!swap||!presentingQueue||pendingPresent->owner!=optishade::taa::SwapchainIdentity(identityOwner))return;
 for(auto& f:frames)if(f&&f->id==*pendingPresent){
  if(!f->outputPending||!f->retagged||!f->submitted||f->failed||f->retired)return;
  if(!OptiShadeTaaRequested()){
   // NR may be switched off after this frame was prepared and its input tags
   // accepted. Keep submitted leases alive for their normal fence-based
   // retirement, but do not copy the prepared NR image onto the game's output.
   f->outputPending=false;f->retired=true;
   LOG_INFO("Native FG NR output commit skipped after session disable; original game output kept. frame={} view={} generation={}",f->id.frame,f->id.view,f->id.generation);
   Collect();return;
  }
  DXGI_SWAP_CHAIN_DESC desc{};
  if(FAILED(swap->GetDesc(&desc))||MenuOverlayDx::PrimarySwapchainGeneration(desc.OutputWindow,identityOwner)!=f->id.generation||
     optishade::ReShadeObjectIdentity(presentingQueue)!=optishade::ReShadeObjectIdentity(queue.Get())||
     !optishade::taa::IsCurrentNativeFgOutput(swap,static_cast<ID3D12Resource*>(f->resources[1].native))){
   f->outputPending=false;f->retired=true;Say("Native FG output owner changed; stale colour was not applied.",f->id.view);return;
  }
  // Same actual queue: the earlier NR and all game writes already submitted
  // precede this commit. No CPU wait and no guessed frame-age reuse.
  trace.Record(f->id.frame,"private NR output submit begin");
  const auto submitted=optishade::nr::SubmitPrivateRecording(presentingQueue,f->commit.Get());
  trace.Record(f->id.frame,std::format("private NR output submit returned hr={:08X}",static_cast<unsigned>(submitted)));
  if(FAILED(submitted)){f->failed=true;Say("Private NR output queue/list contract rejected.",f->id.view);return;}
  ID3D12CommandList* commitLists[]={f->commit.Get()};FinishedPictureSubmitted(presentingQueue,1,commitLists);
  f->outputPending=false;f->outputSubmitted=true;
  if(FAILED(presentingQueue->Signal(f->done.Get(),2)))f->failed=true;
  TracePoint(*f,"after-output-commit");
  if(!haveOutputCommitLog||f->id.frame%300==0){
   haveOutputCommitLog=true;LOG_INFO("Native FG real-output commit submitted at {} Present: frame={} view={} generation={}; visible scanout remains unconfirmed",providerSwap?"provider-input":"wrapped-output",f->id.frame,f->id.view,f->id.generation);
  }
  return;
 }
}
bool TaaFgProviderPrepare(IDXGISwapChain* outer,sl::ResourceTag* tags,uint32_t& view,uint32_t& producer){
 auto lock=g_nrEvents.Lock();
 if(!outer||!swapchain||!queue||providerSwap)return false;
 DXGI_SWAP_CHAIN_DESC a{},b{};ComPtr<ID3D12Device> device;
 if(FAILED(outer->GetDesc(&a))||FAILED(swapchain->GetDesc(&b))||a.OutputWindow!=b.OutputWindow||
    FAILED(outer->GetDevice(IID_PPV_ARGS(&device))))return false;
 ComPtr<ID3D12Device> queued;if(FAILED(queue->GetDevice(IID_PPV_ARGS(&queued)))||
    optishade::ReShadeDeviceIdentity(device.Get())!=optishade::ReShadeDeviceIdentity(queued.Get()))return false;
 trace.Record(0,std::format("provider begin swap={:X}",reinterpret_cast<uintptr_t>(outer)));
 providerBoundaryObserved=true;
 providerSwap=outer;
 return TaaFgPrepare(0,true,tags,view,producer);
}
void TaaFgProviderCommit(IDXGISwapChain* outer){auto lock=g_nrEvents.Lock();if(providerSwap==outer){TaaFgBeforePresent(outer,queue.Get());trace.Record(pendingPresent?pendingPresent->frame:0,"provider original Present about to execute");}}
void TaaFgPresentResult(IDXGISwapChain* swap,HRESULT result){
 auto lock = g_nrEvents.Lock();
 if(providerSwap){if(swap!=providerSwap)return;
 trace.Record(pendingPresent?pendingPresent->frame:0,std::format("provider returned hr={:08X}",unsigned(result)));
 if(pendingPresent)for(auto& f:frames)if(f&&f->id==*pendingPresent)TracePoint(*f,"after-provider-return");
 swap=swapchain.Get();providerSwap=nullptr;}
 // Legacy tags expire at the real Present, regardless of the simulation token
 // carried by PresentEnd. Do not let an old producer survive into another frame.
 if(legacyTagged&&legacyTagged->owner==optishade::taa::SwapchainIdentity(swap)){
  for(auto& f:frames)if(f&&f->id==*legacyTagged){f->presentReturned=true;if(!f->sealed)f->retired=true;break;}
  legacyTagged.reset();
 }
 if(pendingPresent&&pendingPresent->owner==optishade::taa::SwapchainIdentity(swap)){
  for(auto& f:frames)if(f&&f->id==*pendingPresent){f->presentReturned=true;if(!f->sealed)f->retired=true;Stage(*f,OutputStage::PresentSubmitted,result,SUCCEEDED(result));break;}
  pendingPresent.reset();
 }
 if(SUCCEEDED(result)&&queue)for(auto& f:frames){
  if(!f||!f->submitted||!f->retagged||!f->presentReturned||f->presentOrdered||f->id.owner!=optishade::taa::SwapchainIdentity(swap))continue;
  const auto hr=queue->Signal(f->done.Get(),3);f->presentOrdered=SUCCEEDED(hr);
  trace.Record(f->id.frame,std::format("post-provider lifetime signal hr={:08X}",unsigned(hr)),f->done.Get(),3);
 }

}
void TaaFgPresentReturned(uint32_t frame){auto lock = g_nrEvents.Lock();for(auto& f:frames)if(f&&f->id.frame==frame){f->presentReturned=true;if(!f->sealed)f->retired=true;}if(pendingPresent&&pendingPresent->frame==frame)pendingPresent.reset();}

};
inline Context& Instance(){return optishade::route::OutputOwned<Context,7>();}
template<class F> void Each(F&& fn){
 const auto entries=optishade::route::Outputs().Snapshot();
 for(unsigned i=1;i<optishade::route::OutputDirectory::Capacity;++i){const auto& e=entries[i];
  if(e.used&&e.key.route==5){optishade::route::OutputScope scope(i);fn(Instance());}
 }
}
template<class F> void ForSwap(IDXGISwapChain* swap,F&& fn){
 const auto id=optishade::taa::SwapchainIdentity(swap);
 Each([&](Context& context){if(optishade::taa::SwapchainIdentity(context.swapchain.Get())==id||context.providerSwap==swap)fn(context);});
}

} // namespace NativeTaaFg
bool NativeTaaFgContractOwnsFallback(uint64_t deviceIdentity,unsigned width,unsigned height){
 if(!deviceIdentity||!width||!height)return false;
 auto lock=g_nrEvents.Lock();bool owns=false;
 NativeTaaFg::Each([&](auto& context){
  if(owns||context.resizePending||!context.queue||
     !optishade::taa::NativeCompositionAllowed(State::Instance().dlssgTemporalSignature.load(std::memory_order_relaxed)))return;
  for(const auto& frame:context.frames){
   if(!frame||frame->failed||frame->retired||frame->presentReturned||
      frame->id.device!=deviceIdentity||(!frame->sealed&&!frame->retagged)||
      (frame->mask&0x0du)!=0x0du)continue;
   auto* color=static_cast<ID3D12Resource*>(frame->resources[0].native);
   if(!color)continue;
   const auto desc=color->GetDesc();
   if(desc.Dimension==D3D12_RESOURCE_DIMENSION_TEXTURE2D&&desc.Width==width&&desc.Height==height){owns=true;break;}
  }
 });
 return owns;
}
// Streamline may call these on the simulation thread while the render thread
// owns NR and waits inside the provider. Copy notifications into the existing
// ordered inbox; never retain caller-owned constants or wait on NR here.
void TaaFgNewFrameToken(uint32_t f){if(!TaaPreFgUsed())return;NrSubmissionEvent e;e.frameToken=f;g_nrEvents.Post(std::move(e));}
void ConsumeNrFrameNotification(const NrSubmissionEvent& e){
 NativeTaaFg::Each([&](auto& c){if(e.constants)c.TaaFgAcceptedConstants(*e.constants,*e.frameToken,e.viewport);else c.TaaFgNewFrameToken(*e.frameToken);});
}
void TaaFgLegacyPresent(){if(!TaaPreFgUsed())return;NativeTaaFg::Each([](auto& c){c.TaaFgLegacyPresent();});}
void TaaFgBindOutput(IDXGISwapChain* s,ID3D12CommandQueue* q){
 auto lock=g_nrEvents.Lock();if(!s||!q)return;
 Microsoft::WRL::ComPtr<ID3D12Device> device;if(FAILED(q->GetDevice(IID_PPV_ARGS(&device))))return;
 optishade::route::OutputScope scope(optishade::route::OutputKey{reinterpret_cast<uint64_t>(optishade::ReShadeDeviceIdentity(device.Get()).Get()),optishade::taa::SwapchainIdentity(s),0,0,5});
 if(scope)NativeTaaFg::Instance().TaaFgBindOutput(s,q);
}
void TaaFgReset(){auto lock=g_nrEvents.Lock();NativeTaaFg::Each([](auto& c){c.TaaFgReset();});}
bool TaaFgBeginResize(ID3D12CommandQueue* q){
 auto lock=g_nrEvents.Lock();bool matched=false;
 NativeTaaFg::Each([&](auto& c){if(c.MatchesQueue(q)){c.TaaFgBeginResize(q);matched=true;}});
 return matched;
}
void TaaFgEndResize(ID3D12CommandQueue* q){
 auto lock=g_nrEvents.Lock();NativeTaaFg::Each([&](auto& c){c.TaaFgEndResize(q);});
}
void TaaFgQueueIdleCompleted(ID3D12CommandQueue* q,ID3D12Fence* f,uint64_t v){
 auto lock=g_nrEvents.Lock();NativeTaaFg::Each([&](auto& c){c.TaaFgQueueIdleCompleted(q,f,v);});
}
bool TaaFgReadyToRetire(){
 auto lock=g_nrEvents.Lock();bool ready=true;
 NativeTaaFg::Each([&](auto& c){c.Collect();for(const auto& frame:c.frames)if(frame)ready=false;});
 return ready;
}
uint32_t TaaFgPendingCount(){
 auto lock=g_nrEvents.Lock();uint32_t pending=0;
 NativeTaaFg::Each([&](auto& c){for(const auto& frame:c.frames)if(frame)++pending;});
 return pending;
}
void TaaFgReleaseOutput(IDXGISwapChain* s){auto lock=g_nrEvents.Lock();NativeTaaFg::ForSwap(s,[&](auto& c){c.TaaFgReleaseOutput(s);});}
void TaaFgInvalidate(uint32_t v){if(!TaaPreFgUsed())return;auto lock=g_nrEvents.Lock();NativeTaaFg::Each([&](auto& c){c.TaaFgInvalidate(v);});}
void TaaFgAcceptedConstants(const sl::Constants& c,uint32_t f,uint32_t v){if(HeadsetPresenting()||!TaaPreFgUsed())return;NrSubmissionEvent e;e.frameToken=f;e.viewport=v;e.constants=std::make_shared<sl::Constants>(c);e.constants->next=nullptr;g_nrEvents.Post(std::move(e));}
// TAA NR before FG never applies to headset views (projection frames). With
// the OptiMFG observer installed (R327) the tag hooks still ran per eye with
// NR off in the headset (OSD-QMRM); leave them as plain pass-through in VR.
void TaaFgLegacyTags(ID3D12GraphicsCommandList* c,const sl::ResourceTag* t,uint32_t n,uint32_t v){if(HeadsetPresenting()||!TaaPreFgUsed())return;auto lock=g_nrEvents.Lock();NativeTaaFg::Each([&](auto& output){output.TaaFgLegacyTags(c,t,n,v);});}
void TaaFgBeforeTags(ID3D12GraphicsCommandList* c,const sl::ResourceTag* t,uint32_t n,uint32_t f,uint32_t v){if(HeadsetPresenting()||!TaaPreFgUsed())return;auto lock=g_nrEvents.Lock();NativeTaaFg::Each([&](auto& output){output.TaaFgBeforeTags(c,t,n,f,v);});}
bool TaaFgPrepare(uint32_t f,bool legacy,sl::ResourceTag* t,uint32_t& v,uint32_t& producer){
 // New pre-FG work needs TAA selected now, not only used earlier in this session:
 // OSD hang PID 41920 was on DLSS NR, stuck on this lock on the render thread.
 // Completion callbacks stay on the session latch so frames in flight still finish.
 if(HeadsetPresenting()||!TaaPreFgUsed()||!OptiShadeTaaRequested())return false;
 auto lock=g_nrEvents.Lock();unsigned selected=0,count=0;
 NativeTaaFg::Each([&](auto& c){if(c.swapchain){selected=optishade::route::OutputIndex();++count;}});
 // The marker alone has no output identity. Do not guess between outputs;
 // the provider-input Present path below supplies the exact swapchain.
 if(count!=1)return false;optishade::route::OutputScope scope(selected);return NativeTaaFg::Instance().TaaFgPrepare(f,legacy,t,v,producer);
}
void TaaFgTagsAccepted(uint32_t f,uint32_t v,bool a){if(!TaaPreFgUsed())return;auto lock=g_nrEvents.Lock();NativeTaaFg::Each([&](auto& c){c.TaaFgTagsAccepted(f,v,a);});}
void TaaFgInputsConsumed(uint32_t view,ID3D12Fence* f,uint64_t v){if(!TaaPreFgUsed())return;auto lock=g_nrEvents.Lock();NativeTaaFg::Each([&](auto& c){c.TaaFgInputsConsumed(view,f,v);});}
void TaaFgPresentReturned(uint32_t f){if(!TaaPreFgUsed())return;auto lock=g_nrEvents.Lock();NativeTaaFg::Each([&](auto& c){c.TaaFgPresentReturned(f);});}
void TaaFgPresentResult(IDXGISwapChain* s,HRESULT r){if(!TaaPreFgUsed())return;auto lock=g_nrEvents.Lock();NativeTaaFg::ForSwap(s,[&](auto& c){c.TaaFgPresentResult(s,r);});}
void TaaFgBeforePresent(IDXGISwapChain* s,ID3D12CommandQueue* q){if(!TaaPreFgUsed())return;auto lock=g_nrEvents.Lock();NativeTaaFg::ForSwap(s,[&](auto& c){c.TaaFgBeforePresent(s,q);});}
bool TaaFgProviderPrepare(IDXGISwapChain* s,sl::ResourceTag* t,uint32_t& v,uint32_t& p){
 if(HeadsetPresenting()||!TaaPreFgUsed()||!OptiShadeTaaRequested())return false;
 auto lock=g_nrEvents.Lock();unsigned selected=0,count=0;DXGI_SWAP_CHAIN_DESC desc{};if(!s||FAILED(s->GetDesc(&desc)))return false;
 NativeTaaFg::Each([&](auto& c){DXGI_SWAP_CHAIN_DESC bound{};if(c.swapchain&&SUCCEEDED(c.swapchain->GetDesc(&bound))&&bound.OutputWindow==desc.OutputWindow){selected=optishade::route::OutputIndex();++count;}});
 if(count!=1)return false;optishade::route::OutputScope scope(selected);return NativeTaaFg::Instance().TaaFgProviderPrepare(s,t,v,p);
}
void TaaFgProviderCommit(IDXGISwapChain* s){if(!TaaPreFgUsed())return;auto lock=g_nrEvents.Lock();NativeTaaFg::ForSwap(s,[&](auto& c){c.TaaFgProviderCommit(s);});}
void TaaFgTraceStop(){auto lock=g_nrEvents.Lock();NativeTaaFg::Each([](auto& c){c.trace.Stop();});}
