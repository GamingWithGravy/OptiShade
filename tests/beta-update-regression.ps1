$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/updates.ps1"
$env:OPTISHADE_STORE=Join-Path $env:TEMP ('OptiShade-channel-'+[guid]::NewGuid().ToString('N'))
if((GetOptiShadeUpdateChannel) -ne 'stable'){throw 'Must default to stable'}
SetOptiShadeUpdateChannel $true
if((GetOptiShadeUpdateChannel) -ne 'beta'){throw 'Opt in did not persist'}
function Release([string]$version,[bool]$beta=$true){[pscustomobject]@{draft=$false;prerelease=$beta;tag_name="v$version";body='fixture';assets=@([pscustomobject]@{name="OptiShade_Version_$version.exe";browser_download_url="https://github.com/GamingWithGravy/OptiShade/releases/download/v$version/OptiShade_Version_$version.exe";digest=('sha256:'+('a'*64))})}}
function Invoke-RestMethod { $script:releases }
$script:releases=@((Release '0.21.1' $false))
if(GetOptiShadeUpdate -ReportErrors){throw 'Stable offered to beta'}
$script:releases=@((Release '0.22-beta2'),(Release '0.22-beta10'),(Release '0.23' $false))
if((GetOptiShadeUpdate -Current '0.22-beta2' -ReportErrors).Version -ne '0.22-beta10'){throw 'Beta numeric ordering failed'}
if(GetOptiShadeUpdate -Current '0.22-beta10' -ReportErrors){throw 'Same build offered again'}
$invalid=Release '0.24-beta1';$invalid.assets[0].browser_download_url='https://github.com/another/repo/test.exe'
$script:releases+=@($invalid)
if((GetOptiShadeUpdate -Current '0.22-beta2' -ReportErrors).Version -ne '0.22-beta10'){throw 'Invalid newer asset hides valid update'}
SetOptiShadeUpdateChannel $false
$script:releases=@((Release '0.21.1' $false),(Release '0.22-beta10'))
$return=GetOptiShadeUpdate -Current '0.22-beta10' -ReportErrors
if($return.Version -ne '0.21.1' -or -not $return.Rollback -or $return.Channel -ne 'stable'){throw 'Opt out did not offer stable return'}
if(GetOptiShadeUpdate -Current '0.21.1' -InstalledChannel stable -ReportErrors){throw 'Stable same build offered again'}
if($return.ReleaseUrl -ne 'https://github.com/GamingWithGravy/OptiShade/releases/tag/v0.21.1'){throw 'Portable stable link points to wrong release'}
if(Test-Path (Join-Path $env:OPTISHADE_STORE 'beta-updates.txt')){throw 'Opt out did not persist'}
'PASS: opt in/out persisted, correct channels and URLs, beta ordering, stable return and same-version rejection'
. "$PSScriptRoot/../installer/ownership.ps1"
function AssertClosed($Game){}
$fixture=Join-Path $env:TEMP ('OptiShade-beta-update-'+[guid]::NewGuid().ToString('N'))
$game=Join-Path $fixture 'Game';$payload=Join-Path $fixture 'Payload';$store=Join-Path $fixture 'Store'
New-Item -ItemType Directory -Path $game,$payload,$store|Out-Null
Set-Content (Join-Path $payload 'winmm.dll') 'fixture DLL'
ConvertTo-Json -InputObject @(@{Path='winmm.dll';Hash=(HashFile (Join-Path $payload 'winmm.dll'))})|Set-Content (Join-Path $payload 'files.json')
$mp=InstallFusion $game $payload $store 'fixture.exe'
Set-Content (Join-Path $game 'ReShade.log') 'runtime-generated diagnostic'
$before=HashFile (Join-Path $game 'ReShade.log')
$m=Get-Content $mp -Raw|ConvertFrom-Json
$conflicts=@(GetFusionUpdateConflicts $m)
InstallFusion $game $payload $store 'fixture.exe' 'winmm.dll' $conflicts -ReplaceExisting $true -PreserveConfiguration $true|Out-Null
if((HashFile (Join-Path $game 'ReShade.log')) -ne $before){throw 'Log changed during update'}
Set-Content (Join-Path $game 'dxgi.dll') 'unknown graphics loader'
$blocked=$false;try{GetFusionUpdateConflicts (Get-Content $mp -Raw|ConvertFrom-Json)|Out-Null}catch{$blocked=$true}
if(-not $blocked){throw 'Unknown graphics loader was accepted'}
'PASS: generated log survives installation; unknown DLL still blocks update'