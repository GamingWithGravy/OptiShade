# Read launcher catalogues; never crawl entire disks or start games during discovery.
function ResolveFusionStoreFolder([string]$Folder){
 # Appx InstallLocation can be a protected package path or an Xbox junction.
 # Never install through WindowsApps or relax OwnedPath's link protection.
 if($Folder -notmatch '(?i)[\\/]WindowsApps(?:[\\/]|$)'){return $Folder}
 $help='This is a WindowsApps package path, not an installable game folder. In the Xbox app, open the simulator > Manage > Files, then select its installation folder using Browse. OptiShade will not change WindowsApps permissions.'
 if($Folder -notmatch '(?i)[\\/]WindowsApps[\\/]Microsoft\.(FlightSimulator|Limitless)_[^\\/]+$'){throw $help}
 $edition=$Matches[1]
 try{
  $item=Get-Item -LiteralPath $Folder -Force -ErrorAction Stop
  if(-not($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw $help}
  $targets=@($item.Target|Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
  if($targets.Count -ne 1){throw $help}
  $target=[string]$targets[0]
  if($target.StartsWith('\??\')){$target=$target.Substring(4)}
  if($target -notmatch '^[A-Za-z]:[\\/]' -or $target -match '(?i)[\\/]WindowsApps(?:[\\/]|$)'){throw $help}
  $target=[IO.Path]::GetFullPath($target).TrimEnd('\')
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
 if([string]::IsNullOrWhiteSpace($Game)){throw 'Choose the simulator installation folder using Browse.'}
 $candidate=[Environment]::ExpandEnvironmentVariables($Game.Trim().Trim('"').Trim())
 if($candidate -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+)' -or $candidate.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0 -or $candidate -match '[*?]'){
  throw 'The installation path is invalid. Use Browse to select the simulator installation folder.'
 }
 try{$folder=[IO.Path]::GetFullPath($candidate).TrimEnd('\')}catch{throw 'The installation path is invalid. Use Browse to select the simulator installation folder.'}
 if([IO.Path]::GetFileName($folder) -in @('FlightSimulator2024.exe','FlightSimulator.exe','gamelaunchhelper.exe','X-Plane.exe')){$folder=Split-Path $folder -Parent}
 $folder=ResolveFusionStoreFolder $folder
 foreach($candidate in @($folder,(Join-Path $folder 'Content'))){
  foreach($exe in @('FlightSimulator2024.exe','FlightSimulator.exe','X-Plane.exe')){if(Test-Path -LiteralPath (Join-Path $candidate $exe) -PathType Leaf){return $candidate}}
 }
 return $folder
}
function GetMsfsTitle([string]$Game){
 try{$folder=ResolveFusionInstallFolder $Game}catch{return ''}
 if(-not $folder){return ''}
 if(Test-Path -LiteralPath (Join-Path $folder 'X-Plane.exe') -PathType Leaf){return 'X-Plane 12 (experimental)'}
 if(Test-Path -LiteralPath (Join-Path $folder 'FlightSimulator2024.exe') -PathType Leaf){return 'Microsoft Flight Simulator 2024'}
 if(Test-Path -LiteralPath (Join-Path $folder 'FlightSimulator.exe') -PathType Leaf){return 'Microsoft Flight Simulator 2020'}
 return ''
}
function AssertFusionPhysicalFolder([string]$Folder){
 $check=$Folder
 while($check){
  if((Get-Item -LiteralPath $check -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){
   throw 'Select the actual simulator installation folder, not a linked or WindowsApps folder. For Xbox installs, use the location shown under Manage > Files and select its Content folder.'
  }
  $parent=Split-Path $check -Parent;if($parent -eq $check){break};$check=$parent
 }
}
function StartOptiShadeXPlane([string]$Exe){
 AssertFusionExecutable $Exe
 $game=Split-Path $Exe
 $layers=Join-Path $game 'OptiShadeData/Vulkan'
 if(-not(Test-Path -LiteralPath (Join-Path $layers 'OptiShade.json'))){throw 'The X-Plane Vulkan layer is missing. Repair with the manager matching the installed version.'}
 $start=[Diagnostics.ProcessStartInfo]::new()
 $start.FileName=$Exe;$start.WorkingDirectory=$game;$start.UseShellExecute=$false
 # X-Plane otherwise disables the explicitly requested ReShade Vulkan layer.
 $start.Arguments='--allow_reshade'
 $start.EnvironmentVariables['VK_ADD_LAYER_PATH']=$layers
 $start.EnvironmentVariables['VK_INSTANCE_LAYERS']='VK_LAYER_reshade'
 $start.EnvironmentVariables['RESHADE_DISABLE_GRAPHICS_HOOK']='1'
 # Only this child process receives the layer settings; no system environment or registry changes.
 $process=[Diagnostics.Process]::Start($start);$process.Dispose()
}
function GetFusionInstallState([string]$Store,[string]$Game){
 $gamePath=ResolveFusionInstallFolder $Game
 foreach($file in Get-ChildItem (Join-Path $Store 'Games') -Filter manifest.json -Recurse -File -ErrorAction SilentlyContinue){
  try{$m=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8|ConvertFrom-Json;if([IO.Path]::GetFullPath($m.Game).TrimEnd('\') -ne $gamePath){continue}
   if($m.Status -eq 'Installed'){
    $loaders=@($m.Files|Where-Object {$_.SourcePath -eq 'winmm.dll'})
    foreach($loader in $loaders){
     $loaderPath=[IO.Path]::GetFullPath((Join-Path $gamePath $loader.Path))
     if(-not $loaderPath.StartsWith($gamePath+'\',[StringComparison]::OrdinalIgnoreCase) -or -not(Test-Path -LiteralPath $loaderPath -PathType Leaf)){return 'Installation incomplete - repair required'}
     if((Get-Item -LiteralPath $loaderPath).Length -eq 0){return 'Installation incomplete - repair required'}
    }
    if($m.Downloads -eq 'Pending'){return 'Installed - downloads pending'};return 'Installed'
   }
   if($m.Status -eq 'Restored'){return 'Not installed (restored)'}
   return 'Installation incomplete - repair required'
  }catch{}
 }
 if(Test-Path -LiteralPath (Join-Path $gamePath 'ReShade64.dll')){return 'Graphics files detected - not tracked'}
 return 'Not installed'
}
function FindFusionGames([string]$Store){
 $games=@{}
 function AddGame($name,$folder,$launcher){
  if(-not $folder){return}
  try{
   $folder=ResolveFusionInstallFolder $folder
   AssertFusionPhysicalFolder $folder
   # A catalogue entry alone is not enough: validate the launchable x64 EXE.
   $executable=@(FindFusionExecutable $folder $launcher)
   if($executable.Count -ne 1){return}
  }catch{return}
  $name=GetMsfsTitle $folder
  if(-not $name){return}
  if($name -match 'Steamworks Common|SteamVR|Oasis Driver|Unreal Engine|Fab UE Plugin|Quixel Bridge|Minecraft Launcher'){return}
  if(-not $folder -or -not(Test-Path -LiteralPath $folder -PathType Container)){return}
  $folder=[IO.Path]::GetFullPath($folder).TrimEnd('\');$key=$folder.ToLowerInvariant()
  if(-not $games.ContainsKey($key)){$games[$key]=[pscustomobject]@{Name=$name;Folder=$folder;Launcher=$launcher;State='Not installed';Label=''}}
 }
 foreach($list in @((Join-Path $env:LOCALAPPDATA 'x-plane_install_12.txt'),(Join-Path $env:LOCALAPPDATA 'x-plane_install_12_demo.txt'))){
  if(Test-Path -LiteralPath $list){foreach($folder in Get-Content -LiteralPath $list){AddGame 'X-Plane 12' $folder 'Laminar Research'}}
 }
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
  foreach($file in Get-ChildItem -LiteralPath (Join-Path $base 'steamapps') -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue){
   try{
   $data=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
   $name=[regex]::Match($data,'"name"\s+"([^"]+)"').Groups[1].Value
   $dir=[regex]::Match($data,'"installdir"\s+"([^"]+)"').Groups[1].Value
   if($dir){AddGame $name (Join-Path $base "steamapps/common/$dir") 'Steam'}
   }catch{}
  }
 }
 foreach($file in Get-ChildItem "$env:ProgramData/Epic/EpicGamesLauncher/Data/Manifests" -Filter '*.item' -File -ErrorAction SilentlyContinue){
  try{$item=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8|ConvertFrom-Json;AddGame $item.DisplayName $item.InstallLocation 'Epic'}catch{}
 }
 foreach($drive in Get-PSDrive -PSProvider FileSystem){
  foreach($entry in Get-ChildItem -LiteralPath (Join-Path $drive.Root 'XboxGames') -Directory -ErrorAction SilentlyContinue){AddGame $entry.Name (Join-Path $entry.FullName 'Content') 'Xbox'}
  foreach($entry in Get-ChildItem -LiteralPath (Join-Path $drive.Root 'Xbox games') -Directory -ErrorAction SilentlyContinue){AddGame $entry.Name (Join-Path $entry.FullName 'Content') 'Xbox'}
  # Bounded custom simulator roots; inspect only the root and direct children.
  # This covers layouts such as C:\MSFS\Microsoft Flight Simulator\Content.
  foreach($rootName in @('MSFS','MSFS2020','MSFS2024')){
   $custom=Join-Path $drive.Root $rootName
   if(-not(Test-Path -LiteralPath $custom -PathType Container)){continue}
   try{AssertFusionPhysicalFolder $custom}catch{continue}
   AddGame $rootName $custom ''
   foreach($entry in Get-ChildItem -LiteralPath $custom -Directory -ErrorAction SilentlyContinue|Select-Object -First 100){
    if(-not($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)){AddGame $entry.Name $entry.FullName ''}
   }
  }
 }
 # Registered Store packages may live outside the default XboxGames folders.
 # Query only the two simulator identities, never enumerate protected disk trees.
 if(Get-Command Get-AppxPackage -ErrorAction SilentlyContinue){
  foreach($identity in @('Microsoft.FlightSimulator','Microsoft.Limitless')){
   try{foreach($package in Get-AppxPackage -Name $identity -ErrorAction Stop){AddGame $package.Name $package.InstallLocation 'Xbox'}}catch{}
  }
 }
 foreach($file in Get-ChildItem (Join-Path $Store 'Games') -Filter manifest.json -Recurse -File -ErrorAction SilentlyContinue){
  try{
   $m=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8|ConvertFrom-Json
   $parent=@($games.Values|Where-Object {$m.Game.StartsWith($_.Folder+'\',[StringComparison]::OrdinalIgnoreCase)}|Sort-Object @{Expression={$_.Folder.Length};Descending=$true})|Select-Object -First 1
   if($parent){$parent.State=$m.Status;if($m.Status -eq 'Installed' -and $m.Downloads -eq 'Pending'){$parent.State='Installed - finish downloads'};$parent|Add-Member -NotePropertyName InstallFolder -NotePropertyValue $m.Game -Force}
   else{AddGame (Split-Path $m.Game -Leaf) $m.Game 'Added by you';$key=([IO.Path]::GetFullPath($m.Game).TrimEnd('\')).ToLowerInvariant();if($games.ContainsKey($key)){$games[$key].State=$m.Status;if($m.Status -eq 'Installed' -and $m.Downloads -eq 'Pending'){$games[$key].State='Installed - finish downloads'}}}
  }catch{}
 }
 $validated=@(foreach($game in $games.Values){
  try{
   $installPath=ResolveFusionInstallFolder $(if($game.InstallFolder){$game.InstallFolder}else{$game.Folder})
   $null=FindFusionExecutable $installPath $game.Launcher
   $game|Add-Member -NotePropertyName InstallFolder -NotePropertyValue $installPath -Force
   $game.State=GetFusionInstallState $Store $installPath
   $game.Label="$($game.Name) / $($game.Launcher) - OptiShade $($game.State)"
   $game
  }catch{} # A stale installation record must not hide other valid games.
 })
 @($validated|Sort-Object Name)
}
function FindFusionAntiCheat([string]$Game){
 $hits=New-Object 'System.Collections.Generic.HashSet[string]'
 # Bounded scan, avoiding linked folders. Detection is a warning, never a safety certificate.
 $pending=New-Object 'System.Collections.Generic.Queue[object]';$pending.Enqueue(@($Game,0));$visited=0
 while($pending.Count -and $visited -lt 2500){
  $item=$pending.Dequeue();$visited++
  foreach($entry in Get-ChildItem -LiteralPath $item[0] -Force -ErrorAction SilentlyContinue){
   if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
   # Match complete known folders or executable file names, never substrings in
   # game content (MSFS's rallyrace-base is not the ACE-Base anti-cheat folder).
   if($entry.PSIsContainer){
    if($entry.Name -match '^(?i:EasyAntiCheat(?:_EOS)?|easy_anti_cheat)$'){[void]$hits.Add('Easy Anti-Cheat')}
    if($entry.Name -match '^(?i:BattlEye)$'){[void]$hits.Add('BattlEye')}
    if($entry.Name -match '^(?i:EAAntiCheat)$'){[void]$hits.Add('EA AntiCheat')}
    if($entry.Name -match '^(?i:EQU8|ACE-Base|AntiCheatExpert)$'){[void]$hits.Add('Anti-cheat files')}
   }else{
    if($entry.Name -match '^(?i:EasyAntiCheat(?:[_.-][a-z0-9_.-]+)?|easy_anti_cheat)\.(exe|dll|sys)$'){[void]$hits.Add('Easy Anti-Cheat')}
    if($entry.Name -match '^(?i:BEService(?:_x64)?|BEClient(?:_x64)?|BEDaisy)\.(exe|dll|sys)$'){[void]$hits.Add('BattlEye')}
    if($entry.Name -match '^(?i:EAAntiCheat[a-z0-9_.-]*)\.(exe|dll|sys)$'){[void]$hits.Add('EA AntiCheat')}
    if($entry.Name -match '^(?i:EQU8(?:[_.-][a-z0-9_.-]+)?|AntiCheatExpert[a-z0-9_.-]*)\.(exe|dll|sys)$'){[void]$hits.Add('Anti-cheat files')}
   }
   if($entry.PSIsContainer -and $item[1] -lt 4 -and -not($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)){$pending.Enqueue(@($entry.FullName,($item[1]+1)))}
  }
 }
 @($hits)
}
function GetFusionGpu{
  $devices=@(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
 $cards=@($devices|ForEach-Object Name)
 $drivers=@(foreach($device in $devices){
  $raw=[string]$device.DriverVersion;$display=$raw
  if($device.Name -match 'NVIDIA' -and $raw -match '^\d+\.\d+\.(\d+)\.(\d{1,4})$'){$number=(([int]$Matches[1]%10)*10000)+[int]$Matches[2];$display=('{0}.{1:00}' -f [math]::Floor($number/100),($number%100))}
  [pscustomobject]@{Name=$device.Name;Version=$display;WindowsVersion=$raw}
 })
 [pscustomobject]@{Names=($cards -join ', ');Nvidia=[bool]($cards -match 'NVIDIA');Known=($cards.Count -gt 0);Drivers=$drivers}
}
function AssertFusionExecutable([string]$File){
 $stream=[IO.File]::OpenRead($File);$reader=New-Object IO.BinaryReader($stream)
 try{if($reader.ReadUInt16() -ne 0x5a4d){throw 'Choose a Windows game EXE.'};$stream.Position=0x3c;$offset=$reader.ReadInt32();$stream.Position=$offset;if($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664){throw 'This preview supports 64-bit Windows games only.'}}finally{$reader.Dispose()}
}
function FindFusionExecutable([string]$Game,[string]$Launcher=''){
 if(-not $Game -or -not(Test-Path -LiteralPath $Game -PathType Container)){return @()}
 $Game=ResolveFusionInstallFolder $Game
 AssertFusionPhysicalFolder $Game
 $xp=Join-Path $Game 'X-Plane.exe';if(Test-Path -LiteralPath $xp -PathType Leaf){throw 'X-Plane support is removed from this stable build. Existing files can be restored using Troubleshooting.'}
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
 throw 'No supported simulator executable was found. Select the folder containing FlightSimulator.exe (2020), FlightSimulator2024.exe (2024), only. For Xbox installs select the real Content folder; OptiShade selects gamelaunchhelper.exe automatically when required.'
}
function GetFusionGameArtwork($Games){
 Add-Type -AssemblyName System.Drawing
 foreach($game in $Games){
  $art=''
  try{
   $exe=@(FindFusionExecutable $game.Folder $game.Launcher)|Select-Object -First 1
   if($exe){$icon=[Drawing.Icon]::ExtractAssociatedIcon($exe.Path);if($icon){$bitmap=$icon.ToBitmap();$memory=New-Object IO.MemoryStream;try{$bitmap.Save($memory,[Drawing.Imaging.ImageFormat]::Png);$art=[Convert]::ToBase64String($memory.ToArray())}finally{$memory.Dispose();$bitmap.Dispose();$icon.Dispose()}}}
  }catch{}
  $game|Add-Member -NotePropertyName Artwork -NotePropertyValue $art -Force
 }
 $Games
}

function AssertMsfsNvidiaTarget([string]$Exe,$Gpu){
 if(-not $Gpu.Known -or (-not $Gpu.Nvidia -and $Gpu.Names -notmatch '(?i)AMD|Radeon')){throw 'This patch supports detected NVIDIA or AMD graphics cards. Restore and uninstall remain available.'}
 if(-not $Exe -or (Split-Path $Exe -Leaf) -notin @('FlightSimulator2024.exe','FlightSimulator.exe','gamelaunchhelper.exe','X-Plane.exe')){throw 'This edition supports MSFS 2024, MSFS 2020 and experimental X-Plane 12.'}
 if(-not (GetMsfsTitle (Split-Path $Exe))){throw 'Choose the simulator executable folder containing FlightSimulator2024.exe or FlightSimulator.exe.'}
}
