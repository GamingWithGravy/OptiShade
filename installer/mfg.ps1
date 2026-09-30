# Optional upstream RTXMFG integration. Upstream code retains its MIT licence.
function EnsureAutomaticMfg([string]$ManifestPath,[string]$Payload,[string[]]$GpuNames){
 $m=Get-Content -LiteralPath $ManifestPath -Raw|ConvertFrom-Json
 if(-not(Test-Path -LiteralPath (Join-Path $m.Game 'FlightSimulator.exe')) -and -not(Test-Path -LiteralPath (Join-Path $m.Game 'FlightSimulator2024.exe'))){return 'Not a supported simulator'}
 $nvidia=@($GpuNames|Where-Object {$_ -match '(?i)NVIDIA|\bRTX\b|\bGTX\b'}|Select-Object -Unique)
 # Only this adapter family has a pinned, licensed integration in this build.
 if($nvidia.Count -ne 1 -or $nvidia[0] -notmatch '\bRTX\s*40\d{2}\b'){return 'No automatic component for this GPU configuration'}
 try{InstallOptionalMfg $ManifestPath $Payload $GpuNames;$message='RTX 40 MFG installed automatically. Enable native DLSS Frame Generation in game; Backspace opens the MFG menu. Supported multipliers vary.'}
 catch{$message='Automatic RTX 40 MFG was not installed: '+$_.Exception.Message}
 $m=Get-Content -LiteralPath $ManifestPath -Raw|ConvertFrom-Json
 $m|Add-Member AutomaticMfgStatus $message -Force;WriteState $m $ManifestPath
 return $message
}
function SetMfgIniValue([string]$Text,[string]$Section,[string]$Key,[string]$Value){
 $lines=[Collections.Generic.List[string]]::new();$active=$false;$found=$false;$sectionFound=$false
 foreach($line in ($Text -split '\r?\n')){
  if($line -match '^\s*\[([^]]+)\]'){
   if($active -and -not $found){$lines.Add("$Key=$Value");$found=$true}
   $active=$Matches[1] -eq $Section;if($active){$sectionFound=$true}
  }
  if($active -and $line -match ('^\s*'+[regex]::Escape($Key)+'\s*=')){if(-not $found){$lines.Add("$Key=$Value");$found=$true}}else{$lines.Add($line)}
 }
 if(-not $sectionFound){$lines.Add("[$Section]")}
 if(-not $found){$lines.Add("$Key=$Value")}
 return $lines -join "`r`n"
}
function InstallOptionalMfg([string]$ManifestPath,[string]$Payload,[string[]]$GpuNames){
 if(-not ($GpuNames -match '\bRTX\s*40\d{2}\b')){throw 'This optional MFG setup is limited to RTX 40 GPUs. Other series are not validated.'}
 $original=Get-Content -LiteralPath $ManifestPath -Raw;$m=$original|ConvertFrom-Json
 if($m.Status -ne 'Installed'){throw 'Install OptiShade first.'}
 AssertClosed $m.Game
 $source=OwnedPath $Payload 'OptiShadeData/MFG/RTXMFG.dll'
 $expected='E9CA3587854EEB723E0579F7DDF6CFB1E6CF4BED79B0D75BC716003ED98FE040'
 if((HashFile $source) -ne $expected){throw 'Optional MFG payload verification failed.'}
 # Never overwrite another loader, including an OptiShade installation using version.dll.
 $dest=OwnedPath $m.Game 'version.dll'
 $repairMissing=$false
 if($m.PSObject.Properties['OptionalMfg'] -and $m.OptionalMfg){
  $records=@($m.Files|Where-Object Path -eq 'version.dll')
  if($records.Count -ne 1 -or $records[0].Hash -ne $expected -or $records[0].Mutable){throw 'Optional MFG ownership requires review. The current loader and backups were left untouched.'}
  if($records[0].Backup -and (HashFile (OwnedPath (Split-Path $ManifestPath) $records[0].Backup)) -ne $records[0].PreviousHash){throw 'Optional MFG original backup failed verification. No files were changed.'}
  $current=HashFile $dest
  # A repeat click is a verified no-op. Preserve the user's later FG choices.
  if($current -eq $expected){return}
  if($current){throw 'Optional MFG version.dll changed after installation. Review the conflict before reinstalling; no files were changed.'}
  # A missing owned file can be safely repaired from the same pinned payload.
  $repairMissing=$true
 }
 if(Test-Path -LiteralPath $dest){throw 'version.dll is already occupied. Optional MFG was not installed; no existing loader was replaced.'}
 foreach($name in @('RTX40MFGCore.dll','RTX40MFG.asi','RTX40MFG-UI.addon64','RTXMFG.dll','dlss-enabler-headless.dll')){
  if((Test-Path -LiteralPath (OwnedPath $m.Game $name)) -or (Test-Path -LiteralPath (OwnedPath $m.Game ('OptiShadeData/Engine/'+$name)))){throw 'Another MFG component is present. Remove it using its own instructions before enabling optional MFG.'}
 }
 $ini=OwnedPath $m.Game 'OptiScaler.ini';$before=[IO.File]::ReadAllBytes($ini)
 $text=[IO.File]::ReadAllText($ini)
 if(-not $repairMissing){
  $text=SetMfgIniValue $text 'FrameGen' 'External' 'true'
  $text=SetMfgIniValue $text 'DLSSG' 'AdaMfgUnlock' 'false'
  $text=SetMfgIniValue $text 'DLSSG' 'AmpereMfgUnlock' 'false'
 }
 $temp=$dest+'.optishade-staging'
 if(Test-Path -LiteralPath $temp){throw 'An MFG staging file already exists. No files were changed.'}
 $installed=$false
 try{
  [IO.File]::Copy($source,$temp,$false)
  if((HashFile $temp) -ne $expected){throw 'MFG copy verification failed.'}
  [IO.File]::Move($temp,$dest);$installed=$true
  if(-not $repairMissing){[IO.File]::WriteAllText($ini,$text,[Text.UTF8Encoding]::new($false))}
  # Reuse a displaced loader's ownership record so its original backup survives.
  $previous=@($m.Files|Where-Object Path -eq 'version.dll')
  if($previous.Count -gt 1){throw 'Conflicting version.dll ownership records require recovery before enabling MFG.'}
  $backup='';$previousHash=''
  if($previous.Count){$backup=$previous[0].Backup;$previousHash=$previous[0].PreviousHash}
  $m.Files=@($m.Files|Where-Object Path -ne 'version.dll')+[pscustomobject]@{Path='version.dll';SourcePath='';Hash=$expected;PreviousHash=$previousHash;Backup=$backup;Mutable=$false;Retained=$true}
  $m|Add-Member OptionalMfg $true -Force
  $m|Add-Member OptionalMfgVersion 'v1.3.3-hotfix.2' -Force
  WriteState $m $ManifestPath
 }catch{
  [IO.File]::WriteAllBytes($ini,$before)
  if($installed -and (HashFile $dest) -eq $expected){Remove-Item -LiteralPath $dest -Force}
  [IO.File]::WriteAllText($ManifestPath,$original,[Text.UTF8Encoding]::new($true))
  throw
 }finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}}
}
