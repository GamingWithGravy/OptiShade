@echo off
call "%~dp0build-env.cmd" >nul
if errorlevel 1 exit /b 1
cd /d "%~dp0"
if not exist test-run mkdir test-run
cl /nologo /std:c++17 /EHsc /W4 /Ioptiscaler\external\streamline tests\streamline-policy.cpp /Fe:test-run\streamline-policy.exe /Fotest-run\streamline-policy.obj
if errorlevel 1 exit /b 1
test-run\streamline-policy.exe
