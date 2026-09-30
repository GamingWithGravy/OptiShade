@echo off
call "%~dp0build-env.cmd" >nul
if errorlevel 1 exit /b 1
cd /d "%~dp0"
if not exist test-run mkdir test-run
cl /nologo /std:c++17 /EHsc /W4 tests\nr-admission.cpp /Fe:test-run\nr-admission.exe /Fo:test-run\nr-admission.obj /link d3d12.lib dxgi.lib
if errorlevel 1 exit /b 1
test-run\nr-admission.exe
