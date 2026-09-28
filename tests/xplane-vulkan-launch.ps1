$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/ownership.ps1"
. "$PSScriptRoot/../installer/library.ps1"
function AssertClosed($Game){}
function TestOptiShadeElevated { $script:elevated }
function Check($ok,$why){if(-not $ok){throw $why}}
$root=Join-Path $env:TEMP ('OptiShade-XP12-launch-'+[guid]::NewGuid().ToString('N'))
$game=Join-Path $root 'Game';$payload=Join-Path $root 'Payload';$store=Join-Path $root 'Store'
New-Item -ItemType Directory -Path $game,"$payload/OptiShadeData/Vulkan" -Force|Out-Null
# A minimal PE header is sufficient for configuration tests. Never execute this fixture.
$exe=Join-Path $game 'X-Plane.exe';$bytes=New-Object byte[] 128
$bytes[0]=0x4d;$bytes[1]=0x5a;$bytes[60]=64;$bytes[64]=0x50;$bytes[65]=0x45;$bytes[68]=0x64;$bytes[69]=0x86
[IO.File]::WriteAllBytes($exe,$bytes)
Set-Content "$payload/winmm.dll" 'owned NR bridge';Set-Content "$payload/ReShade64.dll" 'owned Vulkan layer'
Set-Content "$payload/ReShade.ini" '[GENERAL]'
$json='{"file_format_version":"1.2.0","layer":{"name":"VK_LAYER_reshade","type":"GLOBAL","library_path":"..\\..\\ReShade64.dll"}}'
Set-Content "$payload/OptiShadeData/Vulkan/OptiShade.json" $json
@(Get-ChildItem $payload -Recurse -File|ForEach-Object {@{Path=$_.FullName.Substring($payload.Length+1);Hash=(HashFile $_.FullName)}})|ConvertTo-Json|Set-Content "$payload/files.json"
Set-Content "$game/dxgi.dll" 'pre-existing proxy';$original=HashFile "$game/dxgi.dll"
$mp=InstallFusion $game $payload $store "$root/manager.exe" 'dxgi.dll' @(FindFusionConflicts $game)
$keys=@('VK_LAYER_PATH','VK_ADD_LAYER_PATH','VK_INSTANCE_LAYERS','RESHADE_DISABLE_GRAPHICS_HOOK');$saved=@{}
foreach($k in $keys){$saved[$k]=[Environment]::GetEnvironmentVariable($k,'Process');[Environment]::SetEnvironmentVariable($k,$null,'Process')}
try{
 $start=NewOptiShadeXPlaneStartInfo $exe $store
 Check ($start.EnvironmentVariables['VK_ADD_LAYER_PATH'] -eq (Join-Path $game 'OptiShadeData/Vulkan')) 'Clean path missing'
 Check (-not $start.EnvironmentVariables['VK_LAYER_PATH']) 'Clean launch must preserve default discovery'
 Check ($start.Arguments -eq '--allow_reshade') 'Compatibility argument missing'
 $env:VK_LAYER_PATH='C:\VulkanTools;C:\VulkanTools\';$env:VK_ADD_LAYER_PATH='C:\OtherLayers;C:\VulkanTools'
 $env:VK_INSTANCE_LAYERS='VK_LAYER_OTHER_tool;VK_LAYER_reshade;VK_LAYER_reshade'
 $start=NewOptiShadeXPlaneStartInfo $exe $store
 Check ($start.EnvironmentVariables['VK_LAYER_PATH'] -eq ((Join-Path $game 'OptiShadeData/Vulkan')+';C:\VulkanTools;C:\OtherLayers')) 'Override path merge or dedup failed'
 Check (-not $start.EnvironmentVariables['VK_ADD_LAYER_PATH']) 'Ignored ADD path retained'
 Check ($start.EnvironmentVariables['VK_INSTANCE_LAYERS'] -ceq 'VK_LAYER_reshade;VK_LAYER_OTHER_tool') 'Layer preservation/dedup failed'
 Check ($env:VK_LAYER_PATH -eq 'C:\VulkanTools;C:\VulkanTools\') 'Parent environment changed'
 [Environment]::SetEnvironmentVariable('VK_LAYER_PATH',$null,'Process')
 $start=NewOptiShadeXPlaneStartInfo $exe $store
 Check ($start.EnvironmentVariables['VK_ADD_LAYER_PATH'] -like '*;C:\OtherLayers;C:\VulkanTools') 'Existing ADD path lost'
 'PASS: clean, inherited override/add paths, deduplication, existing layers and unchanged parent environment'
 $jp=Join-Path $game 'OptiShadeData/Vulkan/OptiShade.json'
 foreach($case in @('MissingJson','MissingDll','InvalidJson','WrongLibrary','LegacySlashes','ChangedProxy','Elevated')){
  switch($case){
   MissingJson {Move-Item $jp "$jp.saved"}
   MissingDll {Move-Item "$game/ReShade64.dll" "$game/ReShade64.saved"}
   InvalidJson {Set-Content $jp '{'}
   WrongLibrary {Set-Content $jp ($json.Replace('ReShade64.dll','Other.dll'))}
   LegacySlashes {Set-Content $jp ($json.Replace('..\\..\\','../../'))}
   ChangedProxy {Set-Content "$game/dxgi.dll" 'foreign loader'}
   Elevated {$script:elevated=$true}
  }
  $failed=$false;try{$null=NewOptiShadeXPlaneStartInfo $exe $store}catch{$failed=$true}
  Check $failed "Launch accepted invalid state: $case"
  if($case -eq 'MissingJson'){Move-Item "$jp.saved" $jp}
  if($case -eq 'MissingDll'){Move-Item "$game/ReShade64.saved" "$game/ReShade64.dll"}
  Copy-Item "$payload/OptiShadeData/Vulkan/OptiShade.json" $jp -Force
  Copy-Item "$payload/winmm.dll" "$game/dxgi.dll" -Force
  $script:elevated=$false
 }
 'PASS: missing, malformed, wrong-path, legacy-path, changed loader and elevated launch are blocked'
 Set-Content $jp 'broken'
 AssertRepairVersion (Get-Content $mp -Raw|ConvertFrom-Json)
 $mp=InstallFusion $game $payload $store "$root/manager.exe" 'dxgi.dll' @(FindFusionConflicts $game) -ReplaceExisting $true -PreserveConfiguration $true
 $null=NewOptiShadeXPlaneStartInfo $exe $store
 'PASS: same-version repair restores valid layer JSON and verified components'
 RestoreFusion $mp
 Check (-not(Test-Path $jp) -and -not(Test-Path "$game/ReShade64.dll") -and (HashFile "$game/dxgi.dll") -eq $original -and (Test-Path $exe)) 'Restore failed to preserve original simulator/proxy'
 'PASS: restore removes owned layer and restores original proxy without changing game EXE'
}finally{foreach($k in $keys){[Environment]::SetEnvironmentVariable($k,$saved[$k],'Process')}}
