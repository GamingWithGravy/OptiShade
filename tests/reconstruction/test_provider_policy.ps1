param([string]$ControlTests)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/fixtures/windows_pe.ps1"
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $root 'Beta/installer/ownership.ps1')
. (Join-Path $root 'Beta/installer/provider-policy.ps1')
$count=0
if(-not $ControlTests){$candidate=Join-Path $root 'test-results/control-tests.exe';if(Test-Path -LiteralPath $candidate -PathType Leaf){$ControlTests=$candidate}}
if($ControlTests){
 if(-not(Test-Path -LiteralPath $ControlTests -PathType Leaf)){throw 'Compiled control-test executable was not supplied.'}
 foreach($row in (& $ControlTests policy)){
  $v=$row.Split(',');$f=[int]$v[2]
  $actual=GetOptiShadeProviderDecision $v[0] ([int]$v[1]) ([bool]($f-band 1)) ([bool]($f-band 2)) ([bool]($f-band 4)) ([bool]($f-band 8)) ([bool]($f-band 16)) ([bool]($f-band 32)) ([bool]($f-band 128)) ([bool]($f-band 64))
  if($actual -ne $v[3]){throw "Native/installer policy divergence: $row -> $actual"};$count++
 }
}
if($ControlTests -and $count -ne 4608){throw 'Policy fixture did not execute complete matrix'}
foreach($case in @(
 @{Channel='stable';Family=20;Source=$false;Legacy=$false;Supported=$true;Ambiguous=$false;SourceAvailable=$true;LegacyAvailable=$true;Sm86Receipt=$false;Sm86Available=$true;Expected='sm86'},
 @{Channel='beta';Family=30;Source=$false;Legacy=$false;Supported=$true;Ambiguous=$false;SourceAvailable=$true;LegacyAvailable=$true;Sm86Receipt=$false;Sm86Available=$true;Expected='sm86'},
 @{Channel='stable';Family=20;Source=$true;Legacy=$false;Supported=$true;Ambiguous=$false;SourceAvailable=$true;LegacyAvailable=$true;Sm86Receipt=$false;Sm86Available=$true;Expected='sm86'},
 @{Channel='beta';Family=30;Source=$false;Legacy=$false;Supported=$true;Ambiguous=$false;SourceAvailable=$true;LegacyAvailable=$true;Sm86Receipt=$true;Sm86Available=$true;Expected='sm86'},
 @{Channel='beta';Family=30;Source=$false;Legacy=$false;Supported=$true;Ambiguous=$false;SourceAvailable=$true;LegacyAvailable=$true;Sm86Receipt=$false;Sm86Available=$false;Expected='payload_missing'},
 @{Channel='stable';Family=40;Source=$false;Legacy=$false;Supported=$true;Ambiguous=$false;SourceAvailable=$true;LegacyAvailable=$true;Sm86Receipt=$false;Sm86Available=$true;Expected='legacy'},
 @{Channel='beta';Family=40;Source=$false;Legacy=$false;Supported=$true;Ambiguous=$false;SourceAvailable=$true;LegacyAvailable=$true;Sm86Receipt=$false;Sm86Available=$true;Expected='source'},
 @{Channel='beta';Family=40;Source=$false;Legacy=$true;Supported=$true;Ambiguous=$false;SourceAvailable=$true;LegacyAvailable=$true;Sm86Receipt=$false;Sm86Available=$true;Expected='source'},
 @{Channel='stable';Family=40;Source=$false;Legacy=$true;Supported=$true;Ambiguous=$false;SourceAvailable=$true;LegacyAvailable=$true;Sm86Receipt=$false;Sm86Available=$true;Expected='legacy'},
 @{Channel='beta';Family=50;Source=$false;Legacy=$false;Supported=$true;Ambiguous=$false;SourceAvailable=$true;LegacyAvailable=$true;Sm86Receipt=$false;Sm86Available=$true;Expected='native'},
 @{Channel='stable';Family=20;Source=$false;Legacy=$true;Supported=$true;Ambiguous=$false;SourceAvailable=$true;LegacyAvailable=$true;Sm86Receipt=$false;Sm86Available=$true;Expected='receipt_adapter_mismatch'}
)){
 $actual=GetOptiShadeProviderDecision $case.Channel $case.Family $case.Source $case.Legacy $case.Supported $case.Ambiguous $case.SourceAvailable $case.LegacyAvailable $case.Sm86Receipt $case.Sm86Available
 if($actual -ne $case.Expected){throw "Unexpected provider policy for $($case.Channel) RTX $($case.Family): $actual"}
}
$nativeMessage=GetOptiShadeMfgPreparationMessage 'native'
if($nativeMessage -notmatch 'game-native provider' -or $nativeMessage -notmatch 'capability and activation are checked in-game'){throw 'Native RTX 50 routing must be selectable while live capability remains an in-game check.'}
if($nativeMessage -notmatch 'No separate provider DLL is needed'){throw 'RTX 50 native routing did not explain that no separate MFG provider is installed.'}
$sourceAdmission=GetOptiShadeMfgComponentAdmission 'unsupported_game' 'source'
$sm86Admission=GetOptiShadeMfgComponentAdmission 'unsupported_game' 'sm86'
$legacyBlockedAdmission=GetOptiShadeMfgComponentAdmission 'unsupported_game' 'legacy' $false
$legacyReadyAdmission=GetOptiShadeMfgComponentAdmission 'unsupported_game' 'legacy' $true
$nativeAdmission=GetOptiShadeMfgComponentAdmission 'native' 'native'
$unknownAdmission=GetOptiShadeMfgComponentAdmission 'unknown_adapter' 'unknown_adapter'
if(-not $sourceAdmission.CanPrepare -or $sourceAdmission.State -ne 'preparable' -or $sourceAdmission.RequiresGameLoader){throw 'Source MFG preparation was incorrectly blocked by an unavailable game/API route or loader alias.'}
if(-not $sm86Admission.CanPrepare -or $sm86Admission.State -ne 'preparable' -or $sm86Admission.RequiresGameLoader){throw 'OptiScaler-hosted SM86 preparation was incorrectly coupled to game-folder imports.'}
if(-not $legacyBlockedAdmission.CanPrepare -or $legacyBlockedAdmission.State -ne 'deferred' -or $legacyBlockedAdmission.RequiresGameLoader){throw 'MFG selection must remain available without an inspected safe loader, while deferring provider mutation.'}
if(-not $legacyReadyAdmission.CanPrepare -or $legacyReadyAdmission.State -ne 'preparable' -or -not $legacyReadyAdmission.RequiresGameLoader){throw 'Legacy MFG should be available when its safe loader alias is verified.'}
if(-not $nativeAdmission.CanPrepare -or $nativeAdmission.State -ne 'native'){throw 'Native RTX 50 MFG must remain selectable without adding an unnecessary separate provider.'}
if(-not $unknownAdmission.CanPrepare -or $unknownAdmission.State -ne 'deferred'){throw 'Unknown adapter state must remain selectable with provider changes deferred to in-game detection.'}
$identityFixture=Join-Path ([IO.Path]::GetTempPath()) ('optishade-channel-identity-'+[guid]::NewGuid().ToString('N')+'.json')
try{
 @{Version='1.0.77-beta.5';Channel='beta';PrivateTesting=$true;PrivateTestNumber=196}|ConvertTo-Json|Set-Content -LiteralPath $identityFixture -Encoding UTF8
 if((GetOptiShadeChannelChangeLabel 'P1.0.77' '1.0.77-beta.5' $identityFixture) -cne 'Install private test build'){throw 'A private candidate was labeled as a public beta switch.'}
 @{Version='1.0.77-beta.5';Channel='beta';PrivateTesting=$false;PrivateTestNumber=0}|ConvertTo-Json|Set-Content -LiteralPath $identityFixture -Encoding UTF8
 if((GetOptiShadeChannelChangeLabel 'P1.0.77' '1.0.77-beta.5' $identityFixture) -cne 'Switch to beta'){throw 'A public prerelease channel transition lost its beta label.'}
 if((GetOptiShadeChannelChangeLabel '1.0.77-beta.5' 'P1.0.77' $identityFixture) -cne 'Switch to stable'){throw 'A return to stable lost its channel label.'}
}finally{if(Test-Path -LiteralPath $identityFixture){Remove-Item -LiteralPath $identityFixture -Force}}
foreach($channel in @('Beta','Stable')){
 $tokens=$null;$errors=$null
 $entry=Join-Path $root "$channel/installer/mfg.ps1"
 if(Test-Path -LiteralPath $entry){. $entry;[void][Management.Automation.Language.Parser]::ParseFile($entry,[ref]$tokens,[ref]$errors)}
 else{[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $root "$channel/installer/provider-policy.ps1"),[ref]$tokens,[ref]$errors)}
 if($errors.Count){throw ($errors|Out-String)}
 $channelText=[IO.File]::ReadAllText((Join-Path $root "$channel/installer/provider-policy.json")).Replace("`r`n","`n")
 $sharedText=[IO.File]::ReadAllText((Join-Path $root 'Beta/shared/provider-policy.json')).Replace("`r`n","`n")
 if($channelText -cne $sharedText){throw 'Channel policy is stale'}
}
if([IO.Path]::DirectorySeparatorChar -ne '\'){
 function OwnedPath([string]$Root,[string]$Relative){$base=[IO.Path]::GetFullPath($Root).TrimEnd('/')+'/';$target=[IO.Path]::GetFullPath((Join-Path $Root $Relative));if(-not $target.StartsWith($base,[StringComparison]::Ordinal)){throw 'Fixture path escape.'};return $target}
}
function FixtureAdaAdapter([string]$Name,[string]$Luid,[int]$Device){[pscustomobject]@{Complete=$true;Adapters=@([pscustomobject]@{Name=$Name;Luid=$Luid;VendorId=0x10DE;DeviceId=$Device;SubSystemId=1;Software=$false;ComputeCapabilityKnown=$true;ComputeMajor=8;ComputeMinor=9;Family=40;DriverVersion='fixture'})}}
 $fixture=Join-Path ([IO.Path]::GetTempPath()) ('optishade-provider-model-'+[guid]::NewGuid().ToString('N'))
try{
 $game=Join-Path $fixture 'game';$payload=Join-Path $fixture 'payload';$mfg=Join-Path $payload 'OptiShadeData/MFG'
 [void][IO.Directory]::CreateDirectory($game);[void][IO.Directory]::CreateDirectory($mfg)
 WriteOptiShadeFixtureExecutable (Join-Path $game 'FlightSimulator2024.exe')
 [IO.File]::WriteAllText((Join-Path $mfg 'source-build.json'),'fixture');[IO.File]::WriteAllText((Join-Path $mfg 'RTXMFG.dll'),'fixture')
 $manifest=[pscustomobject]@{Game=$game;LaunchExe=(Join-Path $game 'FlightSimulator2024.exe');Architecture='x64';RouteDLL='OptiShadeMSFS2024.dll';SourceMfg=$false;OptionalMfg=$true;Sm86Mfg=$false}
 $models4070=@('NVIDIA GeForce RTX 4070','NVIDIA GeForce RTX 4070 Ti','NVIDIA GeForce RTX 4070 SUPER','NVIDIA GeForce RTX 4070 Ti SUPER')
 $routes4070=@(foreach($model in $models4070){GetOptiShadeInstallProviderDecision $manifest $payload (FixtureAdaAdapter $model ('47'+$models4070.IndexOf($model)) 0x2783) 'beta'})
 $route4090=GetOptiShadeInstallProviderDecision $manifest $payload (FixtureAdaAdapter 'NVIDIA GeForce RTX 4090' '49' 0x2684) 'beta'
 if(@($routes4070|Where-Object{$_ -ne 'source'}).Count -gt 0 -or $route4090 -ne 'legacy'){throw "Beta repair provider changed unexpectedly: RTX 4070 family=$($routes4070 -join ','); RTX 4090=$route4090"}
}finally{if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}}
 if($ControlTests){"$count native/PowerShell policy parity cases passed; RTX 20/30 route selection, source-receipt migration, unavailable payload and family-specific routes match. Available channel entry points parse and channel policy snapshots match. No installation modified."}else{'PASS: RTX 20/30 route selection, source-receipt migration, unavailable payload, family-specific routes and channel policy snapshots; native parity matrix skipped because no compiled control-test executable was available.'}
