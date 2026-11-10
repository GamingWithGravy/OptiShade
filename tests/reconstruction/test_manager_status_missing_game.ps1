$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $root 'Beta/installer/library.ps1')
. (Join-Path $root 'Beta/installer/manager-status.ps1')
$assertions=0
function Check([bool]$Value,[string]$Message){if(-not $Value){throw $Message};$script:assertions++}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-stale-msfs-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try{
 $msfs=Join-Path $temp 'MicrosoftFlightSimulator'
 [void][IO.Directory]::CreateDirectory($msfs)
 $game=[pscustomobject]@{Name='Microsoft Flight Simulator 2020';Folder=$msfs;InstallFolder=$msfs;Launcher='Steam'}
 Check (TestFusionMissingSimulatorExecutable $game) 'An existing MSFS folder with no simulator executable was not identified as stale.'
 [IO.File]::WriteAllBytes((Join-Path $msfs 'FlightSimulator.exe'),[byte[]]@())
 Check (-not (TestFusionMissingSimulatorExecutable $game)) 'An installed MSFS2020 executable was misclassified as missing.'
 Remove-Item -LiteralPath (Join-Path $msfs 'FlightSimulator.exe') -Force
 [IO.File]::WriteAllBytes((Join-Path $msfs 'FlightSimulator2024.exe'),[byte[]]@())
 Check (-not (TestFusionMissingSimulatorExecutable $game)) 'A different simulator executable was treated as an uninstalled game instead of preserving the mismatch guard.'
 Remove-Item -LiteralPath (Join-Path $msfs 'FlightSimulator2024.exe') -Force
 $generic=[pscustomobject]@{Name='Flight Simulator scenery tools';Folder=$msfs;Launcher='Steam'}
 Check (-not (TestFusionMissingSimulatorExecutable $generic)) 'A generic game with a similar name was treated as an MSFS installation.'

 $manifestFile=Join-Path $temp 'manifest.json';[IO.File]::WriteAllText($manifestFile,'{}')
 function global:ManifestPath([string]$Store,[string]$Folder){return $script:testManifestPath}
 function global:ReadOptiShadeState([string]$Path){return $script:testManifest}
 $script:testManifestPath=$manifestFile
 $script:testManifest=[pscustomobject]@{Game=$msfs;Status='Installed'}
 $receipt=GetOptiShadeMissingSimulatorReceipt $game $temp
 Check ($receipt -and $receipt.ManifestPath -eq $manifestFile -and $receipt.GameMissing -ne $true -and $receipt.Message -match 'Use Remove in the Library') 'A canonical installed receipt was not retained with clear cleanup guidance.'
 $script:testManifest=[pscustomobject]@{Game=(Join-Path $temp 'other-game');Status='Installed'}
 Check (-not (GetOptiShadeMissingSimulatorReceipt $game $temp)) 'A stale library row was allowed to consume another game installation receipt.'
 $script:testManifest=[pscustomobject]@{Game=$msfs;Status='Restoring'}
 Check (-not (GetOptiShadeMissingSimulatorReceipt $game $temp)) 'A restoring receipt was incorrectly treated as a removable stale installation.'
 Remove-Item -LiteralPath $manifestFile -Force
 Check (-not (GetOptiShadeMissingSimulatorReceipt $game $temp)) 'A missing receipt was treated as a managed stale installation.'

 $managerPath=Join-Path $root 'Beta/installer/manager.ps1';$manager=[IO.File]::ReadAllText($managerPath)
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($manager,[ref]$tokens,[ref]$errors)
 if($errors.Count){throw ('Manager parse failed: '+$errors[0].Message)}
 $refresh=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'RefreshLibrary'},$true)
 Check ($refresh -and $refresh.Extent.Text -match 'cached\.GameMissing' -and $refresh.Extent.Text -match 'UpdateButtonVisibility=\[Windows\.Visibility\]::Collapsed') 'The Library does not visibly retain stale managed games or suppress update actions.'
 $snapshotPath=Join-Path $root 'Beta/installer/manager-status.ps1';$snapshot=[IO.File]::ReadAllText($snapshotPath)
 $tokens=$null;$errors=$null;$snapshotAst=[Management.Automation.Language.Parser]::ParseInput($snapshot,[ref]$tokens,[ref]$errors)
 if($errors.Count){throw ('Manager status parse failed: '+$errors[0].Message)}
 $worker=$snapshotAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'InvokeOptiShadeManagerSnapshot'},$true)
 Check ($worker -and $worker.Extent.Text.IndexOf('GetOptiShadeMissingSimulatorReceipt') -lt $worker.Extent.Text.IndexOf('GetFusionGameTargetFolder') -and $worker.Extent.Text -match 'GameMissing=\$true' -and $worker.Extent.Text -match 'continue') 'The stale receipt is not recognized before normal game-path validation and update discovery.'
 Write-Output "Stale simulator status: $assertions assertions passed; live, removed and mismatched executable cases checked."
}finally{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
