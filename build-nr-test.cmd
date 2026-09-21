@echo off
call "%~dp0build-env.cmd" >nul
if errorlevel 1 exit /b 1
cd /d "%~dp0"
if not exist nr-test-run mkdir nr-test-run
cl /nologo /std:c++17 /EHsc /O2 /MT /Ioptiscaler\external\nvngx_dlss_sdk tests\fusion_nr.cpp /Fe:nr-test-run\OptiShade_NR_Test.exe /link d3d12.lib dxgi.lib dxguid.lib user32.lib

