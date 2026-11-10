@echo off
setlocal
for %%I in ("%~dp0..\..") do set "reconstructionRoot=%%~fI"
call "%reconstructionRoot%\Beta\build-env.cmd" >nul
if errorlevel 1 exit /b 1
if not exist "%reconstructionRoot%\test-results" mkdir "%reconstructionRoot%\test-results"
python "%~dp0run_tests.py" --compiler cl --report "%reconstructionRoot%\test-results\reconstruction-windows.json"
if errorlevel 1 exit /b 1
msbuild "%reconstructionRoot%\Beta\optiscaler\OptiScaler.sln" /t:Build /m:4 /p:Configuration=Release /p:Platform=x64 /p:PostBuildEventUseInBuild=false /v:minimal
if errorlevel 1 exit /b 1
python "%reconstructionRoot%\Beta\reconstruction\symbol_identity.py" "%reconstructionRoot%\Beta\optiscaler\x64\Release\OptiScaler.dll" "%reconstructionRoot%\Beta\optiscaler\x64\Release\OptiScaler.pdb"
exit /b %errorlevel%
