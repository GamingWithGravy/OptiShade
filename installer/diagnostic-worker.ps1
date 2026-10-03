param([Parameter(Mandatory=$true)][string]$Request)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/json-state.ps1"
$requestData=ReadOptiShadeJson $Request 'Diagnostic request JSON' -MaxBytes 65536
$output=Join-Path (Split-Path -Parent $Request) 'report.json'
try {
 foreach($name in @('ownership','library','compatibility','recovery','diagnostics')){. "$PSScriptRoot/$name.ps1"}
 $report=GetDetailedSupportReportCore ([string]$requestData.Game) ([string]$requestData.Store)
 $report|Add-Member -NotePropertyName CollectionStatus -NotePropertyValue 'Completed - individual unavailable fields remain explicitly marked' -Force
 $report=ConvertOptiShadeDiagnosticExport $report
 $json=$report|ConvertTo-Json -Depth 16
 if([Text.Encoding]::UTF8.GetByteCount($json) -gt 8MB){throw 'Diagnostic output exceeded budget'}
 [IO.File]::WriteAllText($output,$json,[Text.UTF8Encoding]::new($true))
}catch{
 [IO.File]::WriteAllText($output,(@{SchemaVersion=8;CollectionStatus='Incomplete';Limitations='The collector stopped before completing. Missing evidence is not a clean result.';FailureType=$_.Exception.GetType().FullName}|ConvertTo-Json),[Text.UTF8Encoding]::new($true))
 exit 1
}
