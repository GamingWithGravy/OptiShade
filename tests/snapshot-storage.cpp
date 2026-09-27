// OptiShade additions, GPL-3.0-or-later.
#include "../shared/SnapshotStorage.h"
#include <cassert>
#include <iostream>
int wmain(int argc,wchar_t** argv){
 assert(argc==4);
 const std::filesystem::path physical=argv[1],alias=argv[2],redirected=argv[3];
 const auto expected=physical/L"Optishade Snapshots";
 assert(optishade::snapshot::folder(physical.u8string())==expected);
 assert(optishade::snapshot::folder(alias.u8string())==expected);
 bool rejected=false;
 try{optishade::snapshot::folder("relative");}catch(...){rejected=true;}
 assert(rejected);
 rejected=false;
 try{optishade::snapshot::folder(redirected.u8string());}catch(...){rejected=true;}
 assert(rejected); // A linked destination is not an installation alias.
 std::cout<<"PASS: physical game path, installation alias, relative rejection, linked capture-folder rejection\n";
}
