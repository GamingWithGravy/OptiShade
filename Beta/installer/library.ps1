. "$PSScriptRoot/json-state.ps1"
. "$PSScriptRoot/store-paths.ps1"
. "$PSScriptRoot/gpu-identity.ps1"
function ResolveOptiShadeLibraryPath([string]$Path){
 if([string]::IsNullOrWhiteSpace($Path)){throw 'Path is empty.'}
 $value=[Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"').Trim()).Replace('/','\')
 if($value.Length -ge 248){
  if($value.StartsWith('\\?\UNC\',[StringComparison]::OrdinalIgnoreCase)){$value='\\'+$value.Substring(8)}
  elseif($value.StartsWith('\\?\',[StringComparison]::OrdinalIgnoreCase)){$value=$value.Substring(4)}
  if($value -notmatch '^(?:[A-Za-z]:\\|\\\\[^\\]+\\[^\\]+)'){throw 'Long paths must be fully qualified.'}
  if(@($value -split '\\'|Where-Object {$_ -eq '.' -or $_ -eq '..'}).Count){throw 'Long paths containing dot traversal are not supported.'}
  return $value.TrimEnd('\','/')
 }
 [IO.Path]::GetFullPath($value).TrimEnd('\','/')
}
# Read launcher catalogues; never crawl entire disks or start games during discovery.
function TestFusionLibraryCandidateName([string]$Name){
 if([string]::IsNullOrWhiteSpace($Name)){return $false}
 $Name=$Name.Trim()
 # Xbox installs the Flight Simulator Digital Ownership entitlement beside the
 # simulator. It is a licensing package, not a runnable game.
 if($Name -match '(?i)digital[\s._-]*ownership'){return $false}
 # These registered locations are launcher/support applications, not game
 # installs. Keep this exact-name list narrow so a game's marketing title is
 # never excluded just because its publisher also has a launcher.
 if($Name -match '(?i)^(?:2K Launcher|Amazon Games|Battle\.net|Bethesda\.net Launcher|EA app|EA Desktop|EA Desktop App|Epic Games Launcher|GOG Galaxy|Paradox Launcher(?: v2)?|REDlauncher|Riot Client|Riot Vanguard|Rockstar Games Launcher|Steam|Ubisoft Anti-Cheat|Ubisoft Connect|Ubisoft Game Launcher|Uplay)$'){return $false}
 if($Name -match '(?i)Steamworks Common|SteamVR|Oasis Driver|Unreal Engine|Fab UE Plugin|Quixel Bridge|Minecraft Launcher'){return $false}
 return $true
}
function GetFusionRegisteredGameLocations([string[]]$RegistryRoots=@(
 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)){
 # Some launchers do not expose a library manifest. Their uninstall records can
 # still provide a custom InstallLocation. Read only metadata, never the
 # uninstall command; AddGame's normal executable verification is the gate.
 $gamePublisher='(?i)(Ubisoft|Electronic Arts|\bEA\b|Amazon Game Studios|Amazon Games|Blizzard|Activision|GOG|CD Projekt|Rockstar|Bethesda|Epic Games|Riot Games|2K Games|Take-Two|SEGA|Square Enix|Bandai Namco|Capcom|THQ Nordic|Deep Silver|Focus Entertainment|Warner Bros|Paradox|Frontier Developments|Team17|Rebellion|Techland|Remedy|Larian|Mojang|Valve Corporation|Microsoft Studios|Xbox Game Studios)'
 $results=[Collections.Generic.List[object]]::new();$seen=@{}
 foreach($root in $RegistryRoots){
  try{$entries=Get-ChildItem -LiteralPath $root -ErrorAction Stop|Select-Object -First 500}catch{continue}
  foreach($entry in $entries){
   try{
    $record=Get-ItemProperty -LiteralPath $entry.PSPath -ErrorAction Stop
    $name=[string]$record.DisplayName;$publisher=[string]$record.Publisher;$location=[string]$record.InstallLocation
    if(-not $name -or -not (TestFusionLibraryCandidateName $name) -or $publisher -notmatch $gamePublisher -or -not $location){continue}
    $location=[Environment]::ExpandEnvironmentVariables($location.Trim().Trim('"'))
    if(-not [IO.Path]::IsPathRooted($location) -or -not (Test-Path -LiteralPath $location -PathType Container)){continue}
    try{$folder=ResolveOptiShadeLibraryPath $location;AssertFusionPhysicalFolder $folder}catch{continue}
    $key=$folder.ToLowerInvariant();if($seen.ContainsKey($key)){continue};$seen[$key]=$true
    $results.Add([pscustomobject]@{Name=$name;Folder=$folder;Publisher=$publisher})
   }catch{}
  }
 }
 return @($results)
}
function GetFusionLibraryGameKey($Game){
 if(-not $Game -or -not $Game.Folder){return ''}
 try{$folder=ResolveOptiShadeLibraryPath ([string]$Game.Folder)}catch{return ''}
 return (([string]$Game.Launcher)+'|'+$folder).ToLowerInvariant()
}
function FilterFusionLibraryGames($Games,$RemovedGames){
 return @($Games|Where-Object {$key=GetFusionLibraryGameKey $_; -not ($key -and $RemovedGames -and $RemovedGames.ContainsKey($key))})
}
function TestFusionSimulatorPackageIdentity([string]$Requested,[string]$Actual){
 return $Requested -in @('Microsoft.FlightSimulator','Microsoft.Limitless') -and $Actual -ieq $Requested
}
function ResolveFusionStoreFolder([string]$Folder){
 # Appx InstallLocation can be a protected package path or an Xbox junction.
 # Never install through WindowsApps or relax OwnedPath's link protection.
 if($Folder -notmatch '(?i)[\\/]WindowsApps(?:[\\/]|$)'){return $Folder}
 $help='This is a WindowsApps package path, not an installable game folder. In the Xbox app, open the simulator > Manage > Files, then select its installation folder using Browse. OptiShade will not change WindowsApps permissions.'
 if($Folder -notmatch '(?i)[\\/]WindowsApps[\\/]Microsoft\.(FlightSimulator|Limitless)_[^\\/]+$'){throw $help}
 $edition=$Matches[1]
 try{
  $target=ResolveSimulatorStoreTarget $Folder
  $exe=if($edition -eq 'Limitless'){'FlightSimulator2024.exe'}else{'FlightSimulator.exe'}
  foreach($root in @($target,(Join-Path $target 'Content'))){
   if(-not(Test-Path -LiteralPath (Join-Path $root $exe) -PathType Leaf)){continue}
   $check=$root
   while($check){
    if((Get-Item -LiteralPath $check -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){throw $help}
    $parent=Split-Path $check -Parent;if($parent -eq $check){break};$check=$parent
   }
   return $root
  }
 }catch{throw $help}
 throw $help
}
function ResolveFusionInstallFolder([string]$Game){
 if([string]::IsNullOrWhiteSpace($Game)){throw 'Choose a game installation folder.'}
 $candidate=[Environment]::ExpandEnvironmentVariables($Game.Trim().Trim('"').Trim())
 if($candidate -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+)' -or $candidate.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0 -or $candidate -match '[<>|"*?\x00-\x1F]' ){
  throw 'The game installation path is invalid. Check the folder and try again.'
 }
 try{$folder=ResolveOptiShadeLibraryPath $candidate}catch{throw 'The game installation path is invalid. Check the folder and try again.'}
 if([IO.Path]::GetFileName($folder) -in @('FlightSimulator2024.exe','FlightSimulator.exe','gamelaunchhelper.exe','X-Plane.exe')){$folder=Split-Path $folder -Parent}
 $folder=ResolveFusionStoreFolder $folder
 foreach($candidate in @($folder,(Join-Path $folder 'Content'))){
  foreach($exe in @('FlightSimulator2024.exe','FlightSimulator.exe','X-Plane.exe')){if(Test-Path -LiteralPath (Join-Path $candidate $exe) -PathType Leaf){return $candidate}}
 }
 return $folder
}
# A generic executable directory (bin, x64, Binaries\Win64, Content) is not a
# game title: use the nearest real folder above it, e.g. DCS World\bin ->
# "DCS World" (was "Unidentified game (Bin)"). Unresolved only with none left.
function GetFusionFolderTitle([string]$Game){
 $generic='^(?i:win64|win_x64|win32|x64|x86|bin|bin64|binaries|content|game|shipping|retail)$'
 $leaf=Split-Path $Game -Leaf
 for($folder=$Game;$folder;$folder=Split-Path $folder -Parent){
  $name=Split-Path $folder -Leaf
  if(-not $name -or $name -match '^[A-Za-z]:\\?$'){break}
  if($name -notmatch $generic){return $name}
 }
 return 'Unidentified game ('+$leaf+')'
}
function GetMsfsTitle([string]$Game){
 try{$folder=ResolveFusionInstallFolder $Game}catch{return ''}
 if(-not $folder){return ''}
 if(Test-Path -LiteralPath (Join-Path $folder 'X-Plane.exe') -PathType Leaf){return 'X-Plane 12 (experimental)'}
 if(Test-Path -LiteralPath (Join-Path $folder 'FlightSimulator2024.exe') -PathType Leaf){return 'Microsoft Flight Simulator 2024'}
 if(Test-Path -LiteralPath (Join-Path $folder 'FlightSimulator.exe') -PathType Leaf){return 'Microsoft Flight Simulator 2020'}
 if(@(GetFusionNestedMsfsExecutables $folder 'Microsoft Flight Simulator 2024').Count){return 'Microsoft Flight Simulator 2024'}
 if(@(GetFusionNestedMsfsExecutables $folder 'Microsoft Flight Simulator 2020').Count){return 'Microsoft Flight Simulator 2020'}
 return ''
}
function GetFusionExpectedSimulatorTitle([string]$Name){
 if([string]::IsNullOrWhiteSpace($Name)){return ''}
 $storeSuffix='(?:\s*/\s*(?:Steam|Xbox|Microsoft Store))?'
 if($Name -match ('(?i)^(?:MSFS\s*2024|Microsoft[ .]*Limitless|(?:Microsoft[ .]*)?Flight[ .]*Simulator[ .]*2024)(?:\s*\(2024\))?'+$storeSuffix+'$')){return 'Microsoft Flight Simulator 2024'}
 if($Name -match ('(?i)^(?:MSFS\s*2020|(?:Microsoft[ .]*)?Flight[ .]*Simulator(?:[ .]*2020)?)(?:\s*\(2020\))?'+$storeSuffix+'$')){return 'Microsoft Flight Simulator 2020'}
 if($Name -match '(?i)^X.?Plane\s*12(?:\s*\(experimental\))?$'){return 'X-Plane 12 (experimental)'}
 return ''
}
function GetFusionNestedMsfsExecutables([string]$Root,[string]$Title){
 # Some Steam/custom layouts place the simulator executable below the
 # registered install root. Search only the selected game folder, with tight
 # depth/count limits and no directory junction traversal.
 $expected=GetFusionExpectedSimulatorTitle $Title
 if($expected -notin @('Microsoft Flight Simulator 2024','Microsoft Flight Simulator 2020')){return @()}
 $exe=if($expected -eq 'Microsoft Flight Simulator 2024'){'FlightSimulator2024.exe'}else{'FlightSimulator.exe'}
 $queue=[Collections.Generic.Queue[object]]::new();$queue.Enqueue([pscustomobject]@{Path=$Root;Depth=0})
 $found=[Collections.Generic.List[string]]::new();$visited=0
 $skip='(?i)^(?:community|official|packages|sceneryindexes|scenerycache|localcache|shadercache|dumps|logs|redist|redistributables|easy.?anticheat|battleye|crashpad|launcher|installers?|prerequisites|support|tools)$'
 while($queue.Count -and $visited -lt 256 -and $found.Count -lt 8){
  $node=$queue.Dequeue();$visited++
  $candidate=Join-Path $node.Path $exe
  if(Test-Path -LiteralPath $candidate -PathType Leaf){
   try{if(-not((Get-Item -LiteralPath $candidate -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint)){$found.Add([IO.Path]::GetFullPath($candidate))}}catch{}
  }
  if($node.Depth -ge 4){continue}
  foreach($directory in Get-ChildItem -LiteralPath $node.Path -Directory -Force -ErrorAction SilentlyContinue){
   if(($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $directory.Name -match $skip){continue}
   $queue.Enqueue([pscustomobject]@{Path=$directory.FullName;Depth=$node.Depth+1})
  }
 }
 return @($found|Select-Object -Unique)
}
function GetFusionKnownSimulatorExecutableCandidates([string]$Root){
 # Manual library-root fallback. Recognize exact simulator executable names;
 # never choose an arbitrary launcher or first EXE from a library folder.
 $queue=[Collections.Generic.Queue[object]]::new();$queue.Enqueue([pscustomobject]@{Path=$Root;Depth=0})
 $found=[Collections.Generic.List[object]]::new();$visited=0
 $names=@('FlightSimulator2024.exe','FlightSimulator.exe','X-Plane.exe')
 $skip='(?i)^(?:community|official|packages|sceneryindexes|scenerycache|localcache|shadercache|dumps|logs|redist|redistributables|easy.?anticheat|battleye|crashpad|launcher|installers?|prerequisites|support|tools)$'
 while($queue.Count -and $visited -lt 512 -and $found.Count -lt 32){
  $node=$queue.Dequeue();$visited++
  foreach($name in $names){
   $candidate=Join-Path $node.Path $name
   if(Test-Path -LiteralPath $candidate -PathType Leaf){
    try{if(-not((Get-Item -LiteralPath $candidate -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint)){$found.Add([pscustomobject]@{Name=$name;Path=[IO.Path]::GetFullPath($candidate)})}}catch{}
   }
  }
  if($node.Depth -ge 5){continue}
  foreach($directory in Get-ChildItem -LiteralPath $node.Path -Directory -Force -ErrorAction SilentlyContinue){
   if(($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $directory.Name -match $skip){continue}
   $queue.Enqueue([pscustomobject]@{Path=$directory.FullName;Depth=$node.Depth+1})
  }
 }
 return @($found|Sort-Object Path -Unique)
}
function TestFusionMissingSimulatorExecutable($Game){
 if(-not $Game -or [string]::IsNullOrWhiteSpace([string]$Game.Folder)){return $false}
 $expected=GetFusionExpectedSimulatorTitle ([string]$Game.Name)
 if(-not $expected){return $false}
 try{$folder=ResolveFusionInstallFolder ([string]$Game.Folder)}catch{return $false}
 if(-not $folder -or -not(Test-Path -LiteralPath $folder -PathType Container)){return $false}
 $roots=@($folder,(Join-Path $folder 'Content'))
 $executables=if($expected -eq 'X-Plane 12 (experimental)'){@('X-Plane.exe')}else{@('FlightSimulator2024.exe','FlightSimulator.exe')}
 foreach($root in $roots){foreach($exe in $executables){
  try{$item=Get-Item -LiteralPath (Join-Path $root $exe) -Force -ErrorAction Stop;if(-not $item.PSIsContainer){return $false}}
  catch [System.Management.Automation.ItemNotFoundException]{}
  catch [System.Management.Automation.DriveNotFoundException]{return $false}
  catch{return $false} # Access denied or an uncertain path is not proof of an uninstalled game.
 }}
 return $true
}
function GetFusionGameTargetFolder($Game,[string]$Store=''){
 if(-not $Game){throw 'Choose a detected game before continuing.'}
 # The detected folder identifies the selected game. InstallFolder is only a
 # cached/receipt hint and may belong to another game after startup refreshes.
 $folder=[string]$Game.Folder
 if(-not $folder){$folder=[string]$Game.InstallFolder}
 if(-not $folder){throw 'The selected game has no installation folder. Scan the library again.'}
 $target=ResolveFusionInstallFolder $folder
 # A nested executable location is valid only within the selected catalogue
 # root. An unrelated cached InstallFolder must never redirect installation.
 if($Game.InstallFolder){
  try{$nested=ResolveFusionInstallFolder ([string]$Game.InstallFolder)
   if($nested.StartsWith($target+'\',[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $nested -PathType Container)){
    $executables=@(FindFusionExecutable $nested ([string]$Game.Launcher) ([string]$Game.Name))
    $recorded=$false
    if($Store){
     $receipt=ManifestPath $Store $nested
     if(Test-Path -LiteralPath $receipt -PathType Leaf){
      $manifest=ReadOptiShadeState $receipt
      if([string]$manifest.Game -ieq $nested -and $manifest.Status -in @('Installed','Installing') -and $manifest.LaunchExe){
       $identity=GetOptiShadeRenderingExecutable $manifest -AllowRecordedUnknown
       $recorded=[bool]$identity
      }
     }
    }
    if($executables.Count -eq 1 -or $recorded){$target=$nested}
   }
  }catch{}
 }
 # Resolve the renderer even before a receipt exists. Catalogue roots and
 # cached launcher folders are not necessarily the DLL installation directory.
 $resolved=@(FindFusionExecutable $target ([string]$Game.Launcher) ([string]$Game.Name))
 if($resolved.Count -eq 1){$target=Split-Path $resolved[0].Path -Parent}
 $name=[string]$Game.Name;$actual=GetMsfsTitle $target;$expected=GetFusionExpectedSimulatorTitle $name
 if($expected -and $actual -ne $expected){throw "The selected game '$name' does not match its detected installation folder. Rescan the library before installing."}
 return $target
}
function AssertFusionPhysicalFolder([string]$Folder){
 $check=$Folder
 while($check){
  if((Get-Item -LiteralPath $check -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){
   throw 'Select the actual game installation folder, not a linked or protected WindowsApps folder. For Xbox installs, use the location shown under Manage > Files.'
  }
  $parent=Split-Path $check -Parent;if($parent -eq $check){break};$check=$parent
 }
}
function TestOptiShadeElevated {
 $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
 try{return ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}finally{$identity.Dispose()}
}
function JoinOptiShadeLayerPaths([string[]]$Values){
 $paths=[Collections.Generic.List[string]]::new()
 foreach($value in $Values){foreach($part in ($value -split ';')){
  $part=$part.Trim().Trim('"');if(-not $part){continue}
  if(-not [IO.Path]::IsPathRooted($part) -or $part -match '[\r\n*?%]'){throw 'A Vulkan layer search path is malformed. Review VK_LAYER_PATH / VK_ADD_LAYER_PATH before launching.'}
  try{$part=ResolveOptiShadeLibraryPath $part}catch{throw 'A Vulkan layer search path is invalid.'}
  if(-not @($paths|Where-Object {$_.TrimEnd('\','/') -ieq $part.TrimEnd('\','/')}).Count){$paths.Add($part)}
 }}
 return $paths -join ';'
}
function AssertOptiShadeXPlaneLaunchPolicy([string]$Exe){
 $conflicts=[Collections.Generic.List[string]]::new()
 foreach($scope in @('HKCU:','HKLM:')){
  $key=$scope+'\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
  try{$properties=Get-ItemProperty -LiteralPath $key -ErrorAction Stop
   foreach($property in $properties.PSObject.Properties){if($property.Name -ieq $Exe -and [string]$property.Value -match '(?i)\bRUNASADMIN\b'){$conflicts.Add($scope+' executable compatibility setting')}}
  }catch{}
 }
 if($env:__COMPAT_LAYER -match '(?i)\bRUNASADMIN\b'){$conflicts.Add('inherited compatibility setting')}
 if($conflicts.Count){throw ('X-Plane is configured to require administrator access ('+($conflicts -join ', ')+'). Review the executable Properties > Compatibility > Run this program as administrator, including All users. OptiShade has not changed this setting; Play requires a normal non-elevated launch.')}
 if(-not ('OptiShadeLaunchManifest' -as [type])){
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class OptiShadeLaunchManifest {
 [DllImport("kernel32",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr LoadLibraryEx(string p,IntPtr f,uint flags);
 [DllImport("kernel32",SetLastError=true)] static extern IntPtr FindResource(IntPtr m,IntPtr n,IntPtr t);
 [DllImport("kernel32")] static extern IntPtr LoadResource(IntPtr m,IntPtr r);
 [DllImport("kernel32")] static extern IntPtr LockResource(IntPtr r);
 [DllImport("kernel32")] static extern uint SizeofResource(IntPtr m,IntPtr r);
 [DllImport("kernel32")] static extern bool FreeLibrary(IntPtr m);
 public static string Read(string p){
  var m=LoadLibraryEx(p,IntPtr.Zero,2|0x20); if(m==IntPtr.Zero)throw new InvalidOperationException("Cannot inspect the X-Plane executable manifest.");
  try{var r=FindResource(m,new IntPtr(1),new IntPtr(24));if(r==IntPtr.Zero)return "";
   uint length=SizeofResource(m,r);if(length>65536)throw new InvalidOperationException("Executable manifest exceeds inspection limit.");
   var bytes=new byte[length];var ptr=LockResource(LoadResource(m,r));if(ptr==IntPtr.Zero)throw new InvalidOperationException("Cannot read executable manifest.");
   Marshal.Copy(ptr,bytes,0,(int)length);return System.Text.Encoding.UTF8.GetString(bytes).Trim('\0','\uFEFF');
  }finally{FreeLibrary(m);}
 }
}
'@
 }
 $text=[OptiShadeLaunchManifest]::Read($Exe)
 if($text){
  $xml=[xml]::new();$xml.XmlResolver=$null;$xml.LoadXml($text)
  $level=$xml.SelectSingleNode("//*[local-name()='requestedExecutionLevel']")
  if($level -and $level.level -in @('requireAdministrator','highestAvailable')){throw ('X-Plane executable manifest requests '+$level.level+'. This conflicts with process-local Vulkan layers. Use an official non-elevated executable or review the executable policy; no security setting was changed and no game was launched.')}
 }
}


function GetOptiShadeRegisteredOpenXRExplicitLayerPaths {
 $paths=[Collections.Generic.List[string]]::new()
 # All supported simulators and OptiShade runtime DLLs are x64. Read the same
 # registry view that the 64-bit OpenXR loader uses even if the manager host or
 # a future helper process changes bitness.
 foreach($hive in @([Microsoft.Win32.RegistryHive]::CurrentUser,[Microsoft.Win32.RegistryHive]::LocalMachine)){
  $base=$null;$key=$null
  try{
   $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey($hive,[Microsoft.Win32.RegistryView]::Registry64)
   $key=$base.OpenSubKey('SOFTWARE\Khronos\OpenXR\1\ApiLayers\Explicit',$false)
   if(-not $key){continue}
   foreach($manifest in $key.GetValueNames()){
    try{
     if($key.GetValueKind($manifest) -ne [Microsoft.Win32.RegistryValueKind]::DWord){continue}
     $disabled=$key.GetValue($manifest,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
     if($null -eq $disabled -or [int]$disabled -ne 0 -or -not [IO.Path]::IsPathRooted($manifest)){continue}
     $dir=Split-Path $manifest -Parent
     if(-not $dir){continue}
     $dir=FullPath $dir
     if(-not @($paths|Where-Object {$_.TrimEnd('\','/') -ieq $dir.TrimEnd('\','/')}).Count){$paths.Add($dir)}
    }catch{}
   }
  }finally{if($key){$key.Dispose()};if($base){$base.Dispose()}}
 }
 return @($paths)
}
function AddOptiShadeOpenXREnvironment($Start,[string]$Game){
 $layers=OwnedPath $Game 'OptiShadeData/OpenXR'
 $json=OwnedPath $Game 'OptiShadeData/OpenXR/OptiShade_XR.json'
 if(-not(Test-Path -LiteralPath $json -PathType Leaf)){return $false}
 try{$layer=ReadOptiShadeJson $json 'OpenXR layer JSON' -MaxBytes 65536}catch{throw 'OptiShade_XR.json is unreadable or invalid. Repair using the matching manager.'}
 if($layer.api_layer.name -cne 'XR_APILAYER_optishade' -or $layer.api_layer.library_path -cne '..\..\ReShade64.dll'){
  throw 'OptiShade_XR.json has an invalid layer definition. Repair using the matching manager.'
 }
 $resolved=FullPath (Join-Path $layers ([string]$layer.api_layer.library_path))
 $localReShade=OwnedPath $Game 'ReShade64.dll'
 if(-not [string]::Equals($resolved,$localReShade,[StringComparison]::OrdinalIgnoreCase) -or -not(Test-Path -LiteralPath $localReShade -PathType Leaf)){
  throw 'The OptiShade OpenXR layer does not resolve to the game-local ReShade64.dll. Repair before VR.'
 }
 $environment=$Start.EnvironmentVariables
 $paths=[Collections.Generic.List[string]]::new()
 $candidates=@($layers,$environment['XR_API_LAYER_PATH'])
 $candidates+=@(GetOptiShadeRegisteredOpenXRExplicitLayerPaths)
 foreach($candidate in $candidates){
  foreach($part in ([string]$candidate -split ';')){
   $part=$part.Trim().Trim('"');if(-not $part){continue}
   if(-not [IO.Path]::IsPathRooted($part) -or $part -match '[\r\n*?%]'){throw 'XR_API_LAYER_PATH contains a malformed entry.'}
   $part=FullPath $part
   if(-not @($paths|Where-Object {$_.TrimEnd('\','/') -ieq $part.TrimEnd('\','/')}).Count){$paths.Add($part)}
  }
 }
 $environment['XR_API_LAYER_PATH']=$paths -join ';'
 $names=[Collections.Generic.List[string]]::new()
 foreach($name in (@('XR_APILAYER_optishade')+@(([string]$environment['XR_ENABLE_API_LAYERS']) -split ';'))){
  $name=$name.Trim()
  if(-not $name -or $name -ceq 'XR_APILAYER_reshade'){continue}
  if($name -notmatch '^XR_APILAYER_[A-Za-z0-9_]+$'){throw 'XR_ENABLE_API_LAYERS contains a malformed layer name.'}
  if(-not $names.Contains($name)){$names.Add($name)}
 }
 $environment['XR_ENABLE_API_LAYERS']=$names -join ';'
 # Disable only the stock/global ReShade OpenXR layer in this child process.
 # Other implicit layers (Virtual Desktop, OpenXR Toolkit, OBS, etc.) remain discoverable.
 $environment['DISABLE_XR_APILAYER_reshade_1']='1'
 return $true
}
function GetOptiShadeSteamLaunchUri([string]$Exe){
 # Restrict this repair to MSFS; preserve Vulkan and process-scoped OpenXR routes.
 if([IO.Path]::GetFileName($Exe) -notin @('FlightSimulator2024.exe','FlightSimulator.exe')){return $null}
 $game=[IO.Path]::GetFullPath((Split-Path $Exe -Parent))
 if(Test-Path -LiteralPath (Join-Path $game 'OptiShadeData/OpenXR/OptiShade_XR.json') -PathType Leaf){return $null}
 $common=Split-Path $game -Parent;$apps=Split-Path $common -Parent
 if((Split-Path $common -Leaf) -ine 'common' -or (Split-Path $apps -Leaf) -ine 'steamapps'){return $null}
 $ids=@(foreach($file in Get-ChildItem -LiteralPath $apps -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue){
  if($file.Length -gt 1MB){continue}
  $acf=[IO.File]::ReadAllText($file.FullName)
  $dirs=[regex]::Matches($acf,'"installdir"\s+"([^"\/]+)"')
  $appIds=[regex]::Matches($acf,'"appid"\s+"([1-9][0-9]{0,9})"')
  if($dirs.Count -ne 1 -or $appIds.Count -ne 1){continue}
  if($dirs[0].Groups[1].Value -ine (Split-Path $game -Leaf)){continue}
  $id=$appIds[0].Groups[1].Value
  if($file.Name -ine ('appmanifest_'+$id+'.acf')){continue}
  $id
 })
 if($ids.Count -ne 1){return $null}
 return ('steam://rungameid/'+$ids[0])
}
function StartOptiShadeDirectGame([string]$Exe){
 AssertFusionExecutable $Exe
 $leaf=[IO.Path]::GetFileName($Exe)
 if($leaf -ieq 'gamelaunchhelper.exe'){throw 'The Xbox/MS Store helper uses its normal clean launch path.'}
 $steamUri=GetOptiShadeSteamLaunchUri $Exe
 if($steamUri){
  WriteInstallerLog ('Play route: Steam client; uri='+$steamUri+'; matching local appmanifest verified')
  Start-Process -FilePath $steamUri -ErrorAction Stop
  return
 }
 WriteInstallerLog 'Play route: direct executable with process-scoped graphics environment'
 $game=Split-Path $Exe
 $start=[Diagnostics.ProcessStartInfo]::new()
 $start.FileName=$Exe;$start.WorkingDirectory=$game;$start.UseShellExecute=$false
 [void](AddOptiShadeOpenXREnvironment $start $game)
 $process=[Diagnostics.Process]::Start($start)
 if(-not $process){throw 'The simulator did not start.'}
 $process.Dispose()
}

function NewOptiShadeXPlaneStartInfo([string]$Exe,[string]$Store){
 AssertFusionExecutable $Exe
 $isXPlane=[IO.Path]::GetFileName($Exe) -ieq 'X-Plane.exe'
 $identity=GetOptiShadeExecutableIdentity $Exe
 $vulkanOnly=($identity.ApiCandidates -contains 'Vulkan') -and -not(($identity.ApiCandidates -contains 'DX11') -or ($identity.ApiCandidates -contains 'DX12'))
 $disableGraphicsHook=$isXPlane -or $vulkanOnly
 if(TestOptiShadeElevated){throw 'Close OptiShade and reopen it normally (not Run as administrator) before Play. Vulkan ignores local layer paths in elevated processes. No game was launched.'}
 $game=Split-Path $Exe;$layers=OwnedPath $game 'OptiShadeData/Vulkan';$json=OwnedPath $game 'OptiShadeData/Vulkan/OptiShade.json'
 if(-not(Test-Path -LiteralPath $json -PathType Leaf)){throw 'OptiShade.json is missing. Repair using the matching beta manager.'}
 try{$layer=ReadOptiShadeJson $json 'Vulkan layer JSON' -MaxBytes 65536}catch{throw 'OptiShade.json is unreadable or invalid JSON. Repair using the matching beta manager.'}
 if($layer.layer.name -cne 'VK_LAYER_OptiShade_effects' -or $layer.layer.type -cne 'GLOBAL' -or -not $layer.layer.library_path){throw 'OptiShade.json has an invalid layer definition. Repair using the matching beta manager.'}
 if($layer.layer.library_path -cne '..\..\ReShade64.dll'){throw 'OptiShade.json uses an unsupported Windows library path. Update to the latest beta, then use its matching Repair if needed.'}
 try{$resolved=ResolveOptiShadeLibraryPath (Join-Path $layers $layer.layer.library_path)}catch{throw 'OptiShade.json has an invalid library_path. Repair using the matching beta manager.'}
 if($resolved -ine (OwnedPath $game 'ReShade64.dll')){throw 'OptiShade.json does not resolve to the game ReShade64.dll. Repair using the matching beta manager.'}
 $mp=ManifestPath $Store $game
 try{$manifest=ReadOptiShadeJson $mp 'Installation receipt JSON'}catch{throw 'The recorded X-Plane installation is missing or unreadable. Install using this beta manager.'}
 if($manifest.Status -ne 'Installed' -or (FullPath $manifest.Game) -ine (FullPath $game)){throw 'The X-Plane installation is incomplete. Repair using the matching beta manager.'}
 if(-not $isXPlane -and ($manifest.RouteDLL -ne 'OptiShadeGeneric.dll' -or (FullPath $manifest.LaunchExe) -ine (FullPath $Exe))){throw 'Vulkan launch requires the recorded rendering executable and neutral route.'}
 $loaderEntries=@($manifest.Files|Where-Object {$_.SourcePath -eq 'winmm.dll'})
 if($loaderEntries.Count -ne 1){throw 'The recorded OptiScaler Vulkan bridge loader is missing or ambiguous. Repair using the matching beta manager.'}
 $loaderPath=[string]$loaderEntries[0].Path
 if($loaderPath -notin @('winmm.dll','dxgi.dll') -or ($isXPlane -and $loaderPath -cne 'dxgi.dll')){throw 'The recorded Vulkan bridge loader is not an approved game-local entry point. Review installation conflicts in Setup.'}
 foreach($name in @('OptiShadeData/Vulkan/OptiShade.json','ReShade64.dll',$loaderPath)){
  $file=OwnedPath $game $name
  $entry=@($manifest.Files|Where-Object {$_.Path.Replace('\','/') -ieq $name})
  if($entry.Count -ne 1 -or -not $entry[0].Hash -or (HashFile $file) -ne $entry[0].Hash){throw "$name is missing, changed or unrecorded. Repair using the matching beta manager before Play."}
  if($name -eq $loaderPath -and $entry[0].SourcePath -ne 'winmm.dll'){throw 'The Vulkan bridge loader is not owned by OptiShade. Review installation conflicts in Setup.'}
 }
 $start=[Diagnostics.ProcessStartInfo]::new()
 $start.FileName=$Exe;$start.WorkingDirectory=$game;$start.UseShellExecute=$false
 if($isXPlane){$start.Arguments='--allow_reshade'}
 $inherited=$start.EnvironmentVariables
 # Preserve system discovery if no explicit override existed. If one did, ADD is ignored
 # by Vulkan, so merge all local/inherited paths into that effective override instead.
 if(-not [string]::IsNullOrWhiteSpace($inherited['VK_LAYER_PATH'])){
  $inherited['VK_LAYER_PATH']=JoinOptiShadeLayerPaths @($layers,$inherited['VK_LAYER_PATH'],$inherited['VK_ADD_LAYER_PATH'])
  $inherited.Remove('VK_ADD_LAYER_PATH')
 }else{
  $inherited.Remove('VK_LAYER_PATH')
  $inherited['VK_ADD_LAYER_PATH']=JoinOptiShadeLayerPaths @($layers,$inherited['VK_ADD_LAYER_PATH'])
 }
 $names=[Collections.Generic.List[string]]::new()
 foreach($name in (@('VK_LAYER_OptiShade_effects')+@($inherited['VK_INSTANCE_LAYERS'] -split ';'))){
  $name=$name.Trim();if(-not $name -or $name -ceq 'VK_LAYER_reshade'){continue}
  if($name -notmatch '^VK_LAYER_[A-Za-z0-9_]+$'){throw 'VK_INSTANCE_LAYERS contains a malformed layer name. Review the existing Vulkan environment before Play.'}
  if(-not $names.Contains($name)){$names.Add($name)}
 }
 $inherited['VK_INSTANCE_LAYERS']=$names -join ';'
 # Child-process scope only. Unique explicit identity avoids name collisions;
 # the registered upstream implicit runtime must not initialize a second copy.
 $inherited['DISABLE_VK_LAYER_reshade_1']='1'
 $filters=@($inherited['VK_LOADER_LAYERS_DISABLE'] -split ',' | Where-Object {$_})
 if($filters -cnotcontains 'VK_LAYER_reshade'){$filters+= 'VK_LAYER_reshade'}
 $inherited['VK_LOADER_LAYERS_DISABLE']=$filters -join ','
 if($disableGraphicsHook){$inherited['RESHADE_DISABLE_GRAPHICS_HOOK']='1'}
 [void](AddOptiShadeOpenXREnvironment $start $game)
 return $start
}
function StartOptiShadeXPlane([string]$Exe,[string]$Store){
 if(-not $Store){$Store=if($env:OPTISHADE_STORE){$env:OPTISHADE_STORE}else{Join-Path $env:LOCALAPPDATA 'OptiShade'}}
 $game=Split-Path $Exe
 $record=[ordered]@{LaunchOrigin='OptiShade Play';Api='Vulkan (process-scoped layer request)';Arguments=$(if([IO.Path]::GetFileName($Exe) -ieq 'X-Plane.exe'){'--allow_reshade'}else{''});Captured=(Get-Date -Format o);ExecutablePresent=(Test-Path -LiteralPath $Exe -PathType Leaf);JsonPresent=(Test-Path -LiteralPath (Join-Path $game 'OptiShadeData/Vulkan/OptiShade.json'));DxgiPresent=(Test-Path -LiteralPath (Join-Path $game 'dxgi.dll'));LoaderPath='';LoaderPresent=$false;Loader='';Validation='Not completed';LaunchRequested=$false;Inherited=@{};Effective=@{};Binaries=@()}
 foreach($key in @('VK_LAYER_PATH','VK_ADD_LAYER_PATH','VK_INSTANCE_LAYERS')){$record.Inherited[$key]=[bool][Environment]::GetEnvironmentVariable($key,'Process')}
 try{
  $start=NewOptiShadeXPlaneStartInfo $Exe $Store
  $launchManifest=ReadOptiShadeJson (ManifestPath $Store $game) 'Installation receipt JSON'
  $loaderEntry=@($launchManifest.Files|Where-Object {$_.SourcePath -eq 'winmm.dll'})[0]
  $loaderPath=[string]$loaderEntry.Path
  $record.Validation='Passed';$record.ResolvedLibrary='<GAME>/ReShade64.dll'
  foreach($key in @('VK_LAYER_PATH','VK_ADD_LAYER_PATH','VK_INSTANCE_LAYERS','RESHADE_DISABLE_GRAPHICS_HOOK')){
   $value=$start.EnvironmentVariables[$key]
   if($key -in @('VK_LAYER_PATH','VK_ADD_LAYER_PATH')){$index=0;$value=(@($value -split ';'|Where-Object {$_}|ForEach-Object {if($_ -ieq (Join-Path $game 'OptiShadeData/Vulkan')){'<GAME>/OptiShadeData/Vulkan'}else{$index++;"<EXTERNAL_LAYER_PATH_$index>"}}) -join ';')}
   $record.Effective[$key]=$value
  }
  $record.LoaderPath=$loaderPath;$record.LoaderPresent=$true;$record.Loader="$loaderPath (OptiScaler Vulkan bridge)"
  foreach($name in @('ReShade64.dll',$loaderPath)){$file=OwnedPath $game $name;$record.Binaries+=@{Name=$name;SHA256=(HashFile $file);Version=(Get-Item -LiteralPath $file).VersionInfo.FileVersion}}
  $process=[Diagnostics.Process]::Start($start);$record.LaunchRequested=$true;$process.Dispose()
 }catch{$record.Validation='Failed';$record.Reason=$_.Exception.Message;throw}
 finally{
  # Store beside the ownership receipt, outside game files; no global environment/registry changes.
  try{$folder=Split-Path (ManifestPath $Store $game);[void][IO.Directory]::CreateDirectory($folder);$text=$record|ConvertTo-Json -Depth 6;$text=$text.Replace(($game|ConvertTo-Json -Compress).Trim('"'),'<GAME>');if($env:USERPROFILE){$text=$text.Replace(($env:USERPROFILE|ConvertTo-Json -Compress).Trim('"'),'<USERPROFILE>')};[IO.File]::WriteAllText((OwnedPath $folder 'XPlane-launch.json'),$text,[Text.UTF8Encoding]::new($false))}catch{Write-Warning 'Could not save X-Plane launch diagnostics.'}
 }
}
function GetFusionInstallationReceipts([string]$Store,[string]$Game='',[switch]$Strict){
 # Backups retain older manifest.json files. Only Games/<path-id>/manifest.json
 # is current; archived nested receipts must never recreate or rename a game.
 # Selection/status checks already know their installation. Reading every
 # game's large effects receipt here makes each UI refresh scale with the
 # entire library. Keep full enumeration for discovery only, without caching
 # status across an install, update or restore.
 $requestedGame='';$directories=@()
 $recordRoot=Join-Path $Store 'Games'
 if($Strict -and (Test-Path -LiteralPath $recordRoot) -and ((Get-Item -LiteralPath $recordRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'The installation record directory is linked. Operation stopped.'}
 if(-not [string]::IsNullOrWhiteSpace($Game)){
  $requestedGame=ResolveOptiShadeLibraryPath $Game
  $sha=[Security.Cryptography.SHA256]::Create()
  try{$id=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($requestedGame.ToLowerInvariant())))).Replace('-','').Substring(0,16)}finally{$sha.Dispose()}
  $directories=@(Get-Item -LiteralPath (Join-Path (Join-Path $Store 'Games') $id) -ErrorAction SilentlyContinue)
 }else{$directories=@(Get-ChildItem -LiteralPath (Join-Path $Store 'Games') -Directory -ErrorAction SilentlyContinue)}
 foreach($directory in $directories){
  if(-not $directory.PSIsContainer -or $directory.Name -notmatch '^[a-fA-F0-9]{16}$'){continue}
  if($directory.Attributes -band [IO.FileAttributes]::ReparsePoint){if($Strict){throw 'A canonical installation record directory is linked. Operation stopped.'};continue}
  $file=Join-Path $directory.FullName 'manifest.json'
  try{
   if(-not(Test-Path -LiteralPath $file -PathType Leaf)){continue}
   if((Get-Item -LiteralPath $file).Length -gt 16MB -or ((Get-Item -LiteralPath $file).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'The canonical installation receipt is too large or linked.'}
   $m=ReadOptiShadeJson $file 'Installation receipt' -MaxBytes 16777216
   $game=ResolveOptiShadeLibraryPath ([string]$m.Game)
   if($requestedGame -and -not [string]::Equals($game,$requestedGame,[StringComparison]::OrdinalIgnoreCase)){continue}
   $sha=[Security.Cryptography.SHA256]::Create()
   try{$id=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($game.ToLowerInvariant())))).Replace('-','').Substring(0,16)}finally{$sha.Dispose()}
   if($directory.Name -ine $id){if($Strict){throw 'The installation receipt does not match its canonical game folder identity.'};continue}
   [pscustomobject]@{FullName=$file;Name='manifest.json';Manifest=$m}
  }catch{if($Strict){throw}}
 }
}
function GetFusionInstallState([string]$Store,[string]$Game){
 $gamePath=ResolveFusionInstallFolder $Game
 foreach($file in GetFusionInstallationReceipts $Store $gamePath){
  try{$m=$file.Manifest;if((ResolveOptiShadeLibraryPath $m.Game) -ne $gamePath){continue}
   if($m.Status -eq 'Installed'){
    $loaders=@($m.Files|Where-Object {$_.SourcePath -in @('winmm.dll','ReShade32.dll')})
    foreach($loader in $loaders){
     $loaderPath=ResolveOptiShadeLibraryPath (Join-Path $gamePath $loader.Path)
     if(-not $loaderPath.StartsWith($gamePath+'\',[StringComparison]::OrdinalIgnoreCase) -or -not(Test-Path -LiteralPath $loaderPath -PathType Leaf)){return 'Installation incomplete - repair required'}
     if((Get-Item -LiteralPath $loaderPath).Length -eq 0){return 'Installation incomplete - repair required'}
    }
    if(Test-Path -LiteralPath (Join-Path (Split-Path $file.FullName) 'MfgRouteTransaction.json')){return 'Installed - recovery required'}
    if($m.AutoCompatibility -and @($m.AutoCompatibility.Features.PSObject.Properties|Where-Object {$_.Value.State -ceq 'needs_review'}).Count){return 'Installed - component review required'}
    if($m.Downloads -eq 'Pending'){if($m.AutoCompatibility){return 'Installed - Auto preparation pending'};return 'Installed - downloads pending'};return 'Installed'
   }
   if($m.Status -eq 'Restored'){return 'Not installed (restored)'}
   return 'Installation incomplete - repair required'
  }catch{}
 }
 if(Test-Path -LiteralPath (Join-Path $gamePath 'ReShade64.dll')){return 'Graphics files detected - not tracked'}
 return 'Not installed'
}
 function FindFusionGames([string]$Store,[scriptblock]$Progress={param($text,$completed=0,$total=0)}){
  $phase=0;$phaseCount=8
  &$Progress 'Checking registered game installations...' $phase $phaseCount;$phase++
 $games=@{}
 function AddGame($name,$folder,$launcher){
  if(-not $folder){return}
  $catalogueName=[string]$name
  if(-not(TestFusionLibraryCandidateName $catalogueName)){return}
  try{
   $folder=ResolveFusionInstallFolder $folder
   AssertFusionPhysicalFolder $folder
   # Resolve known protected simulator launchers automatically. Other catalogue
   # entries stay in the Library and ask the user to choose the real game EXE.
   $knownTitle=GetMsfsTitle $folder
   if($knownTitle){$executable=@(FindFusionExecutable $folder $launcher);if($executable.Count -ne 1){return}}
  }catch{return}
  $name=if($knownTitle){$knownTitle}else{$catalogueName}
  if(-not(TestFusionLibraryCandidateName $name)){return}
  if(-not $folder -or -not(Test-Path -LiteralPath $folder -PathType Container)){return}
  $folder=ResolveOptiShadeLibraryPath $folder;$key=$folder.ToLowerInvariant()
  if(-not $games.ContainsKey($key)){$games[$key]=[pscustomobject]@{Name=$name;Folder=$folder;Launcher=$launcher;State='Not installed';Label=''}}
 }
 foreach($list in @((Join-Path $env:LOCALAPPDATA 'x-plane_install_12.txt'),(Join-Path $env:LOCALAPPDATA 'x-plane_install_12_demo.txt'))){
  if(Test-Path -LiteralPath $list){foreach($folder in Get-Content -LiteralPath $list){AddGame 'X-Plane 12' $folder 'Laminar Research'}}
 }
  &$Progress 'Checking Steam library locations...' $phase $phaseCount;$phase++
  $steam=@("${env:ProgramFiles(x86)}\Steam")
 $registered=(Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
 if($registered){$steam+= $registered}
 foreach($key in @('HKLM:\SOFTWARE\WOW6432Node\Valve\Steam','HKLM:\SOFTWARE\Valve\Steam')){
  $registered=(Get-ItemProperty $key -ErrorAction SilentlyContinue).InstallPath
  if($registered){$steam+=$registered}
 }
 $steam=@($steam|ForEach-Object {try{ResolveFusionInstallFolder $_}catch{}}|Select-Object -Unique)
 foreach($base in @($steam)){
  $vdf=Join-Path $base 'steamapps/libraryfolders.vdf'
  try{if(Test-Path -LiteralPath $vdf){foreach($match in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw -Encoding UTF8),'"path"\s+"([^"]+)"')){try{$steam+=ResolveFusionInstallFolder $match.Groups[1].Value.Replace('\\','\')}catch{}}}}catch{}
 }
  foreach($base in ($steam|Select-Object -Unique)){
   &$Progress ('Checking Steam library: '+$base) $phase $phaseCount
  foreach($file in Get-ChildItem -LiteralPath (Join-Path $base 'steamapps') -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue){
   try{
   $data=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
   $name=[regex]::Match($data,'"name"\s+"([^"]+)"').Groups[1].Value
   $dir=[regex]::Match($data,'"installdir"\s+"([^"]+)"').Groups[1].Value
   if($dir){AddGame $name (Join-Path $base "steamapps/common/$dir") 'Steam'}
   }catch{}
  }
 }
  &$Progress 'Checking Epic Games registrations...' $phase $phaseCount;$phase++
  foreach($file in Get-ChildItem "$env:ProgramData/Epic/EpicGamesLauncher/Data/Manifests" -Filter '*.item' -File -ErrorAction SilentlyContinue){
  try{$item=ReadOptiShadeJson $file.FullName 'Launcher or installation JSON';AddGame $item.DisplayName $item.InstallLocation 'Epic'}catch{}
 }
  &$Progress 'Checking Xbox and custom game folders...' $phase $phaseCount;$phase++
  foreach($drive in Get-PSDrive -PSProvider FileSystem){
   &$Progress ('Checking game folders on '+$drive.Root) $phase $phaseCount
  foreach($entry in Get-ChildItem -LiteralPath (Join-Path $drive.Root 'XboxGames') -Directory -ErrorAction SilentlyContinue){AddGame $entry.Name (Join-Path $entry.FullName 'Content') 'Xbox'}
  foreach($entry in Get-ChildItem -LiteralPath (Join-Path $drive.Root 'Xbox games') -Directory -ErrorAction SilentlyContinue){AddGame $entry.Name (Join-Path $entry.FullName 'Content') 'Xbox'}
  # Common non-Steam store roots. Keep this to the drive root and one known
  # launcher subdirectory: never crawl an entire disk or guess through arbitrary
  # folders. AddGame and the final executable matcher reject non-game entries.
  foreach($rootName in @('GOG Games','EA Games','Origin Games','Amazon Games\Library')){
   $storeRoot=Join-Path $drive.Root $rootName
   if(Test-Path -LiteralPath $storeRoot -PathType Container -ErrorAction SilentlyContinue){
    try{AssertFusionPhysicalFolder $storeRoot}catch{continue}
    foreach($entry in Get-ChildItem -LiteralPath $storeRoot -Directory -ErrorAction SilentlyContinue|Select-Object -First 200){
     if(-not($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)){AddGame $entry.Name $entry.FullName ''}
    }
   }
  }
  foreach($relativeRoot in @('GOG Galaxy\Games','Ubisoft Game Launcher\games','Ubisoft Connect\games','Program Files (x86)\Battle.net\Games','Program Files\Battle.net\Games')){
   $storeRoot=Join-Path $drive.Root $relativeRoot
   if(-not(Test-Path -LiteralPath $storeRoot -PathType Container -ErrorAction SilentlyContinue)){continue}
   try{AssertFusionPhysicalFolder $storeRoot}catch{continue}
   foreach($entry in Get-ChildItem -LiteralPath $storeRoot -Directory -ErrorAction SilentlyContinue|Select-Object -First 200){
    if(-not($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)){AddGame $entry.Name $entry.FullName ''}
   }
  }
  # Bounded custom game roots; inspect only the root and direct children.
  # This covers layouts such as C:\MSFS\Microsoft Flight Simulator\Content.
  foreach($rootName in @('MSFS','MSFS2020','MSFS2024')){
   $custom=Join-Path $drive.Root $rootName
   if(-not(Test-Path -LiteralPath $custom -PathType Container -ErrorAction SilentlyContinue)){continue}
   try{AssertFusionPhysicalFolder $custom}catch{continue}
   if(GetMsfsTitle $custom){AddGame $rootName $custom ''}
   foreach($entry in Get-ChildItem -LiteralPath $custom -Directory -ErrorAction SilentlyContinue|Select-Object -First 100){
    if(-not($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -and (GetMsfsTitle $entry.FullName)){AddGame $entry.Name $entry.FullName ''}
   }
  }
 }
 # Registered Store packages may live outside the default XboxGames folders.
 # Query only the two simulator identities, never enumerate protected disk trees.
  &$Progress 'Checking supported Microsoft Store games...' $phase $phaseCount;$phase++
  if(Get-Command Get-AppxPackage -ErrorAction SilentlyContinue){
  foreach($identity in @('Microsoft.FlightSimulator','Microsoft.Limitless')){
   try{foreach($package in Get-AppxPackage -Name $identity -ErrorAction Stop){if(TestFusionSimulatorPackageIdentity $identity ([string]$package.Name)){AddGame $package.Name $package.InstallLocation 'Xbox'}}}catch{}
  }
 }
  &$Progress 'Checking registered game install locations...' $phase $phaseCount;$phase++
 foreach($registeredGame in GetFusionRegisteredGameLocations){
  AddGame $registeredGame.Name $registeredGame.Folder ('Registered: '+$registeredGame.Publisher)
 }
  &$Progress 'Matching saved OptiShade installations to detected games...' $phase $phaseCount;$phase++
  foreach($file in GetFusionInstallationReceipts $Store){
   &$Progress ('Reading installation record: '+$file.Name) $phase $phaseCount
  try{
   $m=$file.Manifest
   $parent=@($games.Values|Where-Object {$m.Game -ieq $_.Folder -or $m.Game.StartsWith($_.Folder+'\',[StringComparison]::OrdinalIgnoreCase)}|Sort-Object @{Expression={$_.Folder.Length};Descending=$true})|Select-Object -First 1
   if($parent){$parent.State=$m.Status;if($m.Status -eq 'Installed' -and $m.Downloads -eq 'Pending'){$parent.State='Installed - finish downloads'};$parent|Add-Member -NotePropertyName InstallFolder -NotePropertyValue $m.Game -Force}
   else{
    $title=GetMsfsTitle $m.Game
    if(-not $title){$title=[string]$m.DisplayName}
    if(-not $title){$title=GetFusionFolderTitle $m.Game}
    AddGame $title $m.Game 'Added by you';$key=(ResolveOptiShadeLibraryPath $m.Game).ToLowerInvariant();if($games.ContainsKey($key)){$games[$key].State=$m.Status;if($m.Status -eq 'Installed' -and $m.Downloads -eq 'Pending'){$games[$key].State='Installed - finish downloads'}}}
  }catch{}
 }
  &$Progress 'Verifying detected game folders...' $phase $phaseCount
  $validated=@(foreach($game in $games.Values){
  try{
   $installPath=ResolveFusionInstallFolder $(if($game.InstallFolder){$game.InstallFolder}else{$game.Folder})
   $null=FindFusionExecutable $installPath $game.Launcher $game.Name
   $game|Add-Member -NotePropertyName InstallFolder -NotePropertyValue $installPath -Force
   $game.State=GetFusionInstallState $Store $installPath
   $game.Label="$($game.Name) / $($game.Launcher) - OptiShade $($game.State)"
   $game
  }catch{} # A stale installation record must not hide other valid games.
 })
 @($validated|Sort-Object Name)
}
function FindFusionAntiCheat([string]$Game){
 . "$PSScriptRoot/anti-cheat.ps1"
 InvokeAntiCheatScan -Game $Game
}
function GetFusionGpu{
 $facts=GetOptiShadeGpuFacts
 $devices=@();try{$devices=@(Get-CimInstance Win32_VideoController -ErrorAction Stop)}catch{}
 $cards=@($devices|ForEach-Object Name)
 $drivers=@(foreach($device in $devices){
  $raw=[string]$device.DriverVersion;$display=$raw
  if($device.Name -match 'NVIDIA' -and $raw -match '^\d+\.\d+\.(\d+)\.(\d{1,4})$'){$number=(([int]$Matches[1]%10)*10000)+[int]$Matches[2];$display=('{0}.{1:00}' -f [math]::Floor($number/100),($number%100))}
  [pscustomobject]@{Name=$device.Name;Version=$display;WindowsVersion=$raw}
 })
 if(@($facts.Adapters).Count){$cards=@($facts.Adapters|Where-Object {-not $_.Software}|ForEach-Object Name)}
 [pscustomobject]@{Names=($cards -join ', ');Nvidia=[bool](@($facts.Adapters|Where-Object VendorId -eq 0x10DE).Count);Known=($cards.Count -gt 0);Drivers=$drivers;Adapters=@($facts.Adapters);Complete=[bool]$facts.Complete;IdentityError=[string]$facts.Error}
}
. "$PSScriptRoot/executable.ps1"
function AssertFusionExecutable([string]$File){$null=GetOptiShadeExecutableIdentity $File}
function ConvertToFusionMatchText([string]$Value){
 if(-not $Value){return ''}
 $text=[regex]::Replace($Value.ToLowerInvariant(),'[^a-z0-9]+',' ').Trim()
 return [regex]::Replace($text,'\s+',' ')
}
function GetFusionExecutableMatchScore([string]$File,[string]$Title,[string]$GameFolder){
 $leaf=[IO.Path]::GetFileNameWithoutExtension($File);$stem=ConvertToFusionMatchText $leaf
 $directory=ConvertToFusionMatchText (Split-Path $GameFolder -Leaf)
 $product=''
 try{$info=[Diagnostics.FileVersionInfo]::GetVersionInfo($File);$product=($info.ProductName+' '+$info.FileDescription+' '+$info.OriginalFilename+' '+$info.InternalName)}catch{}
 $metadata=ConvertToFusionMatchText $product;$titleText=if($Title){$Title}else{Split-Path $GameFolder -Leaf};$titleNorm=ConvertToFusionMatchText $titleText
 $aliases=@()
 if($titleNorm -match 'euro truck simulator 2|\bets2\b'){$aliases+=@('eurotrucks2','ets2')}
 if($titleNorm -match 'beamng'){$aliases+=@('beamng drive','beamng')}
 if($titleNorm -match 'grand theft auto v|\bgta v\b'){$aliases+=@('gta5','gtav','grand theft auto v')}
 foreach($alias in $aliases){$aliasNorm=ConvertToFusionMatchText $alias;if($stem -eq $aliasNorm -or $stem.StartsWith($aliasNorm+' ') -or $metadata -match ('(^| )'+[regex]::Escape($aliasNorm)+'($| )')){return 100}}
 if($titleNorm -and ($stem -eq $titleNorm -or $metadata.Contains($titleNorm))){return 100}
 if($titleNorm -and ($stem.StartsWith($titleNorm+' ') -or $metadata.StartsWith($titleNorm+' '))){return 92}
 if($directory -and ($stem -eq $directory -or $stem.StartsWith($directory+' '))){return 88}
 $tokens=@($titleNorm.Split(' ')|Where-Object { $_.Length -ge 3 -and $_ -notin @('the','game','edition','windows') }|Select-Object -Unique)
 if($tokens.Count -ge 2){$haystack=' '+$metadata+' '+$stem+' ';$matched=@($tokens|Where-Object {$haystack.Contains(' '+$_+' ')}).Count;if($matched -eq $tokens.Count){return 84}}
 return 0
}
# GIANTS' Farming Simulator EXE in the game root is a stub that starts
# x64\<name>Game.exe, which never loads proxy DLLs from the root (OSD-NXJ5).
function ResolveFusionStubLauncherExecutable([string]$Executable){
 $leaf=[IO.Path]::GetFileNameWithoutExtension($Executable)
 if($leaf -notmatch '^(?i)FarmingSimulator20\d\d$'){return $Executable}
 $root=Split-Path ([IO.Path]::GetFullPath($Executable)) -Parent
 $target=Join-Path (Join-Path $root 'x64') ($leaf+'Game.exe')
 if(-not(Test-Path -LiteralPath $target -PathType Leaf)){return $Executable}
 AssertFusionPhysicalFolder (Split-Path $target -Parent)
 if((Get-Item -LiteralPath $target -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The game target is a linked executable.'}
 return [IO.Path]::GetFullPath($target)
}
function ResolveFusionBootstrapExecutable([string]$Executable){
 $identity=GetOptiShadeExecutableIdentity $Executable
 if(-not $identity.BootstrapRelativePath){return (ResolveFusionStubLauncherExecutable $Executable)}
 $root=Split-Path ([IO.Path]::GetFullPath($Executable)) -Parent
 $relative=[string]$identity.BootstrapRelativePath
 if([IO.Path]::IsPathRooted($relative) -or @($relative -split '[\\/]'|Where-Object {$_ -in @('.','..')}).Count){throw 'The packaged game target escapes its installation folder.'}
 $target=[IO.Path]::GetFullPath((Join-Path $root $relative))
 if(-not $target.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'The packaged game target escapes its installation folder.'}
 AssertFusionPhysicalFolder (Split-Path $target -Parent)
 if((Get-Item -LiteralPath $target -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The packaged game target is a linked executable.'}
 $rendering=GetOptiShadeExecutableIdentity $target
 if($rendering.BootstrapRelativePath){throw 'The packaged game target is another launcher. Select its rendering executable.'}
 return $target
}
function GetFusionNativeLaunchExecutable($Manifest,[string]$RenderingExecutable){
 if(-not $Manifest.NativeLaunchExe -or [string]$Manifest.NativeLaunchExe -ieq $RenderingExecutable){return $RenderingExecutable}
 $launch=[string]$Manifest.NativeLaunchExe
 if((ResolveFusionBootstrapExecutable $launch) -ine [IO.Path]::GetFullPath($RenderingExecutable)){throw 'The game launcher now targets a different executable. Scan and repair this game before launching.'}
 return $launch
}
function FindFusionExecutable([string]$Game,[string]$Launcher='',[string]$Title=''){
 if(-not $Game -or -not(Test-Path -LiteralPath $Game -PathType Container)){return @()}
 $Game=ResolveFusionInstallFolder $Game
 AssertFusionPhysicalFolder $Game
 $leaf=[IO.Path]::GetFileName($Game)
 if($leaf -ieq 'X-Plane.exe'){$Game=Split-Path $Game -Parent;$leaf=[IO.Path]::GetFileName($Game)}
 $xp=Join-Path $Game 'X-Plane.exe';if(Test-Path -LiteralPath $xp -PathType Leaf){AssertFusionExecutable $xp;return [pscustomobject]@{Path=$xp;Score=1000}}
 # MSFS Xbox uses the accessible launch helper beside the protected game EXE.
 # Steam uses the game EXE directly. Both install beside the selected executable.
 foreach($folder in @($Game,(Join-Path $Game 'Content'))){
  $main=Join-Path $folder 'FlightSimulator2024.exe';if(-not(Test-Path -LiteralPath $main)){$main=Join-Path $folder 'FlightSimulator.exe'};$helper=Join-Path $folder 'gamelaunchhelper.exe'
  if(Test-Path -LiteralPath $main -PathType Leaf){
   $xbox=$Launcher -eq 'Xbox' -or ($Launcher -ne 'Steam' -and (Test-Path -LiteralPath (Join-Path $folder 'MicrosoftGame.Config')))
   $target=if($xbox -and ((Test-Path -LiteralPath $helper) -or (Split-Path $main -Leaf) -eq 'FlightSimulator2024.exe')){$helper}else{$main}
   if(-not(Test-Path -LiteralPath $target -PathType Leaf)){throw "Microsoft Flight Simulator launcher is missing: $target. Repair the game through its launcher first."}
   AssertFusionExecutable $target
   return @([pscustomobject]@{Path=$target;Score=1000})
  }
 }
 $knownSimulator=GetFusionExpectedSimulatorTitle $Title
 if($knownSimulator -in @('Microsoft Flight Simulator 2024','Microsoft Flight Simulator 2020')){
  $nested=@(GetFusionNestedMsfsExecutables $Game $knownSimulator)
  if($nested.Count -eq 1){
   $main=$nested[0];$folder=Split-Path $main -Parent;$helper=Join-Path $folder 'gamelaunchhelper.exe'
   $xbox=$Launcher -eq 'Xbox' -or (Test-Path -LiteralPath (Join-Path $folder 'MicrosoftGame.Config'))
   if($xbox -and -not(Test-Path -LiteralPath $helper -PathType Leaf)){throw "Microsoft Flight Simulator launcher is missing: $helper. Repair the game through its launcher first."}
   $target=if($xbox){$helper}else{$main};AssertFusionExecutable $target
   return @([pscustomobject]@{Path=$target;Score=1000})
  }
 }
 # For catalogued PC games, use a bounded filename/product-name match. Never pick
 # the first EXE in a folder: launchers, anti-cheat, editors and crash tools are common.
 $titleText=if($Title -and $Title -notmatch '^(?i)Add a game$'){$Title}else{$leaf}
 $pending=New-Object 'System.Collections.Generic.Queue[object]';$pending.Enqueue([pscustomobject]@{Path=$Game;Depth=0})
 $ignoredDirectory='(?i)^(?:_?commonredist|redist|redistributables|easy.?anticheat|battleye|crashreportclient|crashpad|launcher|installers?|prerequisites|support|tools|dedicatedserver|server|editor|benchmark|thirdparty)$'
 $ignoredExecutable='(?i)(?:webhelper|launcher|crash|report|setup|installer|unins|updat|bootstrap|anti.?cheat|easy.?anticheat|battleye|redist|redistribut|dxsetup|vc_redist|dedicated.?server|server\.exe|editor\.exe|benchmark|repair)'
 $ranked=New-Object 'System.Collections.Generic.List[object]';$visited=0;$filesSeen=0
 while($pending.Count -and $visited -lt 72 -and $filesSeen -lt 320){
  $node=$pending.Dequeue();$visited++
  foreach($file in Get-ChildItem -LiteralPath $node.Path -File -Filter '*.exe' -ErrorAction SilentlyContinue|Select-Object -First 80){
   $filesSeen++;$name=[IO.Path]::GetFileName($file.FullName)
   if($name -match $ignoredExecutable){continue}
   $score=GetFusionExecutableMatchScore $file.FullName $titleText $Game
   if($score -lt 80 -and $file.DirectoryName -match '(?i)(?:\\|/)(?:bin[\\/]win_x64|binaries[\\/]win64|win_x64)$'){$score=82}
   if($score -ge 80){$ranked.Add([pscustomobject]@{Path=$file.FullName;Score=$score})}
   if($filesSeen -ge 320){break}
  }
  if($node.Depth -ge 5){continue}
  foreach($directory in Get-ChildItem -LiteralPath $node.Path -Directory -Force -ErrorAction SilentlyContinue){
   if(($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $directory.Name -match $ignoredDirectory){continue}
   $pending.Enqueue([pscustomobject]@{Path=$directory.FullName;Depth=$node.Depth+1})
  }
 }
 if(-not $ranked.Count){return @()}
 $ranked=@($ranked|Sort-Object @{Expression={$_.Score};Descending=$true},Path -Unique)
 $best=$ranked[0]
 try{AssertFusionExecutable $best.Path;$rendering=ResolveFusionBootstrapExecutable $best.Path}catch{return @()}
 $nativeLaunch=$best.Path;$aliases=@()
 foreach($candidate in $ranked){
  if($candidate.Path -ieq $best.Path){continue}
  try{
   $metadata=[Diagnostics.FileVersionInfo]::GetVersionInfo($candidate.Path)
   if($metadata.OriginalFilename -like 'BootstrapPackagedGame*.exe' -and (ResolveFusionBootstrapExecutable $candidate.Path) -ieq $rendering){$aliases+=@($candidate.Path);$nativeLaunch=$candidate.Path}
  }catch{} # Invalid secondary launchers cannot replace the verified target.
 }
 # A launcher and its exact embedded target are one choice, not an ambiguity.
 $ranked=@($ranked|Where-Object {($_.Path -ieq $best.Path -or $_.Path -ine $rendering) -and $_.Path -notin $aliases})
 $ties=@($ranked|Where-Object Score -eq $best.Score)
 if($ties.Count -ne 1){return @()}
 if($ranked.Count -gt 1 -and ($best.Score-$ranked[1].Score) -lt 16){return @()}
 return @([pscustomobject]@{Path=$rendering;LaunchPath=$nativeLaunch;Score=$best.Score})
}
function GetFusionGameArtwork($Games){
 Add-Type -AssemblyName System.Drawing
 foreach($game in $Games){
  $art=''
  try{
   $exe=@(FindFusionExecutable $game.Folder $game.Launcher $game.Name)|Select-Object -First 1
   # Prefer game-owned launcher artwork. No generated/reference artwork is shipped.
   $thumbnail=$null
   if($game.Launcher -eq 'Steam'){
    $steam=(Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    $library=Split-Path (Split-Path $game.Folder -Parent) -Parent
    foreach($manifest in Get-ChildItem -LiteralPath $library -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue){
     $acf=Get-Content -LiteralPath $manifest.FullName -Raw
     if($acf -match '"installdir"\s+"([^"]+)"' -and $Matches[1] -eq (Split-Path $game.Folder -Leaf)){
      if($acf -match '"appid"\s+"([0-9]+)"'){
       $appId=$Matches[1];$cache=Join-Path $steam 'appcache/librarycache'
       $thumbnail=@(Get-ChildItem -LiteralPath $cache -Filter ($appId+'_library_600x900*') -File -ErrorAction SilentlyContinue;Get-ChildItem -LiteralPath (Join-Path $cache $appId) -File -ErrorAction SilentlyContinue|Where-Object Name -match 'library_600x900')|Select-Object -First 1
      }
     }
    }
   }
   if(-not $thumbnail){$assets=Join-Path $game.Folder 'Assets';$thumbnail=@(Get-ChildItem -LiteralPath $assets -File -ErrorAction SilentlyContinue|Where-Object Name -match 'Square150x150Logo|StoreLogo')|Sort-Object Length -Descending|Select-Object -First 1}
   if(-not $thumbnail){$thumbnail=@(foreach($name in @('Logo.png','StoreLogo.png')){Get-Item -LiteralPath (Join-Path $game.Folder $name) -ErrorAction SilentlyContinue})|Select-Object -First 1}
   if($thumbnail){$art=[Convert]::ToBase64String([IO.File]::ReadAllBytes($thumbnail.FullName))}
   if(-not $art -and $exe){$icon=[Drawing.Icon]::ExtractAssociatedIcon($exe.Path);if($icon){$bitmap=$icon.ToBitmap();$memory=New-Object IO.MemoryStream;try{$bitmap.Save($memory,[Drawing.Imaging.ImageFormat]::Png);$art=[Convert]::ToBase64String($memory.ToArray())}finally{$memory.Dispose();$bitmap.Dispose();$icon.Dispose()}}}
  }catch{}
  $game|Add-Member -NotePropertyName Artwork -NotePropertyValue $art -Force
 }
 $Games
}

# Historical public function name retained for scripts calling this entry point.
# Deployment admits a real x64 game; NR/FG capability remains a runtime decision.
function AssertMsfsNvidiaTarget([string]$Exe,$Gpu){AssertFusionExecutable $Exe}
