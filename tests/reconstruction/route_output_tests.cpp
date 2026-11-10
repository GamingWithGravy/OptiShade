#include <Windows.h>
#include <iostream>
#include <stdexcept>
#include "SimulatorRoute.h"
using namespace optishade::route;
int wmain(int argc,wchar_t** argv){try{
 if(argc!=2)return 2;auto module=LoadLibraryW(argv[1]);if(!module)throw std::runtime_error("Route DLL load failed");
 using Fn=bool(*)(const ConstantRequest*,uint32_t,void*,uint32_t);auto call=reinterpret_cast<Fn>(GetProcAddress(module,"OptiShadeRouteConstants"));if(!call)throw std::runtime_error("Missing constants export");
 auto check=[](bool v){if(!v)throw std::runtime_error("Route isolation failed");};
 auto store=[&](uint64_t owner,uint32_t view,uint32_t frame,uint32_t value){ConstantRequest r;r.event=ConstantEvent::Store;r.owner=owner;r.device=9;r.view=view;r.frame=frame;r.payload=&value;r.payloadBytes=sizeof(value);return call(&r,sizeof(r),nullptr,0);};
 auto read=[&](uint64_t owner,uint32_t view,uint32_t frame,uint32_t value){ConstantRequest r;r.event=ConstantEvent::Read;r.owner=owner;r.device=9;r.view=view;r.frame=frame;uint32_t out=0;return call(&r,sizeof(r),&out,sizeof(out))&&out==value;};
 check(store(1,0,10,100));check(store(1,1,10,200));check(store(2,0,10,300));
 check(read(1,0,10,100));check(read(1,1,10,200));check(read(2,0,10,300));
 ConstantRequest r;r.device=9;r.owner=1;r.view=0;r.frame=10;r.event=ConstantEvent::Consume;check(call(&r,sizeof(r),nullptr,0));check(!read(1,0,10,100));check(read(1,1,10,200));
 r.event=ConstantEvent::Reset;check(call(&r,sizeof(r),nullptr,0));check(!read(1,1,10,200));check(read(2,0,10,300));
 r.abi=Abi-1;check(!call(&r,sizeof(r),nullptr,0));FreeLibrary(module);
 std::cout<<"Actual route DLL: eye/output constants, scoped consumption/reset and mixed-ABI refusal passed.\n";return 0;
 }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
