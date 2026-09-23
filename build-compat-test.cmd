@echo off
call "%~dp0build-env.cmd" >nul
if errorlevel 1 exit /b 1
cd /d "%~dp0"
if not exist test-run mkdir test-run
cl /nologo /std:c++17 /EHsc /W4 tests\presentation-owner.cpp /Fe:test-run\presentation-owner.exe /Fotest-run\presentation-owner.obj /link user32.lib
if errorlevel 1 exit /b 1
test-run\presentation-owner.exe
