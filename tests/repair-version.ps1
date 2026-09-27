$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/ownership.ps1"
AssertRepairVersion ([pscustomobject]@{Version=(GetBundledOptiShadeVersion)})
foreach($version in @('P0.20.11-MSFS24','P0.21-MSFS24','', $null)){
 $rejected=$false
 try{AssertRepairVersion ([pscustomobject]@{Version=$version})}catch{$rejected=$true}
 if(-not $rejected){throw "Repair accepted mismatched version: $version"}
}
'PASS: same-version repair accepted; older/newer/missing versions rejected'
