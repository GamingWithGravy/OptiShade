$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $root 'Beta/installer/ownership.ps1')
$realIdentity=${function:GetOptiShadeExecutableIdentity}
function GetOptiShadeExecutableIdentity([string]$File){
 [pscustomobject]@{Architecture='x64';ApiCandidates=@('DX12');Imports=@();Evidence='fixture executable identity'}
}
$script:assertions=0
function Check([bool]$Value,[string]$Message){if(-not $Value){throw $Message};$script:assertions++}
InitializeOptiShadeGpuIdentity
function IdentityAdapter([string]$Name,[string]$Luid,[int]$Major,[int]$Minor,[uint32]$Device){
 [pscustomobject]@{Name=$Name;Luid=$Luid;LuidHex=([uint64]$Luid).ToString('X16');VendorId=[uint32]0x10DE;DeviceId=$Device;SubSystemId=[uint32]1;Software=$false;ComputeCapabilityKnown=$true;ComputeMajor=$Major;ComputeMinor=$Minor;Family=[OptiShadeGpuIdentity]::FamilyFor($Name,$Major,$Minor);DriverVersion='fixture';ArchitectureEvidence='Synthetic DXGI/CUDA LUID fixture'}
}
$folder=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-compatibility-hybrid-'+[guid]::NewGuid().ToString('N'))
try{
 [void][IO.Directory]::CreateDirectory($folder)
 $exe=Join-Path $folder 'FixtureGame.exe';[IO.File]::WriteAllText($exe,'fixture')
 $hybrid=[pscustomobject]@{Known=$true;Names='NVIDIA GeForce RTX 5090, AMD Radeon(TM) Graphics'}
 $plan=GetFusionCompatibility $folder $exe $hybrid
 Check ($plan.NeuralRendering -match 'Multiple GPUs were detected') 'The hybrid-GPU report omitted its inventory note.'
 Check ($plan.NeuralRendering -match 'This scan lists hardware only and cannot identify the game renderer') 'The hybrid-GPU report still confuses hardware inventory with the live renderer.'
 Check ($plan.NeuralRendering -match 'Start the game from OptiShade to detect its rendering adapter automatically') 'The hybrid-GPU report omitted its current live-renderer check action.'
 Check ($plan.NeuralRendering -notmatch 'ensure the game actually uses the RTX card') 'The hybrid-GPU report retained the misleading assumption that inventory implies renderer choice.'
 $single=[pscustomobject]@{Known=$true;Names='NVIDIA GeForce RTX 5090'}
 $singlePlan=GetFusionCompatibility $folder $exe $single
 Check ($singlePlan.NeuralRendering -notmatch 'Multiple GPUs were detected') 'A single-GPU system received hybrid-GPU guidance.'
 $architectureCases=@(
  @('NVIDIA RTX 5000 Ada Generation','20',8,9,[uint32]0x26B2,'RTX 40'),
  @('NVIDIA Quadro RTX 5000','21',7,5,[uint32]0x1EB0,'RTX 20/30'),
  @('NVIDIA RTX PRO 5000 Blackwell','22',12,0,[uint32]0x2BB2,'RTX 50')
 )
 foreach($case in $architectureCases){
  $adapter=IdentityAdapter $case[0] $case[1] $case[2] $case[3] $case[4]
  $inventory=[pscustomobject]@{Known=$true;Names=$case[0];Adapters=@($adapter);Complete=$true}
  $architecturePlan=GetFusionCompatibility $folder $exe $inventory
  Check ($architecturePlan.NvidiaArchitecture -eq $case[5]) ("GPU summary guessed {0} architecture from product-name digits; expected measured {1}." -f $case[0],$case[5])
  if($case[5] -eq 'RTX 40'){Check ($architecturePlan.NeuralRendering -match 'RTX 40-series' -and $architecturePlan.NeuralRendering -notmatch 'RTX 50-series') 'RTX 5000 Ada received the wrong compatibility guidance.'}
  if($case[5] -eq 'RTX 20/30'){Check ($architecturePlan.NeuralRendering -match 'RTX 20/30-series' -and $architecturePlan.NeuralRendering -notmatch 'RTX 50-series') 'Quadro RTX 5000 received the wrong compatibility guidance.'}
 }
 "Compatibility hybrid-GPU report: $script:assertions production assertions passed; no game launched or files installed."
}finally{
 Set-Item Function:GetOptiShadeExecutableIdentity $realIdentity
 if(Test-Path -LiteralPath $folder){Remove-Item -LiteralPath $folder -Recurse -Force}
}
