$ErrorActionPreference='Stop'
$root=Resolve-Path (Join-Path $PSScriptRoot '..\..')
$installer=Join-Path $root 'Beta/installer'
. (Join-Path $installer 'json-state.ps1')
. (Join-Path $installer 'ownership.ps1')
function Assert($condition,$message){if(-not $condition){throw $message}}

# The names OptiShade ships under, and nothing else.
foreach($name in 'OptiShade_Version_1.0.77_R350.exe','OptiShade_Version_1.0.77.exe','OptiShade Version 1.0.77.exe','OptiShade.Version.1.0.77_R351.exe'){
 Assert (TestOptiShadeLauncherImageName $name) ('Not recognised as the launcher: '+$name)
}
foreach($name in 'FlightSimulator2024.exe','OptiShade-Troubleshooter.exe','OptiShadeSensors.exe','OptiMFG_Live.exe','dlss5-feed-host64.exe','OptiShade_Version_evil.exe','OptiShade_Version_1.0.77_R350.exe.bak'){
 Assert (-not (TestOptiShadeLauncherImageName $name)) ('Wrongly treated as the launcher: '+$name)
}
# A renamed EXE is found through this process's parent chain.
$ids=@(GetOptiShadeLauncherProcessIds)
$parent=(Get-CimInstance Win32_Process -Filter ("ProcessId="+$PID)).ParentProcessId
Assert ($PID -in $ids -and $parent -in $ids) 'The parent chain does not include this process and its parent'

# Real processes run from a fixture game folder.
$game=Join-Path ([IO.Path]::GetTempPath()) ('osclosed-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $game|Out-Null
$running=@()
function StartFrom([string]$Name){
 $copy=Join-Path $game $Name;Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\PING.EXE') -Destination $copy
 $p=Start-Process -FilePath $copy -ArgumentList '-n','60','127.0.0.1' -WindowStyle Hidden -PassThru;$script:running+=$p
 Start-Sleep -Milliseconds 400;Assert (-not $p.HasExited) ('The test process did not stay running: '+$Name);return $p
}
try{
 AssertClosed $game
 # What the tester hit: the launcher in the game folder, no window, must not block.
 $launcher=StartFrom 'OptiShade_Version_1.0.77_R350.exe'
 AssertClosed $game
 # Anything else still blocks, with or without the launcher beside it.
 $other=StartFrom 'SomeOtherTool.exe'
 $blocked='';try{AssertClosed $game}catch{$blocked=$_.Exception.Message}
 Assert ($blocked -match 'SomeOtherTool') ('Another program in the game folder did not block: "'+$blocked+'"')
 Stop-Process -Id $other.Id -Force;$other.WaitForExit();
 $tool=StartFrom 'OptiShade-Troubleshooter.exe'
 $blocked='';try{AssertClosed $game}catch{$blocked=$_.Exception.Message}
 Assert ($blocked -match 'OptiShade-Troubleshooter') 'A running Troubleshooter must still block: it holds files that get replaced'
}finally{
 foreach($p in $running){try{if(-not $p.HasExited){Stop-Process -Id $p.Id -Force;$p.WaitForExit()}}catch{}}
 Remove-Item -LiteralPath $game -Recurse -Force -ErrorAction SilentlyContinue
}
'PASS: the launcher EXE in the game folder does not block itself; the game and other programs still do.'
