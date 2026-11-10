$ErrorActionPreference='Stop'
. "$PSScriptRoot/components.ps1"
. "$PSScriptRoot/mfg.ps1"

function ReadOptiShadeState([string]$ManifestPath){[pscustomobject]@{}}

$installRejected=$false
try{$null=InstallOptiShadeAddon -ManifestPath 'unused' -Payload 'unused' -Id 'Mfg'}catch{$installRejected=$_.Exception.Message -match 'legacy OptiShade MFG installer is retired'}
if(-not $installRejected){throw 'The retired legacy MFG component could still be installed through the component installer.'}

$automaticRetired=$false
$message=EnsureAutomaticMfg -ManifestPath 'unused' -Payload 'unused' -GpuNames @()
$automaticRetired=$message -match 'legacy MFG provider installation is disabled'
if(-not $automaticRetired){throw 'Automatic compatibility repair did not leave legacy MFG disabled.'}

$optionalRejected=$false
try{$null=InstallOptionalMfg -ManifestPath 'unused' -Payload 'unused' -GpuNames @()}catch{$optionalRejected=$_.Exception.Message -match 'legacy OptiShade MFG installer is retired'}
if(-not $optionalRejected){throw 'The retired legacy MFG provider installer could still be called directly.'}

Write-Output 'Legacy MFG installation retirement tests passed.'
