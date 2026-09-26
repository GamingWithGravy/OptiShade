#include <windows.h>
#include <cfloat>
#include <string>
#include <vector>
#include <cassert>
#include <iostream>
static ULONGLONG testNow=1000;
#define GetTickCount64() testNow
struct ImVec2{float x,y;ImVec2(float a=0,float b=0):x(a),y(b){}};
#define IM_COL32(r,g,b,a) 0U
struct Font{ImVec2 CalcTextSizeA(float size,float,float,const char* t){return ImVec2(float(strlen(t))*size*.5f,size);}};
struct DrawList{std::vector<std::string> text;void AddText(Font*,float,ImVec2,unsigned,const char* t){text.push_back(t);}};
namespace ImGui{static Font font;static DrawList draw;Font* GetFont(){return &font;}float GetFontSize(){return 16;}ImVec2 GetWindowPos(){return ImVec2(10,10);}float GetWindowWidth(){return 680;}ImVec2 GetItemRectMax(){return ImVec2(640,35);}DrawList* GetWindowDrawList(){return &draw;}}
#if __has_include("../../OptiShadeFusion/optiscaler/OptiScaler/menu/optishade_update_notice.inl")
#include "../../OptiShadeFusion/optiscaler/OptiScaler/menu/optishade_update_notice.inl"
#else
#include "../optiscaler/OptiScaler/menu/optishade_update_notice.inl"
#endif
int main(){
using namespace OptiShadeUpdates;
assert(ApplyReleaseResponse("{\"tag_name\":\"v" OPTISHADE_VERSION_TEXT "\"}"));
assert(!available);
assert(ApplyReleaseResponse("{\"tag_name\":\"v0.20.9\"}"));
assert(!available);
assert(ApplyReleaseResponse("{\"tag_name\":\"v0.20.12.1\"}"));
assert(available);
assert(ApplyReleaseResponse("{\"tag_name\":\"v0.20.7\"}"));
assert(!available);
assert(ApplyReleaseResponse("{\"tag_name\":\"v0.20.13\"}"));
assert(available);
assert(ApplyReleaseResponse("{\"tag_name\":\"v" OPTISHADE_VERSION_TEXT "\"}"));
assert(!available);
assert(ApplyReleaseResponse("{\"tag_name\":\"v0.21.0\"}"));
assert(available);
assert(ApplyReleaseResponse("{\"tag_name\":\"v1.0.0\"}"));
assert(available);
assert(ApplyReleaseResponse("{\"tag_name\":\"0.20\"}"));
assert(!available);
assert(!ApplyReleaseResponse("{\"tag_name\":\"v0.20.10-beta\"}"));
assert(!available);
assert(!ApplyReleaseResponse("{}"));
assert(!available);
assert(!ApplyReleaseResponse("{\"tag_name\":\"v999999999999999999.0.0\"}"));
assert(!available);
assert(NeedsFrame());nextCheck=301000;
assert(!NeedsFrame());testNow=301000;
assert(NeedsFrame());running=true;
assert(!NeedsFrame());Draw(false);
assert(running);running=false;available=false;DrawHeader();
assert(ImGui::draw.text.empty());available=true;DrawHeader();
assert(ImGui::draw.text.size()==2);
assert(ImGui::draw.text[0]=="UPDATE AVAILABLE");
assert(ImGui::draw.text[1]=="please check OptiShade manager");testNow+=900000;ImGui::draw.text.clear();DrawHeader();
assert(ImGui::draw.text.size()==2);std::cout<<"PASS: equal/older/newer versions, stale notice clearing, malformed tags, scheduling and header notice\n";}
