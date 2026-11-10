param([Parameter(Mandatory=$true)][string]$Fxc)
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot 'reshade/res/shaders/optishade_guides.hlsl'
$output=Join-Path $PSScriptRoot 'reshade/res/shaders/optishade_guides.dxbc.h'
$temp=Join-Path $PSScriptRoot 'test-run/core-guides-dx11'
[void][IO.Directory]::CreateDirectory($temp)
# SM5 uses the same constant-buffer layout with the older declaration syntax.
$text=[IO.File]::ReadAllText($source).Replace('ConstantBuffer<FrameData> frame : register(b0);','cbuffer FrameBuffer : register(b0) { uint width, height, warm, reversed; uint logarithmic; float depthMultiplier; uint depthWidth, depthHeight; };')
$text=[regex]::Replace($text,'(?m)^#define (width|height|warm|reversed|logarithmic|depthMultiplier|depthWidth|depthHeight) frame\.[^\r\n]+\r?\n','')
$input=Join-Path $temp 'guides-sm5.hlsl';[IO.File]::WriteAllText($input,$text)
$lines=[Collections.Generic.List[string]]::new()
$lines.Add('// Generated SM5 variant of original optishade_guides.hlsl; GPL-3.0-or-later.')
$lines.Add('// Source-SHA256: '+(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash)
$lines.Add('#pragma once');$lines.Add('namespace osguide::shaders {')
foreach($entry in @('Prepare','Estimate','Resolve')){
 $target=Join-Path $temp ($entry+'.dxbc')
 & $Fxc /nologo /T cs_5_0 /E $entry /O3 /Fo $target $input
 if($LASTEXITCODE){throw "D3D11 guide compilation failed: $entry"}
 $bytes=[IO.File]::ReadAllBytes($target);$lines.Add("alignas(4) inline constexpr unsigned char ${entry}_dxbc[] = {")
 for($i=0;$i -lt $bytes.Length;$i+=24){$last=[Math]::Min($i+23,$bytes.Length-1);$line=($bytes[$i..$last]|ForEach-Object {'0x{0:X2}' -f $_}) -join ',';if($last -lt $bytes.Length-1){$line+=','};$lines.Add($line)}
 $lines.Add('};')
}
$lines.Add('}');[IO.File]::WriteAllLines($output,$lines,[Text.UTF8Encoding]::new($false))
@{SourceSHA256=(Get-FileHash $source).Hash;CompilerSHA256=(Get-FileHash $Fxc).Hash;GeneratedSHA256=(Get-FileHash $output).Hash;Profile='cs_5_0'}|ConvertTo-Json|Set-Content (Join-Path $temp 'identity.json')
