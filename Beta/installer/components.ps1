. "$PSScriptRoot/anti-cheat.ps1"
. "$PSScriptRoot/component-policy.ps1"
. "$PSScriptRoot/glass-cockpit-update.ps1"
. "$PSScriptRoot/optimfg-headless.ps1"
function GetNeuralAddonCardState([bool]$Ready,[bool]$Selected,[string]$RuntimeState){
 if(-not $Ready){return [pscustomobject]@{Text='Install core first';Foreground='#A99ABF';Action='Install';Available=$false}}
 if(-not $Selected){return [pscustomobject]@{Text='Not installed';Foreground='#A99ABF';Action='Install';Available=$true}}
 switch($RuntimeState){
  'Verified file' {return [pscustomobject]@{Text='Model verified - game test required';Foreground='#55DCA5';Action='Repair / update';Available=$true}}
  'Missing' {return [pscustomobject]@{Text='Model missing - NR cannot run';Foreground='#FFBE83';Action='Install model';Available=$true}}
  'Alternate location' {return [pscustomobject]@{Text='Model needs validation and placement';Foreground='#FFBE83';Action='Install model';Available=$true}}
  'Waiting for rendering adapter' {return [pscustomobject]@{Text='Start the game once to detect its rendering adapter';Foreground='#FFBE83';Action='Start game';Available=$true}}
  'GPU selection required' {return [pscustomobject]@{Text='Choose the game GPU in Advanced options';Foreground='#FFBE83';Action='Choose game GPU';Available=$false}}
  'Unsupported on this hardware' {return [pscustomobject]@{Text='Neural Rendering unavailable on detected hardware';Foreground='#A99ABF';Action='Repair / update';Available=$false}}
  'Incompatible' {return [pscustomobject]@{Text='Model does not match this GPU';Foreground='#FFBE83';Action='Repair / update';Available=$true}}
  'Signature failed' {return [pscustomobject]@{Text='NVIDIA model signature check failed';Foreground='#FFBE83';Action='Repair / update';Available=$true}}
  'Unverified' {return [pscustomobject]@{Text='Model file is not verified';Foreground='#FFBE83';Action='Repair / update';Available=$true}}
  'Unreadable' {return [pscustomobject]@{Text='Model file could not be checked';Foreground='#FFBE83';Action='Repair / update';Available=$true}}
  default {return [pscustomobject]@{Text='Runtime status unavailable';Foreground='#A99ABF';Action='Repair / update';Available=$true}}
 }
}
function GetAddonInventory([string]$Game,[string]$Id){
 # Cockpit owns one root-level addon, not the effect library. Keep path/link checks.
 if($Id -eq 'Cockpit'){
  $cockpitRelative='glass-cockpit-dlss-fix.addon64'
  if(Test-Path -LiteralPath (OwnedPath $Game $cockpitRelative) -PathType Leaf){return @($cockpitRelative)}
  return @()
 }
 # Refuse linked data before descending. Never traverse outside the selected game.
 $result=@()
 $roots=@('OptiShadeData','OptiScaler/nvfp4','host64')
 foreach($root in $roots){
  $base=OwnedPath $Game $root;if(-not(Test-Path -LiteralPath $base)){continue}
  $queue=[Collections.Generic.Queue[string]]::new();$queue.Enqueue($base)
  while($queue.Count){foreach($file in Get-ChildItem -LiteralPath $queue.Dequeue() -Force){
   $relative=$file.FullName.Substring((FullPath $Game).Length+1)
   $null=OwnedPath $Game $relative
    if($file.PSIsContainer){$queue.Enqueue($file.FullName)}elseif($file.Extension -ine '.log' -and (GetOptiShadeAddonId $relative) -eq $Id){$result+=$relative}
  }}
 }
 foreach($relative in @('glass-cockpit-dlss-fix.addon64','nvngx_dlssnr.dll','OptiShadeLegacyNR.addon32','RTXMFG-Universal.json')){if((GetOptiShadeAddonId $relative) -eq $Id -and (Test-Path -LiteralPath (OwnedPath $Game $relative))){$result+=$relative}}
 if($Id -eq 'OptiMfg' -and (Test-OptiMfgBackendMarker $Game)){
  foreach($relative in ((GetOptiMfgBackendPaths)+@('RTX40MFG-UI.ini'))){if(Test-Path -LiteralPath (OwnedPath $Game $relative) -PathType Leaf){$result+=$relative}}
 }
 return @($result|Select-Object -Unique)
}
function Test-OptiMfgBackendMarker([string]$Game){
 $expected='E6B6E6B70A6ED3AF839C9647A32FC22660AE6B2D655062C5C072246C91FC10C7'
 try{
  $marker=ReadOptiShadeJson (OwnedPath $Game 'OptiMFGTest-backend.json') 'OptiMFG backend marker' -Shape Object -MaxBytes 16384
  if($marker.providerVersion -ceq '1.2.2-optimfg.1' -and $marker.proxy -ceq 'version.dll' -and $marker.externalUiOnly){
   $hashes=GetOptiMfgHeadlessHashes
   foreach($name in $hashes.Keys){if((HashFile (OwnedPath $Game $name)) -cne $hashes[$name]){return $false}}
   return $true
  }
  return ([string]$marker.provider -ceq 'MFG Unlocker'  -and [string]$marker.providerVersion -ceq '1.7.0' -and [string]$marker.proxy -ceq 'version.dll' -and [string]$marker.sha256 -ceq $expected -and (HashFile (OwnedPath $Game 'version.dll')) -ceq $expected)
 }catch{return $false}
}
function GetLegacyNrPresetTarget([string]$Game){
 $base=FullPath $Game;$config=OwnedPath $Game 'ReShade.ini';$preset='OptiShadeData/Presets/My look.ini'
 if(Test-Path -LiteralPath $config -PathType Leaf){
  $section=''
  foreach($line in [IO.File]::ReadAllLines($config)){
   if($line -match '^\s*\[([^]]+)\]\s*$'){$section=$Matches[1];continue}
   if($section -eq 'GENERAL' -and $line -match '^\s*PresetPath\s*=\s*(.*?)\s*$'){$preset=$Matches[1].Trim().Trim('"');break}
  }
 }
 if([string]::IsNullOrWhiteSpace($preset)){return [pscustomobject]@{Relative='';Path='';Available=$false;Reason='No active ReShade preset was found.'}}
 try{
  $candidate=if([IO.Path]::IsPathRooted($preset)){[IO.Path]::GetFullPath($preset)}else{[IO.Path]::GetFullPath((Join-Path $base $preset))}
  $prefix=$base.TrimEnd('\')+'\'
  if(-not $candidate.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){return [pscustomobject]@{Relative='';Path='';Available=$false;Reason='The active preset is outside the game folder; enable the Legacy NR feed effect manually.'}}
  $relative=$candidate.Substring($prefix.Length).Replace('\','/')
  $safe=OwnedPath $Game $relative
  if([IO.Path]::GetExtension($safe) -ine '.ini' -or -not(Test-Path -LiteralPath $safe -PathType Leaf)){return [pscustomobject]@{Relative='';Path='';Available=$false;Reason='The active ReShade preset is unavailable; enable the Legacy NR feed effect manually.'}}
  if((Get-Item -LiteralPath $safe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){return [pscustomobject]@{Relative='';Path='';Available=$false;Reason='The active ReShade preset is linked; enable the Legacy NR feed effect manually.'}}
  return [pscustomobject]@{Relative=$relative;Path=$safe;Available=$true;Reason=''}
 }catch{return [pscustomobject]@{Relative='';Path='';Available=$false;Reason='The active ReShade preset could not be safely resolved; enable the Legacy NR feed effect manually.'}}
}
function SetLegacyNrPresetTechnique([string]$PresetPath,[bool]$Enable){
 if(-not(Test-Path -LiteralPath $PresetPath -PathType Leaf)){return $false}
 $technique='DLSS5_Feed@DLSS5_Feed.fx';$bytes=[IO.File]::ReadAllBytes($PresetPath);$encoding=[Text.UTF8Encoding]::new($false)
 if($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF){$encoding=[Text.UTF8Encoding]::new($true)}
 elseif($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE){$encoding=[Text.Encoding]::Unicode}
 elseif($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF){$encoding=[Text.Encoding]::BigEndianUnicode}
 $text=$encoding.GetString($bytes)
 if($text.Length -and $text[0] -eq [char]0xFEFF){$text=$text.Substring(1)}
 $newline=if($text.Contains("`r`n")){"`r`n"}else{"`n"}
 $lines=[Collections.Generic.List[string]]::new();foreach($line in ($text -split "`r?`n")){$lines.Add($line)}
 if($text.EndsWith("`n")){$lines.RemoveAt($lines.Count-1)}
 $section='';$foundTechniques=$false;$foundSorting=$false;$changed=$false
 for($i=0;$i -lt $lines.Count;$i++){
  if($lines[$i] -match '^\s*\[([^]]+)\]\s*$'){$section=$Matches[1];continue}
  if($section -eq '' -and $lines[$i] -match '^\s*(Techniques|TechniqueSorting)\s*=(.*)$'){
   $key=$Matches[1];$value=$Matches[2];$foundTechniques=$foundTechniques -or $key -eq 'Techniques';$foundSorting=$foundSorting -or $key -eq 'TechniqueSorting'
   $parts=@($value -split ',');$hasTechnique=@($parts|Where-Object {$_.Trim() -eq $technique}).Count -gt 0
   if($Enable -and -not $hasTechnique){$lines[$i]=$key+'='+$value.TrimEnd()+$(if($value.Trim()){','})+$technique ;$changed=$true}
   elseif(-not $Enable -and $hasTechnique){$remaining=@($parts|Where-Object {$_.Trim() -ne $technique});$lines[$i]=$key+'='+($remaining -join ',');$changed=$true}
  }
 }
 if($Enable){if(-not $foundTechniques){$lines.Insert(0,'Techniques='+$technique);$changed=$true};if(-not $foundSorting){$lines.Insert(0,'TechniqueSorting='+$technique);$changed=$true}}
 elseif(-not $changed){return $true}
 if(-not $changed){return $true}
 $tmp=$PresetPath+'.nr-'+[guid]::NewGuid().ToString('N')
 try{[IO.File]::WriteAllText($tmp,($lines -join $newline)+$newline,$encoding);[IO.File]::Replace($tmp,$PresetPath,$tmp+'.backup');Remove-Item -LiteralPath ($tmp+'.backup') -Force;return $true}
 finally{if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue};if(Test-Path -LiteralPath ($tmp+'.backup')){Remove-Item -LiteralPath ($tmp+'.backup') -Force -ErrorAction SilentlyContinue}}
}
function InvokeAddonTransaction([string]$ManifestPath,[string]$Id,[scriptblock]$Mutation,[bool]$Adopt=$true,[scriptblock]$Progress=$null){
 $storeMutation=EnterOptiShadeMutation -ManifestPath $ManifestPath
 try{
 [void](RecoverOptiShadeRouteTransaction $ManifestPath)
 $m=ReadOptiShadeState $ManifestPath;if($m.Status -ne 'Installed'){throw 'Install the OptiShade core first.'};AssertClosed $m.Game
 if($m.Architecture -eq 'x86' -and $Id -notin @('Effects','Neural')){throw '32-bit games support Image Effects and the experimental Legacy NR bridge only. Frame generation, FSR / XeSS providers and Glass Cockpit require a 64-bit game.'}
 if($Adopt){AssertAntiCheatMutation $m.Game $m.LaunchExe ('Install component '+$Id)}
 $prior=[IO.File]::ReadAllBytes($ManifestPath);$folder=Split-Path $ManifestPath
 $tx='AddonBackups/'+[guid]::NewGuid().ToString('N');$recovery=OwnedPath $folder $tx
 [void][IO.Directory]::CreateDirectory($recovery)
 $before=@{}; $paths=@(GetAddonInventory $m.Game $Id)+@('OptiScaler.ini')
 if($Id -eq 'OptiMfg'){$paths+=((GetOptiMfgBackendPaths)+@('RTXMFG-Universal.json','RTX40MFG-UI.ini'))}
 # Applying an imported look changes ReShade's startup preset pointer. Keep it
 # in the component transaction so a failed FX install restores the prior look.
 if($Id -eq 'Effects'){$paths+='ReShade.ini'}
  if($Id -eq 'Neural' -and $m.Architecture -eq 'x86'){
   $paths+=@('host64/nvngx_dlss.dll','host64/nvngx_dlssnr.dll','host64/OptiScaler.ini','host64/ReShade.ini')
   if($m.PSObject.Properties['LegacyNrPresetRelative'] -and $m.LegacyNrPresetRelative){$paths+=([string]$m.LegacyNrPresetRelative)}
   $active=GetLegacyNrPresetTarget $m.Game;if($active.Available){$paths+=([string]$active.Relative)}
  }
 if($Id -eq 'Mfg' -and $m.OptionalMfg){$paths+=GetOptiShadeMfgLoaderName $m}
 # Inventory uses Windows separators; explicitly added dependencies use '/'.
 # Canonicalise BEFORE deduplication or duplicate keys reuse backup slots.
 $uniquePaths=@($paths|ForEach-Object {$_.Replace('\','/')}|Sort-Object -Unique);$pathIndex=0
 foreach($relative in $uniquePaths){
  if($Progress){& $Progress ('Checking and backing up '+$relative) $pathIndex $uniquePaths.Count}
  $dest=OwnedPath $m.Game $relative;$hash=HashFile $dest;$backup=$tx+'/'+[guid]::NewGuid().ToString('N')
  $owned=@($m.Files|Where-Object {$_.Path.Replace('\','/') -eq $relative.Replace('\','/')})
  $verifiedCockpitLegacy=$false
  if($Id -eq 'Cockpit' -and $relative.Replace('\\','/') -ieq 'glass-cockpit-dlss-fix.addon64' -and (Get-Command TestGlassCockpitLegacyOwnership -ErrorAction SilentlyContinue)){
   $verifiedCockpitLegacy=TestGlassCockpitLegacyOwnership $owned $dest
  }
  $knownRetainedOriginal=$owned.Count -eq 1 -and (TestOptiShadeKnownRetainedOriginal $owned[0] $hash)
  if($Id -ne 'Effects' -and (GetOptiShadeAddonId $relative) -eq $Id -and $hash -and $owned.Count -eq 1 -and -not (TestOptiShadeMutableFile $relative) -and $owned[0].Hash -ne $hash -and -not $verifiedCockpitLegacy -and -not $knownRetainedOriginal){throw "Changed component file requires review: $relative"}
  if($hash){Copy-Item -LiteralPath $dest -Destination (OwnedPath $folder $backup);if((HashFile (OwnedPath $folder $backup)) -ne $hash){throw 'Component recovery copy failed verification.'}}
  $before[$relative.Replace('\','/')]=@{Path=$relative;Hash=$hash;Backup=$backup}
  $pathIndex++
 }
 [IO.File]::WriteAllBytes((Join-Path $recovery 'manifest.json'),$prior)
 try{
  & $Mutation
  $latest=ReadOptiShadeState $ManifestPath
  $after=@(GetAddonInventory $m.Game $Id)
  foreach($relative in $(if($Adopt){$after}else{@()})){
   $key=$relative.Replace('\','/');$hash=HashFile (OwnedPath $m.Game $relative)
   $old=$before[$key];$entries=@($latest.Files|Where-Object {$_.Path.Replace('\','/') -eq $key})
   $adoptUnchangedCockpit=$Id -eq 'Cockpit' -and $key -ieq 'glass-cockpit-dlss-fix.addon64' -and (TestGlassCockpitLegacyOwnership $entries (OwnedPath $m.Game $relative))
   if($entries.Count -gt 1){throw "Ambiguous ownership for $relative"}
   if($entries.Count){
    # NVIDIA-versions.json is rewritten by OptiShade's own runtime updater.
    if(TestOptiShadeMutableGeneratedMetadata $relative){$entries[0].Mutable=$true}    # A component mutation may record a newly adopted replacement itself.    # Preserve the pre-transaction bytes captured above so uninstall can    # restore an explicitly consented third-party loader exactly.    $ownedBefore=@($m.Files|Where-Object {$_.Path.Replace('\','/') -eq $key})    if($ownedBefore.Count -eq 0 -and $old -and $old.Hash -and -not $entries[0].PreviousHash -and -not $entries[0].Backup){$entries[0].PreviousHash=$old.Hash;$entries[0].Backup=$old.Backup}
    # Existing user presets/edits are not adopted merely because they sit in this folder.
    if($old -and $old.Hash -eq $hash -and -not $entries[0].Component -and -not $adoptUnchangedCockpit){continue}
    # If an explicitly installed component replaces a retained original, the
    # receipt's verified backup now owns the restoration path. Do not leave the
    # replacement marked Retained, or uninstall would keep the new component.
    if($old -and $old.Hash -and $old.Hash -ne $hash -and $entries[0].Retained){$entries[0].Retained=$false}
    $entries[0].Hash=$hash;$entries[0]|Add-Member Component $Id -Force
   }elseif(-not $old -or $old.Hash -ne $hash -or $adoptUnchangedCockpit){
     $latest.Files+= [pscustomobject]@{Path=$relative;SourcePath='';Hash=$hash;PreviousHash=$(if($old -and $old.Hash){$old.Hash}else{''});Backup=$(if($old -and $old.Hash){$old.Backup}else{''});Mutable=(TestOptiShadeMutableFile $relative);Retained=$true;Component=$Id}
   }
  }
  WriteState $latest $ManifestPath
 }catch{
  $failure=$_
  # An inner model/provider transaction owns its exact file/receipt set. Do
  # not let a broader component snapshot overwrite a retained conflict.
  if(Test-Path -LiteralPath (OwnedPath $folder 'MfgRouteTransaction.json')){try{[void](RecoverOptiShadeRouteTransaction $ManifestPath)}catch{throw ($failure.Exception.Message+' Component recovery was retained because the inner transaction needs review: '+$_.Exception.Message)}}
  foreach($relative in (@(GetAddonInventory $m.Game $Id)+@($paths)|ForEach-Object {$_.Replace('\','/')}|Sort-Object -Unique)){
   $dest=OwnedPath $m.Game $relative;$old=$before[$relative.Replace('\','/')]
   if($old -and $old.Hash){
    $saved=OwnedPath $folder $old.Backup
    if((HashFile $saved) -ne $old.Hash){throw "Recovery copy failed verification: $relative. Recovery files retained at $recovery"}
    Copy-Item -LiteralPath $saved -Destination $dest -Force
    if((HashFile $dest) -ne $old.Hash){throw "Restored file failed verification: $relative. Recovery files retained at $recovery"}
   }
   elseif(Test-Path -LiteralPath $dest){Remove-Item -LiteralPath $dest -Force}
  }
  [IO.File]::WriteAllBytes($ManifestPath,$prior);throw $failure
 }
 # Discard duplicate transaction copies only after commit. Original backups
 # referenced by ownership are retained. Cleanup cannot trigger rollback.
 foreach($saved in $before.Values){
  if($saved.Hash -and $saved.Backup -notin @($latest.Files.Backup)){
   try{Remove-Item -LiteralPath (OwnedPath $folder $saved.Backup) -Force -ErrorAction Stop}catch{}
  }
 }
 }finally{ExitOptiShadeMutation $storeMutation}
}
function GetOptiShadeAddonPayloadEntries([object[]]$Catalogue,$Manifest,[string]$Id,[int]$OptiMfgFamily=0){
 @($Catalogue|Where-Object {
  (GetOptiShadeAddonId $_.Path) -eq $Id -and
  (TestOptiShadeCurrentMfgPayload $_.Path $Manifest $OptiMfgFamily) -and
  ($Manifest.Architecture -eq 'x86' -or -not(TestOptiShadeLegacyPayloadPath $_.Path))
 })
}
function InstallAddonPayload([string]$ManifestPath,[string]$Payload,[string]$Id,[scriptblock]$Progress=$null,[int]$OptiMfgFamily=0){
 $m=ReadOptiShadeState $ManifestPath
 AssertAntiCheatMutation $m.Game $m.LaunchExe ('Install component '+$Id)
 $catalog=ReadOptiShadeJson (Join-Path $Payload 'files.json') 'Payload catalogue' -Shape Array
 $entries=@(GetOptiShadeAddonPayloadEntries $catalog $m $Id $OptiMfgFamily)
 # Validate every source and destination before the first payload write.
 $plan=@();$errors=@()
 foreach($entry in $entries){
  $source=OwnedPath $Payload $entry.Path;$dest=OwnedPath $m.Game $entry.Path
  $sourceHash=HashFile $source
  if($sourceHash -ne $entry.Hash){
   $actual=if($sourceHash){$sourceHash}else{'missing'}
   $errors+=('Component payload verification failed: '+$entry.Path+'; expected SHA256='+$entry.Hash+'; actual='+$actual+'. Reopen a fresh installer and check Windows Security Protection history for this file. Do not disable protection.');continue
  }
  $owned=@($m.Files|Where-Object {$_.Path.Replace('\','/') -ieq $entry.Path.Replace('\','/')})
  $hash=HashFile $dest
  if($owned.Count -gt 1){$errors+='Ambiguous ownership: '+$entry.Path;continue}
  if($hash){
   if($Id -eq 'Cockpit' -and $entry.Path.Replace('\','/') -ieq 'glass-cockpit-dlss-fix.addon64'){
    if($owned.Count -eq 1 -and $owned[0].Component -and $owned[0].Component -notin @('Core','Cockpit')){$errors+='Conflicting component ownership: '+$entry.Path;continue}
    # The download updater owns version advancement. A component reinstall must
    # neither reject a pinned official copy nor downgrade a verified download.
    $verifiedDownload=$owned.Count -eq 1 -and $owned[0].Component -eq 'Cockpit' -and $owned[0].Hash -eq $hash
    if($verifiedDownload -or (TestGlassCockpitLegacyOwnership $owned $dest)){continue}
   }
   if($hash -eq $entry.Hash -or $Id -eq 'Effects'){continue}
   if($owned.Count -eq 1 -and (TestOptiShadeUserSettings $entry.Path)){continue}
   if($owned.Count -ne 1 -or ($owned[0].Hash -ne $hash -and -not(TestOptiShadeMutableGeneratedMetadata $entry.Path))){$errors+='Changed or unowned file requires review: '+$entry.Path;continue}
  }
  $plan+=@{Source=$source;Destination=$dest;Before=$hash;Hash=$entry.Hash;Path=$entry.Path}
 }
 if($errors.Count){throw ('Component preflight stopped before changing files:'+"`n"+($errors -join "`n"))}
 $index=0
 foreach($item in $plan){
  if($Progress){& $Progress ('Installing '+$item.Path) $index $plan.Count};$index++
  if((HashFile $item.Destination) -ne $item.Before){throw ('File changed after component preflight: '+$item.Path)}
  [void][IO.Directory]::CreateDirectory((Split-Path $item.Destination))
  Copy-Item -LiteralPath $item.Source -Destination $item.Destination -Force
  $installedHash=HashFile $item.Destination
  if($installedHash -ne $item.Hash){
   $actual=if($installedHash){$installedHash}else{'missing'}
   throw ('Installed component verification failed: '+$item.Path+'; expected SHA256='+$item.Hash+'; actual='+$actual+'. Check Windows Security Protection history for this file before retrying.')
  }
 }
}
function AssertOptiMfgControllerClosed{
 if(@(Get-Process -Name 'OptiMFG_Live' -ErrorAction SilentlyContinue).Count){throw 'Exit OptiMFG from the system tray before updating this component, including any older standalone test copy. Then retry. No controller files have been changed.'}
}
function EnableOptiMfgGameStartup([string]$ManifestPath){
 $m=ReadOptiShadeState $ManifestPath
 $relative='OptiShadeData/OptiMFG/start-with-game.disabled';$marker=OwnedPath $m.Game $relative
 if(Test-Path -LiteralPath $marker){
  if(-not(Test-Path -LiteralPath $marker -PathType Leaf) -or (Get-Item -LiteralPath $marker).Length -gt 256 -or [IO.File]::ReadAllText($marker) -cne 'Automatic game-triggered OptiMFG start disabled by the user.'){throw 'The old OptiMFG startup preference file is not recognised. Review it before updating; it has been preserved.'}
  Remove-Item -LiteralPath $marker -ErrorAction Stop
 }
 $m.Files=@($m.Files|Where-Object {$_.Path.Replace('\','/') -ine $relative})
 $m.PSObject.Properties.Remove('OptiMfgAutoStartOnPlay')
 WriteState $m $ManifestPath
}
function InstallOptiShadeAddon([string]$ManifestPath,[string]$Payload,[ValidateSet('Effects','Neural','Mfg','OptiMfg','Cockpit','Providers')][string]$Id,$Gpu,[scriptblock]$Progress,[switch]$SkipAllFx,[switch]$ExplicitSelection,[string]$DlssRuntimeProfile,[string]$ApprovedForeignVersionDllHash=''){
 if($Id -eq 'Mfg'){throw 'The legacy OptiShade MFG installer is retired. Install OptiMFG instead. Existing legacy MFG components can still be removed or restored.'}
 $storeMutation=EnterOptiShadeMutation -ManifestPath $ManifestPath
 try{
 [void](RecoverOptiShadeRouteTransaction $ManifestPath)
 $record=ReadOptiShadeState $ManifestPath
 if(-not $DlssRuntimeProfile){$DlssRuntimeProfile=if($record.PSObject.Properties['DlssRuntimeProfile'] -and $record.DlssRuntimeProfile){[string]$record.DlssRuntimeProfile}else{'nvidia-310.9.16'}}
 if($DlssRuntimeProfile -cin @('nvidia-310.9.1','nvidia-310.7.0')){&$Progress "The saved DLSS SR/RR profile $DlssRuntimeProfile is retired. This repair will use the current verified profile nvidia-310.9.16.";$DlssRuntimeProfile='nvidia-310.9.16'}
 $excluded=@(GetOptiShadeAutoComponentExclusions $record)
 if(-not $ExplicitSelection -and ($Id -cin $excluded -or ($Id -ceq 'Mfg' -and 'Providers' -cin $excluded))){throw ('This component was explicitly removed: '+$Id+'. Use its explicit installation action to restore it.')}
 AssertAntiCheatMutation $record.Game $record.LaunchExe ('Install component '+$Id)
 if($record.Architecture -eq 'x86' -and $Id -notin @('Effects','Neural','Mfg')){throw '32-bit games support Image Effects and the experimental Legacy NR bridge only. FSR / XeSS providers and Glass Cockpit require a 64-bit game.'}
 if($Id -eq 'Neural' -and $record.Architecture -eq 'x86'){
  $gameExe=[string]$record.LaunchExe
  if($gameExe -and (Test-Path -LiteralPath $gameExe -PathType Leaf)){
   $identity=GetOptiShadeExecutableIdentity $gameExe
   if($identity.ApiCandidates -contains 'DX9' -and (-not(TestOptiShadeLegacyD3D9Wrapper $record.Game) -or (GetOptiShadeInstalledLoaderPath $record) -ne 'dxgi.dll')){throw 'This game uses native D3D9. Install and configure dgVoodoo2 first, then install or repair OptiShade through DXGI so the wrapper keeps D3D9.dll. Native D3D9 cannot run the Legacy NR bridge.'}
  }
 }
 if($Id -eq 'OptiMfg'){
  AssertOptiMfgControllerClosed
  if($record.Architecture -ne 'x64'){throw 'This OptiMFG build supports 64-bit Microsoft Flight Simulator only.'}
  if('Mfg' -in @(GetOptiShadeAddonSelection $record)){throw 'Remove the legacy OptiShade MFG component first. The legacy provider and OptiMFG cannot be installed together.'}
  $isMsfs=(Test-Path -LiteralPath (OwnedPath $record.Game 'FlightSimulator2024.exe') -PathType Leaf) -or (Test-Path -LiteralPath (OwnedPath $record.Game 'FlightSimulator.exe') -PathType Leaf)
  if(-not $isMsfs){throw 'This OptiMFG build supports Microsoft Flight Simulator 2020 and 2024. It does not add X-Plane or generic-game support.'}
  $catalog=ReadOptiShadeJson (Join-Path $Payload 'files.json') 'Payload catalogue' -Shape Array
  $optiMfgEntries=@(GetOptiShadeAddonPayloadEntries $catalog $record 'OptiMfg')
  $optiMfgPaths=@($optiMfgEntries|ForEach-Object {$_.Path.Replace('\','/')})
  $requiredOptiMfgPaths=@('OptiShadeData/OptiMFG/Runtime/OptiMFG_Live.exe','OptiShadeData/OptiMFG/Runtime/OptiMFG_LiveHelper_v4.dll','OptiShadeData/OptiMFG/Runtime/OptiMFG_LiveCtl.exe','OptiShadeData/OptiMFG/Runtime/OptiMFG_Controller.exe')
  $missingOptiMfgPaths=@($requiredOptiMfgPaths|Where-Object {$_ -notin $optiMfgPaths})
  if($missingOptiMfgPaths.Count){throw ('The OptiMFG controller package is missing required files: '+($missingOptiMfgPaths -join ', ')+'. Native MSFS frame generation remains part of OptiShade core; no controller files were changed.')}
  $family=GetOptiMfgComponentFamily $Gpu $record
  $adapter=ResolveOptiMfgComponentAdapter $Gpu $record
  InvokeAddonTransaction $ManifestPath 'OptiMfg' {
   InstallAddonPayload $ManifestPath $Payload 'OptiMfg' $Progress $family
   InstallOptiMfgHeadless $ManifestPath $Payload $family $ApprovedForeignVersionDllHash
   EnableOptiMfgGameStartup $ManifestPath
  }
  $state=ReadOptiShadeState $ManifestPath
  $state|Add-Member -NotePropertyName Components -NotePropertyValue @(@(GetOptiShadeAddonSelection $state)+'OptiMfg'|Select-Object -Unique) -Force
  $state|Add-Member OptiMfgAdapter (GetOptiShadeAdapterReceipt $adapter.Adapter) -Force
  $state|Add-Member OptiMfgBackendRevision 2 -Force
  $state|Add-Member -NotePropertyName OptiMfgVersion -NotePropertyValue '0.8.6' -Force
  $state|Add-Member -NotePropertyName OptiMfgStatus -NotePropertyValue 'Installed; Performance controls use native RTX 50 control or the menu-free older-RTX backend. Restart the game; OptiMFG starts automatically with the installed runtime.' -Force
  WriteState $state $ManifestPath
  return 'OptiMFG component installed. Restart MSFS; OptiMFG starts automatically. Use Performance > Frame generation. Older-RTX output still requires verification.'
 }
 if($Id -eq 'Mfg'){
  if($record.Architecture -eq 'x86'){$decision='unknown_architecture'}else{try{$decision=GetOptiShadeInstallProviderDecision $record $Payload $Gpu (GetOptiShadeMfgPolicyChannel) -AllowPreinstall}catch{$decision='unknown_adapter';if(Get-Command WriteInstallerLog -ErrorAction SilentlyContinue){WriteInstallerLog ('MFG route discovery deferred to the running game: '+$_.Exception.GetBaseException().Message)}}}
  if($decision -ceq 'native'){
   # RTX 50 uses the game's Streamline provider. Record the selectable MFG
   # component without adding a proxy or duplicate provider DLL; the live
   # provider range is checked by the in-game control when the game runs.
   $record=ReadOptiShadeState $ManifestPath;if($record.PreparedMfg){RemoveOptiShadeAddon $ManifestPath 'Mfg';$record=ReadOptiShadeState $ManifestPath}
   $record|Add-Member -NotePropertyName Components -NotePropertyValue @(@(GetOptiShadeAddonSelection $record)+'Mfg'|Select-Object -Unique) -Force
   $record|Add-Member -NotePropertyName NativeMfg -NotePropertyValue $true -Force
   $record|Add-Member -NotePropertyName ProviderPolicy -NotePropertyValue ([pscustomobject]@{Schema=1;Channel=(GetOptiShadeMfgPolicyChannel);Requested='native';RecordedSource=$false;RecordedLegacy=$false;RecordedSm86=$false;Evidence='native_provider_checked_in_game'}) -Force
   $record|Add-Member -NotePropertyName AutomaticMfgStatus -NotePropertyValue 'MFG component installed. The native game provider and supported multiplier are checked in-game; no separate provider DLL is needed.' -Force
   WriteState $record $ManifestPath
   return 'MFG component installed for the native game route. Start the game and enable its DLSS Frame Generation option; live support is checked in-game.'
  }
  if($decision -notin @('source','legacy','sm86')){
   # Keep MFG selectable even when install-time discovery cannot prove a
   # provider route. Do not guess a loader or alter game files; the running
   # game's provider state is the compatibility check.
   $record=ReadOptiShadeState $ManifestPath
   return RecordOptiShadeDeferredMfgSelection $ManifestPath (GetOptiShadeMfgPolicyChannel) $decision $null $Payload $Progress
  }
  $addedProviders='Providers' -notin @(GetOptiShadeAddonSelection $record)
  try{
   if($addedProviders){InstallOptiShadeAddon $ManifestPath $Payload 'Providers' $Gpu $Progress -ExplicitSelection:$ExplicitSelection}
   return InstallOptionalMfg $ManifestPath $Payload $Gpu $Progress
  }catch{
   $failure=$_.Exception.Message
   $pending=$true;try{$pending=[bool](GetOptiShadeRouteRecovery $ManifestPath)}catch{$failure+=' Pending recovery needs review: '+$_.Exception.Message}
   if(-not $pending){$after=ReadOptiShadeState $ManifestPath;if($after.SourceMfg -or $after.OptionalMfg -or $after.Sm86Mfg){throw $failure}}
   if($addedProviders -and -not $pending){try{RemoveOptiShadeAddon $ManifestPath 'Providers' -PreserveAutoPreference:('Providers' -cnotin @(GetOptiShadeAutoComponentExclusions $record))}catch{$failure+=' Provider dependency cleanup also needs review: '+$_.Exception.Message;$pending=$true}}
   elseif($addedProviders){$failure+=' Prepared provider dependencies were retained with the interrupted MFG transaction.'}
   if($pending){throw $failure}
   WriteInstallerLog ('MFG provider/dependency preparation was deferred after safe rollback: '+$failure)
   return RecordOptiShadeDeferredMfgSelection $ManifestPath (GetOptiShadeMfgPolicyChannel) 'provider_setup_failed' ([Exception]::new($failure))
  }
 }
 if($Id -eq 'Cockpit' -and -not(Test-Path -LiteralPath (OwnedPath $record.Game 'FlightSimulator2024.exe'))){throw 'Glass cockpit correction is for MSFS 2024.'}
 if($Id -eq 'Neural' -and $record.Architecture -ne 'x86'){
  $candidate=ResolveOptiShadeNeuralPreparationAdapter $record $Gpu
  if($candidate.State -ne 'candidate'){throw ('Neural preparation needs a measured adapter candidate: '+$candidate.Reason)}
  if($candidate.PSObject.Properties['Evidence'] -and (Get-Command WriteInstallerLog -ErrorAction SilentlyContinue)){WriteInstallerLog ('Neural preparation selected a current measured inventory LUID from the selected game recent renderer record; this is preparation evidence, not a live rendering claim. LUID='+[string]$candidate.Adapter.Luid+'; evidenceUtc='+[string]$candidate.EvidenceModifiedUtc)}
  $identity=GetOptiShadeRenderingExecutable $record -AllowRecordedUnknown
  if($identity.ApiCandidates.Count -gt 0 -and @($identity.ApiCandidates|Where-Object {$_ -in @('DX11','DX12','Vulkan')}).Count -eq 0){
   $observed=@($identity.ApiCandidates) -join ', ';if(-not $observed){$observed='none'}
   if(Get-Command WriteInstallerLog -ErrorAction SilentlyContinue){WriteInstallerLog ('Neural component preparation allowed; runtime API admission remains separate; executable='+[IO.Path]::GetFileName([string]$identity.Path)+'; candidates='+$observed+'; evidence='+[string]$identity.Evidence)}
  }
 }
 InvokeAddonTransaction $ManifestPath $Id {
  InstallAddonPayload $ManifestPath $Payload $Id $Progress
  switch($Id){
   'Effects'{if(-not $SkipAllFx){$null=InstallAllEffects $record.Game (Join-Path $PSScriptRoot 'EffectPackages.ini') $Progress}}
   'Neural'{
    EnsureNeuralRuntime $ManifestPath $Gpu $Progress
    if($record.Architecture -eq 'x86'){
     InstallNvidia $record.Game $Progress $DlssRuntimeProfile
     $runtime=OwnedPath $record.Game 'OptiShadeData/Engine/nvngx_dlss.dll'
     if(-not(Test-Path -LiteralPath $runtime -PathType Leaf)){throw 'The NVIDIA DLSS runtime is missing after installation.'}
     $hostRuntime=OwnedPath $record.Game 'host64/nvngx_dlss.dll';$runtimeHash=HashFile $runtime;$hostHash=HashFile $hostRuntime
     $hostOwned=@($record.Files|Where-Object {$_.Path.Replace('\','/') -ieq 'host64/nvngx_dlss.dll'})
     if($hostHash -and $hostHash -ne $runtimeHash -and ($hostOwned.Count -ne 1 -or $hostOwned[0].Hash -ne $hostHash)){throw 'An unowned host64/nvngx_dlss.dll is present. It was left unchanged.'}
     Copy-Item -LiteralPath $runtime -Destination $hostRuntime -Force
      if((HashFile $hostRuntime) -ne $runtimeHash){throw 'The x64 worker DLSS runtime failed verification.'}
      $model=OwnedPath $record.Game 'nvngx_dlssnr.dll';$hostModel=OwnedPath $record.Game 'host64/nvngx_dlssnr.dll'
     $modelHash=HashFile $model;$existingHash=HashFile $hostModel
     $ownedModel=@($record.Files|Where-Object {$_.Path.Replace('\','/') -ieq 'host64/nvngx_dlssnr.dll'})
     if(-not $modelHash){throw 'The verified neural model is missing.'}
     if($existingHash -and $existingHash -ne $modelHash -and ($ownedModel.Count -ne 1 -or $ownedModel[0].Hash -ne $existingHash)){throw 'An unowned host64/nvngx_dlssnr.dll was left unchanged.'}
     Copy-Item -LiteralPath $model -Destination $hostModel -Force
     if((HashFile $hostModel) -ne $modelHash){throw 'The x64 worker neural model failed verification.'}
     # Core guides are supplied by the existing renderer after session Auto
     # admission. Preparing a worker/model must not enable a preset feed or
     # replace the user's explicit external guide source.
   }elseif(-not(Test-Path -LiteralPath (OwnedPath $record.Game 'X-Plane.exe'))){InstallNvidia $record.Game $Progress $DlssRuntimeProfile}
   }
  }
  $m=ReadOptiShadeState $ManifestPath
  $m|Add-Member Components @(@(GetOptiShadeAddonSelection $m)+$Id|Select-Object -Unique) -Force
  if($ExplicitSelection){SetOptiShadeAutoComponentExclusion $m $Id $false}
  if($Id -eq 'Effects'){$m|Add-Member IncludeEffects $true -Force;$m|Add-Member AllFxInstalled ([bool](-not $SkipAllFx)) -Force}
   if($Id -eq 'Neural'){
    $m|Add-Member OptionalDlss $true -Force
    $m|Add-Member DlssRuntimeProfile $DlssRuntimeProfile -Force
    if($m.Architecture -eq 'x86'){
     $m|Add-Member Runtime 'ReShade32 + Legacy NR x64 worker' -Force
     $m|Add-Member LegacyNrPresetStatus 'Session controlled' -Force
     $m|Add-Member LegacyNrPresetMessage 'Worker/model dependencies prepared. A current-session Auto action requests NR; the actual API/device/guides and completed output are checked independently. Existing preset/external guide choices are retained.' -Force
    }
   }
  WriteState $m $ManifestPath
 } -Progress $Progress
 }finally{ExitOptiShadeMutation $storeMutation}
}
function UpdateGlassCockpitAddon([string]$ManifestPath,$Release,[scriptblock]$Progress,[scriptblock]$DownloadAction,[scriptblock]$VersionReader){
 $storeMutation=EnterOptiShadeMutation -ManifestPath $ManifestPath
 try{
 $m=ReadOptiShadeState $ManifestPath
 if($m.Status -ne 'Installed'){throw 'Install the OptiShade core first.'}
 if(-not(Test-Path -LiteralPath (OwnedPath $m.Game 'FlightSimulator2024.exe'))){throw 'Glass cockpit correction is for MSFS 2024.'}
 AssertClosed $m.Game
 $relative='glass-cockpit-dlss-fix.addon64';$target=OwnedPath $m.Game $relative
 $records=@($m.Files|Where-Object {([string]$_.Path).Replace('\','/') -ieq $relative})
 $adoptLegacy=TestGlassCockpitLegacyOwnership $records $target
 if(-not $adoptLegacy -and ($records.Count -ne 1 -or $records[0].Component -ne 'Cockpit' -or -not $records[0].Hash)){throw "The Glass Cockpit file has neither a verified ownership record nor a recognized official legacy identity. Receipt: $ManifestPath; target: $target; records: $($records.Count); hash: $(HashFile $target); component: $($records.Component); receipt hash: $($records.Hash)"}
 $originalHash=HashFile $target
 if(-not $originalHash -or (-not $adoptLegacy -and $originalHash -cne [string]$records[0].Hash)){throw 'The installed Glass Cockpit file changed outside OptiShade. No update was applied.'}
 $update=GetGlassCockpitUpdateInfo $m $Release $VersionReader
 if(-not $update.Installed){throw 'The Glass Cockpit correction is not installed for this game.'}
 if(-not $update.Available){throw 'There is no newer verified Glass Cockpit release to install.'}
 $identity=AssertGlassCockpitReleaseAsset $Release
 $stage=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-GlassCockpit-'+[guid]::NewGuid().ToString('N')+'.addon64')
 try{
  if($Progress){& $Progress ('Preparing official Glass Cockpit fix '+$identity.VersionText) 0 3}
  if($DownloadAction){& $DownloadAction $Release $stage $Progress}else{$null=SaveGlassCockpitReleaseAsset $Release $stage $Progress}
  if(-not(Test-Path -LiteralPath $stage -PathType Leaf)){throw 'The official Glass Cockpit download did not produce a file.'}
  $newHash=(Get-FileHash -LiteralPath $stage -Algorithm SHA256).Hash.ToLowerInvariant()
  if($newHash -cne $identity.SHA256){throw 'Glass Cockpit download verification failed. The installed file was not changed.'}
  $binaryVersion=if($VersionReader){[string](& $VersionReader $stage)}else{GetGlassCockpitBinaryVersion $stage}
  if($binaryVersion -notmatch '^(\d+\.\d+\.\d+)$' -or [version]$Matches[1] -ne [version]$identity.VersionText){throw 'The downloaded add-on version did not match the official release tag.'}
  if($Progress){& $Progress ('Installing Glass Cockpit fix '+$identity.VersionText) 2 3}
  # Keep this callback in the installer script scope. A dynamic-module closure cannot
  # resolve script-local helpers when FusionSetup hosts manager.ps1 with AddCommand.
  $mutation={
   if((HashFile $target) -cne $originalHash){throw 'The installed Glass Cockpit file changed during the update. No replacement was made.'}
   if($adoptLegacy -and -not(TestGlassCockpitLegacyOwnership $records $target)){throw 'The official legacy add-on identity changed. No replacement was made.'}
   Copy-Item -LiteralPath $stage -Destination $target -Force
   if((HashFile $target).ToLowerInvariant() -cne $newHash){throw 'The installed Glass Cockpit file failed its post-copy hash check.'}
   $state=ReadOptiShadeState $ManifestPath
   $selection=@(GetOptiShadeAddonSelection $state)+@('Cockpit')
   $state|Add-Member -NotePropertyName Components -NotePropertyValue @($selection|Select-Object -Unique) -Force
   WriteState $state $ManifestPath
  }
  InvokeAddonTransaction $ManifestPath 'Cockpit' $mutation $true $Progress
  if($Progress){& $Progress ('Glass Cockpit fix '+$identity.VersionText+' installed') 3 3}
  return [pscustomobject]@{Version=$identity.VersionText;SHA256=$newHash;Game=$m.Game}
 }finally{if(Test-Path -LiteralPath $stage -PathType Leaf){Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue}}
 }finally{ExitOptiShadeMutation $storeMutation}
}
function RemoveOptiShadeAddon([string]$ManifestPath,[ValidateSet('Effects','Neural','Mfg','OptiMfg','Cockpit','Providers')][string]$Id,[switch]$PreserveAutoPreference){
 $storeMutation=EnterOptiShadeMutation -ManifestPath $ManifestPath
 try{
 [void](RecoverOptiShadeRouteTransaction $ManifestPath)
 $beforeReceiptHash=HashFile $ManifestPath;$m=ReadOptiShadeState $ManifestPath;if($m.Status -ne 'Installed'){throw 'A complete installation is required.'};AssertClosed $m.Game
 if($Id -eq 'Mfg' -and $m.Sm86Mfg){RemoveSm86Mfg $ManifestPath;return}
 if($Id -eq 'Mfg' -and $m.PreparedMfg){
  $relative='OptiShadeData/MFG/OptiShadeMFG.dll';$target=OwnedPath $m.Game $relative;$records=@($m.Files|Where-Object {([string]$_.Path).Replace('\','/') -ieq $relative})
  if($records.Count -ne 1 -or $records[0].Component -cne 'Mfg' -or $records[0].Hash -cne $script:SourceMfgSha256.ToUpperInvariant()){throw 'The prepared MFG payload has no unique matching ownership receipt. No files were removed.'}
  if((HashFile $target) -cne $records[0].Hash){throw 'The prepared MFG payload changed outside OptiShade. No files were removed.'}
  if(Test-Path -LiteralPath (OwnedPath $m.Game 'OptiShadeData/MFG/source-backend.json')){throw 'An MFG activation descriptor appeared after staging. Review the active route before removing its payload.'}
  InvokeAddonTransaction $ManifestPath 'Mfg' {
   Remove-Item -LiteralPath $target -Force
   $state=ReadOptiShadeState $ManifestPath
   $state.Files=@($state.Files|Where-Object {([string]$_.Path).Replace('\','/') -ine $relative})
   $state|Add-Member Components @(GetOptiShadeAddonSelection $state|Where-Object {$_ -ne 'Mfg'}) -Force
   $state.PSObject.Properties.Remove('PreparedMfg');$state.PSObject.Properties.Remove('DeferredMfg')
   if($state.PSObject.Properties['ProviderPolicy'] -and $state.ProviderPolicy.Evidence -ceq 'prepared_waiting_for_supported_loader'){$state.PSObject.Properties.Remove('ProviderPolicy')}
   $state|Add-Member AutomaticMfgStatus 'Prepared MFG payload removed. No loader or activation marker was changed.' -Force
   WriteState $state $ManifestPath
  } $false
  return
 }
 if($Id -eq 'Mfg' -and ($m.NativeMfg -or $m.DeferredMfg)){
  $m|Add-Member -NotePropertyName Components -NotePropertyValue @(GetOptiShadeAddonSelection $m|Where-Object {$_ -ne 'Mfg'}) -Force
  $m.PSObject.Properties.Remove('NativeMfg')
  $m.PSObject.Properties.Remove('DeferredMfg')
  if($m.PSObject.Properties['ProviderPolicy'] -and $m.ProviderPolicy.Requested -in @('native','deferred')){$m.PSObject.Properties.Remove('ProviderPolicy')}
  $m|Add-Member -NotePropertyName AutomaticMfgStatus -NotePropertyValue 'MFG test selection removed. No game provider files were changed.' -Force
  WriteState $m $ManifestPath
  return
 }
 $mfgProviderNeedsDependencies='Mfg' -in @(GetOptiShadeAddonSelection $m) -and -not ($m.NativeMfg -or $m.DeferredMfg)
 if($Id -eq 'Providers' -and ($mfgProviderNeedsDependencies -or $m.FrameGenerationRoute -eq 'portable-fsr2x')){throw 'Remove the MFG add-on and select native game FG before removing its FSR / XeSS support files.'}
 $entries=@($m.Files|Where-Object {((GetOptiShadeAddonId $_.Path) -eq $Id -or [string]$_.Component -ceq $Id) -and $_.Hash -and (-not (TestOptiShadeUserSettings $_.Path) -or ($Id -eq 'OptiMfg' -and $_.Path -in @('RTX40MFG-UI.ini','version.ini')))})
 if($Id -eq 'Mfg' -and $m.OptionalMfg){
  $loader=GetOptiShadeMfgLoaderName $m
  $legacy=@($m.Files|Where-Object {$_.Path -in (GetOptiShadeMfgLoaderAliases) -and $_.Hash -eq 'E9CA3587854EEB723E0579F7DDF6CFB1E6CF4BED79B0D75BC716003ED98FE040' -and $_.SourcePath -ne 'winmm.dll'})
  if($legacy.Count -ne 1){throw 'Optional MFG loader ownership is ambiguous. No component files were changed.'}
  $legacy[0].Path=$loader;$m|Add-Member OptionalMfgLoader $loader -Force
  $entries+= $legacy
 }
 if($Id -eq 'Mfg' -and $m.OptionalMfg){
  $legacy=@($entries|Where-Object {$_.Path -in (GetOptiShadeMfgLoaderAliases) -and $_.Hash -eq 'E9CA3587854EEB723E0579F7DDF6CFB1E6CF4BED79B0D75BC716003ED98FE040'})
  if($legacy.Count -ne 1){throw 'Optional MFG loader ownership is ambiguous. No component files were changed.'}
  $physical=HashFile (OwnedPath $m.Game $legacy[0].Path)
  if($physical -and $physical -ne $legacy[0].Hash){throw "The optional MFG loader at $($legacy[0].Path) changed. No component files were changed."}
 }
 # Preflight the entire removal before touching any file. User-modified files are kept.
 $removalBefore=@{}
 foreach($entry in $entries){
  $hash=HashFile (OwnedPath $m.Game $entry.Path)
  if($hash -and $hash -ne $entry.Hash -and -not (TestOptiShadeMutableGeneratedMetadata $entry.Path)){throw "Component file was edited: $($entry.Path). No files removed."}
  if($entry.Backup -and (HashFile (OwnedPath (Split-Path $ManifestPath) $entry.Backup)) -ne $entry.PreviousHash){throw 'An original component backup is missing or damaged.'}
  $key=([string]$entry.Path).Replace('\','/');if($removalBefore.ContainsKey($key)){throw 'Component removal has duplicate ownership targets.'};$removalBefore[$key]=[string]$hash
 }
 if($Id -eq 'Mfg'){
  $changes=@();$folder=Split-Path $ManifestPath
  foreach($entry in $entries){$key=([string]$entry.Path).Replace('\','/');$changes+=[pscustomobject]@{Path=$key;BeforeHash=$removalBefore[$key];Source=$(if($entry.Backup){OwnedPath $folder $entry.Backup}else{''});AfterHash=$(if($entry.Backup){[string]$entry.PreviousHash}else{''})}}
  $ini=OwnedPath $m.Game 'OptiScaler.ini';$iniBeforeHash=HashFile $ini;$text=[IO.File]::ReadAllText($ini)
  $text=SetMfgIniValue $text 'FrameGen' 'External' 'false';$text=SetMfgIniValue $text 'FrameGen' 'Enabled' 'false'
  $changes+=[pscustomobject]@{Path='OptiScaler.ini';BeforeHash=$iniBeforeHash;Bytes=[Text.UTF8Encoding]::new($false).GetBytes($text)}
  $m.Files=@($m.Files|Where-Object {$_.Path -notin $entries.Path});$m|Add-Member Components @(GetOptiShadeAddonSelection $m|Where-Object {$_ -ne 'Mfg'}) -Force
  $m|Add-Member SourceMfg $false -Force;$m|Add-Member OptionalMfg $false -Force
  $m.PSObject.Properties.Remove('OptionalMfgLoader');$m.PSObject.Properties.Remove('OptionalMfgLoaderEvidence');$m.PSObject.Properties.Remove('SourceMfgRollback')
  $m|Add-Member FrameGenerationRoute 'native' -Force;$m|Add-Member AutomaticMfgStatus 'Optional MFG removed. Native game frame generation remains available.' -Force
  InvokeOptiShadeRouteTransaction $ManifestPath $beforeReceiptHash $m $changes ('MfgRollback/'+[guid]::NewGuid().ToString('N')) 'MFG component removal'
  return
 }
 InvokeAddonTransaction $ManifestPath $Id {
  foreach($entry in $entries){
   $dest=OwnedPath $m.Game $entry.Path
   if($entry.Backup){Copy-Item -LiteralPath (OwnedPath (Split-Path $ManifestPath) $entry.Backup) -Destination $dest -Force}
   elseif(Test-Path -LiteralPath $dest){Remove-Item -LiteralPath $dest -Force}
  }
  $legacyPresetRelative=if($Id -eq 'Neural' -and $m.Architecture -eq 'x86' -and $m.PSObject.Properties['LegacyNrPresetRelative']){[string]$m.LegacyNrPresetRelative}else{''}
  $m.Files=@($m.Files|Where-Object {$_.Path -notin $entries.Path})
  $m|Add-Member Components @(GetOptiShadeAddonSelection $m|Where-Object {$_ -ne $Id}) -Force
  if(-not $PreserveAutoPreference){SetOptiShadeAutoComponentExclusion $m $Id $true}
  if($Id -eq 'Effects'){$m|Add-Member IncludeEffects $false -Force;$m|Add-Member AllFxInstalled $false -Force;$m.PSObject.Properties.Remove('FxPresetRelative')}
  if($Id -eq 'Neural'){
   $m|Add-Member OptionalDlss $false -Force
    if($m.Architecture -eq 'x86'){
     if($legacyPresetRelative){$legacyPresetPath=OwnedPath $m.Game $legacyPresetRelative;if(Test-Path -LiteralPath $legacyPresetPath -PathType Leaf){[void](SetLegacyNrPresetTechnique $legacyPresetPath $false);foreach($presetRecord in @($m.Files|Where-Object {$_.Path.Replace('\','/') -ieq $legacyPresetRelative.Replace('\','/')})){$presetRecord.Hash=HashFile $legacyPresetPath;$presetRecord.Mutable=$true}}}
     $m|Add-Member Runtime 'ReShade32 effects-only' -Force
     $m.PSObject.Properties.Remove('LegacyNrPresetRelative');$m.PSObject.Properties.Remove('LegacyNrPresetStatus');$m.PSObject.Properties.Remove('LegacyNrPresetMessage')
    }else{
    $ini=OwnedPath $m.Game 'OptiScaler.ini';$text=[IO.File]::ReadAllText($ini)
    $text=SetMfgIniValue $text 'DlssNr' 'Enabled' 'false'
    [IO.File]::WriteAllText($ini,$text,[Text.UTF8Encoding]::new($false))
   }
  }

  WriteState $m $ManifestPath
 } -Adopt $false
 }finally{ExitOptiShadeMutation $storeMutation}
}
