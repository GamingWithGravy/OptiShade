# Read PE metadata without loading or executing the selected game. Imports are
# discovery evidence only: dynamically loaded APIs require runtime confirmation.
function GetOptiShadeExecutableMetadata([string]$File){
 $item=Get-Item -LiteralPath $File -Force -ErrorAction Stop
 if($item.PSIsContainer){throw 'The selected rendering executable is not a file.'}
 [pscustomobject]@{Length=[long]$item.Length;LastWriteUtcTicks=[long]$item.LastWriteTimeUtc.Ticks;CreationUtcTicks=[long]$item.CreationTimeUtc.Ticks;Attributes=[int]$item.Attributes}
}
function TestOptiShadeExecutableAccessDenied($ErrorRecord){
 $exception=$ErrorRecord.Exception
 while($exception){if($exception -is [UnauthorizedAccessException]){return $true};$exception=$exception.InnerException}
 return $false
}
function GetOptiShadeRecordedXboxExecutableIdentity($Manifest,[string]$Executable){
 # Only an already-installed Xbox MSFS receipt can use this fallback. Its
 # exact route and in-game filename are the prior measured x64 evidence.
 if($Manifest.Status -cne 'Installed' -or [string]$Manifest.Architecture -cne 'x64'){return $null}
 $expectedName=switch([string]$Manifest.RouteDLL){'OptiShadeMSFS2024.dll'{'FlightSimulator2024.exe'};'OptiShadeMSFS2020.dll'{'FlightSimulator.exe'};default{''}}
 if(-not $expectedName -or [IO.Path]::GetFileName($Executable) -ine $expectedName){return $null}
 $game=[IO.Path]::GetFullPath([string]$Manifest.Game).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
 $expected=OwnedPath $game $expectedName
 if([IO.Path]::GetFullPath($Executable) -ine [IO.Path]::GetFullPath($expected)){return $null}
 [pscustomobject]@{Schema=1;Path=$expected;Architecture='x64';Machine=$null;SHA256='';ApiCandidates=@();Imports=@();DelayImports=@();ApiObserved='Unknown';Evidence='Previously installed Xbox MSFS x64 route; executable read denied; renderer/API and PE hash unknown';Metadata=(GetOptiShadeExecutableMetadata $expected)}
}
function GetOptiShadeExecutableIdentity([string]$File){
 if(-not(Test-Path -LiteralPath $File -PathType Leaf)){throw "The recorded game EXE is missing: $File. Locate the current game installation in Library / Setup and select its actual EXE before updating. No replacement executable was guessed."}
 $stream=[IO.File]::OpenRead($File);$reader=[IO.BinaryReader]::new($stream)
 try{
  if($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5a4d){throw 'Choose a Windows game EXE.'}
  $stream.Position=0x3c;$pe=$reader.ReadUInt32()
  if([long]$pe+24 -gt $stream.Length){throw 'Invalid executable header.'}
  $stream.Position=$pe
  if($reader.ReadUInt32() -ne 0x4550){throw 'Invalid executable signature.'}
  $machine=$reader.ReadUInt16();$count=$reader.ReadUInt16();$stream.Position=$pe+20
  $optionalBytes=$reader.ReadUInt16();$characteristics=$reader.ReadUInt16();$optional=$pe+24
  if([long]$optional+$optionalBytes -gt $stream.Length){throw 'Invalid executable optional header.'}
  $stream.Position=$optional;$magic=$reader.ReadUInt16()
  $architecture=if($machine -eq 0x8664 -and $magic -eq 0x20b){'x64'}elseif($machine -eq 0x14c -and $magic -eq 0x10b){'x86'}else{throw 'Only x86 and x64 Windows game executables are supported.'}
  $minimumOptionalBytes=if($architecture -eq 'x64'){112}else{96}
  if($optionalBytes -lt $minimumOptionalBytes){throw 'Invalid executable optional header.'}
  if(($characteristics -band 0x2000) -ne 0){throw 'Select the rendering EXE, not a DLL.'}
  if($count -eq 0 -or $count -gt 96 -or [long]$optional+$optionalBytes+40*$count -gt $stream.Length){throw 'Invalid executable sections.'}
  $stream.Position=$optional+60;$headerBytes=$reader.ReadUInt32()
  $directoryCountOffset=if($architecture -eq 'x64'){108}else{92}
  $importDirectoryOffset=if($architecture -eq 'x64'){120}else{104}
  $stream.Position=$optional+$directoryCountOffset;$directoryCount=$reader.ReadUInt32()
  $importRva=0;$importBytes=0;$delayImportRva=0;$delayImportBytes=0
  if($directoryCount -ge 2 -and $optionalBytes -ge ($importDirectoryOffset+8)){$stream.Position=$optional+$importDirectoryOffset;$importRva=$reader.ReadUInt32();$importBytes=$reader.ReadUInt32()}
  $delayImportOffset=$importDirectoryOffset+12*8
  if($directoryCount -ge 14 -and $optionalBytes -ge ($delayImportOffset+8)){$stream.Position=$optional+$delayImportOffset;$delayImportRva=$reader.ReadUInt32();$delayImportBytes=$reader.ReadUInt32()}
  $imageBase=0L
  if($architecture -eq 'x64'){$stream.Position=$optional+24;$imageBase=[long]$reader.ReadUInt64()}else{$stream.Position=$optional+28;$imageBase=[long]$reader.ReadUInt32()}
  $sections=@()
  for($i=0;$i -lt $count;$i++){
   $stream.Position=$optional+$optionalBytes+40*$i+8
   $virtual=$reader.ReadUInt32();$rva=$reader.ReadUInt32();$rawSize=$reader.ReadUInt32();$raw=$reader.ReadUInt32()
   if([long]$raw+$rawSize -gt $stream.Length){throw 'Truncated executable section.'}
   $sections+=@{Rva=[long]$rva;Raw=[long]$raw;Size=[long]$rawSize}
  }
  $map={param([long]$Address,[long]$Length)
   if($Address -lt $headerBytes -and $Address+$Length -le $headerBytes -and $Address+$Length -le $stream.Length){return $Address}
   foreach($section in $sections){if($Address -ge $section.Rva -and $Address+$Length -le $section.Rva+$section.Size){return $section.Raw+$Address-$section.Rva}}
   throw 'Invalid executable import address.'
  }
  # Unreal packaged launchers store their relative rendering target in RCDATA
  # 201. Read that resource as data; never load or execute the launcher.
  $bootstrapRelativePath=''
  if($directoryCount -ge 3 -and $optionalBytes -ge ($importDirectoryOffset+16)){
   $stream.Position=$optional+$importDirectoryOffset+8
   $resourceRva=$reader.ReadUInt32();$resourceBytes=$reader.ReadUInt32()
   if($resourceRva -and $resourceBytes -ge 16 -and $resourceBytes -le 4MB){
    try{
     $resourceEntry={param([long]$Offset,[int]$Id)
      if($Offset -lt 0 -or $Offset+16 -gt $resourceBytes){throw 'Invalid resource directory.'}
      $stream.Position=& $map ([long]$resourceRva+$Offset+12) 4
      $named=$reader.ReadUInt16();$numbered=$reader.ReadUInt16();$countEntries=[int]$named+[int]$numbered
      if($countEntries -gt 4096 -or $Offset+16+8*$countEntries -gt $resourceBytes){throw 'Invalid resource entries.'}
      for($ri=0;$ri -lt $countEntries;$ri++){
       $stream.Position=& $map ([long]$resourceRva+$Offset+16+8*$ri) 8
       $nameId=$reader.ReadUInt32();$entryOffset=$reader.ReadUInt32()
       if(($Id -ge 0 -and $nameId -eq $Id) -or ($Id -lt 0 -and $countEntries -eq 1)){return [long]$entryOffset}
      }
      return -1L
     }
     $type=& $resourceEntry 0 10
     if($type -ge 2147483648L){
      $target=& $resourceEntry ($type-2147483648L) 201
      if($target -ge 2147483648L){
       $language=& $resourceEntry ($target-2147483648L) -1
       if($language -ge 0 -and $language -lt 2147483648L -and $language+16 -le $resourceBytes){
        $stream.Position=& $map ([long]$resourceRva+$language) 16
        $dataRva=$reader.ReadUInt32();$dataBytes=$reader.ReadUInt32()
        if($dataBytes -ge 4 -and $dataBytes -le 2048 -and $dataBytes%2 -eq 0){
         $stream.Position=& $map ([long]$dataRva) $dataBytes
         $targetText=[Text.Encoding]::Unicode.GetString($reader.ReadBytes($dataBytes)).TrimEnd([char]0)
         if($targetText -match '(?i)^[^:\x00]+[\\/]Binaries[\\/]Win(?:32|64)[\\/][^\\/]+\.exe$'){$bootstrapRelativePath=$targetText}
        }
       }
      }
     }
    }catch{throw ('Invalid packaged game target resource: '+$_.Exception.Message)}
   }
  }
  $imports=@();$delayImports=@()
  if($importRva -and $importBytes){
   for($i=0;$i -lt [Math]::Min(4096,[Math]::Floor($importBytes/20));$i++){
    $stream.Position=& $map ([long]$importRva+20*$i) 20
    $entry=@(1..5|ForEach-Object {$reader.ReadUInt32()})
    if(-not($entry|Where-Object {$_ -ne 0})){break}
    $nameRva=$entry[3];$name=[Text.StringBuilder]::new();$terminated=$false
    for($j=0;$j -lt 260;$j++){
     $stream.Position=& $map ([long]$nameRva+$j) 1;$c=$reader.ReadByte()
     if($c -eq 0){$terminated=$true;break};[void]$name.Append([char]$c)
    }
    if(-not $terminated){throw 'Invalid executable import name.'}
    $imports+=$name.ToString().ToLowerInvariant()
   }
  }
  if($delayImportRva -and $delayImportBytes){
   for($i=0;$i -lt [Math]::Min(4096,[Math]::Floor($delayImportBytes/32));$i++){
    $stream.Position=& $map ([long]$delayImportRva+32*$i) 32
    $entry=@(1..8|ForEach-Object {$reader.ReadUInt32()})
    if(-not($entry|Where-Object {$_ -ne 0})){break}
    $nameAddress=[long]$entry[1]
    if(($entry[0] -band 1) -eq 0){$nameAddress-=$imageBase}
    if($nameAddress -le 0 -or $nameAddress -gt [uint32]::MaxValue){throw 'Invalid delay-import DLL name address.'}
    $name=[Text.StringBuilder]::new();$terminated=$false
    for($j=0;$j -lt 260;$j++){
     $stream.Position=& $map ($nameAddress+$j) 1;$c=$reader.ReadByte()
     if($c -eq 0){$terminated=$true;break};[void]$name.Append([char]$c)
    }
    if(-not $terminated){throw 'Invalid delay-import DLL name.'}
    $delayImports+=$name.ToString().ToLowerInvariant()
   }
  }
  $apiImports=@($imports)+@($delayImports)
  $apis=@();if($apiImports -contains 'd3d9.dll'){$apis+='DX9'};if($apiImports -contains 'd3d10.dll'){$apis+='DX10'};if($apiImports -contains 'd3d11.dll'){$apis+='DX11'};if($apiImports -contains 'd3d12.dll'){$apis+='DX12'};if($apiImports -contains 'opengl32.dll'){$apis+='OpenGL'};if($apiImports -contains 'vulkan-1.dll'){$apis+='Vulkan'}
  $stream.Position=0;$sha=[Security.Cryptography.SHA256]::Create()
  try{$hash=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','')}finally{$sha.Dispose()}
  [pscustomobject]@{Schema=1;Path=[IO.Path]::GetFullPath($File);Architecture=$architecture;Machine=$machine;SHA256=$hash;ApiCandidates=$apis;Imports=$imports;DelayImports=$delayImports;BootstrapRelativePath=$bootstrapRelativePath;ApiObserved='Unknown';Evidence='Static and delay-load PE import discovery; runtime confirmation required'}
 }finally{$reader.Dispose()}
}

function GetOptiShadeRenderingExecutable($Manifest,[switch]$AllowRecordedUnknown,[switch]$ForLiveObservation){
 # The selected rendering image owns session and model preparation identity.
 # The existing Xbox/MS Store simulator helper is a launch mechanism only.
 $executable=[string]$Manifest.LaunchExe
 if(-not $executable -or -not [IO.Path]::IsPathRooted($executable)){throw 'Choose the actual game executable in Setup before automatic preparation.'}
 $game=[IO.Path]::GetFullPath([string]$Manifest.Game).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
 $executable=[IO.Path]::GetFullPath($executable)
 $prefix=$game+[IO.Path]::DirectorySeparatorChar
 if(-not $executable.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'The selected executable is outside the recorded installation.'}
 $relative=$executable.Substring($prefix.Length);$executable=OwnedPath $game $relative
 $launchHelper=$null
 if([IO.Path]::GetFileName($executable) -ieq 'gamelaunchhelper.exe'){
  $launchHelper=$executable
  $leaf=switch([string]$Manifest.RouteDLL){'OptiShadeMSFS2024.dll'{'FlightSimulator2024.exe'};'OptiShadeMSFS2020.dll'{'FlightSimulator.exe'};default{
   if($AllowRecordedUnknown -and -not $ForLiveObservation -and $Manifest.Status -eq 'Installed' -and [string]$Manifest.Architecture -eq 'x64' -and (Test-Path -LiteralPath $executable -PathType Leaf)){
    return [pscustomobject]@{Schema=1;Path=$executable;Architecture='x64';Machine=$null;SHA256='';ApiCandidates=@();Imports=@();DelayImports=@();ApiObserved='Unknown';Evidence='Recorded installed x64 launch helper; rendering executable is not recorded; renderer/API and PE hash unknown'}
   }
   throw 'This launch helper has no recorded qualified rendering executable. Select the actual game EXE in Setup.'
  }}
  $executable=OwnedPath $game $leaf
 }
 try{$identity=GetOptiShadeExecutableIdentity $executable}catch{
  # Some Store/Xbox game packages allow launching an image while denying a
  # read handle to it. A component update does not modify that image. When a
  # caller explicitly opts in, retain the already-installed x64 identity and
  # leave renderer/API evidence unknown; never manufacture a PE hash or API.
  $accessDenied=$false;$exception=$_.Exception
  while($exception){if($exception -is [UnauthorizedAccessException]){$accessDenied=$true;break};$exception=$exception.InnerException}
  if(-not $AllowRecordedUnknown -or -not $accessDenied -or $Manifest.Status -ne 'Installed' -or [string]$Manifest.Architecture -ne 'x64'){throw}
  if($launchHelper -and -not $ForLiveObservation -and (Test-Path -LiteralPath $launchHelper -PathType Leaf)){
   # Use the readable Store/Xbox content helper as the recorded launch target.
   # Do not attribute its PE imports/hash to the encrypted rendering image.
   $identity=[pscustomobject]@{Schema=1;Path=$launchHelper;Architecture='x64';Machine=$null;SHA256='';ApiCandidates=@();Imports=@();DelayImports=@();ApiObserved='Unknown';Evidence='Recorded x64 Store/Xbox content launch helper selected; rendering executable read denied; renderer/API and PE hash unknown'}
  }else{
   $identity=[pscustomobject]@{Schema=1;Path=$executable;Architecture='x64';Machine=$null;SHA256='';ApiCandidates=@();Imports=@();DelayImports=@();ApiObserved='Unknown';Evidence='Recorded installed x64 architecture; executable read denied; renderer/API and PE hash unknown'}
  }
 }
 if($Manifest.Architecture -and [string]$Manifest.Architecture -cne $identity.Architecture){throw 'The recorded game architecture changed. Review the installation before automatic preparation.'}
 return $identity
}
