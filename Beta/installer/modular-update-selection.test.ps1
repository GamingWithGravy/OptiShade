$ErrorActionPreference='Stop'
. "$PSScriptRoot/updates.ps1"
function AssertPackageId([string]$Component,[string]$Expected){
 $actual=GetOptiShadeModularUpdatePackageId $Component
 if($actual -cne $Expected){throw "$Component expected package [$Expected] but received [$actual]"}
}
AssertPackageId 'Core' 'OptiShade.Core'
AssertPackageId 'Effects' 'OptiShade.Effects'
AssertPackageId 'OptiMfg' 'OptiShade.OptiMFG'
AssertPackageId 'Providers' 'OptiShade.Providers'
AssertPackageId 'Neural' ''
AssertPackageId 'Cockpit' ''
$managerSource=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manager.ps1') -Raw -Encoding UTF8
$updateSource=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'updates.ps1') -Raw -Encoding UTF8
$launcherSource=Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'distribution/New-LauncherChannel.ps1') -Raw -Encoding UTF8
if($managerSource -notmatch '(?s)if\(\$Update\.Modular\).*?StartModularManagerUpdate'){throw 'A modular manager update must bypass the legacy game-install update plan.'}
if($managerSource -notmatch 'HostPID=\$PID' -or $managerSource -notmatch 'OPTISHADE_LAUNCHER_PID'){throw 'The modular updater must wait for both the host and launcher processes before replacing files.'}
if($managerSource -match 'EnsureVerifiedModularPayload -RequiredIds @\(\$requiredIds'){throw 'Update Manager refresh must not stage every installed package as one batch.'}
if($managerSource -notmatch 'GetOptiShadeModularUpdatePackageId \(\[string\]\$item\.Id\)'){throw 'A modular component package must be fetched at the individual update-row boundary.'}
if($managerSource -notmatch 'EnsureVerifiedModularPayload -RequiredIds @\(\)' -or $managerSource -notmatch '\$script:modularDistribution -and \(\$onlinePayloadIds\.Count -or \$needsCorePayload\)'){throw 'Core installation and later payload-backed components must use the signed Core base without eagerly fetching unrelated optional packages.'}
if($managerSource -notmatch '\$notYetOnline=@\(\$desired\|Where-Object \{\$_ -eq ''Mfg''\}\)'){throw 'Neural Rendering, Glass Cockpit and AtmosphereMod must keep their independent download routes.'}
if($managerSource -match 'ComponentDownloadTest|ComponentStageSelection|ComponentStageTest|ComponentDownloadStatus'){throw 'The user-facing Components page must not expose the retired package-download test controls.'}
if((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manager.xaml') -Raw -Encoding UTF8) -match 'Online component packages|Verify &amp; stage signed packages'){throw 'The user-facing package staging panel should be removed.'}
if($updateSource -notmatch '--launcher-check-update' -or $updateSource -notmatch 'GetOptiShadeModularUpdate'){throw 'The modular manager must check its signed launcher branch independently of GitHub Releases.'}
if($launcherSource -match "WriteAllText\(\(Join-Path \$staging '\.gitattributes'" -or $launcherSource -notmatch '99MB'){throw 'The launcher channel must use an ordinary GitHub branch file below the 100 MiB limit.'}
Write-Output 'Modular self-update is isolated from game updates; launcher channel uses ordinary GitHub files.'
Write-Output 'Modular update package selection passed.'
