@echo off
call "%~dp0build-env.cmd" >nul
if errorlevel 1 exit /b 1
cd /d "%~dp0"
python tests\input-maintenance.py
if errorlevel 1 exit /b 1
for %%T in (input-hid-maintenance input-physical-maintenance input-window-maintenance input-focus-maintenance) do (
 cl /nologo /std:c++17 /EHsc test-run\%%T.cpp /Fe:test-run\%%T.exe /Fo:test-run\%%T.obj user32.lib
 if errorlevel 1 exit /b 1
 test-run\%%T.exe
 if errorlevel 1 exit /b 1
)
