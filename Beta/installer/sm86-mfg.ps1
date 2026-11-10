. "$PSScriptRoot/anti-cheat.ps1"
function GetOptiShadeMfgPolicyChannel {
 if(Get-Command GetOptiShadeUpdateChannel -ErrorAction SilentlyContinue){$channel=[string](GetOptiShadeUpdateChannel);if($channel -in @('stable','beta')){return $channel}}
 return 'stable'
}
function GetSm86MfgReleaseIdentity {
 [pscustomobject]@{Version='0.4.0';Url='https://github.com/sdli1995/dlssg_for_sm86/releases/download/v0.4.0/dlssg-release-0.4.0-x64.zip';SHA256='5865360C3295038F0FF979D303BB7EB9437EEC09FBC08686967D3B5D41D9C019';Files=[ordered]@{
  'version.dll'='7B3F90435BE4F94348BF8D128C84871C7F904C704F7690601A263277C327A7B2';'alternatives/winmm.dll'='C86BD90C0FBAF3DB0B5CC17C5BBECE40EB34A6A3327FE2C0DD8AB455BA985203';'alternatives/dbghelp.dll'='33653DDCB57872E275548C4D39C29A3F47C39B1637EEA08D62B55953826E839F';'alternatives/dinput8.dll'='19F2E77303C11B40E773EED6B90E17DF54997B57472127438F9FEDD7A5DDC677';'alternatives/dxgi.dll'='2048988DD9CAD19E9F25610538EDF530B35B036C6701378CF663D7DDF251F5ED';'alternatives/d3d12.dll'='C4B6F6320A8AD465334514161911941F769D541F8E8D5186171FBE0027EA1DDC'
  'dlssg_sm86.ini'='1F780AFBD480E1EC14044E17C37F29C22AFFAF4CC8DA322ACDE927E987106136';'dlssg_sm86/backend/sm86_backend.dll'='30FFC6E09A347CCDE87ECC6FA54FD7818F5ED8A9353F5C31C2A90835C7F0CA9B';'dlssg_sm86/kernels/fg_kernels.dll'='1394C2D5D9CC8938BA3E52B043048D20D6D4C13A019C161B11A3DFD16343EC24';'dlssg_sm86/runtime/nvngx_dlssg.dll'='CADEE1AA6DB3907BABDC3285DA2AEBC4553D92B89C38BA3EAE8ABD8BBA1BEA72'
  'LICENSE.md'='7537220F50C6430D953EDA8BFF01F0817014E604CB3607F3B62C786D070D8570';'THIRD_PARTY_NOTICES.txt'='C8F2449237F0C556AB7B494AE131E534B39614B5D0F1E56E39D95353426FF2F7'
 }}
}
function GetSm86MfgLoaderAliases { @('OptiShadeData/Engine/dlssg_sm86/dlssg_sm86.dll') }
function GetSm86MfgInstallPlan([string]$Loader){
 $loaderPath='OptiShadeData/Engine/dlssg_sm86/dlssg_sm86.dll'
 if($Loader -and $Loader.Replace('\','/') -cne $loaderPath){throw 'The SM86 provider must be hosted by OptiScaler inside OptiShadeData/Engine; game-folder proxy installation is disabled.'}
 @(
  [pscustomobject]@{Entry='version.dll';Path=$loaderPath;Mutable=$false}
  [pscustomobject]@{Entry='dlssg_sm86.ini';Path='OptiShadeData/Engine/dlssg_sm86/dlssg_sm86.ini';Mutable=$true}
  [pscustomobject]@{Entry='dlssg_sm86/backend/sm86_backend.dll';Path='OptiShadeData/Engine/dlssg_sm86/backend/sm86_backend.dll';Mutable=$false}
  [pscustomobject]@{Entry='dlssg_sm86/kernels/fg_kernels.dll';Path='OptiShadeData/Engine/dlssg_sm86/kernels/fg_kernels.dll';Mutable=$false}
  [pscustomobject]@{Entry='dlssg_sm86/runtime/nvngx_dlssg.dll';Path='OptiShadeData/Engine/dlssg_sm86/runtime/nvngx_dlssg.dll';Mutable=$false}
  [pscustomobject]@{Entry='LICENSE.md';Path='OptiShadeData/Licenses/DLSSG-SM86/LICENSE.md';Mutable=$false}
  [pscustomobject]@{Entry='THIRD_PARTY_NOTICES.txt';Path='OptiShadeData/Licenses/DLSSG-SM86/THIRD_PARTY_NOTICES.txt';Mutable=$false}
 )
}
function GetSm86MfgIniValue([string]$Text,[string]$Section,[string]$Key){
 $active=$false;foreach($line in ($Text -split '\r?\n')){if($line -match '^\s*\[([^]]+)\]'){$active=$Matches[1] -ieq $Section;continue};if($active -and $line -match ('^\s*'+[regex]::Escape($Key)+'\s*=\s*(.*?)\s*$')){return [string]$Matches[1]}};return $null
}
function SetSm86MfgIniValue([string]$Text,[string]$Section,[string]$Key,[AllowNull()][string]$Value){
 if($null -ne $Value){return SetMfgIniValue $Text $Section $Key $Value}
 $lines=[Collections.Generic.List[string]]::new();$active=$false;$found=$false
 foreach($line in ($Text -split '\r?\n')){if($line -match '^\s*\[([^]]+)\]'){$active=$Matches[1] -ieq $Section;if($active){$found=$true};$lines.Add($line);continue};if($active -and $line -match ('^\s*'+[regex]::Escape($Key)+'\s*=')){continue};$lines.Add($line)}
 if(-not $found){return $Text};return $lines -join "`r`n"
}
function SelectSm86MfgLoader($Manifest){
 $loaderPath='OptiShadeData/Engine/dlssg_sm86/dlssg_sm86.dll'
 $coreRecords=@($Manifest.Files|Where-Object {$_.SourcePath -eq 'winmm.dll' -and $_.Path -in @('winmm.dll','dxgi.dll','d3d12.dll','version.dll','dbghelp.dll','wininet.dll','winhttp.dll')})
 if($coreRecords.Count -ne 1){throw 'The OptiScaler host proxy is not recorded unambiguously for this game. Repair the OptiShade core before installing SM86 MFG.'}
 $core=OwnedPath $Manifest.Game ([string]$coreRecords[0].Path)
 if(-not(Test-Path -LiteralPath $core -PathType Leaf) -or (HashFile $core) -cne [string]$coreRecords[0].Hash){throw 'The recorded OptiScaler host proxy is missing or changed. Repair the OptiShade core before installing SM86 MFG.'}
 $dest=OwnedPath $Manifest.Game $loaderPath;$existing=HashFile $dest
 $owned=@($Manifest.Files|Where-Object {$_.Path.Replace('\','/') -eq $loaderPath -and $_.Component -eq 'Mfg'})
 if($existing -and ($owned.Count -ne 1 -or $existing -cne $owned[0].Hash)){throw 'The OptiScaler-hosted SM86 provider path is occupied or changed. Review the file before continuing.'}
 return $loaderPath
}
function GetSm86MfgInstallArchive([string]$Work,[scriptblock]$Progress,[string]$ArchivePath=''){
 $identity=GetSm86MfgReleaseIdentity
 if($ArchivePath){$archive=[IO.Path]::GetFullPath($ArchivePath);if(-not(Test-Path -LiteralPath $archive -PathType Leaf)){throw 'The pinned SM86 provider archive is missing.'}}
 else{$archive=Join-Path $Work 'dlssg-release-0.4.0-x64.zip';if($Progress){& $Progress 'Downloading the pinned RTX 20/30 frame-generation provider...' 0 4};[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -Uri $identity.Url -OutFile $archive -UseBasicParsing}
 if((HashFile $archive) -cne $identity.SHA256){throw 'The downloaded SM86 provider did not match the pinned upstream release SHA-256.'}
 [pscustomobject]@{Identity=$identity;Archive=$archive}
}
function ExtractSm86MfgFiles([string]$Archive,[string]$Stage,$Plan,$Identity,[scriptblock]$Progress){
 Add-Type -AssemblyName System.IO.Compression.FileSystem;$zip=[IO.Compression.ZipFile]::OpenRead($Archive);$index=0
 try{foreach($item in $Plan){$index++;if($Progress){& $Progress ('Verifying upstream file '+$index+' of '+$Plan.Count+'...') (1+$index) 4};if(-not $Identity.Files.Contains($item.Entry)){throw ('Unexpected SM86 package file: '+$item.Entry)};$entries=@($zip.Entries|Where-Object {$_.FullName.Replace('\','/') -ceq $item.Entry});if($entries.Count -ne 1){$names=@($zip.Entries|ForEach-Object {$_.FullName.Replace('\','/')}|Select-Object -First 20);throw ('SM86 archive entry is missing or duplicated: '+$item.Entry+'; archive entries: '+($names -join ', '))};$target=Join-Path $Stage ('file-'+$index);$input=$entries[0].Open();$output=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$input.CopyTo($output)}finally{$output.Dispose();$input.Dispose()};if((HashFile $target) -cne [string]$Identity.Files[$item.Entry]){throw ('SM86 file hash mismatch: '+$item.Entry)};$item|Add-Member StagedPath $target -Force;$item|Add-Member Hash ([string]$Identity.Files[$item.Entry]) -Force}}
 finally{$zip.Dispose()};return ,$Plan
}
function TestSm86MfgReceipt($Manifest){
 $identity=GetSm86MfgReleaseIdentity
 if(-not $Manifest.Sm86Mfg -or [string]$Manifest.Sm86MfgVersion -ne $identity.Version -or [string]$Manifest.Sm86MfgSHA256 -cne $identity.SHA256 -or [string]$Manifest.Sm86MfgLoader -notin (GetSm86MfgLoaderAliases)){return $false}
 $plan=@(GetSm86MfgInstallPlan ([string]$Manifest.Sm86MfgLoader))
 $manifestPaths=@($Manifest.Sm86MfgFiles);if($manifestPaths.Count -ne $plan.Count -or @($manifestPaths|ForEach-Object {([string]$_).Replace('\','/')}|Select-Object -Unique).Count -ne $plan.Count){return $false}
 foreach($relative in @($Manifest.Sm86MfgFiles)){$normalized=([string]$relative).Replace('\','/');$item=@($plan|Where-Object {$_.Path.Replace('\','/') -eq $normalized});$record=@($Manifest.Files|Where-Object {$_.Path.Replace('\','/') -eq $normalized -and $_.Component -eq 'Mfg'});if($item.Count -ne 1 -or $record.Count -ne 1 -or -not $identity.Files.Contains($item[0].Entry) -or [string]$record[0].Hash -cne [string]$identity.Files[$item[0].Entry] -or [bool]$record[0].Mutable -ne [bool]$item[0].Mutable){return $false};$current=HashFile (OwnedPath $Manifest.Game $relative);if(-not $current){return $false};if($current -cne $record[0].Hash -and -not $record[0].Mutable){throw "SM86 component file changed after installation: $relative"}}
 return $true
}
function InstallSm86Mfg([string]$ManifestPath,$GpuNames,[scriptblock]$Progress,[string]$ArchivePath=''){
 $storeMutation=EnterOptiShadeMutation -ManifestPath $ManifestPath
 try{
 [void](RecoverOptiShadeRouteTransaction $ManifestPath)
 $guardRecord=ReadOptiShadeState $ManifestPath;AssertAntiCheatMutation $guardRecord.Game $guardRecord.LaunchExe 'Install MFG'
 $beforeReceiptHash=HashFile $ManifestPath;$m=ReadOptiShadeState $ManifestPath
 if($m.Status -ne 'Installed'){throw 'Install OptiShade first.'};AssertClosed $m.Game
 if((TestOptiShadeMfgInstallTarget $m $GpuNames).State -ne 'candidate'){throw 'SM86 preparation requires an installed 64-bit game and a measured supported NVIDIA RTX adapter. No provider files were changed.'}
 $candidate=ResolveOptiShadeMfgAdapter $GpuNames $m
 if($candidate.State -ne 'candidate' -or $candidate.Adapter.Family -notin @(20,30)){throw 'The SM86 provider requires an unambiguous, driver-identified Turing or Ampere RTX adapter. Neural preferences cannot select the MFG adapter.'}
 if($m.FrameGenerationRoute -eq 'portable-fsr2x'){throw 'Select native game frame generation before installing the SM86 DLSS-G provider.'}
 if($m.OptionalMfg){throw 'Remove the recorded legacy MFG provider before preparing SM86. Its existing loader was retained.'}
 if(TestSm86MfgReceipt $m){return 'DLSSG for SM86 v0.4.0 is installed. OptiScaler controls use the live game/provider range; output still needs testing.'}
 $loader=SelectSm86MfgLoader $m;$identity=GetSm86MfgReleaseIdentity;$plan=@(GetSm86MfgInstallPlan $loader);$newPaths=@($plan|ForEach-Object {([string]$_.Path).Replace('\','/')})
 $iniPath=OwnedPath $m.Game 'OptiScaler.ini';$iniBeforeHash=HashFile $iniPath
 if(-not $iniBeforeHash){throw 'The OptiScaler settings file is missing. Repair the core before installing MFG.'}
 $work=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-SM86-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory((Join-Path $work 'staged'))
 try{
  $folder=Split-Path $ManifestPath;$changes=@();$retired=@();$oldRecords=@{}
  # Complete ownership and original-backup validation before staging any game
  # mutation. A changed mutable provider INI remains the user's file.
  foreach($relative in @($m.Sm86MfgFiles|Where-Object {$_ -and ([string]$_).Replace('\','/') -notin $newPaths})){
   $oldPath=([string]$relative).Replace('\','/');$record=@($m.Files|Where-Object {([string]$_.Path).Replace('\','/') -ieq $oldPath -and $_.Component -eq 'Mfg'})
   if($record.Count -ne 1){throw "Previous SM86 ownership is missing or ambiguous: $oldPath"}
   $current=[string](HashFile (OwnedPath $m.Game $oldPath));$old=$record[0]
   if($current -and $current -cne [string]$old.Hash -and -not $old.Mutable){throw "Previous SM86 file changed and needs review: $oldPath. No provider files were changed."}
   if($old.Backup -and (HashFile (OwnedPath $folder $old.Backup)) -cne [string]$old.PreviousHash){throw "Previous SM86 original backup is missing or damaged: $oldPath"}
   if(-not($old.Mutable -and $current -and $current -cne [string]$old.Hash)){
    $changes+=[pscustomobject]@{Path=$oldPath;BeforeHash=$current;Source=$(if($old.Backup){OwnedPath $folder $old.Backup}else{''});AfterHash=$(if($old.Backup){[string]$old.PreviousHash}else{''})}
   }
   $retired+=,$oldPath
  }
  if($m.SourceMfg){foreach($relative in @('OptiShadeData/MFG/OptiShadeMFG.dll','OptiShadeData/MFG/source-backend.json')){
   $current=[string](HashFile (OwnedPath $m.Game $relative));$owned=@($m.Files|Where-Object {([string]$_.Path).Replace('\','/') -ieq $relative})
   if($owned.Count -gt 1 -or ($owned.Count -eq 1 -and $owned[0].Mutable) -or ($current -and ($owned.Count -ne 1 -or [string]$owned[0].Hash -cne $current))){throw "Previous source MFG file is not safely owned: $relative"}
   if($owned.Count -and $owned[0].Backup -and (HashFile (OwnedPath $folder $owned[0].Backup)) -cne [string]$owned[0].PreviousHash){throw "Previous source MFG original backup is missing or damaged: $relative"}
   $original=if($owned.Count -and $owned[0].Backup){OwnedPath $folder $owned[0].Backup}else{''}
   $changes+=[pscustomobject]@{Path=$relative;BeforeHash=$current;Source=$original;AfterHash=$(if($original){[string]$owned[0].PreviousHash}else{''})};$retired+=,$relative
  }}
  $package=GetSm86MfgInstallArchive $work $Progress $ArchivePath
  $plan=ExtractSm86MfgFiles $package.Archive (Join-Path $work 'staged') $plan $identity $Progress
  foreach($item in $plan){
   $dest=OwnedPath $m.Game $item.Path;$owned=@($m.Files|Where-Object {([string]$_.Path).Replace('\','/') -ieq $item.Path});$current=[string](HashFile $dest)
   if($owned.Count -gt 1 -or ($owned.Count -eq 1 -and $owned[0].Component -ne 'Mfg')){throw "SM86 ownership is ambiguous: $($item.Path)"}
   if($owned.Count){$oldRecords[$item.Path]=$owned[0];if($owned[0].Backup -and (HashFile (OwnedPath $folder $owned[0].Backup)) -cne [string]$owned[0].PreviousHash){throw "SM86 original backup is missing or damaged: $($item.Path)"}}
   if($current -and ($owned.Count -ne 1 -or $current -cne [string]$owned[0].Hash)){
    if($item.Mutable -and $owned.Count -eq 1 -and $owned[0].Mutable){$item|Add-Member PreserveExisting $true -Force;continue}
    throw "SM86 destination is occupied or changed: $($item.Path). Existing files were left untouched."
   }
   if($current -cne [string]$item.Hash){$changes+=[pscustomobject]@{Path=$item.Path;BeforeHash=$current;Source=$item.StagedPath;AfterHash=$item.Hash}}
  }
  $text=[IO.File]::ReadAllText($iniPath)
  $beforeIni=if($m.Sm86Mfg -and $m.Sm86MfgIniBefore){$m.Sm86MfgIniBefore}else{[pscustomobject]@{External=(GetSm86MfgIniValue $text 'FrameGen' 'External');AdaMfgUnlock=(GetSm86MfgIniValue $text 'DLSSG' 'AdaMfgUnlock');AmpereMfgUnlock=(GetSm86MfgIniValue $text 'DLSSG' 'AmpereMfgUnlock')}}
  if($m.SourceMfg -and $m.SourceMfgRollback){
   $stateRoot=[IO.Path]::GetFullPath($folder);$rollbackRoot=[IO.Path]::GetFullPath([string]$m.SourceMfgRollback)
   if(-not $rollbackRoot.StartsWith((Join-Path $stateRoot 'MfgRollback')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'The previous MFG settings backup is outside the recorded recovery folder.'}
   $rollbackReceipt=OwnedPath $rollbackRoot 'rollback.json';if(-not(Test-Path -LiteralPath $rollbackReceipt -PathType Leaf)){throw 'The previous MFG settings backup is missing; migration stopped before changing files.'}
   $rollbackInfo=ReadOptiShadeJson $rollbackReceipt 'Previous MFG rollback receipt' -MaxBytes 1048576 -Shape Object
   if((FullPath ([string]$rollbackInfo.Game)) -ine (FullPath ([string]$m.Game))){throw 'The previous MFG settings backup belongs to a different game.'}
   $iniBackup=@($rollbackInfo.Files|Where-Object {$_.Path -ceq 'OptiScaler.ini'});if($iniBackup.Count -ne 1 -or -not $iniBackup[0].Hash){throw 'The previous MFG settings backup is ambiguous; migration stopped before changing files.'}
   $iniBackupPath=[IO.Path]::GetFullPath([string]$iniBackup[0].Copy);$prefix=$rollbackRoot.TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
   if(-not $iniBackupPath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'The previous MFG settings backup is outside its recovery folder.'}
   $iniBackupPath=OwnedPath $rollbackRoot $iniBackupPath.Substring($prefix.Length)
   if((HashFile $iniBackupPath) -cne [string]$iniBackup[0].Hash){throw 'The previous MFG settings backup failed verification; migration stopped before changing files.'}
   $originalText=[IO.File]::ReadAllText($iniBackupPath);$beforeIni=[pscustomobject]@{External=(GetSm86MfgIniValue $originalText 'FrameGen' 'External');AdaMfgUnlock=(GetSm86MfgIniValue $originalText 'DLSSG' 'AdaMfgUnlock');AmpereMfgUnlock=(GetSm86MfgIniValue $originalText 'DLSSG' 'AmpereMfgUnlock')}
  }
  $text=SetMfgIniValue $text 'FrameGen' 'External' 'true';$text=SetMfgIniValue $text 'DLSSG' 'AdaMfgUnlock' 'false';$text=SetMfgIniValue $text 'DLSSG' 'AmpereMfgUnlock' 'true'
  $changes+=[pscustomobject]@{Path='OptiScaler.ini';BeforeHash=$iniBeforeHash;Bytes=[Text.UTF8Encoding]::new($false).GetBytes($text)}
  $drop=@($newPaths)+@($retired);$m.Files=@($m.Files|Where-Object {([string]$_.Path).Replace('\','/') -notin $drop})
  foreach($item in $plan){$old=$oldRecords[$item.Path];if($item.PreserveExisting -and $old){$m.Files+=,$old;continue};$m.Files+=[pscustomobject]@{Path=$item.Path;SourcePath='';Hash=$item.Hash;PreviousHash=$(if($old){$old.PreviousHash}else{''});Backup=$(if($old){$old.Backup}else{''});Mutable=[bool]$item.Mutable;Retained=$true;Component='Mfg'}}
  $m|Add-Member Components @(@(GetOptiShadeAddonSelection $m)+'Mfg'|Select-Object -Unique) -Force
  $m|Add-Member ProviderAdapter (GetOptiShadeAdapterReceipt $candidate.Adapter) -Force
  $m|Add-Member Sm86Mfg $true -Force;$m|Add-Member Sm86MfgVersion $identity.Version -Force;$m|Add-Member Sm86MfgSHA256 $identity.SHA256 -Force;$m|Add-Member Sm86MfgLoader $loader -Force;$m|Add-Member Sm86MfgFiles @($plan|ForEach-Object Path) -Force;$m|Add-Member Sm86MfgIniBefore $beforeIni -Force
  $m|Add-Member SourceMfg $false -Force;$m|Add-Member OptionalMfg $false -Force;$m.PSObject.Properties.Remove('SourceMfgRollback');$m.PSObject.Properties.Remove('OptionalMfgLoader');$m.PSObject.Properties.Remove('OptionalMfgLoaderEvidence');$m.PSObject.Properties.Remove('PreparedMfg');$m.PSObject.Properties.Remove('DeferredMfg');$m.PSObject.Properties.Remove('NativeMfg')
  $channel=GetOptiShadeMfgPolicyChannel;$m|Add-Member ProviderPolicy ([pscustomobject]@{Schema=1;Channel=$channel;Requested='sm86';RecordedSource=$false;RecordedLegacy=$false;RecordedSm86=$true;Evidence='pinned_upstream_installation'}) -Force
  $m|Add-Member AutomaticMfgStatus 'DLSSG for SM86 v0.4.0 is hosted by OptiScaler for RTX 20/30. This experimental integration still needs a game test; installed files do not prove generated frames.' -Force
  if($Progress){& $Progress 'Activating the frame-generation provider...' 3 4}
  InvokeOptiShadeRouteTransaction $ManifestPath $beforeReceiptHash $m $changes ('MfgRollback/'+[guid]::NewGuid().ToString('N')) 'SM86 MFG preparation'
  # Keep historical recovery archives and original chains. Cosmetic reporting
  # after commit cannot undo a committed provider or remove its dependencies.
  if($Progress){try{& $Progress 'Provider installed and ownership recorded.' 4 4}catch{}}
  return [string]$m.AutomaticMfgStatus
 }finally{if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}}
 }finally{ExitOptiShadeMutation $storeMutation}
}
function RemoveSm86Mfg([string]$ManifestPath){
 $storeMutation=EnterOptiShadeMutation -ManifestPath $ManifestPath
 try{
 [void](RecoverOptiShadeRouteTransaction $ManifestPath)
 $beforeReceiptHash=HashFile $ManifestPath;$m=ReadOptiShadeState $ManifestPath
 if(-not $m.Sm86Mfg){throw 'The selected game does not have the SM86 MFG provider recorded.'};AssertClosed $m.Game
 $paths=@($m.Sm86MfgFiles);$changes=@();$folder=Split-Path $ManifestPath
 foreach($relative in $paths){
  $record=@($m.Files|Where-Object {([string]$_.Path).Replace('\','/') -ieq ([string]$relative).Replace('\','/') -and $_.Component -eq 'Mfg'})
  if($record.Count -ne 1){throw "SM86 ownership record is missing or ambiguous: $relative"}
  $entry=$record[0];$current=[string](HashFile (OwnedPath $m.Game $relative))
  if($current -and $current -cne [string]$entry.Hash -and -not $entry.Mutable){throw "SM86 component file changed: $relative. No files were removed."}
  if($entry.Backup -and (HashFile (OwnedPath $folder $entry.Backup)) -cne [string]$entry.PreviousHash){throw "SM86 original backup is missing or damaged: $relative"}
  if($entry.Mutable -and $current -and $current -cne [string]$entry.Hash){continue}
  $changes+=[pscustomobject]@{Path=([string]$relative).Replace('\','/');BeforeHash=$current;Source=$(if($entry.Backup){OwnedPath $folder $entry.Backup}else{''});AfterHash=$(if($entry.Backup){[string]$entry.PreviousHash}else{''})}
 }
 $iniPath=OwnedPath $m.Game 'OptiScaler.ini';$iniBeforeHash=HashFile $iniPath;$text=[IO.File]::ReadAllText($iniPath);$prior=$m.Sm86MfgIniBefore
 foreach($pair in @(@('FrameGen','External','true','External'),@('DLSSG','AdaMfgUnlock','false','AdaMfgUnlock'),@('DLSSG','AmpereMfgUnlock','true','AmpereMfgUnlock'))){
  if((GetSm86MfgIniValue $text $pair[0] $pair[1]) -ceq $pair[2]){$property=if($prior){$prior.PSObject.Properties[[string]$pair[3]]}else{$null};$value=if($property){[string]$property.Value}else{$null};$text=SetSm86MfgIniValue $text $pair[0] $pair[1] $value}
 }
 $changes+=[pscustomobject]@{Path='OptiScaler.ini';BeforeHash=$iniBeforeHash;Bytes=[Text.UTF8Encoding]::new($false).GetBytes($text)}
 $drop=@($paths|ForEach-Object {([string]$_).Replace('\','/')});$m.Files=@($m.Files|Where-Object {([string]$_.Path).Replace('\','/') -notin $drop});$m|Add-Member Components @(GetOptiShadeAddonSelection $m|Where-Object {$_ -ne 'Mfg'}) -Force
 foreach($key in @('Sm86Mfg','Sm86MfgVersion','Sm86MfgSHA256','Sm86MfgLoader','Sm86MfgFiles','Sm86MfgIniBefore')){$m.PSObject.Properties.Remove($key)}
 $m|Add-Member SourceMfg $false -Force;$m|Add-Member OptionalMfg $false -Force;$m|Add-Member AutomaticMfgStatus 'SM86 MFG removed. Native game frame generation remains available.' -Force
 InvokeOptiShadeRouteTransaction $ManifestPath $beforeReceiptHash $m $changes ('MfgRollback/'+[guid]::NewGuid().ToString('N')) 'SM86 MFG removal'
 foreach($relative in @('dlssg_sm86','OptiShadeData/Engine/dlssg_sm86','OptiShadeData/Licenses/DLSSG-SM86')){try{$dir=OwnedPath $m.Game $relative;if((Test-Path -LiteralPath $dir -PathType Container) -and -not(Get-ChildItem -LiteralPath $dir -Force)){Remove-Item -LiteralPath $dir -Force}}catch{}}
 }finally{ExitOptiShadeMutation $storeMutation}
}
