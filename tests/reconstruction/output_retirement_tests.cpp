#include "OutputDomain.h"
#include "TaaOutputRetirement.h"
#include <iostream>
#include <stdexcept>
#include <limits>
using namespace optishade::route;
static unsigned checks=0;
void require(bool value){++checks;if(!value)throw std::runtime_error("Output retirement check failed");}
struct Resource { inline static unsigned destroyed=0; ~Resource(){++destroyed;} };
struct CallbackResource { inline static void (*callback)()=nullptr; ~CallbackResource(){if(callback)callback();} };
static OutputStorage<CallbackResource>* callbackStorage=nullptr;
int main(){try{
    OutputDirectory outputs;OutputStorage<Resource> resources;
    OutputKey key{1,2,3,0,1};const auto slot=outputs.FindOrAdd(key);require(slot==1);
    resources.Get(slot);outputs.selected=slot;
    require(!outputs.CompleteRetirement(slot,key,true));
    require(outputs.RetireOwner(2,1)==1);
    require(outputs.FindOrAdd(key)==OutputDirectory::Capacity);
    require(!outputs.CompleteRetirement(slot,key,false));require(Resource::destroyed==0);
    auto wrong=key;++wrong.generation;require(!outputs.CompleteRetirement(slot,wrong,true));
    resources.Release(slot);require(Resource::destroyed==1);
    require(outputs.CompleteRetirement(slot,key,true));require(outputs.selected==0);
    require(!outputs.CompleteRetirement(slot,key,true));
    const auto native=outputs.FindOrAdd({1,2,3,0,5});require(native==slot);
    require(outputs.RetireOwner(2,1)==0);require(!outputs.Snapshot()[native].retiring);
    outputs.selected=native;
    for(unsigned i=0;i<96;++i){
        OutputKey current{1,100+i,1,0,1};const auto s=outputs.FindOrAdd(current);require(s==2);
        resources.Get(s);require(outputs.RetireOwner(current.owner,1)==1);
        require(!outputs.CompleteRetirement(s,key,true));resources.Release(s);
        require(outputs.CompleteRetirement(s,current,true));require(outputs.selected==native);
    }
    // Re-entry may not steal any of the 31 slots while their resources are held.
    for(unsigned i=2;i<OutputDirectory::Capacity;++i)require(outputs.FindOrAdd({1,1000+i,1,0,1})==i);
    require(outputs.FindOrAdd({1,9999,1,0,1})==OutputDirectory::Capacity);
    require(outputs.RetireOwner(1002,1)==1);
    require(outputs.FindOrAdd({1,9999,1,0,1})==OutputDirectory::Capacity);
    resources.Get(2);resources.Release(2);
    require(outputs.CompleteRetirement(2,{1,1002,1,0,1},true));
    require(outputs.FindOrAdd({1,9999,1,0,1})==2);
    require(!outputs.CompleteRetirement(2,{1,1002,1,0,1},true));
    using optishade::taa::PrivateSubmitRetired;
    require(!PrivateSubmitRetired(false,false,true,7,8));
    require(PrivateSubmitRetired(false,false,true,8,8));
    require(!PrivateSubmitRetired(false,false,true,std::numeric_limits<uint64_t>::max(),8));
    require(!PrivateSubmitRetired(true,false,true,8,8));
    require(!PrivateSubmitRetired(false,true,true,8,8));
    require(!PrivateSubmitRetired(false,false,false,0,1));
    require(PrivateSubmitRetired(false,false,false,0,0));
    OutputStorage<CallbackResource> callbacks;callbackStorage=&callbacks;callbacks.Get(1);
    CallbackResource::callback=[](){CallbackResource::callback=nullptr;callbackStorage->Get(0);};
    callbacks.Release(1);require(callbacks.values[0]!=nullptr);require(callbacks.values[1]==nullptr);
    std::cout<<checks<<" output retirement checks passed; native FG route preserved.\n";
    return 0;
}catch(const std::exception& error){std::cerr<<error.what()<<" at "<<checks<<'\n';return 1;}}
