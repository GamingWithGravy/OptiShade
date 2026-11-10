#include "EffectsBridge.h"
#include <cassert>
#include <cstring>
#include <iostream>

int main(){
 osfx::EditAckJournal journal{};
 journal.record(41,osfx::EditResultApplied,"Bloom.fx","Intensity");
 assert(journal.sequence==1);
 const auto& first=journal.entries[1];
 assert(first.sequence==1&&first.request==41&&first.result==osfx::EditResultApplied);
 assert(std::strcmp(first.effect,"Bloom.fx")==0&&std::strcmp(first.name,"Intensity")==0);
 journal.record(42,osfx::EditResultPerformanceMode,"Bloom.fx","Intensity");
 assert(journal.entries[2].request==42&&journal.entries[2].result==osfx::EditResultPerformanceMode);
 for(uint64_t request=43;request<=41+osfx::EditAckCapacity;++request)
  journal.record(request,osfx::EditResultInvalidShape,"Array.fx","Color");
 assert(journal.sequence==osfx::EditAckCapacity+1);
 const auto& wrapped=journal.entries[journal.sequence%osfx::EditAckCapacity];
 assert(wrapped.sequence==journal.sequence&&wrapped.request==41+osfx::EditAckCapacity);
 const auto& overwritten=journal.entries[1];
 assert(overwritten.sequence==journal.sequence&&overwritten.request==41+osfx::EditAckCapacity);
 assert(sizeof(osfx::Snapshot)>sizeof(osfx::EditAckJournal));
 std::cout<<"Per-uniform edit acknowledgement journal: result identity, bounded names and wraparound passed (CPU only)\n";
}
