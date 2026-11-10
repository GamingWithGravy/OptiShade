# Read-only, selected-installation evidence. Never loads a candidate binary.
$consentPath=Join-Path $PSScriptRoot 'consent.ps1'
if(Test-Path -LiteralPath $consentPath -PathType Leaf){. $consentPath}

function GetAntiCheatHash([string]$Text){
 $sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','')}finally{$sha.Dispose()}
}
function ReadAntiCheatXml([string]$Path){
 if((Get-Item -LiteralPath $Path -ErrorAction Stop).Length -gt 1MB){throw 'Game metadata exceeds the size limit.'}
 $settings=[Xml.XmlReaderSettings]::new();$settings.DtdProcessing='Prohibit';$settings.XmlResolver=$null
 $reader=[Xml.XmlReader]::Create($Path,$settings);try{$doc=[Xml.XmlDocument]::new();$doc.XmlResolver=$null;$doc.Load($reader);return ,$doc}finally{$reader.Dispose()}
}
function GetAntiCheatTarget([string]$Game,[string]$Executable=''){
 $root=[IO.Path]::GetFullPath($Game).TrimEnd('\');$limits=[Collections.Generic.List[string]]::new()
 $target=[pscustomobject]@{Root=$root;Executable=$Executable;Name='';Store='';ProductId='';Verified=$false;Limitations=@();ExcludedDirectories=@();ScopeBlocked=$false}
 if($root.TrimEnd('\') -eq [IO.Path]::GetPathRoot($root).TrimEnd('\') -or $root -match '(?i)[\\/](steamapps|common|Xbox games|XboxGames)$'){$target.Name=$root;$target.ScopeBlocked=$true;$target.Limitations=@('Select a specific game installation, not a drive or library root.');return $target}
 # Read only adjacent, bounded store metadata; never scan arbitrary ancestors.
 $part=$root
 while($part){
  try{if((Get-Item -LiteralPath $part -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){$target.Name=[IO.Path]::GetFileName($root)+' (title not verified)';$target.Limitations=@('Linked installation scope could not be verified.');$target.ScopeBlocked=$true;return $target}}catch{}
  $part=[IO.Path]::GetDirectoryName($part)
 }
 $config=Join-Path $root 'MicrosoftGame.config'
 if(Test-Path -LiteralPath $config -PathType Leaf){try{
  $xml=ReadAntiCheatXml $config;$executables=@($xml.Game.ExecutableList.Executable)
  if($executables.Count -eq 1){$relative=[string]$executables[0].Name
   if([IO.Path]::GetFileName($relative) -eq $relative -and $relative -match '\.exe$'){
    $candidate=Join-Path $root $relative
    if(Test-Path -LiteralPath $candidate -PathType Leaf){$target.Executable=$candidate;$target.Name=[string]$xml.Game.ShellVisuals.DefaultDisplayName;$target.Store='Xbox';$target.ProductId=[string]$xml.Game.Identity.Name;$target.Verified=$true}
   }
  }
 }catch{$limits.Add('Game metadata could not be validated.')}}
 # A Steam common/<game> shape allows metadata lookup, not a scan of the library.
 if($root -match '^(?<apps>.+[\\/]steamapps)[\\/]common[\\/](?<dir>[^\\/]+)(?:[\\/].*)?$'){
  $apps=$Matches.apps;$dir=$Matches.dir;$confirmed=[IO.Path]::GetFullPath((Join-Path $apps ('common/'+$dir)))
  try{$count=0;foreach($acf in [IO.Directory]::EnumerateFiles($apps,'appmanifest_*.acf')){
   if(++$count -gt 1000){$limits.Add('Steam metadata entry limit reached.');break}
   if((Get-Item -LiteralPath $acf).Length -gt 256KB){continue}
   $text=[IO.File]::ReadAllText($acf)
   $install=[regex]::Match($text,'"installdir"\s+"([^"\r\n]+)"').Groups[1].Value
   $id=[regex]::Match($text,'"appid"\s+"(\d+)"').Groups[1].Value
   if($install -ieq $dir -and [IO.Path]::GetFileName($acf) -ieq ('appmanifest_'+$id+'.acf')){
    $target.Root=$confirmed;$target.Store='Steam';$target.ProductId=$id;$target.Verified=$true
    $target.Name=[regex]::Match($text,'"name"\s+"([^"\r\n]+)"').Groups[1].Value;break
   }
  }}catch{$limits.Add('Steam installation metadata was unreadable.')}
 }
 if(-not $target.Executable){
  try{$candidates=@([IO.Directory]::EnumerateFiles($root,'*.exe')|Where-Object {[IO.Path]::GetFileName($_) -notmatch '(?i)setup|unins|launcher|gamelaunchhelper|crash|report|update|anti.?cheat|beservice'}|Select-Object -First 2)
   if($candidates.Count -eq 1){$target.Executable=$candidates[0]}
  }catch{$limits.Add('Rendering executable could not be resolved.')}
 }
 if($target.Executable){$target.Executable=[IO.Path]::GetFullPath($target.Executable)
  if(-not $target.Executable.StartsWith($target.Root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'The rendering executable is outside the selected installation.'}
  if(-not(Test-Path -LiteralPath $target.Executable -PathType Leaf)){$target.Verified=$false;$limits.Add('Rendering executable was not found.')}
 }else{$limits.Add('Rendering executable is unresolved.')}
 if(-not $target.Verified){$target.Name=$(if($target.Executable){[IO.Path]::GetFileName($target.Executable)}else{[IO.Path]::GetFileName($root)})+' (title not verified)';$limits.Add('Only the selected folder is checked; the installation root is not verified.')}
 if(-not $target.Name){$target.Name=[IO.Path]::GetFileName($target.Executable)+' (title not verified)'}
 # Exclude only a directory established as OptiShade-owned by the local receipt.
 if(Get-Command ManifestPath -ErrorAction SilentlyContinue){try{
  $existing=GetOptiShadeExistingInstallation $root
  if($existing){$m=$existing.Manifest
   if($m.Game -ieq $root -and @($m.Files|Where-Object {([string]$_.Path).Replace('\','/') -like 'OptiShadeData/Engine/*' -and $_.Hash}).Count){$target.ExcludedDirectories=@('OptiShadeData')}
  }
 }catch{}}
 $target.Limitations=@($limits.ToArray());return $target
}
function GetAntiCheatFileEvidence([string]$Path,$Rule){
 try{
  $stream=[IO.File]::OpenRead($Path);$reader=[IO.BinaryReader]::new($stream)
  try{if($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5a4d){return 'Not a valid PE component'};$stream.Position=0x3c;$offset=$reader.ReadUInt32();if($offset+4 -gt $stream.Length){return 'Invalid PE header'};$stream.Position=$offset;if($reader.ReadUInt32() -ne 0x4550){return 'Invalid PE signature'}}finally{$reader.Dispose()}
  $info=[Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
  $signature=Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
  if($signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -match $Rule.Signer -and ($info.ProductName+' '+$info.FileDescription) -match $Rule.Product){return 'Verified provider signature and product metadata'}
  return 'Provider signature/product evidence unverified'
 }catch{return 'Component metadata could not be verified'}
}
function InvokeAntiCheatScanCore($Target,[string]$RulesPath,[int]$MaxEntries=20000,[int]$MaxDepth=6,[int]$MaxMilliseconds=5000,$Cancellation=$null,[switch]$QuickLocationsOnly){
 $hits=[Collections.Generic.List[object]]::new();$limits=[Collections.Generic.List[string]]::new()
 foreach($limit in $Target.Limitations){$limits.Add([string]$limit)}
 $watch=[Diagnostics.Stopwatch]::StartNew();$entries=0;$version='unavailable';$proofCache=@{}
 try{
  if((Get-Item -LiteralPath $RulesPath -ErrorAction Stop).Length -gt 128KB){throw 'Rules exceed size limit'}
  $rules=[IO.File]::ReadAllText($RulesPath)|ConvertFrom-Json -ErrorAction Stop
  if($rules.Schema -ne 1 -or -not $rules.Version -or @($rules.Providers).Count -ne 5){throw 'Invalid rules schema'}
  foreach($provider in $rules.Providers){
   if($provider.Id -notin @('eac','battleye','ea','vanguard','vac') -or -not $provider.Name -or -not $provider.PSObject.Properties['Files'] -or -not $provider.PSObject.Properties['Directories'] -or $provider.Source -notmatch '^https://'){throw 'Malformed provider rule'}
   [void][regex]::new($provider.Signer);[void][regex]::new($provider.Product)
  }
  if(@($rules.Providers.Id|Select-Object -Unique).Count -ne 5){throw 'Duplicate provider rules'}
  foreach($rule in $rules.Providers){foreach($name in @($rule.Files)+@($rule.Directories)){if([string]::IsNullOrWhiteSpace($name) -or [IO.Path]::GetFileName($name) -ne $name -or $name -in @('.','..')){throw 'Invalid provider basename'}}}
  $version=[string]$rules.Version
  if($Cancellation){$Cancellation.RulesVersion=$version}
  if($Target.ScopeBlocked){throw 'Linked installation scope was not scanned'}
  $reviewed=[datetime]::Parse([string]$rules.ReviewedUtc).ToUniversalTime();$stale=([datetime]::UtcNow-$reviewed).TotalDays -gt 180
  $catalogue=@{};$providers=@{}
  foreach($provider in $rules.Providers){$providers[$provider.Id]=$provider}
  foreach($association in $rules.Games){
   if(-not $providers.ContainsKey([string]$association.Provider) -or $association.Source -notmatch '^https://' -or -not $association.Exe -or -not $association.ProductId){throw 'Malformed game association'}
   $lookup=([string]$association.Store+'|'+[string]$association.ProductId+'|'+[string]$association.Exe).ToLowerInvariant()
   if(-not $catalogue.ContainsKey($lookup)){$catalogue[$lookup]=@()}
   $catalogue[$lookup]+=$association
  }
  $lookup=([string]$Target.Store+'|'+[string]$Target.ProductId+'|'+[IO.Path]::GetFileName($Target.Executable)).ToLowerInvariant()
  if($Target.Verified -and $catalogue.ContainsKey($lookup)){foreach($association in $catalogue[$lookup]){
    $provider=$providers[$association.Provider]
    $entryStale=$stale
    if($association.ReviewedUtc){$entryDate=[datetime]::Parse([string]$association.ReviewedUtc).ToUniversalTime();$entryStale=$entryStale -or ([datetime]::UtcNow-$entryDate).TotalDays -gt 180}
    if($association.EffectiveFrom -and [datetime]::Parse($association.EffectiveFrom).ToUniversalTime() -gt [datetime]::UtcNow){continue}
    $hits.Add([pscustomobject]@{Id=$provider.Id;Name=$provider.Name;Strength=$(if($entryStale){'Possible'}else{'Detected'});Path='';Rule=$association.Id;Basis='Official';Corroboration=$(if($entryStale){'Official catalogue review is stale'}else{'Exact store product and rendering executable'});Source=$association.Source;Mode=$association.Mode})
  }}
  if($Cancellation){$Cancellation.Matches=$hits.ToArray()}
  # Prioritise documented game-local locations before the bounded metadata walk.
  $locationBudgetHit=$false
  foreach($rule in $rules.Providers){foreach($name in @($rule.Files)){
   foreach($folder in @('')+@($rule.Directories)){
    if($watch.ElapsedMilliseconds -ge $MaxMilliseconds){$limits.Add('Time limit reached before standard locations were all checked.');$locationBudgetHit=$true;break}
    $relative=if($folder){$folder+'/'+$name}else{$name};$candidate=Join-Path $Target.Root $relative
    try{
     $item=Get-Item -LiteralPath $candidate -ErrorAction Stop
     if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
     if($folder -and ((Get-Item -LiteralPath (Join-Path $Target.Root $folder)).Attributes -band [IO.FileAttributes]::ReparsePoint)){continue}
     $proof=GetAntiCheatFileEvidence $candidate $rule;$proofCache[$candidate+'|'+$rule.Id]=$proof
     $hits.Add([pscustomobject]@{Id=$rule.Id;Name=$rule.Name;Strength=$(if($proof -eq 'Verified provider signature and product metadata'){'Detected'}else{'Possible'});Path=$relative.Replace('/','\');Rule=($rule.Id+'-local');Basis='Local';Corroboration=$proof;Source=$rule.Source;Mode='Component presence does not establish activity.'})
     if($Cancellation){$Cancellation.Matches=$hits.ToArray()}
    }catch [System.Management.Automation.ItemNotFoundException]{}catch{$limits.Add('A provider location could not be checked: '+$relative)}
   }
   if($locationBudgetHit){break}
  }}
  $pending=[Collections.Generic.Queue[object]]::new();if(-not $QuickLocationsOnly){$pending.Enqueue(@($Target.Root,0))}
  while($pending.Count){
   if(($Cancellation -and $Cancellation.Cancelled) -or $watch.ElapsedMilliseconds -ge $MaxMilliseconds){$limits.Add('Check cancelled or elapsed-time limit reached.');break}
   $node=$pending.Dequeue();$directory=[IO.DirectoryInfo]::new([string]$node[0]);$iterator=$null
   try{
    if(-not $directory.Exists){throw 'Folder missing'}
    if($directory.Attributes -band [IO.FileAttributes]::ReparsePoint){$limits.Add('Linked folder was not traversed.');continue}
    $iterator=$directory.EnumerateFileSystemInfos().GetEnumerator()
    while($iterator.MoveNext()){
     if(++$entries -gt $MaxEntries -or $watch.ElapsedMilliseconds -ge $MaxMilliseconds -or ($Cancellation -and $Cancellation.Cancelled)){$limits.Add('Entry/time limit or cancellation interrupted the check.');$pending.Clear();break}
     $entry=$iterator.Current;$relative=$entry.FullName.Substring($Target.Root.Length+1)
     if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){$limits.Add('Linked entry skipped: '+$relative);continue}
     $isDir=($entry.Attributes -band [IO.FileAttributes]::Directory) -ne 0
     # OptiShade-owned data/rollback/report trees are not live game components.
     if($isDir -and $relative -in @($Target.ExcludedDirectories)){continue}
     foreach($rule in $rules.Providers){
      if(($isDir -and $entry.Name -in $rule.Directories) -or (-not $isDir -and $entry.Name -in $rule.Files)){
       $proof=if($isDir){'Directory name only'}elseif($proofCache.ContainsKey($entry.FullName+'|'+$rule.Id)){$proofCache[$entry.FullName+'|'+$rule.Id]}else{GetAntiCheatFileEvidence $entry.FullName $rule}
       $hits.Add([pscustomobject]@{Id=$rule.Id;Name=$rule.Name;Strength=$(if($proof -eq 'Verified provider signature and product metadata'){'Detected'}else{'Possible'});Path=$relative;Rule=($rule.Id+'-local');Basis='Local';Corroboration=$proof;Source=$rule.Source;Mode='Component presence does not establish activity.'})
       if($Cancellation){$Cancellation.Matches=$hits.ToArray()}
      }
     }
     if($isDir){if([int]$node[1] -ge $MaxDepth){$limits.Add('Depth limit reached: '+$relative)}else{$pending.Enqueue(@($entry.FullName,([int]$node[1]+1)))}}
    }
   }catch{$limits.Add('Unreadable scan location: '+[string]$node[0])}finally{if($iterator -is [IDisposable]){$iterator.Dispose()}}
  }
 }catch{$limits.Add('Anti-cheat rules or scan resources could not be read: '+$_.Exception.Message)}
 $state=if(@($hits|Where-Object Strength -eq 'Detected').Count){'Detected'}elseif($hits.Count){'Possible'}elseif($limits.Count){'Check incomplete'}else{'No known indicators'}
 return [pscustomobject]@{Target=$Target;State=$state;RulesVersion=$version;Utc=[datetime]::UtcNow.ToString('o');CheckedRoots=@($Target.Root);Completed=($limits.Count -eq 0);Limitations=@($limits.ToArray()|Select-Object -Unique);Matches=@($hits.ToArray()|Sort-Object Id,Path,Rule -Unique);Entries=$entries}
}
function GetAntiCheatLibraryCardResult($Target,[string]$RulesPath,[int]$MaxMilliseconds=1500,[string]$Folder=''){
 try{
  if(-not $Folder){$Folder=[string]$Target.Root}
  if(-not [IO.Directory]::Exists([string]$Target.Root)){return [pscustomobject]@{Folder=$Folder;Label='Not checked';Detail='The selected game folder is unavailable. The install check must verify it before making changes.';State='Check incomplete';Completed=$false}}
  # Game-library entries already identify a specific game folder. Executable
  # resolution and an exhaustive walk of every vendor/shader directory are not
  # prerequisites for checking standard anti-cheat locations. Keep verified
  # store identity when available for exact catalogue matching, and never turn
  # a missing/unreadable launcher EXE into a scanner failure.
  $scanTarget=[pscustomobject]@{Root=[string]$Target.Root;Executable=[string]$Target.Executable;Name=[string]$Target.Name;Store=[string]$Target.Store;ProductId=[string]$Target.ProductId;Verified=[bool]$Target.Verified;Limitations=@();ExcludedDirectories=@($Target.ExcludedDirectories);ScopeBlocked=[bool]$Target.ScopeBlocked}
  $result=InvokeAntiCheatScanCore $scanTarget $RulesPath -MaxMilliseconds $MaxMilliseconds -QuickLocationsOnly
  $names=@($result.Matches|Select-Object -ExpandProperty Name -Unique) -join ', '
  switch($result.State){
   'Detected' {$label="Detected: $names";$detail='A known anti-cheat provider was identified in this game or its verified catalogue entry.'}
   'Possible' {$label="Possible indicator: $names";$detail='A provider-like file or folder was found but could not be verified. The install check reviews it again before changes.'}
   'No known indicators' {$label='Quick check: none found';$detail='No known provider was found in the quick check of standard locations or an exact verified catalogue entry. This is not a full game-folder scan; the install check reviews the game before changes.'}
   default {$label='Check incomplete';$detail='The quick check could not finish within its time or entry limit. Anti-cheat status is unknown until the install check completes.'}
  }
  return [pscustomobject]@{Folder=$Folder;Label=$label;Detail=$detail;State=[string]$result.State;Completed=[bool]$result.Completed}
 }catch{
  if(-not $Folder){$Folder=[string]$Target.Root}
  return [pscustomobject]@{Folder=$Folder;Label='Check incomplete';Detail='The quick check was unavailable. Anti-cheat status is unknown until the install check completes.';State='Check incomplete';Completed=$false}
 }
}
function InvokeAntiCheatScan($Target,[string]$Game='',[string]$Executable=''){
 if($Game){$Target=[pscustomobject]@{Root=$Game;Executable=$Executable;Name=$Game;Store='';ProductId='';Verified=$false;Limitations=@();ExcludedDirectories=@();ScopeBlocked=$false}}
 $cancel=[hashtable]::Synchronized(@{Cancelled=$false;Matches=@();RulesVersion='unavailable'});$scanWindow=$null;if($script:AntiCheatScanUI){$scanWindow=& $script:AntiCheatScanUI $cancel};$ps=[powershell]::Create();$watch=[Diagnostics.Stopwatch]::StartNew()
 $null=$ps.AddScript('param($file,$target,$rules,$cancel,$game,$exe) . $file; if($game){. (Join-Path (Split-Path $file) ''ownership.ps1''); $target=GetAntiCheatTarget $game $exe; $cancel.Target=$target}; InvokeAntiCheatScanCore $target $rules -Cancellation $cancel').AddArgument($PSCommandPath).AddArgument($Target).AddArgument((Join-Path $PSScriptRoot 'anti-cheat-rules.json')).AddArgument($cancel).AddArgument($Game).AddArgument($Executable)
 $job=$ps.BeginInvoke()
 try{
  while(-not $job.IsCompleted){
   if($script:AntiCheatPump){& $script:AntiCheatPump 'Checking anti-cheat...'}
   if($script:AntiCheatContextValid -and -not(& $script:AntiCheatContextValid)){$cancel.Cancelled=$true}
   if($watch.ElapsedMilliseconds -gt 8000 -or $cancel.Cancelled){break}
   Start-Sleep -Milliseconds 25
  }
  if($job.IsCompleted){$result=@($ps.EndInvoke($job));if($result.Count -and -not $ps.HadErrors){$result[-1]|Add-Member Cancelled ([bool]$cancel.Cancelled) -Force;return $result[-1]}}
  if($cancel.Target){$Target=$cancel.Target}
  $partial=@($cancel.Matches);$partialState=if(@($partial|Where-Object Strength -eq 'Detected').Count){'Detected'}elseif($partial.Count){'Possible'}else{'Check incomplete'}
  return [pscustomobject]@{Target=$Target;Cancelled=[bool]$cancel.Cancelled;State=$partialState;RulesVersion=$cancel.RulesVersion;Utc=[datetime]::UtcNow.ToString('o');CheckedRoots=@($Target.Root);Completed=$false;Limitations=@('The background check timed out, was cancelled or could not complete.');Matches=$partial;Entries=0}
 }finally{if($scanWindow){$scanWindow.Close()};if($job.IsCompleted){$ps.Dispose()}else{$null=$ps.BeginStop($null,$null)}}
}
function GetAntiCheatDecisionKey($Result,[string]$Operation){
 $findings=@($Result.Matches|ForEach-Object {$_.Id+'|'+$_.Strength+'|'+$_.Path+'|'+$_.Rule+'|'+$_.Corroboration}|Sort-Object)
 # Consent describes a target and evidence snapshot, not the UI operation that
 # happened to trigger it. Core install followed by component install is one
 # unchanged risk decision and should not ask twice.
 GetAntiCheatHash (($Result.Target.Root.ToLowerInvariant(),$Result.Target.Executable.ToLowerInvariant(),$Result.Target.Store,$Result.Target.ProductId,$Result.RulesVersion,$Result.State,($findings -join ';'),($Result.Limitations -join ';'),'warning-1') -join "`n")
}
function TestAntiCheatDecisionAccepted($Result){
 if(-not $Result -or -not $Result.Target -or -not $Result.RulesVersion){return $false}
 $state=if($env:OPTISHADE_STORE){$env:OPTISHADE_STORE}else{Join-Path $env:LOCALAPPDATA 'OptiShade'}
 $folder=Join-Path $state 'AntiCheatConsent';if(-not [IO.Directory]::Exists($folder)){return $false}
 $decisionKey=GetAntiCheatDecisionKey $Result ''
 $warningHash=GetAntiCheatHash (GetAntiCheatWarningText $Result)
 $legacyIncompleteWarningHash=GetAntiCheatHash ("No matching anti-cheat provider was identified, but the check is incomplete. This is not a confirmed detection or a guarantee that the game has no anti-cheat.`n`nInstalling or using OptiShade may result in an account suspension or permanent ban.`n`nOptiShade cannot guarantee compatibility or protection against account penalties. By continuing, you acknowledge these risks and accept responsibility for your decision to use OptiShade, to the extent permitted by applicable law.`n`nI understand the risk and choose to proceed.")
 $root=try{[IO.Path]::GetFullPath([string]$Result.Target.Root).TrimEnd('\')}catch{return $false}
 $exe=try{if($Result.Target.Executable){[IO.Path]::GetFullPath([string]$Result.Target.Executable)}else{''}}catch{[string]$Result.Target.Executable}
 foreach($file in @(Get-ChildItem -LiteralPath $folder -File -Filter '*.json' -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 250)){
  try{
   if($file.Length -gt 64KB){continue}
   $saved=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8|ConvertFrom-Json
   if($saved.Outcome -ne 'Accepted' -or [int]$saved.WarningVersion -ne 1 -or [string]$saved.RulesVersion -ne [string]$Result.RulesVersion){continue}
   $savedRoot=[IO.Path]::GetFullPath([string]$saved.Target.Root).TrimEnd('\')
   $savedExe=try{if($saved.Target.Executable){[IO.Path]::GetFullPath([string]$saved.Target.Executable)}else{''}}catch{[string]$saved.Target.Executable}
   if(-not [string]::Equals($savedRoot,$root,[StringComparison]::OrdinalIgnoreCase) -or -not [string]::Equals($savedExe,$exe,[StringComparison]::OrdinalIgnoreCase) -or [string]$saved.Target.Store -ne [string]$Result.Target.Store -or [string]$saved.Target.ProductId -ne [string]$Result.Target.ProductId){continue}
   if($saved.DecisionKey -and [string]$saved.DecisionKey -eq $decisionKey){return $true}
   # Honor older consent files from this release when the exact warning,
   # target, provider evidence, and rules version are unchanged.
   if(-not $saved.DecisionKey -and ([string]$saved.WarningHash -eq $warningHash -or ($Result.State -eq 'Check incomplete' -and [string]$saved.WarningHash -eq $legacyIncompleteWarningHash))){
    $savedProviders=@($saved.Providers|ForEach-Object {([string]$_.Id)+'|'+([string]$_.Strength)+'|'+([string]$_.Rule)+'|'+([string]$_.Path)+'|'+([string]$_.Corroboration)}|Sort-Object)
    $currentProviders=@($Result.Matches|ForEach-Object {([string]$_.Id)+'|'+([string]$_.Strength)+'|'+([string]$_.Rule)+'|'+([string]$_.Path)+'|'+([string]$_.Corroboration)}|Sort-Object)
    if(($savedProviders -join ';') -eq ($currentProviders -join ';')){return $true}
   }
  }catch{}
 }
 return $false
}
function SaveAntiCheatDecision($Result,[string]$Operation,[string]$Outcome){
 $state=if($env:OPTISHADE_STORE){$env:OPTISHADE_STORE}else{Join-Path $env:LOCALAPPDATA 'OptiShade'}
 $folder=Join-Path $state 'AntiCheatConsent';[void][IO.Directory]::CreateDirectory($folder)
 $record=[ordered]@{Utc=[datetime]::UtcNow.ToString('o');Target=$Result.Target;Providers=@($Result.Matches|Select-Object Id,Strength,Rule,Path,Corroboration);RulesVersion=$Result.RulesVersion;WarningVersion=1;WarningHash=(GetAntiCheatHash (GetAntiCheatWarningText $Result));DecisionKey=(GetAntiCheatDecisionKey $Result $Operation);Operation=$Operation;Build='1.0.77';Outcome=$Outcome}
 $dest=Join-Path $folder ([guid]::NewGuid().ToString('N')+'.json');[IO.File]::WriteAllText($dest,($record|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($true))
}
function GetAntiCheatWarningText($Result=$null) {
 $opening=if($Result -and $Result.Matches.Count -and -not @($Result.Matches|Where-Object Basis -ne 'Official').Count){'Official game information identifies this anti-cheat system.'}elseif($Result -and $Result.State -eq 'Possible'){'Possible anti-cheat components were found in this game.'}elseif($Result -and $Result.State -eq 'Check incomplete'){'The anti-cheat check could not finish within its scan limits. Status is unknown; this is not a confirmed detection or a guarantee that the game has no anti-cheat.'}else{'Anti-cheat has been detected in this game.'}
 $opening+"`n`nInstalling or using OptiShade may result in an account suspension or permanent ban.`n`nOptiShade cannot guarantee compatibility or protection against account penalties. By continuing, you acknowledge these risks and accept responsibility for your decision to use OptiShade, to the extent permitted by applicable law.`n`nI understand the risk and choose to proceed."
}
function GetOptiShadeExistingInstallation([string]$Game){
 # Helpers run in fresh processes. A portable store pointer is a lookup hint,
 # never ownership evidence: each canonical receipt must match this exact game.
 try{$root=[IO.Path]::GetFullPath($Game).TrimEnd('\')}catch{return $null}
 $stores=[Collections.Generic.List[string]]::new()
 if($env:OPTISHADE_STORE){$stores.Add($env:OPTISHADE_STORE)}
 try{
  $pointer=OwnedPath $root 'OptiShadeData/dependency-state.ini'
  if((Test-Path -LiteralPath $pointer -PathType Leaf) -and (Get-Item -LiteralPath $pointer).Length -le 64KB){
   $text=[IO.File]::ReadAllText($pointer)
   if($text -match '(?im)^\s*Root\s*=\s*([^\r\n]+)'){$hint=$Matches[1].Trim();if([IO.Path]::IsPathRooted($hint)){$stores.Add($hint)}}
  }
 }catch{}
 $stores.Add((Join-Path $env:LOCALAPPDATA 'OptiShade'))
 foreach($state in @($stores.ToArray()|Select-Object -Unique)){
  try{
   $receipt=ManifestPath $state $root
   if(-not(Test-Path -LiteralPath $receipt -PathType Leaf) -or (Get-Item -LiteralPath $receipt).Length -gt 8MB){continue}
   $m=ReadOptiShadeState $receipt
   if($m.Status -ne 'Installed' -or -not [string]::Equals([IO.Path]::GetFullPath([string]$m.Game).TrimEnd('\'),$root,[StringComparison]::OrdinalIgnoreCase)){continue}
   $files=@($m.Files|Where-Object {$_.Path -and $_.Hash -match '^[a-fA-F0-9]{64}$' -and -not [IO.Path]::IsPathRooted($_.Path) -and $_.Path -notmatch '(^|[\\/])\.\.([\\/]|$)'})
   if($files.Count){return [pscustomobject]@{Store=[IO.Path]::GetFullPath($state);Path=$receipt;Manifest=$m}}
  }catch{}
 }
 return $null
}
function TestAntiCheatExistingInstallation([string]$Game){
 # Maintenance can replace missing/changed files; existing mutation hash guards
 # remain authoritative. A folder name or consent history never grants access.
 return $null -ne (GetOptiShadeExistingInstallation $Game)
}
function AssertAntiCheatMutation([string]$Game,[string]$Executable='',[string]$Operation='Install components'){
 if($script:AntiCheatBindContext){$script:AntiCheatContextValid=& $script:AntiCheatBindContext $Game}
 if($script:AntiCheatContextValid -and -not(& $script:AntiCheatContextValid)){throw 'Installation context changed. Nothing changed.'}
 # Anti-cheat safety is a global install agreement, not a per-game detection
 # claim. Require it before every install, repair, or component mutation.
 EnsureOptiShadeAntiCheatAgreement $null
 # Update batches are covered by the accepted startup agreement. Do not show
 # a second per-game prompt while applying updates; the per-game detection
 # prompt is reserved for new game installs and component installs.
 if($script:AntiCheatUpdateMode){return}
 $scope='installation|'+[IO.Path]::GetFullPath($Game).TrimEnd('\').ToLowerInvariant()
 if($script:AntiCheatOperation -and $script:AntiCheatOperation.Accepted.ContainsKey($scope)){return}
 # Recheck selected installation before mutation; startup consent is not per-game evidence.
 $result=InvokeAntiCheatScan -Game $Game -Executable $Executable
 if($result.Cancelled){throw 'Anti-cheat check cancelled. Nothing changed.'}
 if($result.State -ne 'No known indicators' -and -not (TestAntiCheatGameSuppressed $result) -and -not (TestAntiCheatDecisionAccepted $result)){
  $accepted=if($script:AntiCheatDecision){& $script:AntiCheatDecision $result}else{ConfirmFusionInstall $null $result}
  SaveAntiCheatDecision $result $Operation $(if($accepted){'Accepted'}else{'Cancelled'})
  if(-not $accepted){throw 'Anti-cheat risk was not accepted for this game. Nothing changed.'}
 }
 if($script:AntiCheatContextValid -and -not(& $script:AntiCheatContextValid)){throw 'Installation context changed. Nothing changed.'}
 # Reuse one explicit acceptance for nested mutations in this synchronous action.
 if($script:AntiCheatOperation){$script:AntiCheatOperation.Accepted[$scope]=$true}
}
