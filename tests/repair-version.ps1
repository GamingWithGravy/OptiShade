$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/ownership.ps1"
AssertRepairVersion ([pscustomobject]@{Version=(GetBundledOptiShadeVersion)})
foreach($version in @('P0.20.11-MSFS24','P0.21-MSFS24','', $null)){
 $rejected=$false
 try{AssertRepairVersion ([pscustomobject]@{Version=$version})}catch{$rejected=$true}
 if(-not $rejected){throw "Repair accepted mismatched version: $version"}
}
'PASS: same-version repair accepted; older/newer/missing versions rejected'

if(-not(TestBundledUpdateVersion ([pscustomobject]@{Version='P0.21.2'}))){throw 'Stable to beta upgrade was not recognised'}
foreach($version in @((GetBundledOptiShadeVersion),'P0.21.3','P0.21.3-beta.2')){if(TestBundledUpdateVersion ([pscustomobject]@{Version=$version})){throw "Non-upgrade incorrectly accepted: $version"}}
function GetBundledOptiShadeVersion { 'P0.21.3-beta.20' }
if(-not(TestBundledUpdateVersion ([pscustomobject]@{Version='P0.21.3-beta.2'}))){throw 'Beta revisions are not ordered numerically'}
'PASS: stable-to-beta and beta revision ordering; same build/downgrades rejected'