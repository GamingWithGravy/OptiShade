$ErrorActionPreference='Stop'
$root=$PSScriptRoot;$payload=Join-Path $root 'installer/PayloadFusion'
. "$root/build-identity.ps1"
# This test build retains the pinned upstream MFG DLL and its Backspace menu.
# A future controls-only replacement requires its separate verification receipt.
$native=AssertOptiShadeCandidateBuild $root
[void][IO.Directory]::CreateDirectory($payload)
$buildVersion='0.21.4';$buildChannel='stable'
Copy-Item -LiteralPath "$root/optiscaler/x64/Release/OptiScaler.dll" -Destination "$payload/winmm.dll" -Force
Copy-Item -LiteralPath "$root/reshade/bin/x64/Release/ReShade64.dll" -Destination "$payload/ReShade64.dll" -Force
if((Get-FileHash "$root/installer/OptionalMFG/RTXMFG.dll").Hash -ne 'E9CA3587854EEB723E0579F7DDF6CFB1E6CF4BED79B0D75BC716003ED98FE040'){throw 'Pinned RTXMFG payload hash mismatch'}
New-Item -ItemType Directory -Path "$payload/OptiShadeData/MFG","$payload/OptiShadeData/Licenses/RTXMFG" -Force|Out-Null
Copy-Item "$root/installer/OptionalMFG/RTXMFG.dll" "$payload/OptiShadeData/MFG/RTXMFG.dll" -Force
foreach($notice in @('LICENSE.txt','LICENSE-UAL.txt','LICENSE-ImGui.txt','LICENSE-MinHook.txt','UPSTREAM-README.md','UPSTREAM-BUILD.md','PROVENANCE.md')){Copy-Item -LiteralPath "$root/installer/OptionalMFG/$notice" -Destination "$payload/OptiShadeData/Licenses/RTXMFG" -Force}
if(Test-Path "$root/installer/DefaultEffects"){New-Item -ItemType Directory -Path "$payload/OptiShadeData" -Force|Out-Null;Copy-Item "$root/installer/DefaultEffects/*" "$payload/OptiShadeData" -Recurse -Force}
New-Item -ItemType Directory -Path $payload,(Join-Path $payload 'OptiShadeData/Presets'),(Join-Path $payload 'OptiShadeData/Shaders'),(Join-Path $payload 'OptiShadeData/Textures'),(Join-Path $payload 'OptiShadeData/Cache'),(Join-Path $payload 'OptiShadeData/Licenses'),(Join-Path $payload 'OptiShadeData/Engine/D3D12_OptiScaler') -Force|Out-Null
Copy-Item "$root/optiscaler/x64/Release/OptiScaler.dll" "$payload/winmm.dll" -Force
Copy-Item "$root/reshade/bin/x64/Release/ReShade64.dll" $payload -Force
New-Item -ItemType Directory -Path "$payload/OptiShadeData/Shaders/Custom" -Force|Out-Null
Copy-Item "$root/installer/FusionCinema/Gravy_FusionCinema.fx" "$payload/OptiShadeData/Shaders/Custom/Gravy_FusionCinema.fx" -Force
Copy-Item "$root/installer/FusionCinema/Gravy - Fusion Cinema Custom v1.ini" "$payload/OptiShadeData/Presets/Gravy - Fusion Cinema Custom v1.ini" -Force
Copy-Item "$root/installer/FusionCinema/LICENSE" "$payload/OptiShadeData/Licenses/FusionCinema-GPL3.txt" -Force
Copy-Item "$root/optiscaler/x64/Release/a/nvngx.dll_dlssnr.dll" $payload -Force
Copy-Item "$root/optiscaler/external/xess/bin/*.dll" "$payload/OptiShadeData/Engine/" -Force
foreach($name in @('amd_fidelityfx_loader_dx12.dll','amd_fidelityfx_upscaler_dx12.dll','amd_fidelityfx_framegeneration_dx12.dll')){Copy-Item "$root/optiscaler/external/FidelityFX-SDK-v2/Kits/FidelityFX/signedbin/$name" "$payload/OptiShadeData/Engine/" -Force}
Copy-Item "$root/optiscaler/external/FidelityFX-SDK/PrebuiltSignedDLL/amd_fidelityfx_vk.dll" "$payload/OptiShadeData/Engine/" -Force
Copy-Item "$root/optiscaler/external/directx_agility_sdk/lib/D3D12Core.dll" "$payload/OptiShadeData/Engine/D3D12_OptiScaler/" -Force
Copy-Item "$root/optiscaler/LICENSE" "$payload/OptiShadeData/Licenses/OptiScaler-GPL3.txt" -Force
foreach($notice in @('LICENSE','LICENSE.md','OPTISHADE_LICENSING.md','NOTICE.md','BRANDING.md','LICENSING.md')){Copy-Item (Join-Path $root $notice) (Join-Path "$payload/OptiShadeData/Licenses" $notice) -Force}
New-Item -ItemType Directory -Path "$payload/OptiShadeData/Licenses/LICENSES" -Force|Out-Null
foreach($notice in @('GPL-3.0.txt','ReShade-BSD-3-Clause.txt','OPTISHADE-PROPRIETARY.txt')){Copy-Item (Join-Path "$root/LICENSES" $notice) (Join-Path "$payload/OptiShadeData/Licenses/LICENSES" $notice) -Force}
Copy-Item "$root/installer/BRANDING-LICENSE.md" "$payload/OptiShadeData/Licenses/BRANDING-LICENSE.md" -Force
Copy-Item "$root/reshade/LICENSE.md" "$payload/OptiShadeData/Licenses/ReShade-BSD3.txt" -Force
Copy-Item "$root/optiscaler/Licenses/*" "$payload/OptiShadeData/Licenses/" -Recurse -Force
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
@'
[GENERAL]
EffectSearchPaths=.\OptiShadeData\Shaders\**
TextureSearchPaths=.\OptiShadeData\Textures\**
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
'@ | Set-Content "$payload/ReShade.ini" -Encoding ASCII
"Techniques=`r`nTechniqueSorting=" | Set-Content "$payload/OptiShadeData/Presets/My look.ini" -Encoding ASCII
foreach($dir in @('Shaders','Textures','Cache')){'OptiShade managed folder'|Set-Content "$payload/OptiShadeData/$dir/.keep"}
New-Item -ItemType Directory -Path "$payload/OptiShadeData/Tools" -Force|Out-Null
Copy-Item "$root/installer/store-paths.ps1" "$payload/OptiShadeData/Tools/store-paths.ps1" -Force
Copy-Item "$root/installer/import-effects.ps1" "$payload/OptiShadeData/Tools/import-effects.ps1" -Force
Copy-Item "$root/installer/EffectPackages.ini" "$payload/OptiShadeData/Tools/EffectPackages.ini" -Force
New-Item -ItemType Directory -Path "$payload/OptiShadeData/Tools/StandardHeaders" -Force|Out-Null
Copy-Item "$root/installer/DefaultEffects/Shaders/Packages/00/ReShade*.fxh" "$payload/OptiShadeData/Tools/StandardHeaders" -Force
# Remove stale experimental files from staging, including files copied by DefaultEffects.
foreach($relative in @('OptiShadeData/Vulkan','OptiShadeData/Shaders/OptiShadeTaa','OptiShadeData/Textures/vort_BlueNoise.png','OptiShadeData/Presets/X-Plane neural guides.ini')){
 $target=[IO.Path]::GetFullPath((Join-Path $payload $relative))
 if(-not $target.StartsWith([IO.Path]::GetFullPath($payload)+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid staging cleanup path'}
 if(Test-Path -LiteralPath $target){Remove-Item -LiteralPath $target -Recurse -Force}
}
# Fail closed on local evidence accidentally left in the embedded payload.
$private=@(Get-ChildItem -LiteralPath $payload -File -Recurse|Where-Object {$_.Name -match '(?i)(diagnostics-|Import-result-|\.dmp$|\.log$|Codex_|Licensing-review-|Ownership-licensing-audit|Release-.*draft|test-results|test-notes)'})
if($private.Count){throw ('Private/debug files found in package staging: '+($private.Name -join ', '))}
@{Version=$buildVersion;Channel=$buildChannel;SourceHead=$native.SourceHead;SourceSHA256=$native.SourceSHA256;BuiltUtc=$native.BuiltUtc;NativeBinaries=$native.Binaries}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath "$payload/OptiShadeData/BuildIdentity.json" -Encoding UTF8
$files=@(Get-ChildItem $payload -File -Recurse|Where-Object {$_.FullName -ne (Join-Path $payload 'files.json')}|ForEach-Object {[pscustomobject]@{Path=$_.FullName.Substring($payload.Length+1);Hash=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}})
$files|ConvertTo-Json|Set-Content "$payload/files.json" -Encoding UTF8
$preview=Join-Path $root 'dist'
New-Item -ItemType Directory -Path $preview -Force|Out-Null
Push-Location "$root/installer"
try{
 & go test -count=1 -v .
 if($LASTEXITCODE){throw 'Embedded payload verification failed. Installer was not built.'}
 & go build -trimpath -ldflags '-H=windowsgui -s -w' -o "$preview/OptiShade_Version_0.21.4.exe" .
 if($LASTEXITCODE){throw 'Installer build failed.'}
}finally{Pop-Location}
TestOptiShadeFinalPackage "$preview/OptiShade_Version_0.21.4.exe" $root $buildChannel $buildVersion
Write-Output "Built: $preview"



