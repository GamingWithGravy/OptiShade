# Read-only status work is coalesced off the WPF dispatcher. Mutation paths must
# still read current receipts and verify files inside their own transactions.
function NewOptiShadeManagerStatusState([scriptblock]$StartWorker,[scriptblock]$ReleaseWorker,[scriptblock]$StopWorker){
 [pscustomobject]@{StartWorker=$StartWorker;ReleaseWorker=$ReleaseWorker;StopWorker=$StopWorker;Busy=$false;Pending=$null;Stopped=$false;Generation=0;Key='';Worker=$null;Snapshot=$null;Error='';Completion=$null}
}
function StartOptiShadeManagerStatusPending($State){
 if($State.Stopped -or $State.Busy -or -not $State.Pending){return}
 $pending=$State.Pending;$State.Pending=$null
 try{$worker=& $State.StartWorker $pending.Context;$State.Worker=[pscustomobject]@{Handle=$worker;Context=$pending.Context;Generation=$pending.Generation;StartedUtc=[DateTime]::UtcNow};$State.Busy=$true}
 catch{$State.Error=$_.Exception.GetBaseException().Message;$State.Busy=$false;$State.Worker=$null;$State.Completion=[pscustomobject]@{Context=$pending.Context;Snapshot=$null;Error=$State.Error;Generation=$pending.Generation}}
}
function RequestOptiShadeManagerStatus($State,$Context,[switch]$Force){
 if($State.Stopped){return}
 if(-not $Force -and [string]$State.Key -ceq [string]$Context.Key){return}
 $State.Generation++;$State.Key=[string]$Context.Key;$State.Error=''
 $State.Pending=[pscustomobject]@{Context=$Context;Generation=$State.Generation}
 StartOptiShadeManagerStatusPending $State
}
function ReceiveOptiShadeManagerStatus($State){
 if($State.Stopped){return}
 if($State.Completion){$completion=$State.Completion;$State.Completion=$null;if($completion.Generation -eq $State.Generation){return $completion}}
 if($State.Stopped -or -not $State.Busy -or -not $State.Worker.Handle.Async.IsCompleted){return}
 $active=$State.Worker;$value=$null;$failure=''
 try{$items=@($active.Handle.Shell.EndInvoke($active.Handle.Async));if($items.Count){$value=$items[-1]}else{throw 'The status worker returned no snapshot.'}}
 catch{$failure=$_.Exception.GetBaseException().Message}
 finally{& $State.ReleaseWorker $active.Handle;$State.Worker=$null;$State.Busy=$false}
 $result=$null
 if(-not $State.Stopped -and $active.Generation -eq $State.Generation){
  $State.Error=$failure
  if(-not $failure){$State.Snapshot=$value}
  $result=[pscustomobject]@{Context=$active.Context;Snapshot=$value;Error=$failure;Generation=$active.Generation}
 }
 StartOptiShadeManagerStatusPending $State
 if($result){return $result}
}
# A worker that never completes would leave verification "checking" forever.
# Cancel it after a bounded time and report one ordinary status error.
function StopStalledOptiShadeManagerStatus($State,[TimeSpan]$Limit,[DateTime]$Now=[DateTime]::UtcNow){
 if($State.Stopped -or -not $State.Busy -or -not $State.Worker -or ($Now-$State.Worker.StartedUtc) -lt $Limit){return $false}
 $active=$State.Worker
 try{& $State.StopWorker $active.Handle}catch{}
 $State.Worker=$null;$State.Busy=$false
 $message='Component verification did not finish within '+[int]$Limit.TotalSeconds+' seconds and was stopped. Use Check for updates to retry.'
 if($active.Generation -eq $State.Generation){$State.Error=$message}
 $State.Completion=[pscustomobject]@{Context=$active.Context;Snapshot=$null;Error=$message;Generation=$active.Generation}
 StartOptiShadeManagerStatusPending $State
 return $true
}
# Nothing running, queued or failed, yet the snapshot does not answer the
# latest request: no event will ever complete verification without a new scan.
function TestOptiShadeManagerStatusOrphaned($State){
 if(-not $State -or $State.Stopped -or $State.Busy -or $State.Pending -or $State.Completion -or $State.Error){return $false}
 return -not $State.Snapshot -or [string]$State.Snapshot.Key -cne [string]$State.Key
}
function StopOptiShadeManagerStatus($State){
 if(-not $State -or $State.Stopped){return}
 $State.Stopped=$true;$State.Pending=$null;$State.Completion=$null
 if($State.Worker){& $State.StopWorker $State.Worker.Handle}
 $State.Worker=$null;$State.Busy=$false
}
function GetOptiShadeManagerStatusKey([string]$Folder){
 if([string]::IsNullOrWhiteSpace($Folder)){return ''}
 try{return [IO.Path]::GetFullPath($Folder).TrimEnd('\','/').ToLowerInvariant()}catch{return $Folder.ToLowerInvariant()}
}
function TestOptiShadeOnlineComponentVersionNewer([string]$Latest,[string]$Installed){
 if($Latest -notmatch '^\d+(?:\.\d+){1,3}(?:-[0-9A-Za-z.-]+)?$'){return $false}
 if(-not $Installed -or $Installed -notmatch '^\d+(?:\.\d+){1,3}(?:-[0-9A-Za-z.-]+)?$'){return $true}
 try{$left=[version]($Latest -replace '-.*$','');$right=[version]($Installed -replace '-.*$','');if($left -gt $right){return $true};if($left -lt $right){return $false};return ([bool]($Installed -match '-') -and -not [bool]($Latest -match '-'))}catch{return $false}
}
function AddOptiShadeModularChannelUpdates($Context,$Record){
 $Record|Add-Member -NotePropertyName OnlinePackages -NotePropertyValue @{} -Force
 if(-not $Context.OnlineComponentVersions -or -not $Record.Manifest){return}
 $manifest=$Record.Manifest;$selected=@(GetOptiShadeAddonSelection $manifest)
 $checks=@([pscustomobject]@{Component='Core';Ids=@('OptiShade.Core')})
 foreach($component in @('Effects','OptiMfg','Providers')){if($component -in $selected){$packageId=GetOptiShadeModularUpdatePackageId $component;$checks+=,[pscustomobject]@{Component=$component;Ids=$(if($component -eq 'Providers'){@('OptiShade.Providers.AMD','OptiShade.Providers.Intel')}else{@($packageId)})}}}
 foreach($check in $checks){
  $versions=@($check.Ids|ForEach-Object {if($Context.OnlineComponentVersions.ContainsKey($_)){$Context.OnlineComponentVersions[$_]}})
  if($versions.Count -ne $check.Ids.Count){continue}
  $installed=@($manifest.OnlineComponentPackages|Where-Object {$_ -and [string]$_.Id -in $check.Ids})
  $needsUpdate=$false
  foreach($remote in $versions){$local=@($installed|Where-Object {[string]$_.Id -ceq [string]$remote.Component}|Select-Object -First 1);$localVersion=if($local.Count){[string]$local[0].Version}else{''};if(TestOptiShadeOnlineComponentVersionNewer ([string]$remote.Version) $localVersion){$needsUpdate=$true}}
  if($check.Component -eq 'Core' -or $check.Component -in $Record.Info.Components -or $needsUpdate){
   $packageId=if($check.Component -eq 'Providers'){'OptiShade.Providers'}else{[string](GetOptiShadeModularUpdatePackageId $check.Component)}
   $displayVersion=(@($versions|ForEach-Object {[string]$_.Version}) -join ' / ')
   $Record.OnlinePackages[$check.Component]=[pscustomobject]@{Id=$packageId;Version=$displayVersion;NeedsUpdate=$needsUpdate}
  }
  if($needsUpdate){if($check.Component -eq 'Core'){$Record.Info.Core=$true}else{if($check.Component -notin $Record.Info.Components){$Record.Info.Components+=,$check.Component}}}
 }
 if($Record.Info.Core){$Record.Info.Target='Setup';$Record.Info.Text='Core update available'}elseif($Record.Info.Components.Count){$Record.Info.Target='Components';$Record.Info.Text='Component update available: '+($Record.Info.Components -join ', ')}
}
function GetOptiShadeManagerSnapshotRows($Context,$Record,$Local){
 $game=$Record.Game;$folder=$Record.Folder;$mp=$Record.ManifestPath;$m=$Record.Manifest;$glass=$Record.Glass;$local=$Local
 if(-not $Record.PSObject.Properties['OnlinePackages']){$Record|Add-Member -NotePropertyName OnlinePackages -NotePropertyValue @{} -Force}elseif(-not $Record.OnlinePackages){$Record.OnlinePackages=@{}}
 $labels=@{Core='OptiShade core';Effects='Image effects';OptiMfg='OptiMFG';Neural='Neural rendering';Providers='FSR / XeSS support';Cockpit='Glass cockpit correction';Atmosphere='AtmosphereMod';PackageSet='Local component package set'}
    $ids=@();if($Record.Info.Core){$ids+='Core'};$ids+=@($Record.Info.Components|Where-Object {$_ -ne 'Mfg'});if($glass.Available){$ids+='Cockpit'};if($Record.PSObject.Properties['Atmosphere'] -and $Record.Atmosphere.Available){$ids+='Atmosphere'};if($local.Available){$ids+=[string]$Context.LocalPackage.Catalog.Id}
    foreach($id in @($ids|Select-Object -Unique)){
     $detail=if($id -eq 'Core'){'Installed '+$m.Version+' → Available '+(GetBundledOptiShadeVersion)}elseif($id -eq 'Cockpit'){'Installed '+$glass.InstalledVersion+' → Available '+$glass.LatestVersion}else{'Installed files → components supplied with OptiShade '+(GetBundledOptiShadeVersion)}
     $manual=$id -eq 'Cockpit' -and (-not $Context.Release -or [string]$Context.Release.SHA256 -notmatch '^[a-fA-F0-9]{64}$')
     if($id -eq 'Atmosphere'){$detail='Installed '+$Record.Atmosphere.InstalledVersion+' → Available '+$Record.Atmosphere.LatestVersion+' · Official tomwhoca release'}
     if($id -eq 'Cockpit'){$detail+=' · Official IFreemz addon'};if($manual){$detail+=' · Verified download information unavailable; check for updates again'}
     $localUpdate=$local.Available -and $id -eq $Context.LocalPackage.Catalog.Id
     if($localUpdate){$isPackageSet=[bool]($Context.LocalPackage.PSObject.Properties['Packages'] -and $null -ne $Context.LocalPackage.Packages -and @($Context.LocalPackage.Packages).Count -gt 0);$detail=if($isPackageSet){'Schema-2 set of '+@($Context.LocalPackage.Packages).Count+' packages · complete set staged locally; no game files are changed'}elseif($Context.LocalPackage.Catalog.Schema -eq 2){'Schema-2 local package v'+$Context.LocalPackage.Catalog.Version+' · stage-only pilot; no game files are changed'}else{'Local component package v'+$Context.LocalPackage.Catalog.Version+' · Manager stays '+(GetBundledOptiShadeVersion)}}
     $onlinePackage=if($Record.OnlinePackages.ContainsKey([string]$id)){$Record.OnlinePackages[[string]$id]}else{$null}
     if($onlinePackage -and $onlinePackage.NeedsUpdate){$detail='Installed component package → Available '+[string]$onlinePackage.Version+' · signed channel'}
     [pscustomobject]@{Game=$game;Folder=$folder;ManifestPath=$mp;Id=$id;Label=$labels[$id];Detail=$detail;Manual=$manual;LocalPackage=$localUpdate;OnlinePackageId=$(if($onlinePackage){[string]$onlinePackage.Id}else{''});OnlinePackageVersion=$(if($onlinePackage){[string]$onlinePackage.Version}else{''});Key=$folder.ToLowerInvariant()+'|'+$id}
    }
}
function GetOptiShadeMissingSimulatorReceipt($Game,[string]$Store){
 if(-not (TestFusionMissingSimulatorExecutable $Game)){return $null}
 $folder=ResolveFusionInstallFolder ([string]$Game.Folder)
 $manifestPath=ManifestPath $Store $folder
 if(-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)){return $null}
 $manifest=ReadOptiShadeState $manifestPath
 if($manifest.Status -cne 'Installed' -or (GetOptiShadeManagerStatusKey ([string]$manifest.Game)) -cne (GetOptiShadeManagerStatusKey $folder)){return $null}
 return [pscustomobject]@{Folder=$folder;ManifestPath=$manifestPath;Manifest=$manifest;Message='The game executable is missing, but OptiShade files and restore data remain. Use Remove in the Library to restore the original files and clear this stale entry.'}
}
function InvokeOptiShadeManagerSnapshot($Context){
 $ErrorActionPreference='Stop'
 if(-not @($Context.Games).Count){return [pscustomobject]@{ByPath=@{};Rows=@();GlassTargets=@();AtmosphereTargets=@();LocalCompatibility=@();Errors=@();Key=$Context.Key;Gpu=$Context.Gpu}}
 foreach($module in @('ownership','effects','nvidia','neural-download','library','components','component-packages','glass-cockpit-update','atmosphere-mod','compatibility','updates','mfg')){. (Join-Path $Context.ModuleRoot ($module+'.ps1'))}
 # The same checker is used by actual updates. This copy runs in this worker's
 # isolated runspace; UI callbacks never invoke it to render status.
 . ([scriptblock]::Create('function GetComponentUpdateIds {'+$Context.ComponentCheck+'}'))
 $Payload=$Context.Payload;$store=$Context.Store;$script:localComponentPackage=$Context.LocalPackage
 $script:bundleCatalog=$null
 $detectedGpu=$Context.Gpu
 if(-not $detectedGpu -or $detectedGpu.Names -in @('Checking','Unavailable','')){try{$detectedGpu=GetFusionGpu}catch{$detectedGpu=[pscustomobject]@{Names='Unavailable';Known=$false;Nvidia=$false}}}
 # Hardware is invariant across this read-only scan, even when the checker
 # consults provider policy for several files and games.
 function GetFusionGpu {return $detectedGpu}
 $byPath=@{};$rows=[Collections.Generic.List[object]]::new();$glassTargets=[Collections.Generic.List[object]]::new();$atmosphereTargets=[Collections.Generic.List[object]]::new();$compatibility=[Collections.Generic.List[object]]::new();$errors=[Collections.Generic.List[string]]::new()
 $labels=@{Core='OptiShade core';Effects='Image effects';Neural='Neural rendering';Providers='FSR / XeSS support';Cockpit='Glass cockpit correction'}
 # The manager reads this while the scan runs, to show which game is being checked.
 $progress=if($Context.PSObject.Properties['Progress']){$Context.Progress}else{$null}
 if($progress){$progress.Total=@($Context.Games).Count;$progress.Done=0}
 foreach($game in $Context.Games){
  if($progress){$progress.Current=[string]$game.Name}
  $folder=[string]$game.Folder
  $record=[pscustomobject]@{Game=$game;Folder=$folder;Manifest=$null;ManifestPath='';State='Checking installation';Info=[pscustomobject]@{Core=$false;Components=@();Target='';Text=''};Glass=$null;Atmosphere=$null;RuntimeState='Checking';MfgRoute='';MfgPreparationRoute='';MfgCanInstall=$false;MfgAdmissionState='checking';MfgAdmissionReason='';MfgLoaderAvailable=$null;MfgLoaderReason='';GameApi=$null;LegacyWrapper=$false;InstalledLoader='';CockpitAvailable=$false;FreeSpace='Checking';DetailReady=$false;Error=''}
  try{
   $missingSimulator=GetOptiShadeMissingSimulatorReceipt $game $store
   if($missingSimulator){
    $record.Folder=$missingSimulator.Folder;$record.ManifestPath=$missingSimulator.ManifestPath;$record.Manifest=$missingSimulator.Manifest
    $record.State='Game executable missing';$record.GameMissing=$true;$record.Error=$missingSimulator.Message
    $key=GetOptiShadeManagerStatusKey $game.Folder;$byPath[$key]=$record;$byPath[(GetOptiShadeManagerStatusKey $folder)]=$record
    continue
   }
   $folder=GetFusionGameTargetFolder $game $store;$record.Folder=$folder
   $record.State=GetFusionInstallState $store $folder
   $mp=ManifestPath $store $folder;$record.ManifestPath=$mp
   if(Test-Path -LiteralPath $mp -PathType Leaf){
    $manifest=ReadOptiShadeState $mp
    if((GetOptiShadeManagerStatusKey $manifest.Game) -ne (GetOptiShadeManagerStatusKey $folder)){throw 'The saved receipt belongs to another installation. Rescan or repair this game.'}
    $record.Manifest=$manifest
   }
   $m=$record.Manifest
   if($m -and $m.Status -eq 'Installed'){
    if($Context.ModularDistribution){
     # A payload-free manager has no local files.json catalogue. Online
     # signed-channel checks below are its only source for first-party updates.
     $record.Info.Core=$false;$record.Info.Components=@()
    }else{
     $record.Info.Core=[bool](TestBundledUpdateVersion $m);$record.Info.Components=@(GetComponentUpdateIds $m|Where-Object {$_ -ne 'Mfg'})
    }
    if($record.Info.Core){$record.Info.Target='Setup';$record.Info.Text='Core update available'}elseif($record.Info.Components.Count){$record.Info.Target='Components';$record.Info.Text='Component update available: '+($record.Info.Components -join ', ')}
    if($Context.ModularDistribution){AddOptiShadeModularChannelUpdates $Context $record}
    $glass=GetGlassCockpitUpdateInfo $m $Context.Release;$record.Glass=$glass
    if($glass.Installed){$glassTargets.Add([pscustomobject]@{Game=$game;Manifest=$m;Info=$glass})}
    $atmosphereRelease=if($Context.PSObject.Properties['AtmosphereRelease']){$Context.AtmosphereRelease}else{$null}
    $record.Atmosphere=GetAtmosphereModUpdateInfo (GetAtmosphereModState $folder) $atmosphereRelease
    if($record.Atmosphere.Installed){$atmosphereTargets.Add([pscustomobject]@{Game=$game;Info=$record.Atmosphere})}
    $local=GetLocalComponentPackageState $m $Context.LocalPackage
    if($Context.LocalPackage){
     $installed=@($m.ComponentPackages|Where-Object {$_.Id -eq $Context.LocalPackage.Catalog.Id});$version=if($installed.Count){'Installed component v'+$installed[0].Version+' · '}else{''}
     $message=if($local.Staged){'Staged locally; provenance is unverified and game files were not changed'}elseif($local.Available){'Update available above'}elseif($local.Installed){'Package files already installed'}else{$local.Reason}
     $compatibility.Add([pscustomobject]@{Text=$game.Name+' · '+$version+$message;Error=$false})
    }
    foreach($row in @(GetOptiShadeManagerSnapshotRows $Context $record $local)){$rows.Add($row)}
    if((GetOptiShadeManagerStatusKey $folder) -eq (GetOptiShadeManagerStatusKey $Context.SelectedFolder) -or (GetOptiShadeManagerStatusKey $game.Folder) -eq (GetOptiShadeManagerStatusKey $Context.SelectedFolder)){
     $gpu=$detectedGpu
     $record.RuntimeState=(GetNeuralRuntimeStatus $m.Game $gpu $m).State
     # The legacy component is retired; old receipts remain available to the
     # transactional removal path but are not probed, updated, or advertised.
     if($m.Architecture -eq 'x86'){
      if($m.LaunchExe){$record.GameApi=GetOptiShadeExecutableIdentity ([string]$m.LaunchExe)}
      $record.LegacyWrapper=TestOptiShadeLegacyD3D9Wrapper $m.Game;$record.InstalledLoader=GetOptiShadeInstalledLoaderPath $m
     }
     $record.CockpitAvailable=Test-Path -LiteralPath (Join-Path $m.Game 'FlightSimulator2024.exe') -PathType Leaf
     try{$drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($folder));$record.FreeSpace=('{0:N1} GB' -f ($drive.AvailableFreeSpace/1GB))}catch{$record.FreeSpace='Unavailable'}
     $record.DetailReady=$true
    }
   }
  }catch{$record.Error=$_.Exception.Message;$record.State='Installation needs attention';$errors.Add($game.Name+': '+$record.Error);if($Context.LocalPackage){$compatibility.Add([pscustomobject]@{Text=$game.Name+' · Could not read installation: '+$record.Error;Error=$true})}}
  $byPath[(GetOptiShadeManagerStatusKey $game.Folder)]=$record
  $byPath[(GetOptiShadeManagerStatusKey $folder)]=$record
  if($progress){$progress.Done=[int]$progress.Done+1}
 }
 [pscustomobject]@{ByPath=$byPath;Rows=$rows.ToArray();GlassTargets=$glassTargets.ToArray();AtmosphereTargets=$atmosphereTargets.ToArray();LocalCompatibility=$compatibility.ToArray();Errors=$errors.ToArray();Key=$Context.Key;Gpu=$detectedGpu}
}
