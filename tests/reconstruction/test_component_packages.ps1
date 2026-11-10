$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Beta/installer/ownership.ps1"
. "$root/Beta/installer/component-packages.ps1"
. "$root/Beta/installer/manager-status.ps1"
function Assert($condition,$message){if(-not $condition){throw $message}}
function AssertClosed($game){}
$fixture=Join-Path $root ('test-run/component-package-'+[guid]::NewGuid().ToString('N'))
$game=Join-Path $fixture 'game';$baseline=Join-Path $fixture 'before';$updated=Join-Path $fixture 'after';$packageRoot=Join-Path $fixture 'package'
foreach($dir in @($game,$baseline,$updated)){[void][IO.Directory]::CreateDirectory($dir)}
[IO.File]::WriteAllText((Join-Path $baseline 'ReShade64.dll'),'old fixture binary')
[IO.File]::WriteAllText((Join-Path $updated 'ReShade64.dll'),'new fixture binary')
Copy-Item -LiteralPath (Join-Path $baseline 'ReShade64.dll') -Destination (Join-Path $game 'dxgi.dll')
$original=HashFile (Join-Path $game 'dxgi.dll')
$record=[pscustomobject]@{Path='dxgi.dll';SourcePath='ReShade64.dll';Hash=$original;PreviousHash='original-game-hash';Backup='original.backup';Mutable=$false;Retained=$false}
$manifest=[pscustomobject]@{Game=$game;Status='Installed';Version=(GetBundledOptiShadeVersion);Architecture='x64';Files=@($record)}
$mp=Join-Path $fixture 'manifest.json';WriteState $manifest $mp
& "$root/Beta/new-component-package.ps1" -BaselinePayload $baseline -UpdatedPayload $updated -Output $packageRoot -Component Core -Version '1.0.1' -Architecture x64 -Files 'ReShade64.dll'
$package=ReadLocalComponentPackage $packageRoot
Assert (GetLocalComponentPackageState $manifest $package).Available 'Matching baseline not offered'
$catalogPath=Join-Path $packageRoot 'component-package.json';$stableCatalogBytes=[IO.File]::ReadAllBytes($catalogPath);$originalBundledVersion=${function:GetBundledOptiShadeVersion}
try{
 function GetBundledOptiShadeVersion{'P1.0.77-beta.5'}
 $betaCatalog=Get-Content -LiteralPath $catalogPath -Raw|ConvertFrom-Json;$betaCatalog.ManagerVersion=GetBundledOptiShadeVersion
 [IO.File]::WriteAllText($catalogPath,($betaCatalog|ConvertTo-Json -Depth 8))
 $betaPackage=ReadLocalComponentPackage $packageRoot;$manifest.Version=GetBundledOptiShadeVersion
 Assert (GetLocalComponentPackageState $manifest $betaPackage).Available 'Generated beta manager version was rejected by local component-package validation'
}finally{
 Set-Item Function:GetBundledOptiShadeVersion $originalBundledVersion
 [IO.File]::WriteAllBytes($catalogPath,$stableCatalogBytes);$manifest.Version=GetBundledOptiShadeVersion
}
$manifest.Architecture='x86';Assert (-not (GetLocalComponentPackageState $manifest $package).Available) 'Wrong architecture offered';$manifest.Architecture='x64'
$record.Mutable=$true;Assert (-not (GetLocalComponentPackageState $manifest $package).Available) 'Mutable file offered';$record.Mutable=$false
[IO.File]::WriteAllText((Join-Path $game 'dxgi.dll'),'unrelated external change')
Assert (-not (GetLocalComponentPackageState $manifest $package).Available) 'Externally changed game file offered'
Copy-Item -LiteralPath (Join-Path $baseline 'ReShade64.dll') -Destination (Join-Path $game 'dxgi.dll') -Force
$manifest.Version='P1.0.19';Assert (-not (GetLocalComponentPackageState $manifest $package).Available) 'Wrong installed baseline offered';$manifest.Version=GetBundledOptiShadeVersion
# Run the real manager row builder and action queue against the real updater.
# Only UI/dispatch surfaces are isolated; receipt and game-file IO are real.
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Beta/installer/manager.ps1'),[ref]$null,[ref]$null)
foreach($name in @('GetManagedUpdateRows','TestManagerStatusCurrent','GetCachedManagerGameStatus','GetManagerUpdateVerificationGap','TestManagerUpdateInstallationVerified','ReconcileCompletedUpdateResults','StartManagedUpdates')){
 $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 Invoke-Expression $node.Extent.Text
}
$script:libraryGames=@([pscustomobject]@{Name='Isolated test game';Folder=$game})
$script:localComponentPackage=$package;$script:updateResults=@{};$script:busy=$false;$script:statusGeneration=0
$form=[pscustomobject]@{Control=[pscustomobject]@{Text='';Foreground=''}}
$form|Add-Member ScriptMethod FindName {param($name) $this.Control}
$status=[pscustomobject]@{Text=''}
function GetFusionGameTargetFolder($entry){$entry.Folder}
function ManifestPath($store,$folder){$mp}
function GetGameUpdateInfo{[pscustomobject]@{Core=$false;Components=@()}}
function GetGlassCockpitUpdateInfo{[pscustomobject]@{Available=$false}}
# Batch risk decisions are covered by test_update_protection_preflight.ps1.
function ConfirmUpdateBatchProtection($queue){}
$progress={}
function RunAction($action,$activity){& $action}
function WaitForManagerVerification{return $false};function TestOperationCancelRequested{return $false}
function UpdateOperationProgress{}
function PumpManagerDispatcher{}
function WriteInstallerLog($message){Write-Output $message}
function RefreshHeaderGlassCockpitUpdateState{}
function RefreshUpdateManager{}
function RequestManagerStatusScan([switch]$Force){if(-not $Force){throw 'Post-update verification must force a fresh scan.'};$script:statusGeneration++;RefreshFixtureStatus}
function RefreshFixtureStatus{
 $current=ReadOptiShadeState $mp
 $context=[pscustomobject]@{LocalPackage=$script:localComponentPackage;Release=$null}
 $record=[pscustomobject]@{Game=$script:libraryGames[0];Folder=$game;ManifestPath=$mp;Manifest=$current;Info=[pscustomobject]@{Core=$false;Components=@()};Glass=[pscustomobject]@{Available=$false}}
 $rows=@(GetOptiShadeManagerSnapshotRows $context $record (GetLocalComponentPackageState $current $script:localComponentPackage))
 $script:managerStatusState=[pscustomobject]@{Key='fixture';Busy=$false;Error='';Generation=$script:statusGeneration;Snapshot=[pscustomobject]@{Key='fixture';Rows=$rows}}
}
RefreshFixtureStatus
Assert (@(GetManagedUpdateRows).Count -eq 1) 'Local candidate did not appear in actual row builder'
$priorSessionConsent=$script:AntiCheatSessionAccepted
try{
 # Model the globally accepted warning required before this integration path.
 # Rejection-before-mutation is covered by test_anti_cheat.ps1.
 $script:AntiCheatSessionAccepted=$true
 StartManagedUpdates $game Core
}finally{
 $script:AntiCheatSessionAccepted=$priorSessionConsent
}
Assert ($script:updateResults[$game.ToLowerInvariant()+'|Core'] -eq 'Complete') 'Actual update queue did not complete'
RefreshFixtureStatus
Assert (@(GetManagedUpdateRows).Count -eq 0) 'Completed local package still appears as available'
$installed=ReadOptiShadeState $mp
Assert ((HashFile (Join-Path $game 'dxgi.dll')) -eq $package.Catalog.Files[0].Hash) 'Mapped loader was not replaced'
Assert ((GetLocalComponentPackageState $installed $package).Installed) 'Completed package remains offered'
Assert (TestLocalComponentReceipt $installed Core) 'Independent receipt not recognised'
Assert ($installed.Version -eq $manifest.Version) 'Manager/core baseline version changed'
Assert ($installed.Files[0].Backup -eq 'original.backup' -and $installed.Files[0].PreviousHash -eq 'original-game-hash') 'Original uninstall provenance changed'
Assert ($installed.ComponentPackages[0].Version -eq '1.0.1') 'Independent component version missing'
$package.Catalog.Version='1.0.0';Assert (-not (GetLocalComponentPackageState $installed $package).Available) 'Downgrade offered'
[IO.File]::WriteAllText((Join-Path $packageRoot 'ReShade64.dll'),'tampered')
$rejected=$false;try{ReadLocalComponentPackage $packageRoot}catch{$rejected=$true};Assert $rejected 'Tampered package accepted'
# Transaction failure restores the mapped binary and byte-exact receipt.
Copy-Item -LiteralPath (Join-Path $updated 'ReShade64.dll') -Destination (Join-Path $packageRoot 'ReShade64.dll') -Force
Copy-Item -LiteralPath (Join-Path $baseline 'ReShade64.dll') -Destination (Join-Path $game 'dxgi.dll') -Force
WriteState $manifest $mp;$prior=HashFile $mp
$writeStateReader=${function:WriteState}
function WriteState($m,$p){throw 'Injected receipt write failure'}
$rejected=$false;try{InstallLocalComponentPackage $mp (ReadLocalComponentPackage $packageRoot)}catch{$rejected=$true}
Set-Item Function:WriteState $writeStateReader
Assert $rejected 'Injected transaction failure did not propagate'
Assert ((HashFile (Join-Path $game 'dxgi.dll')) -eq $original -and (HashFile $mp) -eq $prior) 'Rollback failed to restore file and receipt'
$catalogBytes=[IO.File]::ReadAllBytes($catalogPath)
$catalog=$package.Catalog;$catalog.Files[0].Path='../ReShade64.dll'
[IO.File]::WriteAllText($catalogPath,($catalog|ConvertTo-Json -Depth 8))
$rejected=$false;try{ReadLocalComponentPackage $packageRoot}catch{$rejected=$true};Assert $rejected 'Escaping package path accepted'
[IO.File]::WriteAllBytes($catalogPath,$catalogBytes)
# Schema 2 is deliberately a separate read-only plan. It must not cross the
# existing schema-1 action boundary or alter the receipt, game or payload.
$schema2Root=Join-Path $fixture 'schema2-package';[void][IO.Directory]::CreateDirectory($schema2Root)
Copy-Item -LiteralPath (Join-Path $updated 'ReShade64.dll') -Destination (Join-Path $schema2Root 'ReShade64.dll')
$licensePath=Join-Path $schema2Root 'NOTICE.txt';[IO.File]::WriteAllText($licensePath,'Fixture only; this is not a distributable licence notice.')
$licenseHash=HashFile $licensePath;$oldHash=HashFile (Join-Path $game 'dxgi.dll');$newHash=HashFile (Join-Path $schema2Root 'ReShade64.dll')
$bridgeVersion=[regex]::Match([IO.File]::ReadAllText((Join-Path $root 'Beta/shared/EffectsBridge.h')),'constexpr\s+uint32_t\s+Version\s*=\s*(\d+)').Groups[1].Value
$protocolVersion=[regex]::Match([IO.File]::ReadAllText((Join-Path $root 'Beta/installer/RuntimeControlClient.cs')),'const\s+int\s+ProtocolSchema\s*=\s*(\d+)').Groups[1].Value
$providerPolicyHash=HashFile (Join-Path $root 'Beta/installer/provider-policy.json')
$schema2=[ordered]@{Schema=2;ComponentId='OptiShade.Core';Version='1.0.2';Channel='private-candidate';Architecture='x64';ManagerRange=[ordered]@{MinInclusive='1.0.77-beta.0';MaxExclusive='1.1.0'};Contracts=[ordered]@{PackageCatalog='local-component-package/v2';FileOwnership='immutable-owned-file/v1';NativeBridgeAbi=$bridgeVersion;RuntimeProtocolSchema=$protocolVersion;ProviderPolicySha256=$providerPolicyHash};Requires=@();Conflicts=@();AutoActivate=$false;Target=[ordered]@{Architectures=@('x64');ApiCandidates=@('D3D11','D3D12');GpuFamilies=@('RTX40');ProcessNames=@('fixture.exe')};Transaction=[ordered]@{Mode='replace-immutable-owned-files';Preconditions='sha256';Rollback='verified-owner-backup';RollbackRequired=$true;AutoActivate=$false};Provenance=[ordered]@{SourceUrl='https://reshade.me/';Revision='v6.8.0';ReleaseId='fixture-only';LicenseId='fixture-only-not-for-redistribution';LicensePath='NOTICE.txt';LicenseSha256=$licenseHash};Files=@([ordered]@{Path='ReShade64.dll';Sha256=$newHash;PreconditionSha256=$oldHash;Size=(Get-Item (Join-Path $schema2Root 'ReShade64.dll')).Length})}
$schema2Path=Join-Path $schema2Root 'component-package.json';[IO.File]::WriteAllText($schema2Path,($schema2|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
$schema2CatalogHash=HashFile $schema2Path;$manifest|Add-Member NoteProperty ComponentPackages @() -Force;$readOnly=GetLocalComponentPackageReadOnlyPlan $schema2Root $manifest
Assert ($readOnly.Schema -eq 2 -and $readOnly.State -eq 'available-read-only' -and $readOnly.ReadOnly -and -not $readOnly.MutationsAllowed -and -not $readOnly.ProvenanceVerified -and $readOnly.ContractAdmission -eq 'manager-contract-matched' -and $readOnly.TargetAdmission -eq 'requires-live-process-and-adapter-evidence' -and $readOnly.Plan.Count -eq 1) 'Schema-2 catalog did not produce an explicit read-only plan with matched manager contracts, unverified provenance and closed target admission'
$schema2Candidate=ReadLocalComponentPackageCandidate $schema2Root
Assert ($schema2Candidate.Schema -eq 2 -and $schema2Candidate.Catalog.Id -eq 'Core' -and (GetLocalComponentPackageState $manifest $schema2Candidate).Available) 'Existing Update Manager package selection did not recognize an available schema-2 candidate'
$singleSetPlan=GetLocalComponentPackageSetReadOnlyPlan @($schema2Root) $manifest
Assert ($singleSetPlan.State -eq 'available-read-only' -and $singleSetPlan.ReadOnly -and -not $singleSetPlan.MutationsAllowed -and -not $singleSetPlan.ProvenanceVerified -and $singleSetPlan.Plans.Count -eq 1) 'Explicit package-set planning did not preserve the read-only boundary for an independent package'
$effectsRoot=Join-Path $fixture 'schema2-effects-package';$effectsPayload=Join-Path $effectsRoot 'OptiShadeData/Shaders/fixture.fx';$effectsGamePath=Join-Path $game 'OptiShadeData/Shaders/fixture.fx';[void][IO.Directory]::CreateDirectory((Split-Path $effectsPayload));[void][IO.Directory]::CreateDirectory((Split-Path $effectsGamePath));[IO.File]::WriteAllText($effectsPayload,'new effect fixture');[IO.File]::WriteAllText($effectsGamePath,'old effect fixture')
$effectBefore=HashFile $effectsGamePath;$manifest.Files+=@([pscustomobject]@{Path='OptiShadeData/Shaders/fixture.fx';SourcePath='OptiShadeData/Shaders/fixture.fx';Hash=$effectBefore;Mutable=$false;Retained=$false})
$effectsNotice=Join-Path $effectsRoot 'NOTICE.txt';[void][IO.Directory]::CreateDirectory($effectsRoot);[IO.File]::WriteAllText($effectsNotice,'Fixture-only legal notice.');$effectsNoticeHash=HashFile $effectsNotice;$effectsNewHash=HashFile $effectsPayload
$effectsCatalog=[ordered]@{Schema=2;ComponentId='OptiShade.Effects';Version='1.0.0';Channel='private-candidate';Architecture='x64';ManagerRange=$schema2.ManagerRange;Contracts=$schema2.Contracts;Requires=@();Conflicts=@();Provides=@('effect-host/v1');AutoActivate=$false;Target=$schema2.Target;Transaction=$schema2.Transaction;Provenance=[ordered]@{SourceUrl='https://reshade.me/';Revision='v6.8.0';ReleaseId='fixture-effects';LicenseId='fixture-only-not-for-redistribution';LicensePath='NOTICE.txt';LicenseSha256=$effectsNoticeHash};Files=@([ordered]@{Path='OptiShadeData/Shaders/fixture.fx';Sha256=$effectsNewHash;PreconditionSha256=$effectBefore;Size=(Get-Item $effectsPayload).Length})}
[IO.File]::WriteAllText((Join-Path $effectsRoot 'component-package.json'),($effectsCatalog|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
$schema2.Requires=@([ordered]@{ComponentId='OptiShade.Effects';Version='1.0.0';Contract='effect-host/v1'});[IO.File]::WriteAllText($schema2Path,($schema2|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
$dependentCore=ReadLocalComponentPackageCandidate $schema2Root;$effectsCandidate=ReadLocalComponentPackageCandidate $effectsRoot;$resolvedDependencySet=GetLocalComponentPackageSetReadOnlyPlan @($schema2Root,$effectsRoot) $manifest
Assert ($resolvedDependencySet.State -eq 'available-read-only' -and $resolvedDependencySet.Plans.Count -eq 2 -and $resolvedDependencySet.ReadOnly -and -not $resolvedDependencySet.MutationsAllowed -and -not $resolvedDependencySet.ProvenanceVerified) 'A complete exact dependency set did not resolve as read-only'
$schema2.AtomicGroup=[ordered]@{Id='fixture-renderer-group';Members=@('OptiShade.Core','OptiShade.Effects')};$effectsCatalog.AtomicGroup=[ordered]@{Id='fixture-renderer-group';Members=@('OptiShade.Core','OptiShade.Effects')};[IO.File]::WriteAllText($schema2Path,($schema2|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $effectsRoot 'component-package.json'),($effectsCatalog|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
$resolvedAtomicSet=GetLocalComponentPackageSetReadOnlyPlan @($schema2Root,$effectsRoot) $manifest
Assert ($resolvedAtomicSet.State -eq 'available-read-only' -and $resolvedAtomicSet.Plans.Count -eq 2 -and $resolvedAtomicSet.ReadOnly -and -not $resolvedAtomicSet.MutationsAllowed) 'A complete, consistently declared atomic group did not resolve as read-only'
$setSelection=[pscustomobject]@{Schema=2;Catalog=[pscustomobject]@{Schema=2;Id='PackageSet';Version='2 packages'};Packages=@($resolvedAtomicSet.Packages);Identity=$resolvedAtomicSet.Identity;Stage=$null;StageCacheRoot=''}
$setContext=[pscustomobject]@{LocalPackage=$setSelection;Release=$null};$setRecord=[pscustomobject]@{Game=[pscustomobject]@{Name='Fixture game'};Folder=$game;ManifestPath=$mp;Manifest=$manifest;Info=[pscustomobject]@{Core=$false;Components=@()};Glass=[pscustomobject]@{Available=$false}}
$setRows=@(GetOptiShadeManagerSnapshotRows $setContext $setRecord (GetLocalComponentPackageState $manifest $setSelection))
Assert ($setRows.Count -eq 1 -and $setRows[0].LocalPackage -and $setRows[0].Id -eq 'PackageSet' -and $setRows[0].Detail -match 'set of 2 packages') 'Existing Update Manager row builder did not surface the complete local package set'
$setStageRoot=Join-Path $fixture 'component-set-stage-cache';$setCopyFailure=$false
try{StageLocalComponentPackageSet @($schema2Root,$effectsRoot) $manifest $resolvedAtomicSet $setStageRoot 536870912 {param($source,$destination) Copy-Item -LiteralPath $source -Destination $destination;if($destination.EndsWith('fixture.fx')){throw 'injected package-set staging failure'}}|Out-Null}catch{$setCopyFailure=$_.Exception.Message -match 'injected package-set staging failure'}
Assert ($setCopyFailure -and @(Get-ChildItem -LiteralPath $setStageRoot -Directory -Force -ErrorAction SilentlyContinue).Count -eq 0) 'A failed package-set stage did not roll back the earlier package stage'
$effectsGameBefore=HashFile $effectsGamePath
WriteState $manifest $mp;$prior=HashFile $mp;$effectReceiptBefore=HashFile $mp;$setSelection.StageCacheRoot=$setStageRoot
$setStage=InstallLocalComponentPackage $mp $setSelection
Assert ($setStage.State -eq 'staged' -and $setStage.Packages.Count -eq 2 -and -not $setStage.ProvenanceVerified -and -not $setStage.MutationsAllowed) 'Complete package set was not staged as one read-only operation'
$setSelection.Stage=$setStage;$setSelection.StageCacheRoot=$setStageRoot
$setState=GetLocalComponentPackageState $manifest $setSelection
Assert ($setState.Staged -and -not $setState.Available -and $setState.Approval.State -eq 'staged') 'Update Manager state did not recognize a verified staged package set'
Assert ((HashFile $mp) -ceq $effectReceiptBefore -and (HashFile $effectsGamePath) -ceq $effectsGameBefore) 'Package-set staging changed the game or installation receipt'
$schema2.Requires=@();$schema2.Remove('AtomicGroup');[IO.File]::WriteAllText($schema2Path,($schema2|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
$schema2Context=[pscustomobject]@{LocalPackage=$schema2Candidate;Release=$null};$schema2Record=[pscustomobject]@{Game=[pscustomobject]@{Name='Fixture game'};Folder=$game;ManifestPath=$mp;Manifest=$manifest;Info=[pscustomobject]@{Core=$false;Components=@()};Glass=[pscustomobject]@{Available=$false}}
$schema2Rows=@(GetOptiShadeManagerSnapshotRows $schema2Context $schema2Record (GetLocalComponentPackageState $manifest $schema2Candidate))
Assert ($schema2Rows.Count -eq 1 -and $schema2Rows[0].LocalPackage -and $schema2Rows[0].Detail -match 'stage-only pilot') 'Existing Update Manager row did not present schema-2 packages as an explicit staging action'
$stageRoot=Join-Path $fixture 'component-stage-cache';$staged=StageLocalComponentPackage $schema2Root $readOnly $stageRoot
Assert ($staged.State -eq 'staged' -and -not $staged.ProvenanceVerified -and -not $staged.Reused -and $staged.Files.Count -eq 3) 'Valid local schema-2 package was not copied into the bounded private stage cache'
$schema2Candidate.StageCacheRoot=$stageRoot;$stageAction=InstallLocalComponentPackage $mp $schema2Candidate
Assert ($stageAction.State -eq 'staged' -and $stageAction.Reused -and (HashFile (Join-Path $game 'dxgi.dll')) -eq $oldHash -and (HashFile $mp) -eq $prior) 'Existing Update Manager action did not stage schema-2 payloads without changing the game or receipt'
$schema2Candidate|Add-Member -NotePropertyName Stage -NotePropertyValue $stageAction -Force
Assert ((GetLocalComponentPackageState $manifest $schema2Candidate).Staged) 'Existing Update Manager state did not surface the verified staged package status'
$stagedRows=@(GetOptiShadeManagerSnapshotRows $schema2Context $schema2Record (GetLocalComponentPackageState $manifest $schema2Candidate))
Assert ($stagedRows.Count -eq 0) 'A staged-only package remained actionable as a game update'
Assert ((GetLocalComponentApprovalStatus $readOnly).State -eq 'available' -and (GetLocalComponentApprovalStatus $readOnly $staged).State -eq 'staged') 'Backend approval status did not distinguish available from verified staged content'
$wrongStage=[pscustomobject]@{State='staged';Identity=('0'*64)};Assert ((GetLocalComponentApprovalStatus $readOnly $wrongStage).State -eq 'blocked') 'Stage status was accepted with an unrelated catalog identity'
Assert ((HashFile (Join-Path $staged.Root 'ReShade64.dll')) -eq $newHash -and (HashFile (Join-Path $staged.Root 'NOTICE.txt')) -eq $licenseHash) 'Staged payload or legal notice did not retain its verified hash'
$stagedAgain=StageLocalComponentPackage $schema2Root $readOnly $stageRoot;Assert ($stagedAgain.Reused -and $stagedAgain.Root -eq $staged.Root) 'Repeated staging did not reuse the revalidated immutable cache entry'
$stagedPayload=Join-Path $staged.Root 'ReShade64.dll';[IO.File]::WriteAllText($stagedPayload,'tampered stage');$tamperedStage=$false;try{StageLocalComponentPackage $schema2Root $readOnly $stageRoot|Out-Null}catch{$tamperedStage=$true};Assert $tamperedStage 'A tampered cached payload was silently reused'
Copy-Item -LiteralPath (Join-Path $schema2Root 'ReShade64.dll') -Destination $stagedPayload -Force
$tooSmall=$false;try{StageLocalComponentPackage $schema2Root $readOnly (Join-Path $fixture 'too-small-cache') 1|Out-Null}catch{$tooSmall=$true};Assert $tooSmall 'Oversized component package was written into the staging cache'
$globalLimitRoot=Join-Path $fixture 'global-limit-cache';$globalTooSmall=$false;try{StageLocalComponentPackage $schema2Root $readOnly $globalLimitRoot 536870912 $null 1|Out-Null}catch{$globalTooSmall=$true};Assert ($globalTooSmall -and @(Get-ChildItem -LiteralPath $globalLimitRoot -Force).Count -eq 0) 'Global cache limit allowed a package to be staged'
$recoveryRoot=Join-Path $fixture 'stage-recovery-cache';$partialPath=Join-Path $recoveryRoot ('.stage-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($partialPath);[IO.File]::WriteAllText((Join-Path $partialPath 'incomplete'),'interrupted')
$recoveredStage=StageLocalComponentPackage $schema2Root $readOnly $recoveryRoot;Assert ($recoveredStage.State -eq 'staged' -and -not(Test-Path -LiteralPath $partialPath)) 'A safe interrupted staging directory was not recovered before retry'
$failedStageRoot=Join-Path $fixture 'failed-stage-cache';$copyFailed=$false;try{StageLocalComponentPackage $schema2Root $readOnly $failedStageRoot 536870912 {param($source,$destination) Copy-Item -LiteralPath $source -Destination $destination;if($destination.EndsWith('ReShade64.dll')){throw 'injected staging copy failure'}}|Out-Null}catch{$copyFailed=$true}
Assert ($copyFailed -and @(Get-ChildItem -LiteralPath $failedStageRoot -Directory -Force -ErrorAction SilentlyContinue|Where-Object {$_.Name -like '.stage-*'}).Count -eq 0) 'Interrupted staging did not report failure and clean its exact temporary directory'
Assert ((HashFile $mp) -eq $prior -and (HashFile (Join-Path $game 'dxgi.dll')) -eq $oldHash) 'Component staging mutated the installed game or receipt'
Assert ((HashFile $mp) -eq $prior -and (HashFile (Join-Path $game 'dxgi.dll')) -eq $oldHash -and (HashFile (Join-Path $schema2Root 'ReShade64.dll')) -eq $newHash -and (HashFile $schema2Path) -eq $schema2CatalogHash) 'Schema-2 planning mutated a receipt, game file or package input'
$rejected=$false;try{ReadLocalComponentPackage $schema2Root}catch{$rejected=$true};Assert $rejected 'Schema-2 catalog crossed the schema-1 install entry point'
$schema2.ManagerRange.MinInclusive='1.0.78';[IO.File]::WriteAllText($schema2Path,($schema2|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
Assert ((GetLocalComponentPackageReadOnlyPlan $schema2Root $manifest).State -eq 'blocked') 'Out-of-range manager accepted'
$schema2.ManagerRange.MinInclusive='1.0.77-beta.0';$schema2.Requires=@([ordered]@{ComponentId='OptiShade.Effects';Version='1.0.0';Contract='effect-host/v1'});[IO.File]::WriteAllText($schema2Path,($schema2|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
Assert ((GetLocalComponentPackageReadOnlyPlan $schema2Root $manifest).Reason -match 'Dependency resolution') 'Unresolved exact dependency was not blocked'
$incompleteSet=GetLocalComponentPackageSetReadOnlyPlan @($schema2Root) $manifest
Assert ($incompleteSet.State -eq 'blocked' -and $incompleteSet.Reason -match 'Dependency set is incomplete' -and -not $incompleteSet.MutationsAllowed) 'Package-set resolver did not identify a missing exact dependency before staging'
$schema2.Requires=@();$schema2.AtomicGroup=[ordered]@{Id='fixture-renderer-group';Members=@('OptiShade.Core','OptiShade.Effects')};[IO.File]::WriteAllText($schema2Path,($schema2|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
Assert ((GetLocalComponentPackageReadOnlyPlan $schema2Root $manifest).Reason -match 'explicitly selected complete package set') 'Partial atomic group was not blocked'
$incompleteAtomicSet=GetLocalComponentPackageSetReadOnlyPlan @($schema2Root) $manifest
Assert ($incompleteAtomicSet.State -eq 'blocked' -and $incompleteAtomicSet.Reason -match 'Atomic group fixture-renderer-group is incomplete' -and -not $incompleteAtomicSet.MutationsAllowed) 'Package-set resolver did not identify an incomplete atomic group before staging'
$schema2.Remove('AtomicGroup');$schema2.Channel='research-only';[IO.File]::WriteAllText($schema2Path,($schema2|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
Assert ((GetLocalComponentPackageReadOnlyPlan $schema2Root $manifest).State -eq 'research') 'Research-only component was offered as stable/private candidate'
$schema2.Channel='private-candidate';$schema2.AutoActivate=$true;[IO.File]::WriteAllText($schema2Path,($schema2|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
$rejected=$false;try{GetLocalComponentPackageReadOnlyPlan $schema2Root $manifest}catch{$rejected=$true};Assert $rejected 'Auto-activation metadata was accepted'
$schema2.AutoActivate=$false;$schema2.Provenance.LicenseSha256=('0'*64);[IO.File]::WriteAllText($schema2Path,($schema2|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
$rejected=$false;try{GetLocalComponentPackageReadOnlyPlan $schema2Root $manifest}catch{$rejected=$true};Assert $rejected 'Mismatched legal-notice hash was accepted'
$schema2.Provenance.LicenseSha256=$licenseHash;$schema2.Contracts.RuntimeProtocolSchema='999';[IO.File]::WriteAllText($schema2Path,($schema2|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
$rejected=$false;try{GetLocalComponentPackageReadOnlyPlan $schema2Root $manifest}catch{$rejected=$true};Assert $rejected 'Schema-2 package with a mismatched runtime contract was accepted'
$schema2.Contracts.RuntimeProtocolSchema=$protocolVersion;$schema2.Contracts.ProviderPolicySha256=('0'*64);[IO.File]::WriteAllText($schema2Path,($schema2|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
$rejected=$false;try{GetLocalComponentPackageReadOnlyPlan $schema2Root $manifest}catch{$rejected=$true};Assert $rejected 'Schema-2 package with a mismatched provider-policy contract was accepted'
$schema2.Contracts.ProviderPolicySha256=$providerPolicyHash
$schema2.Provenance.LicenseSha256=$licenseHash;$schema2.Transaction.RollbackRequired=$false;[IO.File]::WriteAllText($schema2Path,($schema2|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
$rejected=$false;try{GetLocalComponentPackageReadOnlyPlan $schema2Root $manifest}catch{$rejected=$true};Assert $rejected 'Schema-2 package without mandatory verified-owner rollback was accepted'
$schema2.Transaction.RollbackRequired=$true;$schema2.Target.ProcessNames=@();[IO.File]::WriteAllText($schema2Path,($schema2|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
$rejected=$false;try{GetLocalComponentPackageReadOnlyPlan $schema2Root $manifest}catch{$rejected=$true};Assert $rejected 'Schema-2 package without process target prerequisites was accepted'
$schema2.Target.ProcessNames=@('fixture.exe');$manifest.ComponentPackages=@([pscustomobject]@{Id='Core';Version='1.0.3';Identity='installed-fixture'});[IO.File]::WriteAllText($schema2Path,($schema2|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
Assert ((GetLocalComponentPackageReadOnlyPlan $schema2Root $manifest).Reason -match 'newer component version') 'Schema-2 planner offered a downgrade'
$manifest.ComponentPackages=@([pscustomobject]@{Id='Core';Version='1.0.2';Identity='different-fixture'});Assert ((GetLocalComponentPackageReadOnlyPlan $schema2Root $manifest).Reason -match 'different package identity') 'Same-version schema-2 identity replacement was offered'
$manifest.ComponentPackages=@()
Write-Output 'PASS: local component package, alias mapping, version independence, compatibility, mutable protection, digest checks, downgrade guard and rollback.'
Write-Output 'PASS: schema-2 read-only planning, target/transaction contracts, manager range, dependency/group blocking, research status, legal-notice hash, per-package/global-bounded local stage cache, staged status, tamper/reuse/size/interruption/recovery guards, downgrade guard and schema-1 mutation boundary.'
