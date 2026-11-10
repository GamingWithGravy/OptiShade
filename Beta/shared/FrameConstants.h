#pragma once
#include <cstdint>
namespace optishade::route {
template<class T> class FrameConstantWindow {
    struct Slot { bool valid=false,consumed=false,hasValue=false;uint32_t frame=0,view=0;T value{}; };
    Slot slots[8]{};
    bool haveOwner=false,haveNewest=false,haveConsumed=false;
    uint32_t owner=0,newest=0,lastConsumed=0;
public:
    bool AcceptedConstants(uint32_t frame,uint32_t view,const T* value=nullptr) {
        if(haveOwner && view!=owner)return false;
        if(haveConsumed && static_cast<int32_t>(frame-lastConsumed)<=0)return false;
        if(haveNewest && static_cast<int32_t>(frame-newest)<-7)return false;
        if(!haveNewest || static_cast<int32_t>(frame-newest)>0){newest=frame;haveNewest=true;}
        auto& slot=slots[frame%8];
        if(slot.valid && slot.frame==frame && (slot.view!=view || slot.consumed))return false;
        slot.valid=true;slot.frame=frame;slot.view=view;slot.consumed=false;
        slot.hasValue=value!=nullptr;if(value)slot.value=*value;
        return true;
    }
    bool Matches(uint32_t frame,uint32_t view)const {
        const auto& slot=slots[frame%8];
        return slot.valid && !slot.consumed && slot.frame==frame && slot.view==view &&
            (!haveOwner||owner==view) && (!haveConsumed||static_cast<int32_t>(frame-lastConsumed)>0) &&
            (!haveNewest||static_cast<int32_t>(frame-newest)>=-7);
    }
    bool Constants(uint32_t frame,uint32_t view,T& out)const {
        if(!Matches(frame,view)||!slots[frame%8].hasValue)return false;
        out=slots[frame%8].value;return true;
    }
    void Consume(uint32_t view,uint32_t frame){
        if(!Matches(frame,view))return;
        owner=view;haveOwner=true;slots[frame%8].consumed=true;lastConsumed=frame;haveConsumed=true;
    }
    void Consume(uint32_t view){Consume(view,newest);}
    void Reset(){for(auto& slot:slots)slot={};haveOwner=haveNewest=haveConsumed=false;owner=newest=lastConsumed=0;}
};
}
