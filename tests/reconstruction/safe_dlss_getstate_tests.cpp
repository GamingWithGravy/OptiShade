#include "SafeDlssGetState.h"
#include <cstdio>

static unsigned calls=0;
static sl::Result GoodState(const sl::ViewportHandle&,sl::DLSSGState&,const sl::DLSSGOptions*){++calls;return sl::Result::eOk;}
static sl::Result FaultState(const sl::ViewportHandle&,sl::DLSSGState&,const sl::DLSSGOptions*){++calls;ULONG_PTR info[2]={1,0x128};RaiseException(EXCEPTION_ACCESS_VIOLATION,0,2,info);return sl::Result::eOk;}
static sl::Result GoodOptions(const sl::ViewportHandle&,const sl::DLSSGOptions&){++calls;return sl::Result::eOk;}
static sl::Result FaultOptions(const sl::ViewportHandle&,const sl::DLSSGOptions&){++calls;ULONG_PTR info[2]={1,0x128};RaiseException(EXCEPTION_ACCESS_VIOLATION,0,2,info);return sl::Result::eOk;}

int main(){
    sl::ViewportHandle viewport(1);sl::DLSSGState state{};sl::DLSSGOptions options{};
    std::atomic<bool> faultLatch{false};
    auto good=optishade::native_mfg::InvokeGetStateGuarded(&GoodState,viewport,state,&options,&faultLatch);
    if(good.result!=sl::Result::eOk||good.exceptionCode||calls!=1){std::fprintf(stderr,"good provider call was not preserved\n");return 1;}
    auto fault=optishade::native_mfg::InvokeGetStateGuarded(&FaultState,viewport,state,&options,&faultLatch);
    if(fault.result!=sl::Result::eErrorExceptionHandler||fault.exceptionCode!=EXCEPTION_ACCESS_VIOLATION||
       !fault.exceptionAddress||fault.accessOperation!=1||fault.faultAddress!=0x128||!faultLatch.load()||calls!=2){std::fprintf(stderr,"provider write access violation was not contained with its exception context\n");return 2;}
    auto suppressed=optishade::native_mfg::InvokeGetStateGuarded(&FaultState,viewport,state,&options,&faultLatch);
    if(suppressed.result!=sl::Result::eErrorExceptionHandler||!suppressed.suppressedAfterFault||suppressed.exceptionCode||calls!=2){std::fprintf(stderr,"provider callback was queried again after its fault\n");return 3;}
    faultLatch.store(false);
    auto setGood=optishade::native_mfg::InvokeSetOptionsGuarded(&GoodOptions,viewport,options,&faultLatch);
    if(setGood.result!=sl::Result::eOk||setGood.exceptionCode||calls!=3){std::fprintf(stderr,"good SetOptions provider call was not preserved\n");return 4;}
    auto setFault=optishade::native_mfg::InvokeSetOptionsGuarded(&FaultOptions,viewport,options,&faultLatch);
    if(setFault.result!=sl::Result::eErrorExceptionHandler||setFault.exceptionCode!=EXCEPTION_ACCESS_VIOLATION||
       !setFault.exceptionAddress||setFault.accessOperation!=1||setFault.faultAddress!=0x128||!faultLatch.load()||calls!=4){std::fprintf(stderr,"SetOptions access violation was not contained with its exception context\n");return 5;}
    auto setSuppressed=optishade::native_mfg::InvokeSetOptionsGuarded(&FaultOptions,viewport,options,&faultLatch);
    if(setSuppressed.result!=sl::Result::eErrorExceptionHandler||!setSuppressed.suppressedAfterFault||setSuppressed.exceptionCode||calls!=4){std::fprintf(stderr,"SetOptions was called again after its provider fault\n");return 6;}
    std::puts("PASS: provider success passes through; GetState and SetOptions access violations are contained, diagnosed and latched; later callback calls are suppressed");
    return 0;
}
