@echo off
call "%~dp0build-env.cmd" >nul
if errorlevel 1 exit /b 1
cd /d "%~dp0"
if not exist test-run\foundation mkdir test-run\foundation
cl /nologo /std:c++17 /EHsc /W4 tests\rendering-foundation.cpp /Fe:test-run\foundation\rendering-foundation.exe /Fotest-run\foundation\rendering-foundation.obj /link d3d12.lib dxgi.lib
if errorlevel 1 exit /b 1
test-run\foundation\rendering-foundation.exe
