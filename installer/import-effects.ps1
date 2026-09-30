param([Alias('Archive')][string]$ImportArchive,[Alias('Game')][string]$ImportGame,[Alias('Result')][string]$ImportResult,[Alias('Preset')][string]$ImportPreset)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/store-paths.ps1"
function ResolveImportRoot([string]$Root){
 $rootPath=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')
 # Resolve only the simulator's Store alias; never accept links inside FX data.
 if($rootPath -match '^(?<package>.+[\\/]WindowsApps[\\/]Microsoft\.(?<edition>FlightSimulator|Limitless)_[^\\/]+)(?<suffix>(?:[\\/].*)?)$'){
  $package=$Matches.package;$suffix=$Matches.suffix;$edition=$Matches.edition
  $target=ResolveSimulatorStoreTarget $package
  $exe=if($edition -eq 'Limitless'){'FlightSimulator2024.exe'}else{'FlightSimulator.exe'}
  if(-not(Test-Path -LiteralPath (Join-Path $target $exe) -PathType Leaf)){throw 'The simulator link target is missing its game executable.'}
  $rootPath=[IO.Path]::GetFullPath($target.TrimEnd('\','/')+$suffix).TrimEnd('\','/')
 }
 return $rootPath
}
function ImportSafePath([string]$Root,[string]$Relative){
 $base=ResolveImportRoot $Root
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
 # TechniqueSorting and saved parameter sections also contain disabled effects.
 # Only the enabled Techniques list defines dependencies of this look.
 $active=[regex]::Match($text,'(?im)^\s*Techniques\s*=([^\r\n]*)').Groups[1].Value
 @([regex]::Matches($active,'(?i)@([^@,;\[\]\r\n/\\]+\.fx)(?=,|\s*$)')|ForEach-Object {$_.Groups[1].Value.Trim()}|Select-Object -Unique)
}
function GetMissingPresetShaders([string]$Preset,[string]$Game){
 $installed=@(Get-ChildItem -LiteralPath (Join-Path $Game 'OptiShadeData/Shaders') -Filter '*.fx' -Recurse -File -ErrorAction SilentlyContinue|ForEach-Object Name)
 @(GetPresetShaderNames $Preset|Where-Object {$_ -notin $installed})
}
function GetPresetTechniqueWarnings([string]$Preset,[string]$Game){
 # This is an offline advisory only. Macros/includes can declare techniques;
 # the live compiled-identity check is authoritative after loading the preset.
 $text=[IO.File]::ReadAllText($Preset)
 $active=[regex]::Match($text,'(?im)^\s*Techniques\s*=([^\r\n]*)').Groups[1].Value
 $data=ResolveImportRoot (Join-Path $Game 'OptiShadeData')
 $files=@(Get-ChildItem -LiteralPath (Join-Path $data 'Shaders') -Filter '*.fx' -Recurse -File -ErrorAction SilentlyContinue)
 foreach($identity in @($active -split ','|ForEach-Object {$_.Trim()}|Where-Object {$_}|Select-Object -Unique)){
  if($identity -notmatch '^(?<technique>[^@,;\[\]\r\n/\\]+)@(?<effect>[^@,;\[\]\r\n/\\]+\.fx)$'){continue}
  $name=$Matches.technique;$effect=$Matches.effect
  $matches=@($files|Where-Object Name -eq $effect)
  if($matches.Count -gt 1){"$identity (multiple installed files share this FX name)";continue}
  if($matches.Count -ne 1){continue}
  $safe=ImportSafePath $data $matches[0].FullName.Substring($data.Length+1)
  if($matches[0].Length -gt 4MB){continue}
  $source=[IO.File]::ReadAllText($safe) -replace '(?s)/\*.*?\*/','' -replace '(?m)//[^\r\n]*',''
  $declared=@([regex]::Matches($source,'\btechnique(?:10|11)?\s+([A-Za-z_][A-Za-z_0-9]*)\b')|ForEach-Object {$_.Groups[1].Value})
  if($declared.Count -and $name -cnotin $declared){"$identity (this FX declares $($declared -join ', '); compiled validation is required)"}
 }
}
function GetPresetImportWarning([string]$Preset,[string]$Game){
 $missing=@(GetMissingPresetShaders $Preset $Game)
 $techniques=@(GetPresetTechniqueWarnings $Preset $Game)
 $legacy=[IO.File]::ReadAllText($Preset) -match '(?im)^\s*Techniques\s*=\s*[^\s@,]+\s*$'
 if(-not($missing.Count -or $techniques.Count -or $legacy)){return}
 $details=@()
 if($missing.Count){$details+='Unable to find a verified download for: '+($missing -join ', ')+'.'}
 if($techniques.Count){$details+='Techniques requiring review: '+($techniques -join '; ')+'.'}
 if($legacy){$details+='This preset does not identify its shader filenames.'}
 return ('The preset has been installed, but please check for possible missing FX files or techniques. '+($details -join ' ')+' Please check the ZIP for custom FX files and follow the preset author''s installation instructions. Your preset is unchanged; check the in-game compiled technique status before relying on the look.')
}
function GetPresetPackages([string[]]$Missing,[string]$Catalogue,[switch]$AllowMissing){
 $packages=@();$current=$null
 foreach($line in Get-Content -LiteralPath $Catalogue){if($line -match '^\[(.+)\]$'){$current=@{Id=$Matches[1]};$packages+=,$current}elseif($current -and $line -match '^([^=]+)=(.*)$'){$current[$Matches[1]]=$Matches[2]}}
 $selected=@{}
 foreach($shader in $Missing){
  $sources=@($packages|Where-Object {$shader -in ($_.EffectFiles -split ',') -and $shader -notin ($_.DenyEffectFiles -split ',')})
  if($sources.Count -ne 1){if($AllowMissing){continue};throw "Unable to find a verified download for $shader in the catalogue. Please check the ZIP for custom FX files and follow the preset author's installation instructions."}
  $pkg=$sources[0];if(-not $selected.ContainsKey($pkg.Id)){$selected[$pkg.Id]=@{Package=$pkg;Shaders=@()}};$selected[$pkg.Id].Shaders+=,$shader
 }
 return $selected
}
function InstallPresetDependencies([string]$Preset,[string]$Game,[string]$Catalogue){
 $missing=@(GetMissingPresetShaders $Preset $Game)
 if(-not $missing.Count){
  return GetPresetImportWarning $Preset $Game
 }
 $selected=GetPresetPackages $missing $Catalogue -AllowMissing
 [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
 $downloads=ImportSafePath (Join-Path $Game 'OptiShadeData') ('Downloads/Import-'+[guid]::NewGuid().ToString('N'))
 New-Item -ItemType Directory -Path $downloads -Force|Out-Null
 try{
  foreach($selection in $selected.Values){
   $uri=[uri]$selection.Package.DownloadUrl
   if($uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com' -or $uri.AbsolutePath -notmatch '^/[^/]+/[^/]+/archive/.+\.zip$'){throw 'Unexpected catalogue download URL.'}
   $zip=Join-Path $downloads ($selection.Package.Id+'.zip')
   # Stream with hard bounds; a partial archive never reaches the importer.
   $request=[Net.HttpWebRequest]::Create($uri);$request.UserAgent='OptiShade/0.21';$request.Timeout=30000;$request.ReadWriteTimeout=30000
   $response=$request.GetResponse()
   try{
    if($response.ResponseUri.Scheme -ne 'https' -or $response.ResponseUri.Host -notin @('github.com','codeload.github.com')){throw 'Unexpected download redirect.'}
    $stream=$response.GetResponseStream();$out=[IO.File]::Create($zip)
    try{$buffer=New-Object byte[] 65536;$bytes=0L;$timer=[Diagnostics.Stopwatch]::StartNew();while(($n=$stream.Read($buffer,0,$buffer.Length)) -gt 0){$bytes+=$n;if($bytes -gt 256MB -or $timer.Elapsed.TotalSeconds -gt 120){throw 'Shader download exceeded its size or time limit.'};$out.Write($buffer,0,$n)}}finally{$out.Dispose();$stream.Dispose()}
   }finally{$response.Dispose()}
   if($selection.Package.SHA256 -and (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $selection.Package.SHA256){throw 'Shader archive verification failed. No files from this package were installed.'}
   $null=ImportEffectsArchive $zip $Game -OnlyShaders $selection.Shaders
  }
  foreach($header in @('ReShade.fxh','ReShadeUI.fxh')){
   if(-not $selected.Count){break}
   $target=ImportSafePath (Join-Path $Game 'OptiShadeData') ('Shaders/'+$header)
   if(-not(Test-Path -LiteralPath $target)){
    $source=Join-Path $PSScriptRoot ('StandardHeaders/'+$header)
    if(-not(Test-Path -LiteralPath $source)){$source=Join-Path $Game ('OptiShadeData/Tools/StandardHeaders/'+$header)}
    [IO.File]::Copy($source,$target,$false)
   }
  }
  return GetPresetImportWarning $Preset $Game
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
  if($ImportPreset){$warning=InstallPresetDependencies $ImportPreset $ImportGame (Join-Path $PSScriptRoot 'EffectPackages.ini');$message=if($warning){'OK: WARNING: '+$warning}else{'OK: Missing shaders installed. Loading the imported look; check shader compilation status.'}}
  else{$count=ImportEffectsArchive $ImportArchive $ImportGame;$message="OK: Imported $count files into OptiShadeData. Choose an imported INI under Saved look; required shaders must compile. Your current look is unchanged."}
 }
 catch{$message='ERROR: '+$_.Exception.Message}
 [IO.File]::WriteAllText($resultPath,$message,[Text.UTF8Encoding]::new($false))
 if($message.StartsWith('ERROR:')){exit 1}
}
