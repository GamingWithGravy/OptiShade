@echo off
call "%~dp0build-env.cmd" >nul
if errorlevel 1 exit /b 1
cd /d "%~dp0"
if not exist test-run mkdir test-run
cl /nologo /std:c++17 /EHsc /W4 tests\taa-working-extent.cpp /Fe:test-run\taa-working-extent.exe /Fo:test-run\taa-working-extent.obj
if errorlevel 1 exit /b 1
test-run\taa-working-extent.exe
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /O2 /Ioptiscaler\external\nvngx_dlss_sdk tests\taa-ultrawide-gpu.cpp /Fe:test-run\taa-ultrawide-gpu.exe /Fo:test-run\taa-ultrawide-gpu.obj /link d3d12.lib dxgi.lib
if errorlevel 1 exit /b 1
test-run\taa-ultrawide-gpu.exe
if errorlevel 1 exit /b 1
test-run\taa-ultrawide-gpu.exe warp
