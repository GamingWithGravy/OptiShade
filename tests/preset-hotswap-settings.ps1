$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/menu-settings.ps1"
function OwnedPath($game,$name){Join-Path $game $name}
function AssertClosed($game){}
$testDir=Join-Path $env:TEMP ('OptiShade-Hotswap-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testDir)
$file=Join-Path $testDir 'OptiScaler.ini'
try {
 [IO.File]::WriteAllText($file,"[Menu]`r`nShortcutKey=45`r`nBackupShortcutKey=79`r`n[DlssNr]`r`nToggleKey=118`r`n")
 if((GetMenuSettings $testDir).PresetHotSwapKey -ne 0){throw 'Must default to unassigned'}
 $before=[IO.File]::ReadAllText($file);$rejected=$false
 try{SetMenuSettings $testDir 45 79 118}catch{$rejected=$true}
 if(-not $rejected -or [IO.File]::ReadAllText($file) -ne $before){throw 'Neural rendering conflict must reject without changing file'}
 SetMenuSettings $testDir 45 79 119
 if((GetMenuSettings $testDir).PresetHotSwapKey -ne 119){throw 'Assigned key did not round trip'}
 SetMenuSettings $testDir 46 79
 if((GetMenuSettings $testDir).PresetHotSwapKey -ne 119){throw 'Menu-only change lost hotswap key'}
 SetMenuSettings $testDir 46 79 -1
 if((GetMenuSettings $testDir).PresetHotSwapKey -ne -1){throw 'In-game cleared key did not round trip'}
 SetMenuSettings $testDir 45 79 0
 if((GetMenuSettings $testDir).PresetHotSwapKey -ne 0){throw 'Reset did not clear hotswap'}
 if([IO.File]::ReadAllText($file) -notmatch 'ToggleKey=118'){throw 'Unrelated settings lost'}
 'PASS: defaults, persistence, clearing, conflict rejection, and unrelated settings preserved'
} finally {Remove-Item -LiteralPath $file -Force;[IO.Directory]::Delete($testDir)}
