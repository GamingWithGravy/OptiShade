param([Parameter(Mandatory=$true)][string]$WrapperFile)
. "$PSScriptRoot/test_components.ps1"
$wg=Join-Path $Output 'wrapped-d3d9';$ws=Join-Path $Output 'wrapped-state'
New-Item -ItemType Directory -Path $wg,$ws -Force|Out-Null
$we=Join-Path $wg 'gta_sa.exe'
[Array]::Clear($bytes32,576,64);$import=[Text.Encoding]::ASCII.GetBytes("d3d9.dll`0");[Array]::Copy($import,0,$bytes32,576,$import.Length);[IO.File]::WriteAllBytes($we,$bytes32)
Copy-Item -LiteralPath $WrapperFile -Destination (Join-Path $wg 'd3d9.dll')
[IO.File]::WriteAllText((Join-Path $wg 'dgVoodoo.conf'),"[DirectX]`nDisableAndPassThru=false`nOutputAPI=d3d11_fl11_0`n")
$wh=HashFile (Join-Path $wg 'd3d9.dll')
Check (@(FindFusionConflicts $wg|Where-Object Path -eq 'd3d9.dll').Count -eq 0) 'configured official dgVoodoo is a preserved dependency'
$wm=InstallFusion $wg $payload $ws (Join-Path $Output 'fixture-installer.exe') 'dxgi.dll' -Executable $we
$null=InstallFusion $wg $payload $ws (Join-Path $Output 'fixture-installer.exe') 'dxgi.dll' @(FindFusionConflicts $wg) -ReplaceExisting $true -PreserveConfiguration $true
Check ((HashFile (Join-Path $wg 'd3d9.dll')) -eq $wh) 'core install and repair preserve wrapper bytes'
Check (@((ReadOptiShadeState $wm).Files|Where-Object Path -eq 'd3d9.dll').Count -eq 0) 'wrapper remains external and is not claimed as owned'
Check ((GetOptiShadeMethodRendererApi 'auto' 'dxgi.dll' @('DX9')) -eq 'DirectX') 'DXGI translation route is not relabelled native D3D9'
[IO.File]::WriteAllText((Join-Path $wg 'dgVoodoo.conf'),"[DirectX]`nDisableAndPassThru=true`nOutputAPI=d3d11`n")
Check (@(FindFusionConflicts $wg|Where-Object Path -eq 'd3d9.dll').Count -eq 1) 'disabled wrapper still requires conflict review'