@echo off
call "%~dp0build-env.cmd" >nul
if errorlevel 1 exit /b 1
cd /d "%~dp0"
if not exist test-run mkdir test-run
cl /nologo /std:c++17 /EHsc /W4 /I optiscaler\external\nlohmann tests\update-notice-release-compatibility.cpp /Fe:test-run\update-notice-release-compatibility.exe /Fo:test-run\update-notice-release-compatibility.obj
if errorlevel 1 exit /b 1
test-run\update-notice-release-compatibility.exe
if errorlevel 1 exit /b 1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\published-updater-compatibility.ps1
exit /b %errorlevel%
