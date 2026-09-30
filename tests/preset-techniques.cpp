#include "../shared/PresetTechniquePolicy.h"
#include <cassert>
#include <iostream>
int main() {
 using namespace optishade::preset;
 std::vector<Technique> available{{"CAS.fx","ContrastAdaptiveSharpen",true},{"Colour.fx","Colour",true}};
 auto valid=audit({"ContrastAdaptiveSharpen@CAS.fx","Colour@Colour.fx"},available,true);
 assert(valid.state==State::Applied&&valid.applied==2);
 auto mismatch=audit({"CAS@CAS.fx","Colour@Colour.fx"},available,true);
 assert(mismatch.state==State::Partial&&mismatch.applied==1&&mismatch.missing[0]=="CAS@CAS.fx (not compiled)");
 auto none=audit({"CAS@CAS.fx"},available,true);
 assert(none.state==State::Failed&&none.applied==0); // Basename is never an alias.
 assert(audit({"CAS@CAS.fx"},available,false).state==State::Failed);
 assert(audit({"Colour@Colour.fx"},available,false).state==State::Partial); // Other compile failures remain visible.
 auto duplicate=available;duplicate.push_back({"Colour.fx","Colour",true});
 assert(audit({"Colour@Colour.fx"},duplicate,true).missing[0]=="Colour@Colour.fx (ambiguous)");
 duplicate=available;duplicate.push_back({"Other.fx","Colour",true});
 assert(audit({"Colour"},duplicate,true).state==State::Failed);
 assert(audit({"Colour@Colour.fx"},duplicate,true).state==State::Applied);
 available[1].enabled=false;
 assert(audit({"Colour@Colour.fx"},available,true).missing[0]=="Colour@Colour.fx (not enabled)");
 assert(audit({"Colour@Colour.fx"},available,true,false,true,true).state==State::Edited);
 assert(audit({"Colour@Colour.fx"},available,true,false,false).state==State::Disabled);
 assert(audit({},available,true).state==State::Applied); // An intentional empty preset is valid.
 assert(audit({},available,true,true).state!=State::Applied);
 assert(audit({"@CAS.fx"},available,true).state==State::Failed);
 assert(audit({"Colour@"},available,true).state==State::Failed);
 auto repeated=audit({"ContrastAdaptiveSharpen@CAS.fx","ContrastAdaptiveSharpen@CAS.fx"},available,true);
 assert(repeated.requested==1&&repeated.applied==1);
 std::cout<<"PASS: exact compiled identities, CAS mismatch, ambiguity, compile errors, disabled/edited and empty presets\n";
}
