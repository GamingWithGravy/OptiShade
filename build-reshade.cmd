@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check-core-guides.ps1"
if errorlevel 1 exit /b 1
call "%~dp0build-env.cmd" >nul
if errorlevel 1 exit /b 1
cd /d "%~dp0reshade"
msbuild ReShade.vcxproj /m:4 /p:Configuration=Release /p:Platform=x64 /p:SolutionDir="%CD%/" /p:PlatformToolset=v143 /v:minimal /fl /flp:logfile=..\reshade-build.log;verbosity=normal
