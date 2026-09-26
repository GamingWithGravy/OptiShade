@echo off
call "%~dp0build-env.cmd" >nul
if errorlevel 1 exit /b 1
cd /d "%~dp0"
python tests\flight-controller-hooks.py
if errorlevel 1 exit /b 1
python tests\menu-shortcut-hooks.py
if errorlevel 1 exit /b 1
python tests\hotswap-notification.py
if errorlevel 1 exit /b 1
for %%T in (flight-controller-hooks menu-shortcut-hooks hotswap-notification) do (
 cl /nologo /std:c++17 /EHsc test-run\%%T.cpp /Fe:test-run\%%T.exe /Fo:test-run\%%T.obj user32.lib
 if errorlevel 1 exit /b 1
 test-run\%%T.exe
 if errorlevel 1 exit /b 1
)
