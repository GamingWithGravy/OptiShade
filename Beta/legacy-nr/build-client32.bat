@echo off
setlocal
set "LEGACY=%~dp0"
set "ROOT=%LEGACY%..\.."
set "OUT=%LEGACY%build"
call "%LEGACY%upstream\tools\vcvars.bat" amd64_x86 || exit /b 1
if not exist "%OUT%\x86" mkdir "%OUT%\x86"
cd /d "%LEGACY%" || exit /b 1
cl /nologo /LD /EHsc /O2 /MD /W3 /std:c++20 /DFEED_BUILD_ID=\"optishade-legacy-nr\" ^
 /I"%ROOT%\Beta\reshade\include" /I"%ROOT%\Beta\reshade\deps\imgui" /I"%ROOT%\Beta\optiscaler\external\vulkan\include" /I"%ROOT%\Beta\reshade\deps\minhook\include" /I"%ROOT%\Beta\optiscaler\external\nlohmann" ^
 /Fo"%OUT%/x86/" /Fd"%OUT%\x86\OptiShadeLegacyNR.pdb" upstream\src\dlss5-feed32.cpp ^
 "%ROOT%\Beta\reshade\deps\minhook\src\buffer.c" "%ROOT%\Beta\reshade\deps\minhook\src\hook.c" ^
 "%ROOT%\Beta\reshade\deps\minhook\src\trampoline.c" "%ROOT%\Beta\reshade\deps\minhook\src\hde\hde32.c" ^
 /link /OUT:"%OUT%\OptiShadeLegacyNR.addon32" /IMPLIB:"%OUT%\x86\OptiShadeLegacyNR.lib" ^
 d3d11.lib dwmapi.lib kernel32.lib user32.lib advapi32.lib
if errorlevel 1 exit /b 1
endlocal
echo OptiShade legacy NR x86 add-on built.
