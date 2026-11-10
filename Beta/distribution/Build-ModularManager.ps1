param([string]$OutputDirectory=(Join-Path $env:TEMP 'OptiShade-Modular-Manager'))
$ErrorActionPreference='Stop'
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'The modular manager build requires Windows resource/version tooling.'}
$distributionRoot=$PSScriptRoot
$betaRoot=Split-Path $distributionRoot -Parent
$installerRoot=Join-Path $betaRoot 'installer'
if(-not(Test-Path -LiteralPath (Join-Path $installerRoot 'go.mod') -PathType Leaf)){throw 'The manager source tree could not be located.'}
$go=Get-Command go.exe -ErrorAction SilentlyContinue
if(-not $go){throw 'Go is required to build the modular manager.'}
$output=[IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($output)
$temporary=Join-Path $output ('OptiShade-Modular-'+[guid]::NewGuid().ToString('N')+'.tmp.exe')
$destination=Join-Path $output 'OptiShade-Modular.exe'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $installerRoot 'modular-update-selection.test.ps1')
if($LASTEXITCODE){throw 'Modular update package-selection regression test failed.'}
$reconstructionRoot=Join-Path (Split-Path $betaRoot -Parent) 'tests\reconstruction'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $reconstructionRoot 'run_installer_fixture.ps1') -TestScript (Join-Path $reconstructionRoot 'test_update_manager.ps1')
if($LASTEXITCODE){throw 'Update Manager regression fixture failed.'}
Push-Location $installerRoot
try{
 & $go.Source test -tags optishade_modular -count=1 .
 if($LASTEXITCODE){throw 'Modular manager regression tests failed.'}
 & $go.Source vet -tags optishade_modular .
 if($LASTEXITCODE){throw 'Modular manager static analysis failed.'}
 & $go.Source test -count=1 .
 if($LASTEXITCODE){throw 'Full manager regression tests failed.'}
 & $go.Source vet .
 if($LASTEXITCODE){throw 'Full manager static analysis failed.'}
 & $go.Source build -tags optishade_modular -trimpath -ldflags '-H=windowsgui -s -w' -o $temporary .
 if($LASTEXITCODE){throw 'Modular manager compilation failed.'}
 $info=[Diagnostics.FileVersionInfo]::GetVersionInfo($temporary)
 if([string]$info.ProductVersion -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$'){throw 'The modular manager does not expose a valid product version.'}
 $length=(Get-Item -LiteralPath $temporary).Length
 if($length -gt 32MB){throw "The modular manager is unexpectedly large ($length bytes). Do not publish this build."}
 $hash=(Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash
 Move-Item -LiteralPath $temporary -Destination $destination -Force
$receipt=[ordered]@{Product='OptiShade Manager';ProductVersion=[string]$info.ProductVersion;FileVersion=[string]$info.FileVersion;Architecture='x64';BuildTag='optishade_modular';Bytes=$length;Sha256=$hash;BuiltUtc=[DateTime]::UtcNow.ToString('o');SourceRoot=$betaRoot;PayloadFusionEmbedded=$false;Checks=@('modular-update-selection.test.ps1','tests/reconstruction/test_update_manager.ps1','launcher_update_test.go','go test -tags optishade_modular','go vet -tags optishade_modular','go test','go vet','go build -tags optishade_modular')}
 $receiptPath=Join-Path $output 'OptiShade-Modular-build.json'
 [IO.File]::WriteAllText($receiptPath,($receipt|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
 Get-Item -LiteralPath $destination,$receiptPath|Select-Object FullName,Length
 Get-FileHash -LiteralPath $destination -Algorithm SHA256
}finally{
 Pop-Location
 if(Test-Path -LiteralPath $temporary -PathType Leaf){Remove-Item -LiteralPath $temporary -Force}
}
