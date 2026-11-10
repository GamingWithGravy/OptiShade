param([switch]$SkipPackage,[switch]$ReuseVerifiedLegacyNRHost,[string]$NvidiaDlssSdkPath=$env:NVIDIA_DLSS_SDK_ROOT,[string]$LegacyWorkerVersionMetadataRoot='', [switch]$PrivateTesting,[int]$PrivateTestNumber=0,[string]$PrivateBuildLabel='')
$ErrorActionPreference='Stop'
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'A native candidate build requires Windows and its configured Windows SDK/MSVC toolchain.'}
if($PrivateBuildLabel -and (-not $PrivateTesting -or $PrivateBuildLabel -notmatch '^Rebuild R[0-9]+$')){throw 'Private build label must identify a private reconstruction revision.'}
$root=$PSScriptRoot
. "$root/build-identity.ps1"
# vcvars64.bat can prepend a reduced PowerShell module mirror which shadows
# Microsoft.PowerShell.Utility; restore the standard module paths before child scripts.
InitializeOptiShadeWindowsPowerShellModules
function GetIsolatedCandidateIdentity([string]$CandidateRoot){
 $helper=Join-Path $CandidateRoot 'test-run/identity-check.ps1'
 [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($helper))
 @'
param([string]$Root)
$ErrorActionPreference='Stop'
. (Join-Path $Root 'build-identity.ps1')
$sourceIdentity=GetOptiShadeSourceIdentity $Root
$buildInputIdentity=GetOptiShadeBuildInputIdentity $Root
[ordered]@{Source=$sourceIdentity;BuildInputs=$buildInputIdentity}|ConvertTo-Json -Compress
'@|Set-Content -LiteralPath $helper -Encoding UTF8
 $json=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $helper -Root $CandidateRoot
 if($LASTEXITCODE){throw 'Isolated source identity verification failed.'}
 return ($json|ConvertFrom-Json)
}
function InvokeLegacyWorkerBuild([string]$CandidateRoot,[string]$SdkPath,[bool]$ReuseVerifiedHost64,[string]$StableVersionMetadataRoot=''){
 $buildScript=Join-Path $CandidateRoot 'legacy-nr/build.ps1'
 if(-not $ReuseVerifiedHost64 -or -not $StableVersionMetadataRoot){
  & $buildScript -NvidiaDlssSdkPath $SdkPath -ReuseVerifiedHost64:$ReuseVerifiedHost64
  return
 }
 # A private beta overlays only the product version/channel text before the
 # native build. The already verified NR worker is compiled from the stable
 # tree and does not consume these two product-version files. Restore those
 # exact base files only while its content receipt is checked, then restore
 # the private overlay before compiling the versioned native product.
 $stableRoot=[IO.Path]::GetFullPath($StableVersionMetadataRoot)
 $relatives=@('shared/build-version.json','shared/OptiShadeVersion.h');$saved=@{};$stable=@{}
 foreach($relative in $relatives){
  $stablePath=Join-Path $stableRoot $relative;$candidatePath=Join-Path $CandidateRoot $relative
  if(-not(Test-Path -LiteralPath $stablePath -PathType Leaf) -or -not(Test-Path -LiteralPath $candidatePath -PathType Leaf)){throw ('Legacy worker channel metadata is missing: '+$relative)}
  $stable[$relative]=[IO.File]::ReadAllBytes($stablePath);$saved[$relative]=[IO.File]::ReadAllBytes($candidatePath)
 }
 try{
  foreach($relative in $relatives){[IO.File]::WriteAllBytes((Join-Path $CandidateRoot $relative),$stable[$relative])}
  & $buildScript -NvidiaDlssSdkPath $SdkPath -ReuseVerifiedHost64:$true
 }finally{
  foreach($relative in $relatives){[IO.File]::WriteAllBytes((Join-Path $CandidateRoot $relative),$saved[$relative])}
 }
}
$header=Get-Content -LiteralPath "$root/shared/OptiShadeVersion.h" -Raw
$package=Get-Content -LiteralPath "$root/package.ps1" -Raw
$expected=[regex]::Match($package,'\$buildVersion=''([^'']+)''').Groups[1].Value
$major=[regex]::Match($header,'OPTISHADE_VERSION_MAJOR (\d+)').Groups[1].Value
$minor=[regex]::Match($header,'OPTISHADE_VERSION_MINOR (\d+)').Groups[1].Value
$patch=[regex]::Match($header,'OPTISHADE_VERSION_PATCH (\d+)').Groups[1].Value
if(-not $expected -or "$major.$minor.$patch" -ne ($expected -replace '-.*$','')){throw 'Overlay and installer versions differ; correct shared/OptiShadeVersion.h before building.'}
python "$root/reconstruction/channel_version.py" --check
if($LASTEXITCODE){throw 'Channel/version consumers are stale'}
& "$root/check-backend-slots.ps1" | Out-Null
python "$root/reconstruction/generate_provider_policy.py" --check
if($LASTEXITCODE){throw 'Provider policy is stale'}
# Lifecycle regressions are a packaging gate, not an optional manual check.
$beforeIdentity=GetIsolatedCandidateIdentity $root
$before=$beforeIdentity.Source
$beforeBuildInputs=$beforeIdentity.BuildInputs
$fixtures=Join-Path (Split-Path $root -Parent) 'tests/reconstruction'
foreach($fixture in @('test_components.ps1','test_component_packages.ps1')){
 & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fixtures 'run_installer_fixture.ps1') -TestScript (Join-Path $fixtures $fixture)
 if($LASTEXITCODE){throw ('Installer lifecycle regression failed: '+$fixture)}
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'installer/mfg-retirement.test.ps1')
if($LASTEXITCODE){throw 'Legacy MFG retirement regression failed.'}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'installer/closure-scope.test.ps1')
if($LASTEXITCODE){throw 'Manager callback closure-scope regression failed.'}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fixtures 'test_update_manager.ps1')
if($LASTEXITCODE){throw 'Update manager regression failed.'}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fixtures 'test_atmosphere_mod.ps1')
if($LASTEXITCODE){throw 'AtmosphereMod component regression failed.'}
InvokeLegacyWorkerBuild $root $NvidiaDlssSdkPath ([bool]$ReuseVerifiedLegacyNRHost) $LegacyWorkerVersionMetadataRoot
if($LASTEXITCODE){throw 'Legacy NR bridge build failed; no candidate packaged.'}
foreach($script in @('build-routes.cmd','build-performance.cmd','build-reshade.cmd','build-installer-host.cmd')){
 & (Join-Path $root $script)
 if($LASTEXITCODE){throw "$script failed; no candidate packaged."}
}
# Preserve private symbols for crash diagnosis and bind each PDB to its exact DLL.
$symbolPairs=@(
 @{Binary='routes/bin/OptiShadeMSFS2024.dll';Symbols='routes/bin/OptiShadeMSFS2024.pdb'},
 @{Binary='routes/bin/OptiShadeMSFS2020.dll';Symbols='routes/bin/OptiShadeMSFS2020.pdb'},
 @{Binary='routes/bin/OptiShadeXPlane12.dll';Symbols='routes/bin/OptiShadeXPlane12.pdb'},
 @{Binary='routes/bin/OptiShadeGeneric.dll';Symbols='routes/bin/OptiShadeGeneric.pdb'},
 @{Binary='optiscaler/x64/Release/OptiScaler.dll';Symbols='optiscaler/x64/Release/OptiScaler.pdb'},
 @{Binary='optiscaler/x64/Release/a/nvngx.dll_dlssnr.dll';Symbols='optiscaler/x64/Release/a/nvngx.dll_dlssnr.pdb'},
 @{Binary='reshade/bin/x64/Release/ReShade64.dll';Symbols='reshade/bin/x64/Release/ReShade64.pdb'},
 @{Binary='reshade/bin/Win32/Release/ReShade32.dll';Symbols='reshade/bin/Win32/Release/ReShade32.pdb'}
)
foreach($pair in $symbolPairs){
 $binaryPath=Join-Path $root $pair.Binary;$symbolsPath=Join-Path $root $pair.Symbols
 if(-not (Test-Path -LiteralPath $binaryPath -PathType Leaf) -or -not (Test-Path -LiteralPath $symbolsPath -PathType Leaf)){throw "Required native symbols are missing: $($pair.Binary) / $($pair.Symbols)"}
 $identity=& python (Join-Path $root 'reconstruction/symbol_identity.py') $binaryPath $symbolsPath|ConvertFrom-Json
 if($LASTEXITCODE -or -not $identity.matching_symbols){throw "Native symbol identity verification failed: $($pair.Binary)"}
}
& "$root/installer/Troubleshooter/build.ps1"
$afterIdentity=GetIsolatedCandidateIdentity $root
$after=$afterIdentity.Source
$afterBuildInputs=$afterIdentity.BuildInputs
if($before -ne $after -or $beforeBuildInputs -ne $afterBuildInputs){throw 'Source or mandatory build dependencies changed while compiling; rerun the candidate build.'}
$sourceHead='source-archive (identified by SourceSHA256)'
if((Test-Path -LiteralPath (Join-Path $root '.git')) -or (Test-Path -LiteralPath (Join-Path (Split-Path $root -Parent) '.git'))){$sourceHead=(git -C $root rev-parse HEAD)}
$stamp=[ordered]@{SourceSHA256=$after;BuildInputsSHA256=$afterBuildInputs;SourceHead=$sourceHead;BuiltUtc=[DateTime]::UtcNow.ToString('o');Binaries=@{}}
if($ReuseVerifiedLegacyNRHost){$stamp.ReusedBinaries=@('legacy-nr/build/dlss5-feed-host64.exe')}
foreach($relative in @('routes/bin/OptiShadeMSFS2024.dll','routes/bin/OptiShadeMSFS2024.pdb','routes/bin/OptiShadeMSFS2020.dll','routes/bin/OptiShadeMSFS2020.pdb','routes/bin/OptiShadeXPlane12.dll','routes/bin/OptiShadeXPlane12.pdb','routes/bin/OptiShadeGeneric.dll','routes/bin/OptiShadeGeneric.pdb','optiscaler/x64/Release/OptiScaler.dll','optiscaler/x64/Release/OptiScaler.pdb','optiscaler/x64/Release/a/nvngx.dll_dlssnr.dll','optiscaler/x64/Release/a/nvngx.dll_dlssnr.pdb','reshade/bin/x64/Release/ReShade64.dll','reshade/bin/x64/Release/ReShade64.pdb','reshade/bin/Win32/Release/ReShade32.dll','reshade/bin/Win32/Release/ReShade32.pdb','legacy-nr/build/OptiShadeLegacyNR.addon32','legacy-nr/build/dlss5-feed-host64.exe','legacy-nr/build/worker-identity.json','installer/FusionSetup.exe','installer/OptiShadeDriver.exe','installer/OptiShadeSensors.exe','installer/OptiShade-Troubleshooter.exe','installer/GlassCockpit/glass-cockpit-dlss-fix.addon64','installer/resource.syso','reshade/res/version.h')){
 $stamp.Binaries[$relative]=(Get-FileHash -LiteralPath (Join-Path $root $relative) -Algorithm SHA256).Hash
}
New-Item -ItemType Directory -Path "$root/test-run" -Force|Out-Null
$stamp|ConvertTo-Json -Depth 5|Set-Content -LiteralPath "$root/test-run/native-build.json" -Encoding UTF8
if(-not $SkipPackage){& "$root/package.ps1" -PrivateTesting:$PrivateTesting.IsPresent -PrivateTestNumber $PrivateTestNumber -PrivateBuildLabel $PrivateBuildLabel}


