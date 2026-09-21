@echo off
call "%~dp0build-env.cmd" >nul
if errorlevel 1 exit /b 1
cd /d "%~dp0"
cl /nologo /std:c++17 /EHsc /O2 /MT tests\fusion_render.cpp /Fe:test-run\OptiShade_Fusion_Test.exe /link /SUBSYSTEM:WINDOWS d3d12.lib dxgi.lib dxguid.lib user32.lib
