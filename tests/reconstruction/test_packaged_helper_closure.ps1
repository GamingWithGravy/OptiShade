param([string]$Root=(Join-Path $PSScriptRoot '../..'))
$ErrorActionPreference='Stop'
$installer=Join-Path $Root 'Beta/installer'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-PackagedHelpers-'+[guid]::NewGuid().ToString('N'))
$checks=0
function Check([bool]$Value,[string]$Message){$script:checks++;if(-not $Value){throw $Message}}
try{
 $tools=Join-Path $fixture 'Tools';[void][IO.Directory]::CreateDirectory($tools)
 # Use the package's actual dependency list in a new process, without any
 # manager functions preloaded into that process. This caught missing scripts
 # hidden by the manager's wider dot-source closure.
 $package=[IO.File]::ReadAllText((Join-Path $Root 'Beta/package.ps1'))
 $match=[regex]::Match($package,'foreach\(\$dependency in @\((?<files>[^\r\n]+)\)\)\{Copy-Item -LiteralPath "\$root/installer/\$dependency"')
 Check $match.Success 'The active package helper closure was not found.'
 $files=@([regex]::Matches($match.Groups['files'].Value,"'([^']+)'")|ForEach-Object {$_.Groups[1].Value})
 foreach($name in @('import-effects.ps1','store-paths.ps1','EffectPackages.ini')+$files){Copy-Item -LiteralPath (Join-Path $installer $name) -Destination (Join-Path $tools $name)}
 $child=Join-Path $fixture 'verify-fresh-helper.ps1'
 @'
param([string]$Tools,[string]$Fixture)
$ErrorActionPreference='Stop'
. (Join-Path $Tools 'import-effects.ps1')
$env:LOCALAPPDATA=Join-Path $Fixture 'profile'
$env:OPTISHADE_STORE=Join-Path $Fixture 'unrelated-store'
# This isolated helper process represents a user who accepted the
# launcher-wide agreement before starting maintenance.
$env:OPTISHADE_ANTICHEAT_SESSION_ACCEPTED='1'
$game=Join-Path $Fixture 'game';$store=Join-Path $Fixture 'portable-store'
[void][IO.Directory]::CreateDirectory((Join-Path $game 'OptiShadeData'))
if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){
 $manifestPath=ManifestPath $store $game
 [void][IO.Directory]::CreateDirectory((Split-Path $manifestPath -Parent))
 $manifest=[pscustomobject]@{Game=$game;Status='Installed';Files=@([pscustomobject]@{Path='dxgi.dll';Hash=('A'*64)})}
 WriteState $manifest $manifestPath
 [IO.File]::WriteAllText((Join-Path $game 'OptiShadeData/dependency-state.ini'),"[Storage]`nRoot=$store")
 $existing=GetOptiShadeExistingInstallation $game
 if(-not $existing -or $existing.Path -ne $manifestPath){throw 'Fresh extracted helper lost the canonical portable receipt.'}
 AssertAntiCheatMutation $game '' 'Offline helper receipt test'
 $manifest.Status='Restored';WriteState $manifest $manifestPath
 if(TestAntiCheatExistingInstallation $game){throw 'A restored receipt incorrectly authorizes maintenance.'}
}
if(-not (Get-Command GetOptiShadeExecutableIdentity -CommandType Function)){throw 'Executable identity dependency was not loaded.'}
if(-not (Get-Command ResolveOptiShadeNeuralAdapter -CommandType Function)){throw 'Measured adapter dependency was not loaded.'}
$models=@(GetOptiShadeNeuralModelCatalog)
if($models.Count -ne 4){throw 'The current pinned model policy is missing from the deployed closure.'}
Add-Type -Path (Join-Path $Tools 'GpuIdentityClient.cs')
if(-not ('OptiShadeGpuIdentity' -as [type])){throw 'Deployed GPU identity client does not compile.'}
$preset=Join-Path $game 'retained.ini'
[IO.File]::WriteAllText($preset,'Techniques=Retained@Retained.fx')
$shaders=@(GetPresetShaderNames $preset)
if($shaders.Count -ne 1 -or $shaders[0] -cne 'Retained.fx'){throw 'The actual importer did not resolve the retained preset technique.'}
if(Get-Command InvokeSimpleNeuralDependency -ErrorAction SilentlyContinue){throw 'The retired standalone model installer remains active in the helper process.'}
'Fresh deployed helper: script closure, model policy, compiled identity client and preset parsing passed. Canonical receipt checks run only on Windows. No OS GPU probe or Windows file-import test was run.'
'@ | Set-Content -LiteralPath $child -Encoding utf8
 $pwsh=(Get-Process -Id $PID).Path
 $output=@(& $pwsh -NoProfile -NonInteractive -File $child -Tools $tools -Fixture $fixture 2>&1)
 Check ($LASTEXITCODE -eq 0) ('The fresh packaged helper failed: '+($output -join "`n"))
 Check (-not ($files -contains 'neural-dependency.ps1')) 'The obsolete standalone neural preparation script is still packaged.'
 Check (-not ($files -contains 'neural-download.ps1')) 'The manager model downloader remains in the independent in-game helper payload.'
 Check (-not ($files -contains 'nvidia.ps1')) 'The unused vendor installer remains in the independent in-game helper payload.'
 foreach($name in @('executable.ps1','gpu-identity.ps1','GpuIdentityClient.cs','neural-model-policy.json')){
  Check ((Get-FileHash -LiteralPath (Join-Path $tools $name)).Hash -ceq (Get-FileHash -LiteralPath (Join-Path $installer $name)).Hash) ('Deployed dependency differs from its canonical source: '+$name)
 }
 Write-Output ($output -join "`n")
 Write-Output "PASS: $checks packaged-helper assertions with an actual fresh child process; no game was installed or launched."
}finally{
 if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}
}
