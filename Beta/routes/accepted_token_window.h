#pragma once
// Token allocation is not frame submission: the simulator may allocate N+1
// before publishing constants/tags for N. Keep a bounded set of issued tokens;
// association is established by accepted constants, never the newest allocation.
class Window {
 bool ready=false,ambiguous=false,haveNewest=false;uint32_t frame=0,view=0,newest=0;
 uint32_t issued[8]{};unsigned count=0,next=0;
 bool Issued(uint32_t value)const{for(unsigned i=0;i<count;++i)if(issued[i]==value)return true;return false;}
public:
 void Begin(uint32_t value){
  if(Issued(value))return;
  if(haveNewest&&static_cast<int32_t>(value-newest)<0)return;
  issued[next]=value;next=(next+1)%8;if(count<8)++count;newest=value;haveNewest=true;
 }
 bool Constants(uint32_t value,uint32_t viewport){
  // A successful slSetConstants call proves this exact token even if its
  // allocation preceded hook startup or fell outside the allocation ring.
  if(ready&&static_cast<int32_t>(value-frame)<0)return false;
  if(ready&&value==frame){if(ambiguous||viewport!=view){ambiguous=true;return false;}return true;}
  frame=value;view=viewport;ready=true;ambiguous=false;return true;
 }
 bool Frame(uint32_t viewport,uint32_t& value)const{if(!ready||ambiguous||viewport!=view)return false;value=frame;return true;}
 void Present(){} // Consumer presentation does not retire an issued producer.
 void Reset(){ready=ambiguous=haveNewest=false;frame=view=newest=count=next=0;}
 bool Ambiguous()const{return ambiguous;}
};
