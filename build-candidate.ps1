param([switch]$SkipPackage)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
. "$root/build-identity.ps1"
$before=GetOptiShadeSourceIdentity $root
foreach($script in @('build-performance.cmd','build-reshade.cmd','build-installer-host.cmd')){
 & (Join-Path $root $script)
 if($LASTEXITCODE){throw "$script failed; no candidate packaged."}
}
$after=GetOptiShadeSourceIdentity $root
if($before -ne $after){throw 'Source changed while compiling; rerun the candidate build.'}
$stamp=[ordered]@{SourceSHA256=$after;SourceHead=(git -C $root rev-parse HEAD);BuiltUtc=[DateTime]::UtcNow.ToString('o');Binaries=@{}}
foreach($relative in @('optiscaler/x64/Release/OptiScaler.dll','optiscaler/x64/Release/a/nvngx.dll_dlssnr.dll','reshade/bin/x64/Release/ReShade64.dll','installer/FusionSetup.exe','installer/resource.syso','reshade/res/version.h')){
 $stamp.Binaries[$relative]=(Get-FileHash -LiteralPath (Join-Path $root $relative) -Algorithm SHA256).Hash
}
New-Item -ItemType Directory -Path "$root/test-run" -Force|Out-Null
$stamp|ConvertTo-Json -Depth 5|Set-Content -LiteralPath "$root/test-run/native-build.json" -Encoding UTF8
if(-not $SkipPackage){& "$root/package.ps1"}
