$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/ownership.ps1"
function AssertClosed($Game){}
function SavePreRestoreEvidence($Game,$Folder){}
function Check($ok,$message){if(-not $ok){throw $message};"PASS: $message"}
$root=Join-Path $env:TEMP ('OptiShade-transaction-fixture-'+[guid]::NewGuid().ToString('N'))
$game=Join-Path $root 'Game';$payload=Join-Path $root 'Payload';$store=Join-Path $root 'Store'
New-Item -ItemType Directory -Path $game,$payload -Force|Out-Null
Set-Content "$payload/A.txt" 'new A';Set-Content "$payload/B.txt" 'new B';Set-Content "$payload/winmm.dll" 'new loader'
Set-Content "$game/A.txt" 'original A';Set-Content "$game/B.txt" 'original B'
function Catalogue { @(Get-ChildItem $payload -File|Where-Object Name -ne 'files.json'|ForEach-Object {@{Path=$_.Name;Hash=(HashFile $_.FullName)}})|ConvertTo-Json|Set-Content "$payload/files.json" }
Catalogue
$a=HashFile "$game/A.txt";$b=HashFile "$game/B.txt"
$script:failCopy=$false;$script:failure=''
function Copy-Item([string]$LiteralPath,[string]$Path,[string]$Destination,[switch]$Force){
 $source=if($LiteralPath){$LiteralPath}else{$Path}
 if($script:failCopy -and $source -eq "$payload\B.txt" -and $Destination -eq "$game\B.txt"){$script:failCopy=$false;throw [IO.IOException]::new($script:failure)}
 Microsoft.PowerShell.Management\Copy-Item -LiteralPath $source -Destination $Destination -Force:$Force
}
foreach($failure in @('Injected interruption after first copy','Injected disk-full error during payload write')){
 $script:failure=$failure;$script:failCopy=$true;$refused=$false
 try{InstallFusion $game $payload $store "$root/Manager.exe"}catch{$refused=$true}
 Check ($refused -and (HashFile "$game/A.txt") -eq $a -and (HashFile "$game/B.txt") -eq $b -and -not(Test-Path "$game/winmm.dll")) "$failure rolls back all game bytes"
 Check (-not(Test-Path (ManifestPath $store $game))) 'Failed new transaction is not marked installed'
}
$missing=Join-Path $payload 'B.txt';Remove-Item -LiteralPath $missing
$refused=$false;try{InstallFusion $game $payload $store "$root/Manager.exe"}catch{$refused=$_.Exception.Message -like '*extracted file is missing*'}
Check ($refused -and (HashFile "$game/A.txt") -eq $a -and -not(Test-Path "$game/winmm.dll")) 'Missing or quarantined extracted payload is rejected before game changes'
Set-Content $missing 'new B';Catalogue
$mp=InstallFusion $game $payload $store "$root/Manager.exe"
$installedA=HashFile "$game/A.txt";$installedB=HashFile "$game/B.txt";$installedLoader=HashFile "$game/winmm.dll";$receipt=HashFile $mp
Set-Content "$payload/A.txt" 'next A';Set-Content "$payload/B.txt" 'next B';Set-Content "$payload/winmm.dll" 'next loader';Catalogue
$script:failure='Injected update interruption';$script:failCopy=$true;$refused=$false
try{InstallFusion $game $payload $store "$root/NewManager.exe" -ReplaceExisting $true -ReplaceMods @(FindFusionConflicts $game)}catch{$refused=$true}
Check ($refused -and (HashFile "$game/A.txt") -eq $installedA -and (HashFile "$game/B.txt") -eq $installedB -and (HashFile "$game/winmm.dll") -eq $installedLoader) 'Interrupted update recovers the complete previous component set'
# JSON rewrite may change BOM/newline, so verify the meaningful state and ownership.
$m=Get-Content $mp -Raw|ConvertFrom-Json
Check ($m.Status -eq 'Installed' -and @($m.Files|Where-Object {$_.Path -eq 'winmm.dll' -and $_.Hash -eq $installedLoader}).Count -eq 1) 'Recovered update receipt describes only the previous installed loader'
RestoreFusion $mp
Check ((HashFile "$game/A.txt") -eq $a -and (HashFile "$game/B.txt") -eq $b -and -not(Test-Path "$game/winmm.dll")) 'Complete restore still recovers original bytes after failed update'
