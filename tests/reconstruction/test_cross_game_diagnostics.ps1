$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $root 'Beta/installer/ownership.ps1')
. (Join-Path $root 'Beta/installer/recovery.ps1')
. (Join-Path $root 'Beta/installer/diagnostics.ps1')

$fixture=Join-Path ([IO.Path]::GetTempPath()) ('optishade-cross-game-diagnostics-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
try{
 function ResolveFusionInstallFolder([string]$Path){return [IO.Path]::GetFullPath($Path)}
 function GetFusionGpu{return [pscustomobject]@{Names='Fixture NVIDIA adapter';Known=$true}}
 function GetNeuralRuntimeStatus([string]$Game,$Gpu){return [pscustomobject]@{State='Fixture only';Message='No runtime claim'}}
 function GetFusionInstallState([string]$Store,[string]$Game){return 'Installed'}
 function GetBundledOptiShadeVersion{return '1.0.fixture'}
 function GetOptiShadeMfgLoaderAliases{return @('version.dll','dinput8.dll')}

 $other=Join-Path ($fixture+'-other') 'ForzaFixture.exe'
 [void][IO.Directory]::CreateDirectory((Split-Path $other))
 $selected=Join-Path $fixture 'ForzaFixture.exe'
 [IO.File]::WriteAllText($selected,'fixture')
 [IO.File]::WriteAllText($other,'other fixture')

 $report=GetOptiShadeSupportReport $fixture (Join-Path $fixture 'store')
 if($report.GameFolder -ne $fixture -or $report.InstallationState -ne 'Installed'){throw 'Generic selected game was rejected by the support-report collector.'}

 $exact=GetOptiShadeProcessAssociation $fixture 'ForzaFixture' $selected @() $selected
 if($exact.State -ne 'Matched' -or $exact.Reason -notmatch 'Exact selected rendering executable path'){throw 'Exact generic rendering executable path was not associated.'}
 $sameNameOtherInstall=GetOptiShadeProcessAssociation $fixture 'ForzaFixture' $other @() $selected
 if($sameNameOtherInstall.State -ne 'Other installation'){throw 'Same-named executable from another store/library folder was incorrectly associated.'}
 $unknownPath=GetOptiShadeProcessAssociation $fixture 'ForzaFixture' 'Unknown' @() $selected
 if($unknownPath.State -ne 'Unknown'){throw 'Process name alone was accepted when executable path was unavailable.'}
 $unknownExpected=GetOptiShadeProcessAssociation $fixture 'ForzaFixture' $selected @()
 if($unknownExpected.State -ne 'Unknown'){throw 'Generic process was associated without a recorded selected executable.'}
 'Cross-game diagnostics: generic folder accepted; exact executable required; same-name foreign install and unknown process path rejected.'
}finally{
 foreach($path in @($fixture,($fixture+'-other'))){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}}
}
