#include <Windows.h>
#include "status_panel.cpp"
namespace glass {
static Status current=[] {Status s;s.enabled=true;s.jitter_positive=true;s.line_smoothing=35;s.glass_strength=100;s.gpu="FIXTURE - no GPU output";return s;}();
Status status(){return current;}
void set_enabled(bool v){current.enabled=v;}
void set_tint(bool v){current.tint=v;}
void set_jitter_positive(bool v){current.jitter_positive=v;}
void set_line_smoothing(int v){current.line_smoothing=v;}
void set_glass_strength(int v){current.glass_strength=v;}
}
extern "C" __declspec(dllexport) void FixtureSetTable(const void* t){imgui_function_table_instance()=static_cast<const imgui_function_table*>(t);}
extern "C" __declspec(dllexport) void FixtureDraw(){draw(nullptr);}
