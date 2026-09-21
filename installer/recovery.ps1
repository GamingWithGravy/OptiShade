function ImportEffectsZip([string]$Archive,[string]$Game){
 AssertClosed $Game
 if(-not(Test-Path -LiteralPath (Join-Path $Game 'FlightSimulator2024.exe'))){throw 'Choose the MSFS Content folder first.'}
 Add-Type -AssemblyName System.IO.Compression.FileSystem
 $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
 $created=New-Object 'System.Collections.Generic.List[string]'
 try{
  $id=[guid]::NewGuid().ToString('N').Substring(0,8);$plan=@();$size=0L
  foreach($entry in $zip.Entries){
   $name=$entry.FullName.Replace('\','/');if($name.EndsWith('/')){continue}
   if($name.StartsWith('/') -or $name.Contains(':') -or $name.Split('/') -contains '..'){throw 'Unsafe archive path. Nothing was installed.'}
   $size+=$entry.Length;if($size -gt 256MB -or $zip.Entries.Count -gt 5000){throw 'Archive exceeds the 256 MB / 5000 entry limit.'}
   $ext=[IO.Path]::GetExtension($name).ToLowerInvariant()
   $relative=$null
   if($ext -eq '.ini'){$relative='Presets/Imported-'+$id+'/'+$name}
   elseif($ext -in @('.fx','.fxh')){$relative='Shaders/Imported-'+$id+'/'+($name -replace '^.*?(?i:reshade-shaders/)?(?i:shaders/)','')}
   elseif($ext -in @('.png','.jpg','.jpeg','.dds','.bmp','.tga')){$relative='Textures/Imported-'+$id+'/'+($name -replace '^.*?(?i:reshade-shaders/)?(?i:textures/)','')}
   if($relative){$dest=OwnedPath (Join-Path $Game 'OptiShadeData') $relative;$plan+=@{Entry=$entry;Dest=$dest}}
  }
  if(-not($plan|Where-Object {$_.Dest -match '\.(ini|fx)$'})){throw 'No INI presets or FX shaders were found.'}
  $names=@{};$shaderNames=@{}
  foreach($item in $plan){
   if($names.ContainsKey($item.Dest)){throw 'Duplicate archive destinations. Nothing was installed.'};$names[$item.Dest]=$true
   if(Test-Path -LiteralPath $item.Dest){throw 'Import destination already exists.'}
   if($item.Dest -match '\.fx$'){
    $leaf=[IO.Path]::GetFileName($item.Dest);if($shaderNames.ContainsKey($leaf)){throw "Duplicate shader name in archive: $leaf"};$shaderNames[$leaf]=$true
    if(Get-ChildItem -LiteralPath (Join-Path $Game 'OptiShadeData/Shaders') -Recurse -File -ErrorAction SilentlyContinue|Where-Object Name -eq $leaf){throw "Shader already installed: $leaf. Existing files were kept."}
   }
  }
  foreach($item in $plan){New-Item -ItemType Directory -Path (Split-Path $item.Dest) -Force|Out-Null;$created.Add($item.Dest);[IO.Compression.ZipFileExtensions]::ExtractToFile($item.Entry,$item.Dest,$false)}
  return $plan.Count
 }catch{foreach($file in $created){if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file -Force}};throw}finally{$zip.Dispose()}
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
 if(-not(Test-Path -LiteralPath (Join-Path $Game 'FlightSimulator2024.exe'))){throw 'Select your MSFS installation in Setup first.'}
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
 [ordered]@{InstallerVersion='0.20';Created=(Get-Date -Format o);GameFolder=$Game;InstallationState=(GetFusionInstallState $Store $Game);GPU=$gpu;NeuralModel=(GetNeuralRuntimeStatus $Game $gpu);Files=$files;Note='Stored files only. This report does not confirm loaded DLLs or rendered output. No presets or log contents included.'}
}

function InstallFusionCinema([string]$Game){
 AssertClosed $Game
 $base=Join-Path $PSScriptRoot 'FusionCinema'
 foreach($pair in @(@('Gravy_FusionCinema.fx','Shaders/Custom/Gravy_FusionCinema.fx'),@('Gravy - Fusion Cinema Custom v1.ini','Presets/Gravy - Fusion Cinema Custom v1.ini'),@('LICENSE','Licenses/FusionCinema-GPL3.txt'))){
  $dest=OwnedPath (Join-Path $Game 'OptiShadeData') $pair[1]
  if(-not(Test-Path -LiteralPath $dest)){New-Item -ItemType Directory -Path (Split-Path $dest) -Force|Out-Null;Copy-Item -LiteralPath (Join-Path $base $pair[0]) -Destination $dest}
 }
}
