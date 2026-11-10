$ErrorActionPreference='Stop'
. "$PSScriptRoot/ownership.ps1"
. "$PSScriptRoot/executable.ps1"
function GetOptiShadeExecutableIdentity([string]$File){return $script:TestIdentity}
. "$PSScriptRoot/mfg.ps1"

$root=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-MfgLoaderTest-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try{
 $exe=Join-Path $root 'FlightSimulator2024.exe'
 [IO.File]::WriteAllText($exe,'fixture')
 $manifest=[pscustomobject]@{Game=$root;LaunchExe=$exe;Files=@()}
 $script:TestIdentity=[pscustomobject]@{Path=$exe;Imports=@('version.dll','dinput8.dll','d3d12.dll');ApiCandidates=@('DX12')}
 $choice=SelectOptionalMfgLoader $manifest
 if($choice.Name -ne 'd3d12.dll' -or $choice.Evidence -notmatch 'Static renderer API import' -or $choice.Evidence -notmatch 'FlightSimulator2024.exe'){throw 'The renderer-specific imported MFG alias was not preferred.'}

 [IO.File]::WriteAllText((Join-Path $root 'version.dll'),'occupied')
 $script:TestIdentity=[pscustomobject]@{Imports=@('version.dll','d3d12.dll');ApiCandidates=@('DX12')}
 $fallbackAlias=SelectOptionalMfgLoader $manifest
 if($fallbackAlias.Name -ne 'd3d12.dll'){throw 'An occupied generic alias displaced the free renderer-specific alias.'}

 [IO.File]::WriteAllText((Join-Path $root 'd3d12.dll'),'occupied renderer proxy')
 $script:TestIdentity=[pscustomobject]@{Imports=@('version.dll','dinput8.dll','d3d12.dll');ApiCandidates=@('DX12')}
 $alternate=SelectOptionalMfgLoader $manifest
 if($alternate.Name -ne 'dinput8.dll' -or [IO.File]::ReadAllText((Join-Path $root 'version.dll')) -ne 'occupied'){throw 'An occupied renderer alias was overwritten or version.dll was preferred to a free supported alias.'}
 [IO.File]::Delete((Join-Path $root 'd3d12.dll'))

 [IO.File]::Delete((Join-Path $root 'version.dll'))
 $script:TestIdentity=[pscustomobject]@{Imports=@('unrelated.dll');ApiCandidates=@()}
 $threw=$false
 try{$null=SelectOptionalMfgLoader $manifest}catch{$threw=$_.Exception.Message -match 'No supported MFG loader alias is imported' -and $_.Exception.Message -match 'do not rename or overwrite'}
 if(-not $threw -or (Test-Path -LiteralPath (Join-Path $root 'version.dll'))){throw 'An unproven default loader was selected instead of preserving the game directory.'}

 $script:TestIdentity=[pscustomobject]@{Architecture='x64';Imports=@();ApiCandidates=@();Evidence='Recorded x64 Store/Xbox content launch helper selected; rendering executable read denied; renderer/API and PE hash unknown'}
 $threw=$false
 try{$null=SelectOptionalMfgLoader $manifest}catch{$threw=$_.Exception.Message -match 'unknown or unreadable' -and $_.Exception.Message -match 'No game files were changed'}
 if(-not $threw -or (Test-Path -LiteralPath (Join-Path $root 'version.dll'))){throw 'An unreadable Store renderer was reported as a confirmed missing alias or changed game files.'}

 $storeManifest=[pscustomobject]@{Game=$root;LaunchExe=$exe;Architecture='x64';RouteDLL='OptiShadeMSFS2024.dll';Files=@()}
 $storeChoice=SelectOptionalMfgLoader $storeManifest
 if($storeChoice.Name -ne 'version.dll' -or $storeChoice.Evidence -notmatch 'Runtime load and MFG output must be checked in-game' -or (Test-Path -LiteralPath (Join-Path $root 'version.dll'))){throw 'A known MSFS Store route did not stage an in-game-verifiable free alias.'}
 [IO.File]::WriteAllText((Join-Path $root 'version.dll'),'foreign loader')
 $threw=$false
 try{$null=SelectOptionalMfgLoader $storeManifest}catch{$threw=$_.Exception.Message -match 'unknown or unreadable' -and $_.Exception.Message -match 'No game files were changed'}
 if(-not $threw -or [IO.File]::ReadAllText((Join-Path $root 'version.dll')) -ne 'foreign loader'){throw 'The MSFS Store fallback selected or overwrote an occupied alias.'}
 [IO.File]::Delete((Join-Path $root 'version.dll'))

 $script:TestIdentity=[pscustomobject]@{Imports=@('version.dll');ApiCandidates=@()}
 $explicit=SelectOptionalMfgLoader $manifest
 if($explicit.Name -ne 'version.dll' -or $explicit.Evidence -notmatch 'Static import'){throw 'An explicitly imported version.dll alias was not accepted as evidence-backed.'}

 $script:TestIdentity=[pscustomobject]@{Imports=@('version.dll','dinput8.dll');ApiCandidates=@()}
 [IO.File]::WriteAllText((Join-Path $root 'version.dll'),'occupied')
 [IO.File]::WriteAllText((Join-Path $root 'dinput8.dll'),'occupied')
 $threw=$false
 try{$null=SelectOptionalMfgLoader $manifest}catch{$threw=$true}
 if(-not $threw){throw 'An occupied alias was selected.'}

 Copy-Item (Join-Path $PSScriptRoot 'OptionalMFG/RTXMFG.dll') (Join-Path $root 'dinput8.dll') -Force
 $manifest|Add-Member OptionalMfg $true
 $manifest|Add-Member OptionalMfgLoader 'version.dll'
 $manifest.Files=@([pscustomobject]@{Path='version.dll';Hash='E9CA3587854EEB723E0579F7DDF6CFB1E6CF4BED79B0D75BC716003ED98FE040';Mutable=$false})
 if((GetOptiShadeMfgLoaderName $manifest) -ne 'dinput8.dll'){throw 'The verified moved MFG alias was not recognised.'}
 $core=[pscustomobject]@{Path='winmm.dll';Hash='CORE-HASH';Mutable=$false;Component='Core'}
 $fresh=[pscustomobject]@{Files=@($core)}
 SetOptiShadeMfgLoaderRecord $fresh 'version.dll' 'MFG-HASH' '' ''
 if($fresh.Files.Count -ne 2 -or @($fresh.Files|Where-Object {$_.Path -eq 'winmm.dll' -and $_.Component -eq 'Core'}).Count -ne 1){throw 'A fresh MFG record removed an unrelated core loader receipt.'}
 $adopted=[pscustomobject]@{Files=@($core,[pscustomobject]@{Path='version.dll';Hash='MFG-HASH';Mutable=$false;PreviousHash='ORIGINAL-HASH';Backup='backup.bin';Retained=$true})}
 SetOptiShadeMfgLoaderRecord $adopted 'dinput8.dll' 'MFG-HASH' 'ORIGINAL-HASH' 'backup.bin'
 if($adopted.Files.Count -ne 2 -or @($adopted.Files|Where-Object {$_.Path -eq 'winmm.dll' -and $_.Component -eq 'Core'}).Count -ne 1 -or @($adopted.Files|Where-Object {$_.Path -eq 'dinput8.dll' -and $_.Hash -eq 'MFG-HASH'}).Count -ne 1){throw 'MFG alias adoption removed an unrelated core loader receipt.'}
 $header=Get-Content -LiteralPath (Join-Path $PSScriptRoot '../shared/MfgControlWin.h') -Raw
 if($header -notmatch 'L"dinput8\.dll"' -or $header -notmatch 'kExpectedDllSha256'){throw 'Runtime alias identity verification is missing.'}
 Write-Output 'MFG loader alias tests passed.'
}finally{
 foreach($name in @('FlightSimulator2024.exe','version.dll','dinput8.dll','d3d12.dll')){$file=Join-Path $root $name;if(Test-Path -LiteralPath $file){[IO.File]::Delete($file)}}
 [IO.Directory]::Delete($root)
}
