@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
cd /d "%~dp0reshade"
msbuild ReShadeFXC.vcxproj /m:4 /p:Configuration=Release /p:Platform=x64 /p:SolutionDir="%CD%/" /p:PlatformToolset=v143 /v:minimal
