$ErrorActionPreference='Stop'
. "$PSScriptRoot/library.ps1"
. (Join-Path $PSScriptRoot '../../tests/reconstruction/fixtures/windows_pe.ps1')
function Assert-Discovery([bool]$Expected,[bool]$Actual,[string]$Name){if($Expected -ne $Actual){throw "$Name expected '$Expected' but got '$Actual'."}}

Assert-Discovery $false (TestFusionLibraryCandidateName 'Microsoft Flight Simulator Digital Ownership') 'Digital Ownership entitlement excluded'
Assert-Discovery $false (TestFusionLibraryCandidateName 'Microsoft.FlightSimulator_Digital_Ownership') 'Package-style entitlement name excluded'
Assert-Discovery $false (TestFusionLibraryCandidateName 'Microsoft.FlightSimulatorDigitalOwnership') 'Compact package identity excluded'
Assert-Discovery $true (TestFusionLibraryCandidateName 'Microsoft Flight Simulator 2024') 'MSFS 2024 retained'
Assert-Discovery $true (TestFusionLibraryCandidateName 'X-Plane 12') 'X-Plane retained'
Assert-Discovery $true (TestFusionLibraryCandidateName 'Cyberpunk 2077') 'Generic game retained'
Assert-Discovery $true (TestFusionSimulatorPackageIdentity 'Microsoft.FlightSimulator' 'Microsoft.FlightSimulator') 'Exact MSFS 2020 package identity accepted'
Assert-Discovery $true (TestFusionSimulatorPackageIdentity 'Microsoft.Limitless' 'Microsoft.Limitless') 'Exact MSFS 2024 package identity accepted'
Assert-Discovery $false (TestFusionSimulatorPackageIdentity 'Microsoft.FlightSimulator' 'Microsoft.FlightSimulatorDigitalOwnership') 'Ownership package rejected by exact identity'
Assert-Discovery $false (TestFusionSimulatorPackageIdentity 'Microsoft.FlightSimulator' 'Microsoft.Limitless') 'Different simulator package rejected'

$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('optishade-game-target-'+[guid]::NewGuid().ToString('N'))
$xplane=Join-Path $fixtureRoot 'X-Plane 12';$msfs=Join-Path $fixtureRoot 'Microsoft Flight Simulator 2024';$nestedMsfs=Join-Path $fixtureRoot 'steamapps/common/MSFS2024/Game'
New-Item -ItemType Directory -Path $xplane,$msfs,$nestedMsfs -Force|Out-Null
WriteOptiShadeFixtureExecutable (Join-Path $xplane 'X-Plane.exe')
WriteOptiShadeFixtureExecutable (Join-Path $msfs 'FlightSimulator2024.exe')
WriteOptiShadeFixtureExecutable (Join-Path $nestedMsfs 'FlightSimulator2024.exe')
try{
 $xpGame=[pscustomobject]@{Name='X-Plane 12 (experimental)';Folder=$xplane;InstallFolder=$msfs}
 Assert-Discovery $true ((GetFusionGameTargetFolder $xpGame) -eq [IO.Path]::GetFullPath($xplane)) 'selected X-Plane target ignores unrelated stale MSFS receipt path'
 $mismatch=$false;try{$null=GetFusionGameTargetFolder ([pscustomobject]@{Name='X-Plane 12';Folder=$msfs;InstallFolder=$msfs})}catch{$mismatch=$_.Exception.Message -like 'The selected game*does not match*'}
 Assert-Discovery $true $mismatch 'selected X-Plane rejects an MSFS executable folder'
 Assert-Discovery $true ((GetMsfsTitle (Split-Path $nestedMsfs -Parent)) -eq 'Microsoft Flight Simulator 2024') 'nested Steam MSFS layout is recognized by exact executable'
 $nestedExecutable=@(FindFusionExecutable (Split-Path $nestedMsfs -Parent) 'Steam' 'MSFS2024')
 Assert-Discovery $true ($nestedExecutable.Count -eq 1 -and $nestedExecutable[0].Path -eq (Join-Path $nestedMsfs 'FlightSimulator2024.exe')) 'nested Steam MSFS executable is selected without choosing another binary'
}finally{Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue}

Write-Output 'Library discovery tests passed.'
