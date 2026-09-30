$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/updates.ps1"
$env:OPTISHADE_STORE=Join-Path $env:TEMP ('OptiShade-channel-'+[guid]::NewGuid().ToString('N'))
if((GetOptiShadeUpdateChannel) -ne 'stable'){throw 'Must default to stable'}
SetOptiShadeUpdateChannel $true
if((GetOptiShadeUpdateChannel) -ne 'beta'){throw 'Opt in did not persist'}
function Release([string]$version,[bool]$beta=$true){[pscustomobject]@{draft=$false;prerelease=$beta;tag_name="v$version";body='fixture';assets=@([pscustomobject]@{name="OptiShade_Version_$version.exe";browser_download_url="https://github.com/GamingWithGravy/OptiShade/releases/download/v$version/OptiShade_Version_$version.exe";digest=('sha256:'+('a'*64))})}}
function Invoke-RestMethod { ,$script:releases }
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
if(GetOptiShadeUpdate -Current '0.22-beta10' -ReportErrors){throw 'Background check offered stable to a running beta'}
$return=@(GetOptiShadePreviousReleases -Current '0.22-beta10' | Sort-Object {[version]$_.Version} -Descending)[0]
if($return.Version -ne '0.21.1' -or -not $return.Rollback){throw 'Explicit stable return did not offer stable'}
if(GetOptiShadeUpdate -Current '0.21.1' -InstalledChannel stable -ReportErrors){throw 'Stable same build offered again'}
if($return.ReleaseUrl -ne 'https://github.com/GamingWithGravy/OptiShade/releases/tag/v0.21.1'){throw 'Portable stable link points to wrong release'}
if(Test-Path (Join-Path $env:OPTISHADE_STORE 'beta-updates.txt')){throw 'Opt out did not persist'}
'PASS: opt in/out persisted, correct channels and URLs, beta ordering, stable return and same-version rejection'
SetOptiShadeUpdateChannel $true
$modern=Release '0.21.3-beta.2'
$modern.assets[0].name='Optishade 0.21.3-beta.2 beta.exe'
$modern.assets[0].browser_download_url='https://github.com/GamingWithGravy/OptiShade/releases/download/v0.21.3-beta.2/Optishade%200.21.3-beta.2%20beta.exe'
$script:releases=@($modern)
if((GetOptiShadeUpdate -Current '0.21.3' -InstalledChannel stable -ReportErrors).Version -ne '0.21.3-beta.2'){throw 'Stable-to-beta switch at same base version failed'}
if(GetOptiShadeUpdate -Current '0.21.3-beta.2' -InstalledChannel beta -ReportErrors){throw 'Beta same version offered again'}
SetOptiShadeUpdateChannel $false
'PASS: readable EXE name and same-base channel switch'
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

SetOptiShadeUpdateChannel $true
$modern.assets[0].name='Optishade.0.21.3-beta.2.beta.exe'
$modern.assets[0].browser_download_url='https://github.com/GamingWithGravy/OptiShade/releases/download/v0.21.3-beta.2/Optishade.0.21.3-beta.2.beta.exe'
$script:releases=@($modern)
if((GetOptiShadeUpdate -Current '0.21.2' -InstalledChannel stable -ReportErrors).Version -ne '0.21.3-beta.2'){throw 'GitHub-normalised filename not detected'}
$script:releases=@((Release '0.21.2' $false),(Release '0.21.4' $false),(Release '0.22-beta.1'))
$latest=@(GetOptiShadePreviousReleases | Sort-Object {[version]$_.Version} -Descending)
if($latest[0].Version -ne '0.21.4' -or @($latest|Where-Object Version -match 'beta').Count){throw 'Stable return is pinned or includes beta'}
'PASS: normalised asset filename and dynamically newest stable return'
# Exercise real startup wiring: a manually downloaded beta with no saved preference.
$env:OPTISHADE_STORE=Join-Path $env:TEMP ('OptiShade-fresh-beta-'+[guid]::NewGuid().ToString('N'))
InitializeOptiShadeUpdateChannel -InstalledChannel stable
if((GetOptiShadeUpdateChannel) -ne 'stable'){throw 'Stable startup opted into beta'}
InitializeOptiShadeUpdateChannel -InstalledChannel beta
if((GetOptiShadeUpdateChannel) -ne 'beta'){throw 'Fresh beta did not select beta'}
$script:releases=@((Release '0.21.3' $false),(Release '0.12.3' $false),(Release '0.99.0' $false),(Release '0.21.3-beta.6'))
$offer=GetOptiShadeUpdate -Current '0.21.3-beta.5' -ReportErrors
if($offer.Version -ne '0.21.3-beta.6' -or (GetOptiShadeUpdateLabel $offer) -ne 'Beta update available - 0.21.3 beta'){throw 'Fresh beta offer/label incorrect'}
SetOptiShadeUpdateChannel $false
InitializeOptiShadeUpdateChannel -InstalledChannel beta
if((GetOptiShadeUpdateChannel) -ne 'stable'){throw 'Explicit opt-out overwritten on restart'}
if(GetOptiShadeUpdate -Current '0.21.3-beta.5' -ReportErrors){throw 'Opted-out beta detected a stable update'}
$stable=@(GetOptiShadePreviousReleases|Sort-Object {[version]$_.Version} -Descending)[0]
if($stable.Version -ne '0.99.0' -or (GetOptiShadeUpdateLabel $stable) -ne 'Return to stable - 0.99.0'){throw 'Explicit return must select current latest stable'}
SetOptiShadeUpdateChannel $true
$script:releases=@((Release '0.99.0' $false))
if(GetOptiShadeUpdate -Current '0.21.3-beta.5' -ReportErrors){throw 'Beta-only checks fell back to stable when no beta was available'}
$script:releases=@((Release '0.21.3-beta.5'),(Release '0.99.0' $false))
if(GetOptiShadeUpdate -Current '0.21.3-beta.5' -ReportErrors){throw 'Current beta should have no newer beta update'}
'PASS: fresh beta startup, beta-only update labels, persisted opt-out, explicit stable return, no stable fallback'

# Unnumbered beta versions use a single channel label in the desktop filename.
if((GetOptiShadeManagerName '0.21.5-beta' beta) -cne 'Optishade 0.21.5 beta.exe'){throw 'Unnumbered beta filename mismatch'}
if((GetOptiShadeManagerName '0.21.3-beta.5' beta) -cne 'Optishade 0.21.3 beta.exe'){throw 'Legacy beta desktop name was not simplified'}
if(-not(TestOptiShadeChannelChange 'P0.21.4' 'P0.21.5-beta') -or -not(TestOptiShadeChannelChange 'P0.21.5-beta' 'P0.21.4')){throw 'Unnumbered beta channel change not recognized'}
SetOptiShadeUpdateChannel $true
$plain=Release '0.21.5-beta'
$plain.assets[0].name='Optishade.0.21.5.beta.exe'
$plain.assets[0].browser_download_url='https://github.com/GamingWithGravy/OptiShade/releases/download/v0.21.5-beta/Optishade.0.21.5.beta.exe'
$script:releases=@((Release '0.99.0' $false),$plain)
if((GetOptiShadeUpdate -Current '0.21.4' -InstalledChannel stable -ReportErrors).Version -cne '0.21.5-beta'){throw 'Stable opt-in did not find unnumbered beta'}
if((GetOptiShadeUpdate -Current '0.21.3-beta.5' -InstalledChannel beta -ReportErrors).Version -cne '0.21.5-beta'){throw 'Legacy beta did not find unnumbered beta'}
if(GetOptiShadeUpdate -Current '0.21.5-beta' -InstalledChannel beta -ReportErrors){throw 'Unnumbered beta offered itself or stable'}
SetOptiShadeUpdateChannel $false
if(GetOptiShadeUpdate -Current '0.21.5-beta' -InstalledChannel beta -ReportErrors){throw 'Opted-out unnumbered beta offered stable automatically'}
'PASS: unnumbered beta discovery, desktop name, both channel switches and no stable fallback'