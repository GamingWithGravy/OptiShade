$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/updates.ps1"
$env:OPTISHADE_STORE=Join-Path $env:TEMP ('OptiShade-channel-'+[guid]::NewGuid().ToString('N'))
function Release([string]$version,[bool]$beta=$false){[pscustomobject]@{draft=$false;prerelease=$beta;tag_name="v$version";body='fixture';assets=@([pscustomobject]@{name="OptiShade_Version_$version.exe";browser_download_url="https://github.com/GamingWithGravy/OptiShade/releases/download/v$version/OptiShade_Version_$version.exe";digest=('sha256:'+('a'*64))})}}
$script:releases=@((Release '0.21.2'),(Release '0.21.4'),(Release '0.22-beta.1' $true))
$script:manifest=[pscustomobject]@{schema=1;channel='beta';version='0.21.3-beta.3';bytes=4;sha256=('a'*64);notes='fixture';parts=@([pscustomobject]@{name='OptiShade-beta.part01';bytes=4;sha256=('b'*64)})}
$script:calls=[Collections.Generic.List[string]]::new()
function Invoke-RestMethod {param([string]$Uri,$Headers,$TimeoutSec)
 $script:calls.Add($Uri)
 if($Uri -match '/releases\?') {return $script:releases}
 if($Uri -eq 'https://api.github.com/repos/GamingWithGravy/OptiShade/commits/beta'){return [pscustomobject]@{sha=('c'*40)}}
 if($Uri -eq ('https://raw.githubusercontent.com/GamingWithGravy/OptiShade/'+('c'*40)+'/downloads/beta/manifest.json')){return $script:manifest}
 throw 'Unexpected download source'
}
if((GetOptiShadeUpdateChannel) -ne 'stable'){throw 'Must default to stable'}
$offer=GetOptiShadeUpdate -Current '0.21.2' -InstalledChannel stable -ReportErrors
if($offer.Version -ne '0.21.4' -or $script:calls.Count -ne 1 -or $script:calls[0] -notmatch '/releases\?'){throw 'Stable queried beta or selected wrong source'}
$null=GetOptiShadeBetaCandidate '0.21.2'
if($script:calls.Count -ne 1){throw 'Beta source queried without opt-in'}
SetOptiShadeUpdateChannel $true;$script:calls.Clear()
$offer=GetOptiShadeUpdate -Current '0.21.3' -InstalledChannel stable -ReportErrors
if($offer.Version -ne '0.21.3-beta.3' -or $offer.Source -ne 'beta-branch' -or @($script:calls|Where-Object {$_ -match '/releases\?'}).Count){throw 'Beta channel did not exclusively use branch'}
if(GetOptiShadeUpdate -Current '0.21.3-beta.3' -InstalledChannel beta -ReportErrors){throw 'Same beta offered again'}
if((GetOptiShadeUpdate -Current '0.21.3-beta.2' -InstalledChannel beta -ReportErrors).Version -ne '0.21.3-beta.3'){throw 'New beta revision not offered'}
$script:manifest.parts[0].name='../unsafe.part'
$rejected=$false;try{GetOptiShadeUpdate -Current '0.21.2' -ReportErrors}catch{$rejected=$true}
if(-not $rejected){throw 'Invalid branch manifest did not fail closed'}
$script:manifest.parts[0].name='OptiShade-beta.part01'
SetOptiShadeUpdateChannel $false
$return=GetOptiShadeUpdate -Current '0.21.3-beta.3' -InstalledChannel beta -ReportErrors
if($return.Version -ne '0.21.4' -or -not $return.Rollback -or $return.Channel -ne 'stable'){throw 'Latest stable return failed'}
$script:releases=@((Release '0.21.2'),(Release '0.22-beta.1' $true))
$return=GetOptiShadeUpdate -Current '0.21.3-beta.3' -InstalledChannel beta -ReportErrors
if($return.Version -ne '0.21.2' -or -not $return.Rollback){throw 'Return to older stable failed'}
$destination=Join-Path $env:OPTISHADE_STORE 'blocked.exe';$rejected=$false
try{SaveOptiShadeBetaDownload $offer $destination $env:OPTISHADE_STORE {}}catch{$rejected=$true}
if(-not $rejected -or (Test-Path $destination)){throw 'Beta download started after opt-out'}
$script:releases=@((Release '0.21.2'),(Release '0.21.4'),(Release '0.22-beta.1' $true))
$latest=@(GetOptiShadePreviousReleases | Sort-Object {[version]$_.Version} -Descending)
if($latest[0].Version -ne '0.21.4' -or @($latest|Where-Object Version -match 'beta').Count){throw 'Stable picker is pinned or includes beta'}
$modern=Release '0.21.4';$modern.assets[0].name='Optishade.0.21.4.stable.exe';$modern.assets[0].browser_download_url='https://github.com/GamingWithGravy/OptiShade/releases/download/v0.21.4/Optishade.0.21.4.stable.exe'
if(-not(GetOptiShadeReleaseAsset $modern '0.21.4')){throw 'Normalised stable filename rejected'}
'PASS: isolated sources, explicit opt-in, immutable beta commit, invalid manifest rejection, no fallback and dynamic stable return'
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
