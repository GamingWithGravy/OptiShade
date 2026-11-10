param([string]$Root=(Split-Path $PSScriptRoot -Parent | Split-Path -Parent))
$ErrorActionPreference='Stop'
$source=[IO.File]::ReadAllText((Join-Path $Root 'Beta/installer/ownership.ps1'))
$match=[regex]::Match($source,'(?ms)^function EnsureOptiShadeReShadeSearchPaths\(\[string\]\$Game\)\s*\{.*?^\}')
if(-not $match.Success){throw 'Production ReShade search-path migration was not found.'}
function OwnedPath([string]$Game,[string]$Relative){Join-Path $Game $Relative}
Invoke-Expression $match.Value
$temp=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-reshade-paths-'+[guid]::NewGuid().ToString('N'))
try{
 [IO.Directory]::CreateDirectory($temp)|Out-Null
 $ini=Join-Path $temp 'ReShade.ini'
 $cr=[char]13;$lf=[char]10
 $original="[GENERAL]$cr$lf"+'PresetPath=.\OptiShadeData\Presets\Mine.ini'+$cr+$lf+'EffectSearchPaths=.\old-custom\Shaders\**'+$cr+$lf+"[INPUT]$cr$lf"+'KeyOverlay=45,0,0,0'+$cr+$lf
 [IO.File]::WriteAllText($ini,$original,[Text.UTF8Encoding]::new($false))
 EnsureOptiShadeReShadeSearchPaths $temp
 $first=[IO.File]::ReadAllText($ini)
 foreach($expected in @('PresetPath=.\OptiShadeData\Presets\Mine.ini','EffectSearchPaths=.\\OptiShadeData\\Shaders\\**,.\old-custom\Shaders\**,.\\reshade-shaders\\Shaders\\**','TextureSearchPaths=.\OptiShadeData\Textures\**,.\\reshade-shaders\\Textures\\**','KeyOverlay=45,0,0,0')){if(-not $first.Contains($expected.Replace('\\','\'))){throw "Expected merged ReShade setting not found: $expected"}}
 EnsureOptiShadeReShadeSearchPaths $temp
 $second=[IO.File]::ReadAllText($ini)
 if($second -ne $first){throw 'Running the migration twice changed ReShade.ini again.'}
 $count=([regex]::Matches($second,'(?i)\.\\OptiShadeData\\Shaders\\\*\*')).Count
 if($count -ne 1){throw "Current shader path was written $count times."}
 # OSD-Q58X: a player's reshade-shaders listed first; OptiShade's own folder moves to the front.
 [IO.File]::WriteAllText($ini,"[GENERAL]$cr$lf"+'EffectSearchPaths=.\reshade-shaders\Shaders\**,.\OptiShadeData\Shaders\**'+$cr+$lf+'TextureSearchPaths=.\reshade-shaders\Textures\**,.\OptiShadeData\Textures\**'+$cr+$lf,[Text.UTF8Encoding]::new($false))
 EnsureOptiShadeReShadeSearchPaths $temp
 $reordered=[IO.File]::ReadAllText($ini)
 foreach($expected in @('EffectSearchPaths=.\OptiShadeData\Shaders\**,.\reshade-shaders\Shaders\**','TextureSearchPaths=.\OptiShadeData\Textures\**,.\reshade-shaders\Textures\**')){if(-not $reordered.Contains($expected)){throw "OptiShade's folder was not moved first: $reordered"}}
 'ReShade search-path migration fixture passed.'
}finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}
