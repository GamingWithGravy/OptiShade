param([string]$CrashFixture='')
$ErrorActionPreference='Stop'
. "$PSScriptRoot/fixtures/windows_pe.ps1"
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Beta/installer/ownership.ps1"
. "$root/Beta/installer/mfg.ps1"
# The product is Windows-only. Fixture paths remain bounded on either host;
# production route planning, journals, file replacement and recovery run intact.
function OwnedPath([string]$Root,[string]$Relative){
 $base=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
 $target=[IO.Path]::GetFullPath((Join-Path $Root $Relative))
 if(-not $target.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture path escaped its root.'}
 $check=$target;while($check){if(Test-Path -LiteralPath $check){if((Get-Item -LiteralPath $check -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Fixture recovery refused a link.'}};$parent=Split-Path $check -Parent;if($parent -eq $check){break};$check=$parent}
 return $target
}
function AssertClosed([string]$Game){if(-not(Test-Path -LiteralPath (Join-Path $Game 'fixture-only.txt'))){throw 'Not an isolated transaction fixture.'}}
if($CrashFixture){
 $realWrite=${function:WriteState};$crashReceipt=Join-Path $CrashFixture 'manifest.json'
 function WriteState($Object,[string]$Path){if($Path -eq $crashReceipt){[Environment]::Exit(91)};& $realWrite $Object $Path}
 SelectPortableFsr2x $crashReceipt (Join-Path $CrashFixture 'payload')
 throw 'Crash injection did not reach receipt commit.'
}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-route-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot);$count=0
function Check($Value,[string]$Message){if(-not $Value){throw $Message};$script:count++}
function Fixture {
 $folder=Join-Path $testRoot ([guid]::NewGuid().ToString('N'));$game=Join-Path $folder 'game';$payload=Join-Path $folder 'payload'
 [void][IO.Directory]::CreateDirectory((Join-Path $game 'OptiShadeData/Engine/dlssg_sm86'));[void][IO.Directory]::CreateDirectory($payload)
 WriteOptiShadeFixtureExecutable (Join-Path $game 'FlightSimulator2024.exe');[IO.File]::WriteAllText((Join-Path $game 'fixture-only.txt'),'fixture')
 [IO.File]::WriteAllText((Join-Path $game 'OptiScaler.ini'),"[FrameGen]`r`nExternal=true`r`n[DLSSG]`r`nAmpereMfgUnlock=true`r`n[DlssNR]`r`nStrength=0.6`r`n")
 $files=@();foreach($name in @('amd_fidelityfx_loader_dx12.dll','amd_fidelityfx_framegeneration_dx12.dll')){
  $relative='OptiShadeData/Engine/'+$name;$path=Join-Path $game $relative;[IO.File]::WriteAllText($path,'pinned fixture '+$name)
  $files+=[pscustomobject]@{Path=$relative;SourcePath=$relative;Hash=(HashFile $path);Mutable=$false;Backup='';PreviousHash='';Retained=$false}
 }
 WriteState @($files) (Join-Path $payload 'files.json')
 $provider='OptiShadeData/Engine/dlssg_sm86/dlssg_sm86.dll';$config='OptiShadeData/Engine/dlssg_sm86/dlssg_sm86.ini'
 [IO.File]::WriteAllText((Join-Path $game $provider),'sm86 provider fixture');[IO.File]::WriteAllText((Join-Path $game $config),'user edited mutable config')
 [IO.File]::WriteAllText((Join-Path $folder 'original-provider'),'original pre-OptiShade bytes')
 $files+=[pscustomobject]@{Path=$provider;SourcePath='';Hash=(HashFile (Join-Path $game $provider));Mutable=$false;Backup='original-provider';PreviousHash=(HashFile (Join-Path $folder 'original-provider'));Retained=$true;Component='Mfg'}
 $files+=[pscustomobject]@{Path=$config;SourcePath='';Hash=('A'*64);Mutable=$true;Backup='';PreviousHash='';Retained=$true;Component='Mfg'}
 $manifest=Join-Path $folder 'manifest.json'
 WriteState ([pscustomobject]@{Game=$game;Status='Installed';LaunchExe=(Join-Path $game 'FlightSimulator2024.exe');Architecture='x64';RouteDLL='OptiShadeMSFS2024.dll';Files=$files;Components=@('Mfg');SourceMfg=$false;OptionalMfg=$false;Sm86Mfg=$true;Sm86MfgFiles=@($provider,$config);Sm86MfgIniBefore=[pscustomobject]@{External='false';AmpereMfgUnlock='false'}}) $manifest
 return [pscustomobject]@{Folder=$folder;Game=$game;Payload=$payload;Manifest=$manifest;Provider=$provider;Config=$config;ReceiptHash=(HashFile $manifest);IniHash=(HashFile (Join-Path $game 'OptiScaler.ini'));ProviderHash=(HashFile (Join-Path $game $provider));ConfigHash=(HashFile (Join-Path $game $config))}
}
function CheckRestored($f){
 Check ((HashFile $f.Manifest) -ceq $f.ReceiptHash) 'Original complete SM86 receipt was not restored.'
 Check ((HashFile (Join-Path $f.Game 'OptiScaler.ini')) -ceq $f.IniHash) 'Original INI was not restored.'
 Check ((HashFile (Join-Path $f.Game $f.Provider)) -ceq $f.ProviderHash) 'Original SM86 provider bytes were not restored.'
 Check ((HashFile (Join-Path $f.Game $f.Config)) -ceq $f.ConfigHash) 'User-edited provider configuration changed.'
}
try{
 $f=Fixture;$realCopy=${function:CopyOptiShadeRouteFile};$script:failIni=Join-Path $f.Game 'OptiScaler.ini'
 function CopyOptiShadeRouteFile([string]$Source,[string]$Destination,[string]$ExpectedHash){if($Destination -eq $script:failIni){$script:failIni='';throw 'Injected failure after SM86 removal, before INI commit.'};& $realCopy $Source $Destination $ExpectedHash}
 $failed=$false;try{SelectPortableFsr2x $f.Manifest $f.Payload}catch{$failed=$true}finally{Set-Item Function:CopyOptiShadeRouteFile $realCopy}
 Check $failed 'First route failure was not injected.';CheckRestored $f
 $f=Fixture;$realWrite=${function:WriteState};$script:failReceipt=$f.Manifest
 function WriteState($Object,[string]$Path){if($Path -eq $script:failReceipt){throw 'Injected receipt failure.'};& $realWrite $Object $Path}
 $failed=$false;try{SelectPortableFsr2x $f.Manifest $f.Payload}catch{$failed=$true}finally{Set-Item Function:WriteState $realWrite}
 Check $failed 'Receipt failure was not injected.';CheckRestored $f
 # Terminate a separate PowerShell process after provider/settings mutations.
 # No catch/finally recovery runs in the child; the manager's next operation
 # must consume the durable journal using original bytes from disk.
 $f=Fixture;$start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=(Get-Process -Id $PID).Path;$start.UseShellExecute=$false
 $start.Arguments='-NoLogo -NoProfile -File "'+$PSCommandPath+'" -CrashFixture "'+$f.Folder+'"'
 $child=[Diagnostics.Process]::Start($start);try{$child.WaitForExit();Check ($child.ExitCode -eq 91) 'Child did not stop at the intended commit point.'}finally{$child.Dispose()}
 Check (Test-Path -LiteralPath (Join-Path $f.Folder 'MfgRouteTransaction.json')) 'An interrupted route has no durable recovery pointer.'
 $providerPath=Join-Path $f.Game $f.Provider;$after=([IO.File]::ReadAllBytes($providerPath));[IO.File]::WriteAllText($providerPath,'foreign concurrent change')
 $failed=$false;try{[void](RecoverOptiShadeRouteTransaction $f.Manifest)}catch{$failed=$true}
 Check ($failed -and [IO.File]::ReadAllText($providerPath) -ceq 'foreign concurrent change') 'Recovery overwrote a concurrent foreign file.'
 Check (Test-Path -LiteralPath (Join-Path $f.Folder 'MfgRouteTransaction.json')) 'Conflict discarded its recovery pointer.'
 [IO.File]::WriteAllBytes($providerPath,$after);Check (RecoverOptiShadeRouteTransaction $f.Manifest) 'Restart recovery did not run.';CheckRestored $f
 Check (-not(RecoverOptiShadeRouteTransaction $f.Manifest)) 'Recovery was not idempotent.'
 SelectPortableFsr2x $f.Manifest $f.Payload;$m=ReadOptiShadeState $f.Manifest
 Check ($m.FrameGenerationRoute -ceq 'portable-fsr2x' -and -not $m.Sm86Mfg) 'Committed receipt still selects SM86.'
 Check ((HashFile (Join-Path $f.Game $f.Provider)) -ceq (HashFile (Join-Path $f.Folder 'original-provider'))) 'Pre-OptiShade original backup was not restored on success.'
 Check ((HashFile (Join-Path $f.Game $f.Config)) -ceq $f.ConfigHash) 'Successful switch changed user-edited config.'
 Check ((HashFile (Join-Path $m.FrameGenerationRouteRollback 'manifest.json')) -ceq $f.ReceiptHash) 'Durable rollback does not retain the pre-switch SM86 receipt.'
 "Route transactions: $count assertions passed, including process termination and restart recovery."
}finally{Remove-Item -LiteralPath $testRoot -Recurse -Force}
