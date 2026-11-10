. "$PSScriptRoot/anti-cheat.ps1"
# Local, explicitly selected component patches. No network credentials or downloaded code.
# Schema 1 replaces existing immutable owned files only; layout/provider migrations
# still belong to the installer. Hashes prove integrity, not publisher identity.
function ReadLocalComponentPackage([string]$Folder){
 $root=FullPath $Folder
 $catalog=OwnedPath $root 'component-package.json'
 $p=ReadOptiShadeJson $catalog 'Local component package' -Shape Object
 if($p.Schema -ne 1 -or $p.Id -notin @('Core','Effects','Neural','Providers') -or $p.Architecture -notin @('x86','x64')){throw 'Unsupported component package schema, component or architecture.'}
 if([string]$p.Version -notmatch '^\d+\.\d+\.\d+$' -or [string]$p.ManagerVersion -notmatch '^P?\d+\.\d+\.\d+(?:-beta\.\d+)?$'){throw 'Invalid component or manager version.'}
 if([string]$p.ManagerVersion -ne (GetBundledOptiShadeVersion)){throw 'This component package requires manager '+$p.ManagerVersion+'.'}
 if(@($p.Files).Count -lt 1 -or @($p.Files).Count -gt 2048){throw 'Invalid component file count.'}
 $seen=@{}
 foreach($f in $p.Files){
  $rel=([string]$f.Path).Replace('\','/')
  if($seen.ContainsKey($rel) -or (GetOptiShadeAddonId $rel) -ne $p.Id -or [IO.Path]::GetExtension($rel) -notin @('.dll','.exe','.addon32','.addon64','.fx','.fxh','.png','.dds')){throw 'Unsupported or duplicate component file: '+$rel}
  $seen[$rel]=$true
  if([string]$f.Hash -notmatch '^[a-fA-F0-9]{64}$' -or [string]$f.PreviousHash -notmatch '^[a-fA-F0-9]{64}$' -or $f.Hash -eq $f.PreviousHash){throw 'Invalid component file hashes.'}
  if((HashFile (OwnedPath $root $rel)) -ne $f.Hash){throw 'Component package verification failed: '+$rel}
 }
 return [pscustomobject]@{Root=$root;Identity=(HashFile $catalog);Catalog=$p}
}
function ReadLocalComponentPackageCandidate([string]$Folder){
 $root=FullPath $Folder;$catalogPath=OwnedPath $root 'component-package.json'
 $p=ReadOptiShadeJson $catalogPath 'Local component package' -Shape Object -MaxBytes 524288
 if($p.Schema -eq 1){return ReadLocalComponentPackage $root}
 if($p.Schema -ne 2 -or [string]$p.ComponentId -notin @('OptiShade.Core','OptiShade.Effects','OptiShade.Neural','OptiShade.Providers')){throw 'Unsupported local component package schema or component.'}
 $id=([string]$p.ComponentId).Substring('OptiShade.'.Length)
 $p|Add-Member -NotePropertyName Id -NotePropertyValue $id -Force
 return [pscustomobject]@{Root=$root;Identity=(HashFile $catalogPath);Catalog=$p;Schema=2;ComponentId=[string]$p.ComponentId;Stage=$null;StageCacheRoot=''}
}
# Schema 2 is a catalog/read-only planning format in this pilot. The existing
# mutation entry point above intentionally remains schema-1-only until a
# reviewed dependency resolver and transactional writer are implemented.
function ConvertToLocalComponentSemVersion([string]$Value,[bool]$AllowPrivatePrefix=$false){
 $prefix=if($AllowPrivatePrefix){'P?'}else{''}
 if($Value -notmatch ('^'+$prefix+'(?<Major>0|[1-9]\d*)\.(?<Minor>0|[1-9]\d*)\.(?<Patch>0|[1-9]\d*)(?:-(?<Stage>alpha|beta|rc)\.(?<StageNumber>0|[1-9]\d*))?$')){return $null}
 return [pscustomobject]@{Major=[long]$Matches.Major;Minor=[long]$Matches.Minor;Patch=[long]$Matches.Patch;Stage=[string]$Matches.Stage;StageNumber=$(if($Matches.StageNumber){[long]$Matches.StageNumber}else{0})}
}
function CompareLocalComponentSemVersion($Left,$Right){
 foreach($part in @('Major','Minor','Patch')){if([long]$Left.$part -lt [long]$Right.$part){return -1};if([long]$Left.$part -gt [long]$Right.$part){return 1}}
 if(-not $Left.Stage -and $Right.Stage){return 1};if($Left.Stage -and -not $Right.Stage){return -1}
 if($Left.Stage -and $Right.Stage){$rank=@{alpha=0;beta=1;rc=2};if($rank[$Left.Stage] -lt $rank[$Right.Stage]){return -1};if($rank[$Left.Stage] -gt $rank[$Right.Stage]){return 1};if([long]$Left.StageNumber -lt [long]$Right.StageNumber){return -1};if([long]$Left.StageNumber -gt [long]$Right.StageNumber){return 1}}
 return 0
}
function TestLocalComponentPackageReparseFreePath([string]$Root,[string]$Relative){
 $rootItem=Get-Item -LiteralPath $Root -Force;if($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Component package roots cannot be reparse points.'}
 $full=OwnedPath $Root $Relative;$rootFull=(FullPath $Root).TrimEnd('\')+'\';$fullFull=FullPath $full
 if(-not $fullFull.StartsWith($rootFull,[StringComparison]::OrdinalIgnoreCase)){throw 'Component package path escaped its root.'}
 $cursor=$rootFull.TrimEnd('\')
 foreach($part in $fullFull.Substring($rootFull.Length).Split('\')){$cursor=Join-Path $cursor $part;if(Test-Path -LiteralPath $cursor){$item=Get-Item -LiteralPath $cursor -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Component package cannot contain reparse points: '+$Relative}}}
 return $fullFull
}
function GetOptiShadeComponentStageRoot{
 $local=[Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
 if([string]::IsNullOrWhiteSpace($local)){throw 'The local application-data path is unavailable.'}
 return Join-Path $local 'OptiShade/Staging/ComponentPackages'
}
function GetLocalComponentApprovalStatus($Plan,$Stage=$null){
 $allowed=@('not-applicable','research','available','blocked','verified','staged','applied','pending-restart','rollback-required')
 $state='blocked';$reason='The component plan is unavailable.';$identity=''
 if($Plan){$identity=[string]$Plan.Identity;$reason=[string]$Plan.Reason
  switch([string]$Plan.State){
   'research'{$state='research'}
   'available-read-only'{$state='available'}
   'installed-read-only'{$state='verified'}
   'blocked'{$state='blocked'}
   default{$state='not-applicable'}
  }
  if($Stage){if([string]$Stage.State -eq 'staged' -and [string]$Stage.Identity -ceq $identity){$state='staged';$reason='Package payloads are hash-verified in the local staging cache; provenance remains unverified.'}else{$state='blocked';$reason='Staging identity does not match the approved component plan.'}}
 }
 if($state -notin $allowed){throw 'Unsupported component update lifecycle state.'}
 return [pscustomobject]@{State=$state;Reason=$reason;Identity=$identity;ReadOnly=$true;MutationsAllowed=$false;ProvenanceVerified=$false}
}
function TestLocalComponentPackageSelectionSet($Package){
 return [bool]($Package -and $Package.PSObject.Properties['Packages'] -and $null -ne $Package.Packages -and @($Package.Packages).Count -gt 0)
}
function StageLocalComponentPackage([string]$Folder,$Plan,[string]$CacheRoot,[long]$MaximumBytes=536870912,[scriptblock]$CopyAction=$null,[long]$MaximumCacheBytes=2147483648){
 if(-not $Plan -or $Plan.Schema -ne 2 -or -not $Plan.ReadOnly -or $Plan.MutationsAllowed -or $Plan.ProvenanceVerified -or $Plan.State -notin @('available-read-only','installed-read-only')){throw 'Only a verified schema-2 read-only package plan can be staged.'}
 if($MaximumBytes -lt 1 -or $MaximumBytes -gt 2147483648 -or $MaximumCacheBytes -lt 1 -or $MaximumCacheBytes -gt 34359738368){throw 'Invalid component staging size limit.'}
 $root=FullPath $Folder;$catalogPath=TestLocalComponentPackageReparseFreePath $root 'component-package.json'
 if((HashFile $catalogPath) -cne [string]$Plan.Identity){throw 'The component package changed after planning. Select it again.'}
 $catalog=ReadOptiShadeJson $catalogPath 'Local component stage' -Shape Object -MaxBytes 524288
 if($catalog.Schema -ne 2 -or [string]$catalog.ComponentId -cne [string]$Plan.ComponentId -or [string]$catalog.Version -cne [string]$Plan.Version){throw 'The component package identity no longer matches its plan.'}
 $files=@([pscustomobject]@{Path='component-package.json';Sha256=[string]$Plan.Identity;Size=(Get-Item -LiteralPath $catalogPath).Length})
 $noticePath=[string]$catalog.Provenance.LicensePath
 if([string]::IsNullOrWhiteSpace($noticePath)){throw 'The package legal notice path is missing.'}
 $files+=@([pscustomobject]@{Path=$noticePath;Sha256=[string]$catalog.Provenance.LicenseSha256;Size=0L})
 foreach($entry in @($catalog.Files)){$files+=@([pscustomobject]@{Path=([string]$entry.Path).Replace('\','/');Sha256=[string]$entry.Sha256;Size=[long]$entry.Size})}
 $seen=@{};$total=0L
 foreach($entry in $files){$key=([string]$entry.Path).ToLowerInvariant();if($seen.ContainsKey($key)){throw 'The component package contains duplicate stage paths.'};$seen[$key]=$true
  if([string]$entry.Sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $entry.Size -lt 0){throw 'The component package has an invalid staged file identity.'}
  $source=TestLocalComponentPackageReparseFreePath $root ([string]$entry.Path)
  if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw 'A component staging input is missing: '+$entry.Path}
  $info=Get-Item -LiteralPath $source -Force;$size=[long]$info.Length;if($entry.Size -gt 0 -and $size -ne $entry.Size){throw 'A component staging input has the wrong size: '+$entry.Path}
  if((HashFile $source) -cne [string]$entry.Sha256){throw 'A component staging input failed SHA-256 verification: '+$entry.Path}
  $total+=$size;if($total -gt $MaximumBytes){throw 'The component package exceeds the staging cache size limit.'}
  $entry.Size=$size
 }
 $cache=if([string]::IsNullOrWhiteSpace($CacheRoot)){GetOptiShadeComponentStageRoot}else{FullPath $CacheRoot};[void][IO.Directory]::CreateDirectory($cache)
 $cacheItem=Get-Item -LiteralPath $cache -Force;if($cacheItem.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Component stage cache cannot be a reparse point.'}
 $cacheFull=FullPath $cache;$cachePrefix=$cacheFull.TrimEnd('\')+'\'
 foreach($partial in @(Get-ChildItem -LiteralPath $cache -Directory -Force|Where-Object {$_.Name -like '.stage-*'})){
  if($partial.Name -notmatch '^\.stage-[a-fA-F0-9]{32}$' -or ($partial.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not(FullPath $partial.FullName).StartsWith($cachePrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'An unexpected partial component stage requires manual review.'}
  Remove-Item -LiteralPath $partial.FullName -Recurse -Force
 }
 $cacheBytes=0L
 foreach($item in @(Get-ChildItem -LiteralPath $cache -Force -Recurse)){
  if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Component stage cache contains a reparse point.'}
  if(-not $item.PSIsContainer){$cacheBytes+=[long]$item.Length;if($cacheBytes -gt $MaximumCacheBytes){throw 'Existing component stages exceed the cache size limit.'}}
 }
 $identity=[string]$Plan.Identity;$destination=Join-Path $cache $identity.ToLowerInvariant()
 if(-not(Test-Path -LiteralPath $destination) -and ($cacheBytes+$total) -gt $MaximumCacheBytes){throw 'The verified package would exceed the component stage cache size limit.'}
 if(Test-Path -LiteralPath $destination){
  $receiptPath=Join-Path $destination 'stage-receipt.json';if(-not(Test-Path -LiteralPath $receiptPath -PathType Leaf)){throw 'An incomplete component stage already occupies this package identity.'}
  $receipt=ReadOptiShadeJson $receiptPath 'Component stage receipt' -Shape Object -MaxBytes 262144
  if([string]$receipt.CatalogSha256 -cne $identity -or @($receipt.Files).Count -ne $files.Count){throw 'The existing component stage receipt is inconsistent.'}
  foreach($entry in $files){$staged=TestLocalComponentPackageReparseFreePath $destination ([string]$entry.Path);if(-not(Test-Path -LiteralPath $staged -PathType Leaf) -or (HashFile $staged) -cne [string]$entry.Sha256){throw 'The existing component stage failed revalidation: '+$entry.Path}}
  return [pscustomobject]@{State='staged';Root=$destination;Identity=$identity;Bytes=$total;Files=$files;ProvenanceVerified=$false;Reused=$true}
 }
 $temp=Join-Path $cache ('.stage-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($temp);$committed=$false
 try{
  foreach($entry in $files){$source=TestLocalComponentPackageReparseFreePath $root ([string]$entry.Path);$target=TestLocalComponentPackageReparseFreePath $temp ([string]$entry.Path);[void][IO.Directory]::CreateDirectory((Split-Path -Parent $target));if($CopyAction){& $CopyAction $source $target}else{Copy-Item -LiteralPath $source -Destination $target}
   if((Get-Item -LiteralPath $target).Length -ne [long]$entry.Size -or (HashFile $target) -cne [string]$entry.Sha256){throw 'A component staging copy failed verification: '+$entry.Path}}
  $receipt=[pscustomobject]@{Schema=1;CatalogSha256=$identity;ComponentId=[string]$Plan.ComponentId;Version=[string]$Plan.Version;StagedUtc=[DateTime]::UtcNow.ToString('o');Bytes=$total;ProvenanceVerified=$false;Files=@($files|ForEach-Object {[pscustomobject]@{Path=$_.Path;Sha256=$_.Sha256;Size=$_.Size}})}
  [IO.File]::WriteAllText((Join-Path $temp 'stage-receipt.json'),($receipt|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
  $stageBytes=0L;foreach($stagedFile in @(Get-ChildItem -LiteralPath $temp -File -Force -Recurse)){$stageBytes+=[long]$stagedFile.Length};if(($cacheBytes+$stageBytes) -gt $MaximumCacheBytes){throw 'The verified package would exceed the component stage cache size limit.'}
  Move-Item -LiteralPath $temp -Destination $destination|Out-Null;$committed=$true
  return [pscustomobject]@{State='staged';Root=$destination;Identity=$identity;Bytes=$total;Files=$files;ProvenanceVerified=$false;Reused=$false}
 }finally{if(-not $committed -and (Test-Path -LiteralPath $temp) -and (FullPath $temp).StartsWith((FullPath $cache).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $temp -Recurse -Force}}
}
function StageLocalComponentPackageSet([string[]]$Folders,$Manifest,$Plan,[string]$CacheRoot,[long]$MaximumBytes=536870912,[scriptblock]$CopyAction=$null,[long]$MaximumCacheBytes=2147483648){
 if(-not $Plan -or $Plan.Schema -ne 2 -or -not $Plan.ReadOnly -or $Plan.MutationsAllowed -or $Plan.ProvenanceVerified -or $Plan.State -ne 'available-read-only' -or @($Plan.Packages).Count -ne @($Folders).Count){throw 'Only a complete available schema-2 read-only package-set plan can be staged.'}
 if($MaximumBytes -lt 1 -or $MaximumBytes -gt 2147483648){throw 'Invalid component set staging size limit.'}
 $fresh=GetLocalComponentPackageSetReadOnlyPlan $Folders $Manifest
 if($fresh.State -cne 'available-read-only' -or [string]$fresh.Identity -cne [string]$Plan.Identity){throw 'The component set changed after planning. Select the complete set again.'}
 $cache=if([string]::IsNullOrWhiteSpace($CacheRoot)){GetOptiShadeComponentStageRoot}else{FullPath $CacheRoot}
 $stages=@();$total=0L
 try{
  for($i=0;$i -lt $fresh.Packages.Count;$i++){
   $candidate=$fresh.Packages[$i];$packagePlan=$fresh.Plans[$i];$remaining=$MaximumBytes-$total
   if($remaining -lt 1){throw 'The complete component set exceeds the staging cache size limit.'}
   $stage=StageLocalComponentPackage $candidate.Root $packagePlan $cache $remaining $CopyAction $MaximumCacheBytes
   $stages+=,$stage;$total+=[long]$stage.Bytes
  }
  if($total -gt $MaximumBytes){throw 'The complete component set exceeds the staging cache size limit.'}
  return [pscustomobject]@{State='staged';Identity=[string]$fresh.Identity;Packages=@($stages);Bytes=$total;ProvenanceVerified=$false;ReadOnly=$true;MutationsAllowed=$false}
 }catch{
  $failure=$_
  foreach($stage in @($stages|Where-Object {-not $_.Reused})){
   try{
    $stageRoot=FullPath ([string]$stage.Root);$expected=FullPath (Join-Path $cache ([string]$stage.Identity).ToLowerInvariant());$cachePrefix=(FullPath $cache).TrimEnd('\')+'\'
    if($stageRoot -ceq $expected -and $stageRoot.StartsWith($cachePrefix,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $stageRoot -PathType Container)){
     $receipt=ReadOptiShadeJson (Join-Path $stageRoot 'stage-receipt.json') 'Component stage rollback receipt' -Shape Object -MaxBytes 262144
     if([string]$receipt.CatalogSha256 -ceq [string]$stage.Identity){Remove-Item -LiteralPath $stageRoot -Recurse -Force}
    }
   }catch{}
  }
  throw $failure
 }
}
function TestLocalComponentPackageSetContract([object[]]$PackageSet){
 if(@($PackageSet).Count -lt 1 -or @($PackageSet).Count -gt 4){return 'Select between one and four schema-2 component packages.'}
 $byId=@{}
 foreach($candidate in $PackageSet){
  if(-not $candidate -or $candidate.Schema -ne 2 -or [string]$candidate.ComponentId -notin @('OptiShade.Core','OptiShade.Effects','OptiShade.Neural','OptiShade.Providers')){return 'Every package in a component set must be a valid schema-2 candidate.'}
  if($byId.ContainsKey([string]$candidate.ComponentId)){return 'A component set cannot contain duplicate component identities.'}
  $byId[[string]$candidate.ComponentId]=$candidate
 }
 foreach($candidate in $PackageSet){
  $catalog=$candidate.Catalog
  foreach($requirement in @($catalog.Requires)){
   $component=[string]$requirement.ComponentId;$version=[string]$requirement.Version;$contract=[string]$requirement.Contract
   if($component -notin @('OptiShade.Core','OptiShade.Effects','OptiShade.Neural','OptiShade.Providers') -or $component -ceq [string]$candidate.ComponentId -or $version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$' -or $contract -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,63}$'){return ('Package '+$candidate.ComponentId+' has an invalid exact dependency declaration.')}
   if(-not $byId.ContainsKey($component)){return ('Dependency set is incomplete: '+$candidate.ComponentId+' requires '+$component+' '+$version+' ('+$contract+').')}
   $dependency=$byId[$component];$provides=@($dependency.Catalog.Provides|ForEach-Object {if($_ -is [string]){[string]$_}elseif($_.Contract){[string]$_.Contract}})
   if([string]$dependency.Catalog.Version -cne $version -or $contract -cnotin $provides){return ('Dependency contract mismatch: '+$candidate.ComponentId+' requires '+$component+' '+$version+' ('+$contract+').')}
  }
  if($catalog.AtomicGroup){
   $groupId=[string]$catalog.AtomicGroup.Id;$members=@($catalog.AtomicGroup.Members|ForEach-Object {[string]$_}|Sort-Object -Unique)
   if($groupId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or $members.Count -lt 2 -or @($catalog.AtomicGroup.Members).Count -ne $members.Count -or @($members|Where-Object {$_ -notin @('OptiShade.Core','OptiShade.Effects','OptiShade.Neural','OptiShade.Providers')}).Count){return ('Package '+$candidate.ComponentId+' has an invalid atomic compatibility group.')}
   if([string]$candidate.ComponentId -notin $members){return ('Atomic group '+$groupId+' does not include '+$candidate.ComponentId+'.')}
   foreach($member in $members){
    if(-not $byId.ContainsKey($member)){return ('Atomic group '+$groupId+' is incomplete; missing '+$member+'.')}
    $other=$byId[$member].Catalog.AtomicGroup
    if(-not $other){return ('Atomic group '+$groupId+' is not declared consistently by every package.')}
    $otherMembers=@($other.Members|ForEach-Object {[string]$_}|Sort-Object -Unique)
    if([string]$other.Id -cne $groupId -or (Compare-Object $members $otherMembers)){return ('Atomic group '+$groupId+' is not declared consistently by every package.')}
   }
  }
 }
 return ''
}
function GetLocalComponentPackageSetReadOnlyPlan([string[]]$Folders,$Manifest){
 $candidates=@()
 foreach($folder in $Folders){$candidate=ReadLocalComponentPackageCandidate $folder;if($candidate.Schema -ne 2){throw 'Multi-package planning accepts schema-2 packages only.'};$candidates+=,$candidate}
 $contractError=TestLocalComponentPackageSetContract $candidates
 $result=[pscustomobject]@{Schema=2;State='blocked';Reason='';Packages=@($candidates);Plans=@();ReadOnly=$true;MutationsAllowed=$false;ProvenanceVerified=$false;Identity=''}
 if($contractError){$result.Reason=$contractError;return $result}
 $plans=@()
 foreach($candidate in $candidates){
  $plan=GetLocalComponentPackageReadOnlyPlan $candidate.Root $Manifest $candidates;$plans+=,$plan
  if($plan.State -ceq 'blocked'){$result.Reason=([string]$candidate.ComponentId+': '+[string]$plan.Reason);$result.Plans=$plans;return $result}
 }
 $result.Plans=$plans;$result.Identity=(@($candidates|ForEach-Object {[string]$_.Identity}|Sort-Object) -join ':')
 if(@($plans|Where-Object {$_.State -ceq 'research'}).Count){$result.State='research';$result.Reason='At least one package is marked research-only; the set is never activated by this planner.';return $result}
 if(@($plans|Where-Object {$_.State -eq 'available-read-only'}).Count){$result.State='available-read-only';$result.Reason='All declared dependencies and atomic groups resolve within this explicitly selected package set. Preconditions match; this planner cannot apply files.';return $result}
 $result.State='installed-read-only';$result.Reason='All packages in this set already match their installed immutable-owned files.';return $result
}
function GetLocalComponentPackageReadOnlyPlan([string]$Folder,$Manifest,[object[]]$PackageSet=@()){
 $root=FullPath $Folder;$catalogPath=OwnedPath $root 'component-package.json';$p=ReadOptiShadeJson $catalogPath 'Local component package plan' -Shape Object -MaxBytes 524288
 if($p.Schema -ne 2 -or [string]$p.ComponentId -notin @('OptiShade.Core','OptiShade.Effects','OptiShade.Neural','OptiShade.Providers') -or [string]$p.Architecture -notin @('x86','x64')){throw 'Unsupported read-only component plan schema, identity or architecture.'}
 $id=([string]$p.ComponentId).Substring('OptiShade.'.Length)
 if([string]$p.Version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$' -or [string]$p.Channel -notin @('stable-verified','private-candidate','research-only')){throw 'Invalid schema-2 component version or release channel.'}
 $min=ConvertToLocalComponentSemVersion ([string]$p.ManagerRange.MinInclusive);$max=ConvertToLocalComponentSemVersion ([string]$p.ManagerRange.MaxExclusive)
 if(-not $min -or -not $max -or (CompareLocalComponentSemVersion $min $max) -ge 0){throw 'Invalid schema-2 manager version range.'}
 $contracts=$p.Contracts
 if([string]$contracts.PackageCatalog -cne 'local-component-package/v2' -or [string]$contracts.FileOwnership -cne 'immutable-owned-file/v1'){throw 'Schema-2 package or ownership contract is unknown.'}
 $repoRoot=Split-Path $PSScriptRoot -Parent;$bridgePath=Join-Path $repoRoot 'shared/EffectsBridge.h';$runtimePath=Join-Path $PSScriptRoot 'RuntimeControlClient.cs';$policyPath=Join-Path $PSScriptRoot 'provider-policy.json'
 $bridgeMatch=[regex]::Match([IO.File]::ReadAllText($bridgePath),'constexpr\s+uint32_t\s+Version\s*=\s*(\d+)');$runtimeMatch=[regex]::Match([IO.File]::ReadAllText($runtimePath),'const\s+int\s+ProtocolSchema\s*=\s*(\d+)')
 if(-not $bridgeMatch.Success -or -not $runtimeMatch.Success -or [string]$contracts.NativeBridgeAbi -cne $bridgeMatch.Groups[1].Value -or [string]$contracts.RuntimeProtocolSchema -cne $runtimeMatch.Groups[1].Value -or [string]$contracts.ProviderPolicySha256 -cne (HashFile $policyPath)){throw 'Schema-2 package does not match the current native ABI, runtime protocol and provider-policy contracts.'}
 if($p.AutoActivate -ne $false){throw 'Schema-2 packages cannot auto-activate.'}
 $provenance=$p.Provenance;$sourceUri=$null
 try{$sourceUri=[uri][string]$provenance.SourceUrl}catch{}
 if(-not $sourceUri -or $sourceUri.Scheme -cne 'https' -or -not $sourceUri.Host -or [string]$provenance.Revision -notmatch '^(?:[a-fA-F0-9]{40,64}|v?\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)$' -or [string]::IsNullOrWhiteSpace([string]$provenance.ReleaseId) -or [string]::IsNullOrWhiteSpace([string]$provenance.LicenseId) -or [string]$provenance.LicenseSha256 -notmatch '^[a-fA-F0-9]{64}$' -or [string]::IsNullOrWhiteSpace([string]$provenance.LicensePath)){throw 'Schema-2 provenance or legal-notice identity is incomplete.'}
 $license=OwnedPath $root ([string]$provenance.LicensePath);if(-not(Test-Path -LiteralPath $license -PathType Leaf) -or (HashFile $license) -cne [string]$provenance.LicenseSha256){throw 'Schema-2 legal notice is absent or does not match its hash.'}
 if(@($p.Files).Count -lt 1 -or @($p.Files).Count -gt 2048){throw 'Invalid schema-2 component file count.'}
 foreach($listName in @('Requires','Conflicts')){if($null -eq $p.$listName){throw ('Schema-2 '+$listName+' list is required.')}}
 $target=$p.Target
 if(-not $target -or @($target.Architectures).Count -lt 1 -or @($target.ApiCandidates).Count -lt 1 -or @($target.GpuFamilies).Count -lt 1 -or @($target.ProcessNames).Count -lt 1){throw 'Schema-2 target prerequisites must name architecture, API, GPU family and game executable candidates.'}
 if(@($target.Architectures|Where-Object {$_ -notin @('x86','x64')}).Count -or [string]$p.Architecture -notin @($target.Architectures)){throw 'Schema-2 target architecture set is invalid.'}
 if(@($target.ApiCandidates|Where-Object {$_ -notin @('D3D9','D3D10','D3D11','D3D12','Vulkan','OpenGL')}).Count -or @($target.GpuFamilies|Where-Object {$_ -notin @('RTX20','RTX30','RTX40','RTX50','AMD','Intel')}).Count -or @($target.ProcessNames|Where-Object {$_ -notmatch '^[A-Za-z0-9][A-Za-z0-9._ -]{0,127}\.exe$'}).Count){throw 'Schema-2 target prerequisite contains an unsupported value.'}
 $transaction=$p.Transaction
 if(-not $transaction -or [string]$transaction.Mode -cne 'replace-immutable-owned-files' -or [string]$transaction.Preconditions -cne 'sha256' -or [string]$transaction.Rollback -cne 'verified-owner-backup' -or $transaction.RollbackRequired -ne $true -or $transaction.AutoActivate -ne $false){throw 'Schema-2 transaction must require hash preconditions, verified-owner rollback and explicit activation.'}
 $manager=ConvertToLocalComponentSemVersion (GetBundledOptiShadeVersion) $true
 if(-not $manager){throw 'Bundled manager version cannot be compared with schema-2 ranges.'}
 $result=[pscustomobject]@{Schema=2;ComponentId=[string]$p.ComponentId;Id=$id;Version=[string]$p.Version;Channel=[string]$p.Channel;State='blocked';Reason='';ReadOnly=$true;MutationsAllowed=$false;ProvenanceVerified=$false;ContractAdmission='manager-contract-matched';TargetAdmission='requires-live-process-and-adapter-evidence';Target=$target;Identity=(HashFile $catalogPath);Plan=@()}
 if((CompareLocalComponentSemVersion $manager $min) -lt 0 -or (CompareLocalComponentSemVersion $manager $max) -ge 0){$result.Reason='Manager version is outside the package range.';return $result}
 $arch=if($Manifest.Architecture){[string]$Manifest.Architecture}else{'x64'}
 if($Manifest.Status -ne 'Installed' -or $arch -cne [string]$p.Architecture){$result.Reason='Requires a matching installed core and architecture.';return $result}
 $prior=@($Manifest.ComponentPackages|Where-Object {$_.Id -ceq $id})
 if($prior.Count -gt 1){$result.Reason='Duplicate installed component receipts.';return $result}
 if($prior.Count){$installedVersion=ConvertToLocalComponentSemVersion ([string]$prior[0].Version);$candidateVersion=ConvertToLocalComponentSemVersion ([string]$p.Version);if(-not $installedVersion -or -not $candidateVersion){$result.Reason='Installed component version cannot be compared.';return $result};$versionOrder=CompareLocalComponentSemVersion $installedVersion $candidateVersion;if($versionOrder -gt 0){$result.Reason='A newer component version is already installed.';return $result};if($versionOrder -eq 0 -and [string]$prior[0].Identity -cne (HashFile $catalogPath)){$result.Reason='The same component version has a different package identity.';return $result}}
 if(@($p.Requires).Count -and -not $PackageSet){$result.Reason='Dependency resolution requires an explicitly selected complete package set.';return $result}
 if($PackageSet){$setError=TestLocalComponentPackageSetContract $PackageSet;if($setError){$result.Reason=$setError;return $result};if(@($PackageSet|Where-Object {$_.ComponentId -ceq [string]$p.ComponentId}).Count -ne 1){$result.Reason='The explicit package set does not contain this component.';return $result}}
 if(@($p.Conflicts|Where-Object {$_ -isnot [string] -or $_ -notmatch '^OptiShade\.(Core|Effects|Neural|Providers)$'}).Count){throw 'Schema-2 conflicts contain an unsupported component identity.'}
 $installedIds=@($Manifest.ComponentPackages|ForEach-Object {if($_.Id){'OptiShade.'+[string]$_.Id}})
 $setIds=@($PackageSet|ForEach-Object {[string]$_.ComponentId})
 $conflict=@($p.Conflicts|Where-Object {$_ -in $installedIds -or $_ -in $setIds})
 if($conflict.Count){$result.Reason='Conflicts with installed component '+$conflict[0]+'.';return $result}
 if($p.AtomicGroup){
  if([string]$p.AtomicGroup.Id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or @($p.AtomicGroup.Members).Count -lt 2 -or @($p.AtomicGroup.Members|Where-Object {$_ -notmatch '^OptiShade\.(Core|Effects|Neural|Providers)$'}).Count){throw 'Schema-2 atomic group declaration is invalid.'}
  if(-not $PackageSet){$result.Reason='Atomic compatibility group requires an explicitly selected complete package set.';return $result}
 }
 $seen=@{};$plan=@();$changed=$false
 foreach($f in $p.Files){
  $rel=([string]$f.Path).Replace('\','/');$key=$rel.ToLowerInvariant()
  if($seen.ContainsKey($key) -or (GetOptiShadeAddonId $rel) -cne $id -or [IO.Path]::GetExtension($rel) -notin @('.dll','.exe','.addon32','.addon64','.fx','.fxh','.png','.dds')){throw 'Unsupported or duplicate schema-2 component file: '+$rel}
  if([string]$f.Sha256 -notmatch '^[a-fA-F0-9]{64}$' -or [string]$f.PreconditionSha256 -notmatch '^[a-fA-F0-9]{64}$' -or [long]$f.Size -lt 1){throw 'Invalid schema-2 file identity or precondition: '+$rel}
  $payload=OwnedPath $root $rel;if(-not(Test-Path -LiteralPath $payload -PathType Leaf) -or (HashFile $payload) -cne [string]$f.Sha256){$result.Reason='Staged payload is absent or does not match its hash: '+$rel;return $result}
  $records=@($Manifest.Files|Where-Object {([string]$_.SourcePath).Replace('\','/') -ceq $rel -or ([string]$_.Path).Replace('\','/') -ceq $rel})
  if($records.Count -ne 1 -or (TestOptiShadeMutableFile $rel) -or $records[0].Mutable -or $records[0].Retained){$result.Reason='Package requires one existing immutable owned file: '+$rel;return $result}
  $record=$records[0];$destination=OwnedPath $Manifest.Game $record.Path;$current=HashFile $destination
  if(-not $current -or $current -cne [string]$f.PreconditionSha256 -or $current -cne [string]$record.Hash){$result.Reason='Installed file does not match the declared precondition: '+$rel;return $result}
  $changed=$changed -or $current -cne [string]$f.Sha256
  $seen[$key]=$true;$plan+=[pscustomobject]@{Path=$rel;CurrentHash=$current;TargetHash=[string]$f.Sha256;Destination=$destination}
 }
 $result.Plan=$plan
 if($p.Channel -ceq 'research-only'){$result.State='research';$result.Reason='Research-only package is never activated by this planner.';return $result}
 if(-not $changed){$result.State='installed-read-only';$result.Reason='All declared files already match; no changes proposed.';return $result}
 $result.State='available-read-only';$result.Reason='Preconditions match. This pilot only reports a plan and cannot download, stage or apply it.'
 return $result
}
function GetLocalComponentPackageState($Manifest,$Package){
 $result=[pscustomobject]@{Available=$false;Installed=$false;Staged=$false;Reason='';Plan=@();Schema=1;Approval=$null}
 if(-not $Package){return $result}
 $p=$Package.Catalog
 if(TestLocalComponentPackageSelectionSet $Package){
  $result.Schema=2;$folders=@($Package.Packages|ForEach-Object {[string]$_.Root});$plan=GetLocalComponentPackageSetReadOnlyPlan $folders $Manifest;$result.Plan=$plan
  $result.Approval=GetLocalComponentApprovalStatus $plan $Package.Stage
  if($result.Approval.State -eq 'staged'){$result.Staged=$true;$result.Reason=$result.Approval.Reason;return $result}
  if($plan.State -ceq 'available-read-only'){$result.Available=$true;$result.Reason=[string]$plan.Reason;return $result}
  if($plan.State -ceq 'installed-read-only'){$result.Installed=$true;$result.Reason=[string]$plan.Reason;return $result}
  $result.Reason=[string]$plan.Reason;return $result
 }
 if($p.Schema -eq 2 -or $Package.Schema -eq 2){
  $result.Schema=2
  $plan=GetLocalComponentPackageReadOnlyPlan $Package.Root $Manifest;$result.Plan=$plan;$result.Approval=GetLocalComponentApprovalStatus $plan $Package.Stage
  if($result.Approval.State -eq 'staged'){$result.Staged=$true;$result.Reason=$result.Approval.Reason;return $result}
  if($plan.State -ceq 'available-read-only'){$result.Available=$true;$result.Reason=[string]$plan.Reason;return $result}
  if($plan.State -ceq 'installed-read-only'){$result.Installed=$true;$result.Reason=[string]$plan.Reason;return $result}
  $result.Reason=[string]$plan.Reason;return $result
 }
 $arch=if($Manifest.Architecture){[string]$Manifest.Architecture}else{'x64'}
 if($Manifest.Status -ne 'Installed' -or $arch -ne $p.Architecture -or [string]$Manifest.Version -ne [string]$p.ManagerVersion){$result.Reason='Requires matching installed core and architecture.';return $result}
 $prior=@($Manifest.ComponentPackages|Where-Object {$_.Id -eq $p.Id})
 if($prior.Count -gt 1){$result.Reason='Duplicate component receipt.';return $result}
 if($prior.Count -and [version]$prior[0].Version -gt [version]$p.Version){$result.Reason='A newer component version is installed.';return $result}
 if($prior.Count -and $prior[0].Version -eq $p.Version -and $prior[0].Identity -ne $Package.Identity){$result.Reason='This component version has a different package identity.';return $result}
 $plan=@();$changed=$false
 foreach($f in $p.Files){
  $rel=([string]$f.Path).Replace('\','/')
  $records=@($Manifest.Files|Where-Object {([string]$_.SourcePath).Replace('\','/') -eq $rel -or ([string]$_.Path).Replace('\','/') -eq $rel})
  if($records.Count -ne 1 -or (TestOptiShadeMutableFile $rel) -or $records[0].Mutable -or $records[0].Retained){$result.Reason='Package requires an existing immutable owned file: '+$rel;return $result}
  $r=$records[0];$current=HashFile (OwnedPath $Manifest.Game $r.Path)
  if(-not $current -or $current -ne $r.Hash -or ($current -ne $f.PreviousHash -and $current -ne $f.Hash)){$result.Reason='Installed file differs from this package baseline: '+$rel;return $result}
  $changed=$changed -or $current -ne $f.Hash
  $plan+=[pscustomobject]@{Record=$r;File=$f;Destination=(OwnedPath $Manifest.Game $r.Path)}
 }
 $result.Plan=$plan;$result.Available=$changed;$result.Installed=-not $changed
 return $result
}
function TestLocalComponentReceipt($Manifest,[string]$Id){
 $receipts=@($Manifest.ComponentPackages|Where-Object {$_.Id -eq $Id -and $_.ManagerVersion -eq (GetBundledOptiShadeVersion)})
 if($receipts.Count -ne 1 -or -not @($receipts[0].Files).Count){return $false}
 foreach($f in $receipts[0].Files){
  $records=@($Manifest.Files|Where-Object {$_.Path -eq $f.Path})
  if($records.Count -ne 1 -or $records[0].Hash -ne $f.Hash -or (HashFile (OwnedPath $Manifest.Game $f.Path)) -ne $f.Hash){return $false}
 }
 return $true
}
function InstallLocalComponentPackage([string]$ManifestPath,$Package,[scriptblock]$Progress=$null){
 if($Package.Schema -eq 2 -or $Package.Catalog.Schema -eq 2){
  $m=ReadOptiShadeState $ManifestPath
  if($m.Status -ne 'Installed'){throw 'Install OptiShade for the matching game before staging this component.'}
  AssertClosed $m.Game
  if(TestLocalComponentPackageSelectionSet $Package){
   $folders=@($Package.Packages|ForEach-Object {[string]$_.Root});$plan=GetLocalComponentPackageSetReadOnlyPlan $folders $m
   if($plan.State -cne 'available-read-only'){throw ([string]$plan.Reason)}
   $cacheRoot=if($Package.StageCacheRoot){[string]$Package.StageCacheRoot}else{GetOptiShadeComponentStageRoot}
   return StageLocalComponentPackageSet $folders $m $plan $cacheRoot
  }
  $catalogPath=OwnedPath $Package.Root 'component-package.json'
  if((HashFile $catalogPath) -cne [string]$Package.Identity){throw 'The component package changed. Select it again.'}
  $plan=GetLocalComponentPackageReadOnlyPlan $Package.Root $m
  if($plan.State -cne 'available-read-only'){throw ([string]$plan.Reason)}
  $cacheRoot=if($Package.StageCacheRoot){[string]$Package.StageCacheRoot}else{GetOptiShadeComponentStageRoot}
  return StageLocalComponentPackage $Package.Root $plan $cacheRoot
 }
 # Verify again at the action boundary; never trust the earlier page snapshot.
 $fresh=ReadLocalComponentPackage $Package.Root
 if($fresh.Identity -ne $Package.Identity){throw 'The component package changed. Select it again.'}
 $m=ReadOptiShadeState $ManifestPath;AssertClosed $m.Game
 $state=GetLocalComponentPackageState $m $fresh
 if($state.Installed){return}
 if(-not $state.Available){throw $state.Reason}
 AssertAntiCheatMutation $m.Game $m.LaunchExe ('Update local component '+$fresh.Component)
 $prior=[IO.File]::ReadAllBytes($ManifestPath)
 $tx=OwnedPath (Split-Path $ManifestPath) ('ComponentTransactions/'+[guid]::NewGuid().ToString('N'))
 [void][IO.Directory]::CreateDirectory($tx)
 $journal=@();$committed=$false
 try{
  $index=0
  foreach($item in $state.Plan){
   if($Progress){& $Progress ('Preparing '+$item.Record.Path) $index $state.Plan.Count}
   $backup=Join-Path $tx ($index.ToString()+'.before');$staged=Join-Path $tx ($index.ToString()+'.new')
   Copy-Item -LiteralPath $item.Destination -Destination $backup
   Copy-Item -LiteralPath (OwnedPath $fresh.Root $item.File.Path) -Destination $staged
   if((HashFile $backup) -ne $item.Record.Hash -or (HashFile $staged) -ne $item.File.Hash){throw 'A file changed during component staging.'}
   $journal+=[pscustomobject]@{Item=$item;Backup=$backup;Staged=$staged;Written=$false};$index++
  }
  foreach($entry in $journal){
   if((HashFile $entry.Item.Destination) -ne $entry.Item.Record.Hash){throw 'An installed file changed during the update.'}
   $entry.Written=$true
   Copy-Item -LiteralPath $entry.Staged -Destination $entry.Item.Destination -Force
   if((HashFile $entry.Item.Destination) -ne $entry.Item.File.Hash){throw 'Updated component verification failed.'}
   $entry.Item.Record.Hash=[string]$entry.Item.File.Hash
  }
  $updatedFiles=@($state.Plan|ForEach-Object {[pscustomobject]@{Path=$_.Record.Path;Hash=$_.File.Hash}})
  $previousFiles=@($m.ComponentPackages|Where-Object {$_.Id -eq $fresh.Catalog.Id}|ForEach-Object {$_.Files}|Where-Object {$_ -and $_.Path -notin $updatedFiles.Path})
  $receipt=[pscustomobject]@{Id=$fresh.Catalog.Id;Version=$fresh.Catalog.Version;ManagerVersion=$fresh.Catalog.ManagerVersion;Identity=$fresh.Identity;Files=@($previousFiles)+@($updatedFiles)}
  $receipts=@($m.ComponentPackages|Where-Object {$_ -and $_.Id -ne $fresh.Catalog.Id})+@($receipt)
  $m|Add-Member NoteProperty ComponentPackages $receipts -Force
  WriteState $m $ManifestPath;$committed=$true
 }catch{
  $failure=$_
  foreach($entry in $journal|Where-Object Written){Copy-Item -LiteralPath $entry.Backup -Destination $entry.Item.Destination -Force}
  [IO.File]::WriteAllBytes($ManifestPath,$prior)
  throw $failure
 }finally{
  # Exact, generated transaction folder only. Keep recovery evidence on failure.
  if($committed -and $tx.StartsWith((FullPath (Split-Path $ManifestPath))+'\',[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $tx -Recurse -Force}
 }
}
