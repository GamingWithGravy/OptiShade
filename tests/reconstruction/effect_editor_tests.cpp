#include "EffectEditorCache.h"
#include <cassert>
#include <iostream>
#include <memory>
int main(){
 using optishade::effects_ui::EditorCache;
 EditorCache cache;cache.Sync(7);assert(cache.SetOpen("A.fx",true));assert(cache.SetOpen("B.fx",true));
 auto s=std::make_unique<osfx::Snapshot>();s->generation=7;
 auto reply=[&](const osfx::Command& c,unsigned total,unsigned n){
  s->inspectSerial=c.inspectSerial;std::strcpy(s->inspectedEffect,c.effect);s->uniformPage=c.enabled;s->uniformTotal=total;s->uniforms=n;
  std::strcpy(s->inspectedDescription,"Effect description from shader annotations");
  for(unsigned i=0;i<n;i++)std::strcpy(s->uniform[i].effect,c.effect);
 };
 osfx::Command a{},b{},next{};assert(cache.Next(100,a));assert(!cache.Next(101,next));
 reply(a,513,512);s->generation=6;assert(!cache.Accept(*s));s->generation=7;
 s->inspectSerial++;assert(!cache.Accept(*s));s->inspectSerial--;
 assert(cache.Accept(*s));assert(!cache.Accept(*s));
 assert(cache.effects.at("A.fx").description=="Effect description from shader annotations");
 assert(cache.Next(110,b));assert(std::string(b.effect)=="B.fx");reply(b,1,1);assert(cache.Accept(*s));
 assert(cache.Next(120,next));assert(std::string(next.effect)=="A.fx"&&next.enabled==1);
 reply(next,513,1);assert(cache.Accept(*s));assert(cache.effects.at("A.fx").pages.size()==2);assert(cache.effects.at("B.fx").pages.size()==1);
 assert(cache.Next(130,next));assert(!cache.Next(131,a));assert(cache.Next(2130,a));reply(next,1,1);assert(!cache.Accept(*s));
 cache.SetOpen(a.effect,false);reply(a,0,0);assert(!cache.Accept(*s));
 cache.Sync(8);assert(cache.effects.empty());assert(!cache.Accept(*s));
 cache.SetOpen("Empty.fx",true);cache.Next(2200,a);s->generation=8;reply(a,0,0);assert(cache.Accept(*s));assert(cache.effects.at("Empty.fx").known);
 cache.Next(2210,a);reply(a,1,1);std::strcpy(s->uniform[0].effect,"Other.fx");assert(!cache.Accept(*s));
 std::cout<<"Editor cache: multiple FX/pages, stale generation/serial, timeout, close and empty response checks passed (CPU only)\n";
}
