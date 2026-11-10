$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot 'reshade/res/shaders/optishade_guides.hlsl'
$header=Join-Path $PSScriptRoot 'reshade/res/shaders/optishade_guides.generated.h'
$sha=[Security.Cryptography.SHA256]::Create()
try{$digest=[BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($source))).Replace('-','')}finally{$sha.Dispose()}
$expected='// Source-SHA256: '+$digest
if(-not(Test-Path -LiteralPath $header) -or (Get-Content -LiteralPath $header -TotalCount 2)[1] -cne $expected){
 throw 'Core guide shader source differs from the compiled header. Run build-core-guides.ps1 with the pinned SPIR-V-capable DXC before building.'
}

$dx11=Join-Path $PSScriptRoot 'reshade/res/shaders/optishade_guides.dxbc.h'
if(-not(Test-Path -LiteralPath $dx11) -or (Get-Content -LiteralPath $dx11 -TotalCount 2)[1] -cne $expected){throw 'D3D11 guide header is stale. Run build-core-guides-dx11.ps1 with the pinned FXC.'}

$gl=Join-Path $PSScriptRoot 'reshade/res/shaders/optishade_guides.glsl.h'
$generator=Join-Path $PSScriptRoot 'reconstruction/generate_guides_glsl.py'
function GetNormalizedTextSha256([string]$Path){
 $hash=[Security.Cryptography.SHA256]::Create()
 try{$text=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($Path));$bytes=[Text.UTF8Encoding]::new($false).GetBytes($text.Replace("`r`n","`n").Replace("`r","`n"));return [BitConverter]::ToString($hash.ComputeHash($bytes)).Replace('-','')}
 finally{$hash.Dispose()}
}
$glExpected='// Source-SHA256: '+(GetNormalizedTextSha256 $source)
if(-not(Test-Path -LiteralPath $gl) -or (Get-Content -LiteralPath $gl -TotalCount 2)[1] -cne $glExpected){throw 'OpenGL guide variant is stale. Run reconstruction/generate_guides_glsl.py.'}
$generatorHash=[Security.Cryptography.SHA256]::Create()
try{$generatorText=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($generator));$generatorBytes=[Text.UTF8Encoding]::new($false).GetBytes($generatorText.Replace("`r`n","`n").Replace("`r","`n"));$generatorDigest=[BitConverter]::ToString($generatorHash.ComputeHash($generatorBytes)).Replace('-','')}finally{$generatorHash.Dispose()}
$generatorExpected='// Generator-SHA256: '+$generatorDigest
if((Get-Content -LiteralPath $gl -TotalCount 3)[2] -cne $generatorExpected){throw 'OpenGL guide translator changed. Regenerate and verify its GLSL output before building.'}
