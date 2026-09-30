#include "../shared/UpdateNoticePolicy.h"
#include <cassert>
#include <cstdio>
int main(){
 using optishade::update_notice::Available;
 const char* both=R"([{"tag_name":"v9.0.0","draft":false,"prerelease":false},{"tag_name":"v0.21.4-beta.10","draft":false,"prerelease":true}])";
 assert(Available(both,"0.21.4")==true);
 assert(Available(both,"0.21.4-beta.2")==true);
 assert(Available(both,"0.21.4-beta.10")==false);
 assert(Available(R"([{"tag_name":"v9.0.0","draft":false,"prerelease":false}])","0.21.4-beta.1")==false);
 assert(Available(R"([{"tag_name":"v9.0.0-beta.1","draft":false,"prerelease":true}])","0.21.4")==false);
 assert(Available(R"([{"tag_name":"v9.0.0-beta.1","draft":false,"prerelease":false},{"tag_name":"v9.0.0-beta.2","draft":true,"prerelease":true}])","0.21.4-beta.1")==false);
 assert(Available(R"({"tag_name":"v0.21.4","draft":false,"prerelease":false})","0.21.4")==false);
 assert(Available("[]","0.21.4-beta.1")==false);
 assert(!Available("broken","0.21.4"));
 assert(!Available("[]","unknown"));
 assert(Available(R"([{"tag_name":"v0.21.5-beta","draft":false,"prerelease":true},{"tag_name":"v9.0.0","draft":false,"prerelease":false}])","0.21.3-beta.5")==true);
 assert(Available(R"([{"tag_name":"v0.21.5-beta","draft":false,"prerelease":true},{"tag_name":"v9.0.0","draft":false,"prerelease":false}])","0.21.5-beta")==false);
 assert(Available(R"([{"tag_name":"v0.21.6-beta","draft":false,"prerelease":true}])","0.21.5-beta")==true);
 assert(!Available("[]","0.21.5-beta."));
 assert(!Available("[]","0.21.5-beta-"));
 puts("PASS: overlay notices isolate stable/beta, numeric beta revisions, drafts and malformed feeds");
}
