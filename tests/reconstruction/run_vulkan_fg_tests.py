"""Compile inactive Vulkan FG contracts and the actual scalar owner publisher."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[2])
    parser.add_argument('--compiler',default='g++')
    args=parser.parse_args()
    root=args.root.resolve()
    source=(root/'Beta/optiscaler/OptiScaler/hooks/Vulkan_Hooks.cpp').read_text()
    first='static void PublishVulkanAutoContext(VkQueue queue)\n{'
    following='\nstatic void ResetOverlayCandidate() noexcept'
    if source.count(first)!=1 or source.count(following)!=1:
        raise SystemExit('Vulkan owner publication extraction boundary changed')
    body=source[source.index(first):source.index(following)]
    # The tested publisher must still be called from the real accepted-owner
    # present path, and every original destruction owner must retire it.
    present=source[source.index('static VkResult hkvkQueuePresentKHR(VkQueue queue, const VkPresentInfoKHR* pPresentInfo)\n{'):]
    if present.count('PublishVulkanAutoContext(queue);')!=1:
        raise SystemExit('Vulkan publication is disconnected from the actual present owner')
    for name,end in [('hkvkDestroySwapchainKHR','hkvkDestroySurfaceKHR'),('hkvkDestroySurfaceKHR','hkvkDestroyDevice'),
                     ('hkvkDestroyDevice','hkvkDestroyInstance'),('hkvkDestroyInstance','// Forward declaration')]:
        start=source.index('static void VKAPI_CALL '+name)
        finish=source.index(end,start+len('static void VKAPI_CALL '+name))
        if 'runtime_render::State().RetireVulkan(_owners.owner.chain)' not in source[start:finish]:
            raise SystemExit('Vulkan metadata retirement disconnected: '+name)
    with tempfile.TemporaryDirectory(prefix='optishade-vulkan-fg-') as temporary:
        work=Path(temporary)
        (work/'vulkan_publisher.inc').write_text(body)
        msvc=Path(args.compiler).name.lower() in ('cl','cl.exe','clang-cl','clang-cl.exe')
        binary=work/('vulkan_fg.exe' if msvc else 'vulkan_fg')
        includes=[work,root/'Beta/shared',root/'Beta/optiscaler/external/nlohmann']
        fixture=root/'tests/reconstruction/vulkan_fg_tests.cpp'
        if msvc:
            command=[args.compiler,'/nologo','/std:c++20','/EHsc','/W4','/Od',*['/I'+str(p) for p in includes],str(fixture),'/Fe:'+str(binary)]
        else:
            command=[args.compiler,'-std=c++20','-O0','-Wall','-Wextra','-pthread',*['-I'+str(p) for p in includes],str(fixture),'-o',str(binary)]
        subprocess.run(command,cwd=work,check=True)
        subprocess.run([str(binary)],cwd=work,check=True)


if __name__=='__main__':
    main()
