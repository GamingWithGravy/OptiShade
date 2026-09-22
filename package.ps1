﻿$ErrorActionPreference='Stop'
$root=$PSScriptRoot;$payload=Join-Path $root 'installer/PayloadFusion'
if(Test-Path "$root/installer/DefaultEffects"){New-Item -ItemType Directory -Path "$payload/OptiShadeData" -Force|Out-Null;Copy-Item "$root/installer/DefaultEffects/*" "$payload/OptiShadeData" -Recurse -Force}
New-Item -ItemType Directory -Path $payload,(Join-Path $payload 'OptiShadeData/Presets'),(Join-Path $payload 'OptiShadeData/Shaders'),(Join-Path $payload 'OptiShadeData/Textures'),(Join-Path $payload 'OptiShadeData/Cache'),(Join-Path $payload 'OptiShadeData/Licenses'),(Join-Path $payload 'OptiShadeData/Engine/D3D12_OptiScaler') -Force|Out-Null
Copy-Item "$root/optiscaler/x64/Release/OptiScaler.dll" "$payload/winmm.dll" -Force
Copy-Item "$root/reshade/bin/x64/Release/ReShade64.dll" $payload -Force
Copy-Item "$root/optiscaler/x64/Release/a/nvngx.dll_dlssnr.dll" $payload -Force
Copy-Item "$root/optiscaler/external/xess/bin/*.dll" "$payload/OptiShadeData/Engine/" -Force
foreach($name in @('amd_fidelityfx_loader_dx12.dll','amd_fidelityfx_upscaler_dx12.dll','amd_fidelityfx_framegeneration_dx12.dll')){Copy-Item "$root/optiscaler/external/FidelityFX-SDK-v2/Kits/FidelityFX/signedbin/$name" "$payload/OptiShadeData/Engine/" -Force}
Copy-Item "$root/optiscaler/external/FidelityFX-SDK/PrebuiltSignedDLL/amd_fidelityfx_vk.dll" "$payload/OptiShadeData/Engine/" -Force
Copy-Item "$root/optiscaler/external/directx_agility_sdk/lib/D3D12Core.dll" "$payload/OptiShadeData/Engine/D3D12_OptiScaler/" -Force
Copy-Item "$root/optiscaler/LICENSE" "$payload/OptiShadeData/Licenses/OptiScaler-GPL3.txt" -Force
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
ScreenshotPath=.\OptiShadeData\Screenshots
PerformanceMode=0
SkipLoadingDisabledEffects=1
[OVERLAY]
ShowSplash=0
TutorialProgress=4
[SCREENSHOT]
SavePath=.\OptiShadeData\Screenshots
'@ | Set-Content "$payload/ReShade.ini" -Encoding ASCII
"Techniques=`r`nTechniqueSorting=" | Set-Content "$payload/OptiShadeData/Presets/My look.ini" -Encoding ASCII
foreach($dir in @('Shaders','Textures','Cache')){'OptiShade managed folder'|Set-Content "$payload/OptiShadeData/$dir/.keep"}
$files=@(Get-ChildItem $payload -File -Recurse|Where-Object {$_.FullName -ne (Join-Path $payload 'files.json')}|ForEach-Object {[pscustomobject]@{Path=$_.FullName.Substring($payload.Length+1);Hash=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}})
$files|ConvertTo-Json|Set-Content "$payload/files.json" -Encoding UTF8
$preview=Join-Path $root 'dist'
New-Item -ItemType Directory -Path $preview -Force|Out-Null
Push-Location "$root/installer"
try{
 & go test -count=1 -v .
 if($LASTEXITCODE){throw 'Embedded payload verification failed. Installer was not built.'}
 & go build -trimpath -ldflags '-H=windowsgui -s -w' -o "$preview/OptiShade_Version_0.20.4.exe" .
 if($LASTEXITCODE){throw 'Installer build failed.'}
}finally{Pop-Location}
Write-Output "Built: $preview"



