$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/import-effects.ps1"
function Check($ok,$message){if(-not $ok){throw $message};"PASS: $message"}
$fixture=Join-Path $env:TEMP ('OptiShade-techniques-'+[guid]::NewGuid().ToString('N'))
$game=Join-Path $fixture 'Game';$shaders=Join-Path $game 'OptiShadeData/Shaders'
New-Item -ItemType Directory -Path $shaders -Force|Out-Null
Set-Content "$game/OptiScaler.ini" '[Menu]'
Copy-Item "$PSScriptRoot/../installer/DefaultEffects/Shaders/Packages/01/SweetFX/CAS.fx" "$shaders/CAS.fx"
$preset=Join-Path $fixture 'User-edited.ini';$catalogue=Join-Path $fixture 'Catalogue.ini'
Set-Content $catalogue "[SweetFX]`nEffectFiles=CAS.fx`nDownloadUrl=https://github.com/example/fixture/archive/main.zip"
Set-Content $preset "Techniques=CAS@CAS.fx`n[CAS.fx]`nSharpness=0.72`n; keep my edits"
$before=(Get-FileHash $preset).Hash
$warning=InstallPresetDependencies $preset $game $catalogue
Check ($warning -like '*CAS@CAS.fx*ContrastAdaptiveSharpen*compiled validation*') 'Existing CAS.fx is not mistaken for the requested CAS technique'
Check ((Get-FileHash $preset).Hash -eq $before) 'Preset and unknown uniform values remain byte-for-byte unchanged'
Set-Content $preset "Techniques=ContrastAdaptiveSharpen@CAS.fx`n[CAS.fx]`nContrast=0.1`nSharpening=0.5"
Check (-not(InstallPresetDependencies $preset $game $catalogue)) 'Exact source declaration passes offline advisory without claiming runtime compilation'
New-Item -ItemType Directory -Path "$shaders/Other" -Force|Out-Null
Set-Content "$shaders/Other/CAS.fx" 'technique CAS { pass {} }'
Check ((GetPresetImportWarning $preset $game) -like '*multiple installed files*') 'Same-basename effects are reported as ambiguous'
Set-Content $preset 'Techniques=Private@BaBa_DTLAA.fx,Private@Barbatos_NVSharpen.fx'
$warning=InstallPresetDependencies $preset $game $catalogue
Check ($warning -like '*BaBa_DTLAA.fx*Barbatos_NVSharpen.fx*ZIP*author*') 'Unknown sources retain preset and provide author-ZIP instructions'
Check (@(Get-ChildItem -LiteralPath $shaders -Recurse -File).Count -eq 2) 'Unknown dependency path does not guess or download a URL'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::Open((Join-Path $fixture 'Unsafe.zip'),'Create')
try{$e=$zip.CreateEntry('../escape.fx');$writer=[IO.StreamWriter]::new($e.Open());$writer.Write('technique Escape {}');$writer.Dispose()}finally{$zip.Dispose()}
$refused=$false;try{ImportEffectsArchive (Join-Path $fixture 'Unsafe.zip') $game}catch{$refused=$_.Exception.Message -like '*Unsafe archive*'}
Check $refused 'Technique checks do not weaken archive path validation'
