@echo off
call "%~dp0build-env.cmd" >nul
if errorlevel 1 exit /b 1
cd /d "%~dp0"
if not exist test-run mkdir test-run
cl /nologo /std:c++20 /EHsc /W4 /DUNICODE /D_UNICODE /I optiscaler\external\nlohmann tests\mfg-control.cpp /Fe:test-run\mfg-control.exe /Fo:test-run\mfg-control.obj
if errorlevel 1 exit /b 1
test-run\mfg-control.exe
