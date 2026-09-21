@echo off
set "OPTISHADE_VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%OPTISHADE_VSWHERE%" (
 echo Install Visual Studio 2022 Build Tools with Desktop development with C++.
 exit /b 1
)
for /f "usebackq tokens=*" %%i in (`"%OPTISHADE_VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "OPTISHADE_VS=%%i"
if not defined OPTISHADE_VS exit /b 1
call "%OPTISHADE_VS%\VC\Auxiliary\Build\vcvars64.bat"
