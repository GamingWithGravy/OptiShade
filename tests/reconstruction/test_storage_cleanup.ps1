param([string]$Output)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Beta/installer/ownership.ps1"
. "$root/Beta/installer/recovery.ps1"
if(-not $Output){$Output=Join-Path $root ('test-results/storage-cleanup-'+[guid]::NewGuid().ToString('N'))}
$store=Join-Path $Output 'store';$diag=Join-Path $store 'Diagnostics';$other=Join-Path $store 'Games'
New-Item -ItemType Directory -Path (Join-Path $diag 'AutoHang/game-a'),(Join-Path $diag 'reports'),$other,(Join-Path $store 'Downloads') -Force|Out-Null
[IO.File]::WriteAllText((Join-Path $diag 'report.zip'),'diagnostic zip')
[IO.File]::WriteAllText((Join-Path $diag 'AutoHang/game-a/hang.dmp'),'hang evidence')
[IO.File]::WriteAllText((Join-Path $diag 'reports/summary.txt'),'summary')
[IO.File]::WriteAllText((Join-Path $other 'manifest.json'),'game record')
[IO.File]::WriteAllText((Join-Path $store 'Downloads/download.bin'),'download cache')
function Check($Condition,$Label){if(-not $Condition){throw $Label};Write-Output ('PASS: '+$Label)}
$inventory=GetOptiShadeDiagnosticsInventory $store
Check ($inventory.Count -eq 3 -and $inventory.Bytes -gt 0 -and -not $inventory.HasLinkedItems) 'diagnostic inventory includes nested ZIP, hang capture and report files'
$result=ClearOptiShadeDiagnostics $store
Check ($result -like 'Cleared 3 diagnostic file(s)*' -and -not(Get-ChildItem -LiteralPath $diag -File -Recurse)) 'clear all diagnostics deletes report files and leaves an empty diagnostics root'
Check ((Test-Path (Join-Path $other 'manifest.json')) -and (Test-Path (Join-Path $store 'Downloads/download.bin'))) 'diagnostic cleanup leaves game records and downloads untouched'
$empty=GetOptiShadeDiagnosticsInventory $store
Check ($empty.Count -eq 0 -and $empty.Bytes -eq 0) 'diagnostic inventory reports an empty store after cleanup'
