#include <windows.h>
#include <cstdio>
#include <cstring>
#include <vulkan/vulkan.h>
int main(int argc,char**argv){
 const bool vanilla=argc>1 && std::strcmp(argv[1],"vanilla")==0;
 if(!vanilla && !LoadLibraryW(L"dxgi.dll")){printf("proxy load failed %lu\n",GetLastError());return 2;}
 HMODULE v=LoadLibraryW(L"vulkan-1.dll");
 auto create=(PFN_vkCreateInstance)GetProcAddress(v,"vkCreateInstance");
 auto destroy=(PFN_vkDestroyInstance)GetProcAddress(v,"vkDestroyInstance");
 const char* layers[]={"VK_LAYER_reshade"};
 VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};app.pApplicationName="OptiShade isolated startup probe";app.apiVersion=VK_API_VERSION_1_3;
 VkInstanceCreateInfo info{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};info.pApplicationInfo=&app;info.enabledLayerCount=vanilla?0:1;info.ppEnabledLayerNames=vanilla?nullptr:layers;
 VkInstance inst{};VkResult r=create(&info,nullptr,&inst);printf("vkCreateInstance=%d\n",r);fflush(stdout);if(r==0)destroy(inst,nullptr);return r==0?0:1;
}
