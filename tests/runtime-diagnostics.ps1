$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/library.ps1"
. "$PSScriptRoot/../installer/compatibility.ps1"
function Assert($value,$text){if(-not $value){throw "FAIL: $text"};"PASS: $text"}
function Get-CimInstance { @([pscustomobject]@{Name='NVIDIA GeForce RTX 5080';DriverVersion='32.0.15.8180'}) }
$gpu=GetFusionGpu
Assert ($gpu.Drivers[0].Version -eq '581.80') 'Windows driver version is displayed as NVIDIA driver version'
$game=Join-Path $env:TEMP ('OptiShade-model-check-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $game|Out-Null
Set-Content (Join-Path $game 'nvngx.dll_dlssnr.dll') 'helper'
$report=GetNeuralRuntimeStatus $game $gpu
Assert ($report.State -eq 'Missing' -and $report.Family -eq 'RTX 50') '5080 selects original family; helper alone does not count as model'
New-Item -ItemType Directory -Path (Join-Path $game 'OptiShadeData/Engine') -Force|Out-Null
Set-Content (Join-Path $game 'OptiShadeData/Engine/nvngx_dlssnr.dll') 'model'
Assert ((GetNeuralRuntimeStatus $game $gpu).State -eq 'Alternate location') 'Alternate engine location reported separately'
Set-Content (Join-Path $game 'nvngx_dlssnr.dll') 'unknown model'
Assert ((GetNeuralRuntimeStatus $game $gpu).State -eq 'Unverified') 'Unknown file is not accepted by version alone'
# Hash and signature outcomes are injected; no vendor binaries are fabricated or loaded.
$script:modelHash='E16BCF15E16E13F527491CDF7845B2FE6521A738D8F7C9C721866A8496E1FC8E'
function Get-FileHash { [pscustomobject]@{Hash=$script:modelHash} }
function Get-AuthenticodeSignature { [pscustomobject]@{Status='Valid'} }
Assert ((GetNeuralRuntimeStatus $game $gpu).State -eq 'Verified file') 'Known original model accepted for 5080 as stored file only'
$gpu.Names='NVIDIA GeForce RTX 4090'
Assert ((GetNeuralRuntimeStatus $game $gpu).State -eq 'Incompatible') '4090 rejects original RTX 50 model'
$script:modelHash='E67DEE209320CDAFE0E93E45675D7AA34323A53ACC57A72B2E40A181581C989A'
Assert ((GetNeuralRuntimeStatus $game $gpu).State -eq 'Verified file') '4090 identifies known compatibility runtime'
$gpu.Names='NVIDIA GeForce RTX 5080, NVIDIA GeForce RTX 4090'
Assert ((GetNeuralRuntimeStatus $game $gpu).State -eq 'GPU selection required') 'Multiple RTX cards do not silently select a GPU'
Assert ((GetNeuralRuntimeStatus $game $gpu).DriverAssessment -match 'unverified') 'No invented minimum driver requirement'
"Fixture: $game"
