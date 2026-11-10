@echo off
call "%~dp0build-env.cmd" >nul
if errorlevel 1 exit /b 1
cd /d "%~dp0optiscaler"
msbuild OptiScaler.sln /t:Rebuild /m:4 /p:Configuration=Release /p:Platform=x64 /p:PostBuildEventUseInBuild=false /p:ForceImportBeforeCppTargets="%~dp0reconstruction\OptiShade.Reconstruction.targets" /v:minimal /fl /flp:logfile=..\performance-build.log;verbosity=normal
exit /b %errorlevel%
