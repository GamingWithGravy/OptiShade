@echo off
call "%~dp0build-env.cmd" >nul
if errorlevel 1 exit /b 1
cd /d "%~dp0"
if not exist test-run mkdir test-run
cl /nologo /std:c++17 /EHsc /W4 tests\upscaler-failure-notice.cpp /Fe:test-run\upscaler-failure-notice.exe /Fo:test-run\upscaler-failure-notice.obj
if errorlevel 1 exit /b 1
test-run\upscaler-failure-notice.exe
