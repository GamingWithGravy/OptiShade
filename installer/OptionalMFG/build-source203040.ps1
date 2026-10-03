param(
 [Parameter(Mandatory=$true)][string]$StreamlineRoot,
 [Parameter(Mandatory=$true)][string]$BuildDirectory,
 [string]$CMakeExecutable='cmake'
)
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot 'Source203040/native'
& $CMakeExecutable -S $source -B $BuildDirectory -G 'Visual Studio 17 2022' -A x64 "-DSTREAMLINE_ROOT=$StreamlineRoot" -DMFG_UNLOCK_BUILD_UNIVERSAL_UI=OFF
if($LASTEXITCODE){throw 'Source MFG configure failed'}
& $CMakeExecutable --build $BuildDirectory --config Release --target RTX40MFGCore
if($LASTEXITCODE){throw 'Source MFG build failed'}
$dll=Join-Path $BuildDirectory 'Release/OptiShadeMFG.dll'
$pdb=Join-Path $BuildDirectory 'Release/OptiShadeMFG.pdb'
if(-not(Test-Path $pdb)){throw 'Matching MFG symbols missing'}
$hash=(Get-FileHash $dll).Hash.ToLowerInvariant()
$inputs=@{}
Get-ChildItem (Join-Path $PSScriptRoot 'Source203040') -File -Recurse|ForEach-Object {$inputs[$_.FullName.Substring((Join-Path $PSScriptRoot 'Source203040').Length+1).Replace('\','/')]=(Get-FileHash $_.FullName).Hash}
$sdk=@{}
foreach($sub in 'include','external/ngx-sdk/include'){Get-ChildItem (Join-Path $StreamlineRoot $sub) -File -Recurse|ForEach-Object {$sdk[$_.FullName.Substring([IO.Path]::GetFullPath($StreamlineRoot).TrimEnd('\','/').Length+1).Replace('\','/')]=(Get-FileHash $_.FullName).Hash}}
Copy-Item $dll (Join-Path $PSScriptRoot 'OptiShadeMFG.dll') -Force
$manifest=@{schema=1;abi=131072;sha256=$hash;sourceRevision='21a2b9931f0c13f46a4b3b8a5856620d9698f88e';families=@(20,30,40);api='D3D12';headless=$true;nativeGameConnectionRequired=$true;hardwareVerification='AWAITING TARGET TEST';SourceFiles=$inputs;SdkHeaders=$sdk;SymbolsSHA256=(Get-FileHash $pdb).Hash}
$manifest|ConvertTo-Json -Depth 5|Set-Content (Join-Path $PSScriptRoot 'source-build.json') -Encoding UTF8
$tree=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$header=Join-Path $tree 'shared/SourceMfgIdentity.h'
[IO.File]::WriteAllText($header,"#pragma once`n// Generated from the pinned source build.`nnamespace optishade::mfg { inline constexpr char kSourceDllSha256[]=`"$hash`"; }`n")
$installer=Join-Path $tree 'installer/mfg.ps1';$text=[IO.File]::ReadAllText($installer) -replace '\$script:SourceMfgSha256="[0-9a-f]{64}"',('$script:SourceMfgSha256="'+$hash+'"')
[IO.File]::WriteAllText($installer,$text,[Text.UTF8Encoding]::new($true))
"Built $dll. Rebuild native OptiShade before packaging; this is not a hardware verification."
