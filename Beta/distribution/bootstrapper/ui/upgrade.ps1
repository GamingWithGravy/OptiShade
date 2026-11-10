param(
 [Parameter(Mandatory=$true)][ValidateSet('Detect','Close','Cleanup')][string]$Mode,
 [Parameter(Mandatory=$true)][string]$Out,
 [string]$App='',
 # Copies found by Detect (separated by |): a copy that was running then has closed since.
 [string]$Known=''
)
# Finds an OptiShade launcher from an earlier private test build, closes it, and
# after the new launcher is installed and verified, moves the user's shortcuts and
# Start with Windows entry to it and removes the old launcher copies and their
# temporary folders. Never touched: game folders (including their ini files),
# OptiShade-SnapShot and snapshot settings, presets, settings, consents, game
# records, diagnostics, pending reports and the component download cache.
$ErrorActionPreference='Stop'
$local=[IO.Path]::GetFullPath($env:LOCALAPPDATA)
$store=Join-Path $local 'OptiShade'
$programs=Join-Path $local 'Programs\OptiShade'
$desktop=if($env:OPTISHADE_UPGRADE_DESKTOP){$env:OPTISHADE_UPGRADE_DESKTOP}else{[Environment]::GetFolderPath('Desktop')}
$startMenu=if($env:OPTISHADE_UPGRADE_STARTMENU){$env:OPTISHADE_UPGRADE_STARTMENU}else{Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'}
$runKey=if($env:OPTISHADE_UPGRADE_RUNKEY){$env:OPTISHADE_UPGRADE_RUNKEY}else{'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'}
# Tests only: limit the running-process scan to one folder so a test never sees
# (or closes) the OptiShade the person running the test is using.
$processRoot=$env:OPTISHADE_UPGRADE_PROCESS_ROOT
function Processes{@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object {$_.ExecutablePath -and (-not $processRoot -or (Inside $_.ExecutablePath $processRoot))})}

function Full([string]$Path){try{return [IO.Path]::GetFullPath($Path)}catch{return ''}}
function Inside([string]$Path,[string]$Root){$p=Full $Path;$r=(Full $Root).TrimEnd('\')+'\';return $p -and $p.StartsWith($r,[StringComparison]::OrdinalIgnoreCase)}
function IsOptiShadeLauncher([string]$Path,[switch]$AnyName){
 if(-not $Path -or (-not $AnyName -and -not $Path.EndsWith('.exe',[StringComparison]::OrdinalIgnoreCase))){return $false}
 $item=Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
 if(-not $item -or $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){return $false}
 return [Diagnostics.FileVersionInfo]::GetVersionInfo($item.FullName).ProductName -eq 'OptiShade Manager'
}
function ExeFromCommand([string]$Command){
 if($Command -match '^\s*"([^"]+)"'){return $Matches[1]}
 if($Command -match '^\s*(\S+\.exe)'){return $Matches[1]}
 return ''
}
function Shortcuts{
 $shell=New-Object -ComObject WScript.Shell
 foreach($root in @($desktop,$startMenu)){
  if(-not $root -or -not (Test-Path -LiteralPath $root)){continue}
  foreach($link in Get-ChildItem -LiteralPath $root -Filter '*OptiShade*.lnk' -Recurse -Force -ErrorAction SilentlyContinue){
   try{[pscustomobject]@{Link=$link.FullName;Target=$shell.CreateShortcut($link.FullName).TargetPath}}catch{}
  }
 }
}
function OldCopies{
 $seen=@{};$copies=@()
 $recorded=$null
 $receipt=Join-Path $store 'manager-installed.json'
 if(Test-Path -LiteralPath $receipt -PathType Leaf){try{$recorded=Get-Content -LiteralPath $receipt -Raw -Encoding UTF8|ConvertFrom-Json}catch{}}
 $candidates=@()
 if($recorded -and $recorded.Installer){$candidates+=[string]$recorded.Installer}
 $startup=(Get-ItemProperty -LiteralPath $runKey -Name OptiShadeManager -ErrorAction SilentlyContinue).OptiShadeManager
 if($startup){$candidates+=(ExeFromCommand ([string]$startup))}
 foreach($s in @(Shortcuts)){$candidates+=[string]$s.Target}
 foreach($k in @($Known -split '\|')){if($k){$candidates+=$k}}
 # An old private build is often run straight from a download or build folder.
 foreach($p in Processes){$candidates+=[string]$p.ExecutablePath}
 foreach($c in $candidates){
  $p=Full $c
  if(-not $p -or $seen.ContainsKey($p.ToLowerInvariant()) -or (Inside $p $programs)){continue}
  $seen[$p.ToLowerInvariant()]=$true
  if(-not (IsOptiShadeLauncher $p)){continue}
  $info=[Diagnostics.FileVersionInfo]::GetVersionInfo($p)
  $copies+=[pscustomobject]@{Path=$p;Version=[string]$info.ProductVersion}
 }
 return ,$copies
}
function RunningOptiShade([object[]]$Copies){
 $paths=@($Copies|ForEach-Object {$_.Path.ToLowerInvariant()})
 $paths+=(Join-Path $programs 'OptiShade.exe').ToLowerInvariant()
 $sessions=Join-Path $store 'Sessions'
 @(Processes|Where-Object {
  $exe=[string]$_.ExecutablePath
  $exe -and $_.ProcessId -ne $PID -and (($paths -contains $exe.ToLowerInvariant()) -or ((Split-Path $exe -Leaf) -ieq 'FusionSetup.exe' -and ((Inside $exe $sessions) -or $exe -match '(?i)\\OptiShadeTemp\\')))
 }|ForEach-Object {[pscustomobject]@{Pid=[int]$_.ProcessId;Path=[string]$_.ExecutablePath}})
}
function Save($Value){[IO.File]::WriteAllText($Out,($Value|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}

$copies=OldCopies
switch($Mode){
 'Detect'{
  $games=0;if(Test-Path -LiteralPath (Join-Path $store 'Games')){$games=@(Get-ChildItem -LiteralPath (Join-Path $store 'Games') -Force -ErrorAction SilentlyContinue).Count}
  $data=(Test-Path -LiteralPath $store -PathType Container) -and -not (Test-Path -LiteralPath (Join-Path $store 'install-setup.json'))
  $versions=@($copies|ForEach-Object Version|Where-Object {$_}|Sort-Object -Unique)
  Save ([ordered]@{Found=[bool]($data -or $copies.Count);Versions=$versions;Copies=@($copies|ForEach-Object Path);Games=$games;Running=@(RunningOptiShade $copies).Count})
 }
 'Close'{
  foreach($p in @(RunningOptiShade $copies)){try{[void](Get-Process -Id $p.Pid -ErrorAction Stop).CloseMainWindow()}catch{}}
  $deadline=(Get-Date).AddSeconds(15)
  do{$left=@(RunningOptiShade $copies);if(-not $left.Count){break};Start-Sleep -Milliseconds 500}while((Get-Date) -lt $deadline)
  Save ([ordered]@{Running=@($left|ForEach-Object Path)})
 }
 'Cleanup'{
  if(-not (IsOptiShadeLauncher $App) -or -not (Inside $App $programs)){throw 'The new launcher could not be confirmed.'}
  $done=@();$kept=@()
  $oldPaths=@($copies|ForEach-Object {$_.Path.ToLowerInvariant()})
  $shell=New-Object -ComObject WScript.Shell
  foreach($s in @(Shortcuts)){
   if($oldPaths -notcontains (Full $s.Target).ToLowerInvariant()){continue}
   try{$l=$shell.CreateShortcut($s.Link);$l.TargetPath=$App;$l.WorkingDirectory=(Split-Path $App);$l.IconLocation=$App+',0';$l.Arguments='';$l.Save();$done+='Shortcut now opens the new launcher: '+(Split-Path $s.Link -Leaf)}catch{$kept+='Could not update shortcut '+$s.Link}
  }
  $startup=(Get-ItemProperty -LiteralPath $runKey -Name OptiShadeManager -ErrorAction SilentlyContinue).OptiShadeManager
  if($startup -and $oldPaths -contains (Full (ExeFromCommand ([string]$startup))).ToLowerInvariant()){
   try{Set-ItemProperty -LiteralPath $runKey -Name OptiShadeManager -Value ('"'+$App+'" --tray');$done+='Start with Windows now starts the new launcher'}catch{$kept+='Could not update Start with Windows'}
  }
  $running=@(RunningOptiShade $copies|ForEach-Object {$_.Path.ToLowerInvariant()})
  foreach($c in $copies){
   if($running -contains $c.Path.ToLowerInvariant()){$kept+='Still running, kept: '+$c.Path;continue}
   try{
    # A launcher that has just closed can hold its EXE for a few seconds.
    for($try=0;$try -lt 20;$try++){try{Remove-Item -LiteralPath $c.Path -Force -ErrorAction Stop;break}catch{if($try -eq 19){throw};Start-Sleep -Milliseconds 500}}
    foreach($side in @($c.Path+'.previous')){if(IsOptiShadeLauncher $side -AnyName){Remove-Item -LiteralPath $side -Force}}
    $temp=Join-Path (Split-Path $c.Path) 'OptiShadeTemp'
    if(Test-Path -LiteralPath $temp -PathType Container){
     Get-ChildItem -LiteralPath $temp -Directory -Filter 'setup-*' -Force|Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
     if(-not @(Get-ChildItem -LiteralPath $temp -Force).Count){Remove-Item -LiteralPath $temp -Force}
    }
    $done+='Removed old launcher '+$c.Version+': '+$c.Path
   }catch{$kept+='Could not remove '+$c.Path+' ('+$_.Exception.Message+')'}
  }
  # Temporary working folders inside OptiShade's data folder only.
  foreach($folder in @(Join-Path $store 'Sessions')){
   if(Test-Path -LiteralPath $folder){Get-ChildItem -LiteralPath $folder -Directory -Filter 'setup-*' -Force|ForEach-Object {try{Remove-Item -LiteralPath $_.FullName -Recurse -Force}catch{}}}
  }
  $updates=Join-Path $store 'Updates'
  if(Test-Path -LiteralPath $updates){Get-ChildItem -LiteralPath $updates -Force|ForEach-Object {try{Remove-Item -LiteralPath $_.FullName -Recurse -Force}catch{}}}
  foreach($name in @('Update-error.txt','Launcher-update-error.txt','Launcher-update-error.shown.txt')){Remove-Item -LiteralPath (Join-Path $store $name) -Force -ErrorAction SilentlyContinue}
  Save ([ordered]@{Done=$done;Kept=$kept})
 }
}
