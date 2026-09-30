@echo off
call "%~dp0build-env.cmd" >nul
if errorlevel 1 exit /b 1
cd /d "%~dp0"
if not exist test-run mkdir test-run
cl /nologo /std:c++17 /EHsc /W4 /I optiscaler\external\nvngx_dlss_sdk tests\deferred-quality.cpp /Fe:test-run\deferred-quality.exe /Fo:test-run\deferred-quality.obj
if errorlevel 1 exit /b 1
test-run\deferred-quality.exe
