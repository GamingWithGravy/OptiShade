$ErrorActionPreference='Stop'
$fixtures=Join-Path $PSScriptRoot 'fixtures/published-updaters'
$manifest=Get-Content -LiteralPath (Join-Path $fixtures 'manifest.json') -Raw | ConvertFrom-Json
$previousStore=$env:OPTISHADE_STORE
$testStore=Join-Path $env:TEMP ('OptiShade-published-updaters-'+[guid]::NewGuid().ToString('N'))
$results=[Collections.Generic.List[object]]::new()

function MakeRelease([string]$Version,[bool]$Beta,[string]$Exe) {
    [pscustomobject]@{draft=$false;prerelease=$Beta;tag_name='v'+$Version;body='Compatibility fixture';assets=@(
        [pscustomobject]@{name=$Exe;browser_download_url="https://github.com/GamingWithGravy/OptiShade/releases/download/v$Version/$([uri]::EscapeDataString($Exe))";digest=('sha256:'+('a'*64))},
        [pscustomobject]@{name="OptiShade-Portable-$Version.zip";browser_download_url="https://github.com/GamingWithGravy/OptiShade/releases/download/v$Version/OptiShade-Portable-$Version.zip";digest=('sha256:'+('b'*64))}
    )}
}
function NormalizedHash([string]$Path) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText($Path).Replace("`r`n","`n")))).Replace('-','') }
    finally { $sha.Dispose() }
}
$layouts=@(
    [pscustomobject]@{Name='legacy-numbered';Stable=(MakeRelease '0.21.4' $false 'OptiShade_Version_0.21.4.exe');Beta=(MakeRelease '0.21.5-beta.1' $true 'OptiShade_Version_0.21.5-beta.1.exe')},
    [pscustomobject]@{Name='readable-numbered';Stable=(MakeRelease '0.21.4' $false 'Optishade.0.21.4.stable.exe');Beta=(MakeRelease '0.21.5-beta.1' $true 'Optishade.0.21.5-beta.1.beta.exe')},
    [pscustomobject]@{Name='readable-bare';Stable=(MakeRelease '0.21.4' $false 'Optishade.0.21.4.stable.exe');Beta=(MakeRelease '0.21.5-beta' $true 'Optishade.0.21.5.beta.exe')},
    [pscustomobject]@{Name='legacy-bare';Stable=(MakeRelease '0.21.4' $false 'OptiShade_Version_0.21.4.exe');Beta=(MakeRelease '0.21.5-beta' $true 'OptiShade_Version_0.21.5-beta.exe')}
)
try {
    foreach($client in $manifest) {
        $fixture=Join-Path $fixtures $client.Fixture
        if((NormalizedHash $fixture) -cne $client.FixtureNormalizedSHA256) { throw "Published fixture changed: $($client.Version)" }
        foreach($layout in $layouts) {
            foreach($release in @($layout.Stable,$layout.Beta)) {
                if(@($release.assets | Where-Object name -Like '*.exe').Count -ne 1 -or
                   @($release.assets | Where-Object name -Like '*.zip').Count -ne 1) { throw 'Fixture must use one EXE and one portable ZIP.' }
            }
            foreach($selected in @('stable','beta')) {
                if($client.Version -eq '0.20.12' -and $selected -eq 'beta') { continue }
                # Functions are exact published bodies in an isolated scope. Do not
                # fix old behavior here: release compatibility depends on that code.
                $row=& {
                    param($Client,$Fixture,$Layout,$Selected)
                    . $Fixture
                    $env:OPTISHADE_STORE=Join-Path $testStore ([guid]::NewGuid().ToString('N'))
                    if($Client.Version -ne '0.20.12') { SetOptiShadeUpdateChannel ($Selected -eq 'beta') }
                    $feed=@($Layout.Beta,$Layout.Stable)
                    $latest=$Layout.Stable
                    function Invoke-RestMethod {
                        param([string]$Uri,$Headers,[int]$TimeoutSec)
                        if($Uri -eq 'https://api.github.com/repos/GamingWithGravy/OptiShade/releases/latest') { return $latest }
                        if($Uri -ne 'https://api.github.com/repos/GamingWithGravy/OptiShade/releases?per_page=100') { throw 'Unexpected request; networking is disabled in this fixture.' }
                        # Windows PowerShell Invoke-RestMethod emits a JSON array
                        # as one pipeline object, not one object per release.
                        Write-Output -NoEnumerate $feed
                    }
                    $offer=$null; $errorText=''; $workerName=''
                    try {
                        $offer=GetOptiShadeUpdate -Current $Client.Version -ReportErrors
                        if($offer -and (Get-Command GetOptiShadeManagerName -ErrorAction SilentlyContinue)) {
                            $workerName=GetOptiShadeManagerName $offer.Version $Selected
                        }
                    } catch { $errorText=$_.Exception.Message }
                    [pscustomobject]@{Client=$Client.Version;Selected=$Selected;Layout=$Layout.Name;Offer=[string]$offer.Version;Error=$errorText;WorkerName=$workerName}
                } $client $fixture $layout $selected
                $expected='';$expectError=$false
                if($client.Version -eq '0.20.12') {
                    if($layout.Name -like 'legacy-*') { $expected='0.21.4' }
                } elseif($client.Version -eq '0.21.2') {
                    # Published bug: the array-valued draft projection is true,
                    # so this client skips the entire multi-release response.
                    $expected=''
                } elseif($selected -eq 'stable') {
                    $expected='0.21.4'
                } elseif($layout.Name -like '*-bare') {
                    $expectError=$true
                } else {
                    $expected='0.21.5-beta.1'
                }
                if($row.Offer -cne $expected -or ([bool]$row.Error -ne $expectError)) {
                    throw ('Unexpected published updater behavior: '+($row | ConvertTo-Json -Compress))
                }
                if($expected -eq '0.21.5-beta.1' -and $row.WorkerName -cne 'Optishade 0.21.5-beta.1 beta.exe') { throw 'Old worker cannot create the expected destination filename.' }
                $results.Add($row)
            }
        }
    }
    if($results.Count -ne 36) { throw 'Incomplete published-client matrix.' }
    Write-Output 'PASS: 36 exact published-reader cases; legacy single-EXE naming and numbered internal beta identity accepted by 0.20.12 stable and selected-channel 0.21.3/beta.3/beta.4 readers.'
    Write-Output 'CONFIRMED LEGACY LIMIT: 0.21.2 skips a multi-release API array; changing new release names cannot repair that executable.'
    Write-Output 'CONFIRMED LEGACY LIMIT: old beta with stable selected/no beta marker offers stable; only the updated client fixes automatic channel isolation.'
    & {
        . (Join-Path (Split-Path $PSScriptRoot -Parent) 'installer/updates.ps1')
        $env:OPTISHADE_STORE=Join-Path $testStore 'maintained-client'
        function Invoke-RestMethod {
            param([string]$Uri,$Headers,[int]$TimeoutSec)
            if($Uri -ne 'https://api.github.com/repos/GamingWithGravy/OptiShade/releases?per_page=100') { throw 'Unexpected request; networking is disabled.' }
            Write-Output -NoEnumerate $feed
        }
        if((GetOptiShadeManagerName '0.21.5-beta.1' beta) -cne 'Optishade 0.21.5 beta.exe') { throw 'Internal beta revision leaked into the maintained Desktop filename.' }
        if((GetOptiShadeDisplayVersion '0.21.5-beta.1') -cne '0.21.5 beta') { throw 'Internal beta revision leaked into display version.' }
        SetOptiShadeUpdateChannel $true
        foreach($assetName in (GetOptiShadeReleaseAssetNames '0.21.5-beta.1' beta)) {
            $feed=@((MakeRelease '0.99.0' $false 'OptiShade_Version_0.99.0.exe'),
                (MakeRelease '0.21.5-beta.1' $true $assetName))
            $offer=GetOptiShadeUpdate -Current '0.21.3-beta.4' -InstalledChannel beta -ReportErrors
            if($offer.Version -cne '0.21.5-beta.1' -or $offer.Channel -cne 'beta') { throw "Maintained beta reader rejected $assetName or selected stable." }
            if((GetOptiShadeUpdateLabel $offer) -cne 'Beta update available - 0.21.5 beta') { throw 'Beta offer text leaked the internal revision.' }
            $request=[pscustomobject]@{Version=$offer.Version;Url=$offer.Url;SHA256=$offer.SHA256;InstalledChannel='beta';Channel='beta';ExplicitReturnToStable=$false;Rollback=$false}
            if((AssertOptiShadeUpdateRequest $request $env:OPTISHADE_STORE) -cne 'beta') { throw 'Worker did not accept the selected canonical beta asset.' }
            if(GetOptiShadeUpdate -Current '0.21.5-beta.1' -InstalledChannel beta -ReportErrors) { throw 'Current canonical beta repeats its own update or offers stable.' }
        }
        $feed=@((MakeRelease '0.21.4' $false 'OptiShade_Version_0.21.4.exe'),
            (MakeRelease '0.21.5-beta.1' $true 'OptiShade_Version_0.21.5-beta.1.exe'))
        if((GetOptiShadeUpdate -Current '0.21.4' -InstalledChannel stable -ReportErrors).Version -cne '0.21.5-beta.1') { throw 'Stable opt-in did not select the canonical beta release.' }
        SetOptiShadeUpdateChannel $false
        if(GetOptiShadeUpdate -Current '0.21.5-beta.1' -InstalledChannel beta -ReportErrors) { throw 'Maintained opted-out beta must not offer stable automatically.' }
        if((GetOptiShadeUpdate -Current '0.21.3' -InstalledChannel stable -ReportErrors).Version -cne '0.21.4') { throw 'Stable reader did not select the legacy-compatible stable asset.' }
        if(GetOptiShadeUpdate -Current '0.21.4' -InstalledChannel stable -ReportErrors) { throw 'Current stable repeats its update or offers beta without opt-in.' }
        $stable=@(GetOptiShadePreviousReleases -Current '0.21.5-beta.1' | Sort-Object {[version]$_.Version} -Descending)[0]
        if($stable.Version -cne '0.21.4' -or !$stable.Rollback) { throw 'Explicit stable return did not select the latest stable in the feed.' }
        Write-Output 'PASS: maintained reader/worker accepts every supported asset spelling, preserves canonical beta.1 identity without repeated offers, shows clean names and isolates beta/stable.'
    }
    Write-Output 'PASS: no network, EXE download/launch, live installation change or duplicate release assets used.'
} finally {
    if($null -eq $previousStore) { Remove-Item Env:OPTISHADE_STORE -ErrorAction SilentlyContinue }
    else { $env:OPTISHADE_STORE=$previousStore }
}
