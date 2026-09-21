$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/compatibility.ps1"
$fixture=Join-Path $env:TEMP ('OptiShade-compatibility-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$rtx=[pscustomobject]@{Known=$true;Names='NVIDIA GeForce RTX 5090'}
$amd=[pscustomobject]@{Known=$true;Names='AMD Radeon RX 7900 XTX'}
$unknown=[pscustomobject]@{Known=$false;Names=''}
function Check($ok,$label){if(-not $ok){throw "FAIL: $label"};"PASS: $label"}
$exe=Join-Path $fixture 'eurotrucks2.exe'
$plan=GetFusionCompatibility $fixture $exe $rtx
Check (-not $plan.PossibleInput -and -not $plan.DownloadNvidia) 'No input: no NVIDIA downloads, even on RTX'
Check ($plan.Performance -match 'Image effects|image effects') 'Effects-only explanation'
$managed=Join-Path $fixture 'OptiShadeData/Engine';New-Item -ItemType Directory -Path $managed -Force|Out-Null
Copy-Item "$PSScriptRoot/../installer/FusionSetup.exe" (Join-Path $managed 'nvngx_dlss.dll')
$plan=GetFusionCompatibility $fixture $exe $rtx
Check (-not $plan.PossibleInput) 'Our own runtime files do not imply native support'
Copy-Item "$PSScriptRoot/../installer/FusionSetup.exe" (Join-Path $fixture 'nvngx_dlssg.dll')
$plan=GetFusionCompatibility $fixture $exe $rtx
Check (-not $plan.PossibleInput) 'Frame-generation companion alone is not an upscaler input'
Copy-Item "$PSScriptRoot/../installer/FusionSetup.exe" (Join-Path $fixture 'libxess.dll')
$plan=GetFusionCompatibility $fixture $exe $rtx
Check (-not $plan.PossibleInput) 'ETS2 copied upscaler files do not enable an unsupported feed path'
$exe=Join-Path $fixture 'GenericGame.exe'
$plan=GetFusionCompatibility $fixture $exe $rtx
Check ($plan.PossibleInput -and $plan.DownloadNvidia) 'Native XeSS is a possible input on RTX, not proof of activation'
Check ($plan.RuntimeState -eq 'Not tested in game') 'Discovery never claims rendering'
$plan=GetFusionCompatibility $fixture $exe $amd
Check ($plan.PossibleInput -and -not $plan.DownloadNvidia) 'AMD gets no NVIDIA downloads'
Check ($plan.NeuralRendering -match 'not supported') 'AMD neural-rendering limitation explained'
$plan=GetFusionCompatibility $fixture $exe $unknown
Check (-not $plan.DownloadNvidia) 'Unknown hardware fails closed'
$gtx=[pscustomobject]@{Known=$true;Names='NVIDIA GeForce GTX 1080'}
Check (-not (GetFusionCompatibility $fixture $exe $gtx).DownloadNvidia) 'GTX is not mistaken for RTX'
$plan=GetFusionCompatibility $fixture (Join-Path $fixture 'FlightSimulator2024.exe') $rtx 'Xbox'
Check ($plan.Proxy -eq 'winmm.dll') 'Xbox loader preserved'
Check ((FormatFusionCompatibility $plan) -match '310.9.1') 'Pinned tested runtime versions shown'
Check (@(GetFusionInstalledVersions $fixture).Count -eq 1) 'Stored runtime inventory stays separate'
Set-Content (Join-Path $fixture 'renodx-dlss5.addon64') 'fixture'
$plan=GetFusionCompatibility $fixture $exe $rtx
Check ($plan.ExternalAddons.Count -eq 1) 'External neural-rendering add-ons are reported as conflicts'
"Fixture: $fixture"
