function GetOptiShadeMenuRuntime([string]$Game){
 $storeValue=Get-Variable -Name store -Scope Script -ValueOnly -ErrorAction SilentlyContinue
 if($storeValue -and (Get-Command ManifestPath -ErrorAction SilentlyContinue) -and (Get-Command ReadOptiShadeState -ErrorAction SilentlyContinue)){
  $receiptPath=ManifestPath $storeValue $Game
  if(Test-Path -LiteralPath $receiptPath -PathType Leaf){$receipt=ReadOptiShadeState $receiptPath;if($receipt.Architecture -eq 'x86'){return 'ReShade32'};if($receipt.Architecture -eq 'x64'){return 'OptiScaler'}}
 }
 if(Test-Path -LiteralPath (OwnedPath $Game 'ReShade32.dll') -PathType Leaf){return 'ReShade32'}
 if(Test-Path -LiteralPath (OwnedPath $Game 'ReShade64.dll') -PathType Leaf){return 'OptiScaler'}
 return 'Unknown'
}
function GetReShadeOverlayKey([string]$Path){
 if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return 45}
 $section=''
 foreach($line in [IO.File]::ReadAllLines($Path)){
  if($line -match '^\s*\[([^]]+)\]'){$section=$Matches[1]}
  elseif($section -eq 'INPUT' -and $line -match '^\s*KeyOverlay\s*=\s*(-?\d+)'){
   $key=[int]$Matches[1]
   if($key -in (@(33..40)+@(44,45,46)+@(48..57)+@(65..90)+@(96..111)+@(112..123))){return $key}
   return 45
  }
 }
 return 45
}
function SetReShadeOverlayKey([string]$Path,[int]$Primary){
 if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw 'Install OptiShade first.'}
 $output=New-Object 'System.Collections.Generic.List[string]';$section='';$inputSeen=$false;$keyWritten=$false
 foreach($line in [IO.File]::ReadAllLines($Path)){
  if($line -match '^\s*\[([^]]+)\]'){
   if($section -eq 'INPUT' -and -not $keyWritten){$output.Add("KeyOverlay=$Primary,0,0,0");$keyWritten=$true}
   $section=$Matches[1];if($section -eq 'INPUT'){$inputSeen=$true}
  }
  if($section -eq 'INPUT' -and $line -match '^\s*KeyOverlay\s*='){
   if(-not $keyWritten){$output.Add("KeyOverlay=$Primary,0,0,0");$keyWritten=$true}
  }else{$output.Add($line)}
 }
 if($section -eq 'INPUT' -and -not $keyWritten){$output.Add("KeyOverlay=$Primary,0,0,0");$keyWritten=$true}
 if(-not $inputSeen){if($output.Count -and $output[$output.Count-1] -ne ''){$output.Add('')};$output.Add('[INPUT]');$output.Add("KeyOverlay=$Primary,0,0,0")}
 $tmp=$Path+'.keys-'+[guid]::NewGuid().ToString('N');$backup=$tmp+'.backup'
 try{[IO.File]::WriteAllLines($tmp,$output,[Text.UTF8Encoding]::new($false));[IO.File]::Replace($tmp,$Path,$backup);Remove-Item -LiteralPath $backup -Force}finally{if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force};if(Test-Path -LiteralPath $backup){Remove-Item -LiteralPath $backup -Force}}
}
function GetMenuSettings([string]$Game){
 $result=@{ShortcutKey=45;BackupShortcutKey=79;PresetHotSwapKey=0;SnapshotKey=0;DlssNrToggleKey=-1;MfgToggleKey=-1;MfgMultiplierUpKey=-1;MfgMultiplierDownKey=-1;SupportsOptiScalerShortcuts=$true;MenuRuntime='OptiScaler'}
 $runtime=GetOptiShadeMenuRuntime $Game
 if($runtime -eq 'ReShade32'){
  $reshadeIni=OwnedPath $Game 'ReShade.ini'
  if(Test-Path -LiteralPath $reshadeIni -PathType Leaf){$result.ShortcutKey=GetReShadeOverlayKey $reshadeIni}
  $result.BackupShortcutKey=0;$result.SupportsOptiScalerShortcuts=$false;$result.MenuRuntime='ReShade32'
  return $result
 }
 $optiscaler=OwnedPath $Game 'OptiScaler.ini'
 if(Test-Path -LiteralPath $optiscaler){$section='';foreach($line in Get-Content -LiteralPath $optiscaler){if($line -match '^\s*\[([^]]+)\]'){$section=$Matches[1]}elseif($section -eq 'Menu' -and $line -match '^\s*(ShortcutKey|BackupShortcutKey|PresetHotSwapKey|SnapshotKey|MfgToggleKey|MfgMultiplierUpKey|MfgMultiplierDownKey)\s*=\s*(-?\d+)\s*$'){$result[$Matches[1]]=[int]$Matches[2]}elseif($section -eq 'DlssNr' -and $line -match '^\s*ToggleKey\s*=\s*(-?\d+)\s*$'){$result.DlssNrToggleKey=[int]$Matches[1]}};return $result}
 $reshadeDll=OwnedPath $Game 'ReShade32.dll';$reshadeIni=OwnedPath $Game 'ReShade.ini'
 if((Test-Path -LiteralPath $reshadeDll -PathType Leaf) -and (Test-Path -LiteralPath $reshadeIni -PathType Leaf)){$result.ShortcutKey=GetReShadeOverlayKey $reshadeIni;$result.BackupShortcutKey=0;$result.SupportsOptiScalerShortcuts=$false;$result.MenuRuntime='ReShade32'}
 return $result
}
function SetMenuSettings([string]$Game,[int]$Primary,[int]$Backup,[int]$HotSwap=-2,[int]$Snapshot=-2,[hashtable]$Features=$null){
 AssertClosed $Game
 if($Primary -notin (@(33..40)+@(44,45,46)+@(48..57)+@(65..90)+@(96..111)+@(112..123))){throw 'Choose a supported primary key.'}
 $runtime=GetOptiShadeMenuRuntime $Game
 if($runtime -eq 'ReShade32'){
  $reshadeIni=OwnedPath $Game 'ReShade.ini'
  SetReShadeOverlayKey $reshadeIni $Primary
  return
 }
 $optiscaler=OwnedPath $Game 'OptiScaler.ini'
 if(-not(Test-Path -LiteralPath $optiscaler)){
  throw 'Install OptiShade first.'
 }
 if($Backup -notin @(65..90)){throw 'Choose a supported recovery shortcut letter.'}
 if($Primary -eq $Backup){throw 'Use different primary and backup keys to avoid overlapping shortcuts.'}
 # These actions use the same input dispatcher; a duplicate would toggle both.
 $otherKeys=@{FpsShortcutKey=33;FpsCycleShortcutKey=34;FGShortcutKey=35;DlssNrToggleKey=-1;MfgToggleKey=-1;MfgMultiplierUpKey=-1;MfgMultiplierDownKey=-1};$section=''
 foreach($line in [IO.File]::ReadAllLines($optiscaler)){
  if($line -match '^\s*\[([^]]+)\]'){$section=$Matches[1]}
  elseif($section -eq 'DlssNr' -and $line -match '^\s*ToggleKey\s*=\s*(-?\d+)\s*$'){$otherKeys.DlssNrToggleKey=[int]$Matches[1]}
  elseif($section -eq 'Menu' -and $line -match '^\s*(FpsShortcutKey|FpsCycleShortcutKey|FGShortcutKey|MfgToggleKey|MfgMultiplierUpKey|MfgMultiplierDownKey)\s*=\s*(-?\d+)\s*$'){$otherKeys[$Matches[1]]=[int]$Matches[2]}
 }
 if($Features){foreach($name in @('DlssNrToggleKey','MfgToggleKey','MfgMultiplierUpKey','MfgMultiplierDownKey')){if($Features.ContainsKey($name)){$otherKeys[$name]=[int]$Features[$name]}}}
 foreach($key in $otherKeys.Keys){if($Primary -eq $otherKeys[$key]){throw "That key is already assigned to $key. Choose a different menu key."}}
 if($HotSwap -eq -2){$HotSwap=[int](GetMenuSettings $Game).PresetHotSwapKey}
 if($HotSwap -ne 0 -and $HotSwap -ne -1 -and $HotSwap -notin (@(33..40)+@(44,45,46)+@(48..57)+@(65..90)+@(96..111)+@(112..123))){throw 'Choose a supported hotswap key or clear it.'}
 if($HotSwap -gt 0 -and ($HotSwap -eq $Primary -or $HotSwap -in $otherKeys.Values)){throw 'The hotswap key conflicts with another OptiShade shortcut.'}
 if($Snapshot -eq -2){$Snapshot=[int](GetMenuSettings $Game).SnapshotKey}
 if($Snapshot -lt -1 -or ($Snapshot -gt 0 -and ($Snapshot -notin (@(33..40)+@(44,45,46)+@(48..57)+@(65..90)+@(96..111)+@(112..123)) -or $Snapshot -eq $Primary -or $Snapshot -eq $HotSwap -or $Snapshot -in $otherKeys.Values))){throw 'Choose a supported SnapShot key that is not assigned to another OptiShade action.'}
 $features=@{DlssNrToggleKey=[int]$otherKeys.DlssNrToggleKey;MfgToggleKey=[int]$otherKeys.MfgToggleKey;MfgMultiplierUpKey=[int]$otherKeys.MfgMultiplierUpKey;MfgMultiplierDownKey=[int]$otherKeys.MfgMultiplierDownKey}
 if($Features){foreach($name in $features.Keys){if($Features.ContainsKey($name)){$features[$name]=[int]$Features[$name]}}}
 foreach($name in $features.Keys){$key=[int]$features[$name];if($key -ne -1 -and $key -notin (@(33..40)+@(44,45,46)+@(48..57)+@(65..90)+@(96..111)+@(112..123))){throw "Choose a supported key or clear $name."}}
 foreach($name in $features.Keys){$key=[int]$features[$name];if($key -le 0){continue};foreach($otherName in $otherKeys.Keys){if($otherName -ne $name -and $key -eq [int]$otherKeys[$otherName]){throw "Shortcut conflict: $name and $otherName use the same key."}}}
 $assigned=@{ShortcutKey=$Primary;BackupShortcutKey=$Backup;PresetHotSwapKey=$HotSwap;SnapshotKey=$Snapshot;DlssNrToggleKey=$features.DlssNrToggleKey;MfgToggleKey=$features.MfgToggleKey;MfgMultiplierUpKey=$features.MfgMultiplierUpKey;MfgMultiplierDownKey=$features.MfgMultiplierDownKey}
 $used=@{};foreach($name in $assigned.Keys){$key=[int]$assigned[$name];if($key -gt 0){if($used.ContainsKey($key)){throw "Shortcut conflict: $name and $($used[$key]) use the same key."};$used[$key]=$name}}
 $settingsBySection=@{Menu=[ordered]@{ShortcutKey=$Primary;BackupShortcutKey=$Backup;PresetHotSwapKey=$HotSwap;SnapshotKey=$Snapshot;MfgToggleKey=$features.MfgToggleKey;MfgMultiplierUpKey=$features.MfgMultiplierUpKey;MfgMultiplierDownKey=$features.MfgMultiplierDownKey};DlssNr=[ordered]@{ToggleKey=$features.DlssNrToggleKey}}
 $seen=@{Menu=@{};DlssNr=@{}};$section='';$lines=New-Object 'System.Collections.Generic.List[string]'
 foreach($line in [IO.File]::ReadAllLines($optiscaler)){
  if($line -match '^\s*\[([^]]+)\]'){
   if($settingsBySection.ContainsKey($section)){foreach($key in $settingsBySection[$section].Keys){if(-not $seen[$section].ContainsKey($key)){$lines.Add("$key=$($settingsBySection[$section][$key])");$seen[$section][$key]=$true}}}
   $section=$Matches[1];$lines.Add($line);continue
  }
  if($settingsBySection.ContainsKey($section) -and $line -match '^\s*([A-Za-z]+)\s*='){$key=$Matches[1];if($settingsBySection[$section].Contains($key)){if(-not $seen[$section].ContainsKey($key)){$lines.Add("$key=$($settingsBySection[$section][$key])");$seen[$section][$key]=$true};continue}}
  $lines.Add($line)
 }
 foreach($target in $settingsBySection.Keys){if(-not $seen[$target].Count){if($lines.Count -and $lines[$lines.Count-1] -ne ''){$lines.Add('')};$lines.Add("[$target]")};foreach($key in $settingsBySection[$target].Keys){if(-not $seen[$target].ContainsKey($key)){$lines.Add("$key=$($settingsBySection[$target][$key])");$seen[$target][$key]=$true}}}
 $tmp=$optiscaler+'.keys-'+[guid]::NewGuid().ToString('N')
 try{[IO.File]::WriteAllLines($tmp,$lines,[Text.UTF8Encoding]::new($false));[IO.File]::Replace($tmp,$optiscaler,$tmp+'.backup');Remove-Item -LiteralPath ($tmp+'.backup')}finally{if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp}}
}
function SetOptiShadeReShadePreset([string]$Game,[string]$PresetRelative){
 AssertClosed $Game
 $config=OwnedPath $Game 'ReShade.ini';$preset=OwnedPath $Game $PresetRelative
 if(-not(Test-Path -LiteralPath $config -PathType Leaf)){throw 'The game ReShade.ini is missing. Repair OptiShade before applying an imported look.'}
 if(-not(Test-Path -LiteralPath $preset -PathType Leaf)){throw 'The imported look is missing. Import it again before applying it.'}
 $presetValue='.\'+$PresetRelative.Replace('/','\')
 $values=[ordered]@{PresetPath=$presetValue;StartupPresetPath=''}
 $lines=[Collections.Generic.List[string]]::new([string[]][IO.File]::ReadAllLines($config))
 $output=[Collections.Generic.List[string]]::new();$section='';$generalSeen=$false;$written=@{}
 foreach($line in $lines){
  if($line -match '^\s*\[([^]]+)\]\s*$'){
   if($section -ieq 'GENERAL'){
    foreach($key in $values.Keys){if(-not $written.ContainsKey($key)){$output.Add($key+'='+$values[$key]);$written[$key]=$true}}
   }
   $section=$Matches[1];if($section -ieq 'GENERAL'){$generalSeen=$true}
   $output.Add($line);continue
  }
  if($section -ieq 'GENERAL' -and $line -match '^\s*(PresetPath|StartupPresetPath)\s*='){
   $key=$Matches[1];if(-not $written.ContainsKey($key)){$output.Add($key+'='+$values[$key]);$written[$key]=$true}
   continue
  }
  $output.Add($line)
 }
 if($section -ieq 'GENERAL'){
  foreach($key in $values.Keys){if(-not $written.ContainsKey($key)){$output.Add($key+'='+$values[$key]);$written[$key]=$true}}
 }elseif(-not $generalSeen){
  if($output.Count -and $output[$output.Count-1] -ne ''){$output.Add('')}
  $output.Add('[GENERAL]')
  foreach($key in $values.Keys){$output.Add($key+'='+$values[$key]);$written[$key]=$true}
 }
 $tmp=$config+'.preset-'+[guid]::NewGuid().ToString('N');$backup=$tmp+'.backup'
 try{
  [IO.File]::WriteAllLines($tmp,$output,[Text.UTF8Encoding]::new($false))
  [IO.File]::Replace($tmp,$config,$backup)
  Remove-Item -LiteralPath $backup -Force
 }finally{if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue};if(Test-Path -LiteralPath $backup){Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue}}
}
# Read-only validation for capture feedback; Save shortcuts validates again.
function GetActionKeyConflict([string]$Game,[int]$Code,[int]$Primary,[int]$OtherAction,[string]$Ignore=''){
 if($Code -le 0){return ''}
 if($Code -eq $Primary){return 'the menu'}
 if($Code -eq $OtherAction){return 'the other SnapShot or hotswap action'}
 $keys=@{FpsShortcutKey=33;FpsCycleShortcutKey=34;FGShortcutKey=35;DlssNrToggleKey=-1;MfgToggleKey=-1;MfgMultiplierUpKey=-1;MfgMultiplierDownKey=-1}
 if(-not [string]::IsNullOrWhiteSpace($Game)){
  $file=OwnedPath $Game 'OptiScaler.ini'
  if(Test-Path -LiteralPath $file){$section='';foreach($line in [IO.File]::ReadAllLines($file)){
   if($line -match '^\s*\[([^]]+)\]'){$section=$Matches[1]}
   elseif($section -eq 'Menu' -and $line -match '^\s*(FpsShortcutKey|FpsCycleShortcutKey|FGShortcutKey|MfgToggleKey|MfgMultiplierUpKey|MfgMultiplierDownKey)\s*=\s*(-?\d+)\s*$'){$keys[$Matches[1]]=[int]$Matches[2]}
   elseif($section -eq 'DlssNr' -and $line -match '^\s*ToggleKey\s*=\s*(-?\d+)\s*$'){$keys.DlssNrToggleKey=[int]$Matches[1]}
  }}
 }
 foreach($name in $keys.Keys){if($name -ne $Ignore -and $Code -eq $keys[$name]){return $name}}
 return ''
}
