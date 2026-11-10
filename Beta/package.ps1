param([switch]$VerifySecurity,[switch]$RequireSigned,[switch]$ManagerOnlyRepack,[bool]$PrivateTesting=$false,[int]$PrivateTestNumber=0,[string]$PrivateBuildLabel='')

$ErrorActionPreference='Stop'

if($PrivateBuildLabel -and (-not $PrivateTesting -or $PrivateBuildLabel -notmatch '^Rebuild R[0-9]+$')){throw 'Private build label must identify a private reconstruction revision.'}
if($PrivateTesting -and $PrivateTestNumber -lt 1){throw 'Private tester builds require a positive test number for build identification.'}

$root=$PSScriptRoot;$payload=Join-Path $root 'installer/PayloadFusion'

. "$root/build-identity.ps1"

. "$root/package-staging.ps1"

# New source installations no longer bundle or enable OptiShade's retired MFG
# providers. Legacy receipts remain supported by the cleanup/restore routines.

$native=AssertOptiShadeCandidateBuild $root -ManagerOnlyRepack:$ManagerOnlyRepack

function GetOptiShadePeIdentity([string]$File){

 $stream=[IO.File]::OpenRead($File);$reader=[IO.BinaryReader]::new($stream)

 try{

  if($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5a4d){throw "Invalid Windows binary: $File"}

  $stream.Position=0x3c;$pe=$reader.ReadUInt32();if([long]$pe+26 -gt $stream.Length){throw "Invalid Windows binary header: $File"}

  $stream.Position=$pe;if($reader.ReadUInt32() -ne 0x4550){throw "Invalid Windows binary signature: $File"}

  $machine=$reader.ReadUInt16();$stream.Position=$pe+24;$magic=$reader.ReadUInt16()

  return [pscustomobject]@{Machine=$machine;Magic=$magic}

 }finally{$reader.Dispose()}

}

$reshade64=GetOptiShadePeIdentity "$root/reshade/bin/x64/Release/ReShade64.dll"

$reshade32=GetOptiShadePeIdentity "$root/reshade/bin/Win32/Release/ReShade32.dll"

if($reshade64.Machine -ne 0x8664 -or $reshade64.Magic -ne 0x20b){throw 'ReShade64.dll is not a valid x64 ReShade binary.'}

if($reshade32.Machine -ne 0x14c -or $reshade32.Magic -ne 0x10b){throw 'ReShade32.dll is not a valid x86 ReShade binary.'}

$payload=NewOptiShadePackageStaging $root

$buildVersion='1.0.77';$buildChannel='stable'
# Retired OptiShade MFG providers stay excluded. OptiMFG is staged as an
# independently selected component with its own receipt and runtime lifecycle.
CopyOptiShadePackageInputs $root Effects "$payload/OptiShadeData"
CopyOptiShadePackageInputs $root OptiMFG "$payload/OptiShadeData"

CopyOptiShadePackageInputs $root Hybrid "$payload/OptiScaler/nvfp4/hybrid"

Copy-Item "$root/installer/HybridAssets/PROVENANCE.json" "$payload/OptiShadeData/Licenses/Hybrid-assets.json" -Force

New-Item -ItemType Directory -Path $payload,(Join-Path $payload 'OptiShadeData/Presets'),(Join-Path $payload 'OptiShadeData/Shaders'),(Join-Path $payload 'OptiShadeData/Textures'),(Join-Path $payload 'OptiShadeData/Cache'),(Join-Path $payload 'OptiShadeData/Licenses'),(Join-Path $payload 'OptiShadeData/Engine/D3D12_OptiScaler') -Force|Out-Null

# The optional OptiMFG component owns its menu-free backend. Never stage a
# competing version.dll provider as an unconditional core dependency.

Copy-Item "$root/optiscaler/x64/Release/OptiScaler.dll" "$payload/winmm.dll" -Force

New-Item -ItemType Directory -Path "$payload/OptiShadeData/Engine/Routes" -Force|Out-Null

foreach($adapter in @("OptiShadeMSFS2024.dll","OptiShadeMSFS2020.dll","OptiShadeXPlane12.dll","OptiShadeGeneric.dll")){Copy-Item -LiteralPath "$root/routes/bin/$adapter" -Destination "$payload/OptiShadeData/Engine/Routes/$adapter" -Force}



Copy-Item "$root/reshade/bin/x64/Release/ReShade64.dll" $payload -Force

Copy-Item "$root/reshade/bin/Win32/Release/ReShade32.dll" $payload -Force

# Legacy x86 Neural Rendering uses a ReShade x86 client and an isolated x64 worker.

# The external D3D9-to-D3D11 wrapper is deliberately not bundled.

$legacyBuild=Join-Path $root 'legacy-nr/build'

$legacyClient=Join-Path $legacyBuild 'OptiShadeLegacyNR.addon32'

$legacyWorker=Join-Path $legacyBuild 'dlss5-feed-host64.exe'

foreach($file in @($legacyClient,$legacyWorker)){if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw "Build the x86 Neural Rendering bridge first: missing $file"}}

if((GetOptiShadePeIdentity $legacyClient).Machine -ne 0x14c){throw 'The legacy Neural Rendering client must be x86.'}

if((GetOptiShadePeIdentity $legacyWorker).Machine -ne 0x8664){throw 'The legacy Neural Rendering worker must be x64.'}

New-Item -ItemType Directory -Path "$payload/OptiShadeData/Shaders/LegacyNR","$payload/OptiShadeData/Licenses/LegacyNR","$payload/host64" -Force|Out-Null

Copy-Item -LiteralPath $legacyClient -Destination "$payload/OptiShadeLegacyNR.addon32" -Force

Copy-Item -LiteralPath $legacyWorker -Destination "$payload/host64/dlss5-feed-host64.exe" -Force

Copy-Item -LiteralPath "$root/legacy-nr/upstream/shaders/DLSS5_Feed.fx" -Destination "$payload/OptiShadeData/Shaders/LegacyNR/DLSS5_Feed.fx" -Force

# Neural is independently installable: its shader include must not depend on Image Effects.
Copy-Item -LiteralPath "$root/installer/DefaultEffects/Shaders/Packages/00/ReShade.fxh" -Destination "$payload/OptiShadeData/Shaders/LegacyNR/ReShade.fxh" -Force

Copy-Item -LiteralPath "$payload/ReShade64.dll" -Destination "$payload/host64/dxgi.dll" -Force

Copy-Item -LiteralPath "$root/optiscaler/x64/Release/OptiScaler.dll" -Destination "$payload/host64/winmm.dll" -Force

Copy-Item -LiteralPath "$root/optiscaler/x64/Release/a/nvngx.dll_dlssnr.dll" -Destination "$payload/host64/nvngx.dll_dlssnr.dll" -Force

Copy-Item -LiteralPath "$root/legacy-nr/upstream/LICENSE" -Destination "$payload/OptiShadeData/Licenses/LegacyNR/LICENSE.txt" -Force

Copy-Item -LiteralPath "$root/legacy-nr/UPSTREAM.md" -Destination "$payload/OptiShadeData/Licenses/LegacyNR/UPSTREAM.md" -Force

# The official add-on is shipped unchanged in stable and private packages.

$glass="$root/installer/GlassCockpit"

$provenance=Get-Content -LiteralPath "$glass/PROVENANCE.json" -Raw|ConvertFrom-Json

if($provenance.Modified -or (Get-FileHash -LiteralPath "$glass/glass-cockpit-dlss-fix.addon64" -Algorithm SHA256).Hash.ToLowerInvariant() -cne $provenance.SHA256){throw 'Official glass cockpit asset identity mismatch'}

Copy-Item -LiteralPath "$glass/glass-cockpit-dlss-fix.addon64" -Destination $payload

$notices="$payload/OptiShadeData/Licenses/GlassCockpit"

New-Item -ItemType Directory -Path $notices -Force|Out-Null

foreach($name in @('LICENSE','LICENSE.txt','NOTICE.md','THIRD_PARTY_NOTICES.md','PROVENANCE.json','MinHook.txt','ReShade.txt','ImGui.txt')){Copy-Item -LiteralPath "$glass/$name" -Destination $notices}





New-Item -ItemType Directory -Path "$payload/OptiShadeData/Shaders/Custom" -Force|Out-Null

Copy-Item "$root/installer/FusionCinema/Gravy_FusionCinema.fx" "$payload/OptiShadeData/Shaders/Custom/Gravy_FusionCinema.fx" -Force

Copy-Item "$root/installer/FusionCinema/Gravy - Fusion Cinema Custom v1.ini" "$payload/OptiShadeData/Presets/Gravy - Fusion Cinema Custom v1.ini" -Force

Copy-Item "$root/installer/FusionCinema/LICENSE" "$payload/OptiShadeData/Licenses/FusionCinema-GPL3.txt" -Force

Copy-Item "$root/optiscaler/x64/Release/a/nvngx.dll_dlssnr.dll" $payload -Force

CopyOptiShadePackageInputs $root XeSS "$payload/OptiShadeData/Engine"

foreach($name in @('amd_fidelityfx_loader_dx12.dll','amd_fidelityfx_upscaler_dx12.dll','amd_fidelityfx_framegeneration_dx12.dll')){Copy-Item "$root/optiscaler/external/FidelityFX-SDK-v2/Kits/FidelityFX/signedbin/$name" "$payload/OptiShadeData/Engine/" -Force}

Copy-Item "$root/optiscaler/external/FidelityFX-SDK/PrebuiltSignedDLL/amd_fidelityfx_vk.dll" "$payload/OptiShadeData/Engine/" -Force

Copy-Item "$root/optiscaler/external/directx_agility_sdk/lib/D3D12Core.dll" "$payload/OptiShadeData/Engine/D3D12_OptiScaler/" -Force

Copy-Item "$root/optiscaler/LICENSE" "$payload/OptiShadeData/Licenses/OptiScaler-GPL3.txt" -Force

foreach($notice in @('LICENSE','LICENSE.md','OPTISHADE_LICENSING.md','NOTICE.md','BRANDING.md','LICENSING.md')){Copy-Item (Join-Path $root $notice) (Join-Path "$payload/OptiShadeData/Licenses" $notice) -Force}

New-Item -ItemType Directory -Path "$payload/OptiShadeData/Licenses/LICENSES" -Force|Out-Null

foreach($notice in @('GPL-3.0.txt','ReShade-BSD-3-Clause.txt','OPTISHADE-PROPRIETARY.txt')){Copy-Item (Join-Path "$root/LICENSES" $notice) (Join-Path "$payload/OptiShadeData/Licenses/LICENSES" $notice) -Force}

Copy-Item -LiteralPath "$root/LICENSES/ThirdParty" -Destination "$payload/OptiShadeData/Licenses/LICENSES/ThirdParty" -Recurse -Force

Copy-Item "$root/installer/BRANDING-LICENSE.md" "$payload/OptiShadeData/Licenses/BRANDING-LICENSE.md" -Force

Copy-Item "$root/reshade/LICENSE.md" "$payload/OptiShadeData/Licenses/ReShade-BSD3.txt" -Force

CopyOptiShadePackageInputs $root Notices "$payload/OptiShadeData/Licenses"

Copy-Item "$root/optiscaler/external/xess/LICENSE.txt" "$payload/OptiShadeData/Licenses/XeSS.txt" -Force

Copy-Item "$root/optiscaler/external/directx_agility_sdk/LICENSE.txt" "$payload/OptiShadeData/Licenses/DirectX.txt" -Force

Copy-Item "$root/optiscaler/external/FidelityFX-SDK-v2/docs/license.md" "$payload/OptiShadeData/Licenses/FidelityFX-v2.md" -Force

Copy-Item "$root/optiscaler/external/FidelityFX-SDK/docs/license.md" "$payload/OptiShadeData/Licenses/FidelityFX-v1.md" -Force

@'

[Libraries]

OptiDllPath=OptiShadeData/Engine

[Upscalers]

Dx12Upscaler=auto

[Plugins]

LoadReShade=true

[Menu]

OverlayMenu=true

ShowFps=false

DisableSplash=true

[Hotfix]

CheckForUpdate=false

[Log]

LogToFile=true

LogFileName=OptiShadeData/Performance.log

LogLevel=2

LogAsync=true

[DlssNr]

Enabled=false

Passes=1

RunBeforeSR=true

'@ | Set-Content "$payload/OptiScaler.ini" -Encoding ASCII

$legacyOptiIni=Get-Content -LiteralPath "$payload/OptiScaler.ini" -Raw

# The worker uses the same startup-Off configuration. Its current-session
# control export is called only after the authenticated preparation/activation
# exchange; a saved Enabled=true value cannot activate the current runtime.

$legacyOptiIni=[regex]::Replace($legacyOptiIni,'(?ms)(\[DlssNr\][^\[]*?ScanExposure\s*=\s*)[^\r\n]+','$1false',1)

Set-Content -LiteralPath "$payload/host64/OptiScaler.ini" -Value $legacyOptiIni -Encoding ASCII

@'

[GENERAL]

EffectSearchPaths=.\OptiShadeData\Shaders\**,.\reshade-shaders\Shaders\**

TextureSearchPaths=.\OptiShadeData\Textures\**,.\reshade-shaders\Textures\**

PresetPath=.\OptiShadeData\Presets\My look.ini

IntermediateCachePath=.\OptiShadeData\Cache

ScreenshotPath=.\Optishade Snapshots

PerformanceMode=0

SkipLoadingDisabledEffects=1

[OVERLAY]

ShowSplash=0

TutorialProgress=4

[SCREENSHOT]

SavePath=.\Optishade Snapshots

SaveBeforeShot=0

SaveOverlayShot=0

KeyScreenshot=0,0,0,0

[INPUT]

KeyOverlay=45,0,0,0

'@ | Set-Content "$payload/ReShade.ini" -Encoding ASCII

@'

[GENERAL]

EffectSearchPaths=.

TextureSearchPaths=.

[OVERLAY]

ShowSplash=0

[DLSS5Host]

WindowWidth=900

WindowHeight=0

'@ | Set-Content "$payload/host64/ReShade.ini" -Encoding ASCII

"Techniques=`r`nTechniqueSorting=" | Set-Content "$payload/OptiShadeData/Presets/My look.ini" -Encoding ASCII

foreach($dir in @('Shaders','Textures','Cache')){'OptiShade managed folder'|Set-Content "$payload/OptiShadeData/$dir/.keep"}

# Explicit OpenXR layer for process-scoped VR launch. The manager opts this in

# only for the selected simulator process; nothing is registered globally.

New-Item -ItemType Directory -Path "$payload/OptiShadeData/OpenXR" -Force|Out-Null

@'

{

  "file_format_version": "1.0.0",

  "api_layer": {

    "name": "XR_APILAYER_optishade",

    "library_path": "..\\..\\ReShade64.dll",

    "api_version": "1.0",

    "implementation_version": "1",

    "description": "OptiShade game-local OpenXR post-processing layer"

  }

}

'@ | Set-Content -LiteralPath "$payload/OptiShadeData/OpenXR/OptiShade_XR.json" -Encoding ASCII

New-Item -ItemType Directory -Path "$payload/OptiShadeData/Tools" -Force|Out-Null

Copy-Item -LiteralPath "$root/installer/OptiShadeSensors.exe" -Destination "$payload/OptiShadeData/Tools/OptiShadeSensors.exe" -Force

Copy-Item -LiteralPath "$root/installer/OptiShade-Troubleshooter.exe" -Destination "$payload/OptiShadeData/Tools/OptiShade-Troubleshooter.exe" -Force

Copy-Item "$root/installer/store-paths.ps1" "$payload/OptiShadeData/Tools/store-paths.ps1" -Force

Copy-Item "$root/installer/import-effects.ps1" "$payload/OptiShadeData/Tools/import-effects.ps1" -Force

foreach($dependency in @('anti-cheat.ps1','anti-cheat-rules.json','consent.ps1','component-policy.ps1','compatibility.ps1','ownership.ps1','json-state.ps1','executable.ps1','gpu-identity.ps1','GpuIdentityClient.cs','neural-model-policy.json')){Copy-Item -LiteralPath "$root/installer/$dependency" -Destination "$payload/OptiShadeData/Tools/$dependency" -Force}

"[Storage]`nRoot=" | Set-Content -LiteralPath "$payload/OptiShadeData/dependency-state.ini" -Encoding UTF8

Copy-Item "$root/installer/EffectPackages.ini" "$payload/OptiShadeData/Tools/EffectPackages.ini" -Force

New-Item -ItemType Directory -Path "$payload/OptiShadeData/Tools/StandardHeaders" -Force|Out-Null

foreach($name in @('ReShade.fxh','ReShadeUI.fxh')){Copy-Item -LiteralPath "$root/installer/DefaultEffects/Shaders/Packages/00/$name" -Destination "$payload/OptiShadeData/Tools/StandardHeaders" -Force}

New-Item -ItemType Directory -Path "$payload/OptiShadeData/Vulkan" -Force|Out-Null

@'

{"file_format_version":"1.2.0","layer":{"name":"VK_LAYER_OptiShade_effects","type":"GLOBAL","library_path":"..\\..\\ReShade64.dll","api_version":"1.3.268","implementation_version":"1","description":"OptiShade Vulkan image effects","device_extensions":[{"name":"VK_EXT_tooling_info","spec_version":"1","entrypoints":["vkGetPhysicalDeviceToolPropertiesEXT"]}]}}

'@ | Set-Content -LiteralPath "$payload/OptiShadeData/Vulkan/OptiShade.json" -Encoding ASCII

# Fail closed on local evidence accidentally left in the embedded payload.

$private=@(Get-ChildItem -LiteralPath $payload -File -Recurse|Where-Object {$_.Name -match '(?i)(diagnostics-|Import-result-|\.dmp$|\.log$|Licensing-review-|Ownership-licensing-audit|Release-.*draft|test-results|test-notes)'})

if($private.Count){throw ('Private/debug files found in package staging: '+($private.Name -join ', '))}

$buildIdentity=@{Version=$buildVersion;Channel=$buildChannel;PrivateTesting=$PrivateTesting;PrivateBuildLabel=$PrivateBuildLabel;PrivateTestNumber=$(if($PrivateTesting){$PrivateTestNumber}else{0});SourceHead=$native.SourceHead;SourceSHA256=$native.SourceSHA256;BuildInputsSHA256=$native.BuildInputsSHA256;BuiltUtc=$native.BuiltUtc;NativeBinaries=$native.Binaries}
# Retain explicit provenance when only the desktop scripts/bootstrap were rebuilt.
# BuiltUtc and NativeBuildSourceSHA256 continue to identify the reused native build.
if($native.BuildMode -eq 'ManagerOnlyRepackVerifiedRuntime'){
 $buildIdentity.BuildMode=$native.BuildMode
 $buildIdentity.NativeBuildSourceSHA256=$native.NativeBuildSourceSHA256
 $buildIdentity.ReusedFromExecutableSHA256=$native.ReusedFromExecutableSHA256
 $buildIdentity.ManagerRepackedUtc=$native.ManagerRepackedUtc
 $buildIdentity.ManagerOnlyChanges=$native.ManagerOnlyChanges
}
$buildIdentity|ConvertTo-Json -Depth 5|Set-Content -LiteralPath "$payload/OptiShadeData/BuildIdentity.json" -Encoding UTF8

$files=@(Get-ChildItem $payload -File -Recurse|Where-Object {$_.FullName -ne (Join-Path $payload 'files.json')}|ForEach-Object {[pscustomobject]@{Path=$_.FullName.Substring($payload.Length+1);Hash=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}})

$files|ConvertTo-Json|Set-Content "$payload/files.json" -Encoding UTF8

$preview=if($env:OPTISHADE_LOCAL_CANDIDATE_DIR){
 $localCandidateDir=[IO.Path]::GetFullPath([string]$env:OPTISHADE_LOCAL_CANDIDATE_DIR)
 if(-not [IO.Path]::IsPathRooted($localCandidateDir)){throw 'Local candidate output directory must be an absolute path.'}
 $localCandidateDir
}else{Join-Path $root 'dist'}
$candidateFileName=if($PrivateTesting){"OptiShade_Version_${buildVersion}_R${PrivateTestNumber}.exe"}else{"OptiShade_Version_${buildVersion}.exe"}
$candidateExe=Join-Path $preview $candidateFileName
if($PrivateTesting -and (Test-Path -LiteralPath $candidateExe)){throw "Private candidate already exists; choose a new test number to preserve the existing executable: $candidateExe"}

New-Item -ItemType Directory -Path $preview -Force|Out-Null

if($env:OPTISHADE_SIGNING_THUMBPRINT){& "$root/sign-release.ps1" -File "$root/installer/FusionSetup.exe" -Thumbprint $env:OPTISHADE_SIGNING_THUMBPRINT}

Push-Location "$root/installer"

try{

 & "$root/installer/mfg-loader.test.ps1"

 & go test -count=1 -v .

 if($LASTEXITCODE){throw 'Embedded payload verification failed. Installer was not built.'}

 $ldflags='-H=windowsgui -s -w'
	$buildArgs=@('build','-trimpath','-ldflags',$ldflags)
	$buildArgs+=@('-o',$candidateExe,'.')
	& go @buildArgs

 if($LASTEXITCODE){throw 'Installer build failed.'}

}finally{Pop-Location}

if($env:OPTISHADE_SIGNING_THUMBPRINT){& "$root/sign-release.ps1" -File $candidateExe -Thumbprint $env:OPTISHADE_SIGNING_THUMBPRINT}

if($VerifySecurity -or $RequireSigned){& "$root/verify-release-security.ps1" -Files @("$root/installer/FusionSetup.exe",$candidateExe) -Report "$preview/security-check.json" -RequireSigned:$RequireSigned}

TestOptiShadeFinalPackage $candidateExe $root $buildChannel $buildVersion
& python (Join-Path $root 'reconstruction/candidate_receipt.py') --root $root --executable $candidateExe --output ($candidateExe+'.candidate.json')
if($LASTEXITCODE){throw 'Candidate handoff identity verification failed. Candidate is not ready for testing.'}

Write-Output "Built: $preview"








