@echo off
rem Builds the OptiShade camera plugin for X-Plane 12: build\64\win.xpl
setlocal
call "%~dp0..\build-env.cmd" >nul || exit /b 1
set "OUT=%~dp0build\64"
if not exist "%OUT%" mkdir "%OUT%"
set "SDK=%~dp0sdk\XPSDK410"
cl /nologo /std:c++17 /EHsc /utf-8 /O2 /W4 /MT /LD /DIBM=1 /DXPLM200=1 /DXPLM210=1 /DXPLM300=1 /DXPLM301=1 /DXPLM302=1 ^
 /I"%SDK%\CHeaders\XPLM" /I"%~dp0include" "%~dp0src\plugin.cpp" ^
 /Fo"%OUT%\\" /Fe:"%OUT%\win.xpl" /link "%SDK%\Libraries\Win\XPLM_64.lib" || exit /b 1
del /q "%OUT%\*.obj" "%OUT%\*.exp" "%OUT%\*.lib" 2>nul
echo Built %OUT%\win.xpl
