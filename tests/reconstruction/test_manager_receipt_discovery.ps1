param([string]$Root=(Join-Path $PSScriptRoot '../..'))
$ErrorActionPreference='Stop'
. (Join-Path $Root 'Beta/installer/ownership.ps1')
. (Join-Path $Root 'Beta/installer/library.ps1')
function Check($Value,[string]$Message){if(-not $Value){throw $Message};Write-Output ('PASS: '+$Message)}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-ReceiptDiscovery-'+[guid]::NewGuid().ToString('N'))
try{
 $state=Join-Path $fixture 'store';$game=Join-Path $fixture 'Sports 2024';$nested=Join-Path $game 'Binaries/Win64'
 [void][IO.Directory]::CreateDirectory($nested)
 [IO.File]::WriteAllText((Join-Path $nested 'Sports.exe'),'fixture')
 $receipt=ManifestPath $state $nested;$m=[pscustomobject]@{Game=$nested;Status='Installed';Files=@()};[void][IO.Directory]::CreateDirectory((Split-Path $receipt));WriteState $m $receipt
 $archived=Join-Path (Split-Path $receipt) 'Repair-archived/manifest.json';[void][IO.Directory]::CreateDirectory((Split-Path $archived));WriteState ([pscustomobject]@{Game=(Join-Path $fixture 'Deleted');Status='Installed';Files=@()}) $archived
 [void][IO.Directory]::CreateDirectory((Join-Path $state 'Games/0000000000000000'))
 WriteState $m (Join-Path $state 'Games/0000000000000000/manifest.json')
 $receipts=@(GetFusionInstallationReceipts $state)
 Check ($receipts.Count -eq 1 -and $receipts[0].FullName -eq $receipt) 'only canonical direct receipts are enumerated; archives and wrong path IDs are excluded'
 Check ((GetFusionInstallState $state $nested) -eq 'Installed') 'current receipt still identifies its installation'
 # Count real JSON reads, not timing thresholds: selection must inspect only
 # its canonical receipt and consume that exact validated object once.
 $script:originalReceiptReader=(Get-Command ReadOptiShadeJson).ScriptBlock
 $script:receiptReadPaths=@()
 function ReadOptiShadeJson([string]$Path,[string]$Role='saved state',[int]$MaxBytes=4194304,[string]$Shape='Object'){
  $script:receiptReadPaths+=$Path
  & $script:originalReceiptReader $Path $Role $MaxBytes $Shape
 }
 $unrelated=Join-Path $fixture 'Unrelated';[void][IO.Directory]::CreateDirectory($unrelated)
 $unrelatedReceipt=ManifestPath $state $unrelated;[void][IO.Directory]::CreateDirectory((Split-Path $unrelatedReceipt))
 WriteState ([pscustomobject]@{Game=$unrelated;Status='Installed';Files=@()}) $unrelatedReceipt
 $script:receiptReadPaths=@()
 Check ((GetFusionInstallState $state $nested) -eq 'Installed' -and $script:receiptReadPaths.Count -eq 1 -and $script:receiptReadPaths[0] -eq $receipt) 'selected installation reads its own canonical receipt once and no unrelated receipt'
 $script:receiptReadPaths=@()
 Check ((GetFusionInstallState $state ($nested.ToUpperInvariant()+'\')) -eq 'Installed' -and $script:receiptReadPaths.Count -eq 1) 'direct lookup preserves Windows case and trailing-separator path normalization'
 [IO.File]::WriteAllText($unrelatedReceipt,'broken unrelated JSON')
 $script:receiptReadPaths=@()
 Check ((GetFusionInstallState $state $nested) -eq 'Installed' -and $script:receiptReadPaths.Count -eq 1) 'malformed unrelated receipt does not add parse retries to selected status'
 $missingGame=Join-Path $fixture 'Not installed';[void][IO.Directory]::CreateDirectory($missingGame)
 $script:receiptReadPaths=@()
 Check ((GetFusionInstallState $state $missingGame) -eq 'Not installed' -and $script:receiptReadPaths.Count -eq 0) 'uninstalled selection does not scan any other receipt'
 WriteState ([pscustomobject]@{Game=$unrelated;Status='Installed';Files=@()}) $receipt
 Check ((GetFusionInstallState $state $nested) -eq 'Not installed') 'direct receipt cannot identify a different game even at the selected path ID'
 $m|Add-Member -NotePropertyName Downloads -NotePropertyValue 'Pending'
 WriteState $m $receipt
 Check ((GetFusionInstallState $state $nested) -eq 'Installed - downloads pending') 'status is freshly read after receipt changes without a stale global cache'
 $m.Status='Restored';WriteState $m $receipt
 Check ((GetFusionInstallState $state $nested) -eq 'Not installed (restored)') 'restored receipt is reflected immediately'
 $m.Status='Installed';$m.Downloads='Complete';WriteState $m $receipt
 $script:receiptReadPaths=@();$current=@(GetFusionInstallationReceipts $state)
 Check ($current.Count -eq 1 -and $current[0].FullName -eq $receipt) 'full discovery still contains malformed unrelated receipts and excludes wrong path IDs'
 # Use production path validation; executable discovery alone is stubbed to
 # avoid treating the fixture's deliberately non-executable text as a PE file.
 function FindFusionExecutable($Folder,$Launcher,$Title){$path=Join-Path $Folder 'Sports.exe';if(Test-Path -LiteralPath $path){[pscustomobject]@{Path=$path;Score=1000}}}
 $selection=[pscustomobject]@{Name='Sports 2024';Folder=$game;InstallFolder=$nested;Launcher='Steam'}
 Check ((GetFusionGameTargetFolder $selection) -eq $nested) 'generic title with 2024 is not misclassified as MSFS; valid nested executable target retained'
 $other=Join-Path $fixture 'Other';[void][IO.Directory]::CreateDirectory($other);[IO.File]::WriteAllText((Join-Path $other 'Sports.exe'),'fixture')
 $selection.InstallFolder=$other
 Check ((GetFusionGameTargetFolder $selection) -eq $game) 'unrelated stale cached target cannot redirect selected game'
 $msfs=Join-Path $fixture 'MSFS2024';[void][IO.Directory]::CreateDirectory($msfs)
 $failed=$false;try{GetFusionGameTargetFolder ([pscustomobject]@{Name='MSFS2024';Folder=$msfs})}catch{$failed=$true}
 Check $failed 'empty custom MSFS root cannot pass title-to-executable validation'
 # Async snapshot per-game failure/receipt identity isolation is exercised by
 # test_manager_responsiveness.ps1 using the full production worker closure.
 Remove-Item -LiteralPath $receipt
 Check ((GetFusionInstallState $state $nested) -eq 'Not installed') 'archived receipt cannot resurrect an installation after live receipt removal'
}finally{if($fixture.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue}}
