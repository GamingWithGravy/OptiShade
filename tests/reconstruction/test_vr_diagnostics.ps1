$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not(Test-Path -LiteralPath $compiler)){throw 'The .NET Framework x64 C# compiler is unavailable; VR diagnostics tests were not run.'}
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('optishade-vr-diagnostics-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary | Out-Null
try {
    $binary=Join-Path $temporary 'vr-diagnostics-tests.exe'
    $source=Join-Path $root 'Beta\installer\Troubleshooter\src\VrDiagnostics.cs'
    $test=Join-Path $PSScriptRoot 'vr_diagnostics_tests.cs'
    & $compiler /nologo /target:exe /platform:x64 "/out:$binary" /r:System.Web.Extensions.dll $source $test
    if($LASTEXITCODE -ne 0){throw "VR diagnostics test compile failed: $LASTEXITCODE"}
    & $binary
    if($LASTEXITCODE -ne 0){throw "VR diagnostics tests failed: $LASTEXITCODE"}
} finally {
    if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Recurse -Force}
}
