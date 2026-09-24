param([Alias('Archive')][string]$ImportArchive,[Alias('Game')][string]$ImportGame,[Alias('Result')][string]$ImportResult,[Alias('Preset')][string]$ImportPreset)
$ErrorActionPreference='Stop'
function ImportSafePath([string]$Root,[string]$Relative){
 $base=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')
 $path=[IO.Path]::GetFullPath((Join-Path $base $Relative))
 if(-not $path.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe archive destination.'}
 for($check=$path;$check;$check=Split-Path $check -Parent){if(Test-Path -LiteralPath $check){if((Get-Item -LiteralPath $check -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked folders are not supported for import.'}}}
 return $path
}
function ImportEffectsArchive([string]$Archive,[string]$Game,[string[]]$OnlyShaders=@(),[switch]$HeadersOnly){
 if(-not(Test-Path -LiteralPath (Join-Path $Game 'OptiScaler.ini'))){throw 'Install OptiShade before importing a ZIP.'}
 Add-Type -AssemblyName System.IO.Compression.FileSystem
 if((Get-Item -LiteralPath $Archive).Length -gt 256MB){throw 'Archive exceeds the 256 MB limit.'}
 $zip=[IO.Compression.ZipFile]::OpenRead($Archive);$created=New-Object 'System.Collections.Generic.List[string]'
 try{
  $id=[guid]::NewGuid().ToString('N');$plan=@();$size=0L;$names=@{};$shaderNames=@{}
  if($zip.Entries.Count -gt 5000){throw 'Archive exceeds the 5000 entry limit.'}
  foreach($entry in $zip.Entries){
   $name=$entry.FullName.Replace('\','/');$parts=$name.TrimEnd('/').Split('/')
   if($name.StartsWith('/') -or $name -match '[:<>"|?*\x00-\x1f]' -or @($parts|Where-Object {$_ -in @('','..','.') -or $_ -match '[. ]$' -or $_ -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'}).Count){throw 'Unsafe archive path. Nothing was installed.'}
   $size+=$entry.Length;if($size -gt 256MB){throw 'Archive exceeds the 256 MB expanded limit.'}
   if($name.EndsWith('/')){continue}
   $ext=[IO.Path]::GetExtension($name).ToLowerInvariant();$relative=$null
   if($OnlyShaders.Count -or $HeadersOnly){if($ext -eq '.ini'){continue};if($ext -eq '.fx' -and ($HeadersOnly -or [IO.Path]::GetFileName($name) -notin $OnlyShaders)){continue}}
   if($ext -eq '.ini' -and [IO.Path]::GetFileName($name) -notin @('ReShade.ini','OptiScaler.ini')){$relative='Presets/Imported-'+$id+'/'+$name}
   elseif($ext -in @('.fx','.fxh','.h','.hlsl')){$relative='Shaders/Imported-'+$id+'/'+($name -replace '^.*?(?i:shaders/)','')}
   elseif($ext -in @('.png','.jpg','.jpeg','.dds','.bmp','.tga','.cube','.lut')){$relative='Textures/Imported-'+$id+'/'+($name -replace '^.*?(?i:textures/)','')}
   elseif([IO.Path]::GetFileName($name) -match '^(?i:LICENSE|COPYING|NOTICE)(?:\.|$)'){$relative='Licenses/Imported-'+$id+'/'+$name}
   if(-not $relative){continue}
   if($ext -in @('.ini','.fx','.fxh')){$relative=[IO.Path]::ChangeExtension($relative,$ext)}
   $dest=ImportSafePath (Join-Path $Game 'OptiShadeData') $relative
   if($names.ContainsKey($dest) -or (Test-Path -LiteralPath $dest)){throw 'Duplicate archive destination. Existing files were kept.'};$names[$dest]=$true
   if($ext -eq '.fx'){
    $leaf=[IO.Path]::GetFileName($name)
    if($shaderNames.ContainsKey($leaf) -or (Get-ChildItem -LiteralPath (Join-Path $Game 'OptiShadeData/Shaders') -Recurse -File -ErrorAction SilentlyContinue|Where-Object Name -eq $leaf)){throw "Shader already installed or duplicated in archive: $leaf. Existing files were kept."}
    $shaderNames[$leaf]=$true
   }
   $plan+=@{Entry=$entry;Dest=$dest;Relative=$relative}
  }
  if(-not $HeadersOnly -and -not($plan|Where-Object {$_.Dest -match '\.(ini|fx)$'})){throw 'No INI presets or FX shaders were found.'}
  foreach($required in $OnlyShaders){if(-not($plan|Where-Object {[IO.Path]::GetFileName($_.Dest) -eq $required})){throw "The package no longer contains $required. Nothing from this package was installed."}}
  foreach($item in $plan){
   $dest=ImportSafePath (Join-Path $Game 'OptiShadeData') $item.Relative
   New-Item -ItemType Directory -Path (Split-Path $dest) -Force|Out-Null
   # CreateNew is atomic: a file created by another process is never overwritten or removed.
   $output=[IO.File]::Open($dest,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$created.Add($dest)
   try{
    $input=$item.Entry.Open()
    try{$buffer=New-Object byte[] 65536;$written=0L;while(($n=$input.Read($buffer,0,$buffer.Length)) -gt 0){$written+=$n;if($written -gt $item.Entry.Length){throw 'Archive entry exceeds its declared size.'};$output.Write($buffer,0,$n)};if($written -ne $item.Entry.Length){throw 'Archive entry is incomplete.'}}
    finally{$input.Dispose()}
   }finally{$output.Dispose()}
  }
  return $plan.Count
 }catch{foreach($file in $created){if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file -Force}};throw}finally{$zip.Dispose()}
}
function GetPresetShaderNames([string]$Preset){
 if((Get-Item -LiteralPath $Preset).Length -gt 4MB){throw 'Preset exceeds the 4 MB limit.'}
 $text=[IO.File]::ReadAllText($Preset)
 # Qualified techniques identify the shader reliably; legacy unqualified names do not.
 @([regex]::Matches($text,'(?im)(?:@|^\[)([^@,;\[\]\r\n/\\]+\.fx)(?=,|\]|\s*$)')|ForEach-Object {$_.Groups[1].Value.Trim()}|Select-Object -Unique)
}
function GetMissingPresetShaders([string]$Preset,[string]$Game){
 $installed=@(Get-ChildItem -LiteralPath (Join-Path $Game 'OptiShadeData/Shaders') -Filter '*.fx' -Recurse -File -ErrorAction SilentlyContinue|ForEach-Object Name)
 @(GetPresetShaderNames $Preset|Where-Object {$_ -notin $installed})
}
function GetPresetPackages([string[]]$Missing,[string]$Catalogue){
 $packages=@();$current=$null
 foreach($line in Get-Content -LiteralPath $Catalogue){if($line -match '^\[(.+)\]$'){$current=@{Id=$Matches[1]};$packages+=,$current}elseif($current -and $line -match '^([^=]+)=(.*)$'){$current[$Matches[1]]=$Matches[2]}}
 $selected=@{}
 foreach($shader in $Missing){
  $sources=@($packages|Where-Object {$shader -in ($_.EffectFiles -split ',') -and $shader -notin ($_.DenyEffectFiles -split ',')})
  if($sources.Count -ne 1){throw "No unique catalogue source for $shader. Import the author's ZIP instead; no download was started."}
  $pkg=$sources[0];if(-not $selected.ContainsKey($pkg.Id)){$selected[$pkg.Id]=@{Package=$pkg;Shaders=@()}};$selected[$pkg.Id].Shaders+=,$shader
 }
 return $selected
}
function InstallPresetDependencies([string]$Preset,[string]$Game,[string]$Catalogue){
 $missing=@(GetMissingPresetShaders $Preset $Game);if(-not $missing.Count){return}
 $selected=GetPresetPackages $missing $Catalogue
 [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
 $downloads=ImportSafePath (Join-Path $Game 'OptiShadeData') ('Downloads/Import-'+[guid]::NewGuid().ToString('N'))
 New-Item -ItemType Directory -Path $downloads -Force|Out-Null
 try{
  foreach($selection in $selected.Values){
   $uri=[uri]$selection.Package.DownloadUrl
   if($uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com' -or $uri.AbsolutePath -notmatch '^/[^/]+/[^/]+/archive/.+\.zip$'){throw 'Unexpected catalogue download URL.'}
   $zip=Join-Path $downloads ($selection.Package.Id+'.zip')
   # Stream with hard bounds; a partial archive never reaches the importer.
   $request=[Net.HttpWebRequest]::Create($uri);$request.UserAgent='OptiShade/0.20.11';$request.Timeout=30000;$request.ReadWriteTimeout=30000
   $response=$request.GetResponse()
   try{
    if($response.ResponseUri.Scheme -ne 'https' -or $response.ResponseUri.Host -notin @('github.com','codeload.github.com')){throw 'Unexpected download redirect.'}
    $stream=$response.GetResponseStream();$out=[IO.File]::Create($zip)
    try{$buffer=New-Object byte[] 65536;$bytes=0L;$timer=[Diagnostics.Stopwatch]::StartNew();while(($n=$stream.Read($buffer,0,$buffer.Length)) -gt 0){$bytes+=$n;if($bytes -gt 256MB -or $timer.Elapsed.TotalSeconds -gt 120){throw 'Shader download exceeded its size or time limit.'};$out.Write($buffer,0,$n)}}finally{$out.Dispose();$stream.Dispose()}
   }finally{$response.Dispose()}
   $null=ImportEffectsArchive $zip $Game -OnlyShaders $selection.Shaders
  }
  foreach($header in @('ReShade.fxh','ReShadeUI.fxh')){
   $target=ImportSafePath (Join-Path $Game 'OptiShadeData') ('Shaders/'+$header)
   if(-not(Test-Path -LiteralPath $target)){
    $source=Join-Path $PSScriptRoot ('StandardHeaders/'+$header)
    if(-not(Test-Path -LiteralPath $source)){$source=Join-Path $Game ('OptiShadeData/Tools/StandardHeaders/'+$header)}
    [IO.File]::Copy($source,$target,$false)
   }
  }
  $remaining=@(GetMissingPresetShaders $Preset $Game);if($remaining.Count){throw ('Still missing: '+($remaining -join ', '))}
 }finally{
  # Only delete transport files created inside this invocation's verified folder.
  foreach($file in Get-ChildItem -LiteralPath $downloads -File){Remove-Item -LiteralPath (ImportSafePath $downloads $file.Name) -Force}
  Remove-Item -LiteralPath $downloads
 }
}
if($ImportResult){
 # The in-game caller supplies only a result leaf inside the managed folder.
 $resultPath=ImportSafePath (Join-Path $ImportGame 'OptiShadeData') $ImportResult
 try{
  if($ImportPreset){InstallPresetDependencies $ImportPreset $ImportGame (Join-Path $PSScriptRoot 'EffectPackages.ini');$message='OK: Missing shaders installed. Loading the imported look; check shader compilation status.'}
  else{$count=ImportEffectsArchive $ImportArchive $ImportGame;$message="OK: Imported $count files into OptiShadeData. Choose an imported INI under Saved look; required shaders must compile. Your current look is unchanged."}
 }
 catch{$message='ERROR: '+$_.Exception.Message}
 [IO.File]::WriteAllText($resultPath,$message,[Text.UTF8Encoding]::new($false))
 if($message.StartsWith('ERROR:')){exit 1}
}
