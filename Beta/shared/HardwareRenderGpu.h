#pragma once
#include <mutex>
#include <string>
namespace optishade::hardware {
struct RenderGpu { unsigned vendor=0; std::string name; };
inline std::mutex renderGpuMutex;
inline RenderGpu renderGpu;
inline void SetRenderGpu(unsigned vendor,const std::string& name){std::lock_guard<std::mutex> lock(renderGpuMutex);renderGpu={vendor,name};}
inline RenderGpu GetRenderGpu(){std::lock_guard<std::mutex> lock(renderGpuMutex);return renderGpu;}
inline std::wstring SensorGpuArgument(const std::string& name){
 const wchar_t hex[]=L"0123456789abcdef";std::wstring s;
 for(unsigned char c:name){s+=hex[c>>4];s+=hex[c&15];}return s.empty()?L"":L" --gpu "+s;
}
}
