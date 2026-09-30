$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/ownership.ps1"
function Check($ok,$message){if(-not $ok){throw $message};"PASS: $message"}
$script:events=@();$script:denied=$false
function Get-WinEvent($FilterHashtable,$MaxEvents,$ErrorAction){
 Check ($MaxEvents -eq 128 -and ($FilterHashtable.Id -join ',') -eq '1116,1117' -and $FilterHashtable.LogName -eq 'Microsoft-Windows-Windows Defender/Operational' -and $FilterHashtable.StartTime -gt (Get-Date).AddHours(-49)) 'Only bounded recent Defender events requested' | Out-Null
 if($script:denied){throw 'Access denied'}
 $script:events
}
function Event([string]$path,[string]$threat='Trojan:Win32/Fixture!cl',[int]$id=1116){
 $p=[Security.SecurityElement]::Escape($path);$t=[Security.SecurityElement]::Escape($threat)
 $e=[pscustomobject]@{Xml="<Event><System><EventID>$id</EventID></System><EventData><Data Name='Path'>$p</Data><Data Name='Threat Name'>$t</Data><Data Name='Action Name'>Allow</Data></EventData></Event>"}
 $e|Add-Member -MemberType ScriptMethod -Name ToXml -Value {$this.Xml};$e
}
$target='C:\OptiShade fixture\Payload\winmm.dll'
foreach($path in @('file:C:\Elsewhere\winmm.dll','file:C:\OptiShade fixture\Payload\winmm.dll.evil','file:C:\OptiShade fixture\Payload\winmm.dll\child','C:\OptiShade fixture\Payload')){
 $script:events=@(Event $path)
 Check ((GetDefenderFileEvidence $target) -like '*no matching recent Defender event*') 'Other paths and prefix matches are not attributed to this file'
}
$script:events=@(Event 'file:c:\OPTISHADE fixture\Payload\winmm.dll')
Check ((GetDefenderFileEvidence $target) -like '*recorded Trojan:Win32/Fixture!cl for this exact file*') 'Case-insensitive exact file detection is reported'
$script:events=@(Event ('containerfile:C:\Unrelated.zip;file:'+$target) 'Fixture action' 1117)
$message=GetDefenderFileEvidence $target
Check ($message -like '*recorded Fixture action*' -and $message -notmatch 'quarantined|removed|blocked') 'An action event does not imply successful quarantine or removal'
Check ($message -notmatch 'Unrelated|containerfile:|C:\\') 'Unrelated event resource paths are not included in the message'
$script:events=@(Event ('file:'+$target) "Fixture`nsecond line")
Check ((GetDefenderFileEvidence $target) -notmatch '[\r\n]') 'Event text cannot inject status lines'
foreach($label in @('Fixture C:\Private unrelated\Secret.txt','D:/Private unrelated/Secret.txt','Fixture \\private-host\share\Secret.txt')){
 $script:events=@(Event ('file:'+$target) $label)
 $message=GetDefenderFileEvidence $target
 Check ($message -like '*recorded unnamed detection*' -and $message -notmatch 'Private unrelated|private-host|Secret.txt') 'Malformed detection labels cannot reveal unrelated drive or UNC paths'
}
$script:denied=$true
Check ((GetDefenderFileEvidence $target) -like '*no matching recent Defender event*') 'Unavailable history is not a confirmed antivirus cause'
$script:denied=$false;$script:events=@()
Check ((GetDefenderFileEvidence $target) -like '*no matching recent Defender event*') 'Missing events keep the underlying verification failure'

# Actual filesystem transaction with a synthetic payload. The mocked copy removes
# only the fixture loader after a successful write, reproducing verification loss
# without changing antivirus settings or touching a real installation.
function AssertClosed($Game){}
function SavePreRestoreEvidence($Game,$Folder){}
function Get-CimInstance { @([pscustomobject]@{Name='AMD fixture adapter'}) }
$root=Join-Path $env:TEMP ('OptiShade-Defender-fixture-'+[guid]::NewGuid().ToString('N'))
$game=Join-Path $root 'Game';$payload=Join-Path $root 'Payload';$store=Join-Path $root 'Store'
New-Item -ItemType Directory -Path $game,$payload -Force|Out-Null
Set-Content -LiteralPath (Join-Path $game 'A.txt') -Value 'original user A'
Set-Content -LiteralPath (Join-Path $game 'winmm.dll') -Value 'original user loader'
Set-Content -LiteralPath (Join-Path $game 'unrelated.txt') -Value 'unrelated user data'
$originalA=HashFile (Join-Path $game 'A.txt');$originalLoader=HashFile (Join-Path $game 'winmm.dll');$unrelated=HashFile (Join-Path $game 'unrelated.txt')
function Catalogue {
 @('A.txt','winmm.dll')|ForEach-Object {@{Path=$_;Hash=(HashFile (Join-Path $payload $_))}}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $payload 'files.json')
}
Set-Content -LiteralPath (Join-Path $payload 'A.txt') -Value 'installed A'
Set-Content -LiteralPath (Join-Path $payload 'winmm.dll') -Value 'installed loader'
Catalogue
$script:removeCopiedLoader=$false;$script:removedCount=0
$script:fixtureSource=FullPath (Join-Path $payload 'winmm.dll');$script:fixtureDestination=FullPath (Join-Path $game 'winmm.dll')
function Copy-Item([string]$LiteralPath,[string]$Path,[string]$Destination,[switch]$Force){
 $source=if($LiteralPath){$LiteralPath}else{$Path}
 Microsoft.PowerShell.Management\Copy-Item -LiteralPath $source -Destination $Destination -Force:$Force
 if($script:removeCopiedLoader -and (FullPath $source) -eq $script:fixtureSource -and (FullPath $Destination) -eq $script:fixtureDestination){
  $script:removeCopiedLoader=$false;$script:removedCount++
  Remove-Item -LiteralPath $script:fixtureDestination -Force
 }
}
$mp=InstallFusion $game $payload $store (Join-Path $root 'Manager.exe') -ReplaceMods @(FindFusionConflicts $game)
$installedA=HashFile (Join-Path $game 'A.txt');$installedLoader=HashFile (Join-Path $game 'winmm.dll');$receipt=[IO.File]::ReadAllText($mp)
Set-Content -LiteralPath (Join-Path $payload 'A.txt') -Value 'updated A'
Set-Content -LiteralPath (Join-Path $payload 'winmm.dll') -Value 'updated loader'
Catalogue
$script:events=@(Event ('containerfile:C:\Private unrelated\Secret.zip;file:'+$script:fixtureDestination) 'Trojan:Win32/CopiedFixture!cl' 1117)
$script:removeCopiedLoader=$true;$failure=''
try{InstallFusion $game $payload $store (Join-Path $root 'Next.exe') -ReplaceExisting $true -ReplaceMods @(FindFusionConflicts $game)|Out-Null}catch{$failure=$_.Exception.Message}
Check ($script:removedCount -eq 1 -and $failure -like '*Installed file verification failed for winmm.dll*' -and $failure -like '*recorded Trojan:Win32/CopiedFixture!cl*') 'Copied loader deletion reports the affected filename and exact-file Defender evidence'
Check ($failure -notmatch 'Private unrelated|Secret.zip|quarantined|removed|blocked') 'Copied-file failure does not expose unrelated event paths or assert quarantine success'
Check ((HashFile (Join-Path $game 'A.txt')) -eq $installedA -and (HashFile (Join-Path $game 'winmm.dll')) -eq $installedLoader -and (HashFile (Join-Path $game 'unrelated.txt')) -eq $unrelated) 'Copied loader deletion rolls back all previous installed bytes and preserves unrelated files'
Check (([IO.File]::ReadAllText($mp)).TrimEnd([char[]]"`r`n") -ceq $receipt.TrimEnd([char[]]"`r`n")) 'Previous receipt content and ownership remain intact after copied-file failure'

Remove-Item -LiteralPath $script:fixtureSource -Force
$script:events=@(Event ('file:'+$script:fixtureSource) 'Trojan:Win32/ExtractedFixture!cl')
$failure=''
try{InstallFusion $game $payload $store (Join-Path $root 'Next.exe') -ReplaceExisting $true -ReplaceMods @(FindFusionConflicts $game)|Out-Null}catch{$failure=$_.Exception.Message}
Check ($failure -like '*Installer verification failed for winmm.dll*' -and $failure -like '*recorded Trojan:Win32/ExtractedFixture!cl*') 'Missing extracted loader reports its own exact-file detection'
Check ((HashFile (Join-Path $game 'A.txt')) -eq $installedA -and (HashFile (Join-Path $game 'winmm.dll')) -eq $installedLoader -and ([IO.File]::ReadAllText($mp)).TrimEnd([char[]]"`r`n") -ceq $receipt.TrimEnd([char[]]"`r`n")) 'Extracted-file verification failure leaves installed bytes and receipt unchanged'
RestoreFusion $mp
Check ((HashFile (Join-Path $game 'A.txt')) -eq $originalA -and (HashFile (Join-Path $game 'winmm.dll')) -eq $originalLoader -and (HashFile (Join-Path $game 'unrelated.txt')) -eq $unrelated) 'Restore after both verification failures recovers original user bytes and preserves unrelated files'
