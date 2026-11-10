$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if(-not ('Windows.Visibility' -as [type])){Add-Type -TypeDefinition 'namespace Windows { public enum Visibility { Visible, Hidden, Collapsed } }'}
. (Join-Path $root 'Beta/installer/manager-status.ps1')
$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Beta/installer/manager.ps1'),[ref]$null,[ref]$errors)
if($errors.Count){throw $errors[0]}
$managerSource=Get-Content -LiteralPath (Join-Path $root 'Beta/installer/manager.ps1') -Raw
if($managerSource -match '\$status\.Text=\(if\(' -or $managerSource -notmatch '\$launchMessage=if\(' -or $managerSource -notmatch '\$status\.Text=\$launchMessage\+\$autoMfgMessage'){throw 'Play status construction must assign the branch result before setting Text.'}
if($managerSource -notmatch "foreach\(\`$id in @\('Effects','Neural','OptiMfg','Cockpit','Providers'\)"){throw 'OptiMFG payload additions must surface as component updates for existing installations.'}
$statusSource=Get-Content -LiteralPath (Join-Path $root 'Beta/installer/manager-status.ps1') -Raw
if($statusSource -notmatch '\$folder=GetFusionGameTargetFolder \$game \$store' -or $statusSource -notmatch 'saved receipt belongs to another installation'){throw 'Component status scans must resolve canonical game targets and verify receipt ownership.'}
if($managerSource -notmatch 'Refresh is an inventory operation only' -or $managerSource -match 'EnsureVerifiedModularPayload -RequiredIds @\(\$requiredIds'){throw 'Update Manager refresh must stay metadata-only and must not stage all optional packages.'}
if($managerSource -notmatch 'GetOptiShadeModularUpdatePackageId \(\[string\]\$item\.Id\)'){throw 'Each online component package must be staged inside its own update-row transaction.'}
if($managerSource -notmatch 'RefreshModularComponentChannels' -or $managerSource -notmatch 'onlineComponentChannelFailures'){throw 'Modular update refresh must report per-channel results while continuing with successful components.'}
if($statusSource -notmatch 'if\(\$Context\.ModularDistribution\)\{' -or $statusSource -notmatch 'OnlineComponentVersions'){throw 'Payload-free manager status must use independently verified component-channel versions.'}
if($managerSource -notmatch '\$notYetOnline=@\(\$desired\|Where-Object \{\$_ -eq ''Mfg''\}\)'){throw 'Neural Rendering and Glass Cockpit must remain selectable through their independent download routes.'}
$managerXaml=Get-Content -LiteralPath (Join-Path $root 'Beta/installer/manager.xaml') -Raw
if($managerXaml -notmatch 'x:Name="AddonCoreStatus"' -or $managerXaml -notmatch 'x:Name="AddonCoreStatusDot"' -or $managerSource -notmatch '\$coreStatus\.Text=''Installed • required • managed in Setup''' -or $managerSource -notmatch '\$coreStatus\.Foreground=''#55DCA5'''){throw 'The Setup-managed Core must show a green installed state on the Components page.'}
if($managerXaml -match 'Private diagnostics|ClearDiagnostics' -or $managerSource -match 'ClearDiagnostics'){throw 'The obsolete private diagnostics card and local Clear diagnostics control must be removed.'}
$troubleshooterSource=Get-Content -LiteralPath (Join-Path $root 'Beta/installer/Troubleshooter/src/Shell.cs') -Raw
if($troubleshooterSource -notmatch 'No copy stays on this PC once the relay has confirmed every part' -or $troubleshooterSource -notmatch 'PendingReports\.Discard\(Path\.GetDirectoryName\(zip\)\)'){throw 'A successfully uploaded diagnostic report must be deleted from its local pending folder.'}
if($managerXaml -match 'AddonMfgAutoStart' -or $managerSource -match 'AddonMfgAutoStart|OptiMfgAutoStartOnPlay'){throw 'Automatic startup belongs to the game runtime, without a card toggle or separate Play path.'}
if($managerXaml -notmatch 'x:Name="AddonMfgStart"'){throw 'Manual OptiMFG recovery start must remain available.'}
foreach($name in @('StartManagedUpdates','TestOperationCancelRequested','AssertOperationNotCancelled','GetManagerScanProgressText','InvokeManagedUpdateFollowUp','GetManagedUpdateRows','TestManagerStatusCurrent','GetUpdateResultPresentation','GetCachedManagerGameStatus','GetManagerUpdateVerificationGap','TestManagerUpdateInstallationVerified','ReconcileCompletedUpdateResults','RefreshUpdateBatchSummary')){
 $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 Invoke-Expression $node.Extent.Text
}
function Assert($condition,$message){if(-not $condition){throw $message}}
function WriteInstallerLog{}
$script:managerStatusState=[pscustomobject]@{Busy=$false;Error='';Key='new';Snapshot=[pscustomobject]@{Key='old';Rows=@('stale')}}
Assert (-not (TestManagerStatusCurrent) -and @((GetManagedUpdateRows)).Count -eq 0) 'A stale completed snapshot kept old update badges visible while rechecking'
$script:managerStatusState.Snapshot.Key='new'
Assert ((TestManagerStatusCurrent) -and @((GetManagedUpdateRows)).Count -eq 1) 'Current verified update rows were hidden'
$script:managerStatusState.Busy=$true
Assert (@((GetManagedUpdateRows)).Count -eq 0) 'Rows remained actionable while a status scan was busy'
$script:managerStatusState.Busy=$false;$script:managerStatusState.Error='scan failed'
Assert (@((GetManagedUpdateRows)).Count -eq 0) 'Rows remained visible after current verification failed'
$script:managerStatusState=$null
$completePresentation=GetUpdateResultPresentation 'Complete'
Assert ($completePresentation.Color -eq '#56D9A0' -and $completePresentation.Button -eq 'Complete' -and $completePresentation.IsComplete) 'A successful update was presented as a warning or retry'
$failedPresentation=GetUpdateResultPresentation 'Not updated: fixture failure'
Assert ($failedPresentation.Color -eq '#FFBE83' -and $failedPresentation.Button -eq 'Retry update' -and -not $failedPresentation.IsComplete) 'A failed update lost its warning and retry action'
$pendingPresentation=GetUpdateResultPresentation 'Update completed, but verification still finds an available update.'
Assert ($pendingPresentation.Color -eq '#FFBE83' -and $pendingPresentation.Button -eq 'Retry update' -and -not $pendingPresentation.IsComplete) 'A post-update verification mismatch lost its warning and retry action'
$script:updateResults=@{'A|Neural'='Complete'};$script:updateResultScanGeneration=@{'A|Neural'=7}
$pendingAfterUpdate=@([pscustomobject]@{Key='A|Neural'})
ReconcileCompletedUpdateResults $pendingAfterUpdate 7
Assert ($script:updateResults['A|Neural'] -like 'Update completed, but verification still finds*') 'A completed operation stayed green when the fresh scan still found an update'
$recordA=[pscustomobject]@{Folder='A';Error='';Manifest=[pscustomobject]@{Game='A';Status='Installed'}}
$recordB=[pscustomobject]@{Folder='B';Error='';Manifest=[pscustomobject]@{Game='B';Status='Installed'}}
$script:managerStatusState=[pscustomobject]@{Snapshot=[pscustomobject]@{ByPath=@{(GetOptiShadeManagerStatusKey 'A')=$recordA;(GetOptiShadeManagerStatusKey 'B')=$recordB}}}
$script:updateResults=@{'A|Neural'='Complete'};$script:updateResultScanGeneration=@{'A|Neural'=7}
ReconcileCompletedUpdateResults @() 7
Assert ($script:updateResults['A|Neural'] -eq 'Complete' -and $script:updateResultScanGeneration['A|Neural'] -eq 'verified') 'A fresh scan that cleared the update did not retain verified completion'
$recordA.Error='canonical receipt could not be read'
$script:updateResults=@{'A|Neural'='Complete';'B|Neural'='Complete'};$script:updateResultScanGeneration=@{'A|Neural'=7;'B|Neural'=7}
ReconcileCompletedUpdateResults @() 8
Assert ($script:updateResults['A|Neural'] -eq 'Complete' -and $script:updateResultScanGeneration['A|Neural'] -eq 8) 'An installation-specific scan error was incorrectly accepted as proof of a current component'
Assert ($script:updateResultScanGeneration['B|Neural'] -eq 'verified') 'A scan error for one game prevented a separate successfully checked game from being verified'
$recordA.Error=''
ReconcileCompletedUpdateResults @() 9
Assert ($script:updateResultScanGeneration['A|Neural'] -eq 'verified') 'A later successful canonical scan did not verify the previously errored installation'
$script:updateResults=@{'A|Neural'='Complete'};$script:updateResultScanGeneration=@{'A|Neural'='verified'}
ReconcileCompletedUpdateResults @([pscustomobject]@{Key='A|Neural'}) 8
Assert (-not $script:updateResults.ContainsKey('A|Neural')) 'A later genuine update remained hidden behind an old completion result'
Write-Output 'PASS: stale update snapshots are hidden while scanning; completed results reconcile against a fresh scan, expose verification mismatches, and do not hide later updates.'
$activity=[pscustomobject]@{Text='';Foreground=''};$controls=@{UpdatesActivity=$activity}
$form=[pscustomobject]@{Controls=$controls};$form|Add-Member ScriptMethod FindName {param($name) $this.Controls[$name]}
$status=[pscustomobject]@{Text='';Foreground=''}
$recordA=[pscustomobject]@{Folder='A';Error='';Manifest=[pscustomobject]@{Game='A';Status='Installed'}}
$script:managerStatusState=[pscustomobject]@{Busy=$false;Error='';Key='current';Snapshot=[pscustomobject]@{Key='current';ByPath=@{(GetOptiShadeManagerStatusKey 'A')=$recordA}}}
$script:updateBatchKeys=@('A|Neural')
$script:updateResults=@{'A|Neural'='Complete'};$script:updateResultScanGeneration=@{'A|Neural'=8}
RefreshUpdateBatchSummary
Assert ($activity.Text -like 'Update operations finished. Verifying*' -and $activity.Foreground -eq '#FFBE83') 'The batch banner claimed completion before the post-update scan finished'
$script:updateResultScanGeneration['A|Neural']='verified';RefreshUpdateBatchSummary
Assert ($activity.Text -eq 'Updates completed and verified. You can start your games.' -and $activity.Foreground -eq '#56D9A0') 'A verified update did not turn the batch result green'
$script:updateResults['A|Neural']='Update completed, but verification still finds an available update.';RefreshUpdateBatchSummary
Assert ($activity.Text -like 'Update operations finished, but verification still finds an update*' -and $activity.Foreground -eq '#FFBE83') 'The batch banner hid an update still reported by the fresh verifier'
$script:updateResults['A|Neural']='Complete';$recordA.Error='Receipt could not be read';RefreshUpdateBatchSummary
Assert ($activity.Text -like 'Update operations finished, but installed files could not be verified*') 'A verifier error was presented as a successful update'
$script:updateResults['A|Neural']='Not updated: access denied';$recordA.Error='';RefreshUpdateBatchSummary
Assert ($activity.Text -like 'Finished with 1 update*' -and $activity.Foreground -eq '#FFBE83') 'An operation failure was not reflected in the batch summary'
# A finished scan that cannot confirm the update names the reason instead of
# leaving the banner on Verifying for good, and a later confirming scan clears it.
$script:updateResults=@{'A|Neural'='Complete'};$script:updateResultScanGeneration=@{'A|Neural'=8};$script:updateResultUnconfirmed=@{};$script:updateResultLogged=@{}
$script:verifyLog=@();function WriteInstallerLog($text){$script:verifyLog+=$text}
$recordA.Manifest=[pscustomobject]@{Game='C:\Elsewhere';Status='Installed'}
$script:managerStatusState|Add-Member -Force NoteProperty Generation 8
ReconcileCompletedUpdateResults @() 8;ReconcileCompletedUpdateResults @() 8;RefreshUpdateBatchSummary
Assert ($activity.Text -like 'Update operations finished, but the check afterwards could not confirm 1 installation(s): the installation receipt names C:\Elsewhere*' -and $activity.Foreground -eq '#FFBE83') 'A finished scan that could not confirm the update left the banner on Verifying'
Assert ($script:verifyLog.Count -eq 1 -and $script:verifyLog[0] -like 'Update verification could not confirm A|Neural: *') 'The unconfirmed reason was not logged exactly once'
$recordA.Manifest=[pscustomobject]@{Game='A';Status='Installed'}
ReconcileCompletedUpdateResults @() 9;RefreshUpdateBatchSummary
Assert ($activity.Text -eq 'Updates completed and verified. You can start your games.') 'A later confirming scan did not turn an unconfirmed update green'
$script:updateResultScanGeneration=@{'A|Neural'=10};RefreshUpdateBatchSummary
Assert ($activity.Text -like 'Update operations finished. Verifying*') 'A scan still in progress was reported as unconfirmed'
Write-Output 'PASS: batch summary waits for fresh verification and distinguishes green verified, yellow mismatch, scan error, unconfirmed and operation failure states.'
$form=[pscustomobject]@{Control=[pscustomobject]@{Text='';Foreground=''}}
$form|Add-Member ScriptMethod FindName {param($name) return $this.Control}
$status=[pscustomobject]@{Text='';Foreground=''};$Payload='fixture';$progress={}
$script:rows=@();$script:calls=@();$script:updateResults=@{};$script:busy=$false;$script:statusScanRequests=0
$script:managerStatusState=[pscustomobject]@{Busy=$false;Error='';Key='update-test';Snapshot=[pscustomobject]@{Key='update-test';Rows=@()};Generation=40}
$script:blocked=@();$script:outdated=@('Effects','Neural');$script:core=$true
function GetManagedUpdateRows {return $script:rows}
# Risk consent is exercised by the dedicated batch preflight fixture.
function ConfirmUpdateBatchProtection($queue){}
function RunAction($action,$activity){$script:busy=$true;try{& $action}finally{$script:busy=$false}}
function WaitForManagerVerification{return $false}
function ReadOptiShadeState($mp){[pscustomobject]@{Game=$mp;Status='Installed';AllFxInstalled=$false}}
function AssertClosed($game){if($game -in $script:blocked){throw 'Close the game first.'}}
function GetOptiShadeFriendlyError($ErrorRecord){return $ErrorRecord.Exception.Message}
function TestBundledUpdateVersion($m){return $script:core}
function SetSelectedFusionGame($game){$script:selected=$game.Name}
function SyncMethodSelection{}
function InvokeRepairInstall([switch]$UpdateApproved,[switch]$ModularPackageApproved){Assert $UpdateApproved 'Core update must use explicit queue approval';$script:calls+='Core';$script:core=$false}
function GetComponentUpdateIds($m){return $script:outdated}
function GetFusionGpu{[pscustomobject]@{Names='Fixture'}}
function ShowNeuralAdapterPicker($mp){$script:pickerCalls++;return $script:pickerAccepted}
function InstallOptiShadeAddon($mp,$payload,$id,$gpu,$progress,[switch]$SkipAllFx){$script:calls+=($mp+'|'+$id);if($id -eq 'Effects'){Assert $SkipAllFx 'Existing selective effects install must be preserved'};if($id -eq 'Neural' -and $script:failFirstNeural){$script:failFirstNeural=$false;throw 'Neural preparation needs a measured adapter candidate: Multiple physical NVIDIA adapters remain possible.'}}
function UpdateOperationProgress{}
function PumpManagerDispatcher{}
function WriteInstallerLog{}
function RefreshHeaderGlassCockpitUpdateState{}
function RefreshUpdateManager{}
function RequestManagerStatusScan([switch]$Force){if(-not $Force){throw 'Post-update verification must force a fresh scan.'};$script:statusScanRequests++;if($script:managerStatusState.PSObject.Properties['Generation']){$script:managerStatusState.Generation++}else{$script:managerStatusState|Add-Member NoteProperty Generation 1}}
function NewRow($folder,$id,[bool]$manual=$false){[pscustomobject]@{Folder=$folder;ManifestPath=$folder;Id=$id;Manual=$manual;Key=$folder+'|'+$id;Label=$id;Game=[pscustomobject]@{Name=$folder}}}
$script:rows=@((NewRow 'A' 'Core'),(NewRow 'A' 'Effects'),(NewRow 'B' 'Effects'),(NewRow 'C' 'Cockpit' $true))
$script:pickerCalls=0;$script:pickerAccepted=$false;$script:failFirstNeural=$false
$script:blocked=@('B')
StartManagedUpdates
Assert (($script:calls -join ',') -eq 'Core,A|Effects') ("Update all must preserve order, skip running games and exclude manual files (calls={0}, scans={1}, results={2})" -f ($script:calls -join ','),$script:statusScanRequests,($script:updateResults|ConvertTo-Json -Compress))
Assert ($script:statusScanRequests -eq 1 -and $script:updateResultScanGeneration['A|Core'] -eq 41 -and $script:updateResultScanGeneration['A|Effects'] -eq 41) 'Successful updates did not trigger a fresh post-write scan before result reconciliation'
Assert ($script:updateResults['B|Effects'] -match 'Close the game') 'Blocked game must retain actionable failure'
Assert (-not $script:updateResults.ContainsKey('C|Cockpit')) 'Manual files must not enter update all'
# A receipt may change after its snapshot; verify its installation again before
# any current receipt can redirect an old displayed action to a different game.
function ReadOptiShadeState($mp){[pscustomobject]@{Game='other-game';Status='Installed';AllFxInstalled=$false}}
$script:calls=@();StartManagedUpdates 'A' 'Effects'
Assert ($script:calls.Count -eq 0 -and $script:updateResults['A|Effects'] -match 'different game') 'Changed receipt redirected a cached update row'
function ReadOptiShadeState($mp){[pscustomobject]@{Game=$mp;Status='Installed';AllFxInstalled=$false}}
$script:calls=@();$script:blocked=@();StartManagedUpdates 'B' 'Effects'
Assert (($script:calls -join ',') -eq 'B|Effects') 'Per-game/component retry updated unrelated installations'
Assert ($script:updateResults['B|Effects'] -eq 'Complete') 'Retry did not replace failure'
$script:calls=@();$script:outdated=@();StartManagedUpdates 'A' 'Effects'
Assert ($script:calls.Count -eq 0) 'Stale row must not reinstall a component'
$script:outdated=@('Effects');$script:busy=$true;StartManagedUpdates
Assert ($script:calls.Count -eq 0) 'Busy guard did not prevent reentrant mutation'
$script:busy=$false;$script:blocked=@('A');$script:calls=@();StartManagedUpdates
Assert (($script:calls -join ',') -eq 'B|Effects') 'Failure must not abort later game updates'
# When Neural preparation finds multiple physical NVIDIA candidates, the
# manager should offer the explicit per-game picker and retry that one row.
$script:rows=@((NewRow 'N' 'Neural'));$script:outdated=@('Neural');$script:calls=@();$script:pickerCalls=0;$script:pickerAccepted=$true;$script:failFirstNeural=$true
StartManagedUpdates 'N' 'Neural'
Assert ($script:pickerCalls -eq 1 -and $script:calls.Count -eq 2) ("Ambiguous Neural update did not prompt once and retry only the selected component. picker=$script:pickerCalls calls=$($script:calls -join ',') result=$($script:updateResults['N|Neural'])")
Assert ($script:updateResults['N|Neural'] -eq 'Complete') 'Successful adapter selection retry was left in a failed state.'
# Cancelling the picker must retain the original useful failure and never retry.
$script:calls=@();$script:pickerCalls=0;$script:pickerAccepted=$false;$script:failFirstNeural=$true
StartManagedUpdates 'N' 'Neural'
Assert ($script:pickerCalls -eq 1 -and $script:calls.Count -eq 1 -and $script:updateResults['N|Neural'] -match 'Multiple physical NVIDIA adapters') 'Cancelling adapter selection must not retry or hide the original update error.'
$script:rows=@((NewRow 'A' 'Core'),(NewRow 'A' 'Effects'),(NewRow 'B' 'Effects'),(NewRow 'C' 'Cockpit' $true));$script:outdated=@('Effects','Neural')
$script:pickerCalls=0;$script:pickerAccepted=$false;$script:failFirstNeural=$false
$script:rows=@((NewRow 'C' 'Cockpit'));$script:calls=@()
function GetGlassCockpitUpdateInfo { [pscustomobject]@{Available=$true;Managed=$false;CanDownload=$false} }
function UpdateGlassCockpitAddon($mp,$release,$progress){$script:calls+='Verified updater'}
StartManagedUpdates 'C' 'Cockpit'
Assert (($script:calls -join ',') -eq 'Verified updater') 'Untracked UI metadata must not block the authoritative verified updater'
Write-Output 'PASS: Update Manager queue isolation, manual exclusion, running-game guard, retry, stale-state recheck, reentrancy and failure continuation.'

# R353: exercise the production Atmosphere branch through Update All.
. (Join-Path $root 'Beta/installer/atmosphere-mod.ps1')
$script:atmosphereLatestRelease=[pscustomobject]@{VersionText='0.6.1'}
$script:atmoInstalled=$true;$script:atmoVersion='0.5.1';$script:atmoCalls=0
function GetAtmosphereModState($game){[pscustomobject]@{Installed=$script:atmoInstalled;Version=$script:atmoVersion}}
function InstallAtmosphereMod($game,$pump,$release){$script:atmoCalls++;$script:atmoVersion=$release.VersionText;GetAtmosphereModState $game}
$script:rows=@((NewRow 'A' 'Atmosphere'));$script:blocked=@();$script:outdated=@();$script:busy=$false
StartManagedUpdates
Assert ($script:atmoCalls -eq 1 -and $script:updateResults['A|Atmosphere'] -eq 'Complete') 'Update All did not install and verify AtmosphereMod'
StartManagedUpdates -Folder A -Id Atmosphere
Assert ($script:atmoCalls -eq 1) 'A stale current AtmosphereMod row reinstalled the component'
$script:atmoVersion='0.5.1';$script:blocked=@('A')
StartManagedUpdates -Folder A -Id Atmosphere
Assert ($script:atmoCalls -eq 1 -and $script:updateResults['A|Atmosphere'] -like 'Not updated:*') 'Running-game Atmosphere update was not blocked'
$script:blocked=@();$script:atmoInstalled=$false
StartManagedUpdates -Folder A -Id Atmosphere
Assert ($script:atmoCalls -eq 1 -and $script:updateResults['A|Atmosphere'] -like 'Not updated:*') 'Uninstalled Atmosphere component was reinstalled by a stale row'
Write-Output 'PASS: AtmosphereMod Update All, already current, running-game and removed-component cases'

# Exercise the real core-update helper with file writes and UI prompts isolated.
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Beta/installer/manager.ps1'),[ref]$null,[ref]$errors)
$node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'InvokeRepairInstall'},$true)
Invoke-Expression $node.Extent.Text
$path=[pscustomobject]@{Text='FixtureGame'};$store='FixtureStore';$Installer='FixtureInstaller'
$script:installed=$false;$script:core=$true
function ManifestPath($store,$game){return $PSCommandPath}
function ReadOptiShadeState($mp){[pscustomobject]@{Game='FixtureGame';Status='Installed';Version='P1.0.18';LaunchExe='FixtureGame/game.exe'}}
function GetOptiShadeRepairAction($m){'Update OptiShade'}
function GetBundledOptiShadeVersion{'P1.0.20'}
function ShowOptiShadeDialog{'No'}
function GetOptiShadeInstalledLoaderPath($m){'dxgi.dll'}
function GetSelectedMethod{'DXGI'}
function ResolveOptiShadeInstallMethod($method,$proxy){$proxy}
function GetManifestMethodRendererApi{'DX12'}
function FindFusionConflicts{}
function InstallFusion($game,$payload,$store,$installer,$proxy,$conflicts,$ReplaceExisting,$PreserveConfiguration,$Progress){
 Assert $ReplaceExisting 'Core update must use the existing replacement workflow'
 Assert $PreserveConfiguration 'Core update must preserve configuration'
 $script:installed=$true;return $PSCommandPath
}
function WriteState{}
function SetOnlineComponentPackageReceipt{}
function CompleteManualManagerInstall{}
function EnsureVerifiedModularPayload{}
function ConfirmManagerCoreInstallation($mp){Assert $script:installed 'Core confirmation ran before installation';$script:confirmed=$true}
InvokeRepairInstall -UpdateApproved
Assert ($script:installed -and $script:confirmed) 'Approved core update must install and confirm before reporting success'
$script:installed=$false;InvokeRepairInstall
Assert $script:installed 'User-triggered repair runs without an extra confirmation prompt'
$script:core=$false;$rejected=$false
try{InvokeRepairInstall -UpdateApproved}catch{$rejected=$true}
Assert $rejected 'Stale core update must not downgrade or reinstall'
Write-Output 'PASS: approved core update reaches the preserving installer; ordinary repair consent and stale-version guard remain.'

. (Join-Path $root 'Beta/installer/manager-status.ps1')
function GetOptiShadeAddonSelection($manifest){@($manifest.Components)}
function GetOptiShadeModularUpdatePackageId([string]$component){switch -CaseSensitive ($component){'Core'{'OptiShade.Core'}'Effects'{'OptiShade.Effects'}'OptiMfg'{'OptiShade.OptiMFG'}'Providers'{'OptiShade.Providers'}default{''}}}
$onlineVersions=@{
 'OptiShade.Core'=[pscustomobject]@{Component='OptiShade.Core';Version='1.0.77'}
 'OptiShade.Effects'=[pscustomobject]@{Component='OptiShade.Effects';Version='1.0.2'}
 'OptiShade.OptiMFG'=[pscustomobject]@{Component='OptiShade.OptiMFG';Version='1.0.1'}
}
$modularRecord=[pscustomobject]@{Manifest=[pscustomobject]@{Components=@('Effects','OptiMfg');OnlineComponentPackages=@([pscustomobject]@{Id='OptiShade.Core';Version='1.0.77'},[pscustomobject]@{Id='OptiShade.Effects';Version='1.0.1'},[pscustomobject]@{Id='OptiShade.OptiMFG';Version='1.0.1'})};Info=[pscustomobject]@{Core=$false;Components=@();Target='';Text=''}}
AddOptiShadeModularChannelUpdates ([pscustomobject]@{OnlineComponentVersions=$onlineVersions}) $modularRecord
Assert (-not $modularRecord.Info.Core -and $modularRecord.Info.Components.Count -eq 1 -and $modularRecord.Info.Components[0] -eq 'Effects') 'Signed package version comparison should offer only the changed installed component.'
Assert ($modularRecord.OnlinePackages.Effects.Id -eq 'OptiShade.Effects' -and $modularRecord.OnlinePackages.Effects.NeedsUpdate) 'Changed component row must carry only its independent package channel.'
Write-Output 'PASS: modular component update discovery offers only installed first-party packages with newer signed versions.'
$rowContext=[pscustomobject]@{Release=[pscustomobject]@{SHA256=('a'*64)};LocalPackage=$null}
$rowRecord=[pscustomobject]@{Game=[pscustomobject]@{Name='MSFS fixture'};Folder='FixtureGame';ManifestPath='FixtureGame';Manifest=[pscustomobject]@{Version='old'};Info=[pscustomobject]@{Core=$false;Components=@()};Glass=[pscustomobject]@{Available=$true;Managed=$false;CanAdopt=$false;CanDownload=$false;InstalledVersion='v0.8.3';LatestVersion='v1.0.0'}}
$local=[pscustomobject]@{Available=$false}
$rows=@(GetOptiShadeManagerSnapshotRows $rowContext $rowRecord $local)
Assert ($rows.Count -eq 1 -and -not $rows[0].Manual) 'UI must offer the direct update despite untracked metadata'
Assert ($rows[0].Detail -notmatch 'not managed') 'Tracking status must not be presented as a permission denial'
$rowContext.Release.SHA256=''
$rows=@(GetOptiShadeManagerSnapshotRows $rowContext $rowRecord $local)
Assert $rows[0].Manual 'Unverified download metadata must still require refresh'
Write-Output 'PASS: production snapshot row builder enables the authoritative update independently of tracking metadata, without bypassing download digest requirements.'

$script:localComponentPackage=[pscustomobject]@{Catalog=[pscustomobject]@{Id='Core';Version='1.0.1'}}
$rowContext.LocalPackage=$script:localComponentPackage;$local.Available=$true
$rows=@(GetOptiShadeManagerSnapshotRows $rowContext $rowRecord $local)
Assert (@($rows|Where-Object {$_.Id -eq 'Core' -and $_.LocalPackage}).Count -eq 1) 'Local package not routed to Update Manager'
$script:rows=@($rows|Where-Object {$_.Id -eq 'Core'});$script:calls=@();$script:blocked=@()
function GetManagedUpdateRows{$script:rows}
function InstallLocalComponentPackage($mp,$package,$progress){$script:calls+='Local package'}
StartManagedUpdates
Assert (($script:calls -join ',') -eq 'Local package') 'Local component queue fell through to bundled core installer'
Write-Output 'PASS: local package row and Update component dispatch remain separate from bundled installer.'
# A package selection changes the snapshot generation immediately. Old labels
# must never dispatch the newly selected package before its scan completes.
$script:managerStatusState=[pscustomobject]@{Busy=$true;Error='';Key='B';Snapshot=[pscustomobject]@{Key='A'}}
$script:calls=@();StartManagedUpdates
Assert ($script:calls.Count -eq 0) 'Pending snapshot allowed stale local-package mutation'
$script:managerStatusState.Busy=$false;StartManagedUpdates
Assert ($script:calls.Count -eq 0) 'Mismatched snapshot key allowed stale local-package mutation'
$script:managerStatusState.Snapshot.Key='B';$script:managerStatusState.Error='failed';StartManagedUpdates
Assert ($script:calls.Count -eq 0) 'Failed verification allowed an outdated row to mutate an installation'
$script:managerStatusState.Error='';StartManagedUpdates
Assert (($script:calls -join ',') -eq 'Local package') 'Matching completed snapshot did not restore the update action'
$script:managerStatusState=$null
Write-Output 'PASS: pending, failed and mismatched snapshot generations cannot dispatch stale local-package rows.'


# Header and navigation must follow current rows, even with stale library flags.
foreach($name in @('RefreshHeaderComponentUpdateState','RefreshUpdateNavigation')){
 $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 Invoke-Expression $node.Extent.Text
}
$controls=@{
 UpdatesNav=[pscustomobject]@{Foreground='';Background='';BorderBrush='';Content='icon stays'}
 UpdatesNavLabel=[pscustomobject]@{Text=''}
 UpdatesPage=[pscustomobject]@{Visibility='Visible'}
 HeaderComponentUpdateAvailable=[pscustomobject]@{Visibility='';Content='';ToolTip=''}
}
$form=[pscustomobject]@{Controls=$controls}
$form|Add-Member ScriptMethod FindName {param($name) $this.Controls[$name]}
$form|Add-Member ScriptMethod FindResource {param($name) $name}
$script:updateResults=@{}
$script:currentRows=@([pscustomobject]@{Id='Neural';Folder='A'})
function GetManagedUpdateRows{$script:currentRows}
RefreshHeaderComponentUpdateState
Assert ($controls.HeaderComponentUpdateAvailable.Visibility -eq 'Visible' -and $controls.UpdatesNav.Background -eq '#35271C') 'Pending component must highlight both entry points'
$script:currentRows=@();$script:libraryGames=@([pscustomobject]@{UpdateTarget='Components';ComponentUpdateIds=@('Neural')})
RefreshHeaderComponentUpdateState
Assert ($controls.HeaderComponentUpdateAvailable.Visibility -eq 'Collapsed') 'Completed update left stale header badge'
Assert ($controls.UpdatesNav.Background -eq 'NavPurple' -and $controls.UpdatesNavLabel.Text -eq 'Update Manager') 'Completed update left stale orange navigation'
Assert ($controls.UpdatesNav.Content -eq 'icon stays') 'Navigation refresh replaced the icon layout'
$script:updateResults=@{'A|Core'='Not updated: fixture receipt error'}
RefreshHeaderComponentUpdateState
Assert ($controls.HeaderComponentUpdateAvailable.Visibility -eq 'Visible' -and $controls.HeaderComponentUpdateAvailable.Content -eq 'Update results need attention') 'A failed update lost its header attention badge after pending rows cleared'
Assert ($controls.UpdatesNav.Background -eq '#35271C' -and $controls.UpdatesNavLabel.Text -like 'Update Manager*') 'A failed update lost its orange navigation state after pending rows cleared'
$script:updateResults=@{}
$controls.UpdatesPage.Visibility='Collapsed';RefreshUpdateNavigation
Assert ($controls.UpdatesNav.Background -eq 'Transparent') 'Inactive navigation retains selected styling'
Write-Output 'PASS: current receipt rows clear stale badges and restore navigation styling without destroying the icon.'

# Batch completion must refresh every card, independent of Setup selection.
Add-Type -AssemblyName PresentationFramework
$node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'RefreshLibrary'},$true)
Invoke-Expression $node.Extent.Text
$games=@('A','B','C')|ForEach-Object {[pscustomobject]@{Name=$_;Folder=$_;Launcher='Fixture';State='old';Label='old'}}
$controls.MsfsCopies=[pscustomobject]@{ItemsSource=@($games)}
$path=[pscustomobject]@{Text='A'}
$script:libraryGames=@($games|ForEach-Object {[pscustomobject]@{Folder=$_.Folder;State='Component update available';Installed=$true;StatusColor='#FFBE83';ActionLabel='Manage';Description='old';UpdateButtonVisibility='Visible';UpdateTarget='Components';ComponentUpdateIds=@('Neural')}})
function GetFusionGameTargetFolder($game){$game.Folder}
function GetFusionInstallState{throw 'Library rendering must not read receipts'}
function GetCachedManagerGameStatus($game){[pscustomobject]@{State='Installed'}}
function RequestManagerStatusScan([switch]$Force){Assert $Force 'Post-action refresh must invalidate all game status';$script:scanRequested=$true}
function GetGameUpdateInfo($game){if($game.Folder -eq 'C'){[pscustomobject]@{Target='Components';Text='Component update available';Components=@('Neural')}}else{[pscustomobject]@{Target='';Text='';Components=@()}}}
function UpdateLibraryGrid{}
function RefreshHomeState{}
RefreshLibrary
Assert $script:scanRequested 'Post-operation refresh did not request background verification'
foreach($card in $script:libraryGames|Where-Object Folder -in @('A','B')){
 Assert ($card.State -eq 'Installed' -and $card.StatusColor -eq '#56D9A0' -and $card.UpdateButtonVisibility -eq 'Collapsed' -and -not $card.ComponentUpdateIds.Count) 'Completed game retained stale yellow Library state'
}
Assert ($script:libraryGames[2].StatusColor -eq '#FFBE83' -and $script:libraryGames[2].UpdateTarget -eq 'Components') 'Unfinished game lost its pending update warning'
Write-Output 'PASS: batch refresh clears completed Library cards outside Setup selection and retains pending updates.'

# Exercise the deferred follow-up dispatcher without touching any installation.
& {
 function TestManagerStatusCurrent {return $script:followScanReady}
 function GetManagedUpdateRows {return $script:followRows}
 function StartManagedUpdates([switch]$FollowUp,[string[]]$AllowedKeys){
  Assert $FollowUp 'Follow-up must be bounded, never another unrestricted Update all'
  $script:followCalls++;$script:followKeys=$AllowedKeys
 }
 $script:busy=$false;$script:followCalls=0;$script:followKeys=@();$script:followScanReady=$true
 $script:managerStatusState=[pscustomobject]@{Generation=10}
 $script:followRows=@((NewRow 'A' 'Core'),(NewRow 'A' 'Effects'),(NewRow 'A' 'Neural' $true),(NewRow 'A' 'Providers'),(NewRow 'B' 'Core'))
 $script:updateFollowUp=[pscustomobject]@{Generation=11;Allowed=@('A|Core','A|Effects','A|Neural');Attempted=@('A|Effects')}
 InvokeManagedUpdateFollowUp
 Assert ($script:followCalls -eq 0 -and $script:updateFollowUp) 'Older scan consumed pending follow-up'
 $script:managerStatusState.Generation=11;$script:followScanReady=$false;InvokeManagedUpdateFollowUp
 Assert ($script:followCalls -eq 0) 'Incomplete scan dispatched updates'
 $script:followScanReady=$true;InvokeManagedUpdateFollowUp
 Assert ($script:followCalls -eq 1 -and ($script:followKeys -join ',') -eq 'A|Core') 'Follow-up included attempted, manual, absent or unrelated component'
 InvokeManagedUpdateFollowUp
 Assert ($script:followCalls -eq 1 -and -not $script:updateFollowUp) 'Follow-up was not consumed before dispatch'
}
Write-Output 'PASS: one fresh follow-up includes only new authorised rows; stale/error scans, previous attempts and unrelated components cannot dispatch.'


# One run: OptiMFG that becomes available only after Core lands joins the same
# batch right after that game's Core row, and Cancel stops before the next row.
function UpdateOperationProgress{};function PumpManagerDispatcher{};function WriteInstallerLog{};function RefreshUpdateManager{};function RefreshHeaderGlassCockpitUpdateState{}
function NewRow($folder,$id){[pscustomobject]@{Folder=$folder;ManifestPath=$folder;Id=$id;Manual=$false;LocalPackage=$null;Key=$folder.ToLowerInvariant()+'|'+$id;Label=$id;Game=[pscustomobject]@{Name=$folder}}}
function ReadOptiShadeState($mp){[pscustomobject]@{Game=$mp;Status='Installed';AllFxInstalled=$true;Components=@('OptiMfg')}}
function AssertClosed($game){}
function SetSelectedFusionGame($game){};function SyncMethodSelection{}
$script:coreDone=@{}
function TestBundledUpdateVersion($m){return -not $script:coreDone[[string]$m.Game]}
function InvokeRepairInstall([switch]$UpdateApproved,[switch]$ModularPackageApproved){$script:calls+=($script:selectedGame+'|Core');$script:coreDone[$script:selectedGame]=$true}
function SetSelectedFusionGame($game){$script:selectedGame=[string]$game.Name}
function GetComponentUpdateIds($m){if($script:coreDone[[string]$m.Game] -and -not $script:mfgDone[[string]$m.Game]){return @('OptiMfg')};return @()}
$script:mfgDone=@{}
function InstallSelectedOptiMfgComponent($mp){$script:calls+=($mp+'|OptiMfg');$script:mfgDone[$mp]=$true;if($script:cancelAfterFirstMfg){[IO.File]::WriteAllText($script:operationCancelPath,'x')}}
$controls=@{UpdatesActivity=[pscustomobject]@{Text='';Foreground=''}};$form=[pscustomobject]@{Controls=$controls};$form|Add-Member ScriptMethod FindName {param($name) $this.Controls[$name]};$status=[pscustomobject]@{Text='';Foreground=''}
$script:managerStatusState=[pscustomobject]@{Busy=$false;Error='';Key='k';Generation=1;Snapshot=[pscustomobject]@{Key='k';Rows=@()}}
$script:rows=@((NewRow 'MSFS' 'Core'),(NewRow 'ETS2' 'Core'))
function GetManagedUpdateRows{$script:rows}
$script:updateResults=@{};$script:updateResultScanGeneration=@{};$script:updateResultUnconfirmed=@{};$script:calls=@();$script:operationCancelPath=$null;$script:cancelAfterFirstMfg=$false
StartManagedUpdates
Assert (($script:calls -join ',') -eq 'MSFS|Core,MSFS|OptiMfg,ETS2|Core,ETS2|OptiMfg') ('Follow-on OptiMFG did not join the same run after each Core update (calls='+($script:calls -join ',')+')')
Assert ($script:updateResults['msfs|OptiMfg'] -eq 'Complete' -and $script:updateResults['ets2|OptiMfg'] -eq 'Complete') 'Follow-on rows were not recorded as complete'
Assert ($script:updateFollowUp.Attempted -contains 'msfs|OptiMfg') 'An in-run follow-on would be offered again by the later scan'
$script:coreDone=@{};$script:mfgDone=@{};$script:calls=@();$script:updateResults=@{}
$script:operationCancelPath=Join-Path ([IO.Path]::GetTempPath()) ('optishade-cancel-'+[guid]::NewGuid().ToString('N'));$script:cancelAfterFirstMfg=$true
StartManagedUpdates
Assert (($script:calls -join ',') -eq 'MSFS|Core,MSFS|OptiMfg') ('Cancel did not stop before the next update (calls='+($script:calls -join ',')+')')
Assert ($script:updateResults['ets2|Core'] -like 'Not updated: cancelled*' -and $script:operationCancelled) 'Rows after a cancel were not reported as not started'
Remove-Item -LiteralPath $script:operationCancelPath -Force -ErrorAction SilentlyContinue;$script:operationCancelPath=$null;$script:operationCancelled=$false
# Verification inside the run: the update reports its verified outcome itself
# and does not leave a second check running after the window closes.
$script:coreDone=@{};$script:mfgDone=@{};$script:calls=@();$script:updateResults=@{};$script:cancelAfterFirstMfg=$false;$script:statusScanRequests=0
$script:verifyRequested=0;function WaitForManagerVerification{$script:verifyRequested++;return $true}
function RefreshUpdateBatchSummary{$script:updateBatchMessage='Updates completed and verified. You can start your games.';$form.FindName('UpdatesActivity').Text=$script:updateBatchMessage}
function InvokeManagedUpdateFollowUp{}
$script:operationAttention=$false
StartManagedUpdates
Assert ($script:verifyRequested -eq 1 -and $script:statusScanRequests -eq 0) 'The update did not verify inside its own run, or started a second check afterwards'
Assert ($form.FindName('UpdatesActivity').Text -like 'Updates completed and verified*' -and -not $script:operationAttention) 'A verified run did not finish with the verified result'
function RefreshUpdateBatchSummary{$script:updateBatchMessage='Update operations finished, but the check afterwards could not confirm 1 installation(s): x';$form.FindName('UpdatesActivity').Text=$script:updateBatchMessage}
$script:coreDone=@{};$script:mfgDone=@{};$script:updateResults=@{};$script:operationAttention=$false
StartManagedUpdates
Assert ($script:operationAttention) 'An unconfirmed verification inside the run was reported as a clean finish'
function WaitForManagerVerification{return $false}
Write-Output 'PASS: updates for every game, follow-on OptiMFG included, run as one batch and are verified before the run finishes; Cancel stops before the next update.'
