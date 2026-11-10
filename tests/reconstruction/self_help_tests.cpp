#include "SelfHelp.h"
#include <stdexcept>
#include <iostream>
#define CHECK(x) do{if(!(x))throw std::runtime_error(#x);}while(0)
using namespace optishade::selfhelp;
static bool Says(const Advice& a,const char* cause,const char* step){return Has(a.cause,cause)&&Has(a.tryThis,step);}
int main(){
try{
 // NR waiting: each runtime fact names its own cause and step.
 NrFacts nr;
 CHECK(Says(NrWaiting(nr),"has not started DLSS","graphics settings"));
 nr.upscalerActive=true;
 CHECK(Says(NrWaiting(nr),"has not sent NR a frame","Check my setup"));
 nr.ranEarlier=true;
 CHECK(Says(NrWaiting(nr),"ran earlier","menus"));
 nr.taaRouteSeen=true;nr.taaStatus="Waiting for the game's depth and movement data.";
 CHECK(Says(NrWaiting(nr),"depth and motion","Load into the scene"));
 nr.taaStatus="TAA bridge version mismatch. Repair OptiShade.";
 CHECK(Says(NrWaiting(nr),"do not match","Repair"));
 nr.taaStatus="Waiting for PresentStart marker for the current FG frame token. Late NR is not submitted.";
 CHECK(Says(NrWaiting(nr),"frame generation","TAA NR with frame generation"));
 nr.taaStatus="The game's depth or movement data is not supported.";
 CHECK(Says(NrWaiting(nr),"not supported","DLSS"));
 nr.vulkan=true;nr.vulkanStatus="Waiting for primary Vulkan swapchain";
 CHECK(Says(NrWaiting(nr),"Vulkan route","flight"));
 nr.dx11Native=true;nr.dx11Upscaler="DLSS";
 CHECK(Says(NrWaiting(nr),"using DLSS directly","D3D12 bridge"));
 nr.headsetNrOff=true;
 CHECK(Says(NrWaiting(nr),"VR headset","Use NR in the VR headset"));
 nr.memoryPaused=true;
 CHECK(Says(NrWaiting(nr),"video memory","Pause NR when video memory is low"));
 // OptiMFG: a Windows start error outranks every other reason, antivirus first.
 MfgFacts mfg;
 CHECK(Says(MfgNotConnected(mfg),"first frame","main menu"));
 mfg.startAttempted=true;
 CHECK(Says(MfgNotConnected(mfg),"closed or was blocked","Protection history"));
 mfg.startDisabled=true;
 CHECK(Says(MfgNotConnected(mfg),"Start with game","Start"));
 mfg.autoStartGame=false;
 CHECK(Says(MfgNotConnected(mfg),"only with Microsoft Flight Simulator","component card"));
 mfg.channelOpen=true;
 mfg.heartbeatFresh=true;CHECK(Says(MfgNotConnected(mfg),"not linked","DLSS Frame Generation"));
 mfg.heartbeatFresh=false;CHECK(Says(MfgNotConnected(mfg),"stopped responding","system tray"));
 mfg.startError=kErrorVirusInfected;
 CHECK(Says(MfgNotConnected(mfg),"Windows Security blocked","Protection history"));
 mfg.startError=kErrorFileNotFound;
 CHECK(Says(MfgNotConnected(mfg),"missing","exclusion"));
 mfg.startError=kErrorAccessDenied;
 CHECK(Says(MfgNotConnected(mfg),"access denied","Protection history"));
 mfg.startError=kErrorElevationRequired;
 CHECK(Says(MfgNotConnected(mfg),"administrator","component card"));
 mfg.startError=1234;
 CHECK(Says(MfgNotConnected(mfg),"error 1234","Repair"));
 // Flicker: nothing with NR off; each setting known to flicker is listed.
 FlickerFacts fl;fl.deferredDlss=true;
 CHECK(FlickerSuspects(fl).empty());
 fl.nrOn=true;
 CHECK(FlickerSuspects(fl).size()==1&&Says(FlickerSuspects(fl)[0],"Generate before SR","Turn it off"));
 fl.hdrReplace=fl.residualExperimental=fl.memoryLow=fl.nrStopping=fl.beforeFrameGeneration=fl.estimatedMotion=true;
 const auto all=FlickerSuspects(fl);
 CHECK(all.size()==7);
 CHECK(Says(all.front(),"not finishing frames","NR status"));
 CHECK(Says(all.back(),"estimates motion","DLSS"));
 std::cout<<"Self-help: NR waiting, OptiMFG connection and flicker advice tests passed\n";
}catch(const std::exception&e){std::cerr<<e.what();return 1;}}
