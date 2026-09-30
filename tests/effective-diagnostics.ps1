$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/diagnostics.ps1"
function Check($value,$text){if(-not $value){throw $text};"PASS: $text"}
$now=[DateTime]::UtcNow;$birth=$now.AddMinutes(-5).ToFileTimeUtc()
$process=@{Id=123;StartedFileTimeUtc=[string]$birth;SelectedInstallation='Matched'}
$status=@{pid=123;processBirth=$birth;heartbeat=([DateTimeOffset]$now).ToUnixTimeSeconds();multiplier=2;lastSetOptionsResult=0;numFramesToGenerateMax=1;dynamicMfgSupported=$false;intervalValidSamples=0;realFpsMilli=0;dlssFpsMilli=0}
$valid=GetMfgSessionAssessment $status @($process) $now
Check ($valid.Association -eq 'Current selected process' -and $valid.RequestedMultiplier -eq 2 -and $valid.ObservedMultiplier -eq 'Unknown' -and $valid.DynamicSupported -eq $false) 'Matching hooks/options are not claimed as measured output or higher support'
$status.intervalValidSamples=30;$status.realFpsMilli=30000;$status.dlssFpsMilli=60000
Check ((GetMfgSessionAssessment $status @($process) $now).ObservedMultiplier -eq 2) 'Actual populated timing counters provide observed ratio'
$preservedBirth=$status.processBirth
foreach($missingBirth in @($null,'',0,'not-a-filetime','18446744073709551616')){
 $status.processBirth=$missingBirth
 Check ((GetMfgSessionAssessment $status @($process) $now).Association -eq 'Unverifiable process birth') 'Missing/invalid process birth never claims PID-only current association'
}
$status.processBirth=$preservedBirth
$status.processBirth++
Check ((GetMfgSessionAssessment $status @($process) $now).Association -eq 'Unmatched or stale') 'PID reuse cannot associate an old status'
$status.processBirth=$birth;$process.SelectedInstallation='Other installation'
Check ((GetMfgSessionAssessment $status @($process) $now).Association -eq 'Unmatched or stale') 'Another install is not the selected runtime'
$process.SelectedInstallation='Matched';$status.heartbeat-=60
Check ((GetMfgSessionAssessment $status @($process) $now).Association -eq 'Unmatched or stale') 'Old heartbeat remains historical'
$fixture=Join-Path $env:TEMP ('OptiShade-identity-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$file=Join-Path $fixture 'winmm.dll';[IO.File]::WriteAllText($file,'synthetic owned bytes')
$hash=(Get-FileHash $file).Hash;$receipt=@{Files=@(@{Path='winmm.dll';Hash=$hash})}
$identity=GetDiagnosticModuleIdentity $file $fixture $receipt
Check ($identity.SHA256 -eq $hash -and $identity.Ownership -eq 'Matches OptiShade ownership receipt' -and $identity.SelectedEntrypoint -like 'Unknown*') 'Exact receipt hash distinguishes owned bytes without inventing entrypoint activity'
[IO.File]::WriteAllText($file,'changed')
Check ((GetDiagnosticModuleIdentity $file $fixture $receipt).Ownership -eq 'Selected game folder; ownership not verified') 'Modified module is not claimed as verified ownership'
