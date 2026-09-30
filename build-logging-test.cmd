@echo off
call "%~dp0build-env.cmd" >nul
if errorlevel 1 exit /b 1
cd /d "%~dp0"
if not exist test-run mkdir test-run
cl /nologo /utf-8 /std:c++17 /EHsc /Ioptiscaler/external/spdlog/include tests/bounded-logging.cpp /Fe:test-run/bounded-logging.exe /Fo:test-run/bounded-logging.obj
if errorlevel 1 exit /b 1
test-run\bounded-logging.exe
if errorlevel 1 exit /b 1
cl /nologo /utf-8 /std:c++17 /EHsc /DNOMINMAX tests/reshade-logging.cpp reshade/source/dll_log.cpp /Fe:test-run/reshade-logging.exe /Fo:test-run/
if errorlevel 1 exit /b 1
test-run\reshade-logging.exe
