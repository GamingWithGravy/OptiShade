param([switch]$VerifySecurity,[switch]$RequireSigned)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot;$payload=Join-Path $root 'installer/PayloadFusion'
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
New-Item -ItemType Directory -Path "$payload/OptiShadeData/Vulkan" -Force|Out-Null
@'
{"file_format_version":"1.2.0","layer":{"name":"VK_LAYER_reshade","type":"GLOBAL","library_path":"../../ReShade64.dll","api_version":"1.3.268","implementation_version":"1","description":"OptiShade Vulkan image effects","device_extensions":[{"name":"VK_EXT_tooling_info","spec_version":"1","entrypoints":["vkGetPhysicalDeviceToolPropertiesEXT"]}]}}
'@ | Set-Content -LiteralPath "$payload/OptiShadeData/Vulkan/OptiShade.json" -Encoding ASCII
"Techniques=OptiShade_TAA_Guides@OptiShade_TAA_Guides.fx`r`nTechniqueSorting=OptiShade_TAA_Guides@OptiShade_TAA_Guides.fx" | Set-Content -LiteralPath "$payload/OptiShadeData/Presets/X-Plane neural guides.ini" -Encoding ASCII
# Fail closed on local evidence accidentally left in the embedded payload.
$private=@(Get-ChildItem -LiteralPath $payload -File -Recurse|Where-Object {$_.Name -match '(?i)(diagnostics-|Import-result-|\.dmp$|\.log$|Codex_|Licensing-review-|Ownership-licensing-audit|Release-.*draft|test-results|test-notes)'})
if($private.Count){throw ('Private/debug files found in package staging: '+($private.Name -join ', '))}
$files=@(Get-ChildItem $payload -File -Recurse|Where-Object {$_.FullName -ne (Join-Path $payload 'files.json')}|ForEach-Object {[pscustomobject]@{Path=$_.FullName.Substring($payload.Length+1);Hash=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}})
$files|ConvertTo-Json|Set-Content "$payload/files.json" -Encoding UTF8
$preview=Join-Path $root 'dist'
New-Item -ItemType Directory -Path $preview -Force|Out-Null
if($env:OPTISHADE_SIGNING_THUMBPRINT){& "$root/sign-release.ps1" -File "$root/installer/FusionSetup.exe" -Thumbprint $env:OPTISHADE_SIGNING_THUMBPRINT}
Push-Location "$root/installer"
try{
 & go test -count=1 -v .
 if($LASTEXITCODE){throw 'Embedded payload verification failed. Installer was not built.'}
 & go build -trimpath -ldflags '-H=windowsgui -s -w' -o "$preview/OptiShade_Version_0.21.3-beta.2.exe" .
 if($LASTEXITCODE){throw 'Installer build failed.'}
}finally{Pop-Location}
if($env:OPTISHADE_SIGNING_THUMBPRINT){& "$root/sign-release.ps1" -File "$preview/OptiShade_Version_0.21.3-beta.2.exe" -Thumbprint $env:OPTISHADE_SIGNING_THUMBPRINT}
if($VerifySecurity -or $RequireSigned){& "$root/verify-release-security.ps1" -Files @("$root/installer/FusionSetup.exe","$preview/OptiShade_Version_0.21.3-beta.2.exe") -Report "$preview/security-check.json" -RequireSigned:$RequireSigned}
Write-Output "Built: $preview"



