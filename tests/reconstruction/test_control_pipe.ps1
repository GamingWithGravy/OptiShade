param([string]$ControlTests)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $root 'Beta/installer/runtime-control.ps1')
. (Join-Path $root 'Beta/installer/auto-compatibility.ps1')
InitializeOptiShadeRuntimeControl
$receiptSnapshot=[pscustomobject]@{pid=42;birth='123';binding=[pscustomobject]@{executable='C:\Games\Sim\game.exe';evidence='os_image_birth_and_pipe_pid'};mfg=[pscustomobject]@{installationProvider=$null;installationProviderEvidence='';policyDecision=$null;policyDecisionEvidence='';loadedProvider='unverified';loadedProviderVerified=$false;frameGeneration=$null;sourceInput=$null;sourceInputEvidence='source-frame identity is not reported by the current provider';stage='provider_unavailable';requestedMultiplier=$null;accepted=$false;effectiveObservedRatio=$null;latestOutputSampleAgeMs=$null;firstBlockingReason='provider_unavailable'}}
$receiptManifest=[pscustomobject]@{Status='Installed';Game='C:\Games\Sim';LaunchExe='C:\Games\Sim\game.exe';SourceMfg=$true;OptionalMfg=$false;Sm86Mfg=$false;FrameGenerationRoute=$null;ProviderPolicy=[pscustomobject]@{Schema=1;Channel='stable';Requested='source';RecordedSource=$true;RecordedLegacy=$false;RecordedSm86=$false;Evidence='installation_only'}}
$joined=AddOptiShadeRuntimeInstallerEvidence $receiptSnapshot $receiptManifest 'C:\Games\Sim'
if($joined.mfg.installationProvider -cne 'source' -or $joined.mfg.policyDecision -cne 'source' -or $joined.mfg.installationProviderEvidence -notlike 'matching game manifest receipt*' -or $joined.mfg.sourceInput -ne $null){throw 'Matching local receipt was not exposed separately from unknown source-frame identity.'}
$caseSnapshot=$receiptSnapshot|ConvertTo-Json -Depth 8|ConvertFrom-Json
$caseManifest=$receiptManifest|ConvertTo-Json -Depth 8|ConvertFrom-Json
$caseSnapshot.binding.executable='C:\GAMES\SIM\GAME.EXE'
$caseManifest.Game='c:\games\sim';$caseManifest.LaunchExe='c:\games\sim\game.exe'
$caseJoined=AddOptiShadeRuntimeInstallerEvidence $caseSnapshot $caseManifest 'C:\Games\Sim'
if($caseJoined.mfg.installationProvider -cne 'source' -or $caseJoined.mfg.policyDecision -cne 'source'){throw 'Windows path casing differences hid a matching OS-bound receipt.'}
$joined|Add-Member auto ([pscustomobject]@{state='waiting_for_rendering_context';renderingAdapterLuid='42';api='d3d12';outputId='display-1';features=[pscustomobject]@{}}) -Force
$rendered=FormatOptiShadeAutoRuntimeSnapshot $joined
if($rendered -notmatch 'MFG receipt: installation provider=source; policy decision=source\.' -or $rendered -notmatch 'does not prove loaded files or visible output' -or $rendered -notmatch 'loaded provider=unknown' -or $rendered -notmatch 'source input=unknown \(source-frame identity is not reported by the current provider\)' -or $rendered -notmatch 'requested multiplier=unknown; accepted=False; observed ratio=unknown; latest sample age=unknown; first blocker=provider_unavailable'){throw 'The manager runtime status hid install/runtime evidence distinctions or inferred unknown values.'}
$mismatched=AddOptiShadeRuntimeInstallerEvidence $receiptSnapshot $receiptManifest 'C:\Games\Other'
if($mismatched.mfg.installationProvider -ne $null -or $mismatched.mfg.policyDecision -ne $null){throw 'Receipt from another selected game was attached to the live session.'}
$receiptManifest.SourceMfg=$false;$mismatched=AddOptiShadeRuntimeInstallerEvidence $receiptSnapshot $receiptManifest 'C:\Games\Sim'
if($mismatched.mfg.installationProvider -ne $null -or $mismatched.mfg.policyDecision -ne $null){throw 'Inconsistent manifest/provider receipt was accepted.'}
$receiptManifest.SourceMfg=$true;$receiptSnapshot.binding.executable='C:\Games\Sim\helper.exe';$mismatched=AddOptiShadeRuntimeInstallerEvidence $receiptSnapshot $receiptManifest 'C:\Games\Sim'
if($mismatched.mfg.installationProvider -ne $null -or $mismatched.mfg.policyDecision -ne $null){throw 'A helper process was incorrectly bound to another rendering executable receipt.'}
$receiptSnapshot.binding.executable='C:\Games\Sim\game.exe';$receiptManifest.SourceMfg=$false;$receiptManifest.OptionalMfg=$true;$receiptManifest.ProviderPolicy.RecordedSource=$false;$receiptManifest.ProviderPolicy.RecordedLegacy=$true;$receiptManifest.ProviderPolicy.Requested='legacy'
if((AddOptiShadeRuntimeInstallerEvidence $receiptSnapshot $receiptManifest 'C:\Games\Sim').mfg.installationProvider -cne 'legacy'){throw 'A matching legacy-provider receipt was not identified.'}
$receiptManifest.OptionalMfg=$false;$receiptManifest.Sm86Mfg=$true;$receiptManifest.ProviderPolicy.RecordedLegacy=$false;$receiptManifest.ProviderPolicy.RecordedSm86=$true;$receiptManifest.ProviderPolicy.Requested='sm86'
if((AddOptiShadeRuntimeInstallerEvidence $receiptSnapshot $receiptManifest 'C:\Games\Sim').mfg.installationProvider -cne 'sm86'){throw 'A matching SM86-provider receipt was not identified.'}
$receiptManifest.ProviderPolicy.Evidence='pinned_upstream_installation'
if((AddOptiShadeRuntimeInstallerEvidence $receiptSnapshot $receiptManifest 'C:\Games\Sim').mfg.installationProvider -cne 'sm86'){throw 'The direct SM86 installer receipt shape was not recognized.'}
$receiptManifest.ProviderPolicy.Requested='legacy'
if((AddOptiShadeRuntimeInstallerEvidence $receiptSnapshot $receiptManifest 'C:\Games\Sim').mfg.installationProvider -ne $null){throw 'A pinned SM86 receipt with a conflicting policy decision was accepted.'}
$receiptManifest.ProviderPolicy.Evidence='installation_only';$receiptManifest.ProviderPolicy.Requested='sm86'
$receiptManifest.Sm86Mfg=$false;$receiptManifest.ProviderPolicy.RecordedSm86=$false;$receiptManifest.ProviderPolicy.Requested='native'
if((AddOptiShadeRuntimeInstallerEvidence $receiptSnapshot $receiptManifest 'C:\Games\Sim').mfg.installationProvider -cne 'none_recorded'){throw 'A no-add-on receipt state was not distinguished from an unknown decision.'}
$receiptManifest.ProviderPolicy.Requested='unknown_adapter'
if((AddOptiShadeRuntimeInstallerEvidence $receiptSnapshot $receiptManifest 'C:\Games\Sim').mfg.policyDecision -cne 'unknown_adapter'){throw 'A recognized adapter-selection blocker was hidden from the manager.'}
$receiptManifest.FrameGenerationRoute='portable-fsr2x';$receiptManifest.ProviderPolicy.Requested='portable-fsr2x'
if((AddOptiShadeRuntimeInstallerEvidence $receiptSnapshot $receiptManifest 'C:\Games\Sim').mfg.installationProvider -cne 'portable-fsr2x'){throw 'A matching portable route receipt was not identified.'}
$receiptManifest.PSObject.Properties.Remove('Sm86Mfg')
if((AddOptiShadeRuntimeInstallerEvidence $receiptSnapshot $receiptManifest 'C:\Games\Sim').mfg.installationProvider -cne 'portable-fsr2x'){throw 'A current portable receipt without a false Sm86Mfg top-level flag was not recognized.'}
$receiptManifest|Add-Member Sm86Mfg $null -Force
if((AddOptiShadeRuntimeInstallerEvidence $receiptSnapshot $receiptManifest 'C:\Games\Sim').mfg.installationProvider -ne $null){throw 'A malformed present flag was treated as an omitted false flag.'}
$receiptManifest|Add-Member Sm86Mfg $false -Force
$receiptManifest.ProviderPolicy.RecordedSm86=$true
$receiptManifest.PSObject.Properties.Remove('Sm86Mfg')
if((AddOptiShadeRuntimeInstallerEvidence $receiptSnapshot $receiptManifest 'C:\Games\Sim').mfg.installationProvider -ne $null){throw 'A missing top-level flag for a recorded installed provider was accepted.'}
$receiptManifest|Add-Member Sm86Mfg $false -Force;$receiptManifest.ProviderPolicy.RecordedSm86=$false
$receiptManifest.FrameGenerationRoute=$null;$receiptManifest.SourceMfg=$true;$receiptManifest.OptionalMfg=$true;$receiptManifest.ProviderPolicy.RecordedSource=$true;$receiptManifest.ProviderPolicy.RecordedLegacy=$true
if((AddOptiShadeRuntimeInstallerEvidence $receiptSnapshot $receiptManifest 'C:\Games\Sim').mfg.installationProvider -ne $null){throw 'Conflicting provider receipts were reported as a single installed provider.'}
$unbound=[pscustomobject]@{pid=42;birth='123';mfg=[pscustomobject]@{installationProvider=$null;installationProviderEvidence='';policyDecision=$null;policyDecisionEvidence=''}}
if((AddOptiShadeRuntimeInstallerEvidence $unbound $receiptManifest 'C:\Games\Sim').mfg.installationProvider -ne $null){throw 'A receipt was joined without OS-bound process evidence.'}
Add-Type -TypeDefinition @'
using System;using System.IO.Pipes;using System.Threading;using System.Threading.Tasks;
public static class SilentControlFixture {
 public static Task Begin(int pid){return Task.Run(()=>{using(var server=new NamedPipeServerStream("OptiShade.Control.v1."+pid,PipeDirection.InOut,1,PipeTransmissionMode.Message,PipeOptions.Asynchronous)){server.WaitForConnection();Thread.Sleep(3000);}});}
}
'@
$silent=[SilentControlFixture]::Begin($PID)
$watch=[Diagnostics.Stopwatch]::StartNew();$timedOut=$false
try{[void][OptiShadeControlClient]::Send($PID,(NewOptiShadeRuntimeRequest $PID))}catch{$timedOut=$true}
if(-not $timedOut -or $watch.ElapsedMilliseconds -gt 2800){throw 'Silent-server client deadline failed'}
$controlBinary=if($ControlTests){$ControlTests}else{Join-Path $root 'test-results/control-tests.exe'}
if(-not(Test-Path -LiteralPath $controlBinary -PathType Leaf)){throw 'Compiled native control test fixture is required.'}
$server=Start-Process -FilePath $controlBinary -ArgumentList 'pipe-fixture' -WindowStyle Hidden -PassThru
$manifestFile=$null
try{
 $gameRoot=Split-Path -Parent (Resolve-Path -LiteralPath $controlBinary).Path
 $manifestFile=Join-Path $env:TEMP ('OptiShade-control-receipt-'+[guid]::NewGuid().ToString('N')+'.json')
 $persistedReceipt=[pscustomobject]@{Status='Installed';Game=$gameRoot;LaunchExe=(Resolve-Path -LiteralPath $controlBinary).Path;SourceMfg=$true;OptionalMfg=$false;Sm86Mfg=$false;ProviderPolicy=[pscustomobject]@{Schema=1;Channel='stable';Requested='source';RecordedSource=$true;RecordedLegacy=$false;RecordedSm86=$false;Evidence='installation_only'}}
 [IO.File]::WriteAllText($manifestFile,($persistedReceipt|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
 $process=[Diagnostics.Process]::GetProcessById($server.Id)
 try{$fixtureBirth=$process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture)}finally{$process.Dispose()}
 $receiptTask=[OptiShadeControlClient]::BeginSnapshot($gameRoot,$persistedReceipt.LaunchExe,'0',[uint32]$server.Id,$fixtureBirth,$manifestFile)
 if(-not $receiptTask.Wait(3000)){throw 'Background runtime snapshot plus local receipt read exceeded deadline'}
 $receiptSnapshot=$receiptTask.GetAwaiter().GetResult()|ConvertFrom-Json
 if(-not $receiptSnapshot.installerReceipt -or $receiptSnapshot.installerReceipt.Status -cne 'Installed'){throw 'Background runtime snapshot did not attach the selected installation receipt.'}
 $receiptSnapshot=AddOptiShadeRuntimeInstallerEvidence $receiptSnapshot $receiptSnapshot.installerReceipt $gameRoot
 if($receiptSnapshot.mfg.installationProvider -cne 'source' -or $receiptSnapshot.mfg.policyDecision -cne 'source'){throw 'OS-bound runtime and local provider receipt did not join.'}
 $snapshot=$null
 for($attempt=0;$attempt -lt 4 -and -not $snapshot;$attempt++){try{$snapshot=GetOptiShadeRuntimeSnapshot $server.Id}catch{if($attempt -eq 3){throw};Start-Sleep -Milliseconds 100}}
 if($snapshot.schema -ne [OptiShadeControlClient]::ProtocolSchema -or $snapshot.mfg.provider -ne 'optishade-source-mfg' -or [string]::IsNullOrEmpty([string]$snapshot.birth)){throw 'Bad fixture handshake or protocol schema'}
 if($null -ne $snapshot.mfg.effectiveObservedRatio){throw 'Unknown output became a ratio'}
 $wrong=NewOptiShadeRuntimeRequest $server.Id 'snapshot' 'another-session'
 $reply=[OptiShadeControlClient]::Send($server.Id,$wrong)|ConvertFrom-Json
 if($reply.code -ne 'wrong_session'){throw 'Wrong session accepted'}
 $task=[OptiShadeControlClient]::Begin($server.Id,(NewOptiShadeRuntimeRequest $server.Id))
 if(-not $task.Wait(3000)){throw 'Asynchronous client exceeded deadline'}
 if(($task.Result|ConvertFrom-Json).code -ne 'ok'){throw 'Asynchronous request failed'}
 # Connect without sending anything: server must evict the client and recover.
 $abandoned=[IO.Pipes.NamedPipeClientStream]::new('.','OptiShade.Control.v1.'+$server.Id,[IO.Pipes.PipeDirection]::InOut)
 try{$abandoned.Connect(500);Start-Sleep -Milliseconds 1200}finally{$abandoned.Dispose()}
 $snapshot=GetOptiShadeRuntimeSnapshot $server.Id
 if($snapshot.code -ne 'ok'){throw 'Server did not recover from abandoned client'}
 'Real local named-pipe handshake, async client, session rejection, abandoned-client timeout and reconnect passed. Provider data was a labelled fixture.'
}finally{if($manifestFile -and (Test-Path -LiteralPath $manifestFile)){Remove-Item -LiteralPath $manifestFile -Force};if(-not $server.HasExited){Stop-Process -Id $server.Id -Force};$server.Dispose()}
$errorServer=Start-Process -FilePath $controlBinary -ArgumentList 'pipe-error-fixture' -WindowStyle Hidden -PassThru
try{
 $process=[Diagnostics.Process]::GetProcessById($errorServer.Id)
 try{$errorBirth=$process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture)}finally{$process.Dispose()}
 $reported=$false
 $gameRoot=Split-Path -Parent (Resolve-Path -LiteralPath $controlBinary).Path
 $errorTask=[OptiShadeControlClient]::BeginSnapshot($gameRoot,(Resolve-Path -LiteralPath $controlBinary).Path,'0',[uint32]$errorServer.Id,$errorBirth)
 try{[void]$errorTask.GetAwaiter().GetResult()}catch{if($_.Exception.GetBaseException().Message -match 'Runtime snapshot failed: internal_error'){$reported=$true}else{throw}}
 if(-not $reported){throw 'The manager discovery path hid the bound C# runtime internal_error code.'}
 $intentionalErrorId=[guid]::NewGuid().ToString('N')
 $request=[ordered]@{schema=(GetOptiShadeRuntimeProtocolSchema);pid=[uint32]$errorServer.Id;birth=$errorBirth;id=$intentionalErrorId;operation='auto.configure'}
 $requestText=$request|ConvertTo-Json -Compress
 $response=[OptiShadeControlClient]::Send([uint32]$errorServer.Id,$requestText)|ConvertFrom-Json
 if($response.code -cne 'snapshot_too_large' -or [uint32]$response.pid -ne [uint32]$errorServer.Id -or [string]$response.birth -cne $errorBirth -or [string]$response.id -cne $intentionalErrorId){throw 'Oversized-response fallback lost its code, trusted session identity or request id.'}
 $intent=[pscustomobject]@{Pid=[uint32]$errorServer.Id;Birth=$errorBirth;LastRequest=$requestText;Terminal=$false;State='requesting';Reason=''}
 CompleteOptiShadeAutoSessionCommand $intent $response
 if(-not $intent.Terminal -or $intent.State -cne 'request_failed' -or $intent.Reason -notlike '*snapshot_too_large*'){throw 'Auto did not retain the specific pipe fallback error.'}
 if((GetOptiShadeRuntimeSnapshot $errorServer.Id).code -cne 'ok'){throw 'Pipe server did not recover after fallback errors.'}
 'Production C# client surfaced schema-v2 pipe errors with matching PID, birth and request id; the Auto UI retained the specific failure and the pipe recovered.'
}finally{if(-not $errorServer.HasExited){Stop-Process -Id $errorServer.Id -Force};$errorServer.Dispose()}
