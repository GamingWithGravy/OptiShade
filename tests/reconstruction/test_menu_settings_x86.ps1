$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
function OwnedPath([string]$Root,[string]$Relative){Join-Path $Root $Relative}
function AssertClosed([string]$Game){}
function ManifestPath([string]$StateRoot,[string]$Game){Join-Path $Game 'optishade-test-manifest.json'}
function ReadOptiShadeState([string]$Path){Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}
. "$root/Beta/installer/menu-settings.ps1"
function Check([bool]$Condition,[string]$Name){if(-not $Condition){throw $Name};Write-Output "PASS: $Name"}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('optishade-menu-x86-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temp)
$script:store=$temp
try{
 $x86=Join-Path $temp 'x86';[void](New-Item -ItemType Directory -Path $x86)
 [IO.File]::WriteAllBytes((Join-Path $x86 'd3d9.dll'),[byte[]](1,2,3))
 [IO.File]::WriteAllText((Join-Path $x86 'OptiScaler.ini'),"[Menu]`r`nShortcutKey=99`r`n",[Text.UTF8Encoding]::new($false))
 [IO.File]::WriteAllText((ManifestPath $temp $x86),'{"Architecture":"x86","Status":"Installed"}',[Text.UTF8Encoding]::new($false))
 $ini=Join-Path $x86 'ReShade.ini'
 [IO.File]::WriteAllText($ini,"[GENERAL]`r`nPresetPath=looks.ini`r`n[INPUT]`r`nKeyOverlay=36,0,0,0`r`n[OVERLAY]`r`nShowFPS=1`r`n",[Text.UTF8Encoding]::new($false))
 $settings=GetMenuSettings $x86
 Check ($settings.MenuRuntime -eq 'ReShade32' -and -not $settings.SupportsOptiScalerShortcuts -and $settings.ShortcutKey -eq 36) 'x86 menu settings read the local ReShade overlay key and report unsupported OptiScaler shortcuts'
 SetMenuSettings $x86 45 79 0 0
 $text=[IO.File]::ReadAllText($ini)
 Check ($text.Contains('KeyOverlay=45,0,0,0') -and $text.Contains('PresetPath=looks.ini') -and $text.Contains('ShowFPS=1')) 'saving an x86 shortcut changes only the ReShade menu key and preserves unrelated settings'
 Check ([IO.File]::ReadAllText((Join-Path $x86 'OptiScaler.ini')).Contains('ShortcutKey=99')) 'x86 shortcut saving does not edit its unused OptiScaler configuration'

 $presetRelative='OptiShadeData/Presets/Imported-001/look.ini'
 $presetPath=OwnedPath $x86 $presetRelative
 [void][IO.Directory]::CreateDirectory((Split-Path $presetPath -Parent))
 [IO.File]::WriteAllText($presetPath,'Techniques=Test@Test.fx',[Text.UTF8Encoding]::new($false))
 SetOptiShadeReShadePreset $x86 $presetRelative
 $text=[IO.File]::ReadAllText($ini)
 Check ($text.Contains('PresetPath=.\OptiShadeData\Presets\Imported-001\look.ini') -and $text.Contains('StartupPresetPath=') -and $text.Contains('KeyOverlay=45,0,0,0') -and $text.Contains('ShowFPS=1')) 'imported look is selected for next startup while unrelated ReShade settings are preserved'
 SetOptiShadeReShadePreset $x86 $presetRelative
 $text=[IO.File]::ReadAllText($ini)
 Check (([regex]::Matches($text,'(?im)^PresetPath=')).Count -eq 1 -and ([regex]::Matches($text,'(?im)^StartupPresetPath=')).Count -eq 1) 'applying an imported look does not duplicate ReShade preset keys'
 $beforeMissing=$text
 $failed=$false
 try{SetOptiShadeReShadePreset $x86 'OptiShadeData/Presets/missing.ini'}catch{$failed=$true}
 Check ($failed -and [IO.File]::ReadAllText($ini) -eq $beforeMissing) 'missing imported look fails without changing ReShade.ini'

 $missing=Join-Path $temp 'missing-key';[void](New-Item -ItemType Directory -Path $missing)
 [IO.File]::WriteAllBytes((Join-Path $missing 'd3d9.dll'),[byte[]](1,2,3))
 [IO.File]::WriteAllText((Join-Path $missing 'OptiScaler.ini'),"[Menu]`r`nShortcutKey=99`r`n",[Text.UTF8Encoding]::new($false))
 [IO.File]::WriteAllText((ManifestPath $temp $missing),'{"Architecture":"x86","Status":"Installed"}',[Text.UTF8Encoding]::new($false))
 $missingIni=Join-Path $missing 'ReShade.ini';[IO.File]::WriteAllText($missingIni,"[GENERAL]`r`nEffectSearchPaths=.`r`n",[Text.UTF8Encoding]::new($false))
 Check ((GetMenuSettings $missing).ShortcutKey -eq 45) 'missing local ReShade key matches OptiShade Insert default'
 SetMenuSettings $missing 73 79 0 0
 Check ([IO.File]::ReadAllText($missingIni).Contains("[INPUT]`r`nKeyOverlay=73,0,0,0")) 'saving a shortcut adds an INPUT section when ReShade has no local key'

 $x64=Join-Path $temp 'x64';[void](New-Item -ItemType Directory -Path $x64)
 [IO.File]::WriteAllBytes((Join-Path $x64 'ReShade64.dll'),[byte[]](1,2,3))
 [IO.File]::WriteAllText((ManifestPath $temp $x64),'{"Architecture":"x64","Status":"Installed"}',[Text.UTF8Encoding]::new($false))
 $os=Join-Path $x64 'OptiScaler.ini';[IO.File]::WriteAllText($os,"[Menu]`r`nShortcutKey=45`r`nBackupShortcutKey=79`r`nPresetHotSwapKey=0`r`nSnapshotKey=0`r`nFpsShortcutKey=33`r`n",[Text.UTF8Encoding]::new($false))
 $x64Settings=GetMenuSettings $x64
 Check ($x64Settings.MenuRuntime -eq 'OptiScaler' -and $x64Settings.SupportsOptiScalerShortcuts -and $x64Settings.ShortcutKey -eq 45) '64-bit OptiScaler shortcut settings retain their existing backend'
 SetMenuSettings $x64 67 79 0 0
 Check ([IO.File]::ReadAllText($os).Contains('ShortcutKey=67')) '64-bit OptiScaler primary shortcut remains editable'
 Write-Output '32-bit and 64-bit menu shortcut tests passed.'
}finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}
