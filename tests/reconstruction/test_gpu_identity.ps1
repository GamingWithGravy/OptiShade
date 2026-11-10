$ErrorActionPreference='Stop'
. "$PSScriptRoot/fixtures/windows_pe.ps1"
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Beta/installer/ownership.ps1"
. "$root/Beta/installer/neural-download.ps1"
. "$root/Beta/installer/provider-policy.ps1"
if([IO.Path]::DirectorySeparatorChar -ne '\'){
 function OwnedPath([string]$Root,[string]$Relative){$base=[IO.Path]::GetFullPath($Root).TrimEnd('/')+'/';$target=[IO.Path]::GetFullPath((Join-Path $Root $Relative));if(-not $target.StartsWith($base,[StringComparison]::Ordinal)){throw 'Fixture path escape.'};return $target}
}
InitializeOptiShadeGpuIdentity
$count=0
function Check($Value,[string]$Message){if(-not $Value){throw $Message};$script:count++}
function Adapter([string]$Name,[string]$Luid,[int]$Major,[int]$Minor,[uint32]$Device=1,[uint32]$Vendor=0x10DE){
 [pscustomobject]@{Name=$Name;Luid=$Luid;LuidHex=([uint64]$Luid).ToString('X16');VendorId=$Vendor;DeviceId=$Device;SubSystemId=7;Software=$false;ComputeCapabilityKnown=$true;ComputeMajor=$Major;ComputeMinor=$Minor;Family=[OptiShadeGpuIdentity]::FamilyFor($Name,$Major,$Minor);DriverVersion='fixture-driver';ArchitectureEvidence='Synthetic test fixture'}
}
$ada=Adapter 'NVIDIA RTX 5000 Ada' '10' 8 9 0x26B2
$turing=Adapter 'Quadro RTX 5000' '11' 7 5 0x1EB0
$blackwell=Adapter 'NVIDIA RTX PRO 5000 Blackwell' '12' 12 0 0x2BB2
$ampere=Adapter 'NVIDIA GeForce RTX 3090' '13' 8 6 0x2204
$geforce=Adapter 'NVIDIA GeForce RTX 4090' '14' 8 9 0x2684
Check ($ada.Family -eq 40 -and $turing.Family -eq 20 -and $blackwell.Family -eq 50) 'Professional model numbers were mistaken for GPU architecture.'
Check ([OptiShadeGpuIdentity]::FamilyFor('NVIDIA TITAN RTX',7,5) -eq 20) 'Driver-identified TITAN RTX was rejected by a consumer-number rule.'
Check ([OptiShadeGpuIdentity]::FamilyFor('NVIDIA GeForce GTX 1650',7,5) -eq 0) 'Turing GTX was advertised as an RTX inference candidate.'
Check ([OptiShadeGpuIdentity]::FamilyFor('NVIDIA GeForce RTX 6090',13,0) -eq 0) 'An unknown future architecture was silently mapped to an old provider.'
$gpu=[pscustomobject]@{Names='RTX 5000 Ada, Quadro RTX 5000';Adapters=@($ada,$turing)}
Check ((ResolveOptiShadeAdapterCandidate $gpu).State -eq 'ambiguous_adapter') 'Multiple physical NVIDIA adapters were silently collapsed.'
Check ((ResolveOptiShadeAdapterCandidate $gpu '' '10').Adapter.Family -eq 40) 'A rendering LUID did not select its exact measured architecture.'
$amdRenderer=Adapter 'AMD Radeon integrated graphics' '17' 0 0 1 0x1002
$hybrid=[pscustomobject]@{Adapters=@($ada,$amdRenderer);Complete=$true}
$integrated=ResolveOptiShadeAdapterCandidate $hybrid '' '17'
Check ($integrated.State -eq 'unsupported_hardware' -and $integrated.Adapter.VendorId -eq 0x1002 -and $integrated.Reason -match 'Windows graphics preference to High performance') 'A live AMD rendering LUID did not produce a clear hybrid-GPU blocker or was allowed to fall back to the NVIDIA inventory adapter.'
$twin=Adapter 'NVIDIA RTX 5000 Ada' '15' 8 9 0x26B2
Check ((ResolveOptiShadeAdapterCandidate ([pscustomobject]@{Adapters=@($ada,$twin)}) 'NVIDIA RTX 5000 Ada').State -eq 'ambiguous_adapter') 'Identical GPU names hid two physical adapters.'
$partial=[pscustomobject]@{Adapters=@($ada);Complete=$false}
Check ((ResolveOptiShadeAdapterCandidate $partial).State -eq 'unknown_adapter') 'An incomplete DXGI inventory silently selected its sole observed adapter.'
Check ((ResolveOptiShadeAdapterCandidate $partial '' '10').Adapter.Luid -ceq '10') 'An exact live LUID could not select its measured adapter in an otherwise incomplete inventory.'
$evidenceRoot=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-neural-evidence-'+[guid]::NewGuid().ToString('N'))
try{
 [void][IO.Directory]::CreateDirectory($evidenceRoot)
 $luidHex=([uint64]$ada.Luid).ToString('X16');$deviceHex=([uint32]$ada.DeviceId).ToString('X4')
 [IO.File]::WriteAllText((Join-Path $evidenceRoot 'OptiScaler.log'),"[2026-10-22 12:34:56.789] [info] DlssNr::Evaluate NR rendering adapter: luid=$luidHex; vendor=10DE; device=$deviceHex; software=false; name=$($ada.Name)`r`n")
 $inventory=[pscustomobject]@{Adapters=@($ada,$geforce);Complete=$true}
 $record=[pscustomobject]@{Game=$evidenceRoot;LaunchExe='fixture.exe';NeuralGpuName=''}
 $resolved=ResolveOptiShadeNeuralPreparationAdapter $record $inventory
 Check ($resolved.State -eq 'candidate' -and $resolved.Adapter.Luid -ceq $ada.Luid -and $resolved.PSObject.Properties['Evidence']) 'Component preparation did not reuse the selected game recent renderer LUID before rejecting an otherwise ambiguous inventory.'
 $amdRenderer=Adapter 'AMD Radeon integrated graphics' '17' 0 0 1 0x1002
 $liveAmd=[pscustomobject]@{Adapters=@($ada,$amdRenderer);Complete=$true;PreferredRenderingLuid=$amdRenderer.Luid}
 $blocked=ResolveOptiShadeNeuralPreparationAdapter $record $liveAmd
 Check ($blocked.State -ne 'candidate') 'A prior NVIDIA log overrode the explicit AMD rendering-adapter hint and prepared NR for a different GPU.'
 $explicit=[pscustomobject]@{Game=$evidenceRoot;LaunchExe='fixture.exe';NeuralGpuName='';NeuralAdapterSelection='explicit';NeuralAdapter=(GetOptiShadeAdapterReceipt $geforce)}
 Check ((ResolveOptiShadeNeuralPreparationAdapter $explicit $inventory).Adapter.Luid -ceq $geforce.Luid) 'Previous renderer evidence overrode an explicit adapter selection.'
 $explicitWithRendererHint=[pscustomobject]@{Adapters=@($ada,$geforce,$amdRenderer);Complete=$true;PreferredRenderingLuid=$amdRenderer.Luid}
 Check ((ResolveOptiShadeNeuralPreparationAdapter $explicit $explicitWithRendererHint).Adapter.Luid -ceq $geforce.Luid) 'An observed AMD rendering adapter overrode the user-selected NVIDIA NR preparation adapter.'
 Check ((ResolveOptiShadeNeuralAdapter $explicit $explicitWithRendererHint).State -ne 'candidate') 'Preparation adapter selection was incorrectly treated as proof that the game renders on NVIDIA.'
 $staleLog=Get-Item -LiteralPath (Join-Path $evidenceRoot 'OptiScaler.log');$staleLog.LastWriteTimeUtc=[DateTime]::UtcNow.AddDays(-8)
 Check ((ResolveOptiShadeNeuralPreparationAdapter $record $inventory).State -eq 'ambiguous_adapter') 'Stale renderer evidence bypassed the multi-GPU selection safeguard.'
}finally{$evidenceLog=Join-Path $evidenceRoot 'OptiScaler.log';if(Test-Path -LiteralPath $evidenceLog){Remove-Item -LiteralPath $evidenceLog -Force};if(Test-Path -LiteralPath $evidenceRoot){Remove-Item -LiteralPath $evidenceRoot -Force}}
$unknown=Adapter 'NVIDIA RTX 5090' '16' 12 0;$unknown.ComputeCapabilityKnown=$false
Check ((ResolveOptiShadeAdapterCandidate ([pscustomobject]@{Adapters=@($unknown)})).State -eq 'unknown_architecture') 'A name alone authorized a model without driver architecture evidence.'
$amd=Adapter 'AMD Radeon RX 7900 XTX' '17' 0 0 0x744C 0x1002
Check ((ResolveOptiShadeAdapterCandidate ([pscustomobject]@{Adapters=@($amd,$ada)})).Adapter.Luid -eq '10') 'A hybrid AMD adapter selected or hid the NVIDIA model candidate.'
$software=Adapter 'NVIDIA RTX 5090' '18' 12 0;$software.Software=$true
Check ((ResolveOptiShadeAdapterCandidate ([pscustomobject]@{Adapters=@($software)})).State -eq 'unknown_adapter') 'Software adapter admitted to architecture-specific preparation.'
$actualFacts=${function:GetOptiShadeGpuFacts};function GetOptiShadeGpuFacts {[pscustomobject]@{Adapters=@();Error='fixture no driver'}}
try{Check ((ResolveOptiShadeAdapterCandidate ([pscustomobject]@{Names='NVIDIA RTX 5090'})).State -eq 'unknown_adapter') 'A WMI name substituted for missing driver identity.'}finally{Set-Item Function:GetOptiShadeGpuFacts $actualFacts}
foreach($pair in @(@($ada,'compat-3108'),@($turing,'compat-3108'),@($ampere,'compat-3108'),@($blackwell,'original-3108'))){
 $selection=GetNeuralDownload ([pscustomobject]@{Adapters=@($pair[0])}) ''
 Check ($selection.Id -eq $pair[1] -and $selection.Adapter.Luid -eq $pair[0].Luid) 'Model catalogue selection lost the exact measured adapter.'
}
Check ((ResolveOptiShadeNeuralAdapter $null ([pscustomobject]@{Adapters=@($ampere)})).State -eq 'candidate') 'RTX 30-series was rejected before model matching or runtime compatibility checks.'
$ampereModels=@(GetOptiShadeNeuralModelCatalog|Where-Object {30 -in $_.Families})
Check ($ampereModels.Count -ge 1) 'No pinned experimental NR model candidate is available for RTX 30-series.'
$failed=$false;try{$null=GetNeuralDownload $gpu ''}catch{$failed=$true};Check $failed 'Ambiguous adapters caused an arbitrary model download.'
$catalog=@(GetOptiShadeNeuralModelCatalog)
Check ($catalog.Count -eq 5 -and @($catalog.ModelHash|Select-Object -Unique).Count -eq 5) 'Model catalogue does not have unique pinned identities.'
Check (40 -notin @($catalog|Where-Object Id -eq 'v7-3109')[0].Families) 'V7 admitted Ada despite the retained provider limitation.'
$officialNr=@($catalog|Where-Object Id -eq 'official-3109');Check ($officialNr.Count -eq 1 -and $officialNr[0].Families.Count -eq 1 -and 50 -in $officialNr[0].Families -and $officialNr[0].Signed -and $officialNr[0].ModelHash -ceq '2BC19BC09A7B89DD44F73E2AC0108FCC586E2154BDD0830F242F4F040E28789F') 'Signed 310.9.16 model identity/family gate changed.'
$record=[pscustomobject]@{NeuralAdapter=(GetOptiShadeAdapterReceipt $ada)};$rebooted=Adapter $ada.Name '100' 8 9 $ada.DeviceId
Check ((ResolveOptiShadeNeuralAdapter $record ([pscustomobject]@{Adapters=@($rebooted)})).Adapter.Luid -eq '100') 'Unique measured device could not rebind after a reboot changed its LUID.'
Check ((ResolveOptiShadeNeuralAdapter $record ([pscustomobject]@{Adapters=@($rebooted,$twin)})).State -eq 'unknown_adapter') 'Reboot rebinding guessed between identical physical devices.'
Check ((ResolveOptiShadeNeuralAdapter $record ([pscustomobject]@{Adapters=@($rebooted);Complete=$false})).State -eq 'unknown_adapter') 'An incomplete post-reboot inventory guessed which identical physical GPU had changed its LUID.'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-gpu-'+[guid]::NewGuid().ToString('N'))
try{
 [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'payload/OptiShadeData/MFG'))
 WriteOptiShadeFixtureExecutable (Join-Path $fixture 'FlightSimulator2024.exe')
 foreach($name in @('source-build.json','RTXMFG.dll')){[IO.File]::WriteAllText((Join-Path $fixture ('payload/OptiShadeData/MFG/'+$name)),'fixture identity presence')}
 $manifest=[pscustomobject]@{Game=$fixture;LaunchExe=(Join-Path $fixture 'FlightSimulator2024.exe');Architecture='x64';RouteDLL='OptiShadeMSFS2024.dll';SourceMfg=$false;OptionalMfg=$false;Sm86Mfg=$false};$payload=Join-Path $fixture 'payload'
 Check ((GetOptiShadeInstallProviderDecision $manifest $payload ([pscustomobject]@{Adapters=@($ada)}) 'beta') -eq 'source') 'Ada professional adapter was sent to native Blackwell instead of the Ada provider candidate.'
 Check ((GetOptiShadeInstallProviderDecision $manifest $payload ([pscustomobject]@{Adapters=@($turing)}) 'beta') -eq 'sm86') 'Turing professional adapter was sent to native Blackwell.'
 Check ((GetOptiShadeInstallProviderDecision $manifest $payload ([pscustomobject]@{Adapters=@($ampere)}) 'stable') -eq 'sm86') 'The NR-only RTX 30 restriction accidentally removed its independent stable frame-generation provider path.'
 $manifest.OptionalMfg=$true
 Check ((GetOptiShadeInstallProviderDecision $manifest $payload ([pscustomobject]@{Adapters=@($geforce)}) 'beta') -eq 'legacy') 'Qualified recorded 4090 legacy path was changed by Auto preparation.'
 [IO.File]::Delete((Join-Path $fixture 'payload/OptiShadeData/MFG/RTXMFG.dll'))
 Check ((GetOptiShadeInstallProviderDecision $manifest $payload ([pscustomobject]@{Adapters=@($geforce)}) 'beta') -eq 'payload_missing') 'Legacy preservation bypassed the payload availability gate.'
 [IO.File]::Delete((Join-Path $fixture 'FlightSimulator2024.exe'))
 Check ((GetOptiShadeInstallProviderDecision $manifest $payload ([pscustomobject]@{Adapters=@($geforce)}) 'beta') -eq 'unsupported_game') 'Legacy preservation bypassed the still-required game route gate.'
}finally{if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}}
"GPU identity: $count assertions passed against production selection and catalogue functions; C# probe compiled. No Windows driver or GPU execution is claimed."
