function GetMenuSettings([string]$Game){
 $result=@{ShortcutKey=45;BackupShortcutKey=79;PresetHotSwapKey=0};$file=OwnedPath $Game 'OptiScaler.ini'
 if(Test-Path -LiteralPath $file){$section='';foreach($line in Get-Content -LiteralPath $file){if($line -match '^\s*\[([^]]+)\]'){$section=$Matches[1]}elseif($section -eq 'Menu' -and $line -match '^\s*(ShortcutKey|BackupShortcutKey|PresetHotSwapKey)\s*=\s*(-?\d+)\s*$'){$result[$Matches[1]]=[int]$Matches[2]}}}
 return $result
}
function SetMenuSettings([string]$Game,[int]$Primary,[int]$Backup,[int]$HotSwap=-2){
 AssertClosed $Game
 if($Primary -notin (@(33..40)+@(45,46)+@(48..57)+@(65..90)+@(96..111)+@(112..123)) -or $Backup -notin @(65..90)){throw 'Choose a supported primary key and a backup letter.'}
 if($Primary -eq $Backup){throw 'Use different primary and backup keys to avoid overlapping shortcuts.'}
 $file=OwnedPath $Game 'OptiScaler.ini';if(-not(Test-Path -LiteralPath $file)){throw 'Install OptiShade first.'}
 # These actions use the same input dispatcher; a duplicate would toggle both.
 $otherKeys=@{FpsShortcutKey=33;FpsCycleShortcutKey=34;FGShortcutKey=35;DlssNrToggleKey=-1};$section=''
 foreach($line in [IO.File]::ReadAllLines($file)){
  if($line -match '^\s*\[([^]]+)\]'){$section=$Matches[1]}
  elseif($section -eq 'DlssNr' -and $line -match '^\s*ToggleKey\s*=\s*(-?\d+)\s*$'){$otherKeys.DlssNrToggleKey=[int]$Matches[1]}
  elseif($section -eq 'Menu' -and $line -match '^\s*(FpsShortcutKey|FpsCycleShortcutKey|FGShortcutKey)\s*=\s*(-?\d+)\s*$'){$otherKeys[$Matches[1]]=[int]$Matches[2]}
 }
 foreach($key in $otherKeys.Keys){if($Primary -eq $otherKeys[$key]){throw "That key is already assigned to $key. Choose a different menu key."}}
 if($HotSwap -eq -2){$HotSwap=[int](GetMenuSettings $Game).PresetHotSwapKey}
 if($HotSwap -ne 0 -and $HotSwap -ne -1 -and $HotSwap -notin (@(33..40)+@(45,46)+@(48..57)+@(65..90)+@(96..111)+@(112..123))){throw 'Choose a supported hotswap key or clear it.'}
 if($HotSwap -gt 0 -and ($HotSwap -eq $Primary -or $HotSwap -in $otherKeys.Values)){throw 'The hotswap key conflicts with another OptiShade shortcut.'}
 $settings=@{ShortcutKey=$Primary;BackupShortcutKey=$Backup;PresetHotSwapKey=$HotSwap};$section='';$seen=@{};$lines=New-Object 'System.Collections.Generic.List[string]'
 foreach($line in [IO.File]::ReadAllLines($file)){
  if($line -match '^\s*\[([^]]+)\]'){
   if($section -eq 'Menu'){foreach($key in $settings.Keys){if(-not $seen[$key]){$lines.Add("$key=$($settings[$key])");$seen[$key]=$true}}}
   $section=$Matches[1]
  }
  if($section -eq 'Menu' -and $line -match '^\s*(ShortcutKey|BackupShortcutKey|PresetHotSwapKey)\s*='){$key=$Matches[1];if(-not $seen[$key]){$lines.Add("$key=$($settings[$key])");$seen[$key]=$true}}else{$lines.Add($line)}
 }
 if($seen.Count -eq 0 -and $section -ne 'Menu'){$lines.Add('[Menu]')}
 foreach($key in $settings.Keys){if(-not $seen[$key]){$lines.Add("$key=$($settings[$key])")}}
 $tmp=$file+'.keys-'+[guid]::NewGuid().ToString('N')
 try{[IO.File]::WriteAllLines($tmp,$lines,[Text.UTF8Encoding]::new($false));[IO.File]::Replace($tmp,$file,$tmp+'.backup');Remove-Item -LiteralPath ($tmp+'.backup')}finally{if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp}}
}
