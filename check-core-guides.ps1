$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot 'reshade/res/shaders/optishade_guides.hlsl'
$header=Join-Path $PSScriptRoot 'reshade/res/shaders/optishade_guides.generated.h'
$sha=[Security.Cryptography.SHA256]::Create()
try{$digest=[BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($source))).Replace('-','')}finally{$sha.Dispose()}
$expected='// Source-SHA256: '+$digest
if(-not(Test-Path -LiteralPath $header) -or (Get-Content -LiteralPath $header -TotalCount 2)[1] -cne $expected){
 throw 'Core guide shader source differs from the compiled header. Run build-core-guides.ps1 with the pinned SPIR-V-capable DXC before building.'
}
