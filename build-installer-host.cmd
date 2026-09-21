@echo off
call "%~dp0build-env.cmd" >nul
if errorlevel 1 exit /b 1
cd /d "%~dp0installer"
"C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /platform:x64 /win32icon:OptiShade-app.ico /out:FusionSetup.exe /r:System.Windows.Forms.dll /r:"C:\Windows\Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation\v4.0_3.0.0.0__31bf3856ad364e35\System.Management.Automation.dll" FusionSetup.cs
if errorlevel 1 exit /b 1
go run github.com/josephspurrier/goversioninfo/cmd/goversioninfo@v1.7.0 -64 -o resource.syso versioninfo.json
