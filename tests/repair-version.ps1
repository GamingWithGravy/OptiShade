$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/ownership.ps1"
AssertRepairVersion ([pscustomobject]@{Version=(GetBundledOptiShadeVersion)})
foreach($version in @('P0.20.11-MSFS24','P0.21-MSFS24','', $null)){
 $rejected=$false
 try{AssertRepairVersion ([pscustomobject]@{Version=$version})}catch{$rejected=$true}
 if(-not $rejected){throw "Repair accepted mismatched version: $version"}
}
'PASS: same-version repair accepted; older/newer/missing versions rejected'

function GetBundledOptiShadeVersion { 'P0.21.3-beta.4' }
if(-not(TestBundledUpdateVersion ([pscustomobject]@{Version='P0.21.2'}))){throw 'Stable to beta upgrade was not recognised'}
foreach($version in @((GetBundledOptiShadeVersion),'P0.21.3','P0.21.3-beta.9')){if(TestBundledUpdateVersion ([pscustomobject]@{Version=$version})){throw "Non-upgrade incorrectly accepted: $version"}}
function GetBundledOptiShadeVersion { 'P0.21.3-beta.20' }
if(-not(TestBundledUpdateVersion ([pscustomobject]@{Version='P0.21.3-beta.2'}))){throw 'Beta revisions are not ordered numerically'}
'PASS: stable-to-beta and beta revision ordering; same build/downgrades rejected'
$message='';try{AssertRepairVersion ([pscustomobject]@{Version='P0.20.1'})}catch{$message=$_.Exception.Message}
if($message -notlike '*Choose Update OptiShade in Setup*'){throw 'Mismatched repair did not point to the separate reviewed update action'}
'PASS: mismatched Repair points to the distinct Update action without applying it'
