$ErrorActionPreference='Stop'
. "$PSScriptRoot/fixtures/windows_pe.ps1"
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $root 'Beta/installer/ownership.ps1')
. (Join-Path $root 'Beta/installer/mfg.ps1')
function GetOptiShadeMfgPolicyChannel { return 'beta' }
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('optishade-adapter-fixture-'+[guid]::NewGuid().ToString('N'))
$fixturePreviousLocalAppData=$env:LOCALAPPDATA;$env:LOCALAPPDATA=$fixture
[void][IO.Directory]::CreateDirectory($fixture)
WriteOptiShadeFixtureExecutable (Join-Path $fixture 'FlightSimulator2024.exe')
$script:fixtureState=[pscustomobject]@{Status='Installed';Game=$fixture;LaunchExe=(Join-Path $fixture 'FlightSimulator2024.exe');Architecture='x64';RouteDLL='OptiShadeMSFS2024.dll';NeuralGpuName='NVIDIA GeForce RTX 4090'}
function ReadOptiShadeState { return $script:fixtureState }
function AssertClosed { }

if([IO.Path]::DirectorySeparatorChar -ne '\'){
 function OwnedPath([string]$Root,[string]$Relative){$base=[IO.Path]::GetFullPath($Root).TrimEnd('/')+'/';$target=[IO.Path]::GetFullPath((Join-Path $Root $Relative));if(-not $target.StartsWith($base,[StringComparison]::Ordinal)){throw 'Fixture path escape.'};return $target}
}
function ReadOptiShadeJson { throw 'TEST: reached payload verification after adapter admission' }
$checks=0
function FixtureAdapter([string]$name,[string]$luid,[int]$family){
 $major=switch($family){20{7};30{8};40{8};50{12};default{0}};$minor=switch($family){20{5};30{6};40{9};default{0}}
 [pscustomobject]@{Name=$name;Luid=$luid;VendorId=$(if($family){0x10DE}else{0x1002});DeviceId=1;SubSystemId=1;Software=$false;ComputeCapabilityKnown=[bool]$family;ComputeMajor=$major;ComputeMinor=$minor;Family=$family;DriverVersion='fixture'}
}
$ada=FixtureAdapter 'NVIDIA GeForce RTX 4090' '40' 40;$ampere=FixtureAdapter 'NVIDIA GeForce RTX 3090' '30' 30;$turing=FixtureAdapter 'NVIDIA GeForce RTX 2080' '20' 20;$blackwell=FixtureAdapter 'NVIDIA GeForce RTX 5090' '50' 50;$amd=FixtureAdapter 'AMD Radeon RX 7900 XTX' '79' 0
# Current-action consent is provided by this test harness only. The product
# guard still executes; no production force flag or name-only admission exists.
$script:AntiCheatOperation=@{Name='source admission fixture';Accepted=@{('installation|'+[IO.Path]::GetFullPath($fixture).TrimEnd('\').ToLowerInvariant())=$true}}
# Exercise adapter admission after the global start-up agreement has already
# been accepted. Consent-specific refusal/acceptance behavior is covered by
# test_anti_cheat.ps1 and test_anti_cheat_routes.ps1.
$script:AntiCheatSessionAccepted=$true
function CheckAdmission([object[]]$cards,[bool]$allowed){
 Write-Output ('Checking source-MFG admission: '+($cards.Name -join ', '))
 $message=''
 try {InstallSourceMfg (Join-Path $fixture 'manifest.json') (Join-Path $fixture 'payload') ([pscustomobject]@{Adapters=@($cards);Complete=$true})} catch {$message=$_.Exception.Message}
 $admitted=$message -eq 'TEST: reached payload verification after adapter admission'
 if($admitted -ne $allowed){throw "Wrong admission (expected $allowed): $message"}
 $script:checks++
}
try {
 CheckAdmission @($ada,$ampere) $false
 CheckAdmission @($ada,$blackwell) $false
 CheckAdmission @($ada) $true
 $script:fixtureState.NeuralGpuName='NVIDIA GeForce RTX 5090'
 # RTX 20/30 now use the separate pinned SM86 provider path; this legacy
 # source installer must refuse them even when the NR preference differs.
 CheckAdmission @($ampere) $false
 CheckAdmission @($turing) $false
 CheckAdmission @($blackwell) $false
 CheckAdmission @($amd) $false
 CheckAdmission @() $false
 Write-Output "$checks installer admission assertions passed; CPU fixtures only, not rendering-adapter/output qualification."
} finally {
 $script:AntiCheatOperation=$null;$script:AntiCheatSessionAccepted=$false;$env:LOCALAPPDATA=$fixturePreviousLocalAppData
 # Only the exact file and empty directory created by this test.
 Remove-Item -LiteralPath (Join-Path $fixture 'FlightSimulator2024.exe')
 [IO.Directory]::Delete($fixture)
}
