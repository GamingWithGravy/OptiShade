param([ValidateSet('','Auto','Cleanup','Abandon')][string]$Worker='', [string]$FixtureRoot='', [string]$ReadyPath='')
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Beta/installer/ownership.ps1"
. "$root/Beta/installer/components.ps1"
. "$root/Beta/installer/neural-download.ps1"
. "$root/Beta/installer/mfg.ps1"
. "$root/Beta/installer/auto-compatibility.ps1"
function OwnedPath([string]$Root,[string]$Relative){
 $base=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
 $target=[IO.Path]::GetFullPath((Join-Path $Root $Relative))
 if(-not $target.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture escaped its root.'}
 $check=$target;while($check){if(Test-Path -LiteralPath $check){if((Get-Item -LiteralPath $check -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked fixture refused.'}};$next=Split-Path $check -Parent;if($next -eq $check){break};$check=$next};$target
}
function AssertClosed([string]$Game){if(-not(Test-Path -LiteralPath (Join-Path $Game 'fixture-only'))){throw 'Not a closed fixture game.'}}
function AssertAntiCheatMutation([string]$Game,[string]$Exe,[string]$Action){AssertClosed $Game}
# Only the physical GPU/network/Windows-process boundaries are controlled.
# All mutexes, processes, receipts, component transactions and model journals
# below are the actual production owners and real operating-system objects.
function GetOptiShadeNeuralModelCatalog {[pscustomobject]@{Id='fixture-model';Variant='auto';Families=@(40);ModelHash=(HashFile $script:fixtureModel);Signed=$false;Family='Fixture Ada'}}
function GetVerifiedNeuralCache($Selection,[scriptblock]$Progress){return $script:fixtureModel}
function InstallNvidia([string]$Game,[scriptblock]$Progress){AssertClosed $Game}
function InstallAllEffects {throw 'Unexpected external effects acquisition.'}
function WriteFixtureExe([string]$Path){
 $bytes=New-Object byte[] 1024;$stream=[IO.MemoryStream]::new($bytes,$true);$writer=[IO.BinaryWriter]::new($stream)
 try{$writer.Write([uint16]0x5a4d);$stream.Position=0x3c;$writer.Write([uint32]0x80);$stream.Position=0x80;$writer.Write([uint32]0x4550);$writer.Write([uint16]0x8664);$writer.Write([uint16]1);$stream.Position=0x94;$writer.Write([uint16]240);$writer.Write([uint16]2);$writer.Write([uint16]0x20b);$stream.Position=0x98+60;$writer.Write([uint32]512);$stream.Position=0x98+240+8;$writer.Write([uint32]512);$writer.Write([uint32]0x1000);$writer.Write([uint32]512);$writer.Write([uint32]512)}finally{$writer.Dispose()};[IO.File]::WriteAllBytes($Path,$bytes)
}
if(-not $FixtureRoot){$FixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-store-mutation-'+[guid]::NewGuid().ToString('N'))}
$store=Join-Path $FixtureRoot 'OptiShade';$game=Join-Path $FixtureRoot 'game';$payload=Join-Path $FixtureRoot 'payload'
$script:fixtureModel=Join-Path $FixtureRoot 'fixture-model';$manifest=ManifestPath $store $game
$gpu=[pscustomobject]@{Known=$true;Complete=$true;Names='NVIDIA RTX fixture';Adapters=@([pscustomobject]@{Name='NVIDIA RTX fixture';Luid='42';VendorId=0x10DE;DeviceId=0x2684;SubSystemId=1;Software=$false;ComputeCapabilityKnown=$true;ComputeMajor=8;ComputeMinor=9;Family=40;DriverVersion='nvcuda-file:32.0.15.8000'})}
if($Worker){
 $script:workerReady=$ReadyPath;$script:workerStore=$store;$script:workerMode=$Worker;$script:workerPaused=$false
 try{
  if($Worker -eq 'Cleanup'){
   try{
    UninstallFusion $store (Join-Path $FixtureRoot 'fixture-manager.exe') -Progress {
     param($text,$completed,$total)
     if($text -ceq 'Finding OptiShade-managed game installations...'){
      [IO.File]::WriteAllText($script:workerReady,'cleanup owns store');[void][Console]::ReadLine()
      throw 'fixture stopped cleanup after admission'
     }
    }
    throw 'The cleanup pause was not reached.'
   }catch{if($_.Exception.Message -notlike '*fixture stopped cleanup after admission*'){throw}}
  }else{
   [void](InvokeOptiShadeAutoPreparation $manifest $payload $gpu {
    param($text,$completed,$total)
    if(-not $script:workerPaused -and $text -ceq 'Auto: preparing nr...'){
     $script:workerPaused=$true
     # A nested acquisition must release just its own recursion; the outer
     # production Auto owner must remain held while this process is paused.
     $nested=EnterOptiShadeMutation -StateRoot $script:workerStore
     try{}finally{ExitOptiShadeMutation $nested}
     [IO.File]::WriteAllText($script:workerReady,'Auto owns store');[void][Console]::ReadLine()
     if($script:workerMode -eq 'Abandon'){[Environment]::Exit(87)}
    }
   })
   if(-not $script:workerPaused){throw 'The production Auto pause was not reached.'}
  }
  'worker completed';exit 0
 }catch{[Console]::Error.WriteLine($_.Exception.ToString());exit 1}
}
$count=0;$children=[Collections.Generic.List[object]]::new()
function Check($Value,[string]$Message){if(-not $Value){throw $Message};$script:count++}
function StartFixtureWorker([string]$Mode){
 $ready=Join-Path $FixtureRoot ('ready-'+[guid]::NewGuid().ToString('N'))
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=(Get-Process -Id $PID).Path;$start.UseShellExecute=$false
 $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $start.Arguments='-NoLogo -NoProfile -File "'+$PSCommandPath+'" -Worker '+$Mode+' -FixtureRoot "'+$FixtureRoot+'" -ReadyPath "'+$ready+'"'
 $process=[Diagnostics.Process]::Start($start);$script:children.Add($process)
 $deadline=[DateTime]::UtcNow.AddSeconds(30)
 while(-not(Test-Path -LiteralPath $ready)){
  if($process.HasExited){throw ('Worker failed before admission: '+$process.StandardError.ReadToEnd()+$process.StandardOutput.ReadToEnd())}
  if([DateTime]::UtcNow -ge $deadline){throw 'Timed out waiting for the real child process admission signal.'}
  Start-Sleep -Milliseconds 20
 }
 return $process
}
function FinishFixtureWorker($Process,[int]$ExpectedExit=0){
 $Process.StandardInput.WriteLine('continue');$Process.StandardInput.Flush()
 if(-not $Process.WaitForExit(30000)){throw 'A child process failed to finish after its explicit release signal.'}
 $errorText=$Process.StandardError.ReadToEnd();$output=$Process.StandardOutput.ReadToEnd()
 if($Process.ExitCode -ne $ExpectedExit){throw ('Unexpected child exit '+$Process.ExitCode+': '+$errorText+$output)}
}
try{
 [void][IO.Directory]::CreateDirectory($game);[void][IO.Directory]::CreateDirectory($payload);[void][IO.Directory]::CreateDirectory((Split-Path $manifest))
 $exe=Join-Path $game 'ForzaHorizon4.exe';WriteFixtureExe $exe;[IO.File]::WriteAllText((Join-Path $game 'fixture-only'),'fixture');[IO.File]::WriteAllText((Join-Path $game 'OptiScaler.ini'),'[DlssNR]')
 [IO.File]::WriteAllText($script:fixtureModel,'CPU model fixture; never loaded')
 $catalogue=@();foreach($relative in @('OptiShadeData/Shaders/Fixture.fx','OptiShadeData/Engine/libxess.dll','OptiShadeData/Engine/amd_fidelityfx_loader_dx12.dll','OptiShadeData/Engine/amd_fidelityfx_framegeneration_dx12.dll','OptiShadeData/Engine/nvngx_dlss.dll')){
  $file=Join-Path $payload $relative;[void][IO.Directory]::CreateDirectory((Split-Path $file));[IO.File]::WriteAllText($file,'CPU fixture '+$relative);$catalogue+=[pscustomobject]@{Path=$relative;Hash=(HashFile $file)}
 }
 WriteState @($catalogue) (Join-Path $payload 'files.json')
 WriteState ([pscustomobject]@{Game=$game;Status='Installed';Version=(GetBundledOptiShadeVersion);LaunchExe=$exe;Architecture='x64';RouteDLL='OptiShadeGeneric.dll';Components=@();Files=@()}) $manifest
 [void](InvokeOptiShadeAutoPreparation $manifest $payload $gpu {})
 $otherGame=Join-Path $FixtureRoot 'new-game';[void][IO.Directory]::CreateDirectory($otherGame);[IO.File]::WriteAllText((Join-Path $otherGame 'fixture-only'),'fixture')
 $otherReceipt=ManifestPath $store $otherGame
 Check ((GetOptiShadeMutationStore $manifest) -ceq (FullPath $store) -and (GetOptiShadeMutationStore $otherReceipt) -ceq (FullPath $store)) 'Existing and not-yet-created canonical receipts resolved to different mutation stores.'
 foreach($bad in @((Join-Path $store 'Games/not-an-id/manifest.json'),(Join-Path (Split-Path $manifest) 'AddonBackups/archived/manifest.json'))){$failed=$false;try{GetOptiShadeMutationStore $bad}catch{$failed=$true};Check $failed 'A malformed or archived managed receipt silently selected another lock owner.'}
 $direct=Join-Path (Join-Path $FixtureRoot 'standalone') 'manifest.json'
 Check ((GetOptiShadeMutationStore $direct) -ceq (FullPath (Split-Path $direct))) 'The explicit standalone receipt format lost its directory owner.'
 $child=StartFixtureWorker 'Auto';$duringReceipt=HashFile $manifest;$duringModel=HashFile (Join-Path $game 'nvngx_dlssnr.dll')
 $watch=[Diagnostics.Stopwatch]::StartNew();$blocked=$false
 try{RemoveOptiShadeAddon $manifest 'Neural'}catch{$blocked=$_.Exception.Message -like '*Another OptiShade operation*'};$watch.Stop()
 Check ($blocked -and $watch.Elapsed.TotalSeconds -lt 3 -and (HashFile $manifest) -ceq $duringReceipt -and (HashFile (Join-Path $game 'nvngx_dlssnr.dll')) -ceq $duringModel) 'A second process changed the active Auto receipt/files or blocked instead of returning promptly.'
 $blocked=$false;try{InstallFusion $otherGame $payload $store (Join-Path $FixtureRoot 'fixture-manager.exe')}catch{$blocked=$_.Exception.Message -like '*Another OptiShade operation*'}
 Check ($blocked -and -not(Test-Path -LiteralPath $otherReceipt)) 'A new game installation acquired a separate lock inside the same active store.'
 $independent=EnterOptiShadeMutation -StateRoot (Join-Path $FixtureRoot 'independent-store');try{Check ($null -ne $independent) 'An unrelated store was blocked by another installation owner.'}finally{ExitOptiShadeMutation $independent}
 FinishFixtureWorker $child
 RemoveOptiShadeAddon $manifest 'Neural';$after=ReadOptiShadeState $manifest
 Check ('Neural' -notin $after.Components -and 'Neural' -cin @(GetOptiShadeAutoComponentExclusions $after) -and -not(Test-Path -LiteralPath (Join-Path $game 'nvngx_dlssnr.dll'))) 'Normal child completion did not release all nested locks for a real component removal.'
 InstallOptiShadeAddon $manifest $payload 'Neural' $gpu {} -ExplicitSelection
 [void](InvokeOptiShadeAutoPreparation $manifest $payload $gpu {})
 $before=HashFile $manifest;$failed=$false
 try{InvokeAddonTransaction $manifest 'Neural' {throw 'fixture transaction abort'}}catch{$failed=$_.Exception.Message -like '*fixture transaction abort*'}
 Check ($failed -and (HashFile $manifest) -ceq $before) 'A thrown production transaction lost the previous receipt.'
 # Acquisition in a different process proves exception release, rather than
 # merely testing same-thread recursive acquisition after an unreleased lock.
 $child=StartFixtureWorker 'Auto';FinishFixtureWorker $child
 Check ($child.ExitCode -eq 0) 'Transaction failure left the store locked against another process.'
 $child=StartFixtureWorker 'Abandon';FinishFixtureWorker $child 87
 $resumed=InvokeOptiShadeAutoPreparation $manifest $payload $gpu {} -RetryFailed
 Check ($resumed.State -cin @('prepared','prepared_with_limits') -and (ReadOptiShadeState $manifest).Downloads -ceq 'Complete') 'A terminated real Auto owner left a stale OS lock or prevented normal preparation recovery.'
 $before=HashFile $manifest;$child=StartFixtureWorker 'Cleanup';$blocked=$false
 try{InstallFusion $otherGame $payload $store (Join-Path $FixtureRoot 'fixture-manager.exe')}catch{$blocked=$_.Exception.Message -like '*Another OptiShade operation*'}
 Check ($blocked -and -not(Test-Path -LiteralPath $otherReceipt) -and (HashFile $manifest) -ceq $before) 'Store-wide cleanup admitted a new installation after taking its store ownership.'
 FinishFixtureWorker $child
 $admitted=$false
 try{InstallFusion $otherGame $payload $store (Join-Path $FixtureRoot 'fixture-manager.exe') -Progress {throw 'fixture new install admitted'}}catch{$admitted=$_.Exception.Message -like '*fixture new install admitted*'}
 Check ($admitted -and -not(Test-Path -LiteralPath $otherReceipt)) 'Cleanup exception did not release store ownership for the real new-install entry point.'
 # A different process can still enter after that installation callback throws.
 $child=StartFixtureWorker 'Auto';FinishFixtureWorker $child
 Check ($child.ExitCode -eq 0) 'New-install admission failure leaked the store lock.'
 "Store mutation: $count assertions passed with real child processes, production Auto/component/core/cleanup admission, nonblocking shared-store exclusion, nested release, exception release and terminated-owner recovery. No GPU or game output is claimed."
}finally{
 foreach($child in $children){try{if(-not $child.HasExited){$child.Kill();[void]$child.WaitForExit(10000)}}finally{$child.Dispose()}}
 if(Test-Path -LiteralPath $FixtureRoot){Remove-Item -LiteralPath $FixtureRoot -Recurse -Force}
}
