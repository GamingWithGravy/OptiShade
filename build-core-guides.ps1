param([Parameter(Mandatory=$true)][string]$Dxc)
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot 'reshade/res/shaders/optishade_guides.hlsl'
$output=Join-Path $PSScriptRoot 'reshade/res/shaders/optishade_guides.generated.h'
$temp=Join-Path $PSScriptRoot 'test-run/core-guides'
[void][IO.Directory]::CreateDirectory($temp)
$lines=[Collections.Generic.List[string]]::new()
$lines.Add('// Generated from original optishade_guides.hlsl; GPL-3.0-or-later. Do not edit.')
$lines.Add('// Source-SHA256: '+(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash)
$lines.Add('#pragma once')
$lines.Add('namespace osguide::shaders {')
foreach($entry in @('Prepare','Estimate','Resolve')){
 foreach($format in @('dxil','spirv')){
  $target=Join-Path $temp ($entry+'.'+$format)
  $args=@('-T','cs_6_0','-E',$entry,'-O3','-Fo',$target,$source)
  if($format -eq 'spirv'){$args+=@('-spirv','-D','SPIRV','-fspv-target-env=vulkan1.1')}
  & $Dxc @args
  if($LASTEXITCODE){throw "Core guide shader compilation failed: $entry/$format"}
  $bytes=[IO.File]::ReadAllBytes($target)
  $lines.Add("alignas(4) inline constexpr unsigned char ${entry}_${format}[] = {")
  for($i=0;$i -lt $bytes.Length;$i+=24){$last=[Math]::Min($i+23,$bytes.Length-1);$lines.Add(($bytes[$i..$last]|ForEach-Object {'0x{0:X2}' -f $_}) -join ',');if($last -lt $bytes.Length-1){$lines[$lines.Count-1]+=','}}
  $lines.Add('};')
 }
}
$lines.Add('}')
[IO.File]::WriteAllLines($output,$lines,[Text.UTF8Encoding]::new($false))
@{SourceSHA256=(Get-FileHash $source).Hash;CompilerSHA256=(Get-FileHash $Dxc).Hash;GeneratedSHA256=(Get-FileHash $output).Hash}|ConvertTo-Json|Set-Content (Join-Path $temp 'identity.json')
