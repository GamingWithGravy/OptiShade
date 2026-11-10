@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check-core-guides.ps1"
if errorlevel 1 exit /b 1
call "%~dp0build-env.cmd" >nul
if errorlevel 1 exit /b 1
cd /d "%~dp0reshade"
msbuild ReShade.vcxproj /t:Rebuild /m:4 /p:Configuration=Release /p:Platform=x64 /p:SolutionDir="%CD%/" /p:PlatformToolset=v143 /v:minimal /fl /flp:logfile=..\reshade-build.log;verbosity=normal
if errorlevel 1 exit /b 1
msbuild ReShade.sln /t:ReShade /m:4 /p:Configuration=Release /p:Platform=32-bit /p:PlatformToolset=v143 /p:PostBuildEventUseInBuild=false /v:minimal /fl /flp:logfile=..\reshade-build-x86.log;verbosity=normal
