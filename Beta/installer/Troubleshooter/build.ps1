$ErrorActionPreference='Stop'
Push-Location $PSScriptRoot
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $PSScriptRoot "dist") | Out-Null
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $wpf=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\WPF'
    & $compiler /nologo /target:winexe /platform:x64 /optimize+ /out:dist\OptiShade-Troubleshooter-0.2.34.exe /win32icon:src\OptiShade-app.ico /win32manifest:src\app.manifest /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Management.dll /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll /r:System.Web.Extensions.dll /r:System.Net.Http.dll "/r:$wpf\WindowsBase.dll" /r:System.Xaml.dll "/r:$wpf\PresentationFramework.dll" "/r:$wpf\PresentationCore.dll" /resource:src\UI.xaml,TesterUI ..\RuntimeControlClient.cs src\DiagnosticsLocation.cs src\CaptureNotice.cs src\AutoCapture.cs src\HangCapture.cs src\VrDiagnostics.cs src\Verdicts.cs src\SelfHelp.cs src\Collector.cs src\Program.cs src\DumpSummary.cs src\ReportUpload.cs src\UninstallFeedback.cs src\CrashDumps.cs src\Shell.cs
    if($LASTEXITCODE -ne 0){throw "Build failed: $LASTEXITCODE"}
    Get-FileHash -LiteralPath dist\OptiShade-Troubleshooter-0.2.34.exe -Algorithm SHA256
} finally {Pop-Location}

Copy-Item -LiteralPath (Join-Path $PSScriptRoot "dist\OptiShade-Troubleshooter-0.2.34.exe") -Destination (Join-Path $PSScriptRoot "..\OptiShade-Troubleshooter.exe") -Force



