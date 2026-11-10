param([string]$Root=(Join-Path $PSScriptRoot '../..'))
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -eq 'Core'){throw 'Run with Windows PowerShell 5.1 -STA, matching the packaged manager host.'}
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'The dispatcher fixture requires -STA.'}
$Root=[IO.Path]::GetFullPath($Root)
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
. (Join-Path $Root 'Beta/installer/manager-lifetime.ps1')
. (Join-Path $Root 'Beta/installer/ownership.ps1')
. (Join-Path $Root 'Beta/installer/manager-status.ps1')
. (Join-Path $Root 'Beta/installer/library.ps1')
$script:removedGames=@{};$script:favoriteGames=@{};$script:libraryPreferences=@{InstalledFirst=$true;FavoritesOnly=$false}
function Check($Value,[string]$Message){if(-not $Value){throw $Message};Write-Output ('PASS: '+$Message)}

# Instrumentation is shared with the real PowerShell worker runspaces, without
# a process, network request, installed game, or receipt write.
Add-Type -TypeDefinition @'
using System.Collections.Concurrent;
public static class OptiShadeManagerResponsivenessTrace {
 public static readonly ConcurrentQueue<string> Started = new ConcurrentQueue<string>();
 public static readonly ConcurrentQueue<string> Stages = new ConcurrentQueue<string>();
}
'@
$script:fixtureWorker=@'
param($context)
$ErrorActionPreference='Stop'
[OptiShadeManagerResponsivenessTrace]::Started.Enqueue([string]$context.Key)
function ReadFixtureReceiptStatus {
 [OptiShadeManagerResponsivenessTrace]::Stages.Enqueue($context.Key+':receipts')
 Start-Sleep -Milliseconds $context.DelayMs
}
function ReadFixtureComponentHashes {
 [OptiShadeManagerResponsivenessTrace]::Stages.Enqueue($context.Key+':component-hashes')
 Start-Sleep -Milliseconds $context.DelayMs
}
function ReadFixtureHardwareStatus {
 [OptiShadeManagerResponsivenessTrace]::Stages.Enqueue($context.Key+':hardware')
 Start-Sleep -Milliseconds $context.DelayMs
}
ReadFixtureReceiptStatus
ReadFixtureComponentHashes
ReadFixtureHardwareStatus
if($context.Fail){throw 'fixture snapshot failure'}
[pscustomobject]@{Key=$context.Key;SelectedGame=$context.SelectedGame;Rows=@();Games=@{};Complete=$true}
'@
$script:releasedWorkers=0
$script:stoppedWorkers=0
$script:workerHandles=[Collections.Generic.List[object]]::new()
$script:startFixtureWorker={param($context)
 $worker=NewOptiShadeManagerWorker
 [void]$worker.AddScript($script:fixtureWorker).AddArgument($context)
 $handle=[pscustomobject]@{Shell=$worker;Async=$worker.BeginInvoke()}
 $script:workerHandles.Add($handle)
 return $handle
}
$script:releaseFixtureWorker={param($worker)
 $script:releasedWorkers++
 RemoveOptiShadeManagerWorker $worker.Shell
}
$script:stopFixtureWorker={param($worker)
 $script:stoppedWorkers++
 [void]$script:managerWorkers.Remove($worker.Shell)
 [OptiShadeManagerWorkerCleanup]::Release($worker.Shell)
}
function NewFixtureContext([string]$Key,[int]$DelayMs=500,[switch]$Fail){
 [pscustomobject]@{Key=$Key;SelectedGame=$Key;DelayMs=$DelayMs;Fail=[bool]$Fail}
}

# This pumps a real WPF dispatcher but never calls Window.Show/ShowDialog.
# Render priority is a scheduling proxy for first paint, not a visual FPS test.
function PumpFixtureDispatcher([scriptblock]$Tick,[scriptblock]$Until,[int]$TimeoutMs=10000){
 $frame=[Windows.Threading.DispatcherFrame]::new()
 $timer=[Windows.Threading.DispatcherTimer]::new()
 $timer.Interval=[TimeSpan]::FromMilliseconds(15)
 $probe=[pscustomobject]@{Watch=[Diagnostics.Stopwatch]::StartNew();Failure=$null;Previous=0L;MaxGap=0L;Ticks=0}
 $handler=[EventHandler]{
  try{
   $now=$probe.Watch.ElapsedMilliseconds
   $probe.MaxGap=[Math]::Max($probe.MaxGap,$now-$probe.Previous)
   $probe.Previous=$now;$probe.Ticks++
   & $Tick $now
   if(& $Until){$frame.Continue=$false}
   elseif($now -gt $TimeoutMs){throw "Dispatcher fixture timed out after $TimeoutMs ms"}
  }catch{$probe.Failure=$_;$frame.Continue=$false}
 }.GetNewClosure()
 $timer.Add_Tick($handler)
 try{$timer.Start();[Windows.Threading.Dispatcher]::PushFrame($frame)}
 finally{$timer.Stop();$timer.Remove_Tick($handler);$probe.Watch.Stop()}
 if($probe.Failure){throw $probe.Failure}
 return $probe
}

InitializeOptiShadeManagerLifetime
$script:fixtureState=NewOptiShadeManagerStatusState $script:startFixtureWorker $script:releaseFixtureWorker $script:stopFixtureWorker
$script:acceptedSnapshots=[Collections.Generic.List[object]]::new()
$script:renderCallbackMs=-1L
$script:refreshBRequested=$false;$script:refreshCRequested=$false
$script:fixtureClock=[Diagnostics.Stopwatch]::StartNew()
try{
 $requestWatch=[Diagnostics.Stopwatch]::StartNew()
 RequestOptiShadeManagerStatus $script:fixtureState (NewFixtureContext 'A')
 $requestWatch.Stop()
 Check ($requestWatch.ElapsedMilliseconds -lt 700) 'starting slow receipt/hash/hardware work returns before the worker completes'
 1..20|ForEach-Object {RequestOptiShadeManagerStatus $script:fixtureState (NewFixtureContext 'A')}
 $dispatcher=[Windows.Threading.Dispatcher]::CurrentDispatcher
 $renderOperation=$dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Render,[Action]{$script:renderCallbackMs=$script:fixtureClock.ElapsedMilliseconds})
 $phase=PumpFixtureDispatcher {
  param($elapsed)
  if($elapsed -ge 75 -and -not $script:refreshBRequested){
   $script:refreshBRequested=$true
   RequestOptiShadeManagerStatus $script:fixtureState (NewFixtureContext 'B')
  }
  if($elapsed -ge 125 -and -not $script:refreshCRequested){
   $script:refreshCRequested=$true
   RequestOptiShadeManagerStatus $script:fixtureState (NewFixtureContext 'C')
   1..20|ForEach-Object {RequestOptiShadeManagerStatus $script:fixtureState (NewFixtureContext 'C')}
  }
  $received=ReceiveOptiShadeManagerStatus $script:fixtureState
  if($received){$script:acceptedSnapshots.Add($received)}
 } { $script:acceptedSnapshots.Count -gt 0 -and -not $script:fixtureState.Busy }
 $started=@([OptiShadeManagerResponsivenessTrace]::Started.ToArray())
 Check ($started.Count -eq 2 -and $started[0] -eq 'A' -and $started[1] -eq 'C') 'duplicate requests coalesce and only the latest pending context runs'
 Check ([OptiShadeManagerResponsivenessTrace]::Stages.Count -eq 6) 'both completed workers perform all three slow read-only status/hash/hardware stages'
 Check ($script:acceptedSnapshots.Count -eq 1 -and $script:acceptedSnapshots[0].Context.Key -eq 'C' -and $script:fixtureState.Snapshot.Key -eq 'C') 'stale A snapshot never reaches the UI result stream after selection changes'
 Check ($script:renderCallbackMs -ge 0 -and $script:renderCallbackMs -lt 700) 'render-priority callback is dispatched while slow read-only work is running'
 Check ($phase.Ticks -gt 20 -and $phase.MaxGap -lt 700) 'dispatcher heartbeat remains responsive during both slow snapshots'
 Check ($script:releasedWorkers -eq 2 -and $script:managerWorkers.Count -eq 0) 'completed background workers release their runspaces and lifetime registrations'
 Write-Output ('METRIC: request={0} ms; render-priority callback={1} ms; maximum heartbeat gap={2} ms; heartbeats={3}' -f $requestWatch.ElapsedMilliseconds,$script:renderCallbackMs,$phase.MaxGap,$phase.Ticks)

 # A completed failure is delivered once. Polling cannot start a retry storm;
 # only an explicit fresh request/force initiates recovery.
 RequestOptiShadeManagerStatus $script:fixtureState (NewFixtureContext 'failed' 20 -Fail)
 $script:failureResults=[Collections.Generic.List[object]]::new()
 [void](PumpFixtureDispatcher {
  $received=ReceiveOptiShadeManagerStatus $script:fixtureState
  if($received){$script:failureResults.Add($received)}
 } {$script:failureResults.Count -gt 0})
 Check ($script:failureResults.Count -eq 1 -and $script:failureResults[0].Error -match 'fixture snapshot failure') 'worker failure is reported without throwing through the dispatcher'
 $startsAfterFailure=[OptiShadeManagerResponsivenessTrace]::Started.Count
 $script:unexpectedFailureCallbacks=0
 [void](PumpFixtureDispatcher {
  if(ReceiveOptiShadeManagerStatus $script:fixtureState){$script:unexpectedFailureCallbacks++}
 } {$script:unexpectedFailureCallbacks -gt 0 -or -not $script:fixtureState.Busy} 1000)
 1..25|ForEach-Object {RequestOptiShadeManagerStatus $script:fixtureState (NewFixtureContext 'failed' 20 -Fail);if(ReceiveOptiShadeManagerStatus $script:fixtureState){$script:unexpectedFailureCallbacks++}}
 Check ($script:unexpectedFailureCallbacks -eq 0 -and [OptiShadeManagerResponsivenessTrace]::Started.Count -eq $startsAfterFailure -and -not $script:fixtureState.Busy) 'repeated polling and navigation requests do not spin on a failed snapshot'
 Check ($script:fixtureState.Snapshot.Key -eq 'C') 'failed refresh preserves the last successful snapshot'
 RequestOptiShadeManagerStatus $script:fixtureState (NewFixtureContext 'failed' 20) -Force
 $script:recoveryResult=$null
 [void](PumpFixtureDispatcher {$script:recoveryResult=ReceiveOptiShadeManagerStatus $script:fixtureState} {$null -ne $script:recoveryResult})
 Check (-not $script:recoveryResult.Error -and -not $script:fixtureState.Error -and $script:fixtureState.Snapshot.Key -eq 'failed') 'explicit retry recovers and clears the prior status error'

 # Verification must never wait forever: an orphaned key mismatch is detected,
 # and a worker that never completes is stopped after its bound and reported.
 Check (-not (TestOptiShadeManagerStatusOrphaned $script:fixtureState)) 'a current snapshot is not reported as orphaned'
 $orphan=NewOptiShadeManagerStatusState {} {} {}
 Check (TestOptiShadeManagerStatusOrphaned $orphan) 'no snapshot and no running or queued work is orphaned'
 $orphan.Key='new';$orphan.Snapshot=[pscustomobject]@{Key='old'}
 Check (TestOptiShadeManagerStatusOrphaned $orphan) 'a snapshot for an older request with nothing running is orphaned'
 $orphan.Busy=$true;Check (-not (TestOptiShadeManagerStatusOrphaned $orphan)) 'a running worker is not orphaned'
 $orphan.Busy=$false;$orphan.Error='x';Check (-not (TestOptiShadeManagerStatusOrphaned $orphan)) 'a reported error is not orphaned'
 $script:stallStops=0
 $stallState=NewOptiShadeManagerStatusState $script:startFixtureWorker $script:releaseFixtureWorker {param($worker) $script:stallStops++;[void]$script:managerWorkers.Remove($worker.Shell);[OptiShadeManagerWorkerCleanup]::Release($worker.Shell)}
 RequestOptiShadeManagerStatus $stallState (NewFixtureContext 'stall' 30000)
 [void](PumpFixtureDispatcher {} { @([OptiShadeManagerResponsivenessTrace]::Started.ToArray()) -contains 'stall' } 2000)
 Check (-not (StopStalledOptiShadeManagerStatus $stallState ([TimeSpan]::FromMinutes(3)))) 'a worker inside its time bound is left running'
 Check (StopStalledOptiShadeManagerStatus $stallState ([TimeSpan]::FromMinutes(3)) ([DateTime]::UtcNow.AddMinutes(4))) 'a worker past its time bound is stopped'
 $stallResult=ReceiveOptiShadeManagerStatus $stallState
 Check ($script:stallStops -eq 1 -and -not $stallState.Busy -and $stallResult.Error -match 'did not finish within 180 seconds' -and $stallState.Error) 'stalled verification is reported once as an ordinary retryable error'
 Check ($null -eq (ReceiveOptiShadeManagerStatus $stallState)) 'the stalled-worker error is not repeated on every tick'
 StopOptiShadeManagerStatus $stallState

 RequestOptiShadeManagerStatus $script:fixtureState (NewFixtureContext 'closing' 30000)
 [void](PumpFixtureDispatcher {} { @([OptiShadeManagerResponsivenessTrace]::Started.ToArray()) -contains 'closing' } 2000)
 $closingHandle=$script:fixtureState.Worker.Handle
 RequestOptiShadeManagerStatus $script:fixtureState (NewFixtureContext 'never-start' 30000)
 $closeWatch=[Diagnostics.Stopwatch]::StartNew()
 StopOptiShadeManagerStatus $script:fixtureState
 StopOptiShadeManagerLifetime
 $closeWatch.Stop()
 Check ($closeWatch.ElapsedMilliseconds -lt 700 -and $script:fixtureState.Stopped -and -not $script:fixtureState.Busy -and $null -eq $script:fixtureState.Pending) 'closing cancels a slow active worker and discards pending work without blocking'
 $startsAtClose=[OptiShadeManagerResponsivenessTrace]::Started.Count
 $script:postCloseCallbacks=0
 $postCloseWatch=[Diagnostics.Stopwatch]::StartNew()
 [void](PumpFixtureDispatcher {
  if(ReceiveOptiShadeManagerStatus $script:fixtureState){$script:postCloseCallbacks++}
  RequestOptiShadeManagerStatus $script:fixtureState (NewFixtureContext 'after-close' 10) -Force
 } {$postCloseWatch.ElapsedMilliseconds -ge 120})
 Check ($script:postCloseCallbacks -eq 0 -and [OptiShadeManagerResponsivenessTrace]::Started.Count -eq $startsAtClose -and $script:managerWorkers.Count -eq 0) 'closed manager ignores late results/new requests and retains no registered worker'
 Check ($script:stoppedWorkers -eq 1) 'the active worker is cancelled exactly once on close'
 [void](PumpFixtureDispatcher {} {$closingHandle.Async.IsCompleted} 2000)
 Check ($closingHandle.Async.IsCompleted) 'cancelled slow worker actually completes instead of surviving as an unregistered background task'
 StopOptiShadeManagerStatus $script:fixtureState
 $startFailureState=NewOptiShadeManagerStatusState {throw 'fixture worker startup failure'} {} {}
 RequestOptiShadeManagerStatus $startFailureState (NewFixtureContext 'start-failure' 10)
 $startFailure=ReceiveOptiShadeManagerStatus $startFailureState
 Check ($startFailure.Error -match 'fixture worker startup failure' -and -not $startFailureState.Busy) 'worker startup failure reaches the same UI error stream as invocation failure'
 Check ($null -eq (ReceiveOptiShadeManagerStatus $startFailureState)) 'startup failure is consumed once instead of repeating on every dispatcher tick'
 StopOptiShadeManagerStatus $startFailureState
}finally{
 StopOptiShadeManagerStatus $script:fixtureState
 StopOptiShadeManagerLifetime
}

# Load the real manager function bodies and XAML, but none of its top-level
# startup/event registration/install paths. This exercises the UI consumers,
# not a parallel fixture implementation of navigation or component cards.
foreach($source in @('manager.ps1','component-policy.ps1','components.ps1')){
 $tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Root ('Beta/installer/'+$source)),[ref]$tokens,[ref]$errors)
 if($errors.Count){throw ($errors|Out-String)}
 if($source -eq 'manager.ps1'){
  $managerAst=$ast
  $cardSource=$ast.Find({param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.Contains('public class FusionGameCard')},$true)
  if(-not $cardSource){throw 'Production manager card type was not found.'}
  Add-Type -TypeDefinition $cardSource.Value -ReferencedAssemblies @([Windows.Media.ImageSource].Assembly.Location,[Windows.Threading.DispatcherObject].Assembly.Location,[Windows.Window].Assembly.Location,[Windows.Controls.Button].Assembly.Location,[System.Xaml.XamlReader].Assembly.Location)
 }
 foreach($definition in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
  $parent=$definition.Parent;$nested=$false
  while($parent){if($parent -is [Management.Automation.Language.FunctionDefinitionAst]){$nested=$true;break};$parent=$parent.Parent}
  if(-not $nested){. ([scriptblock]::Create($definition.Extent.Text))}
 }
}
$savedListFailure=GetStartupLibraryStatus 'fixture scan failure' '' 2
Check ($savedListFailure -match 'showing saved entries' -and $savedListFailure -match 'Scan for games' -and $savedListFailure -match 'fixture scan failure') 'failed discovery identifies the cached library and gives the actual scan retry action'
$emptyListFailure=GetStartupLibraryStatus 'fixture scan failure' '' 0
Check ($emptyListFailure -match 'Game scan failed' -and $emptyListFailure -notmatch 'showing saved entries' -and $emptyListFailure -match 'Scan for games') 'failed discovery with no cached entries gives the same actionable retry'
$snapshotFailure=GetStartupLibraryStatus '' 'fixture snapshot failure' 0
Check ($snapshotFailure -match 'Snapshot library needs attention' -and $snapshotFailure -match 'fixture snapshot failure') 'snapshot failure remains distinct when game discovery succeeds'
$scanSuccess=GetStartupLibraryStatus '' '' 3
Check ($scanSuccess -eq 'Game scan complete. Open the library to install or manage a game.') 'successful game discovery retains the normal startup status'
$script:forbiddenStatusReads=[Collections.Generic.List[string]]::new()
function FailUiStatusRead([string]$Name){$script:forbiddenStatusReads.Add($Name);throw ('Slow read-only backend ran on the UI thread: '+$Name)}
function ReadOptiShadeState {FailUiStatusRead 'ReadOptiShadeState'}
function HashFile {FailUiStatusRead 'HashFile'}
function GetFusionGpu {FailUiStatusRead 'GetFusionGpu'}
function GetNeuralRuntimeStatus {FailUiStatusRead 'GetNeuralRuntimeStatus'}
function GetLocalComponentPackageState {FailUiStatusRead 'GetLocalComponentPackageState'}
function GetGlassCockpitUpdateInfo {FailUiStatusRead 'GetGlassCockpitUpdateInfo'}
function GetComponentUpdateIds {FailUiStatusRead 'GetComponentUpdateIds'}
function GetOptiShadeExecutableIdentity {FailUiStatusRead 'GetOptiShadeExecutableIdentity'}
function GetOptiShadeInstallProviderDecision {FailUiStatusRead 'GetOptiShadeInstallProviderDecision'}
function GetFusionGameTargetFolder {FailUiStatusRead 'GetFusionGameTargetFolder'}
function StartGlassCockpitReleaseCheck {} # Network scheduler is outside this isolated test.
function CancelSnapshotCapture {}
function SaveManagerPreferences {throw 'Navigation attempted a preference write in the read-only fixture.'}
function WriteInstallerLog {}
function GetBundledOptiShadeVersion {return 'Pfixture'}
# RunAction is exercised here for dispatcher/UI behavior only. Store ownership
# and transaction semantics are covered by the dedicated ownership fixtures.
function EnterOptiShadeMutation {return $null}
function ExitOptiShadeMutation($Mutation) {}
function ManifestPath($Store,$Game){return Join-Path ([IO.Path]::GetTempPath()) 'OptiShade-manager-ui-fixture-receipt.json'}
function RecoverOptiShadeRouteTransaction($ReceiptPath) {}
function FormatOptiShadeAutoPreparation($Preparation,[string]$ManifestPath=''){return 'Fixture preparation status'}
[xml]$markup=[IO.File]::ReadAllText((Join-Path $Root 'Beta/installer/manager.xaml'))
$form=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup))
$path=$form.FindName('GamePath');$status=$form.FindName('Status')
$script:busy=$false;$script:captureState=@{HotSwap=$false;MenuKey=$false};$script:preferencesReady=$false
$script:componentSelections=@{};$script:pendingFxPresetPath='';$script:gameRoot=''
$script:updateResults=@{};$script:componentUpdateGames=@();$script:glassCockpitUpdateGames=@()
$script:pathRefreshTimer=$null;$script:glassCockpitReleaseCheckRunning=$false
$script:glassCockpitLastCheckUtc=$null;$script:glassCockpitLatestRelease=$null
$script:libraryGames=@();$script:favoriteGames=@{}
$script:libraryPreferences=@{InstalledFirst=$true;FavoritesOnly=$false}
$script:localComponentPackage=[pscustomobject]@{Root='fixture package';Catalog=[pscustomobject]@{Id='Neural';Version='fixture'}}
$componentSelectors=@('Effects','Neural','Mfg','Cockpit','Providers'|ForEach-Object {$form.FindName('Addon'+$_+'Selected')})
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('optishade-responsiveness-'+[guid]::NewGuid().ToString('N'))
$fixtureFolderA=Join-Path $fixtureRoot 'A'
$fixtureFolderB=Join-Path $fixtureRoot 'B'
[void][IO.Directory]::CreateDirectory($fixtureFolderA)
[void][IO.Directory]::CreateDirectory($fixtureFolderB)
$fixtureGameA=[pscustomobject]@{Name='Fixture A';Folder=$fixtureFolderA;InstallFolder=$fixtureFolderA;Launcher='Fixture';State='Installed'}
$fixtureGameB=[pscustomobject]@{Name='Fixture B';Folder=$fixtureFolderB;InstallFolder=$fixtureFolderB;Launcher='Fixture';State='Installed'}
foreach($fixtureGame in @($fixtureGameA,$fixtureGameB)){
 foreach($property in @{Label='';Installed=$true;StatusColor='';ActionLabel='';Description='';UpdateButtonVisibility=[Windows.Visibility]::Collapsed;UpdateTarget='';ComponentUpdateIds=@();IsFavorite=$false;DisplayName=$fixtureGame.Name}.GetEnumerator()){
  $fixtureGame|Add-Member -NotePropertyName $property.Key -NotePropertyValue $property.Value
 }
}
$form.FindName('MsfsCopies').ItemsSource=@($fixtureGameA,$fixtureGameB)
function NewCachedFixtureGame($Game,[string]$RuntimeState){
 [pscustomobject]@{
  Game=$Game;Folder=$Game.Folder;State='Installed'
  Manifest=[pscustomobject]@{Status='Installed';Game=$Game.Folder;Architecture='x64';Components=@('Neural');Files=@();AllFxInstalled=$false;Version='Pfixture'}
  Info=[pscustomobject]@{Core=$false;Components=@();Target='';Text=''}
  Glass=[pscustomobject]@{Available=$false;Installed=$false;State='Current'}
  RuntimeState=$RuntimeState;MfgRoute='unsupported_game';GameApi=$null;DetailReady=$true;Error=''
  LegacyWrapper=$false;InstalledLoader='dxgi.dll';CockpitAvailable=$false;FreeSpace='fixture free space'
 }
}
InitializeOptiShadeManagerLifetime
$script:managerStatusState=NewOptiShadeManagerStatusState $script:startFixtureWorker $script:releaseFixtureWorker $script:stopFixtureWorker
$cacheByPath=@{}
$cacheByPath[(GetOptiShadeManagerStatusKey $fixtureFolderA)]=NewCachedFixtureGame $fixtureGameA 'Verified file'
$cacheByPath[(GetOptiShadeManagerStatusKey $fixtureFolderB)]=NewCachedFixtureGame $fixtureGameB 'Missing'
$script:managerStatusState.Snapshot=[pscustomobject]@{ByPath=$cacheByPath;Rows=@();GlassTargets=@();LocalCompatibility=@();Errors=@()}
$script:libraryGames=@($fixtureGameA,$fixtureGameB)
try{
 $path.Text=$fixtureFolderA
 $cachedA=GetCachedManagerGameStatus $path.Text
 Check ($cachedA.Manifest.Game -eq $fixtureFolderA) 'cached status resolves the selected exact installation'
 $path.Text=$fixtureFolderB
 $cachedB=GetCachedManagerGameStatus $path.Text
 Check ($cachedB.Manifest.Game -eq $fixtureFolderB -and $cachedB.RuntimeState -eq 'Missing') 'changing selection resolves B status instead of reusing A status'
 Check ($null -eq (GetCachedManagerGameStatus ($fixtureFolderA+'-other'))) 'unknown installation cannot inherit a prefix-matching stale game snapshot'
 RefreshAddonCards
 Check ($form.FindName('AddonNeuralStatus').Text -match 'missing') 'production component card renders the current B snapshot'
 $cachedB.DetailReady=$false;$cachedB.MfgRoute='unavailable'
 RefreshAddonCards
 $mfgPendingSelector=$form.FindName('AddonMfgSelected')
 Check ($mfgPendingSelector.IsEnabled -and $form.FindName('AddonMfgStatus').Text -match 'Ready to install' -and $mfgPendingSelector.ToolTip -match 'checked in-game') 'production MFG card stays selectable while asynchronous provider discovery is pending'
 $cachedB.DetailReady=$true
 RefreshAddonCards
 $path.Text=$fixtureFolderA
 RefreshAddonCards
 Check ($form.FindName('AddonNeuralStatus').Text -match 'verified') 'production component card switches back to the preserved successful A snapshot'
 # A slow snapshot must not replace an unsaved per-game all-FX choice.
 # Register the production path-change callback, with an inert long-interval
 # timer, so target changes exercise its actual draft invalidation behavior.
 $script:pathRefreshTimer=[Windows.Threading.DispatcherTimer]::new()
 $script:pathRefreshTimer.Interval=[TimeSpan]::FromHours(1)
 RegisterOptiShadeManagerTimer $script:pathRefreshTimer {}
 $pathChangeRegistration=$managerAst.Find({param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Extent.Text.StartsWith('$path.Add_TextChanged(')},$true)
 if(-not $pathChangeRegistration){throw 'Production path-change callback was not found.'}
 Invoke-Expression $pathChangeRegistration.Extent.Text
 $cachedA.Manifest.Components=@('Neural','Effects');$cachedA.Manifest.AllFxInstalled=$false
 $form.FindName('InstallAllFx').IsChecked=$true;RememberAllFxSelection
 RefreshAddonCards
 Check ($form.FindName('InstallAllFx').IsChecked -eq $true -and $script:allFxDraft.Value) 'cached refresh preserves an unsaved all-FX enable choice over an older receipt'
 $path.Text=$fixtureFolderB
 RefreshAddonCards
 Check ($null -eq $script:allFxDraft -and $form.FindName('InstallAllFx').IsChecked -eq $false) 'production target-change callback clears the draft and B cannot inherit A all-FX selection'
 $path.Text=$fixtureFolderA;$cachedA.Manifest.AllFxInstalled=$true
 RefreshAddonCards
 $form.FindName('InstallAllFx').IsChecked=$false;RememberAllFxSelection
 RefreshAddonCards
 Check ($null -ne $script:allFxDraft -and -not $script:allFxDraft.Value -and $form.FindName('InstallAllFx').IsChecked -eq $false) 'cached refresh preserves an explicit unchecked draft over an all-FX installed receipt'
 # Keep operation effects isolated: execute the actual RunAction boundary
 # around no-op/failing actions, with only progress UI and path resolution
 # substituted. Neither action installs, downloads or writes a receipt.
 function ResolveFusionInstallFolder([string]$Game){return $Game}
 function StopOperationProgress([switch]$Failed){}
 $buttons=@();$script:startupResult=$null;$script:startupReady=$true;$script:uninstallDone=$true
 $script:fixtureActionReached=$false
 RunAction {$script:fixtureActionReached=$true;throw 'fixture action failure'}
 Check ($script:fixtureActionReached -and $script:operationFailed -and $null -ne $script:allFxDraft -and -not $script:allFxDraft.Value) 'failed production action preserves the pending all-FX choice for retry'
 $script:fixtureActionReached=$false
 RunAction {$script:fixtureActionReached=$true}
 Check ($script:fixtureActionReached -and -not $script:operationFailed -and $null -eq $script:allFxDraft) 'successful production action clears its consumed all-FX draft'
 $script:uninstallDone=$false
 SelectGame $fixtureGameB
 RefreshHomeState
 RefreshComponentsGameSelector
 Check ($path.Text -eq $fixtureFolderB -and $form.FindName('ComponentsGame').SelectedItem -eq $fixtureGameB -and $form.FindName('SelectedTitle').Text -eq 'Fixture B') 'production selection, Home and Components selector retain the exact cached game identity'
 RefreshLibrary -FromSnapshot
 Check ($fixtureGameA.Installed -and $fixtureGameB.Installed -and $fixtureGameA.ActionLabel -eq 'Manage') 'production Library refresh renders cached installed state without rescanning receipts'

 RequestOptiShadeManagerStatus $script:managerStatusState (NewFixtureContext 'slow-ui-refresh' 30000)
 $script:navigationSamples=[Collections.Generic.List[long]]::new()
 $script:navigationIndex=0
 $navigationProbe=PumpFixtureDispatcher {
  $page=@('Home','Library','Setup','Components','Updates')[$script:navigationIndex%5]
  $navigationWatch=[Diagnostics.Stopwatch]::StartNew()
  ShowPage $page
  if($page -eq 'Home'){RefreshHomeState}
  if($page -eq 'Library'){RefreshLibrary -FromSnapshot}
  if($page -eq 'Setup'){SelectGame $(if(($script:navigationIndex%2) -eq 0){$fixtureGameA}else{$fixtureGameB})}
  if($page -eq 'Components'){RefreshComponentsGameSelector;RefreshAddonCards}
  $navigationWatch.Stop();$script:navigationSamples.Add($navigationWatch.ElapsedMilliseconds)
  $script:navigationIndex++
 } {$script:navigationIndex -ge 20} 10000
 $slowestNavigation=($script:navigationSamples|Measure-Object -Maximum).Maximum
 Check ($slowestNavigation -lt 700 -and $navigationProbe.MaxGap -lt 700) 'real navigation and component/update rendering remain responsive during an active slow snapshot'
 Check ($form.FindName('UpdatesPage').Visibility -eq 'Visible' -and $form.FindName('HeaderBuildType').Text -eq 'Update Manager') 'repeated production navigation reaches the requested page'
 Check ($script:forbiddenStatusReads.Count -eq 0) ('cached UI consumers never invoke slow receipt/hash/hardware backends: '+($script:forbiddenStatusReads -join ', '))
 Check (-not $form.IsVisible) 'the regression fixture never shows a window'
 Write-Output ('METRIC: production navigation callbacks={0}; slowest navigation={1} ms; maximum dispatcher gap={2} ms' -f $script:navigationSamples.Count,$slowestNavigation,$navigationProbe.MaxGap)
 SelectGame $fixtureGameB
 ApplyStartupGameResults @($fixtureGameA,$fixtureGameB)
 Check ($path.Text -eq $fixtureFolderB -and $form.FindName('MsfsCopies').SelectedItem.Folder -eq $fixtureFolderB) 'late startup discovery preserves the game selected while discovery was running'
 $manualPath=Join-Path $fixtureRoot 'Manual'
 $form.FindName('MsfsCopies').SelectedItem=$null;$path.Text=$manualPath
 ApplyStartupGameResults @($fixtureGameA,$fixtureGameB)
 Check ($path.Text -eq $manualPath) 'late startup discovery preserves a manually entered path outside discovered games'
 Check ($script:forbiddenStatusReads.Count -eq 0) 'startup result application only renders cached status and schedules background verification'
}finally{
 StopOptiShadeManagerStatus $script:managerStatusState
 StopOptiShadeManagerLifetime
 $form.Close()
}

# Exercise the actual producer and all of its dot-sourced dependencies in a
# fresh runspace. Only these temporary fixture receipts are written. The
# production snapshot itself must leave them unchanged and never use network.
$producerBase=[IO.Path]::GetFullPath((Join-Path $Root 'test-run/manager-responsiveness'))
$producerRoot=Join-Path $producerBase ([guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($producerRoot)
$componentDefinition=$managerAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'GetComponentUpdateIds'},$true)
$componentBody=$componentDefinition.Body.Extent.Text
$componentBody=$componentBody.Substring(1,$componentBody.Length-2)
$producerWorker=[PowerShell]::Create()
try{
 [void]$producerWorker.AddScript(@'
param($moduleRoot,$fixtureRoot,$payload,$componentCheck)
$ErrorActionPreference='Stop'
. (Join-Path $moduleRoot 'ownership.ps1')
. (Join-Path $moduleRoot 'manager-status.ps1')
function Invoke-WebRequest {throw 'Network is forbidden in the producer fixture.'}
function Invoke-RestMethod {throw 'Network is forbidden in the producer fixture.'}
function Start-Process {throw 'External processes are forbidden in the producer fixture.'}
$fixtureStore=Join-Path $fixtureRoot 'Store'
$games=@()
foreach($name in @('Installed','Uninstalled','Malformed','Mismatched')){
 $folder=Join-Path $fixtureRoot $name;[void][IO.Directory]::CreateDirectory($folder)
 $games+=[pscustomobject]@{Name=$name;Folder=$folder;InstallFolder=$folder;Launcher='Fixture'}
}
$receipts=@()
foreach($name in @('Installed','Malformed','Mismatched')){
 $folder=Join-Path $fixtureRoot $name
 $receipt=ManifestPath $fixtureStore $folder;[void][IO.Directory]::CreateDirectory((Split-Path $receipt -Parent))
 if($name -eq 'Malformed'){$text='{ invalid fixture receipt'}
 else{
  $owner=if($name -eq 'Mismatched'){Join-Path $fixtureRoot 'Installed'}else{$folder}
  $text=[pscustomobject]@{Game=$owner;Status='Installed';Version=(GetBundledOptiShadeVersion);Files=@();Components=@();Architecture='x64';Downloads='Complete'}|ConvertTo-Json -Depth 5
 }
 [IO.File]::WriteAllText($receipt,$text,[Text.UTF8Encoding]::new($false));$receipts+=$receipt
}
$before=@{};foreach($receipt in $receipts){$before[$receipt]=(Get-FileHash -LiteralPath $receipt -Algorithm SHA256).Hash}
$context=[pscustomobject]@{Key='actual-producer';ModuleRoot=$moduleRoot;Payload=$payload;Store=$fixtureStore;Games=$games;SelectedFolder=$games[0].Folder;Release=$null;LocalPackage=$null;Gpu=[pscustomobject]@{Names='Fixture GPU';Known=$true;Nvidia=$false};ComponentCheck=$componentCheck}
$snapshot=InvokeOptiShadeManagerSnapshot $context
$unchanged=$true;foreach($receipt in $receipts){if((Get-FileHash -LiteralPath $receipt -Algorithm SHA256).Hash -ne $before[$receipt]){$unchanged=$false}}
[pscustomobject]@{Snapshot=$snapshot;Games=$games;ReceiptsUnchanged=$unchanged;GameFiles=@($games|ForEach-Object {Get-ChildItem -LiteralPath $_.Folder -File -Recurse}).Count}
'@).AddArgument((Join-Path $Root 'Beta/installer')).AddArgument($producerRoot).AddArgument((Join-Path $Root 'Beta/installer/PayloadFusion')).AddArgument($componentBody)
 $producerAsync=$producerWorker.BeginInvoke()
 [void](PumpFixtureDispatcher {} {$producerAsync.IsCompleted} 15000)
 $producerResults=@($producerWorker.EndInvoke($producerAsync))
 if($producerWorker.HadErrors){throw ($producerWorker.Streams.Error|Out-String)}
 Check ($producerResults.Count -eq 1) 'actual background snapshot producer returns one snapshot through a fresh runspace'
 $producer=$producerResults[0];$snapshot=$producer.Snapshot
 $installed=$snapshot.ByPath[(GetOptiShadeManagerStatusKey $producer.Games[0].Folder)]
 $uninstalled=$snapshot.ByPath[(GetOptiShadeManagerStatusKey $producer.Games[1].Folder)]
 $malformed=$snapshot.ByPath[(GetOptiShadeManagerStatusKey $producer.Games[2].Folder)]
 $mismatched=$snapshot.ByPath[(GetOptiShadeManagerStatusKey $producer.Games[3].Folder)]
 Check ($installed.State -eq 'Installed' -and -not $installed.Error -and $installed.DetailReady -and $installed.RuntimeState -ne 'Checking') 'real producer resolves installed receipt, component policy and selected-game runtime details'
 Check ($uninstalled.State -eq 'Not installed' -and -not $uninstalled.Manifest -and -not $uninstalled.Error) 'real producer retains a normal uninstalled game without fabricating a failure'
 Check ($malformed.Error -match 'receipt could not be read or validated' -and $malformed.State -eq 'Installation needs attention') 'malformed receipt failure is isolated to its exact game snapshot'
 Check ($mismatched.Error -match 'belongs to another installation' -and -not $mismatched.Manifest -and -not $mismatched.DetailReady) 'cross-game receipt is rejected before updates or component details can use it'
 Check (@($snapshot.Errors).Count -eq 2 -and @($snapshot.Rows).Count -eq 0) 'only malformed and mismatched fixtures report errors; neither becomes an update target'
 Check ($producer.ReceiptsUnchanged -and $producer.GameFiles -eq 0) 'production snapshot leaves receipts unchanged and writes no game files'
}finally{
 try{$producerWorker.Stop()}catch{}
 $producerWorker.Dispose()
 $resolvedFixture=[IO.Path]::GetFullPath($producerRoot)
 if(-not $resolvedFixture.StartsWith($producerBase+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Refusing fixture cleanup outside the isolated test directory.'}
 Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
}

