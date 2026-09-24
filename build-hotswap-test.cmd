@echo off
call "%~dp0build-env.cmd" >nul
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc tests\preset-hotswap.cpp /Fe:tests\preset-hotswap.exe /Fo:tests\preset-hotswap.obj
if errorlevel 1 exit /b 1
tests\preset-hotswap.exe
