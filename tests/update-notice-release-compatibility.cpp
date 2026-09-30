#include "../shared/UpdateNoticePolicy.h"
#include <cassert>
#include <cstdio>

int main()
{
    using optishade::update_notice::Available;
    using optishade::update_notice::Parse;
    const char* releases=R"([
        {"tag_name":"v0.21.4","draft":false,"prerelease":false},
        {"tag_name":"v0.21.5-beta.1","draft":false,"prerelease":true}
    ])";
    assert(Available(releases,"0.21.3")==true);
    assert(Available(releases,"0.21.4")==false);
    assert(Available(releases,"0.21.3-beta.4")==true);
    assert(Available(releases,"0.21.5-beta.1")==false);
    const auto canonical=Parse("0.21.5-beta.1");
    assert(canonical && canonical->beta && canonical->revision==1);
    assert(Available(R"([{"tag_name":"v9.0.0","draft":false,"prerelease":false}])","0.21.5-beta.1")==false);
    assert(Available(R"([{"tag_name":"v9.0.0-beta.1","draft":false,"prerelease":true}])","0.21.4")==false);
    assert(Available(R"([{"tag_name":"v0.21.5-beta.1","draft":true,"prerelease":true}])","0.21.3-beta.4")==false);
    assert(Available(R"([{"tag_name":"v0.21.5-beta.1","draft":false,"prerelease":false}])","0.21.3-beta.4")==false);
    assert(Available(R"([{"tag_name":"v0.21.5-beta.10","draft":false,"prerelease":true}])","0.21.5-beta.2")==true);
    assert(Available(R"([{"tag_name":"v0.21.5-beta","draft":false,"prerelease":true}])","0.21.5-beta.1")==false);
    assert(Available(R"([{"tag_name":"v0.21.6-beta.1","draft":false,"prerelease":true}])","0.21.5-beta.1")==true);
    puts("PASS: native release identity uses beta revision for ordering while isolating channels and rejecting repeated canonical offers");
}
