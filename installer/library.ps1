# Read launcher catalogues; never crawl entire disks or start games during discovery.
function ResolveFusionInstallFolder([string]$Game){
 if(-not $Game){return $Game}
 $folder=[IO.Path]::GetFullPath($Game).TrimEnd('\','/')
 if(Test-Path -LiteralPath (Join-Path $folder 'FlightSimulator2024.exe') -PathType Leaf){return $folder}
 $content=Join-Path $folder 'Content'
 if(Test-Path -LiteralPath (Join-Path $content 'FlightSimulator2024.exe') -PathType Leaf){return $content}
 return $folder
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
  if(-not (Test-Path -LiteralPath (Join-Path $folder 'FlightSimulator2024.exe') -PathType Leaf) -and -not (Test-Path -LiteralPath (Join-Path $folder 'Content/FlightSimulator2024.exe') -PathType Leaf)){return}
  $name='Microsoft Flight Simulator 2024'
  if($name -match 'Steamworks Common|SteamVR|Oasis Driver|Unreal Engine|Fab UE Plugin|Quixel Bridge|Minecraft Launcher'){return}
  if(-not $folder -or -not(Test-Path -LiteralPath $folder -PathType Container)){return}
  $folder=[IO.Path]::GetFullPath($folder).TrimEnd('\');$key=$folder.ToLowerInvariant()
  if(-not $games.ContainsKey($key)){$games[$key]=[pscustomobject]@{Name=$name;Folder=$folder;Launcher=$launcher;State='Not installed';Label=''}}
 }
 $steam=@("${env:ProgramFiles(x86)}\Steam")
 $registered=(Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
 if($registered){$steam+= $registered}
 foreach($base in @($steam)){
  $vdf=Join-Path $base 'steamapps/libraryfolders.vdf'
  if(Test-Path -LiteralPath $vdf){foreach($match in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw -Encoding UTF8),'"path"\s+"([^"]+)"')){$steam+=$match.Groups[1].Value.Replace('\\','\')}}
 }
 foreach($base in ($steam|Select-Object -Unique)){
  foreach($file in Get-ChildItem -LiteralPath (Join-Path $base 'steamapps') -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue){
   $data=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
   $name=[regex]::Match($data,'"name"\s+"([^"]+)"').Groups[1].Value
   $dir=[regex]::Match($data,'"installdir"\s+"([^"]+)"').Groups[1].Value
   if($dir){AddGame $name (Join-Path $base "steamapps/common/$dir") 'Steam'}
  }
 }
 foreach($file in Get-ChildItem "$env:ProgramData/Epic/EpicGamesLauncher/Data/Manifests" -Filter '*.item' -File -ErrorAction SilentlyContinue){
  try{$item=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8|ConvertFrom-Json;AddGame $item.DisplayName $item.InstallLocation 'Epic'}catch{}
 }
 foreach($drive in Get-PSDrive -PSProvider FileSystem){
  foreach($entry in Get-ChildItem -LiteralPath (Join-Path $drive.Root 'XboxGames') -Directory -ErrorAction SilentlyContinue){AddGame $entry.Name (Join-Path $entry.FullName 'Content') 'Xbox'}
  foreach($entry in Get-ChildItem -LiteralPath (Join-Path $drive.Root 'Xbox games') -Directory -ErrorAction SilentlyContinue){AddGame $entry.Name (Join-Path $entry.FullName 'Content') 'Xbox'}
 }
 foreach($file in Get-ChildItem (Join-Path $Store 'Games') -Filter manifest.json -Recurse -File -ErrorAction SilentlyContinue){
  try{
   $m=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8|ConvertFrom-Json
   $parent=@($games.Values|Where-Object {$m.Game.StartsWith($_.Folder+'\',[StringComparison]::OrdinalIgnoreCase)}|Sort-Object @{Expression={$_.Folder.Length};Descending=$true})|Select-Object -First 1
   if($parent){$parent.State=$m.Status;if($m.Status -eq 'Installed' -and $m.Downloads -eq 'Pending'){$parent.State='Installed - finish downloads'};$parent|Add-Member -NotePropertyName InstallFolder -NotePropertyValue $m.Game -Force}
   else{AddGame (Split-Path $m.Game -Leaf) $m.Game 'Added by you';$key=([IO.Path]::GetFullPath($m.Game).TrimEnd('\')).ToLowerInvariant();if($games.ContainsKey($key)){$games[$key].State=$m.Status;if($m.Status -eq 'Installed' -and $m.Downloads -eq 'Pending'){$games[$key].State='Installed - finish downloads'}}}
  }catch{}
 }
 foreach($game in $games.Values){$installPath=ResolveFusionInstallFolder $(if($game.InstallFolder){$game.InstallFolder}else{$game.Folder});$game|Add-Member -NotePropertyName InstallFolder -NotePropertyValue $installPath -Force;$game.State=GetFusionInstallState $Store $installPath;$game.Label="$($game.Launcher) - OptiShade $($game.State)"}
 @($games.Values|Sort-Object Name)
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
 $drivers=@(foreach($device in $devices|Where-Object Name -match 'NVIDIA'){
  $raw=[string]$device.DriverVersion;$display=$raw
  if($raw -match '^\d+\.\d+\.(\d+)\.(\d{1,4})$'){$number=(([int]$Matches[1]%10)*10000)+[int]$Matches[2];$display=('{0}.{1:00}' -f [math]::Floor($number/100),($number%100))}
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
 # MSFS Xbox uses the accessible launch helper beside the protected game EXE.
 # Steam uses the game EXE directly. Both install beside the selected executable.
 foreach($folder in @($Game,(Join-Path $Game 'Content'))){
  $main=Join-Path $folder 'FlightSimulator2024.exe';$helper=Join-Path $folder 'gamelaunchhelper.exe'
  if(Test-Path -LiteralPath $main -PathType Leaf){
   $xbox=$Launcher -eq 'Xbox' -or ($Launcher -ne 'Steam' -and (Test-Path -LiteralPath (Join-Path $folder 'MicrosoftGame.Config')))
   $target=if($xbox){$helper}else{$main}
   if(-not(Test-Path -LiteralPath $target -PathType Leaf)){throw "Microsoft Flight Simulator 2024 launcher is missing: $target. Repair the game through its launcher first."}
   AssertFusionExecutable $target
   return @([pscustomobject]@{Path=$target;Score=1000})
  }
 }
 throw 'Microsoft Flight Simulator 2024 was not found in this folder. Choose its installation folder or Content folder.'
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
 if(-not $Gpu.Known -or -not $Gpu.Nvidia){throw 'Optishade requires an NVIDIA graphics card. Restore and uninstall remain available.'}
 if(-not $Exe -or (Split-Path $Exe -Leaf) -notin @('FlightSimulator2024.exe','gamelaunchhelper.exe')){throw 'This edition supports Microsoft Flight Simulator 2024 only.'}
 if(-not (Test-Path -LiteralPath (Join-Path (Split-Path $Exe) 'FlightSimulator2024.exe') -PathType Leaf)){throw 'Choose the Microsoft Flight Simulator 2024 installation folder containing FlightSimulator2024.exe.'}
}


