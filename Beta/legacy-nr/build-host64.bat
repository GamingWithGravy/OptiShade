@echo off
setlocal
set "LEGACY=%~dp0"
set "ROOT=%LEGACY%..\.."
set "SDK=%NVIDIA_DLSS_SDK_ROOT%"
set "OUT=%LEGACY%build"
if "%SDK%"=="" (
 echo Set NVIDIA_DLSS_SDK_ROOT to the official NVIDIA DLSS SDK folder. 1>&2
 exit /b 2
)
if not exist "%SDK%\include\nvsdk_ngx_helpers.h" (
 echo NVIDIA DLSS SDK headers were not found under "%SDK%\include". 1>&2
 exit /b 2
)
if not exist "%SDK%\lib\Windows_x86_64\x64\nvsdk_ngx_d.lib" (
 echo NVIDIA DLSS SDK import library was not found under "%SDK%\lib\Windows_x86_64\x64". 1>&2
 exit /b 2
)
call "%LEGACY%upstream\tools\vcvars.bat" x64 || exit /b 1
if not exist "%OUT%" mkdir "%OUT%"
cd /d "%LEGACY%" || exit /b 1
cl /nologo /O2 /EHsc /W3 /MD /std:c++20 /DFEED_BUILD_ID=\"optishade-legacy-nr\" ^
 /I"%SDK%\include" /I"%ROOT%\Beta\optiscaler\external\nlohmann" upstream\host\dlss5-feed-host64.cpp ^
 /Fe:"%OUT%\dlss5-feed-host64.exe" ^
 /link "%SDK%\lib\Windows_x86_64\x64\nvsdk_ngx_d.lib" version.lib winmm.lib kernel32.lib user32.lib gdi32.lib advapi32.lib ole32.lib
if errorlevel 1 exit /b 1
endlocal
echo OptiShade legacy NR x64 worker built.
