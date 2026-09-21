@echo off
call "%~dp0build-env.cmd" >nul
if errorlevel 1 exit /b 1
cd /d "%~dp0optiscaler"
msbuild OptiScaler.sln /m:4 /p:Configuration=Release /p:Platform=x64 /p:PostBuildEventUseInBuild=false /v:minimal /fl /flp:logfile=..\performance-build.log;verbosity=normal
