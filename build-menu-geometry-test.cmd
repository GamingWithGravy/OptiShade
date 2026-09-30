@echo off
call "%~dp0build-env.cmd" >nul
if errorlevel 1 exit /b 1
cd /d "%~dp0"
if not exist test-run mkdir test-run
cl /nologo /std:c++17 /EHsc /W4 /DUNICODE /D_UNICODE tests\menu-geometry.cpp /Fe:test-run\menu-geometry.exe /Fo:test-run\menu-geometry.obj
if errorlevel 1 exit /b 1
test-run\menu-geometry.exe
