"""Exercise the production XeLL limiter update against controlled backend responses."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
source = (root/'optiscaler/OptiScaler/hooks/Xell_Hooks.cpp').read_text()
body = source[source.index('bool XellHooks::update()'):source.index('xell_result_t XellHooks::hkxellDestroyContext')]
prefix = r'''
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cassert>
#include <cstdio>
#include <limits>
struct xell_sleep_params_t { bool bLowLatencyMode=true; uint32_t minimumIntervalUs=0; } backend;
constexpr int XELL_RESULT_SUCCESS=0;
bool gamesContextCanLimitFps=false,blockExternal=false;
void* gamesContext=reinterpret_cast<void*>(1);
bool queryOk=true,setOk=true;int writes=0;
int get(void*,xell_sleep_params_t* p){if(!queryOk)return -1;*p=backend;return 0;}
int set(void*,const xell_sleep_params_t* p){++writes;if(!setOk)return -1;backend=*p;return 0;}
auto o_xellGetSleepMode=&get;auto o_xellSetSleepMode=&set;
struct Optional {float value=60;float value_or_default(){return value;}};
struct Config {Optional FramerateLimit;static Config* Instance(){static Config c;return &c;}};
struct XellHooks {static bool update();};
'''
suffix = r'''
int main(){
 assert(XellHooks::update() && gamesContextCanLimitFps && backend.minimumIntervalUs==16667);
 int before=writes;assert(!XellHooks::update() && gamesContextCanLimitFps && writes==before);
 backend.bLowLatencyMode=false;assert(!XellHooks::update() && !gamesContextCanLimitFps);
 backend.bLowLatencyMode=true;queryOk=false;assert(!XellHooks::update() && !gamesContextCanLimitFps);
 queryOk=true;backend.minimumIntervalUs=0;setOk=false;
 assert(!XellHooks::update() && !gamesContextCanLimitFps);
 setOk=true;assert(XellHooks::update() && gamesContextCanLimitFps);
 gamesContext=reinterpret_cast<void*>(2);backend.minimumIntervalUs=0;
 assert(XellHooks::update() && backend.minimumIntervalUs==16667);
 backend.minimumIntervalUs=500;assert(XellHooks::update() && backend.minimumIntervalUs==16667);
 blockExternal=true;assert(!XellHooks::update() && !gamesContextCanLimitFps);blockExternal=false;
 gamesContext=nullptr;assert(!XellHooks::update() && !gamesContextCanLimitFps);gamesContext=reinterpret_cast<void*>(2);
 Config::Instance()->FramerateLimit.value=0;assert(XellHooks::update() && backend.minimumIntervalUs==0);
 backend.minimumIntervalUs=100;Config::Instance()->FramerateLimit.value=std::numeric_limits<float>::quiet_NaN();
 assert(XellHooks::update() && backend.minimumIntervalUs==0);
 puts("PASS: XeLL limit applies, avoids redundant writes, retries failure, releases fallback, follows context/parameter changes and resets safely");
}
'''
out = root/'test-run/xell-limiter.cpp'
out.parent.mkdir(exist_ok=True)
out.write_text(prefix+body+suffix)
