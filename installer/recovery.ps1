. "$PSScriptRoot/import-effects.ps1"
function ImportEffectsZip([string]$Archive,[string]$Game){AssertClosed $Game;ImportEffectsArchive $Archive $Game}
function TestOwnPreset([string]$Preset,[string]$Game,[string]$Catalogue){
 if([IO.Path]::GetExtension($Preset) -ne '.ini' -or -not(Test-Path -LiteralPath $Preset -PathType Leaf)){throw 'Choose an INI preset first.'}
 $names=@(GetPresetShaderNames $Preset)
 $text=[IO.File]::ReadAllText($Preset)
 if($text -notmatch '(?im)^Techniques='){throw 'This INI is not a ReShade look preset (Techniques is missing).'}
 if(-not $names.Count -and $text -match '(?im)^Techniques=\S'){throw 'This preset does not identify its FX files. Import the author''s shader ZIP first or use the full FX package.'}
 $null=GetPresetPackages @(GetMissingPresetShaders $Preset $Game) $Catalogue
}
function SaveOwnPreset([string]$Preset,[string]$Game,[string]$Catalogue){
 AssertClosed $Game;TestOwnPreset $Preset $Game $Catalogue
 $relative='OptiShadeData/Presets/Imported-'+[guid]::NewGuid().ToString('N')+'/'+[IO.Path]::GetFileName($Preset)
 $dest=OwnedPath $Game $relative;New-Item -ItemType Directory -Path (Split-Path $dest) -Force|Out-Null
 [IO.File]::Copy($Preset,$dest,$false)
 return $relative
}
function ResetOptiShadeSettings([string]$Game,[string]$Payload,[string]$Store){
 AssertClosed $Game
 $mp=ManifestPath $Store $Game
 if(-not(Test-Path -LiteralPath $mp)){throw 'No recorded OptiShade installation for this folder.'}
 $m=Get-Content -LiteralPath $mp -Raw|ConvertFrom-Json
 if($m.Status -ne 'Installed'){throw 'Install OptiShade first.'}
 $backup=Join-Path (Split-Path $mp) ('Settings-'+[guid]::NewGuid().ToString('N'))
 New-Item -ItemType Directory -Path $backup|Out-Null
 foreach($name in @('OptiScaler.ini','ReShade.ini')){ $dest=OwnedPath $Game $name;if(Test-Path -LiteralPath $dest){Copy-Item -LiteralPath $dest -Destination (Join-Path $backup $name)} }
 try{
  foreach($name in @('OptiScaler.ini','ReShade.ini')){Copy-Item -LiteralPath (Join-Path $Payload $name) -Destination (OwnedPath $Game $name) -Force}
  $look=OwnedPath $Game 'OptiShadeData/Presets/OptiShade recovery.ini'
  if(Test-Path -LiteralPath $look){$look=OwnedPath $Game ('OptiShadeData/Presets/OptiShade recovery-'+[guid]::NewGuid().ToString('N')+'.ini')}
  "Techniques=`r`nTechniqueSorting="|Set-Content -LiteralPath $look -Encoding UTF8
  $config=OwnedPath $Game 'ReShade.ini';$text=Get-Content -LiteralPath $config -Raw
  $text=$text -replace '(?m)^PresetPath=.*$',('PresetPath=.\'+$look.Substring((FullPath $Game).Length+1))
  [IO.File]::WriteAllText($config,$text,[Text.UTF8Encoding]::new($false))
 }catch{foreach($name in @('OptiScaler.ini','ReShade.ini')){if(Test-Path -LiteralPath (Join-Path $backup $name)){Copy-Item -LiteralPath (Join-Path $backup $name) -Destination (OwnedPath $Game $name) -Force}};throw}
 return $backup
}
function GetOptiShadeSupportReport([string]$Game,[string]$Store){
 $Game=ResolveFusionInstallFolder $Game
 if(-not(GetMsfsTitle $Game)){throw 'Select your MSFS installation in Setup first.'}
 $gpu=GetFusionGpu
 $files=@()
 # Bounded metadata only: no presets or log contents.
 $names=@('winmm.dll','dxgi.dll','d3d12.dll','version.dll','dbghelp.dll','wininet.dll','winhttp.dll','dinput8.dll','OptiScaler.dll','ReShade64.dll','nvngx_dlssnr.dll','nvngx.dll_dlssnr.dll','nvngx_dlss.dll','nvngx_dlssg.dll','nvngx_dlssd.dll')
 foreach($base in @('','OptiShadeData/Engine','OptiShadeData/Engine/streamline')){
  $relativeNames=if($base -like '*streamline'){@('sl.interposer.dll','sl.common.dll','sl.dlss_g.dll','sl.reflex.dll','sl.pcl.dll','nvngx_dlssg.dll')}else{$names}
  foreach($name in $relativeNames){
   $relative=if($base){$base+'/'+$name}else{$name}
   $file=OwnedPath $Game $relative
   if(Test-Path -LiteralPath $file -PathType Leaf){
    try{$item=Get-Item -LiteralPath $file;$files+=@{Path=$relative;Bytes=$item.Length;Version=$item.VersionInfo.FileVersion;SHA256=(HashFile $file)}}
    catch{$files+=@{Path=$relative;Error='File could not be read'}}
   }
  }
 }
 [ordered]@{InstallerVersion='0.20.9';Created=(Get-Date -Format o);GameFolder=$Game;InstallationState=(GetFusionInstallState $Store $Game);GPU=$gpu;NeuralModel=(GetNeuralRuntimeStatus $Game $gpu);Files=$files;Note='Stored files only. This report does not confirm loaded DLLs or rendered output. No presets or log contents included.'}
}

function InstallFusionCinema([string]$Game){
 AssertClosed $Game
 $base=Join-Path $PSScriptRoot 'FusionCinema'
 foreach($pair in @(@('Gravy_FusionCinema.fx','Shaders/Custom/Gravy_FusionCinema.fx'),@('Gravy - Fusion Cinema Custom v1.ini','Presets/Gravy - Fusion Cinema Custom v1.ini'),@('LICENSE','Licenses/FusionCinema-GPL3.txt'))){
  $dest=OwnedPath (Join-Path $Game 'OptiShadeData') $pair[1]
  if(-not(Test-Path -LiteralPath $dest)){New-Item -ItemType Directory -Path (Split-Path $dest) -Force|Out-Null;Copy-Item -LiteralPath (Join-Path $base $pair[0]) -Destination $dest}
 }
}
