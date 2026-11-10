param([string]$Root=(Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $Root 'Beta/package-staging.ps1')
. (Join-Path $Root 'Beta/installer/component-policy.ps1')
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('optishade-core-package-'+[guid]::NewGuid().ToString('N'))
try {
 [void][IO.Directory]::CreateDirectory($fixture)
 $manifest=Join-Path $Root 'Beta/package-inputs.json'
 Copy-Item -LiteralPath $manifest -Destination (Join-Path $fixture 'package-inputs.json')
 $entries=@((Get-Content -LiteralPath $manifest -Raw|ConvertFrom-Json).Groups.Effects)
 foreach($entry in $entries){
  $source=Join-Path $fixture $entry.Source
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($source))
  [IO.File]::WriteAllText($source,'declared input fixture: '+$entry.Source)
 }
 # Undeclared legacy helpers may still exist in a source checkout.
 $obsolete=Join-Path $fixture 'installer/DefaultEffects/Shaders/OptiShadeTaa/OptiShade_TAA_Guides.fx'
 [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($obsolete))
 [IO.File]::WriteAllText($obsolete,'legacy fixture, must not be staged')
 $destination=Join-Path $fixture 'payload/OptiShadeData'
 CopyOptiShadePackageInputs $fixture Effects $destination
 $actual=@(Get-ChildItem -LiteralPath $destination -Recurse -File -Force)
 if($actual.Count -ne $entries.Count){throw 'Clean payload inventory differs from the declared inputs'}
 foreach($entry in $entries){
  $copied=Join-Path $destination $entry.Target
  if([IO.File]::ReadAllText($copied) -ne ('declared input fixture: '+$entry.Source)){throw ('Wrong staged bytes: '+$entry.Target)}
 }
 if(Test-Path -LiteralPath (Join-Path $destination 'Shaders/OptiShadeTaa')){throw 'Loose legacy helper was packaged'}
 foreach($path in @('OptiShadeData/Shaders/OptiShadeTaa/OptiShade_TAA_Guides.fx','OptiShadeData/Textures/vort_BlueNoise.png')){
  if((GetOptiShadeAddonId $path) -ne 'Effects'){throw 'Old effect asset is still a mandatory core dependency'}
 }
 if((GetOptiShadeAddonId 'OptiShadeData/Shaders/LegacyNR/DLSS5_Feed.fx') -ne 'Neural'){throw 'Legacy feed lost independent Neural ownership'}
 if((GetOptiShadeAddonId 'OptiShadeData/Neural-runtime.json') -ne 'Neural'){throw 'Verified Neural preparation receipt lost component ownership'}
 'PASS: real package staging copies exactly the declared clean fixture inputs, excludes legacy guide source, and preserves independent Neural classification. No native shader/GPU test.'
} finally {
 if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}
}
