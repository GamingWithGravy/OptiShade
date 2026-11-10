param([string]$CrashFixture='')
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Beta/installer/ownership.ps1"
. "$root/Beta/installer/neural-download.ps1"
. "$root/Beta/installer/components.ps1"
function OwnedPath([string]$Root,[string]$Relative){
 $base=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
 $target=[IO.Path]::GetFullPath((Join-Path $Root $Relative))
 if(-not $target.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture path escaped its root.'}
 $check=$target;while($check){if(Test-Path -LiteralPath $check){if((Get-Item -LiteralPath $check -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Fixture refused linked target.'}};$next=Split-Path $check -Parent;if($next -eq $check){break};$check=$next};$target
}
function AssertClosed([string]$Game){if(-not(Test-Path -LiteralPath (Join-Path $Game 'fixture-only'))){throw 'Not an isolated fixture.'}}
function AssertAntiCheatMutation([string]$Game,[string]$Exe,[string]$Action){AssertClosed $Game}
# The fixture is a local fake model; production hashing, ownership, architecture
# selection, PE parsing, staging, journal and recovery are not mocked.
function GetOptiShadeNeuralModelCatalog {
 [pscustomobject]@{Id='test-fixture';Variant='auto';Families=@(40);ModelHash=(HashFile $script:fixtureModel);Signed=$false}
}
$gpu=[pscustomobject]@{Adapters=@([pscustomobject]@{Name='Fixture RTX';Luid='42';VendorId=0x10DE;DeviceId=0x2684;SubSystemId=1;Software=$false;ComputeCapabilityKnown=$true;ComputeMajor=8;ComputeMinor=9;Family=40;DriverVersion='fixture'})}
if($CrashFixture){
 $script:fixtureModel=Join-Path $CrashFixture 'model-new';$realWrite=${function:WriteState};$crashReceipt=Join-Path $CrashFixture 'manifest.json'
 function WriteState($Object,[string]$Path){if($Path -eq $crashReceipt){[Environment]::Exit(92)};& $realWrite $Object $Path}
 ImportNrRuntime $crashReceipt $script:fixtureModel auto $gpu
 throw 'Crash fixture did not reach final receipt.'
}
$count=0;function Check($Value,[string]$Message){if(-not $Value){throw $Message};$script:count++}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-neural-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($testRoot)
function WriteFixtureExe([string]$Path){
 $bytes=New-Object byte[] 1024;$stream=[IO.MemoryStream]::new($bytes,$true);$writer=[IO.BinaryWriter]::new($stream)
 try{$writer.Write([uint16]0x5a4d);$stream.Position=0x3c;$writer.Write([uint32]0x80);$stream.Position=0x80;$writer.Write([uint32]0x4550);$writer.Write([uint16]0x8664);$writer.Write([uint16]1);$stream.Position=0x94;$writer.Write([uint16]240);$writer.Write([uint16]2);$writer.Write([uint16]0x20b);$stream.Position=0x98+60;$writer.Write([uint32]512);$stream.Position=0x98+240+8;$writer.Write([uint32]512);$writer.Write([uint32]0x1000);$writer.Write([uint32]512);$writer.Write([uint32]512)}finally{$writer.Dispose()};[IO.File]::WriteAllBytes($Path,$bytes)
}
function Fixture {
 $folder=Join-Path $testRoot ([guid]::NewGuid().ToString('N'));$game=Join-Path $folder 'game';[void][IO.Directory]::CreateDirectory($game)
 $exe=Join-Path $game 'ForzaHorizon4.exe';WriteFixtureExe $exe;[IO.File]::WriteAllText((Join-Path $game 'fixture-only'),'fixture')
 $model=Join-Path $folder 'model-new';[IO.File]::WriteAllText($model,'fixture new model');$script:fixtureModel=$model
 $target=Join-Path $game 'nvngx_dlssnr.dll';[IO.File]::WriteAllText($target,'foreign original model to preserve')
 $manifest=Join-Path $folder 'manifest.json';WriteState ([pscustomobject]@{Game=$game;Status='Installed';LaunchExe=$exe;Architecture='x64';RouteDLL='OptiShadeGeneric.dll';Files=@()}) $manifest
 [pscustomobject]@{Folder=$folder;Game=$game;Exe=$exe;Model=$model;Target=$target;Manifest=$manifest;BeforeReceipt=(HashFile $manifest);BeforeModel=(HashFile $target);Narrow=(Join-Path $game 'OptiShadeData/Neural-runtime.json')}
}
function CheckRestored($f){Check ((HashFile $f.Manifest) -ceq $f.BeforeReceipt) 'Canonical receipt did not roll back.';Check ((HashFile $f.Target) -ceq $f.BeforeModel) 'Model did not roll back.';Check (-not(Test-Path -LiteralPath $f.Narrow)) 'Uncommitted preparation identity survived rollback.'}
try{
 $f=Fixture;$realCopy=${function:CopyOptiShadeRouteFile};$script:failPath=$f.Narrow
 function CopyOptiShadeRouteFile([string]$Source,[string]$Destination,[string]$ExpectedHash){if($Destination -eq $script:failPath){$script:failPath='';throw 'Injected narrow receipt write failure.'};& $realCopy $Source $Destination $ExpectedHash}
 $failed=$false;try{ImportNrRuntime $f.Manifest $f.Model auto $gpu}catch{$failed=$true}finally{Set-Item Function:CopyOptiShadeRouteFile $realCopy}
 Check $failed 'Receipt write failure was not injected.';CheckRestored $f
 $f=Fixture;$start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=(Get-Process -Id $PID).Path;$start.UseShellExecute=$false;$start.Arguments='-NoLogo -NoProfile -File "'+$PSCommandPath+'" -CrashFixture "'+$f.Folder+'"'
 $child=[Diagnostics.Process]::Start($start);try{$child.WaitForExit();Check ($child.ExitCode -eq 92) 'Child did not stop at final receipt commit.'}finally{$child.Dispose()}
 Check (Test-Path -LiteralPath $f.Narrow) 'Crash fixture did not stage model preparation identity.'
 Check (RecoverOptiShadeRouteTransaction $f.Manifest) 'Restart did not recover the interrupted import.';CheckRestored $f
 ImportNrRuntime $f.Manifest $f.Model auto $gpu;$m=ReadOptiShadeState $f.Manifest;$receipt=ReadOptiShadeJson $f.Narrow 'fixture receipt' -MaxBytes 4096 -Shape Object
 Check ($receipt.schema -eq 1 -and $receipt.modelSha256 -ceq (HashFile $f.Model)) 'Narrow model identity did not bind the verified bytes.'
 Check ($receipt.executable -ceq 'ForzaHorizon4.exe' -and $receipt.executableSha256 -ceq (HashFile $f.Exe) -and $receipt.architecture -ceq 'x64') 'Receipt did not bind the actual rendering PE.'
 Check ($receipt.evidence -ceq 'inventory_candidate' -and $receipt.adapter.luid -ceq '42') 'Preparation was incorrectly promoted to live rendering evidence.'
 $owned=@($m.Files|Where-Object Path -eq 'OptiShadeData/Neural-runtime.json')
 Check ($owned.Count -eq 1 -and $owned[0].Hash -ceq (HashFile $f.Narrow) -and $owned[0].Component -eq 'Neural') 'Preparation identity is not owned with the model.'
 $modelOwned=@($m.Files|Where-Object Path -eq 'nvngx_dlssnr.dll')[0]
 Check ((HashFile (Join-Path $f.Folder $modelOwned.Backup)) -ceq $f.BeforeModel) 'Explicit import lost the original foreign model backup.'
 # A same-model refresh must still bind the updated real executable hash and
 # preserve its original backup chain; it must not require another download.
 $exeBytes=[IO.File]::ReadAllBytes($f.Exe);$exeBytes[1000]=1;[IO.File]::WriteAllBytes($f.Exe,$exeBytes)
 EnsureNeuralRuntime $f.Manifest $gpu {param($text)};$updated=ReadOptiShadeJson $f.Narrow 'fixture receipt' -MaxBytes 4096 -Shape Object
 Check ($updated.executableSha256 -ceq (HashFile $f.Exe)) 'Same-model Ensure returned without refreshing executable identity.'
 $m=ReadOptiShadeState $f.Manifest;Check (@($m.Files|Where-Object Path -eq 'nvngx_dlssnr.dll')[0].Backup -ceq $modelOwned.Backup) 'Same-model refresh replaced the original restore chain.'
 $before=HashFile $f.Manifest;[IO.File]::WriteAllText($f.Narrow,'foreign concurrent receipt edit');$failed=$false
 try{ImportNrRuntime $f.Manifest $f.Model auto $gpu}catch{$failed=$_.Exception.Message -like '*outside OptiShade*'}
 Check ($failed -and [IO.File]::ReadAllText($f.Narrow) -ceq 'foreign concurrent receipt edit' -and (HashFile $f.Manifest) -ceq $before) 'Model import overwrote an externally changed preparation receipt.'
 $f=Fixture;$m=ReadOptiShadeState $f.Manifest;$m.LaunchExe=Join-Path $f.Folder 'outside.exe';WriteState $m $f.Manifest;$failed=$false
 try{ImportNrRuntime $f.Manifest $f.Model auto $gpu}catch{$failed=$_.Exception.Message -like '*outside*'}
 Check $failed 'Preparation accepted an executable outside the installation.'

 # A component wrapper must not overwrite a foreign edit when its inner model
 # journal deliberately refuses recovery. This executes both production owners.
 $f=Fixture;$realWrite=${function:WriteState};$script:failReceipt=$f.Manifest;$script:conflictModel=$f.Target
 function WriteState($Object,[string]$Path){if($Path -eq $script:failReceipt){[IO.File]::WriteAllText($script:conflictModel,'foreign edit during nested model commit');throw 'Injected nested receipt fault.'};& $realWrite $Object $Path}
 $failed=$false;try{InvokeAddonTransaction $f.Manifest 'Neural' {ImportNrRuntime $f.Manifest $f.Model auto $gpu}}catch{$failed=$_.Exception.Message -like '*inner transaction needs review*'}finally{Set-Item Function:WriteState $realWrite}
 Check ($failed -and [IO.File]::ReadAllText($f.Target) -ceq 'foreign edit during nested model commit') 'Broader component recovery overwrote the foreign edit retained by the inner model transaction.'
 Check (Test-Path -LiteralPath (Join-Path $f.Folder 'MfgRouteTransaction.json')) 'Nested component failure discarded model recovery evidence.'
 [IO.File]::WriteAllBytes($f.Target,[IO.File]::ReadAllBytes($f.Model));Check (RecoverOptiShadeRouteTransaction $f.Manifest) 'Nested model recovery could not resume after conflict resolution.';CheckRestored $f
 "Neural preparation: $count assertions passed, including durable model/receipt rollback and real child-process termination. No inference is claimed."
}finally{Remove-Item -LiteralPath $testRoot -Recurse -Force}
