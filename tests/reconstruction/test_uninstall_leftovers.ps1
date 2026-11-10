$ErrorActionPreference='Stop'
$root=Resolve-Path (Join-Path $PSScriptRoot '..\..')
$installer=Join-Path $root 'Beta/installer'
. (Join-Path $installer 'json-state.ps1')
. (Join-Path $installer 'ownership.ps1')
function Assert($condition,$message){if(-not $condition){throw $message}}
function Touch($folder,$name,$text='x'){$path=Join-Path $folder $name;New-Item -ItemType Directory -Path (Split-Path $path) -Force|Out-Null;[IO.File]::WriteAllText($path,$text)}

$work=Join-Path ([IO.Path]::GetTempPath()) ('osleft-'+[guid]::NewGuid().ToString('N'));$savedLocal=$env:LOCALAPPDATA;$savedRoaming=$env:APPDATA
try{
 # Never the PC's own AtmosphereMod record or sim settings.
 $env:LOCALAPPDATA=Join-Path $work 'local';$env:APPDATA=Join-Path $work 'roaming'
 New-Item -ItemType Directory -Path $env:LOCALAPPDATA,$env:APPDATA -Force|Out-Null

 # Every leftover seen in a real game folder goes; stock game files and anything
 # the player owns stay.
 $game=Join-Path $work 'Content';New-Item -ItemType Directory -Path $game|Out-Null
 $ours='glass-cockpit-dlss-fix.log','glass-cockpit-dlss-fix.old.log','OptiScaler.ini.save-6040-1.tmp.pre-source-policy-v1.bak','ReShade.ini.atmospheremod.bak','RTX40MFG-UI-layout.ini','RTX40MFG-UI.ini','RTX40MFG-Universal.json.removed-41c7.bak','RTX40MFG-Universal.status.json','RTXMFG-flightsimulator2024-9074-intervals.csv','RTXMFG-flightsimulator2024-9074.log','RTXMFG-Universal.json.removed-f8d9.bak','RTXMFG-Universal.status.json','winmm.dll.optimfg-baseline-disabled'
 $stock='FlightSimulator2024.exe','gamelaunchhelper.exe','nvngx_dlss.dll','nvngx_dlssg.dll','sl.common.dll','sl.dlss.dll','sl.dlss_g.dll','sl.interposer.dll','sl.pcl.dll','sl.reflex.dll','amd_ags_x64.dll','openxr_loader.dll','SimConnect_internal.dll','dummy.ini','crashrpt_lang.ini','RoflybyV3.ini','mimalloc.dll'
 foreach($name in $ours+$stock){Touch $game $name}
 Touch $game 'glass-cockpit-dlss-fix.ini' '[overlay]'
 Touch $game 'ReShade2.ini' "[GENERAL]`nEffectSearchPaths=.\OptiShadeData\Shaders\**`n"
 Touch $game 'ReShade3.ini' "[GENERAL]`nEffectSearchPaths=.\my-own-reshade\Shaders\**`n"
 foreach($empty in 'host64','OptiScaler\nvfp4\hybrid\contract','OptiScaler\dlssnr\design'){New-Item -ItemType Directory -Path (Join-Path $game $empty) -Force|Out-Null}
 foreach($stockFolder in 'D3D12','Licenses','Shaders','Optishade Snapshots'){Touch (Join-Path $game $stockFolder) 'keep.txt'}

 $removed=@(RemoveOptiShadeRuntimeLeftovers $game $true)
 foreach($name in $ours+'ReShade2.ini'){Assert (-not(Test-Path -LiteralPath (Join-Path $game $name))) ('Leftover not removed: '+$name)}
 foreach($name in $stock+'ReShade3.ini'){Assert (Test-Path -LiteralPath (Join-Path $game $name)) ('A file that is not ours was removed: '+$name)}
 foreach($folder in 'host64','OptiScaler'){Assert (-not(Test-Path -LiteralPath (Join-Path $game $folder))) ('Empty folder not removed: '+$folder);Assert ($removed -contains ($folder+'\')) ('Not reported: '+$folder)}
 foreach($stockFolder in 'D3D12','Licenses','Shaders','Optishade Snapshots'){Assert (Test-Path -LiteralPath (Join-Path $game ($stockFolder+'\keep.txt'))) ('A folder that is not ours was touched: '+$stockFolder)}
 Assert (Test-Path -LiteralPath (Join-Path $game 'glass-cockpit-dlss-fix.ini')) 'Add-on settings were removed although the player chose to keep settings'
 $null=RemoveOptiShadeRuntimeLeftovers $game $false
 Assert (-not(Test-Path -LiteralPath (Join-Path $game 'glass-cockpit-dlss-fix.ini'))) 'Add-on settings stayed although the player chose to remove them'

 # Add-ons the player still has keep their logs and settings; a folder with
 # anything in it is never removed.
 $own=Join-Path $work 'OwnAddons';New-Item -ItemType Directory -Path $own|Out-Null
 foreach($name in 'glass-cockpit-dlss-fix.addon64','glass-cockpit-dlss-fix.log','glass-cockpit-dlss-fix.ini','RTX40MFG.asi','RTX40MFG-UI.ini','RTX40MFG-Universal.status.json','AtmosphereMod.addon64','ReShade.ini.atmospheremod.bak'){Touch $own $name}
 Touch (Join-Path $own 'host64') 'someone-elses.dll'
 $null=RemoveOptiShadeRuntimeLeftovers $own $false
 foreach($name in 'glass-cockpit-dlss-fix.log','glass-cockpit-dlss-fix.ini','RTX40MFG-UI.ini','RTX40MFG-Universal.status.json','ReShade.ini.atmospheremod.bak','AtmosphereMod.addon64'){Assert (Test-Path -LiteralPath (Join-Path $own $name)) ('Removed a file of an add-on still present: '+$name)}
 Assert (Test-Path -LiteralPath (Join-Path $own 'host64\someone-elses.dll')) 'A folder with files in it was removed'

 # AtmosphereMod: OptiShade's own copy goes, including the EFB app and data folder,
 # and the tunables are kept. The mod's own installer's copy stays.
 . (Join-Path $installer 'atmosphere-mod.ps1')
 $data=GetAtmosphereModDataFolder;$community=Join-Path $work 'Packages\Community'
 $sim=Join-Path $work 'Sim';Touch $sim 'FlightSimulator2024.exe';Touch $sim 'AtmosphereMod.addon64';Touch $sim 'ReShade.ini.atmospheremod.bak'
 [IO.File]::WriteAllText((Join-Path $sim 'ReShade.ini'),"[GENERAL]`nPresetPath=x.ini`n`n[ATMOSPHEREMOD]`nDataPath=$data`n")
 Touch (Join-Path $community 'atmospheremod-weather') 'layout.json';Touch $data 'tunables.ini' "T1=5`n"
 $record=@{version='0.6.0';sim=$sim;community=$community;installedBy='OptiShade'}|ConvertTo-Json
 [IO.File]::WriteAllText((Join-Path $data 'install.json'),$record)
 $null=RemoveOptiShadeRuntimeLeftovers $sim $true
 Assert (-not(Test-Path -LiteralPath (Join-Path $sim 'AtmosphereMod.addon64'))) 'OptiShade''s AtmosphereMod add-on stayed'
 Assert (-not(Test-Path -LiteralPath (Join-Path $sim 'ReShade.ini.atmospheremod.bak'))) 'The AtmosphereMod ReShade.ini backup stayed'
 Assert (-not(Test-Path -LiteralPath (Join-Path $community 'atmospheremod-weather'))) 'The EFB app stayed'
 Assert (-not(Test-Path -LiteralPath $data)) 'The AtmosphereMod data folder stayed'
 Assert ([IO.File]::ReadAllText((Join-Path $sim 'ReShade.ini')) -notmatch 'ATMOSPHEREMOD') 'The ReShade.ini section stayed'
 Assert (Test-Path -LiteralPath (Join-Path (GetAtmosphereModBackupFolder) 'tunables.ini')) 'The player''s tunables.ini was not kept'

 foreach($case in @(@{installedBy='';label='the mod''s own installer'},@{installedBy='OptiShade';label='another copy of the sim';other=$true})){
  $sim2=Join-Path $work ('Sim2-'+[guid]::NewGuid().ToString('N'));Touch $sim2 'FlightSimulator2024.exe';Touch $sim2 'AtmosphereMod.addon64'
  New-Item -ItemType Directory -Path $data -Force|Out-Null
  $simRecorded=if($case.other){'D:\Other\Content'}else{$sim2}
  [IO.File]::WriteAllText((Join-Path $data 'install.json'),(@{version='0.6.0';sim=$simRecorded;community=$community;installedBy=$case.installedBy}|ConvertTo-Json))
  $null=RemoveOptiShadeRuntimeLeftovers $sim2 $true
  Assert (Test-Path -LiteralPath (Join-Path $sim2 'AtmosphereMod.addon64')) ('Removed AtmosphereMod installed by '+$case.label)
  Assert (Test-Path -LiteralPath (Join-Path $data 'install.json')) ('Removed the data folder of '+$case.label)
 }

 # The crash-dump removal names only the key it was given, as a .reg deletion.
 $text=GetOptiShadeCrashDumpRemovalText @('FlightSimulator2024.exe','X-Plane.exe')
 Assert ($text -match '(?m)^\[-HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\Windows Error Reporting\\LocalDumps\\FlightSimulator2024\.exe\]') 'The removal text does not delete the game''s key'
 Assert ($text -match 'LocalDumps\\X-Plane\.exe\]') 'One prompt must cover every game'
 Assert ($text -notmatch 'LocalDumps\]') 'The removal text could delete the whole LocalDumps key'
 Assert ((RemoveOptiShadeCrashDumps @('C:\Games\NoSuchGame-OptiShadeTest.exe')) -eq 'nothing to remove') 'A key that was never set must not prompt'
}finally{$env:LOCALAPPDATA=$savedLocal;$env:APPDATA=$savedRoaming;Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}
'PASS: uninstall removes runtime leftovers, empty folders and OptiShade''s AtmosphereMod; stock files, a player''s own add-ons, ReShade and populated folders stay.'
