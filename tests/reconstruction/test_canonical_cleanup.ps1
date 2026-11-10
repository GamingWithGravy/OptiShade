$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Beta/installer/ownership.ps1"
. "$root/Beta/installer/library.ps1"

# The product uses Windows paths. Only path normalization and process lookup
# are replaced on other hosts; ownership, hashes, restore and cleanup are real.
if([IO.Path]::DirectorySeparatorChar -ne '\'){
 function OwnedPath([string]$Root,[string]$Relative){
  $base=[IO.Path]::GetFullPath($Root).TrimEnd('/')+'/'
  $path=[IO.Path]::GetFullPath((Join-Path $Root $Relative))
  if(-not $path.StartsWith($base,[StringComparison]::Ordinal)){throw 'Fixture path escape.'}
  $check=$path
  while($check){
   if((Test-Path -LiteralPath $check) -and ((Get-Item -LiteralPath $check -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Linked fixture path.'}
   $parent=Split-Path $check -Parent;if($parent -eq $check){break};$check=$parent
  }
  return $path
 }
 function ResolveOptiShadeLibraryPath([string]$Path){return [IO.Path]::GetFullPath($Path).TrimEnd('/')}
}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-cleanup-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
function GetShaderRecoveryRoot { Join-Path $testRoot 'recovery' }
$script:closedGames=@();$script:restoreReceipts=@();$script:checks=0
function AssertClosed([string]$Game){
 if((Test-Path -LiteralPath $Game) -and -not(Test-Path -LiteralPath (Join-Path $Game 'fixture-only.txt'))){throw 'Cleanup attempted a non-fixture game.'}
 $script:closedGames+=,$Game
 if(Test-Path -LiteralPath (Join-Path $Game 'fixture-running')){throw 'Fixture game is running.'}
}
$script:realRestore=${function:RestoreFusion}
function RestoreFusion([string]$ManifestPath,[bool]$KeepPresets=$true,[scriptblock]$Progress={param($detail,$completed=0,$total=0)}){
 $script:restoreReceipts+=,$ManifestPath
 & $script:realRestore $ManifestPath -KeepPresets $KeepPresets -Progress $Progress
}
function Check($Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Fixture([string]$Name,[string]$Store='',[string]$Status='Installed'){
 if(-not $Store){$Store=Join-Path $testRoot ($Name+'/OptiShade')}
 $game=Join-Path $testRoot ($Name+'/game');[void][IO.Directory]::CreateDirectory((Join-Path $game 'OptiShadeData/Presets'))
 $receipt=ManifestPath $Store $game;$folder=Split-Path $receipt
 [void][IO.Directory]::CreateDirectory((Join-Path $folder 'Backups'))
 $loader=Join-Path $game 'dxgi.dll';$original=Join-Path $folder 'Backups/original-loader'
 $preset=Join-Path $game 'OptiShadeData/Presets/my-look.ini'
 [IO.File]::WriteAllText((Join-Path $game 'fixture-only.txt'),'isolated ownership fixture')
 [IO.File]::WriteAllText((Join-Path $game 'Game.exe'),'unchanged game executable fixture')
 [IO.File]::WriteAllText($loader,'OptiShade loader '+$Name)
 [IO.File]::WriteAllText($original,'original game loader '+$Name)
 [IO.File]::WriteAllText($preset,'user saved look '+$Name)
 WriteState ([pscustomobject]@{Game=$game;Status=$Status;Version=(GetBundledOptiShadeVersion);OwnedDirectories=@('OptiShadeData');Components=@();Files=@(
  [pscustomobject]@{Path='dxgi.dll';SourcePath='winmm.dll';Hash=(HashFile $loader);PreviousHash=(HashFile $original);Backup='Backups/original-loader';Mutable=$false;Retained=$false},
  [pscustomobject]@{Path='OptiShadeData/Presets/my-look.ini';SourcePath='';Hash=(HashFile $preset);PreviousHash='';Backup='';Mutable=$true;Retained=$false}
 )}) $receipt
 return [pscustomobject]@{Game=$game;Store=$Store;Receipt=$receipt;Folder=$folder;Loader=$loader;Original=$original;Preset=$preset;ReceiptHash=(HashFile $receipt);LoaderHash=(HashFile $loader);OriginalHash=(HashFile $original)}
}
function SaveArchive($Fixture,[string]$Relative,$Manifest=$null){
 $file=Join-Path $Fixture.Folder ($Relative+'/manifest.json');[void][IO.Directory]::CreateDirectory((Split-Path $file))
 if($Manifest){WriteState $Manifest $file}else{Copy-Item -LiteralPath $Fixture.Receipt -Destination $file}
 return $file
}
function ExpectBlocked([scriptblock]$Action,[string]$Pattern,[string]$Message){
 $blocked=$false;try{& $Action}catch{$blocked=$_.Exception.Message -like $Pattern}
 Check $blocked $Message
}
try{
 $f=Fixture 'real-uninstall'
 $archives=@();foreach($relative in @('MfgRollback/0123456789abcdef','AddonBackups/0123456789abcdef','Rollback/older','Repair-archived/older')){$archives+=SaveArchive $f $relative}
 # A saved rollback receipt must never become a mutation owner. The shared
 # store gate now rejects it before process or backup lookup; the actual
 # damaged-original case below still exercises the independent hash guard.
 ExpectBlocked {RestoreFusion $archives[0]} '*canonical game receipt*' 'A saved transaction receipt was admitted as a mutation owner.'
 Check ($script:closedGames.Count -eq 0 -and (HashFile $f.Loader) -ceq $f.LoaderHash -and (HashFile $f.Receipt) -ceq $f.ReceiptHash -and (HashFile $archives[0]) -ceq $f.ReceiptHash -and (HashFile $f.Original) -ceq $f.OriginalHash) 'Archive admission reached process lookup or changed a loader, receipt, archive or original backup.'
 $script:restoreReceipts=@();$progressEvents=[Collections.Generic.List[object]]::new()
 $onProgress={param($detail,$completed,$total);$progressEvents.Add([pscustomobject]@{Detail=$detail;Completed=$completed})}.GetNewClosure()
 UninstallFusion $f.Store (Join-Path $testRoot 'installer.exe') -Progress $onProgress
 Check ($script:restoreReceipts.Count -eq 1 -and $script:restoreReceipts[0] -ceq $f.Receipt) 'Uninstall restored a nested archive or repeated a canonical installation.'
 Check ((HashFile $f.Loader) -ceq $f.OriginalHash) 'Uninstall failed to restore the verified original game loader.'
 Check ((Test-Path -LiteralPath $f.Preset) -and [IO.File]::ReadAllText((Join-Path $f.Game 'Game.exe')) -ceq 'unchanged game executable fixture') 'Uninstall changed the game executable or failed to retain the saved look.'
 Check (-not(Test-Path -LiteralPath $f.Store)) 'Completed uninstall retained the obsolete application store.'
 Check ($progressEvents.Count -gt 1 -and $progressEvents[-1].Completed -eq 100) 'Canonical uninstall lost final progress reporting.'

 $emptyStore=Join-Path $testRoot 'clean-manager-only/OptiShade';[void][IO.Directory]::CreateDirectory((Join-Path $emptyStore 'Games'))
 UninstallFusion $emptyStore (Join-Path $testRoot 'installer.exe')
 Check (-not(Test-Path -LiteralPath $emptyStore)) 'A fresh manager with an empty game index could not be uninstalled.'

 $f=Fixture 'live-manager-session'
 $sessions=Join-Path $f.Store 'Sessions';$stale=Join-Path $sessions 'setup-stale';$live=Join-Path $sessions 'setup-live'
 [void][IO.Directory]::CreateDirectory($stale);[void][IO.Directory]::CreateDirectory($live)
 $staleFile=Join-Path $stale 'old-extraction.bin';$liveImage=Join-Path $live 'FusionSetup.exe'
 [IO.File]::WriteAllText($staleFile,'stale session');[IO.File]::WriteAllText($liveImage,'running session fixture')
 $liveDirectories=@(GetOptiShadeLiveManagerSessionDirectories $f.Store @($liveImage))
 Check ($liveDirectories.Count -eq 1 -and $liveDirectories[0] -ceq (FullPath $live)) 'Live manager process paths were not scoped to their exact session directory.'
 $progressEvents=[Collections.Generic.List[object]]::new()
 $onProgress={param($detail,$completed,$total);$progressEvents.Add([pscustomobject]@{Detail=$detail;Completed=$completed})}.GetNewClosure()
 UninstallFusion $f.Store (Join-Path $testRoot 'installer.exe') -RunningImagePaths @($liveImage) -Progress $onProgress
 Check (-not(Test-Path -LiteralPath $staleFile) -and (Test-Path -LiteralPath $liveImage)) 'Uninstall failed to remove stale sessions or attempted to delete a live manager session.'
 Check ($progressEvents[-1].Detail -match 'Other open OptiShade windows will finish cleaning') 'Uninstall did not explain deferred cleanup for another open manager.'

 $f=Fixture 'current-manager-session'
 $current=Join-Path $f.Store 'Sessions/setup-current';[void][IO.Directory]::CreateDirectory($current)
 $currentImage=Join-Path $current 'FusionSetup.exe';[IO.File]::WriteAllText($currentImage,'current session fixture')
 $progressEvents=[Collections.Generic.List[object]]::new()
 $onProgress={param($detail,$completed,$total);$progressEvents.Add([pscustomobject]@{Detail=$detail;Completed=$completed})}.GetNewClosure()
 UninstallFusion $f.Store (Join-Path $testRoot 'installer.exe') $current -RunningImagePaths @($currentImage) -Progress $onProgress
 Check ((Test-Path -LiteralPath $currentImage) -and $progressEvents[-1].Detail -match 'This manager will finish cleaning its session files') 'Uninstall mislabeled its own active session as another manager or removed it before process exit.'

 $f=Fixture 'preset-only';$restored=Fixture 'already-restored' $f.Store 'Restored'
 Copy-Item -LiteralPath $restored.Original -Destination $restored.Loader -Force
 $unrelated=Join-Path $testRoot 'unowned-game';[void][IO.Directory]::CreateDirectory((Join-Path $unrelated 'OptiShadeData/Presets'))
 [IO.File]::WriteAllText((Join-Path $unrelated 'fixture-only.txt'),'fixture')
 $unrelatedPreset=Join-Path $unrelated 'OptiShadeData/Presets/do-not-remove.ini';[IO.File]::WriteAllText($unrelatedPreset,'unowned look')
 $poison=ReadOptiShadeState $f.Receipt;$poison.Game=$unrelated
 $archive=SaveArchive $f 'MfgRollback/old-other-game' $poison;$archiveHash=HashFile $archive
 $script:closedGames=@()
 RemoveSelectedOptiShadeData $f.Store (Join-Path $testRoot 'installer.exe') '' $false $true $false
 Check (-not(Test-Path -LiteralPath $f.Preset) -and -not(Test-Path -LiteralPath $restored.Preset)) 'Preset cleanup dropped a canonical current or already-restored installation.'
 Check (Test-Path -LiteralPath $unrelatedPreset) 'Preset cleanup admitted an archived manifest pointing to another game.'
 Check ($unrelated -notin $script:closedGames -and $f.Game -in $script:closedGames -and $restored.Game -in $script:closedGames) 'Cleanup preflight did not restrict process checks to the canonical games.'
 Check ((HashFile $f.Loader) -ceq $f.LoaderHash -and (HashFile $f.Receipt) -ceq $f.ReceiptHash -and (HashFile $archive) -ceq $archiveHash) 'Preset-only cleanup changed a runtime, receipt or rollback copy.'

 $available=Fixture 'available';$offline=Fixture 'offline' $available.Store
 $disconnected=$offline.Game+'-disconnected';Move-Item -LiteralPath $offline.Game -Destination $disconnected
 $inventory=@(GetFusionInstallationReceipts $available.Store -Strict)
 Check ($inventory.Count -eq 2 -and $offline.Receipt -in $inventory.FullName) 'Canonical inventory silently dropped an unavailable owned game.'
 $script:restoreReceipts=@()
 ExpectBlocked {UninstallFusion $available.Store (Join-Path $testRoot 'installer.exe')} '*game folder is unavailable*' 'Uninstall silently discarded an unavailable installation.'
 Check ($script:restoreReceipts.Count -eq 0 -and (HashFile $available.Loader) -ceq $available.LoaderHash) 'Unavailable target was detected only after another game was restored.'
 Check ((HashFile $available.Receipt) -ceq $available.ReceiptHash -and (HashFile $offline.Receipt) -ceq $offline.ReceiptHash -and (HashFile $offline.Original) -ceq $offline.OriginalHash) 'Unavailable target lost its canonical receipt or original backup.'
 ExpectBlocked {RemoveSelectedOptiShadeData $available.Store (Join-Path $testRoot 'installer.exe') '' $false $true $false} '*game folder is unavailable*' 'Preset cleanup claimed completion for an unavailable owned target.'
 Check (Test-Path -LiteralPath $available.Preset) 'Unavailable target caused partial preset deletion in another game.'
 Move-Item -LiteralPath $disconnected -Destination $offline.Game
 $script:restoreReceipts=@();UninstallFusion $available.Store (Join-Path $testRoot 'installer.exe')
 Check ($script:restoreReceipts.Count -eq 2 -and (HashFile $available.Loader) -ceq $available.OriginalHash -and (HashFile $offline.Loader) -ceq $offline.OriginalHash) 'An unavailable canonical target did not resume restoration after its folder returned.'

 $removed=Fixture 'already-uninstalled';$removedPeer=Fixture 'already-uninstalled-peer' $removed.Store
 $removedPeerReceiptHash=$removedPeer.ReceiptHash;$removedPeerLoaderHash=$removedPeer.LoaderHash
 Remove-Item -LiteralPath $removed.Game -Recurse -Force
 Check (RemoveMissingOptiShadeInstallRecord $removed.Store $removed.Game) 'Explicit missing-game removal did not complete.'
 Check (-not(Test-Path -LiteralPath $removed.Game) -and -not(Test-Path -LiteralPath $removed.Receipt) -and -not(Test-Path -LiteralPath $removed.Folder)) 'Missing-game cleanup recreated the game folder or retained its canonical OptiShade backups.'
 Check ((HashFile $removedPeer.Receipt) -ceq $removedPeerReceiptHash -and (HashFile $removedPeer.Loader) -ceq $removedPeerLoaderHash) 'Missing-game removal changed another game in the same store.'

 $replaced=Fixture 'missing-game-path-replaced';Remove-Item -LiteralPath $replaced.Game -Recurse -Force;[IO.File]::WriteAllText($replaced.Game,'foreign file')
 ExpectBlocked {RemoveMissingOptiShadeInstallRecord $replaced.Store $replaced.Game} '*game folder exists*' 'Missing-game cleanup discarded backups when the old path was occupied by a file.'
 Check ((HashFile $replaced.Receipt) -ceq $replaced.ReceiptHash -and (HashFile $replaced.Original) -ceq $replaced.OriginalHash) 'Occupied game path changed the ownership receipt or backup.'

 $parentGone=Fixture 'missing-game-parent' $removed.Store;$parentPath=Split-Path $parentGone.Game -Parent;$parkedParent=$parentPath+'-parked'
 Move-Item -LiteralPath $parentPath -Destination $parkedParent
 Check (RemoveMissingOptiShadeInstallRecord $parentGone.Store $parentGone.Game) 'Removing a game whose parent folder was removed did not complete.'
 Check (-not(Test-Path -LiteralPath $parentPath) -and -not(Test-Path -LiteralPath $parentGone.Receipt) -and -not(Test-Path -LiteralPath $parentGone.Folder)) 'Missing-parent cleanup recreated the game path or retained its OptiShade records.'

 $unusedDrive=$null
 foreach($letter in [char[]]'ZYXWVUTSRQPONMLKJIHGFEDCBA'){if(-not(Get-PSDrive -Name ([string]$letter) -PSProvider FileSystem -ErrorAction SilentlyContinue)){$unusedDrive=[string]$letter;break}}
 if(-not $unusedDrive){throw 'Could not reserve an unused drive-letter fixture for offline-game safety.'}
 $unavailableStore=Join-Path $testRoot 'offline-game/OptiShade';$unavailableGame=$unusedDrive+':\NeverMountedOptiShadeFixture\Game';$unavailableReceipt=ManifestPath $unavailableStore $unavailableGame
 [void][IO.Directory]::CreateDirectory((Split-Path $unavailableReceipt -Parent));WriteState ([pscustomobject]@{Game=$unavailableGame;Status='Installed';Version='fixture';OwnedDirectories=@();Files=@()}) $unavailableReceipt
 $unavailableReceiptHash=HashFile $unavailableReceipt
 ExpectBlocked {RemoveMissingOptiShadeInstallRecord $unavailableStore $unavailableGame} '*drive*unavailable*' 'Missing-game cleanup discarded backups when the installation drive was offline.'
 Check ((HashFile $unavailableReceipt) -ceq $unavailableReceiptHash -and -not(Test-Path -LiteralPath (Join-Path $unavailableStore 'RemovedGameRecords'))) 'Offline drive cleanup changed the receipt or staged a removal.'

 $f=Fixture 'malformed';[IO.File]::WriteAllText($f.Receipt,'{ malformed receipt')
 $malformedHash=HashFile $f.Receipt;$script:restoreReceipts=@()
 ExpectBlocked {UninstallFusion $f.Store (Join-Path $testRoot 'installer.exe')} '*Installation receipt could not be read or validated*' 'Uninstall ignored a malformed canonical receipt.'
 Check ($script:restoreReceipts.Count -eq 0 -and (HashFile $f.Receipt) -ceq $malformedHash -and (HashFile $f.Loader) -ceq $f.LoaderHash) 'Malformed receipt was reset, skipped or followed by game mutation.'

 $f=Fixture 'wrong-identity';$other=Fixture 'wrong-identity-other'
 $wrong=ReadOptiShadeState $f.Receipt;$wrong.Game=$other.Game;WriteState $wrong $f.Receipt
 $wrongHash=HashFile $f.Receipt;$script:restoreReceipts=@()
 ExpectBlocked {UninstallFusion $f.Store (Join-Path $testRoot 'installer.exe')} '*canonical game folder identity*' 'Cleanup admitted a canonical directory containing another game identity.'
 Check ($script:restoreReceipts.Count -eq 0 -and (HashFile $f.Receipt) -ceq $wrongHash -and (HashFile $f.Loader) -ceq $f.LoaderHash -and (HashFile $other.Loader) -ceq $other.LoaderHash) 'Mismatched canonical identity mutated either game or rewrote ownership.'

 $f=Fixture 'linked-record';$saved=Join-Path $testRoot 'linked-record-original';Move-Item -LiteralPath $f.Folder -Destination $saved
 $linkType=if([IO.Path]::DirectorySeparatorChar -eq '\'){'Junction'}else{'SymbolicLink'}
 [void](New-Item -ItemType $linkType -Path $f.Folder -Target $saved)
 $script:restoreReceipts=@()
 try{
  ExpectBlocked {UninstallFusion $f.Store (Join-Path $testRoot 'installer.exe')} '*linked*' 'Cleanup followed a linked canonical record directory.'
  Check ($script:restoreReceipts.Count -eq 0 -and (HashFile (Join-Path $saved 'manifest.json')) -ceq $f.ReceiptHash -and (HashFile $f.Loader) -ceq $f.LoaderHash) 'Linked receipt changed game files or discarded its original ownership record.'
 }finally{
  # Windows PowerShell 5.1 can throw NullReferenceException when Remove-Item
  # removes a directory junction. Delete the link itself without traversing
  # its target; the enclosing fixture cleanup owns the target directory.
  [IO.Directory]::Delete($f.Folder,$false)
 }

 $f=Fixture 'changed-loader';[IO.File]::WriteAllText($f.Loader,'changed OptiShade-owned loader')
 UninstallFusion $f.Store (Join-Path $testRoot 'installer.exe')
 $recoveryDirs=@(Get-ChildItem -LiteralPath (GetShaderRecoveryRoot) -Directory -Filter 'RestoreFiles-*' -ErrorAction SilentlyContinue|Where-Object {Test-Path (Join-Path $_.FullName 'dxgi.dll')})
 Check ((HashFile $f.Loader) -ceq $f.OriginalHash -and -not(Test-Path -LiteralPath $f.Store) -and $recoveryDirs.Count -gt 0 -and [IO.File]::ReadAllText((Join-Path $recoveryDirs[-1].FullName 'dxgi.dll')) -ceq 'changed OptiShade-owned loader') 'Uninstall restores the original and archives changed receipt-owned bytes before removing OptiShade.'
 $f=Fixture 'damaged-original';[IO.File]::WriteAllText($f.Original,'damaged original');[IO.File]::WriteAllText($f.Loader,'changed OptiShade-owned loader')
 $null=RestoreFusion $f.Receipt
 $damagedState=ReadOptiShadeState $f.Receipt
 Check ((-not(Test-Path -LiteralPath $f.Loader)) -and $damagedState.Status -eq 'Restored' -and $damagedState.UnrestoredOriginalFiles -contains 'dxgi.dll' -and (HashFile $f.Original) -ne $f.OriginalHash) 'Restore completes with a damaged original backup, removes OptiShade bytes and reports game-launcher verification.'
 $f=Fixture 'damaged-original-uninstall';[IO.File]::WriteAllText($f.Original,'damaged original');[IO.File]::WriteAllText($f.Loader,'changed OptiShade-owned loader')
 $uninstallSummary=RemoveSelectedOptiShadeData $f.Store (Join-Path $testRoot 'installer.exe') '' $true $false $false
 $damagedRecovery=@(Get-ChildItem -LiteralPath (GetShaderRecoveryRoot) -Directory -Filter 'RestoreFiles-*' -ErrorAction SilentlyContinue|Where-Object {(Test-Path (Join-Path $_.FullName 'dxgi.dll')) -and ([IO.File]::ReadAllText((Join-Path $_.FullName 'dxgi.dll')) -ceq 'changed OptiShade-owned loader')})
 Check ((-not(Test-Path -LiteralPath $f.Loader)) -and -not(Test-Path -LiteralPath $f.Store) -and $damagedRecovery.Count -gt 0 -and $uninstallSummary.UnrestoredOriginalFiles -contains 'dxgi.dll' -and $uninstallSummary.RecoveredChangedFiles.Count -gt 0) 'Uninstall completes despite a damaged original backup and preserves changed OptiShade bytes for recovery.'
 $f=Fixture 'archives-only';$archive=SaveArchive $f 'AddonBackups/only-saved-receipt';Remove-Item -LiteralPath $f.Receipt
 $script:restoreReceipts=@()
 ExpectBlocked {UninstallFusion $f.Store (Join-Path $testRoot 'installer.exe')} '*No recorded game installations*' 'A backup-only record was promoted into current ownership.'
 Check ($script:restoreReceipts.Count -eq 0 -and (Test-Path -LiteralPath $archive) -and (HashFile $f.Loader) -ceq $f.LoaderHash) 'Missing canonical ownership caused archive replay or backup removal.'

 $f=Fixture 'running';[IO.File]::WriteAllText((Join-Path $f.Game 'fixture-running'),'running');$script:restoreReceipts=@()
 ExpectBlocked {UninstallFusion $f.Store (Join-Path $testRoot 'installer.exe')} '*running*' 'Canonical cleanup bypassed the closed-game requirement.'
 Check ($script:restoreReceipts.Count -eq 0 -and (HashFile $f.Receipt) -ceq $f.ReceiptHash -and (HashFile $f.Loader) -ceq $f.LoaderHash) 'Running-game preflight changed owned files.'
 "Canonical cleanup: $script:checks assertions passed with real restoration, archive exclusion, preset-only cleanup, offline retention/resumption and unchanged ownership/hash guards."
}finally{if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}}
