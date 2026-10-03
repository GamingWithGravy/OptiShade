# Optional upstream RTXMFG integration. Upstream code retains its MIT licence.
function EnsureAutomaticMfg([string]$ManifestPath,[string]$Payload,[string[]]$GpuNames){
 $m=ReadOptiShadeState $ManifestPath
 if(-not(Test-Path -LiteralPath (Join-Path $m.Game 'FlightSimulator.exe')) -and -not(Test-Path -LiteralPath (Join-Path $m.Game 'FlightSimulator2024.exe'))){return 'Not a supported simulator'}
 if($m.SourceMfg -and (Test-Path (Join-Path $Payload 'OptiShadeData/MFG/source-build.json'))){
  try{InstallSourceMfg $ManifestPath $Payload $GpuNames;return 'Source-built MFG prepared; use the OptiShade Performance panel.'}
  catch{$m|Add-Member AutomaticMfgStatus ('Source MFG not activated: '+$_.Exception.Message) -Force;WriteState $m $ManifestPath;return $m.AutomaticMfgStatus}
 }
 $nvidia=@($GpuNames|Where-Object {$_ -match '(?i)NVIDIA|\bRTX\b|\bGTX\b'}|Select-Object -Unique)
 # Only this adapter family has a pinned, licensed integration in this build.
 if($nvidia.Count -ne 1 -or $nvidia[0] -notmatch '\bRTX\s*40\d{2}\b'){return 'No automatic component for this GPU configuration'}
 try{InstallOptionalMfg $ManifestPath $Payload $GpuNames;$message='MFG component installed. Enable native DLSS Frame Generation in game and use Performance > Multi Frame Generation in OptiShade. Actual GPU/provider capabilities are checked at runtime.'}
 catch{$message='Automatic RTX 40 MFG was not installed: '+$_.Exception.Message}
 $m=ReadOptiShadeState $ManifestPath
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
 $existing=ReadOptiShadeState $ManifestPath
 if($existing.SourceMfg){InstallSourceMfg $ManifestPath $Payload $GpuNames;return}
 # Stable retains the established RTX40 provider. Existing source receipts
 # are repaired through EnsureAutomaticMfg, never migrated by a normal click.
 if(-not ($GpuNames -match '\bRTX\s*40\d{2}\b')){throw 'This optional MFG setup is limited to RTX 40 GPUs. Other series are not validated.'}
 $original=Get-Content -LiteralPath $ManifestPath -Raw;$m=ReadOptiShadeState $ManifestPath
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

$script:SourceMfgSha256="b61093ea83ecfa19ba4a041093a20d6f213c531e33a9c27af193b2321d1cac02"
function InstallSourceMfg([string]$ManifestPath,[string]$Payload,[string[]]$GpuNames){
 $m=ReadOptiShadeState $ManifestPath
 if(-not $m.SourceMfg){throw 'New source MFG activation is held for beta target testing. Stable preserves the existing provider.'}
 if($m.Status -ne 'Installed'){throw 'Install OptiShade first.'}
 AssertClosed $m.Game
 if(-not(Test-Path (Join-Path $m.Game 'FlightSimulator.exe')) -and -not(Test-Path (Join-Path $m.Game 'FlightSimulator2024.exe'))){throw 'Source MFG requires a supported native DLSS frame-generation game connection. X-Plane is not enabled by this component.'}
 $cards=@($GpuNames -split ',\s*'|Where-Object {$_ -match '\bRTX\b'}|Select-Object -Unique)
 if($m.NeuralGpuName){$cards=@($cards|Where-Object {$_ -ceq $m.NeuralGpuName})}
 if($cards.Count -ne 1 -or $cards[0] -notmatch '\bRTX\s*([234])0\d{2}\b'){throw 'Choose the actual RTX 20/30/40 game GPU first. RTX 50 and other GPUs retain their native provider.'}
 $family=[int]$Matches[1]*10
 $metadata=ReadOptiShadeJson (Join-Path $Payload 'OptiShadeData/MFG/source-build.json') 'Source MFG build manifest'
 $source=OwnedPath $Payload 'OptiShadeData/MFG/OptiShadeMFG.dll'
 if($metadata.abi -ne 131072 -or $metadata.sha256 -cne $script:SourceMfgSha256 -or (HashFile $source).ToLowerInvariant() -cne $script:SourceMfgSha256 -or $family -notin @($metadata.families)){throw 'Source MFG build identity/capability manifest mismatch.'}
 foreach($name in @('RTXMFG.dll','RTX40MFGCore.dll','RTX40MFG.asi','RTX40MFG-UI.addon64','dlss-enabler-headless.dll')){
  if(Test-Path -LiteralPath (OwnedPath $m.Game $name)){throw "Another provider file requires review: $name. Nothing was changed."}
 }
 $legacy=OwnedPath $m.Game 'version.dll';$legacyHash=HashFile $legacy
 if($legacyHash){
  $owned=@($m.Files|Where-Object Path -eq 'version.dll')
  if(-not $m.OptionalMfg -or $owned.Count -ne 1 -or $owned[0].Hash -ne $legacyHash -or $legacyHash -ne 'E9CA3587854EEB723E0579F7DDF6CFB1E6CF4BED79B0D75BC716003ED98FE040'){throw 'Existing version.dll is not the recorded legacy MFG backend. Review it in Setup; nothing was changed.'}
 }
 $folder=Split-Path $ManifestPath;$rollback=OwnedPath $folder ('MfgRollback/'+[guid]::NewGuid().ToString('N'))
 [void][IO.Directory]::CreateDirectory($rollback)
 $old=[IO.File]::ReadAllBytes($ManifestPath);[IO.File]::WriteAllBytes((Join-Path $rollback 'manifest.json'),$old)
 $paths=@('version.dll','OptiScaler.ini','OptiShadeData/MFG/OptiShadeMFG.dll','OptiShadeData/MFG/source-backend.json')
 $snapshots=@();foreach($relative in $paths){$dest=OwnedPath $m.Game $relative;$hash=HashFile $dest;$copy=Join-Path $rollback ([string]$snapshots.Count);if($hash){Copy-Item -LiteralPath $dest -Destination $copy;if((HashFile $copy) -ne $hash){throw 'MFG recovery snapshot verification failed.'}};$snapshots+=@{Path=$relative;Hash=$hash;Copy=$copy}}
 WriteState @{Files=$snapshots;Game=$m.Game} (Join-Path $rollback 'rollback.json')
 try{
  $dest=OwnedPath $m.Game 'OptiShadeData/MFG/OptiShadeMFG.dll';[void][IO.Directory]::CreateDirectory((Split-Path $dest));Copy-Item -LiteralPath $source -Destination $dest -Force
  if((HashFile $dest).ToLowerInvariant() -cne $script:SourceMfgSha256){throw 'Source MFG installed-file verification failed.'}
  $ini=OwnedPath $m.Game 'OptiScaler.ini';$text=[IO.File]::ReadAllText($ini)
  $text=SetMfgIniValue $text 'FrameGen' 'External' 'true';$text=SetMfgIniValue $text 'DLSSG' 'AdaMfgUnlock' 'false';$text=SetMfgIniValue $text 'DLSSG' 'AmpereMfgUnlock' 'false'
  [IO.File]::WriteAllText($ini,$text,[Text.UTF8Encoding]::new($false))
  if($legacyHash){if((HashFile $legacy) -ne $legacyHash){throw 'Legacy provider changed during migration'};Remove-Item -LiteralPath $legacy}
  $activation=OwnedPath $m.Game 'OptiShadeData/MFG/source-backend.json'
  WriteState @{schema=1;abi=131072;sha256=$script:SourceMfgSha256;selectedGpu=$cards[0];family=$family;status='Installed; awaiting actual rendering device and game connection'} $activation
  foreach($relative in @('OptiShadeData/MFG/OptiShadeMFG.dll','OptiShadeData/MFG/source-backend.json')){
   $existing=@($m.Files|Where-Object {$_.Path.Replace('\','/') -eq $relative});$backup='';$previous='';$recordPath=$relative;if($existing.Count){$backup=$existing[0].Backup;$previous=$existing[0].PreviousHash;$recordPath=$existing[0].Path}
   $chains=@($existing|ForEach-Object {([string]$_.Backup)+'|'+([string]$_.PreviousHash)+'|'+([string]$_.Hash)}|Select-Object -Unique);if($chains.Count -gt 1){throw 'Conflicting source MFG original ownership records require recovery.'}
   $m.Files=@($m.Files|Where-Object {$_.Path.Replace('\','/') -ne $relative})+[pscustomobject]@{Path=$recordPath;SourcePath=$(if($relative -like '*.dll'){$relative}else{''});Hash=(HashFile (OwnedPath $m.Game $relative));PreviousHash=$previous;Backup=$backup;Mutable=$false;Retained=$true}
  }
  foreach($entry in @($m.Files|Where-Object Path -eq 'version.dll')){$entry.Hash='';$entry.SourcePath='';$entry.Retained=$true}
  $m|Add-Member OptionalMfg $false -Force;$m|Add-Member SourceMfg $true -Force;$m|Add-Member SourceMfgRollback $rollback -Force
  $m|Add-Member AutomaticMfgStatus 'Source-built MFG installed. Use Performance > Multi Frame Generation in OptiShade. Hardware output still requires target testing.' -Force
  WriteState $m $ManifestPath
 }catch{
  $failure=$_
  foreach($snapshot in $snapshots){$dest=OwnedPath $m.Game $snapshot.Path;if($snapshot.Hash){Copy-Item -LiteralPath $snapshot.Copy -Destination $dest -Force}else{if(Test-Path -LiteralPath $dest){Remove-Item -LiteralPath $dest}}}
  [IO.File]::WriteAllBytes($ManifestPath,$old);throw $failure
 }
}
