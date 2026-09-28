param([Parameter(Mandatory=$true)][string]$Probe)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/ownership.ps1"
. "$PSScriptRoot/../installer/library.ps1"
$root=Join-Path $env:TEMP ('OptiShade-XP12-payload-'+[guid]::NewGuid().ToString('N'))
$game=Join-Path $root 'Game';$store=Join-Path $root 'Store';$payload=Join-Path $PSScriptRoot '../installer/PayloadFusion'
[void][IO.Directory]::CreateDirectory($game)
Copy-Item -LiteralPath $Probe -Destination "$game/X-Plane.exe"
$mp=InstallFusion $game $payload $store "$root/manager.exe" 'dxgi.dll'
function RunProbe($info){
 $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.CreateNoWindow=$true
 $p=[Diagnostics.Process]::Start($info);$output=$p.StandardOutput.ReadToEndAsync();$errors=$p.StandardError.ReadToEndAsync()
 try{if(-not $p.WaitForExit(30000)){$p.Kill();throw 'Isolated Vulkan probe timed out'};$text=$output.Result;[IO.File]::WriteAllText((Join-Path $root 'last-probe.txt'),$text+"`n"+$errors.Result);if($p.ExitCode -ne 0 -or $text -notmatch 'vkCreateInstance=0'){throw "Vulkan probe failed. Evidence: $root"}}finally{$p.Dispose()}
}
$keys=@('VK_LAYER_PATH','VK_ADD_LAYER_PATH','VK_INSTANCE_LAYERS');$saved=@{}
foreach($key in $keys){$saved[$key]=[Environment]::GetEnvironmentVariable($key,'Process');[Environment]::SetEnvironmentVariable($key,$null,'Process')}
try{
 $start=NewOptiShadeXPlaneStartInfo "$game/X-Plane.exe" $store
 RunProbe $start
 'PASS: generated payload installed as XP12; recorded JSON resolves and Vulkan instance initializes with NR proxy and effects layer'
 $env:VK_LAYER_PATH=Join-Path $root 'ExistingLayers';[void][IO.Directory]::CreateDirectory($env:VK_LAYER_PATH)
 RunProbe (NewOptiShadeXPlaneStartInfo "$game/X-Plane.exe" $store)
 'PASS: native Vulkan initialization also succeeds with an inherited explicit layer path'
 RestoreFusion $mp
 if(Test-Path "$game/dxgi.dll"){throw 'Owned proxy survived restore'}
 $plain=[Diagnostics.ProcessStartInfo]::new();$plain.FileName="$game/X-Plane.exe";$plain.WorkingDirectory=$game;$plain.Arguments='vanilla';$plain.UseShellExecute=$false
 foreach($key in $keys){$plain.EnvironmentVariables.Remove($key)}
 RunProbe $plain
 'PASS: restore removes owned proxy/layer and vanilla Vulkan instance initializes'
 "Private fixture: $root"
}finally{foreach($key in $keys){[Environment]::SetEnvironmentVariable($key,$saved[$key],'Process')}}
