$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/consent.ps1"
function Check($ok,$text){if(-not $ok){throw $text};"PASS: $text"}
foreach($version in @('581.80','616.91','616.92','617.14','1000.00')){
 $gpu=[pscustomobject]@{Nvidia=$true;Names='NVIDIA GeForce RTX 5090, AMD Radeon(TM) Graphics';Drivers=@([pscustomobject]@{Name='AMD Radeon(TM) Graphics';Version='31.0.24002.92'},[pscustomobject]@{Name='NVIDIA GeForce RTX 5090';Version=$version})}
 $message=GetNvidiaDriverWarning $gpu
 Check ([bool]$message -eq ([version]$version -lt [version]'616.92')) "Numeric driver comparison: $version"
 if($message){Check ($message.Contains($version) -and -not $message.Contains('31.0.24002.92')) 'Warning identifies NVIDIA version without comparing the AMD driver'}
}
$gpu.Drivers=@();Check ([bool](GetNvidiaDriverWarning $gpu)) 'Missing NVIDIA driver metadata warns without guessing'
$gpu.Drivers=@([pscustomobject]@{Name='NVIDIA GeForce RTX 5090';Version='not known'});Check ([bool](GetNvidiaDriverWarning $gpu)) 'Unparseable NVIDIA version is unknown'
$gpu=[pscustomobject]@{Nvidia=$false;Names='AMD Radeon RX 9070';Drivers=@()};Check (-not(GetNvidiaDriverWarning $gpu)) 'AMD-only does not receive an NVIDIA version warning'
$source=Get-Content "$PSScriptRoot/../installer/manager.ps1" -Raw
Check ($source.IndexOf('ConfirmNvidiaDriver $form') -lt $source.IndexOf('$script:manifest=InstallFusion')) 'Driver confirmation precedes installation mutation'
