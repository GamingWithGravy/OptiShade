$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Beta/installer/ownership.ps1"
. "$root/Beta/installer/library.ps1"
. "$root/Beta/installer/executable.ps1"
$expectedVersion=GetBundledOptiShadeVersion
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Beta/installer/update-install.ps1'),[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw $parseErrors[0]}
# Load the actual downloaded updater's production functions without launching
# its process handoff. These tests run its real canonical target preflight.
foreach($node in $ast.EndBlock.Statements){if($node -is [Management.Automation.Language.FunctionDefinitionAst]){Invoke-Expression $node.Extent.Text}}
if([IO.Path]::DirectorySeparatorChar -ne '\'){
 function OwnedPath([string]$Root,[string]$Relative){$base=[IO.Path]::GetFullPath($Root).TrimEnd('/')+'/';$path=[IO.Path]::GetFullPath((Join-Path $Root $Relative));if(-not $path.StartsWith($base,[StringComparison]::Ordinal)){throw 'Fixture path escape'};return $path}
 function ResolveOptiShadeLibraryPath([string]$Path){return [IO.Path]::GetFullPath($Path).TrimEnd('/')}
}
function AssertClosed([string]$Game){if(Test-Path -LiteralPath (Join-Path $Game 'fixture-running')){throw 'Fixture game is running.'}}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-updater-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($testRoot)
$store=Join-Path $testRoot 'store';$count=0
function Check($Value,[string]$Message){if(-not $Value){throw $Message};$script:count++}
function InvokeChildUpdate([string]$Payload,[string]$Installer,[switch]$ValidateOnly){
 $scriptPath=Join-Path $root 'Beta/installer/update-install.ps1';$id=[guid]::NewGuid().ToString('N')
 $stdout=Join-Path $testRoot ($id+'.stdout');$stderr=Join-Path $testRoot ($id+'.stderr')
 $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath,'-Payload',$Payload,'-Installer',$Installer)
 if($ValidateOnly){$args+='-ValidateOnly'}
 $quoted=@($args|ForEach-Object {'"'+([string]$_).Replace('"','\"')+'"'}) -join ' '
 # Use the same PowerShell host as the test runner. In particular, pwsh may
 # prepend its bundled modules to PSModulePath; launching inbox Windows
 # PowerShell with that inherited module path can make Get-FileHash disappear.
 $hostPath=(Get-Process -Id $PID).Path
 $process=Start-Process -FilePath $hostPath -ArgumentList $quoted -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
 $output='';foreach($file in @($stdout,$stderr)){if(Test-Path -LiteralPath $file){$output+=[IO.File]::ReadAllText($file);Remove-Item -LiteralPath $file -Force}}
 [pscustomobject]@{ExitCode=$process.ExitCode;Output=$output}
}
function WriteFixtureExe([string]$Path,[bool]$X86){
 $bytes=New-Object byte[] 1024;$stream=[IO.MemoryStream]::new($bytes,$true);$writer=[IO.BinaryWriter]::new($stream)
 try{
  $writer.Write([uint16]0x5a4d);$stream.Position=0x3c;$writer.Write([uint32]0x80)
  $stream.Position=0x80;$writer.Write([uint32]0x4550);$writer.Write([uint16]$(if($X86){0x14c}else{0x8664}));$writer.Write([uint16]1)
  $optional=if($X86){224}else{240};$stream.Position=0x94;$writer.Write([uint16]$optional);$writer.Write([uint16]2);$writer.Write([uint16]$(if($X86){0x10b}else{0x20b}))
  $stream.Position=0x98+60;$writer.Write([uint32]512)
  $stream.Position=0x98+$optional+8;$writer.Write([uint32]512);$writer.Write([uint32]0x1000);$writer.Write([uint32]512);$writer.Write([uint32]512)
 }finally{$writer.Dispose()}
 [IO.File]::WriteAllBytes($Path,$bytes)
}
function Fixture([string]$Name,[bool]$X86){
 $game=Join-Path $testRoot $Name;[void][IO.Directory]::CreateDirectory($game);$exe=Join-Path $game ($Name+'.exe');WriteFixtureExe $exe $X86
 $loader=if($X86){'opengl32.dll'}else{'dxgi.dll'};[IO.File]::WriteAllText((Join-Path $game $loader),'owned core '+$Name)
 $source=if($X86){'ReShade32.dll'}else{'winmm.dll'};$receipt=ManifestPath $store $game;[void][IO.Directory]::CreateDirectory((Split-Path $receipt))
 WriteState ([pscustomobject]@{Game=$game;Status='Installed';LaunchExe=$exe;Architecture=$(if($X86){'x86'}else{'x64'});RouteDLL='OptiShadeGeneric.dll';Files=@([pscustomobject]@{Path=$loader;SourcePath=$source;Hash=(HashFile (Join-Path $game $loader));Mutable=$false;Backup='';PreviousHash='';Retained=$false})}) $receipt
 [pscustomobject]@{Game=$game;Exe=$exe;Receipt=$receipt;Loader=$loader}
}
try{
 $generic=Fixture 'ForzaHorizon4' $false;$legacy=Fixture 'LegacyGeneric' $true
 foreach($name in @('AddonBackups/older','Rollback/older','MfgRollback/older','Backup/older')){
  $directory=Join-Path (Split-Path $generic.Receipt) $name;[void][IO.Directory]::CreateDirectory($directory)
  WriteState ([pscustomobject]@{Game=$generic.Game;Status='Installing';Files=@()}) (Join-Path $directory 'manifest.json')
 }
 $targets=@(GetOptiShadeWholeManagerUpdateTargets $store @())
 Check ($targets.Count -eq 2) 'Whole-manager preflight included a nested archived receipt or excluded a generic game.'
 Check (@($targets|Where-Object {$_.Architecture -eq 'x86' -and $_.Proxy -eq 'opengl32.dll'}).Count -eq 1) 'ReShade32 ownership was not accepted as the x86 core route.'
 Check (@($targets|Where-Object {$_.Executable -eq $generic.Exe -and $_.Architecture -eq 'x64'}).Count -eq 1) 'Generic x64 rendering identity was not preserved.'
 $childPayload=Join-Path $testRoot 'child-update-payload';[void][IO.Directory]::CreateDirectory($childPayload)
 $sourcePayload=Join-Path $root 'Beta/installer/PayloadFusion';$sourceCatalog=Get-Content (Join-Path $sourcePayload 'files.json') -Raw|ConvertFrom-Json
 $childPaths=@('winmm.dll','ReShade64.dll','ReShade32.dll','ReShade.ini','OptiShadeData/Engine/Routes/OptiShadeGeneric.dll')
 $childCatalog=@($sourceCatalog|Where-Object {$_.Path.Replace('\','/') -cin $childPaths})
 foreach($entry in $childCatalog){$targetPath=OwnedPath $childPayload $entry.Path;[void][IO.Directory]::CreateDirectory((Split-Path $targetPath -Parent));Copy-Item -LiteralPath (OwnedPath $sourcePayload $entry.Path) -Destination $targetPath}
 [IO.File]::WriteAllText((Join-Path $childPayload 'files.json'),(ConvertTo-Json -InputObject $childCatalog -Depth 8),[Text.UTF8Encoding]::new($false))
 $childInstaller=Join-Path $testRoot 'fixture-installer.exe';[IO.File]::WriteAllText($childInstaller,'verified installer identity')
 $priorStore=$env:OPTISHADE_STORE;$env:OPTISHADE_STORE=$store
 try{
  $childRun=InvokeChildUpdate $childPayload $childInstaller -ValidateOnly;$childOutput=$childRun.Output;$childExit=$childRun.ExitCode
 }finally{if($null -eq $priorStore){Remove-Item Env:OPTISHADE_STORE -ErrorAction SilentlyContinue}else{$env:OPTISHADE_STORE=$priorStore}}
 Check ($childExit -eq 0 -and $childOutput -match 'Validated 5 payload files and 2 available recorded installation\(s\); 0 unavailable installation\(s\)') ("The actual child-manager check rejected mixed generic/x86 receipts or included nested archived receipts (exit $childExit): $childOutput")
 $savedStore=$store;$applyStore=Join-Path $testRoot 'child-apply-store';$store=$applyStore
 $applyGeneric=Fixture 'ChildApplyGeneric' $false;$applyLegacy=Fixture 'ChildApplyLegacyX86' $true
 $deferredGame=Join-Path $testRoot 'ChildResumeAfterInstall';[void][IO.Directory]::CreateDirectory($deferredGame)
 $deferredExe=Join-Path $deferredGame 'ChildResumeAfterInstall.exe';$deferredLoader=Join-Path $deferredGame 'dxgi.dll';[IO.File]::WriteAllText($deferredLoader,'owned deferred core')
 $deferredReceipt=ManifestPath $store $deferredGame;[void][IO.Directory]::CreateDirectory((Split-Path $deferredReceipt))
 WriteState ([pscustomobject]@{Game=$deferredGame;Status='Installed';LaunchExe=$deferredExe;Architecture='x64';RouteDLL='OptiShadeGeneric.dll';Files=@([pscustomobject]@{Path='dxgi.dll';SourcePath='winmm.dll';Hash=(HashFile $deferredLoader);Mutable=$false;Backup='';PreviousHash='';Retained=$false})}) $deferredReceipt
 $priorStore=$env:OPTISHADE_STORE;$priorConsent=$env:OPTISHADE_ANTICHEAT_SESSION_ACCEPTED;$env:OPTISHADE_STORE=$store;$env:OPTISHADE_ANTICHEAT_SESSION_ACCEPTED='1'
 try{
  $applyRun=InvokeChildUpdate $childPayload $childInstaller;$applyOutput=$applyRun.Output;$applyExit=$applyRun.ExitCode
 }finally{if($null -eq $priorStore){Remove-Item Env:OPTISHADE_STORE -ErrorAction SilentlyContinue}else{$env:OPTISHADE_STORE=$priorStore};if($null -eq $priorConsent){Remove-Item Env:OPTISHADE_ANTICHEAT_SESSION_ACCEPTED -ErrorAction SilentlyContinue}else{$env:OPTISHADE_ANTICHEAT_SESSION_ACCEPTED=$priorConsent}}
 Check ($applyExit -ne 0 -and $applyOutput -match 'InstallationsDeferred') ("The real child-manager apply did not retain the deferred target as expected (exit $applyExit): $applyOutput")
 $genericApplied=ReadOptiShadeState (ManifestPath $store $applyGeneric.Game);$legacyApplied=ReadOptiShadeState (ManifestPath $store $applyLegacy.Game)
 Check ($genericApplied.Version -eq $expectedVersion -and @($genericApplied.Files|Where-Object {$_.Path -eq 'dxgi.dll' -and $_.SourcePath -eq 'winmm.dll'}).Count -eq 1) 'The real child-manager apply did not preserve and refresh the generic x64 core loader.'
 Check ($legacyApplied.Version -eq $expectedVersion -and @($legacyApplied.Files|Where-Object {$_.Path -eq 'opengl32.dll' -and $_.SourcePath -eq 'ReShade32.dll'}).Count -eq 1) 'The real child-manager apply did not preserve and refresh the x86 ReShade32 loader.'
 WriteFixtureExe $deferredExe $false
 $priorStore=$env:OPTISHADE_STORE;$priorConsent=$env:OPTISHADE_ANTICHEAT_SESSION_ACCEPTED;$env:OPTISHADE_STORE=$store;$env:OPTISHADE_ANTICHEAT_SESSION_ACCEPTED='1'
 try{
  $resumeRun=InvokeChildUpdate $childPayload $childInstaller;$resumeOutput=$resumeRun.Output;$resumeExit=$resumeRun.ExitCode
 }finally{if($null -eq $priorStore){Remove-Item Env:OPTISHADE_STORE -ErrorAction SilentlyContinue}else{$env:OPTISHADE_STORE=$priorStore};if($null -eq $priorConsent){Remove-Item Env:OPTISHADE_ANTICHEAT_SESSION_ACCEPTED -ErrorAction SilentlyContinue}else{$env:OPTISHADE_ANTICHEAT_SESSION_ACCEPTED=$priorConsent}}
 Check ($resumeExit -eq 0 -and $resumeOutput -match 'Updated 1 supported game installation\(s\); 2 already-completed installation\(s\) were verified and skipped') 'The real child-manager resume did not update the returned target while revalidating and skipping completed targets.'
 $deferredApplied=ReadOptiShadeState $deferredReceipt
 $completedJournals=@(Get-ChildItem (Join-Path $store 'UpdateTransactions') -Filter '*.json'|ForEach-Object {Get-Content $_.FullName -Raw|ConvertFrom-Json}|Where-Object Status -eq 'Complete')
 Check ($deferredApplied.Version -eq $expectedVersion -and $completedJournals.Count -eq 1) ("The child-manager resume did not complete and record the deferred target (version='$($deferredApplied.Version)', expected='$expectedVersion', completeJournals=$($completedJournals.Count), resumeExit=$resumeExit, output='$resumeOutput').")
 $store=$savedStore
 $target=@($targets|Where-Object Executable -eq $generic.Exe)[0];AssertOptiShadeUpdateTargetUnchanged $target
 $xboxGame=Join-Path $testRoot 'XboxMSFS24';[void][IO.Directory]::CreateDirectory($xboxGame);$xboxExe=Join-Path $xboxGame 'FlightSimulator2024.exe';WriteFixtureExe $xboxExe $false
 $xboxLoader=Join-Path $xboxGame 'winmm.dll';[IO.File]::WriteAllText($xboxLoader,'owned Xbox MSFS loader');$xboxReceipt=ManifestPath $store $xboxGame;[void][IO.Directory]::CreateDirectory((Split-Path $xboxReceipt))
 WriteState ([pscustomobject]@{Game=$xboxGame;Status='Installed';LaunchExe=$xboxExe;Architecture='x64';RouteDLL='OptiShadeMSFS2024.dll';Files=@([pscustomobject]@{Path='winmm.dll';SourcePath='winmm.dll';Hash=(HashFile $xboxLoader);Mutable=$false;Backup='';PreviousHash='';Retained=$false})}) $xboxReceipt
 $identityFunction=(Get-Command GetOptiShadeExecutableIdentity -CommandType Function).ScriptBlock
 function GetOptiShadeExecutableIdentity([string]$File){if($File -ieq $script:testDeniedExecutable){throw [UnauthorizedAccessException]::new('Access is denied.')};& $script:identityFunction $File}
 $script:testDeniedExecutable=$xboxExe
 try{
  $xboxTarget=@(GetOptiShadeWholeManagerUpdateTargets $store @()|Where-Object Executable -eq $xboxExe)[0]
  Check (-not $xboxTarget.Deferred -and -not $xboxTarget.ExecutableHash -and $xboxTarget.Architecture -eq 'x64' -and $null -eq $xboxTarget.ExecutableMetadata.PSObject.Properties['ApiObserved']) 'Unreadable Xbox MSFS did not preserve only its prior x64 route with unknown API/hash.'
  AssertOptiShadeUpdateTargetUnchanged $xboxTarget
  $priorTime=[IO.File]::GetLastWriteTimeUtc($xboxExe);[IO.File]::SetLastWriteTimeUtc($xboxExe,$priorTime.AddSeconds(2))
  $failed=$false;try{AssertOptiShadeUpdateTargetUnchanged $xboxTarget}catch{$failed=$_.Exception.Message -like '*changed after update preflight*'}
  Check $failed 'An unreadable executable metadata change did not invalidate update preflight.'
  [IO.File]::SetLastWriteTimeUtc($xboxExe,$priorTime)
  $xboxResume=[pscustomobject]@{Receipt=$xboxTarget.Receipt;Executable=$xboxTarget.Executable;ExecutableHash='';ExecutableMetadata=$xboxTarget.ExecutableMetadata;Architecture='x64';BeforeFingerprint=$xboxTarget.BeforeFingerprint;State='Pending';CompletedFingerprint='';Failure='';UpdatedUtc=''}
  SetOptiShadeUpdateResumeTarget $xboxTarget $xboxResume
  [IO.File]::SetLastWriteTimeUtc($xboxExe,$priorTime.AddSeconds(3));$changedXBoxTarget=@(GetOptiShadeWholeManagerUpdateTargets $store @()|Where-Object Executable -eq $xboxExe)[0]
  $failed=$false;try{SetOptiShadeUpdateResumeTarget $changedXBoxTarget $xboxResume}catch{$failed=$_.Exception.Message -like '*executable changed after this update was planned*'}
  Check $failed 'A resumed hashless Xbox target ignored executable metadata drift.'
  [IO.File]::SetLastWriteTimeUtc($xboxExe,$priorTime)
  $wrongRoute=ReadOptiShadeState $xboxReceipt;$wrongRoute.RouteDLL='OptiShadeGeneric.dll';WriteState $wrongRoute $xboxReceipt
  $failed=$false;try{$null=GetOptiShadeWholeManagerUpdateTargets $store @()}catch{$failed=$_.Exception.Message -like '*no previously installed*'}
  $wrongRoute.RouteDLL='OptiShadeMSFS2024.dll';WriteState $wrongRoute $xboxReceipt
  Check $failed 'The unreadable executable fallback accepted a non-MSFS route.'
 }finally{$script:testDeniedExecutable=$null;Set-Item Function:GetOptiShadeExecutableIdentity -Value $identityFunction}
 $preferenceBefore=[IO.File]::ReadAllBytes($generic.Receipt)
 foreach($change in @(@('AutoComponentExclusions',@('Effects')),@('NeuralAdapterSelection','explicit'))){
  $m=ReadOptiShadeState $generic.Receipt;$m|Add-Member -NotePropertyName $change[0] -NotePropertyValue $change[1] -Force;WriteState $m $generic.Receipt
  $failed=$false;try{AssertOptiShadeUpdateTargetUnchanged $target}catch{$failed=$true}
  Check $failed ('A newer '+$change[0]+' choice did not invalidate the pending update preflight.')
  [IO.File]::WriteAllBytes($generic.Receipt,$preferenceBefore)
 }
 [IO.File]::WriteAllText((Join-Path $generic.Game 'fixture-running'),'fixture')
 $failed=$false;try{$null=GetOptiShadeWholeManagerUpdateTargets $store @()}catch{$failed=$_.Exception.Message -like '*running*'}
 Check $failed 'Running generic target was admitted.';Remove-Item -LiteralPath (Join-Path $generic.Game 'fixture-running')
 $before=[IO.File]::ReadAllBytes($generic.Receipt);$m=ReadOptiShadeState $generic.Receipt;$m.Architecture='x86';WriteState $m $generic.Receipt
 $failed=$false;try{$null=GetOptiShadeWholeManagerUpdateTargets $store @()}catch{$failed=$_.Exception.Message -like '*architecture*'}
 Check $failed 'Receipt/loader architecture mismatch was admitted.';[IO.File]::WriteAllBytes($generic.Receipt,$before)
 $exeBefore=[IO.File]::ReadAllBytes($generic.Exe);WriteFixtureExe $generic.Exe $true
 $failed=$false;try{AssertOptiShadeUpdateTargetUnchanged $target}catch{$failed=$true};Check $failed 'Game build changed after preflight without invalidating the target.'
 $failed=$false;try{$null=GetOptiShadeWholeManagerUpdateTargets $store @()}catch{$failed=$_.Exception.Message -like '*architecture changed*'};Check $failed 'Changed executable architecture was admitted.'
 [IO.File]::WriteAllBytes($generic.Exe,$exeBefore)
 $loaderPath=Join-Path $generic.Game $generic.Loader;$loaderBefore=[IO.File]::ReadAllBytes($loaderPath);[IO.File]::WriteAllText($loaderPath,'foreign loader')
 $failed=$false;try{$null=GetOptiShadeWholeManagerUpdateTargets $store @()}catch{$failed=$_.Exception.Message -like '*core loader changed*'};Check ($failed -and [IO.File]::ReadAllText($loaderPath) -eq 'foreign loader') 'Foreign loader was admitted or overwritten.'
 [IO.File]::WriteAllBytes($loaderPath,$loaderBefore)
 $knownLegacy=@($targets|Where-Object Executable -eq $legacy.Exe)[0]
 $resumeEntry=[pscustomobject]@{Receipt=$knownLegacy.Receipt;Executable=$knownLegacy.Executable;ExecutableHash=$knownLegacy.ExecutableHash;Architecture=$knownLegacy.Architecture;BeforeFingerprint=$knownLegacy.BeforeFingerprint;State='Pending';CompletedFingerprint='';Failure='';UpdatedUtc=''}
 $legacyReceiptBefore=HashFile $legacy.Receipt
 [IO.File]::Delete($legacy.Exe);$deferredTargets=@(GetOptiShadeWholeManagerUpdateTargets $store @())
 Check ($deferredTargets.Count -eq 3 -and @($deferredTargets|Where-Object Deferred).Count -eq 1 -and @($deferredTargets|Where-Object {-not $_.Deferred}).Count -eq 2) 'Unavailable generic target disappeared or blocked the independently available update targets.'
 $deferred=@($deferredTargets|Where-Object Deferred)[0];SetOptiShadeUpdateResumeTarget $deferred $resumeEntry
 Check ($resumeEntry.State -eq 'Deferred' -and $deferred.Skip -and $resumeEntry.Failure -like '*unavailable*' -and $resumeEntry.ExecutableHash -ceq $knownLegacy.ExecutableHash) 'Scoped deferral lost the known executable identity or did not keep the target out of file mutation.'
 Check ((HashFile $legacy.Receipt) -ceq $legacyReceiptBefore) 'Read-only preflight/deferral modified the unavailable installation receipt.'
 $journalPath=Join-Path $testRoot 'deferred-journal.json';WriteUpdateJournal ([pscustomobject]@{Schema=1;Targets=@($resumeEntry)}) $journalPath
 $saved=ReadOptiShadeJson $journalPath 'fixture journal';$resumeEntry=$saved.Targets[0]
 Check ($resumeEntry.State -eq 'Deferred' -and $resumeEntry.ExecutableHash -ceq $knownLegacy.ExecutableHash) 'The existing durable update journal failed to retain deferred identity.'
 WriteFixtureExe $legacy.Exe $true
 $returned=@(GetOptiShadeWholeManagerUpdateTargets $store @()|Where-Object Executable -eq $legacy.Exe)[0]
 SetOptiShadeUpdateResumeTarget $returned $resumeEntry
 Check (-not $returned.Skip -and $resumeEntry.State -eq 'Pending' -and $resumeEntry.ExecutableHash -ceq $returned.ExecutableHash) 'A returned unchanged installation could not resume its deferred update.'
 $changedBytes=[IO.File]::ReadAllBytes($legacy.Exe);$changedBytes[1023]=1;[IO.File]::WriteAllBytes($legacy.Exe,$changedBytes)
 $changedTarget=@(GetOptiShadeWholeManagerUpdateTargets $store @()|Where-Object Executable -eq $legacy.Exe)[0]
 $failed=$false;try{SetOptiShadeUpdateResumeTarget $changedTarget $resumeEntry}catch{$failed=$_.Exception.Message -like '*executable changed*'};Check $failed 'A different executable build inherited an earlier deferred update identity.'
 WriteFixtureExe $legacy.Exe $true
 $preferences=[pscustomobject]@{AutoCompatibility=[pscustomobject]@{Desired=[pscustomobject]@{enabled=$true;nr='off';upscaling='auto';frameGeneration='auto'};Evidence='installation_only'};NeuralAdapter=[pscustomobject]@{Luid='42';Evidence='inventory_candidate'};NeuralRuntimeVariant='compat-3109';NeuralRuntimeHash=('A'*64);DlssRuntimeProfile='nvidia-310.7.0';Architecture='old architecture';RouteDLL='old route';LaunchExe='old executable'}
 $newReceipt=@{Architecture='x64';RouteDLL='new route';LaunchExe='new executable'};CopyOptiShadeInstallationPreferences $preferences $newReceipt
 Check ($newReceipt.AutoCompatibility.Desired.nr -ceq 'off' -and $newReceipt.NeuralAdapter.Luid -ceq '42' -and $newReceipt.NeuralRuntimeVariant -ceq 'compat-3109' -and $newReceipt.NeuralRuntimeHash -ceq ('A'*64) -and $newReceipt.DlssRuntimeProfile -ceq 'nvidia-310.7.0') 'Core receipt reconstruction preserves preferences and the legacy runtime ID until an explicit runtime repair migrates it.'
 Check ($newReceipt.Architecture -ceq 'x64' -and $newReceipt.RouteDLL -ceq 'new route' -and $newReceipt.LaunchExe -ceq 'new executable') 'Preserving preferences replaced the new core/runtime/executable identity.'

 $m=ReadOptiShadeState $generic.Receipt;$m.Status='Restored';WriteState $m $generic.Receipt
 Check (@(GetOptiShadeWholeManagerUpdateTargets $store @()).Count -eq 2) 'Restored receipt remained an update target.'
 [IO.File]::WriteAllText($generic.Receipt,'{ damaged canonical receipt')
 $failed=$false;try{$null=GetOptiShadeWholeManagerUpdateTargets $store @()}catch{$failed=$true};Check $failed 'Malformed canonical receipt was silently ignored by whole-manager update.'
 "Whole-manager updater: $count assertions passed with real canonical enumeration, PE identities, x86/x64 core ownership, archive exclusion, scoped offline deferral/resume, preference retention and preflight invalidation."
}finally{Remove-Item -LiteralPath $testRoot -Recurse -Force}
