param([string]$CrashFixture='',[switch]$CrashRemove)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/fixtures/windows_pe.ps1"
$parseFiles=@('sm86-mfg.ps1','mfg.ps1','components.ps1','component-policy.ps1','ownership.ps1','manager.ps1','diagnostics.ps1','update-install.ps1')|ForEach-Object {Join-Path $PSScriptRoot ('../../Beta/installer/'+$_)}
foreach($parseFile in $parseFiles){$parseTokens=$null;$parseErrors=$null;[void][Management.Automation.Language.Parser]::ParseFile($parseFile,[ref]$parseTokens,[ref]$parseErrors);if($parseErrors.Count){throw ('PowerShell parse failed for '+$parseFile+': '+($parseErrors|Out-String))}}
. "$PSScriptRoot/../../Beta/installer/ownership.ps1"
. "$PSScriptRoot/../../Beta/installer/mfg.ps1"
$script:testRoot=if($CrashFixture){Split-Path $CrashFixture}else{Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-sm86-'+[guid]::NewGuid().ToString('N'))}
$fixturePreviousLocalAppData=$env:LOCALAPPDATA;$env:LOCALAPPDATA=$script:testRoot
[void][IO.Directory]::CreateDirectory($script:testRoot)
Add-Type -AssemblyName System.IO.Compression.FileSystem
function AssertClosed([string]$Game){$base=[IO.Path]::GetFullPath($script:testRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar;if(-not [IO.Path]::GetFullPath($Game).StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){throw 'SM86 fixture escaped its isolated temporary root.'}}
if([IO.Path]::DirectorySeparatorChar -ne '\'){
 function OwnedPath([string]$Root,[string]$Relative){
  $base=[IO.Path]::GetFullPath($Root).TrimEnd('/')+'/';$target=[IO.Path]::GetFullPath((Join-Path $Root $Relative))
  if(-not $target.StartsWith($base,[StringComparison]::Ordinal)){throw 'Fixture path escape.'}
  $check=$target;while($check){if((Test-Path -LiteralPath $check) -and ((Get-Item -LiteralPath $check -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Linked fixture refused.'};$next=Split-Path $check -Parent;if($next -eq $check){break};$check=$next};return $target
 }
}
$script:fixtureGpu=[pscustomobject]@{Complete=$true;Adapters=@([pscustomobject]@{Name='NVIDIA RTX 3070';Luid='30';VendorId=0x10DE;DeviceId=0x2484;SubSystemId=1;Software=$false;ComputeCapabilityKnown=$true;ComputeMajor=8;ComputeMinor=6;Family=30;DriverVersion='fixture'})}
$script:AntiCheatOperation=@{Name='SM86 fixture';Accepted=@{}}
# Installer lifecycle assertions start after the launcher-wide agreement.
# Consent refusal and acceptance are covered by the dedicated anti-cheat tests.
$script:AntiCheatSessionAccepted=$true

function GetOptiShadeMfgPolicyChannel {'stable'}
function GetSm86MfgReleaseIdentity {$script:fixtureIdentity}
$script:assertions=0
function Check($Condition,[string]$Message){if(-not $Condition){throw $Message};$script:assertions++}
function New-Fixture([string]$Name,[switch]$ForeignVersion,[switch]$OldSource,[switch]$OldSm86,[string]$ProxyName='winmm.dll'){
 $root=Join-Path $script:testRoot $Name;$game=Join-Path $root 'game';$state=Join-Path $root 'state';$source=Join-Path $root 'upstream';$staging=Join-Path $root 'staging'
 [void][IO.Directory]::CreateDirectory($game);[void][IO.Directory]::CreateDirectory($state);[void][IO.Directory]::CreateDirectory($source);[void][IO.Directory]::CreateDirectory($staging)
 WriteOptiShadeFixtureExecutable (Join-Path $game 'FlightSimulator2024.exe')
 [IO.File]::WriteAllText((Join-Path $game 'OptiScaler.ini'),"[FrameGen]`r`nExternal=false`r`nEnabled=auto`r`n[DLSSG]`r`nAdaMfgUnlock=true`r`nAmpereMfgUnlock=false`r`n")
 [IO.File]::WriteAllText((Join-Path $game $ProxyName),'fixture recorded OptiScaler core proxy')
 $contents=[ordered]@{
  'version.dll'='fixture proxy version';'alternatives/winmm.dll'='fixture proxy winmm';'alternatives/dbghelp.dll'='fixture proxy dbghelp';'alternatives/dinput8.dll'='fixture proxy dinput8';'alternatives/dxgi.dll'='fixture proxy dxgi';'alternatives/d3d12.dll'='fixture proxy d3d12';
  'dlssg_sm86.ini'="[FrameGeneration]`r`nMaxGeneratedFrames=3`r`n";'dlssg_sm86/backend/sm86_backend.dll'='fixture backend';'dlssg_sm86/kernels/fg_kernels.dll'='fixture kernels';'dlssg_sm86/runtime/nvngx_dlssg.dll'='fixture runtime';'LICENSE.md'='fixture MIT license';'THIRD_PARTY_NOTICES.txt'='fixture notices'
 }
 $fileHashes=[ordered]@{}
 foreach($entry in $contents.GetEnumerator()){$path=Join-Path $source $entry.Key;[void][IO.Directory]::CreateDirectory((Split-Path $path));[IO.File]::WriteAllText($path,[string]$entry.Value);$fileHashes[$entry.Key]=HashFile $path}
 $archive=Join-Path $root 'provider.zip';[IO.Compression.ZipFile]::CreateFromDirectory($source,$archive)
 $sha=[Security.Cryptography.SHA256]::Create();try{$archiveHash=[BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($archive))).Replace('-','')}finally{$sha.Dispose()}
 $script:fixtureIdentity=[pscustomobject]@{Version='test-0.4.0';Url='fixture-only';SHA256=$archiveHash;Files=$fileHashes}
 if($ForeignVersion){[IO.File]::WriteAllText((Join-Path $game 'version.dll'),'foreign game proxy')}
 $files=@([pscustomobject]@{Path=$ProxyName;SourcePath='winmm.dll';Hash=(HashFile (Join-Path $game $ProxyName));PreviousHash='';Backup='';Mutable=$false;Retained=$true;Component='Core'});if($OldSource){
  $sourceDll=Join-Path $game 'OptiShadeData/MFG/OptiShadeMFG.dll';$activation=Join-Path $game 'OptiShadeData/MFG/source-backend.json'
  [void][IO.Directory]::CreateDirectory((Split-Path $sourceDll));[IO.File]::WriteAllText($sourceDll,'old source provider');[IO.File]::WriteAllText($activation,'{}')
  foreach($relative in @('OptiShadeData/MFG/OptiShadeMFG.dll','OptiShadeData/MFG/source-backend.json')){$path=OwnedPath $game $relative;$files+=,[pscustomobject]@{Path=$relative;SourcePath='';Hash=(HashFile $path);PreviousHash='';Backup='';Mutable=$false;Retained=$true;Component='Mfg'}}
  $rollback=Join-Path $state 'MfgRollback/old-source';[void][IO.Directory]::CreateDirectory($rollback);$originalIni=Join-Path $rollback 'original-ini';[IO.File]::WriteAllText($originalIni,"[FrameGen]`r`nExternal=false`r`n[DLSSG]`r`nAdaMfgUnlock=true`r`nAmpereMfgUnlock=false`r`n")
  $rollbackHash=HashFile $originalIni;WriteState @{Game=$game;Files=@(@{Path='OptiScaler.ini';Hash=$rollbackHash;Copy=$originalIni})} (Join-Path $rollback 'rollback.json')
 }
 if($OldSm86){
  $legacyMap=[ordered]@{'version.dll'='version.dll';'dlssg_sm86.ini'='dlssg_sm86.ini';'dlssg_sm86/backend/sm86_backend.dll'='dlssg_sm86/backend/sm86_backend.dll';'dlssg_sm86/kernels/fg_kernels.dll'='dlssg_sm86/kernels/fg_kernels.dll';'dlssg_sm86/runtime/nvngx_dlssg.dll'='dlssg_sm86/runtime/nvngx_dlssg.dll';'LICENSE.md'='OptiShadeData/Licenses/DLSSG-SM86/LICENSE.md';'THIRD_PARTY_NOTICES.txt'='OptiShadeData/Licenses/DLSSG-SM86/THIRD_PARTY_NOTICES.txt'}
  $legacyPaths=@();foreach($pair in $legacyMap.GetEnumerator()){$path=OwnedPath $game $pair.Value;[void][IO.Directory]::CreateDirectory((Split-Path $path));[IO.File]::WriteAllText($path,[string]$contents[$pair.Key]);$legacyPaths+=,[string]$pair.Value;$files+=,[pscustomobject]@{Path=[string]$pair.Value;SourcePath='';Hash=(HashFile $path);PreviousHash='';Backup='';Mutable=([string]$pair.Key -eq 'dlssg_sm86.ini');Retained=$true;Component='Mfg'}}
 }
 $script:AntiCheatOperation.Accepted[('installation|'+[IO.Path]::GetFullPath($game).TrimEnd('\').ToLowerInvariant())]=$true
 $manifest=Join-Path $state 'manifest.json';$value=@{Version='P1.0.14';Game=$game;Status='Installed';Architecture='x64';RouteDLL='OptiShadeMSFS2024.dll';Files=$files;Components=@();LaunchExe=(Join-Path $game 'FlightSimulator2024.exe')}
 if($OldSource){$value.SourceMfg=$true;$value.SourceMfgRollback=$rollback;$value.Components=@('Mfg')}
 if($OldSm86){$value.Sm86Mfg=$true;$value.Sm86MfgVersion='test-0.4.0';$value.Sm86MfgSHA256=$archiveHash;$value.Sm86MfgLoader='version.dll';$value.Sm86MfgFiles=$legacyPaths;$value.Sm86MfgIniBefore=@{External='false';AdaMfgUnlock='true';AmpereMfgUnlock='false'};$value.Components=@('Mfg')}
 WriteState $value $manifest
 WriteState $script:fixtureIdentity (Join-Path $root 'fixture-identity.json')
 return [pscustomobject]@{Root=$root;Game=$game;State=$state;Manifest=$manifest;Archive=$archive;ForeignVersion=[bool]$ForeignVersion;OldSource=[bool]$OldSource}
}
if($CrashFixture){
 $serialized=ReadOptiShadeJson (Join-Path $CrashFixture 'fixture-identity.json') 'Fixture identity';$pins=[ordered]@{}
 foreach($property in $serialized.Files.PSObject.Properties){$pins[$property.Name]=[string]$property.Value}
 $script:fixtureIdentity=[pscustomobject]@{Version=$serialized.Version;Url='fixture-only';SHA256=$serialized.SHA256;Files=$pins}
 $game=Join-Path $CrashFixture 'game';$manifest=Join-Path $CrashFixture 'state/manifest.json'
 $script:AntiCheatOperation.Accepted[('installation|'+[IO.Path]::GetFullPath($game).TrimEnd('\').ToLowerInvariant())]=$true
 $realWrite=${function:WriteState};$script:crashReceipt=$manifest
 function WriteState($Value,[string]$Path){if($Path -eq $script:crashReceipt){[Environment]::Exit(93)};& $realWrite $Value $Path}
 if($CrashRemove){RemoveSm86Mfg $manifest}else{InstallSm86Mfg $manifest $script:fixtureGpu {} (Join-Path $CrashFixture 'provider.zip')|Out-Null}
 throw 'SM86 process did not reach the canonical receipt commit.'
}
function CaptureSm86Fixture($f){
 $files=@{};foreach($item in @(Get-ChildItem -LiteralPath $f.Game -Recurse -File)){$files[$item.FullName]=HashFile $item.FullName}
 [pscustomobject]@{Receipt=(HashFile $f.Manifest);Files=$files}
}
function CheckSm86Restored($f,$before){
 Check ((HashFile $f.Manifest) -ceq $before.Receipt) 'SM86 recovery did not restore the exact original receipt.'
 $files=@(Get-ChildItem -LiteralPath $f.Game -Recurse -File);Check ($files.Count -eq $before.Files.Count) 'SM86 recovery left extra or missing game files.'
 foreach($item in $files){Check ($before.Files.ContainsKey($item.FullName) -and (HashFile $item.FullName) -ceq $before.Files[$item.FullName]) ('SM86 recovery changed '+$item.Name)}
 Check (-not(Test-Path -LiteralPath (Join-Path $f.State 'MfgRouteTransaction.json'))) 'SM86 recovery did not retire the active pointer.'
}

try{
 $clean=New-Fixture 'install-remove'
 $status=InstallSm86Mfg $clean.Manifest $script:fixtureGpu {} $clean.Archive
 $installed=ReadOptiShadeState $clean.Manifest
 Check ($installed.Sm86Mfg -and $installed.Sm86MfgVersion -eq 'test-0.4.0' -and $installed.Sm86MfgSHA256 -eq $script:fixtureIdentity.SHA256) 'records exact upstream release identity after install'
 $providerPath='OptiShadeData/Engine/dlssg_sm86/dlssg_sm86.dll'
 Check ($installed.Sm86MfgLoader -eq $providerPath -and (HashFile (OwnedPath $clean.Game $providerPath)) -eq $script:fixtureIdentity.Files['version.dll'] -and -not(Test-Path (Join-Path $clean.Game 'version.dll'))) 'hosts the pinned provider under the OptiScaler engine path without adding a second game-root proxy'
 Check (@($installed.Files|Where-Object {$_.Component -eq 'Mfg'}).Count -eq 7 -and 'Mfg' -in $installed.Components) 'records component ownership and bundled license notices'
 $activationIni=[IO.File]::ReadAllText((Join-Path $clean.Game 'OptiScaler.ini'));Check (($activationIni -match '(?m)^External=true\r?$') -and ($activationIni -match '(?m)^AmpereMfgUnlock=true\r?$')) 'activates the OptiScaler-hosted Ampere MFG loader and external Streamline route'
 $receiptCheck=TestSm86MfgReceipt $installed;Check ($receiptCheck -and $status -like '*experimental integration still needs a game test*') 'receipt validates pinned component payload while making no output claim'
 $recordedPin=$installed.Sm86MfgSHA256;$installed.Sm86MfgSHA256='untrusted';Check (-not(TestSm86MfgReceipt $installed)) 'rejects a receipt with a different upstream archive hash';$installed.Sm86MfgSHA256=$recordedPin
 $loaderRecord=@($installed.Files|Where-Object {$_.Path -eq $providerPath -and $_.Component -eq 'Mfg'})[0];$recordedFilePin=$loaderRecord.Hash;$loaderRecord.Hash='untrusted';Check (-not(TestSm86MfgReceipt $installed)) 'rejects a file receipt that differs from the pinned release manifest';$loaderRecord.Hash=$recordedFilePin
 $recordedPaths=@($installed.Sm86MfgFiles);$installed.Sm86MfgFiles=@();Check (-not(TestSm86MfgReceipt $installed)) 'rejects an incomplete provider file inventory';$installed.Sm86MfgFiles=@($recordedPaths[0],$recordedPaths[0])+@($recordedPaths|Select-Object -Skip 2);Check (-not(TestSm86MfgReceipt $installed)) 'rejects a duplicated provider file inventory';$installed.Sm86MfgFiles=$recordedPaths
 $iniConfig=OwnedPath $clean.Game 'OptiShadeData/Engine/dlssg_sm86/dlssg_sm86.ini';$iniTemp=$iniConfig+'.receipt-test';[IO.File]::Move($iniConfig,$iniTemp);try{Check (-not(TestSm86MfgReceipt $installed)) 'treats a missing mutable provider config as needing repair'}finally{[IO.File]::Move($iniTemp,$iniConfig)}
 $editedIni=$iniConfig;[IO.File]::AppendAllText($editedIni,"`r`n; user setting")
 RemoveSm86Mfg $clean.Manifest
 $removed=ReadOptiShadeState $clean.Manifest
 Check (-not $removed.Sm86Mfg -and 'Mfg' -notin $removed.Components -and -not(Test-Path (OwnedPath $clean.Game 'OptiShadeData/Engine/dlssg_sm86/runtime/nvngx_dlssg.dll'))) 'removal deletes verified provider runtime and clears its receipt'
 Check ([IO.File]::ReadAllText($editedIni).Contains('; user setting')) 'removal preserves a user-edited upstream config file'
 Check (([IO.File]::ReadAllText((Join-Path $clean.Game 'OptiScaler.ini')) -match '(?m)^External=false\r?$') -and ([IO.File]::ReadAllText((Join-Path $clean.Game 'OptiScaler.ini')) -match '(?m)^AdaMfgUnlock=true\r?$')) 'removal restores the pre-install OptiScaler settings'

 $conflict=New-Fixture 'foreign-loader' -ForeignVersion
 InstallSm86Mfg $conflict.Manifest $script:fixtureGpu {} $conflict.Archive | Out-Null
 $conflictState=ReadOptiShadeState $conflict.Manifest
 Check ($conflictState.Sm86MfgLoader -eq $providerPath -and [IO.File]::ReadAllText((Join-Path $conflict.Game 'version.dll')) -eq 'foreign game proxy') 'uses the OptiScaler host path and leaves an unrelated game-root proxy untouched'
 RemoveSm86Mfg $conflict.Manifest
 Check ([IO.File]::ReadAllText((Join-Path $conflict.Game 'version.dll')) -eq 'foreign game proxy') 'component removal leaves a foreign proxy intact'

 $alternate=New-Fixture 'alternate-core-proxy' -ProxyName 'dxgi.dll'
 InstallSm86Mfg $alternate.Manifest $script:fixtureGpu {} $alternate.Archive | Out-Null
 Check ((ReadOptiShadeState $alternate.Manifest).Sm86MfgLoader -eq $providerPath -and (Test-Path (Join-Path $alternate.Game 'dxgi.dll'))) 'accepts a verified OptiScaler core installed through a supported alternate proxy'
 RemoveSm86Mfg $alternate.Manifest

 $uninstall=New-Fixture 'uninstall-owned-host-only'
 InstallSm86Mfg $uninstall.Manifest $script:fixtureGpu {} $uninstall.Archive | Out-Null
 Copy-Item -LiteralPath (OwnedPath $uninstall.Game $providerPath) -Destination (Join-Path $uninstall.Game 'version.dll')
 $uninstallState=ReadOptiShadeState $uninstall.Manifest
 RemoveRecordedOptiShadeLoaders $uninstallState $uninstall.Manifest
 Check ((Test-Path (Join-Path $uninstall.Game 'version.dll')) -and -not(Test-Path (OwnedPath $uninstall.Game $providerPath))) 'uninstall removes the provider at its recorded host path and leaves a matching file at an unrelated path'

 $migration=New-Fixture 'source-migration' -OldSource
 InstallSm86Mfg $migration.Manifest $script:fixtureGpu {} $migration.Archive | Out-Null
 $migrated=ReadOptiShadeState $migration.Manifest
 Check ($migrated.Sm86Mfg -and -not $migrated.SourceMfg -and -not(Test-Path (Join-Path $migration.Game 'OptiShadeData/MFG/OptiShadeMFG.dll'))) 'migrates old source-provider receipt and retires only verified source files'
 Check (Test-Path (Join-Path $migration.State 'MfgRollback/old-source')) 'committed provider migration retains historical recovery evidence and original backup chains'
 RemoveSm86Mfg $migration.Manifest
 Check (([IO.File]::ReadAllText((Join-Path $migration.Game 'OptiScaler.ini')) -match '(?m)^External=false\r?$') -and ([IO.File]::ReadAllText((Join-Path $migration.Game 'OptiScaler.ini')) -match '(?m)^AdaMfgUnlock=true\r?$')) 'provider removal returns migrated config to its pre-source values'

 $legacy=New-Fixture 'legacy-proxy-migration' -OldSm86
 InstallSm86Mfg $legacy.Manifest $script:fixtureGpu {} $legacy.Archive | Out-Null
 $legacyState=ReadOptiShadeState $legacy.Manifest
 Check ($legacyState.Sm86MfgLoader -eq $providerPath -and -not(Test-Path (Join-Path $legacy.Game 'version.dll')) -and -not(Test-Path (Join-Path $legacy.Game 'dlssg_sm86.ini'))) 'migrates the prior game-root proxy into the single OptiScaler-hosted provider path'
 RemoveSm86Mfg $legacy.Manifest
 Check (-not(Test-Path (OwnedPath $legacy.Game $providerPath))) 'removes the migrated provider only from its receipt-owned host path'

 $failure=New-Fixture 'failed-activation'
 $beforeManifest=HashFile $failure.Manifest;$failed=$false
 try{InstallSm86Mfg $failure.Manifest $script:fixtureGpu {param($detail,$done,$total) if($detail -like 'Activating*'){throw 'Injected fixture failure.'}} $failure.Archive}catch{$failed=$_.Exception.Message -like '*Injected fixture failure*'}
 Check ($failed -and (HashFile $failure.Manifest) -eq $beforeManifest -and -not(Test-Path (OwnedPath $failure.Game $providerPath)) -and -not(Test-Path (OwnedPath $failure.Game 'OptiShadeData/Engine/dlssg_sm86/dlssg_sm86.ini'))) 'cancellation before activation leaves files and the installation receipt unchanged'

 # Fault after actual provider/INI mutations, followed by real process exit.
 # Both install/migration and removal must recover through the same journal.
 foreach($remove in @($false,$true)){
  $name=if($remove){'remove'}else{'migration'}
  $f=New-Fixture ('late-fault-'+$name) -OldSource
  if($remove){InstallSm86Mfg $f.Manifest $script:fixtureGpu {} $f.Archive|Out-Null}
  $before=CaptureSm86Fixture $f;$realWrite=${function:WriteState};$script:failReceipt=$f.Manifest
  function WriteState($Value,[string]$Path){if($Path -eq $script:failReceipt){throw 'Injected SM86 receipt failure.'};& $realWrite $Value $Path}
  $failed=$false;try{if($remove){RemoveSm86Mfg $f.Manifest}else{InstallSm86Mfg $f.Manifest $script:fixtureGpu {} $f.Archive|Out-Null}}catch{$failed=$_.Exception.Message -like '*Injected SM86 receipt failure*'}finally{Set-Item Function:WriteState $realWrite}
  Check $failed ('SM86 late fault did not reach commit: '+$name);CheckSm86Restored $f $before
  $f=New-Fixture ('crash-'+$name) -OldSource;if($remove){InstallSm86Mfg $f.Manifest $script:fixtureGpu {} $f.Archive|Out-Null};$before=CaptureSm86Fixture $f
  $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=(Get-Process -Id $PID).Path;$start.UseShellExecute=$false;$start.Arguments='-NoLogo -NoProfile -File "'+$PSCommandPath+'" -CrashFixture "'+$f.Root+'"'+$(if($remove){' -CrashRemove'}else{''})
  $child=[Diagnostics.Process]::Start($start);try{$child.WaitForExit();Check ($child.ExitCode -eq 93) ('SM86 child did not exit at receipt commit: '+$name)}finally{$child.Dispose()}
  Check (Test-Path -LiteralPath (Join-Path $f.State 'MfgRouteTransaction.json')) ('Interrupted SM86 operation has no durable pointer: '+$name)
  Check (RecoverOptiShadeRouteTransaction $f.Manifest) ('SM86 restart recovery did not run: '+$name);CheckSm86Restored $f $before
 }
 $original=New-Fixture 'source-original-chain' -OldSource;$m=ReadOptiShadeState $original.Manifest
 $backup=Join-Path $original.State 'original-source';[IO.File]::WriteAllText($backup,'pre-source original payload')
 $record=@($m.Files|Where-Object Path -eq 'OptiShadeData/MFG/OptiShadeMFG.dll')[0];$record.Backup='original-source';$record.PreviousHash=HashFile $backup;WriteState $m $original.Manifest
 InstallSm86Mfg $original.Manifest $script:fixtureGpu {} $original.Archive|Out-Null
 Check ((HashFile (Join-Path $original.Game 'OptiShadeData/MFG/OptiShadeMFG.dll')) -ceq (HashFile $backup)) 'Source-to-SM86 migration discarded the pre-OptiShade original file.'
 "PASS: $script:assertions SM86 installer, migration, removal, ownership and rollback assertions passed. Fixture binaries are data only; no game or GPU was run."
}finally{$script:AntiCheatOperation=$null;$script:AntiCheatSessionAccepted=$false;$env:LOCALAPPDATA=$fixturePreviousLocalAppData;if(Test-Path -LiteralPath $script:testRoot){Remove-Item -LiteralPath $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue}}
