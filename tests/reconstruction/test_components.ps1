param([string]$Output)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$env:OPTISHADE_ANTICHEAT_SESSION_ACCEPTED='1'
. "$root/Beta/installer/executable.ps1"
. "$root/Beta/installer/ownership.ps1"
. "$root/Beta/installer/components.ps1"
. "$root/Beta/installer/mfg.ps1"
. "$root/Beta/installer/compatibility.ps1"
# This fixture writes synthetic game folders only. Real games/controllers on
# the developer PC must not change its simulated process state.
function Get-Process {param([string[]]$Name,[string]$ErrorAction) @()}
& {
 function Get-Process {param([string[]]$Name,[string]$ErrorAction) if(-not $Name -or $Name -contains 'FlightSimulator2024' -or $Name -contains 'FlightSimulator'){[pscustomobject]@{Path=$null;ProcessName='FlightSimulator2024'}}else{@()}}
 $blocked=$false;try{AssertClosed 'fixture-only'}catch{$blocked=$_.Exception.Message -like '*Close MSFS*'}
 if(-not $blocked){throw 'Real AssertClosed must refuse a simulated running MSFS process'}
}
& {
 function Get-Process {param([string[]]$Name,[string]$ErrorAction) [pscustomobject]@{Path=$null;ProcessName='OptiMFG_LiveCtl'}}
 $blocked=$false;try{AssertClosed 'fixture-only'}catch{$blocked=$_.Exception.Message -like '*Exit OptiMFG*' -and $_.Exception.Message -like '*No files have been changed*'}
 if(-not $blocked){throw 'AssertClosed must catch a running elevated OptiMFG controller even when its path is unavailable'}
}
function WriteTestGameExe([string]$File,[string]$Import='d3d11.dll'){
 $bytes=New-Object byte[] 1024;$memory=[IO.MemoryStream]::new($bytes,$true);$writer=[IO.BinaryWriter]::new($memory)
 $writer.Write([uint16]0x5a4d);$memory.Position=0x3c;$writer.Write([uint32]0x80)
 $memory.Position=0x80;$writer.Write([uint32]0x4550);$writer.Write([uint16]0x8664);$writer.Write([uint16]1)
 $memory.Position=0x94;$writer.Write([uint16]240);$writer.Write([uint16]2);$writer.Write([uint16]0x20b)
 $memory.Position=0x98+60;$writer.Write([uint32]512);$memory.Position=0x98+108;$writer.Write([uint32]16)
 $memory.Position=0x98+120;$writer.Write([uint32]0x1000);$writer.Write([uint32]40)
 $memory.Position=0x98+240+8;$writer.Write([uint32]512);$writer.Write([uint32]0x1000);$writer.Write([uint32]512);$writer.Write([uint32]512)
 $memory.Position=512+12;$writer.Write([uint32]0x1040);$memory.Position=576;$writer.Write([Text.Encoding]::ASCII.GetBytes($Import+"`0"));$writer.Dispose()
 [IO.File]::WriteAllBytes($File,$bytes)
}
if(-not $Output){$Output=Join-Path $root ('test-results/components-'+[guid]::NewGuid().ToString('N'))}
function GetShaderRecoveryRoot { Join-Path $Output 'recovery' }
$game=Join-Path $Output 'game';$payload=Join-Path $Output 'payload';$state=Join-Path $Output 'state'
New-Item -ItemType Directory -Path $game,$payload,$state -Force|Out-Null
$mp=Join-Path $state 'manifest.json'
[IO.File]::WriteAllText((Join-Path $game 'FlightSimulator2024.exe'),'fixture only')
[IO.File]::WriteAllText((Join-Path $game 'OptiScaler.ini'),"[FrameGen]`nExternal=false`nEnabled=auto`n")
$addon='glass-cockpit-dlss-fix.addon64';[IO.File]::WriteAllText((Join-Path $payload $addon),'verified fixture addon')
ConvertTo-Json -InputObject @(@{Path=$addon;Hash=(HashFile (Join-Path $payload $addon))}) | Set-Content (Join-Path $payload 'files.json') -Encoding UTF8
WriteState @{Status='Installed';Game=$game;Files=@();Components=@();IncludeEffects=$false} $mp
function Check($Condition,$Label){if(-not $Condition){throw $Label};Write-Output ('PASS: '+$Label)}
$card=GetNeuralAddonCardState $true $true 'Missing'
Check ($card.Action -eq 'Install model' -and $card.Text -like '*cannot run*' -and $card.Available) 'selected neural component exposes missing model and direct recovery action'
$card=GetNeuralAddonCardState $true $true 'Verified file'
Check ($card.Text -like '*game test required*' -and $card.Foreground -eq '#55DCA5') 'verified model status does not claim rendered output'
$card=GetNeuralAddonCardState $true $true 'Unsupported on this hardware'
Check ($card.Text -like '*unavailable on detected hardware*' -and -not $card.Available) 'unknown unsupported hardware remains blocked without claiming a blanket RTX 30-series exclusion'
$card=GetNeuralAddonCardState $false $true 'Missing'
Check ($card.Text -eq 'Install core first' -and -not $card.Available) 'neural recovery remains unavailable before core installation'
# A previous core install can record a pre-existing NR model as a retained
# conflict (empty Hash, PreviousHash=original bytes). Installing Neural must
# accept those unchanged bytes while continuing to reject unrecognized edits.
$retainedNrGame=Join-Path $Output 'retained-nr-original-game';$retainedNrState=Join-Path $Output 'retained-nr-original-state';New-Item -ItemType Directory -Path $retainedNrGame,$retainedNrState -Force|Out-Null
$retainedNrPath=Join-Path $retainedNrGame 'nvngx_dlssnr.dll';[IO.File]::WriteAllText($retainedNrPath,'known retained NVIDIA model fixture')
$retainedNrHash=HashFile $retainedNrPath;$retainedNrReceipt=Join-Path $retainedNrState 'manifest.json'
WriteState @{Status='Installed';Game=$retainedNrGame;Architecture='x64';Files=@(@{Path='nvngx_dlssnr.dll';Hash='';PreviousHash=$retainedNrHash;Backup='Backups/original-nr-model';Mutable=$false;Retained=$true});Components=@()} $retainedNrReceipt
$retainedNrInstallWorked=$true;try{InvokeAddonTransaction $retainedNrReceipt Neural { }}catch{$retainedNrInstallWorked=$false;Write-Output ('Unexpected retained-NR install failure: '+$_.Exception.Message)}
Check ($retainedNrInstallWorked) 'unchanged retained NR model bytes no longer block Neural component installation'
$editedNrGame=Join-Path $Output 'edited-nr-original-game';$editedNrState=Join-Path $Output 'edited-nr-original-state';New-Item -ItemType Directory -Path $editedNrGame,$editedNrState -Force|Out-Null
$editedNrPath=Join-Path $editedNrGame 'nvngx_dlssnr.dll';[IO.File]::WriteAllText($editedNrPath,'unrecognized changed model fixture')
$editedNrReceipt=Join-Path $editedNrState 'manifest.json';WriteState @{Status='Installed';Game=$editedNrGame;Architecture='x64';Files=@(@{Path='nvngx_dlssnr.dll';Hash='';PreviousHash='PREVIOUS-KNOWN-HASH';Backup='Backups/original-nr-model';Mutable=$false;Retained=$true});Components=@()} $editedNrReceipt
$editedNrInstallBlocked=$false;try{InvokeAddonTransaction $editedNrReceipt Neural { }}catch{$editedNrInstallBlocked=$_.Exception.Message -like 'Changed component file requires review: nvngx_dlssnr.dll*'}
Check ($editedNrInstallBlocked) 'changed retained NR model bytes still require review'
InstallOptiShadeAddon $mp $payload Cockpit $null {}
$m=ReadOptiShadeState $mp
Check ($m.Components -contains 'Cockpit' -and $m.Files.Count -eq 1) 'explicit addon installation records ownership'
Check ((HashFile (Join-Path $game $addon)) -eq (HashFile (Join-Path $payload $addon))) 'installed addon bytes verified'
[IO.File]::WriteAllText((Join-Path $game $addon),'edited by user')
$blocked=$false;try{RemoveOptiShadeAddon $mp Cockpit}catch{$blocked=$true}
Check ($blocked -and [IO.File]::ReadAllText((Join-Path $game $addon)) -eq 'edited by user') 'modified addon removal refused before mutation'
Copy-Item (Join-Path $payload $addon) (Join-Path $game $addon) -Force
RemoveOptiShadeAddon $mp Cockpit
Check (-not(Test-Path (Join-Path $game $addon)) -and (ReadOptiShadeState $mp).Components -notcontains 'Cockpit') 'remove clears owned addon and selection'
$original=[IO.File]::ReadAllText($mp)
$failed=$false;try{InvokeAddonTransaction $mp Cockpit {[IO.File]::WriteAllText((Join-Path $game $addon),'partial');throw 'injected failure'}.GetNewClosure()}catch{$failed=$true}
Check ($failed -and -not(Test-Path (Join-Path $game $addon)) -and [IO.File]::ReadAllText($mp) -eq $original) 'failed operation restores files and manifest'
# Removal restores the real original and releases ownership rather than claiming it again.
[IO.File]::WriteAllText((Join-Path $state 'original'),'third party original')
Copy-Item (Join-Path $payload $addon) (Join-Path $game $addon)
WriteState @{Status='Installed';Game=$game;Files=@(@{Path=$addon;SourcePath=$addon;Hash=(HashFile (Join-Path $game $addon));PreviousHash=(HashFile (Join-Path $state 'original'));Backup='original';Mutable=$false});Components=@('Cockpit')} $mp
RemoveOptiShadeAddon $mp Cockpit
Check ([IO.File]::ReadAllText((Join-Path $game $addon)) -eq 'third party original' -and (ReadOptiShadeState $mp).Files.Count -eq 0) 'original restored without adopting foreign file'
# New installs/repair must select only current family-appropriate backend paths.
$selectionFixture=[pscustomobject]@{Architecture='x64';OptiMfgAdapter=[pscustomobject]@{Family=50}}
$mfgCatalog=@('OptiShadeData/OptiMFG/Runtime/OptiMFG_Live.exe','OptiShadeData/OptiMFG/Runtime/backends/headless/version.dll','OptiShadeData/OptiMFG/Runtime/backends/MFGUnlocker-1.7.0/MFGUnlocker.dll','OptiShadeData/OptiMFG/Runtime/backends/headless/unexpected.dll')|ForEach-Object {[pscustomobject]@{Path=$_}}
$selected=@(GetOptiShadeAddonPayloadEntries $mfgCatalog $selectionFixture OptiMfg)
Check ($selected.Count -eq 1 -and $selected[0].Path -like '*OptiMFG_Live.exe') 'RTX 50 install/update selection excludes all dormant older-RTX backend files'
$selected=@(GetOptiShadeAddonPayloadEntries $mfgCatalog $selectionFixture OptiMfg 40)
Check ($selected.Count -eq 2 -and $selected.Path -contains 'OptiShadeData/OptiMFG/Runtime/backends/headless/version.dll') 'explicit RTX 40 selection retains required loader and rejects retired or unexpected backend paths'
Check (-not(TestOptiShadeCurrentMfgPayload 'version.dll' $null) -and -not(TestOptiShadeCurrentMfgPayload 'RTXMFG-Universal.json' $null) -and (TestOptiShadeCurrentMfgPayload 'winmm.dll' $null)) 'core payload refuses retired root provider while preserving source for the selected core loader alias'
$optiMfgGame=Join-Path $Output 'optimfg-optional-game';$optiMfgState=Join-Path $Output 'optimfg-optional-state';$optiMfgPayload=Join-Path $Output 'optimfg-optional-payload';$optiMfgCatalog=@()
New-Item -ItemType Directory -Path $optiMfgGame,$optiMfgState,(Join-Path $optiMfgPayload 'OptiShadeData/OptiMFG/Runtime') -Force|Out-Null
[IO.File]::WriteAllText((Join-Path $optiMfgGame 'FlightSimulator2024.exe'),'fixture only')
foreach($relative in @('OptiShadeData/OptiMFG/Runtime/OptiMFG_Live.exe','OptiShadeData/OptiMFG/Runtime/OptiMFG_LiveHelper_v4.dll','OptiShadeData/OptiMFG/Runtime/OptiMFG_LiveCtl.exe','OptiShadeData/OptiMFG/Runtime/OptiMFG_Controller.exe')){$path=Join-Path $optiMfgPayload $relative;[IO.File]::WriteAllText($path,'fixture controller payload');$optiMfgCatalog+=@{Path=$relative;Hash=(HashFile $path)}}
ConvertTo-Json -InputObject $optiMfgCatalog | Set-Content (Join-Path $optiMfgPayload 'files.json') -Encoding UTF8
$optiMfgReceipt=Join-Path $optiMfgState 'manifest.json';WriteState @{Status='Installed';Game=$optiMfgGame;LaunchExe=(Join-Path $optiMfgGame 'FlightSimulator2024.exe');Architecture='x64';Files=@();Components=@()} $optiMfgReceipt
$optiGpu=[pscustomobject]@{Complete=$true;PreferredRenderingLuid='fixture';Adapters=@([pscustomobject]@{VendorId=0x10DE;DeviceId=1;SubSystemId=7;Software=$false;ComputeCapabilityKnown=$true;Family=50;Luid='fixture';Name='fixture RTX'})}
InstallOptiShadeAddon $optiMfgReceipt $optiMfgPayload 'OptiMfg' $optiGpu {}
$optiMfgInstalled=ReadOptiShadeState $optiMfgReceipt
Check (-not(Test-Path (Join-Path $optiMfgGame 'version.dll')) -and -not(Test-Path (Join-Path $optiMfgGame 'OptiMFGTest-backend.json')) -and $optiMfgInstalled.Files.Count -eq 4 -and 'OptiMfg' -in $optiMfgInstalled.Components) 'OptiMFG controller installs independently without owning native MSFS MFG provider files'
Check ((GetOptiShadeAddonId 'version.dll') -eq 'Core' -and (GetOptiShadeAddonId 'RTX40MFG-UI.ini') -eq 'Core' -and (GetOptiShadeAddonId 'RTXMFG-Universal.json') -eq 'Core') 'native MFG provider and settings belong to core rather than optional OptiMFG'
# Upgrade the existing fixed-path controller; remove only the recognised old opt-out.
$controllerRelative='OptiShadeData/OptiMFG/Runtime/OptiMFG_Live.exe'
$oldControllerHash=HashFile (Join-Path $optiMfgGame $controllerRelative)
[IO.File]::WriteAllText((Join-Path $optiMfgPayload $controllerRelative),'fixture controller upgrade')
@($optiMfgCatalog|Where-Object Path -eq $controllerRelative)[0].Hash=HashFile (Join-Path $optiMfgPayload $controllerRelative)
ConvertTo-Json -InputObject $optiMfgCatalog | Set-Content (Join-Path $optiMfgPayload 'files.json') -Encoding UTF8
$marker=Join-Path $optiMfgGame 'OptiShadeData/OptiMFG/start-with-game.disabled'
[IO.File]::WriteAllText($marker,'Automatic game-triggered OptiMFG start disabled by the user.')
Check (TestOptiMfgComponentNeedsRepair $optiMfgInstalled) 'old startup opt-out surfaces an OptiMFG update'
InstallOptiShadeAddon $optiMfgReceipt $optiMfgPayload 'OptiMfg' $optiGpu {}
Check (-not(Test-Path $marker) -and (HashFile (Join-Path $optiMfgGame $controllerRelative)) -ne $oldControllerHash -and @(Get-ChildItem $optiMfgGame -Recurse -File -Filter OptiMFG_Live.exe).Count -eq 1) 'update replaces controller in place, removes old opt-out and creates no second controller'
InstallOptiShadeAddon $optiMfgReceipt $optiMfgPayload 'OptiMfg' $optiGpu {}
Check (@(Get-ChildItem $optiMfgGame -Recurse -File -Filter OptiMFG_Live.exe).Count -eq 1) 'repeated component update keeps one installed controller'
[IO.File]::WriteAllText($marker,'unknown user file')
$beforeReceipt=[IO.File]::ReadAllBytes($optiMfgReceipt);$beforeHash=HashFile (Join-Path $optiMfgGame $controllerRelative)
$blocked=$false;try{InstallOptiShadeAddon $optiMfgReceipt $optiMfgPayload 'OptiMfg' $optiGpu {}}catch{$blocked=$_.Exception.Message -like '*not recognised*'}
Check ($blocked -and [IO.File]::ReadAllText($marker) -ceq 'unknown user file' -and (HashFile (Join-Path $optiMfgGame $controllerRelative)) -eq $beforeHash -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($optiMfgReceipt)) -ceq [Convert]::ToBase64String($beforeReceipt)) 'unknown startup file is preserved and failed update rolls back receipt/controller'
# This is the fixture's exact file; restore the recognised preference for cleanup.
[IO.File]::WriteAllText($marker,'Automatic game-triggered OptiMFG start disabled by the user.')
InstallOptiShadeAddon $optiMfgReceipt $optiMfgPayload 'OptiMfg' $optiGpu {}
& {
 function Get-Process {param($Name,$ErrorAction) [pscustomobject]@{Id=123;ProcessName='OptiMFG_Live'}}
 $blocked=$false;try{AssertOptiMfgControllerClosed}catch{$blocked=$_.Exception.Message -like '*older standalone test copy*'}
 Check $blocked 'running standalone controller blocks component update with explicit exit guidance'
}
RemoveOptiShadeAddon $optiMfgReceipt 'OptiMfg'
Check (@(Get-ChildItem (Join-Path $optiMfgGame 'OptiShadeData/OptiMFG') -File -Recurse -ErrorAction SilentlyContinue).Count -eq 0 -and -not(Test-Path (Join-Path $optiMfgGame 'version.dll'))) 'Removing optional OptiMFG leaves core-managed native MFG support untouched'
# RTX 50 migration removes only the exact receipt-owned previous provider.
$legacy=Join-Path $root 'Beta/installer/OptiMFGRuntime/backends/MFGUnlocker-1.7.0/MFGUnlocker.dll'
$proxy=Join-Path $optiMfgGame 'version.dll';Copy-Item $legacy $proxy
$legacyHash=HashFile $proxy
$legacyState=ReadOptiShadeState $optiMfgReceipt
$legacyState.Files=@([pscustomobject]@{Path='version.dll';Hash=$legacyHash;Backup='';PreviousHash='';Mutable=$false;Retained=$false})
WriteState $legacyState $optiMfgReceipt
$priorReceipt=[IO.File]::ReadAllText($optiMfgReceipt);$failed=$false
try{InvokeAddonTransaction $optiMfgReceipt OptiMfg {InstallOptiMfgHeadless $optiMfgReceipt $optiMfgPayload 50;throw 'migration fixture failure'}}catch{$failed=$true}
Check ($failed -and (HashFile $proxy) -ceq $legacyHash -and [IO.File]::ReadAllText($optiMfgReceipt) -ceq $priorReceipt) 'failed RTX 50 migration restores exact loader and receipt'
InstallOptiShadeAddon $optiMfgReceipt $optiMfgPayload OptiMfg $optiGpu {}
Check (-not(Test-Path $proxy) -and -not(TestOptiMfgComponentNeedsRepair (ReadOptiShadeState $optiMfgReceipt))) 'RTX 50 migrates a verified receipt-owned old provider to native control'
RemoveOptiShadeAddon $optiMfgReceipt OptiMfg
Copy-Item $legacy $proxy
$blocked=$false;try{InstallOptiShadeAddon $optiMfgReceipt $optiMfgPayload OptiMfg $optiGpu {}}catch{$blocked=$_.Exception.Message -like '*unowned or changed*'}
Check (-not $blocked -and (HashFile $proxy) -ceq $legacyHash) 'RTX 50 native route preserves an unrelated unowned version.dll without blocking OptiMFG'
[IO.File]::Delete($proxy)
# Exercise the real menu-free payload and component ownership without a game process.
$optiGpu.Adapters[0].Family=40
$selection=ReadOptiShadeState $optiMfgReceipt;SetOptiMfgAdapterSelection $selection $optiGpu 'fixture';WriteState $selection $optiMfgReceipt
$backendPayload=Join-Path $optiMfgPayload 'OptiShadeData/OptiMFG/Runtime/backends/headless'
New-Item -ItemType Directory $backendPayload -Force|Out-Null
foreach($name in (GetOptiMfgHeadlessHashes).Keys){
 Copy-Item (Join-Path $root ('Beta/installer/OptiMFGRuntime/backends/headless/'+$name)) (Join-Path $backendPayload $name)
 $optiMfgCatalog+=@{Path=('OptiShadeData/OptiMFG/Runtime/backends/headless/'+$name);Hash=(HashFile (Join-Path $backendPayload $name))}
}
ConvertTo-Json -InputObject $optiMfgCatalog | Set-Content (Join-Path $optiMfgPayload 'files.json') -Encoding UTF8
InstallOptiShadeAddon $optiMfgReceipt $optiMfgPayload 'OptiMfg' $optiGpu {}
Check (Test-OptiMfgBackendMarker $optiMfgGame) 'RTX 40 component installs the pinned menu-free route marker and payload'
Check (@((ReadOptiShadeState $optiMfgReceipt).Files|Where-Object {$_.Path -eq 'version.dll' -and $_.Component -eq 'OptiMfg'}).Count -eq 1) 'root backend loader belongs to the optional component'
$configPath=Join-Path $optiMfgGame 'RTX40MFG-Universal.json'
$configText=[IO.File]::ReadAllText($configPath).Replace('"multiplier":2','"multiplier":4');[IO.File]::WriteAllText($configPath,$configText)
InstallOptiShadeAddon $optiMfgReceipt $optiMfgPayload 'OptiMfg' $optiGpu {}
Check ([IO.File]::ReadAllText($configPath) -eq $configText) 'component repair preserves live-control settings'
RemoveOptiShadeAddon $optiMfgReceipt 'OptiMfg'
Check (-not(Test-Path (Join-Path $optiMfgGame 'version.dll')) -and -not(Test-Path (Join-Path $optiMfgGame 'version.ini')) -and (Test-Path $configPath)) 'component removal removes its loader and preserves user settings'
$foreign=Join-Path $optiMfgGame 'version.dll';[IO.File]::WriteAllText($foreign,'foreign loader')
$beforeReceipt=[IO.File]::ReadAllText($optiMfgReceipt);$blocked=$false
try{InstallOptiShadeAddon $optiMfgReceipt $optiMfgPayload 'OptiMfg' $optiGpu {}}catch{$blocked=$true}
Check ($blocked -and [IO.File]::ReadAllText($foreign) -eq 'foreign loader' -and [IO.File]::ReadAllText($optiMfgReceipt) -eq $beforeReceipt -and -not(Test-Path (Join-Path $optiMfgGame 'OptiMFGTest-backend.json'))) 'foreign loader refusal rolls back component payload and receipt'
# Consent is bound to the exact unowned DLL hash. Approval replaces it only
# after InvokeAddonTransaction has created a verified recovery copy; uninstall
# must restore the user's original bytes.
$foreignHash=HashFile $foreign;$consentRequired=$false
try{InstallOptiShadeAddon $optiMfgReceipt $optiMfgPayload 'OptiMfg' $optiGpu {} -ApprovedForeignVersionDllHash ''}catch{$consentRequired=$_.Exception.GetBaseException().Message -ceq ('OPTIMFG_FOREIGN_VERSION_DLL_CONSENT_REQUIRED:'+$foreignHash)}
Check ($consentRequired -and (HashFile $foreign) -ceq $foreignHash -and [IO.File]::ReadAllText($optiMfgReceipt) -ceq $beforeReceipt) 'foreign loader consent request leaves file and receipt untouched'
InstallOptiShadeAddon $optiMfgReceipt $optiMfgPayload 'OptiMfg' $optiGpu {} -ApprovedForeignVersionDllHash $foreignHash
$approvedState=ReadOptiShadeState $optiMfgReceipt;$approvedEntry=@($approvedState.Files|Where-Object {$_.Path -eq 'version.dll' -and $_.Component -eq 'OptiMfg'})
Check ($approvedEntry.Count -eq 1 -and $approvedEntry[0].PreviousHash -ceq $foreignHash -and (HashFile (Join-Path (Split-Path $optiMfgReceipt) $approvedEntry[0].Backup)) -ceq $foreignHash -and (HashFile $foreign) -ceq (GetOptiMfgHeadlessHashes)['version.dll']) 'consented version.dll replacement has verified original recovery bytes'
RemoveOptiShadeAddon $optiMfgReceipt 'OptiMfg'
Check ((HashFile $foreign) -ceq $foreignHash) 'OptiMFG uninstall restores the exact consented foreign version.dll'
# Exact external-test loader reuse must neither overwrite nor adopt that loader.
[IO.File]::Delete($foreign)
Copy-Item (Join-Path $backendPayload 'version.dll') $foreign
$sharedHash=HashFile $foreign
InstallOptiShadeAddon $optiMfgReceipt $optiMfgPayload 'OptiMfg' $optiGpu {}
$repaired=ReadOptiShadeState $optiMfgReceipt
Check (-not(TestOptiMfgComponentNeedsRepair $repaired)) 'completed preparation clears the backend repair state'
Check (@($repaired.Files|Where-Object Path -eq 'version.dll').Count -eq 0) 'exact pre-existing loader remains unowned'
[IO.File]::Delete((Join-Path $optiMfgGame 'OptiMFGTest-backend.json'))
Check (TestOptiMfgComponentNeedsRepair $repaired) 'missing root marker requires repair despite matching controller payload'
InstallOptiShadeAddon $optiMfgReceipt $optiMfgPayload 'OptiMfg' $optiGpu {}
RemoveOptiShadeAddon $optiMfgReceipt 'OptiMfg'
Check ((HashFile $foreign) -ceq $sharedHash) 'removal preserves the external tester loader exactly'
# Two measured adapters require an explicit identity, never a name-only guess.
$a=[pscustomobject]@{VendorId=0x10DE;DeviceId=1;SubSystemId=7;Software=$false;ComputeCapabilityKnown=$true;Family=40;Luid='101';Name='RTX fixture'}
$b=[pscustomobject]@{VendorId=0x10DE;DeviceId=2;SubSystemId=7;Software=$false;ComputeCapabilityKnown=$true;Family=50;Luid='102';Name='RTX fixture'}
$multi=[pscustomobject]@{Complete=$true;Adapters=@($a,$b)};$choice=[pscustomobject]@{}
$blocked=$false;try{GetOptiMfgComponentFamily $multi $choice}catch{$blocked=$_.Exception.Message -like '*OPTIMFG_GPU_SELECTION_REQUIRED:*'}
Check $blocked 'ambiguous GPU result is actionable by the component picker'
SetOptiMfgAdapterSelection $choice $multi '102'
Check ((GetOptiMfgComponentFamily $multi $choice) -eq 50) 'saved measured choice selects native RTX 50 preparation'
$b.DeviceId=3
$blocked=$false;try{GetOptiMfgComponentFamily $multi $choice}catch{$blocked=$true}
Check $blocked 'changed GPU identity invalidates the saved selection'
Check ((GetOptiShadeAddonId 'OptiShadeData/Engine/Routes/OptiShadeMSFS2024.dll') -eq 'Core') 'simulator route remains required core'
Check ((GetOptiShadeAddonId 'OptiShadeData/Shaders/OptiShadeTaa/OptiShade_TAA_Guides.fx') -eq 'Effects') 'retired loose guide shader remains ordinary effects data'
Check (@(GetOptiShadeAddonSelection $null).Count -eq 0) 'fresh installation selects no addons'
$legacy=[pscustomobject]@{Files=@([pscustomobject]@{Path=$addon;Hash='old'});IncludeEffects=$true;OptionalDlss=$true;SourceMfg=$true}
Check (@(GetOptiShadeAddonSelection $legacy).Count -eq 4) 'legacy addon choices retained on migration'
$coreGame=Join-Path $Output 'core-game';New-Item -ItemType Directory $coreGame -Force|Out-Null
$coreExe=Join-Path $coreGame 'FlightSimulator2024.exe';WriteTestGameExe $coreExe
$catalog=@()
foreach($relative in @('winmm.dll','version.dll','RTXMFG-Universal.json','RTX40MFG-UI.ini','ReShade32.dll','ReShade.ini','OptiScaler.ini','OptiShadeData/Presets/My look.ini','OptiShadeData/Licenses/x86.txt','OptiShadeData/Engine/Routes/OptiShadeMSFS2024.dll','OptiShadeData/Engine/Routes/OptiShadeXPlane12.dll','OptiShadeData/Engine/Routes/OptiShadeGeneric.dll','OptiShadeData/Engine/amd_fidelityfx_framegeneration_dx12.dll','OptiShadeData/Engine/libxess.dll','OptiShadeData/Engine/nvngx_dlss.dll','OptiShadeData/Shaders/LegacyNR/DLSS5_Feed.fx','OptiShadeLegacyNR.addon32','nvngx_dlssnr.dll','host64/dlss5-feed-host64.exe','host64/dxgi.dll','host64/winmm.dll','host64/nvngx.dll_dlssnr.dll','host64/OptiScaler.ini','host64/ReShade.ini','glass-cockpit-dlss-fix.addon64','OptiShadeData/Shaders/Custom/look.fx','OptiShadeData/Shaders/Custom/x86.fx','OptiShadeData/MFG/OptiShadeMFG.dll','OptiScaler/nvfp4/hybrid/weights.bin','OptiShadeData/Shaders/OptiShadeTaa/guide.fx')){
 $dest=OwnedPath $payload $relative;New-Item -ItemType Directory (Split-Path $dest) -Force|Out-Null
  $content=if($relative -eq 'ReShade.ini'){"[GENERAL]`nPresetPath=.\OptiShadeData\Presets\My look.ini`n"}elseif($relative -eq 'OptiShadeData/Presets/My look.ini'){"Techniques=Original@Base.fx`nTechniqueSorting=Original@Base.fx`n"}else{'fixture payload '+$relative}
  [IO.File]::WriteAllText($dest,$content);$catalog+=@{Path=$relative;Hash=(HashFile $dest)}
}
ConvertTo-Json -InputObject $catalog | Set-Content (Join-Path $payload 'files.json') -Encoding UTF8
$coreManifest=@(InstallFusion $coreGame $payload (Join-Path $Output 'core-state') (Join-Path $Output 'fixture-installer.exe') -Executable $coreExe)[-1]
$core=ReadOptiShadeState $coreManifest
Check (@($core.Files|Where-Object {(GetOptiShadeAddonId $_.Path) -ne 'Core'}).Count -eq 0) 'real fresh InstallFusion excludes optional payloads'
Check (-not(Test-Path (Join-Path $coreGame 'version.dll')) -and (@($core.Files|Where-Object {$_.Path -eq 'version.dll'}).Count -eq 0)) 'MSFS core refuses a retired root provider even when supplied by the incoming catalogue'
[IO.File]::WriteAllText((Join-Path $coreGame 'version.dll.disabled'),'tester disabled original')
Check ((Test-Path (Join-Path $coreGame 'OptiShadeData/Engine/Routes/OptiShadeMSFS2024.dll')) -and -not(Test-Path (Join-Path $coreGame 'OptiShadeData/Engine/Routes/OptiShadeXPlane12.dll'))) 'core installs only the selected simulator adapter'
InstallOptiShadeAddon $coreManifest $payload Cockpit $null {}
$null=InstallFusion $coreGame $payload (Join-Path $Output 'core-state') (Join-Path $Output 'fixture-installer.exe') 'winmm.dll' @(FindFusionConflicts $coreGame) -ReplaceExisting $true -PreserveConfiguration $true
Check ((Test-Path (Join-Path $coreGame $addon)) -and (ReadOptiShadeState $coreManifest).Components -contains 'Cockpit') 'core repair preserves selected addon'
RemoveOptiShadeAddon $coreManifest Cockpit
$null=InstallFusion $coreGame $payload (Join-Path $Output 'core-state') (Join-Path $Output 'fixture-installer.exe') 'winmm.dll' @(FindFusionConflicts $coreGame) -ReplaceExisting $true -PreserveConfiguration $true
Check (-not(Test-Path (Join-Path $coreGame $addon))) 'repair does not silently reinstall removed addon'
Check (-not(Test-Path (Join-Path $coreGame 'version.dll')) -and [IO.File]::ReadAllText((Join-Path $coreGame 'version.dll.disabled')) -ceq 'tester disabled original') 'repeated core repairs cannot resurrect a retired provider or reactivate a manually disabled DLL'
$x86Game=Join-Path $Output 'x86-game';$x86State=Join-Path $Output 'x86-state';New-Item -ItemType Directory -Path $x86Game,$x86State -Force|Out-Null
$x86Exe=Join-Path $x86Game 'gta_sa.exe';$bytes32=New-Object byte[] 1024;$memory32=[IO.MemoryStream]::new($bytes32,$true);$w32=[IO.BinaryWriter]::new($memory32)
$w32.Write([uint16]0x5a4d);$memory32.Position=0x3c;$w32.Write([uint32]0x80)
$memory32.Position=0x80;$w32.Write([uint32]0x4550);$w32.Write([uint16]0x14c);$w32.Write([uint16]1)
$memory32.Position=0x94;$w32.Write([uint16]224);$w32.Write([uint16]2);$w32.Write([uint16]0x10b)
$memory32.Position=0x98+60;$w32.Write([uint32]512);$memory32.Position=0x98+92;$w32.Write([uint32]16)
$memory32.Position=0x98+104;$w32.Write([uint32]0x1000);$w32.Write([uint32]40)
$memory32.Position=0x98+224+8;$w32.Write([uint32]512);$w32.Write([uint32]0x1000);$w32.Write([uint32]512);$w32.Write([uint32]512)
$memory32.Position=512+12;$w32.Write([uint32]0x1040);$memory32.Position=576;$w32.Write([Text.Encoding]::ASCII.GetBytes("d3d9.dll`0"));$w32.Dispose();[IO.File]::WriteAllBytes($x86Exe,$bytes32)
$x86Manifest=@(InstallFusion $x86Game $payload $x86State (Join-Path $Output 'fixture-installer.exe') 'd3d9.dll' -Executable $x86Exe)[-1]
$x86Record=ReadOptiShadeState $x86Manifest
Check ($x86Record.Architecture -eq 'x86' -and $x86Record.Runtime -eq 'ReShade32 effects-only' -and (Test-Path (Join-Path $x86Game 'd3d9.dll'))) '32-bit DirectX 9 install deploys the architecture-matched ReShade entry point'
Check (-not(Test-Path (Join-Path $x86Game 'winmm.dll')) -and -not(Test-Path (Join-Path $x86Game 'OptiScaler.ini')) -and -not(Test-Path (Join-Path $x86Game 'OptiShadeData/Engine/Routes/OptiShadeGeneric.dll'))) '32-bit install cannot receive x64 OptiScaler or simulator adapter files'
InstallOptiShadeAddon $x86Manifest $payload Effects $null {} -SkipAllFx
$x86Record=ReadOptiShadeState $x86Manifest
Check ('Effects' -in $x86Record.Components -and (Test-Path (Join-Path $x86Game 'OptiShadeData/Shaders/Custom/x86.fx'))) '32-bit game can install the ReShade image-effects component'
Check ((GetOptiShadeInstalledLoaderPath $x86Record) -eq 'd3d9.dll') '32-bit install receipt resolves its ReShade loader for repair'
$x86Blocked=$false;try{InstallOptiShadeAddon $x86Manifest $payload Neural $null {}}catch{$x86Blocked=$_.Exception.Message -match 'native D3D9'}
Check $x86Blocked 'native 32-bit D3D9 cannot install the Legacy NR bridge without a configured wrapper and DXGI hook'
RestoreFusion $x86Manifest
Check ((-not(Test-Path (Join-Path $x86Game 'd3d9.dll'))) -and (Test-Path $x86Exe)) '32-bit Restore removes the ReShade hook and keeps the game executable'
$x86Modern=Join-Path $Output 'x86-modern-game';$x86ModernState=Join-Path $Output 'x86-modern-state';New-Item -ItemType Directory -Path $x86Modern,$x86ModernState -Force|Out-Null
$x86ModernExe=Join-Path $x86Modern 'fixture32.exe';$modernBytes=New-Object byte[] 1024;$modernMemory=[IO.MemoryStream]::new($modernBytes,$true);$modernWriter=[IO.BinaryWriter]::new($modernMemory)
$modernWriter.Write([uint16]0x5a4d);$modernMemory.Position=0x3c;$modernWriter.Write([uint32]0x80);$modernMemory.Position=0x80;$modernWriter.Write([uint32]0x4550);$modernWriter.Write([uint16]0x14c);$modernWriter.Write([uint16]1);$modernMemory.Position=0x94;$modernWriter.Write([uint16]224);$modernWriter.Write([uint16]2);$modernWriter.Write([uint16]0x10b);$modernMemory.Position=0x98+60;$modernWriter.Write([uint32]512);$modernMemory.Position=0x98+92;$modernWriter.Write([uint32]16);$modernMemory.Position=0x98+104;$modernWriter.Write([uint32]0x1000);$modernWriter.Write([uint32]40);$modernMemory.Position=0x98+224+8;$modernWriter.Write([uint32]512);$modernWriter.Write([uint32]0x1000);$modernWriter.Write([uint32]512);$modernWriter.Write([uint32]512);$modernMemory.Position=512+12;$modernWriter.Write([uint32]0x1040);$modernMemory.Position=576;$modernWriter.Write([Text.Encoding]::ASCII.GetBytes("d3d11.dll`0"));$modernWriter.Dispose();[IO.File]::WriteAllBytes($x86ModernExe,$modernBytes)
$x86ModernManifest=@(InstallFusion $x86Modern $payload $x86ModernState (Join-Path $Output 'fixture-installer.exe') 'dxgi.dll' -Executable $x86ModernExe)[-1]
function EnsureNeuralRuntime([string]$ManifestPath,$Gpu,[scriptblock]$Progress){return}
function InstallNvidia([string]$Game,[scriptblock]$Progress,[string]$DlssRuntimeProfile='nvidia-310.9.16'){if($DlssRuntimeProfile -cin @('nvidia-310.9.1','nvidia-310.7.0')){$DlssRuntimeProfile='nvidia-310.9.16'};$script:lastDlssRuntimeProfile=$DlssRuntimeProfile;return [pscustomobject]@{DlssRuntimeProfile=$DlssRuntimeProfile}}
 $x86Preset=Join-Path $x86Modern 'OptiShadeData/Presets/My look.ini';$x86PresetBefore=[IO.File]::ReadAllText($x86Preset)
InstallOptiShadeAddon $x86ModernManifest $payload Neural ([pscustomobject]@{Names='NVIDIA GeForce RTX 5090'}) {} -DlssRuntimeProfile 'nvidia-310.7.0'
$x86Bridge=ReadOptiShadeState $x86ModernManifest;$x86PresetText=[IO.File]::ReadAllText($x86Preset)
Check ($x86Bridge.Architecture -eq 'x86' -and $x86Bridge.Runtime -eq 'ReShade32 + Legacy NR x64 worker' -and $x86Bridge.LegacyNrPresetStatus -eq 'Session controlled') '32-bit D3D11 prepares the x64 NR worker while deferring enablement to the current session'
Check ($x86Bridge.DlssRuntimeProfile -eq 'nvidia-310.9.16' -and $script:lastDlssRuntimeProfile -eq 'nvidia-310.9.16') 'retired saved DLSS SR/RR profile migrates to the current profile and is persisted per game'
Check ((Test-Path (Join-Path $x86Modern 'OptiShadeLegacyNR.addon32')) -and (Test-Path (Join-Path $x86Modern 'host64/dlss5-feed-host64.exe')) -and (Test-Path (Join-Path $x86Modern 'host64/nvngx_dlss.dll'))) '32-bit NR component installs the x86 client, isolated x64 worker and matching runtime'
Check ($x86PresetText -ceq $x86PresetBefore -and $x86PresetText -notmatch 'DLSS5_Feed@DLSS5_Feed\.fx') 'NR preparation preserves the user preset and leaves feed enablement to the current session'
$repairConflicts=@(FindFusionConflicts $x86Modern)
$null=InstallFusion -Game $x86Modern -Payload $payload -StateRoot $x86ModernState -Installer (Join-Path $Output 'fixture-installer.exe') -Proxy 'dxgi.dll' -ReplaceMods $repairConflicts -ReplaceExisting $true -PreserveConfiguration $true -Executable $x86ModernExe
$x86Bridge=ReadOptiShadeState $x86ModernManifest
 Check ('Neural' -in @($x86Bridge.Components) -and $x86Bridge.Runtime -eq 'ReShade32 + Legacy NR x64 worker' -and $x86Bridge.DlssRuntimeProfile -eq 'nvidia-310.9.16' -and (Test-Path (Join-Path $x86Modern 'host64/dlss5-feed-host64.exe')) -and ([IO.File]::ReadAllText($x86Preset) -ceq $x86PresetBefore)) 'x86 core repair retains the NR bridge, migrates the retired DLSS profile and preserves the user preset'
$settingsPaths=@('host64/OptiScaler.ini','host64/ReShade.ini')
foreach($relative in $settingsPaths){[IO.File]::WriteAllText((Join-Path $x86Modern $relative),"[UserSettings]`nKeep=custom value`n")}
$legacySettings=ReadOptiShadeState $x86ModernManifest;foreach($e in $legacySettings.Files){if($e.Path.Replace('\','/') -in $settingsPaths){$e.Mutable=$false}};WriteState $legacySettings $x86ModernManifest
InstallOptiShadeAddon $x86ModernManifest $payload Neural ([pscustomobject]@{Names='NVIDIA GeForce RTX 5090'}) {}
InstallOptiShadeAddon $x86ModernManifest $payload Neural ([pscustomobject]@{Names='NVIDIA GeForce RTX 5090'}) {}
foreach($relative in $settingsPaths){Check ([IO.File]::ReadAllText((Join-Path $x86Modern $relative)) -eq "[UserSettings]`nKeep=custom value`n") ('repeated Neural update preserves edited '+$relative)}
$worker=Join-Path $x86Modern 'host64/dlss5-feed-host64.exe';$workerBytes=[IO.File]::ReadAllBytes($worker);[IO.File]::WriteAllText($worker,'unapproved binary change')
$badFlag=ReadOptiShadeState $x86ModernManifest;($badFlag.Files|Where-Object {$_.Path.Replace('\','/') -eq 'host64/dlss5-feed-host64.exe'}).Mutable=$true;WriteState $badFlag $x86ModernManifest
$blocked=$false;try{InstallOptiShadeAddon $x86ModernManifest $payload Neural ([pscustomobject]@{Names='NVIDIA GeForce RTX 5090'}) {}}catch{$blocked=$_.Exception.Message -match 'requires review'}
Check $blocked 'mutable settings exception does not permit changed worker executables'
[IO.File]::WriteAllBytes($worker,$workerBytes)
# Real inventory returns backslashes while extra worker/preset paths use '/'.
# Failed transactions must never restore one file's bytes over another file.
$rollbackHashes=@{}
foreach($file in Get-ChildItem -LiteralPath $x86Modern -File -Recurse){$rollbackHashes[$file.FullName]=HashFile $file.FullName}
$rollbackReceipt=[IO.File]::ReadAllText($x86ModernManifest)
$rollbackFailed=$false
try{InvokeAddonTransaction $x86ModernManifest Neural {
 [IO.File]::WriteAllText((Join-Path $x86Modern 'host64/nvngx_dlss.dll'),'partial runtime')
 [IO.File]::WriteAllText($x86Preset,'partial preset')
 throw 'injected mixed-separator rollback failure'
}.GetNewClosure()}catch{$rollbackFailed=$_.Exception.Message -match 'injected mixed-separator'}
Check $rollbackFailed 'mixed-separator transaction reached injected failure'
foreach($file in $rollbackHashes.Keys){Check ((HashFile $file) -eq $rollbackHashes[$file]) ('rollback restores exact original bytes: '+$file)}
Check ([IO.File]::ReadAllText($x86ModernManifest) -eq $rollbackReceipt) 'mixed-separator rollback preserves receipt'
RemoveOptiShadeAddon $x86ModernManifest Neural
$x86AfterRemove=ReadOptiShadeState $x86ModernManifest;$x86PresetText=[IO.File]::ReadAllText($x86Preset)
Check (-not(Test-Path (Join-Path $x86Modern 'OptiShadeLegacyNR.addon32')) -and -not(Test-Path (Join-Path $x86Modern 'host64/dlss5-feed-host64.exe')) -and 'Neural' -notin @($x86AfterRemove.Components)) 'removing x86 Neural Rendering removes only its owned bridge files and selection'
Check ($x86PresetText -ceq $x86PresetBefore) 'removing the bridge preserves the existing preset without changing feed selection'
$effectsGame=Join-Path $Output 'effects-game';New-Item -ItemType Directory $effectsGame -Force|Out-Null
$effectsExe=Join-Path $effectsGame 'Fixture.exe';WriteTestGameExe $effectsExe
$effectsManifest=@(InstallFusion $effectsGame $payload (Join-Path $Output 'effects-state') (Join-Path $Output 'fixture-installer.exe') 'dxgi.dll' -Executable $effectsExe)[-1]
$script:allFxInstallCalls=0
function InstallAllEffects([string]$Game,[string]$Catalogue,[scriptblock]$Progress){$script:allFxInstallCalls++;return 'fixture FX library installed'}
InstallOptiShadeAddon $effectsManifest $payload Effects $null {} -SkipAllFx
$effectsState=ReadOptiShadeState $effectsManifest
Check ($effectsState.Components -contains 'Effects' -and -not $effectsState.AllFxInstalled -and $script:allFxInstallCalls -eq 0) 'image effects component can be selected without starting the all-FX download'
InstallOptiShadeAddon $effectsManifest $payload Effects $null {}
$effectsState=ReadOptiShadeState $effectsManifest
Check ($effectsState.AllFxInstalled -and $script:allFxInstallCalls -eq 1) 'all-FX selection invokes the FX library install and records it'
RemoveOptiShadeAddon $effectsManifest Effects
$effectsState=ReadOptiShadeState $effectsManifest
Check (-not $effectsState.AllFxInstalled -and 'Effects' -notin @($effectsState.Components)) 'removing image effects clears its all-FX selection'
$beforeLegacyInstall=(ReadOptiShadeState $coreManifest).Files.Count
$blocked=$false;try{InstallOptiShadeAddon $coreManifest $payload Mfg $null {}}catch{$blocked=$_.Exception.Message -match 'legacy OptiShade MFG installer is retired'}
$legacyAfterAttempt=ReadOptiShadeState $coreManifest
Check ($blocked -and $legacyAfterAttempt.Files.Count -eq $beforeLegacyInstall -and 'Providers' -notin @(GetOptiShadeAddonSelection $legacyAfterAttempt)) 'retired legacy MFG cannot install files or pull in FSR/XeSS'
$legacyAfterAttempt|Add-Member Components @('Mfg') -Force;$legacyAfterAttempt|Add-Member NativeMfg $true -Force;WriteState $legacyAfterAttempt $coreManifest
RemoveOptiShadeAddon $coreManifest Mfg
$legacyRemoved=ReadOptiShadeState $coreManifest
Check ('Mfg' -notin @(GetOptiShadeAddonSelection $legacyRemoved) -and -not $legacyRemoved.NativeMfg) 'existing legacy MFG selection remains removable'

# A retained user preset never needs replacing during repair. A lost historical
# preset backup must not block unrelated repair or restoration of runtime files.
$presetRelative='OptiShadeData/Presets/Gravy - Fusion Cinema Custom v1.ini'
$preset=OwnedPath $coreGame $presetRelative
New-Item -ItemType Directory (Split-Path $preset) -Force|Out-Null
[IO.File]::WriteAllText($preset,'user edited preset; preserve exactly')
$presetHash=HashFile $preset
$core=ReadOptiShadeState $coreManifest
$badPresetBackup=Join-Path (Split-Path $coreManifest) 'Backups/missing-original';New-Item -ItemType Directory (Split-Path $badPresetBackup) -Force|Out-Null;[IO.File]::WriteAllText($badPresetBackup,'corrupt historical backup')
$core.Files+= [pscustomobject]@{Path=$presetRelative;SourcePath='';Hash=$presetHash;PreviousHash=('A'*64);Backup='Backups/missing-original';Mutable=$true;Retained=$true}
WriteState $core $coreManifest
$null=InstallFusion $coreGame $payload (Join-Path $Output 'core-state') (Join-Path $Output 'fixture-installer.exe') 'winmm.dll' @(FindFusionConflicts $coreGame) -ReplaceExisting $true -PreserveConfiguration $true
Check ((HashFile $preset) -eq $presetHash) 'repair preserves current preset when historical backup is missing'
$kept=@((ReadOptiShadeState $coreManifest).Files|Where-Object Path -eq $presetRelative)[0]
Check ($kept.Backup -eq 'Backups/missing-original' -and $kept.PreviousHash -eq ('A'*64) -and $kept.Retained) 'repair retains original recovery chain without inventing a backup'
# Missing retained preset: repair must leave it missing instead of silently
# recreating a bundled default over a user-owned look.
[IO.File]::Move($preset,$preset+'.fixture-saved')
$null=InstallFusion $coreGame $payload (Join-Path $Output 'core-state') (Join-Path $Output 'fixture-installer.exe') 'winmm.dll' @(FindFusionConflicts $coreGame) -ReplaceExisting $true -PreserveConfiguration $true
$missingPresetRecord=@((ReadOptiShadeState $coreManifest).Files|Where-Object {$_.Path -eq $presetRelative -and $_.Retained})
Check ((-not(Test-Path -LiteralPath $preset)) -and $missingPresetRecord.Count -eq 1) 'repair preserves absence of a missing retained preset'
[IO.File]::Move($preset+'.fixture-saved',$preset)
$core=ReadOptiShadeState $coreManifest
$loader=@($core.Files|Where-Object Path -eq 'winmm.dll')[0];$loader.Backup='Backups/missing-loader';$loader.PreviousHash=('B'*64)
WriteState $core $coreManifest;$before=HashFile $coreManifest;$repairSucceeded=$false
try{$null=InstallFusion $coreGame $payload (Join-Path $Output 'core-state') (Join-Path $Output 'fixture-installer.exe') 'winmm.dll' @(FindFusionConflicts $coreGame) -ReplaceExisting $true -PreserveConfiguration $true;$repairSucceeded=$true}catch{}
Check ($repairSucceeded -and (HashFile $coreManifest) -ne $before -and (ReadOptiShadeState $coreManifest).UnrestoredOriginalFiles -contains 'winmm.dll') 'repair proceeds and reports an unavailable original loader backup'
# Restore and Uninstall may proceed when only a saved-look backup is damaged:
# retain the current preset by default, and remove it only when the user opted out.
function NewPresetRecoveryFixture([string]$Name,[bool]$CorruptBackup=$false){
 $g=Join-Path $Output $Name;$stateRoot=if($Name -eq 'preset-uninstall'){Join-Path $Output 'OptiShade'}else{Join-Path $Output ($Name+'-state')};$stateFolder=Split-Path (ManifestPath $stateRoot $g);$presetPath=Join-Path $g $presetRelative
 New-Item -ItemType Directory -Path (Split-Path $presetPath),$stateFolder -Force|Out-Null
 $loader=Join-Path $g 'dxgi.dll';[IO.File]::WriteAllText($loader,'OptiShade loader fixture');[IO.File]::WriteAllText($presetPath,'saved look fixture')
 $badBackup='Backups/missing-original';if($CorruptBackup){$backup=OwnedPath $stateFolder $badBackup;New-Item -ItemType Directory (Split-Path $backup) -Force|Out-Null;[IO.File]::WriteAllText($backup,'corrupt historical backup')};$receipt=Join-Path $stateFolder 'manifest.json'
 WriteState @{Status='Installed';Version=(GetBundledOptiShadeVersion);Game=$g;Files=@(
  @{Path='dxgi.dll';SourcePath='winmm.dll';Hash=(HashFile $loader);PreviousHash='';Backup='';Mutable=$false;Retained=$false},
  @{Path=$presetRelative;SourcePath='';Hash=(HashFile $presetPath);PreviousHash=('A'*64);Backup=$badBackup;Mutable=$true;Retained=$true}
 );OwnedDirectories=@('OptiShadeData');Components=@()} $receipt
 return @{Game=$g;StateRoot=$stateRoot;StateFolder=$stateFolder;Preset=$presetPath;Loader=$loader;Receipt=$receipt}
}
$restoreFixture=NewPresetRecoveryFixture 'preset-restore' $true
$restoreProgressEvents=[Collections.Generic.List[object]]::new()
$restoreProgress={param($detail,$completed=0,$total=0);$restoreProgressEvents.Add([pscustomobject]@{Detail=$detail;Completed=$completed;Total=$total})}.GetNewClosure()
RestoreFusion $restoreFixture.Receipt -Progress $restoreProgress
$restoredPreset=ReadOptiShadeState $restoreFixture.Receipt
Check ((Test-Path $restoreFixture.Preset) -and -not(Test-Path $restoreFixture.Loader) -and $restoredPreset.Status -eq 'Restored') 'Restore removes runtime while keeping preset with a damaged original backup'
Check ($restoredPreset.RestoreWarnings -contains $presetRelative) 'Restore records the unavailable preset backup for the user'
Check ($restoreProgressEvents.Count -gt 1 -and $restoreProgressEvents[-1].Completed -eq 100 -and $restoreProgressEvents[-1].Total -eq 100) 'Restore reports determinate progress through completion'
$uninstallFixture=NewPresetRecoveryFixture 'preset-uninstall'
$uninstallProgressEvents=[Collections.Generic.List[object]]::new()
$uninstallProgress={param($detail,$completed=0,$total=0);$uninstallProgressEvents.Add([pscustomobject]@{Detail=$detail;Completed=$completed;Total=$total})}.GetNewClosure()
UninstallFusion $uninstallFixture.StateRoot (Join-Path $Output 'fixture-installer.exe') '' $true -Progress $uninstallProgress
Check ((Test-Path $uninstallFixture.Preset) -and -not(Test-Path $uninstallFixture.Loader) -and -not(Test-Path $uninstallFixture.StateRoot)) 'Uninstall removes runtime and retains preset when its original backup is damaged'
Check ($uninstallProgressEvents.Count -gt 1 -and $uninstallProgressEvents[-1].Completed -eq 100 -and $uninstallProgressEvents[-1].Total -eq 100) 'Uninstall reports determinate game and manager-file progress through completion'
$discardFixture=NewPresetRecoveryFixture 'preset-discard'
RestoreFusion $discardFixture.Receipt -KeepPresets $false
Check ((-not(Test-Path $discardFixture.Preset)) -and -not(Test-Path $discardFixture.Loader)) 'Restore removes preset after explicit discard despite damaged original backup'

# Legacy approved reinstalls could mistake the previous OptiShade runtime under
# OptiShadeData for an original game file. Restore must remove it, not revive it.
$legacyRestoreGame=Join-Path $Output 'legacy-orphan-restore';$legacyRestoreState=Join-Path $Output 'legacy-orphan-state';$legacyRestoreFolder=Join-Path $legacyRestoreState 'Games/41be2e785eff4699'
$legacyRuntime=Join-Path $legacyRestoreGame 'OptiShadeData/Engine/libxess.dll';$legacyLoader=Join-Path $legacyRestoreGame 'dxgi.dll'
New-Item -ItemType Directory -Path (Split-Path $legacyRuntime),$legacyRestoreFolder -Force|Out-Null
[IO.File]::WriteAllText($legacyRuntime,'older OptiShade runtime');[IO.File]::WriteAllText($legacyLoader,'current OptiShade loader')
$legacyBackup='Backups/41be2e785eff4699bfeb208fa3ce55d7-orphan-0';$legacyBackupPath=OwnedPath $legacyRestoreFolder $legacyBackup
New-Item -ItemType Directory (Split-Path $legacyBackupPath) -Force|Out-Null;Copy-Item -LiteralPath $legacyRuntime -Destination $legacyBackupPath
$legacyReceipt=Join-Path $legacyRestoreFolder 'manifest.json'
WriteState @{Status='Installed';Version='P0.21.7-beta.1';Game=$legacyRestoreGame;OwnedDirectories=@('OptiShadeData');Files=@(
 @{Path='dxgi.dll';SourcePath='winmm.dll';Hash=(HashFile $legacyLoader);PreviousHash='';Backup='';Mutable=$false;Retained=$false},
 @{Path='OptiShadeData/Engine/libxess.dll';SourcePath='';Hash='';PreviousHash=(HashFile $legacyRuntime);Backup=$legacyBackup;Mutable=$true;Retained=$false}
)} $legacyReceipt
RestoreFusion $legacyReceipt
Check ((-not(Test-Path $legacyRuntime)) -and (-not(Test-Path $legacyBackupPath)) -and (ReadOptiShadeState $legacyReceipt).Status -eq 'Restored') 'uninstall removes a legacy OptiShade orphan backup instead of restoring the previous runtime'

# If an earlier route switch left a duplicate OptiShade loader under a second
# supported alias, remove it only when its bytes match the receipt-owned loader.
$duplicateLoaderGame=Join-Path $Output 'duplicate-loader-restore';$duplicateLoaderState=Join-Path $Output 'duplicate-loader-state';New-Item -ItemType Directory -Path $duplicateLoaderGame,$duplicateLoaderState -Force|Out-Null
$ownedLoaderBytes='verified OptiShade loader';$ownedLoaderHashPath=Join-Path $Output 'owned-loader.bin';[IO.File]::WriteAllText($ownedLoaderHashPath,$ownedLoaderBytes)
[IO.File]::WriteAllText((Join-Path $duplicateLoaderGame 'dxgi.dll'),$ownedLoaderBytes);[IO.File]::WriteAllText((Join-Path $duplicateLoaderGame 'version.dll'),$ownedLoaderBytes);[IO.File]::WriteAllText((Join-Path $duplicateLoaderGame 'd3d12.dll'),'unrelated game loader')
$duplicateLoaderReceipt=Join-Path $duplicateLoaderState 'manifest.json'
WriteState @{Status='Restored';Game=$duplicateLoaderGame;OptionalMfg=$false;Sm86Mfg=$false;Files=@(@{Path='winmm.dll';SourcePath='winmm.dll';Hash=(HashFile $ownedLoaderHashPath)})} $duplicateLoaderReceipt
RemoveRecordedOptiShadeLoaders (ReadOptiShadeState $duplicateLoaderReceipt) $duplicateLoaderReceipt
Check ((-not(Test-Path (Join-Path $duplicateLoaderGame 'dxgi.dll'))) -and (-not(Test-Path (Join-Path $duplicateLoaderGame 'version.dll'))) -and [IO.File]::ReadAllText((Join-Path $duplicateLoaderGame 'd3d12.dll')) -eq 'unrelated game loader') 'uninstall removes duplicate OptiShade loader aliases by exact receipt hash and preserves foreign DLLs'

# An unrecorded reinstall preserves user looks, but does not save old runtime
# files as uninstall backups.
$legacyInstallGame=Join-Path $Output 'legacy-orphan-install';$legacyInstallState=Join-Path $Output 'legacy-orphan-install-state'
$legacyInstallRuntime=Join-Path $legacyInstallGame 'OptiShadeData/Engine/old-runtime.dll';$legacyPreset=Join-Path $legacyInstallGame 'OptiShadeData/Presets/user-look.ini';$legacyShader=Join-Path $legacyInstallGame 'OptiShadeData/Shaders/Custom/user-look.fx'
New-Item -ItemType Directory -Path (Split-Path $legacyInstallRuntime),(Split-Path $legacyPreset),(Split-Path $legacyShader) -Force|Out-Null
[IO.File]::WriteAllText((Join-Path $legacyInstallGame 'FlightSimulator2024.exe'),'fixture only');[IO.File]::WriteAllText($legacyInstallRuntime,'old app runtime');[IO.File]::WriteAllText($legacyPreset,'user preset');[IO.File]::WriteAllText($legacyShader,'user shader')
$legacyInstallReceipt=@(InstallFusion $legacyInstallGame $payload $legacyInstallState (Join-Path $Output 'fixture-installer.exe') 'winmm.dll' @(FindFusionConflicts $legacyInstallGame) -ReplaceExisting $true)[-1]
$legacyInstallManifest=ReadOptiShadeState $legacyInstallReceipt
$oldRuntimeRecord=@($legacyInstallManifest.Files|Where-Object Path -eq 'OptiShadeData/Engine/old-runtime.dll')[0]
Check ((-not(Test-Path $legacyInstallRuntime)) -and -not $oldRuntimeRecord.Backup -and (Test-Path $legacyPreset) -and (Test-Path $legacyShader)) 'unrecorded reinstall deletes stale runtime without backing it up and preserves user looks and shaders'
Check ($legacyInstallManifest.RecoveredChangedFiles -and [IO.File]::ReadAllText((Join-Path $legacyInstallManifest.RecoveredChangedFiles 'OptiShadeData/Engine/old-runtime.dll')) -eq 'old app runtime') 'repair archives unrecorded runtime files from OptiShade-owned data before removing them'
RestoreFusion $legacyInstallReceipt
Check ((-not(Test-Path $legacyInstallRuntime)) -and [IO.File]::ReadAllText($legacyPreset) -eq 'user preset' -and [IO.File]::ReadAllText($legacyShader) -eq 'user shader') 'uninstall does not restore old runtime and keeps retained user assets'

# OptiShade rewrites this generated report when pinned NVIDIA files are checked. Older manifests incorrectly recorded it as immutable.
$reportGame=Join-Path $Output 'mutable-nvidia-report';$reportState=Join-Path $Output 'mutable-nvidia-report-state';$reportData=Join-Path $reportGame 'OptiShadeData';New-Item -ItemType Directory -Path $reportData,$reportState -Force|Out-Null
$reportPath=Join-Path $reportData 'NVIDIA-versions.json';$reportOld='{"InstalledDLSS":"old"}';$reportNew='{"InstalledDLSS":"current","Checked":"now"}';$reportOldPath=Join-Path $Output 'old-nvidia-report.json';[IO.File]::WriteAllText($reportOldPath,$reportOld);[IO.File]::WriteAllText($reportPath,$reportNew);$reportReceipt=Join-Path $reportState 'manifest.json'
WriteState @{Status='Installed';Version='P1.0.17';Game=$reportGame;Architecture='x64';Files=@(@{Path='OptiShadeData/NVIDIA-versions.json';SourcePath='';Hash=(HashFile $reportOldPath);PreviousHash='';Backup='';Mutable=$false;Retained=$true;Component='Neural'});Components=@('Neural')} $reportReceipt
$reportTransactionWorked=$true;try{InvokeAddonTransaction $reportReceipt Neural { }}catch{$reportTransactionWorked=$false}
$reportManifest=ReadOptiShadeState $reportReceipt
Check ($reportTransactionWorked -and $reportManifest.Files[0].Mutable -and $reportManifest.Files[0].Hash -eq (HashFile $reportPath)) 'changed OptiShade NVIDIA version report no longer blocks the Neural component transaction'
$removeReportGame=Join-Path $Output 'mutable-nvidia-remove';$removeReportState=Join-Path $Output 'mutable-nvidia-remove-state';$removeReportData=Join-Path $removeReportGame 'OptiShadeData';New-Item -ItemType Directory -Path $removeReportData,$removeReportState -Force|Out-Null
$removeReportPath=Join-Path $removeReportData 'NVIDIA-versions.json';[IO.File]::WriteAllText($removeReportPath,$reportNew);[IO.File]::WriteAllText((Join-Path $removeReportGame 'OptiScaler.ini'),"[DlssNr]`nEnabled=true`n")
$removeReportReceipt=Join-Path $removeReportState 'manifest.json';WriteState @{Status='Installed';Version='P1.0.17';Game=$removeReportGame;Architecture='x64';Files=@(@{Path='OptiShadeData/NVIDIA-versions.json';SourcePath='';Hash=(HashFile $reportOldPath);PreviousHash='';Backup='';Mutable=$false;Retained=$true;Component='Neural'});Components=@('Neural');OptionalDlss=$true} $removeReportReceipt
$removeReportWorked=$true;try{RemoveOptiShadeAddon $removeReportReceipt Neural}catch{$removeReportWorked=$false;Write-Output ('Expected report-removal path threw: '+$_.Exception.Message)}
Check ($removeReportWorked -and -not(Test-Path $removeReportPath) -and 'Neural' -notin @(GetOptiShadeAddonSelection (ReadOptiShadeState $removeReportReceipt))) 'Neural uninstall tolerates and removes its rewritten NVIDIA version report'
$restoreReportGame=Join-Path $Output 'mutable-nvidia-restore';$restoreReportState=Join-Path $Output 'mutable-nvidia-restore-state';$restoreReportData=Join-Path $restoreReportGame 'OptiShadeData';New-Item -ItemType Directory -Path $restoreReportData,$restoreReportState -Force|Out-Null
$restoreReportPath=Join-Path $restoreReportData 'NVIDIA-versions.json';[IO.File]::WriteAllText($restoreReportPath,$reportNew);$restoreReportReceipt=Join-Path $restoreReportState 'manifest.json'
WriteState @{Status='Installed';Version='P1.0.17';Game=$restoreReportGame;OwnedDirectories=@('OptiShadeData');Files=@(@{Path='OptiShadeData/NVIDIA-versions.json';SourcePath='';Hash=(HashFile $reportOldPath);PreviousHash='';Backup='';Mutable=$false;Retained=$false;Component='Neural'});Components=@('Neural')} $restoreReportReceipt
$restoreReportWorked=$true;try{RestoreFusion $restoreReportReceipt}catch{$restoreReportWorked=$false}
Check ($restoreReportWorked -and -not(Test-Path $restoreReportPath) -and (ReadOptiShadeState $restoreReportReceipt).Status -eq 'Restored') 'Restore removes a changed OptiShade-generated NVIDIA versions report safely'

# A diagnostics/log viewer can keep a mutable runtime log open after the game
# exits. Restore must still remove the owned game loader, then retry the exact
# deferred log path after the viewer releases it.
$lockedLogGame=Join-Path $Output 'locked-runtime-log-restore';$lockedLogState=Join-Path $Output 'locked-runtime-log-state';$lockedLogData=Join-Path $lockedLogGame 'OptiShadeData'
New-Item -ItemType Directory -Path $lockedLogData,$lockedLogState -Force|Out-Null
$lockedLoader=Join-Path $lockedLogGame 'dxgi.dll';$lockedLog=Join-Path $lockedLogData 'Performance.log';[IO.File]::WriteAllText($lockedLoader,'owned runtime loader');[IO.File]::WriteAllText($lockedLog,'runtime log held by diagnostics viewer')
$lockedLogReceipt=Join-Path $lockedLogState 'manifest.json';WriteState @{Status='Installed';Version=(GetBundledOptiShadeVersion);Game=$lockedLogGame;Files=@(
 @{Path='dxgi.dll';SourcePath='winmm.dll';Hash=(HashFile $lockedLoader);PreviousHash='';Backup='';Mutable=$false;Retained=$false},
 @{Path='OptiShadeData/Performance.log';SourcePath='';Hash=(HashFile $lockedLog);PreviousHash='';Backup='';Mutable=$true;Retained=$false}
);OwnedDirectories=@('OptiShadeData');Components=@()} $lockedLogReceipt
$logLock=[IO.File]::Open($lockedLog,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$lockedRestoreCompleted=$false
try{RestoreFusion $lockedLogReceipt;$lockedRestoreCompleted=$true}finally{$logLock.Dispose()}
$lockedState=ReadOptiShadeState $lockedLogReceipt
Check ($lockedRestoreCompleted -and -not(Test-Path $lockedLoader) -and (Test-Path $lockedLog) -and $lockedState.Status -eq 'Restored' -and @($lockedState.DeferredCleanupPaths) -contains 'OptiShadeData/Performance.log') 'locked runtime log is deferred while the owned loader is restored'
RestoreFusion $lockedLogReceipt
Check (-not(Test-Path $lockedLog) -and -not(Test-Path (Join-Path $lockedLogGame 'OptiShadeData'))) 'a later cleanup removes the exact deferred log after its viewer releases it'

# Unknown rendering EXE selects the neutral route, even beside a known simulator.
$generic=Join-Path $Output 'generic-game';New-Item -ItemType Directory $generic -Force|Out-Null
[IO.File]::WriteAllText((Join-Path $generic 'FlightSimulator2024.exe'),'unrelated fixture')
$render=Join-Path $generic 'Unknown-Shipping.exe';WriteTestGameExe $render
$genericState=Join-Path $Output 'generic-state'
$gm=@(InstallFusion $generic $payload $genericState (Join-Path $Output 'fixture-installer.exe') 'dxgi.dll' -Executable $render)[-1]
Check ((ReadOptiShadeState $gm).RouteDLL -eq 'OptiShadeGeneric.dll' -and (Test-Path (Join-Path $generic 'OptiShadeData/Engine/Routes/OptiShadeGeneric.dll'))) 'explicit unlisted executable installs neutral route'
Check (-not(Test-Path (Join-Path $generic 'OptiShadeData/Engine/Routes/OptiShadeMSFS2024.dll'))) 'unrelated simulator file cannot change selected route'

# A completed core update can discard abandoned transaction copies, while an
# Exact current payload bytes can repair an interrupted legacy receipt; an
# edited receipt-owned DLLs are preserved for recovery and repaired from verified payload.
$staleRecord=ReadOptiShadeState $gm
$loaderRecord=@($staleRecord.Files|Where-Object {$_.Path -eq 'dxgi.dll'})[0]
$loaderRecord.Hash='A'*64;WriteState $staleRecord $gm
$gm=@(InstallFusion $generic $payload $genericState (Join-Path $Output 'fixture-installer.exe') 'dxgi.dll' -Executable $render -ReplaceExisting $true -PreserveConfiguration $true -ReplaceMods @(FindFusionConflicts $generic))[-1]
Check ((@( (ReadOptiShadeState $gm).Files|Where-Object Path -eq 'dxgi.dll')[0].Hash) -eq (HashFile (Join-Path $generic 'dxgi.dll'))) 'repair reconciles stale receipt only for exact verified incoming payload'
$loaderPath=Join-Path $generic 'dxgi.dll';$loaderBytes=[IO.File]::ReadAllBytes($loaderPath)
[IO.File]::WriteAllText($loaderPath,'unknown DLL bytes')
try{$repairedChanged=InstallFusion $generic $payload $genericState (Join-Path $Output 'fixture-installer.exe') 'dxgi.dll' -Executable $render -ReplaceExisting $true -PreserveConfiguration $true -ReplaceMods @(FindFusionConflicts $generic)}catch{throw}
$changedRecovery=(ReadOptiShadeState $repairedChanged).RecoveredChangedFiles
Check ($changedRecovery -and [IO.File]::ReadAllText((Join-Path $changedRecovery 'dxgi.dll')) -eq 'unknown DLL bytes' -and (HashFile $loaderPath) -eq (HashFile (Join-Path $payload 'winmm.dll'))) 'repair archives changed receipt-owned binaries and replaces them with the verified payload'
# A completed core update can discard abandoned transaction copies, while an
# AddonBackups folder whose receipt still matches remains a recovery point.
$transactionFolder=Split-Path $gm;$staleRollback='Rollback/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';$staleAddon='AddonBackups/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';$activeAddon='AddonBackups/cccccccccccccccccccccccccccccccc';$referencedAddon='AddonBackups/dddddddddddddddddddddddddddddddd'
foreach($relative in @($staleRollback,$staleAddon,$activeAddon,$referencedAddon)){[void][IO.Directory]::CreateDirectory((OwnedPath $transactionFolder $relative))}
[IO.File]::WriteAllText((OwnedPath $transactionFolder ($staleRollback+'/0')),'old install copy');[IO.File]::WriteAllText((OwnedPath $transactionFolder ($staleAddon+'/0')),'old component copy')
[IO.File]::WriteAllText((OwnedPath $transactionFolder ($staleAddon+'/manifest.json')),'{}');[IO.File]::WriteAllText((OwnedPath $transactionFolder ($referencedAddon+'/manifest.json')),'{}')
$referencedOriginal=OwnedPath $transactionFolder ($referencedAddon+'/0');[IO.File]::WriteAllText($referencedOriginal,'verified user original')
$transactionState=ReadOptiShadeState $gm;$transactionState.Files=@($transactionState.Files)+@([pscustomobject]@{Path='OptiShadeData/Presets/legacy.ini';SourcePath='';Hash='';PreviousHash=(HashFile $referencedOriginal);Backup=($referencedAddon+'/0');Mutable=$true;Retained=$true});WriteState $transactionState $gm
Copy-Item -LiteralPath $gm -Destination (OwnedPath $transactionFolder ($activeAddon+'/manifest.json'))
RemoveCompletedInstallTransactionBackups (ReadOptiShadeState $gm) $transactionFolder
Check ((-not(Test-Path (OwnedPath $transactionFolder $staleRollback))) -and (-not(Test-Path (OwnedPath $transactionFolder $staleAddon))) -and (Test-Path (OwnedPath $transactionFolder $activeAddon))) 'successful update prunes obsolete transaction copies and retains a matching recovery snapshot'
Check ((Test-Path -LiteralPath $referencedOriginal) -and (HashFile $referencedOriginal) -eq (ReadOptiShadeState $gm).Files[-1].PreviousHash) 'backup cleanup keeps a verified original still referenced for uninstall'

$null=InstallFusion $generic $payload $genericState (Join-Path $Output 'fixture-installer.exe') 'dxgi.dll' @(FindFusionConflicts $generic) -ReplaceExisting $true -PreserveConfiguration $true
Check ((ReadOptiShadeState $gm).LaunchExe -eq $render -and (ReadOptiShadeState $gm).RouteDLL -eq 'OptiShadeGeneric.dll') 'repair retains selected rendering executable and route'
RestoreFusion $gm
Check ((Test-Path $render) -and -not(Test-Path (Join-Path $generic 'dxgi.dll'))) 'generic restore removes owned loader and preserves game executable'

# A foreign version.dll may belong to another game add-on (for example,
# FSOzone). Installing through DXGI must leave it in place; selecting that
# occupied name must stop before any game files are changed.
$foreignProxyGame=Join-Path $Output 'foreign-proxy-game';New-Item -ItemType Directory $foreignProxyGame -Force|Out-Null
$foreignProxyExe=Join-Path $foreignProxyGame 'Game.exe';WriteTestGameExe $foreignProxyExe
$foreignVersionPath=Join-Path $foreignProxyGame 'version.dll';[IO.File]::WriteAllText($foreignVersionPath,'foreign add-on proxy fixture')
$foreignVersionHash=HashFile $foreignVersionPath;$foreignProxyState=Join-Path $Output 'foreign-proxy-state'
$foreignProxyRecord=@(InstallFusion $foreignProxyGame $payload $foreignProxyState (Join-Path $Output 'fixture-installer.exe') 'dxgi.dll' @(FindFusionConflicts $foreignProxyGame) -Executable $foreignProxyExe)[-1]
Check ((HashFile $foreignVersionPath) -eq $foreignVersionHash -and (Test-Path (Join-Path $foreignProxyGame 'dxgi.dll')) -and -not(@((ReadOptiShadeState $foreignProxyRecord).Files|Where-Object Path -ieq 'version.dll').Count)) 'DXGI installation preserves an unrelated foreign version.dll'
$foreignRouteBlocked=$false
try{$null=InstallFusion $foreignProxyGame $payload $foreignProxyState (Join-Path $Output 'fixture-installer.exe') 'version.dll' @(FindFusionConflicts $foreignProxyGame) -ReplaceExisting $true -Executable $foreignProxyExe}catch{$foreignRouteBlocked=$_.Exception.Message -like '*third-party version.dll*left untouched*'}
Check ($foreignRouteBlocked -and (HashFile $foreignVersionPath) -eq $foreignVersionHash -and (Test-Path (Join-Path $foreignProxyGame 'dxgi.dll'))) 'occupied foreign version.dll blocks that route without changing either file'

# When an older OptiShade receipt owns version.dll and recorded an original
# add-on backup, changing the route restores that exact original DLL.
$migrationGame=Join-Path $Output 'proxy-migration-game';New-Item -ItemType Directory $migrationGame -Force|Out-Null
$migrationExe=Join-Path $migrationGame 'Game.exe';WriteTestGameExe $migrationExe
$migrationState=Join-Path $Output 'proxy-migration-state';$migrationFolder=Split-Path (ManifestPath $migrationState $migrationGame)
$migrationBackup=Join-Path $migrationFolder 'Backups/original-version.dll';New-Item -ItemType Directory (Split-Path $migrationBackup) -Force|Out-Null
$originalVersionPath=Join-Path $migrationGame 'version.dll';$originalVersionBytes=[Text.Encoding]::UTF8.GetBytes('original FSOzone proxy fixture');[IO.File]::WriteAllBytes($migrationBackup,$originalVersionBytes)
$optishadeProxy=Join-Path $payload 'winmm.dll';Copy-Item -LiteralPath $optishadeProxy -Destination $originalVersionPath
$originalVersionHash=HashFile $migrationBackup;$installedVersionHash=HashFile $originalVersionPath
WriteState @{Status='Installed';Game=$migrationGame;Version='1.0.49';LaunchExe=$migrationExe;InstallMethod='version.dll';Files=@(@{Path='version.dll';SourcePath='winmm.dll';Hash=$installedVersionHash;PreviousHash=$originalVersionHash;Backup='Backups/original-version.dll';Mutable=$false});Components=@();IncludeEffects=$false} (ManifestPath $migrationState $migrationGame)
$migratedRecord=@(InstallFusion $migrationGame $payload $migrationState (Join-Path $Output 'fixture-installer.exe') 'dxgi.dll' @(FindFusionConflicts $migrationGame) -ReplaceExisting $true -PreserveConfiguration $true -Executable $migrationExe)[-1]
Check ((HashFile $originalVersionPath) -eq $originalVersionHash -and (Test-Path (Join-Path $migrationGame 'dxgi.dll'))) 'changing an owned OptiShade version.dll route restores the verified original add-on DLL'

# Full uninstall restores verified game originals, drops a legacy OptiShade
# runtime backup rather than reviving it, and removes diagnostics/cache/session
# data from the dedicated app store.
$uninstallStore=Join-Path $Output 'uninstall-clean/OptiShade';$uninstallGame=Join-Path $Output 'uninstall-clean-game';$uninstallFolder=Split-Path (ManifestPath $uninstallStore $uninstallGame)
$originalLoader=Join-Path $uninstallFolder 'Backups/original-loader';$oldRuntimeBackup=Join-Path $uninstallFolder 'Backups/41be2e785eff4699bfeb208fa3ce55d7-orphan-0'
New-Item -ItemType Directory -Path $uninstallFolder,(Split-Path $oldRuntimeBackup),$uninstallGame,(Join-Path $uninstallGame 'OptiShadeData/Engine'),(Join-Path $uninstallStore 'Diagnostics'),(Join-Path $uninstallStore 'Sessions/setup-stale'),(Join-Path $uninstallStore 'Downloads'),(Join-Path $uninstallFolder 'Rollback/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),(Join-Path $uninstallFolder 'AddonBackups/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb') -Force|Out-Null
$installedLoader=Join-Path $uninstallGame 'dxgi.dll';$oldRuntime=Join-Path $uninstallGame 'OptiShadeData/Engine/old-runtime.dll'
[IO.File]::WriteAllText($installedLoader,'OptiShade loader');[IO.File]::WriteAllText($oldRuntime,'old OptiShade runtime');[IO.File]::WriteAllText($originalLoader,'actual game loader');Copy-Item -LiteralPath $oldRuntime -Destination $oldRuntimeBackup
[IO.File]::WriteAllText((Join-Path $uninstallStore 'Diagnostics/old-report.zip'),'old diagnostic');[IO.File]::WriteAllText((Join-Path $uninstallStore 'Sessions/setup-stale/extracted.bin'),'stale setup extraction');[IO.File]::WriteAllText((Join-Path $uninstallStore 'Downloads/old-package.zip'),'old package');[IO.File]::WriteAllText((Join-Path $uninstallFolder 'Rollback/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/0'),'old rollback');[IO.File]::WriteAllText((Join-Path $uninstallFolder 'AddonBackups/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/0'),'old addon rollback')
$uninstallReceipt=Join-Path $uninstallFolder 'manifest.json'
WriteState @{Status='Installed';Version='P0.21.7-beta.1';Game=$uninstallGame;OwnedDirectories=@('OptiShadeData');Files=@(
 @{Path='dxgi.dll';SourcePath='winmm.dll';Hash=(HashFile $installedLoader);PreviousHash=(HashFile $originalLoader);Backup='Backups/original-loader';Mutable=$false;Retained=$false},
 @{Path='OptiShadeData/Engine/old-runtime.dll';SourcePath='';Hash='';PreviousHash=(HashFile $oldRuntime);Backup='Backups/41be2e785eff4699bfeb208fa3ce55d7-orphan-0';Mutable=$true;Retained=$false}
);Components=@()} $uninstallReceipt
UninstallFusion $uninstallStore (Join-Path $Output 'fixture-installer.exe') '' $true
Check (([IO.File]::ReadAllText($installedLoader) -eq 'actual game loader') -and -not(Test-Path $oldRuntime)) 'full uninstall restores original game loader without reviving an older OptiShade runtime'
Check (-not(Test-Path $uninstallStore)) 'full uninstall removes diagnostics, downloads, session extractions and old transaction backups'
# Repair must tolerate OptiShade's generated dependency status even in old receipts.
$metaGame=Join-Path $Output 'metadata-repair-game';New-Item -ItemType Directory $metaGame -Force|Out-Null
$metaExe=Join-Path $metaGame 'Fixture.exe';WriteTestGameExe $metaExe
$metaRelative='OptiShadeData/Neural-dependency-status.txt';$metaSource=Join-Path $payload $metaRelative
[IO.File]::WriteAllText($metaSource,'bundled status')
$catalog=ReadOptiShadeJson (Join-Path $payload 'files.json') 'fixture' -Shape Array;$catalog=@($catalog)+@(@{Path=$metaRelative;Hash=(HashFile $metaSource)})
ConvertTo-Json -InputObject $catalog|Set-Content (Join-Path $payload 'files.json') -Encoding UTF8
$metaStore=Join-Path $Output 'metadata-repair-state';$metaManifest=@(InstallFusion $metaGame $payload $metaStore (Join-Path $Output 'fixture-installer.exe') 'dxgi.dll' -Executable $metaExe)[-1]
$metaRecord=ReadOptiShadeState $metaManifest;($metaRecord.Files|Where-Object Path -eq $metaRelative).Mutable=$false;WriteState $metaRecord $metaManifest
[IO.File]::WriteAllText((Join-Path $metaGame $metaRelative),'runtime-generated updated status')
$null=InstallFusion $metaGame $payload $metaStore (Join-Path $Output 'fixture-installer.exe') 'dxgi.dll' @(FindFusionConflicts $metaGame) -ReplaceExisting $true -PreserveConfiguration $true
Check ((ReadOptiShadeState $metaManifest).Status -eq 'Installed') 'core repair accepts regenerated dependency status from older immutable receipt'
# A developer-updated addon is independent of the bundled core version.
$cockpitPath=Join-Path $metaGame 'glass-cockpit-dlss-fix.addon64'
[IO.File]::WriteAllText($cockpitPath,'official newer addon fixture')
$cockpitHash=HashFile $cockpitPath
$cockpitRecord=ReadOptiShadeState $metaManifest
$cockpitRecord|Add-Member Components @('Cockpit') -Force
$cockpitRecord.Files+= [pscustomobject]@{Path='glass-cockpit-dlss-fix.addon64';Hash=$cockpitHash;SourcePath='';PreviousHash='';Backup='';Mutable=$false;Retained=$true;Component='Cockpit'}
WriteState $cockpitRecord $metaManifest
for($repair=0;$repair -lt 2;$repair++){
 $null=InstallFusion $metaGame $payload $metaStore (Join-Path $Output 'fixture-installer.exe') 'dxgi.dll' @(FindFusionConflicts $metaGame) -ReplaceExisting $true -PreserveConfiguration $true
 $afterCockpit=@((ReadOptiShadeState $metaManifest).Files|Where-Object Path -eq 'glass-cockpit-dlss-fix.addon64')
 Check ((HashFile $cockpitPath) -eq $cockpitHash -and $afterCockpit.Count -eq 1 -and $afterCockpit[0].Hash -eq $cockpitHash -and $afterCockpit[0].Component -eq 'Cockpit') 'repeated core repair preserves separately updated Cockpit bytes and ownership'
}
$missingClear=$false;try{GetOptiShadeExecutableIdentity (Join-Path $Output 'missing-game.exe')}catch{$missingClear=$_.Exception.Message -match 'recorded game EXE is missing'}
Check $missingClear 'missing game EXE produces actionable location guidance'
# A later conflict must not allow an earlier payload file to be written.
$pf=Join-Path $Output 'policy-preflight';$pg=Join-Path $pf 'game';$pp=Join-Path $pf 'payload';New-Item -ItemType Directory (Join-Path $pg 'host64'),(Join-Path $pp 'host64') -Force|Out-Null
$pc=@();$pr=@()
foreach($name in @('first.dll','second.dll')){$rel='host64/'+$name;[IO.File]::WriteAllText((Join-Path $pg $rel),'old');[IO.File]::WriteAllText((Join-Path $pp $rel),'new');$pc+=@{Path=$rel;Hash=(HashFile (Join-Path $pp $rel))};$pr+=@{Path=$rel;Hash=(HashFile (Join-Path $pg $rel));Mutable=$true}}
$pm=Join-Path $pf 'manifest.json';WriteState @{Status='Installed';Game=$pg;Architecture='x86';Files=$pr} $pm
ConvertTo-Json -InputObject $pc|Set-Content (Join-Path $pp 'files.json') -Encoding UTF8
[IO.File]::WriteAllText((Join-Path $pg 'host64/second.dll'),'foreign change')
$preflightError='';try{InstallAddonPayload $pm $pp Neural {}}catch{$preflightError=$_.Exception.Message}
Check ($preflightError -match 'preflight stopped' -and [IO.File]::ReadAllText((Join-Path $pg 'host64/first.dll')) -eq 'old') ('full payload preflight blocks later binary conflict before any earlier file write (error={0})' -f $preflightError)
foreach($path in @('settings.ini','host64/OptiScaler.ini','host64/ReShade.ini','dlss5-feed.cfg')){Check ((GetOptiShadeFilePolicy $path) -eq 'UserSettings') ('shared settings policy: '+$path)}
foreach($path in @('OptiShadeData/NVIDIA-versions.json','OptiShadeData/Effects-install.json','OptiShadeData/Neural-dependency-status.txt')){Check ((GetOptiShadeFilePolicy $path) -eq 'GeneratedMetadata') ('shared generated metadata policy: '+$path)}
foreach($path in @('host64/worker.exe','dxgi.dll','nvngx_dlssnr.dll','unknown.json','host64/settings.ini.dll')){Check (-not(TestOptiShadeMutableFile $path)) ('unknown/binary file remains strict: '+$path)}
foreach($path in @('OptiShadeData/OptiMFG/Runtime/RTX40MFG-Universal.status.json','OptiShadeData/OptiMFG/Runtime/controller-35268-3500140.jsonl','OptiShadeData/OptiMFG/Runtime/exports/OptiMFGTest-diagnostics-1.zip')){Check ((GetOptiShadeFilePolicy $path) -eq 'RuntimeLog') ('OptiMFG runtime-written state is mutable: '+$path)}
foreach($path in @('OptiShadeData/OptiMFG/Runtime/OptiMFG_Controller.exe','OptiShadeData/OptiMFG/Runtime/msvcp140.dll','OptiShadeData/OptiMFG/Runtime/backends/headless/files.json','OptiShadeData/OptiMFG/Runtime/backends/headless/status.json','OptiShadeData/OptiMFG/Runtime/README.txt')){Check (-not(TestOptiShadeMutableFile $path)) ('OptiMFG runtime payload stays strict: '+$path)}
# Run production update detection against mutable data and genuinely missing files.
$parseErrors=$null;$managerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Beta/installer/manager.ps1'),[ref]$null,[ref]$parseErrors)
if($parseErrors.Count){throw $parseErrors[0]}
$fn=$managerAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'GetComponentUpdateIds'},$true);Invoke-Expression $fn.Extent.Text
function TestLocalComponentReceipt($Manifest,$Id){return $false}
function GetLocalComponentPackageState($Manifest,$Package){return [pscustomobject]@{Available=$false}}
$updateGame=Join-Path $Output 'policy-update-detection';New-Item -ItemType Directory (Join-Path $updateGame 'host64') -Force|Out-Null
$ini=Join-Path $updateGame 'host64/OptiScaler.ini';$dll=Join-Path $updateGame 'host64/worker.dll'
[IO.File]::WriteAllText($ini,'custom saved options');[IO.File]::WriteAllText($dll,'verified worker')
$script:bundleCatalog=@(@{Path='host64/OptiScaler.ini';Hash=('0'*64)},@{Path='host64/worker.dll';Hash=(HashFile $dll)})
$um=[pscustomobject]@{Status='Installed';Game=$updateGame;Architecture='x86';Components=@('Neural');Files=@([pscustomobject]@{Path='host64/OptiScaler.ini';Hash=(HashFile $ini);Mutable=$false},[pscustomobject]@{Path='host64/worker.dll';Hash=(HashFile $dll);Mutable=$false})}
Check (@(GetComponentUpdateIds $um).Count -eq 0) 'edited settings with old immutable flag do not cause endless update badge'
$savedFiles=$um.Files;$um.Files=@($um.Files|Where-Object Path -ne 'host64/worker.dll')
Check (@(GetComponentUpdateIds $um).Count -eq 0) 'matching shared file without ownership does not cause endless update badge'
Remove-Item -LiteralPath $dll
$um.Architecture='x64';$um.Files=@()
Check (@(GetComponentUpdateIds $um).Count -eq 0) 'x64 update verification ignores host64 Neural payload that x64 installs intentionally omit'
[IO.File]::WriteAllText($dll,'verified worker')
$um.Architecture='x86';$um.Files=@([pscustomobject]@{Path='host64/worker.dll';Hash=(HashFile $dll);Mutable=$false})
Check ($um.Files.Count -eq 1) 'update detection does not adopt shared file ownership'
$um.Files=$savedFiles
Remove-Item -LiteralPath $ini
Check ('Neural' -in @(GetComponentUpdateIds $um)) 'missing settings still request repair rather than disappearing from update detection'
[IO.File]::WriteAllText($ini,'custom saved options');Remove-Item -LiteralPath $dll
Check ('Neural' -in @(GetComponentUpdateIds $um)) 'missing runtime still requests an update'

$oldOpti=[pscustomobject]@{Status='Installed';Game=$optiMfgGame;Architecture='x64';Components=@('OptiMfg');Files=@()}
$script:bundleCatalog=@()
Check ('OptiMfg' -in @(GetComponentUpdateIds $oldOpti)) 'old controller-only receipt offers a backend update even with no payload differences'
# Exercise production picker/retry orchestration with UI isolated from the fixture.
$fn=$managerAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'InstallSelectedOptiMfgComponent'},$true);Invoke-Expression $fn.Extent.Text
function GetOptiShadeManagerStatusKey($Game){return $Game.ToLowerInvariant()}
function GetFusionGpu{return $multi}
function InstallOptiShadeAddon {param($ManifestPath,$Payload,$Id,$Gpu,$Progress,[switch]$ExplicitSelection,[string]$ApprovedForeignVersionDllHash);$script:attempts++;if($script:gpuRequired -and $script:attempts -eq 1){throw 'OPTIMFG_GPU_SELECTION_REQUIRED: fixture'};if($script:consentMode -and -not $ApprovedForeignVersionDllHash){throw ('OPTIMFG_FOREIGN_VERSION_DLL_CONSENT_REQUIRED:'+$script:foreignConsentHash)};$script:receivedApprovedHash=$ApprovedForeignVersionDllHash}
function ShowNeuralAdapterPicker($ManifestPath,$Component){if($Component -ne 'OptiMfg'){throw 'Wrong GPU picker'};return $script:acceptPicker}
$script:form=[pscustomobject]@{}
function ShowOptiShadeDialog($Owner,$Message,$Title,$Buttons,$Icon,$Default){$script:consentMessage=$Message;return $script:consentAnswer}
$script:attempts=0;$script:acceptPicker=$true;$script:gpuRequired=$true
InstallSelectedOptiMfgComponent $optiMfgReceipt
Check ($script:attempts -eq 2) 'picker acceptance retries the selected component exactly once'
$script:attempts=0;$script:acceptPicker=$false;$blocked=$false
try{InstallSelectedOptiMfgComponent $optiMfgReceipt}catch{$blocked=$_.Exception.Message -like '*selection cancelled*'}
Check ($blocked -and $script:attempts -eq 1) 'cancelled GPU selection never retries installation'
$script:attempts=0;$script:gpuRequired=$false;$script:consentMode=$true;$script:foreignConsentHash=('A'*64);$script:consentAnswer='Yes'
InstallSelectedOptiMfgComponent $optiMfgReceipt
Check ($script:attempts -eq 2 -and $script:receivedApprovedHash -ceq $script:foreignConsentHash -and $script:consentMessage -like '*verified recovery copy*') 'user approval retries with the exact version.dll hash and explains recovery'
$script:attempts=0;$script:receivedApprovedHash='';$script:consentAnswer='No';$blocked=$false
try{InstallSelectedOptiMfgComponent $optiMfgReceipt}catch{$blocked=$_.Exception.Message -like '*left untouched*'}
Check ($blocked -and $script:attempts -eq 1 -and -not $script:receivedApprovedHash) 'declining version.dll replacement cancels without retrying install'
