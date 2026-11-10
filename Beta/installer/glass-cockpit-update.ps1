$script:glassCockpitUpdateApi = 'https://api.github.com/repos/IFreemz/msfs2024-glass-cockpit-dlss-fix/releases?per_page=20'
$script:glassCockpitUpdateAsset = 'glass-cockpit-dlss-fix.addon64'
$script:glassCockpitUpdateRepo = '/IFreemz/msfs2024-glass-cockpit-dlss-fix'

# A manual refresh bypasses the cache. Background checks stay bounded.
function TestGlassCockpitCheckDue($LastCheckUtc, [bool]$HasRelease, [bool]$Force=$false, [DateTime]$NowUtc=[DateTime]::UtcNow) {
    if ($Force -or -not $LastCheckUtc) { return $true }
    $age = $NowUtc - [DateTime]$LastCheckUtc
    if ($age.TotalSeconds -lt 0) { return $true }
    $minutes = if ($HasRelease) { 5 } else { 2 }
    return $age.TotalMinutes -ge $minutes
}

function ConvertFromGlassCockpitReleaseList($Releases) {
    $candidates = New-Object 'System.Collections.Generic.List[object]'
    foreach ($release in @($Releases | Select-Object -First 20)) {
        if (-not $release -or [bool]$release.draft) { continue }
        $tag = [string]$release.tag_name
        if ($tag -notmatch '^v?(\d+\.\d+\.\d+)$') { continue }
        $versionText = $Matches[1]
        $version = $null
        try { $version = [version]$versionText } catch { continue }

        $assets = @($release.assets | Where-Object { [string]$_.name -ceq $script:glassCockpitUpdateAsset })
        if ($assets.Count -ne 1) { continue }
        $assetUri = $null
        try { $assetUri = [uri][string]$assets[0].browser_download_url } catch { continue }
        $expectedPath = $script:glassCockpitUpdateRepo + '/releases/download/' + $tag + '/' + $script:glassCockpitUpdateAsset
        if ($assetUri.Scheme -cne 'https' -or $assetUri.Host -cne 'github.com' -or $assetUri.AbsolutePath -cne $expectedPath) { continue }

        $digest = [string]$assets[0].digest
        if ($digest -notmatch '^sha256:[a-fA-F0-9]{64}$') { $digest = '' }
        $tagSegment = [uri]::EscapeDataString($tag)
        $candidates.Add([pscustomobject]@{
            Version = $version
            VersionText = $versionText
            Tag = $tag
            AssetUrl = $assetUri.AbsoluteUri
            ReleaseUrl = 'https://github.com' + $script:glassCockpitUpdateRepo + '/releases/tag/' + $tagSegment
            SHA256 = if ($digest) { $digest.Substring(7).ToLowerInvariant() } else { '' }
            Size = [long]$assets[0].size
            PublishedAt = [string]$release.published_at
        })
    }
    return $candidates | Sort-Object Version -Descending | Select-Object -First 1
}

function GetGlassCockpitLatestRelease([scriptblock]$Request, [switch]$ReportErrors) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    try {
        if ($Request) {
            $releases = & $Request $script:glassCockpitUpdateApi
        } else {
            $releases = Invoke-RestMethod -Uri $script:glassCockpitUpdateApi -Headers @{
                'User-Agent' = 'OptiShade-GlassCockpit-update-check'
                'Accept' = 'application/vnd.github+json'
            } -TimeoutSec 8 -ErrorAction Stop
        }
        return ConvertFromGlassCockpitReleaseList $releases
    } catch {
        if ($ReportErrors) { throw 'Could not check Glass Cockpit updates on GitHub.' }
        return $null
    }
}

function TestGlassCockpitOfficialLegacyCopy([string]$Path) {
    # Exact official releases distributed by earlier OptiShade installers or
    # installed by users before the manager could reconcile the receipt. A
    # version string or filename alone is not sufficient evidence to adopt it.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
    $hash=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    return $hash -iin @(
        'db7adb7e964f7034718608677be97259b261aa76c1f1e89386b89d0915ed5466', # v0.7.5, official GitHub asset digest
        '84f0c261183309f153ae837e6a721d23e574255618a2523b41d0ba846801a65d', # v0.8.3
        '2c27d7b6a956d939fb29af3b55ccf3f1714cf06ff9e32a80498343cd4aedd2a2', # v1.0.0
        'a637456d2a93780ccfea73043f428e4f2a0f5f009423a3ca22b694b198565517', # v1.0.1
        '9474b66e2e22bc005233463574fc9ba9c107d4bfa8364e5c3478588f0e8f2036', # v1.0.2
        '524cbd27601bc8e1904e76ecf7f0702cdef8dbc81f089a8c88adf622a66f16e3', # v1.0.3
        '1adf8771fb050572d01d0628d9e7a75a60f07bb890ad98d770fd7cd0db4eafaa'  # v1.0.4, official GitHub asset digest
    )
}

function TestGlassCockpitLegacyOwnership($Records,[string]$Path) {
    $entries=@($Records)
    if ($entries.Count -gt 1) { return $false }
    if (-not (TestGlassCockpitOfficialLegacyCopy $Path)) { return $false }
    if ($entries.Count -eq 1) {
        # Old installers recorded this addon as core or without a component tag.
        # A manager receipt can retain an earlier official hash after the user's
        # official updater replaced the file (for example 0.8.3 -> 1.0.0).
        # Reconcile that stale receipt only when the current bytes exactly match
        # a pinned official release; never override a conflicting component.
        if ($entries[0].Component -and $entries[0].Component -notin @('Core','Cockpit')) { return $false }
    }
    return $true
}
function GetGlassCockpitUpdateInfo($Manifest, $Release, [scriptblock]$VersionReader) {
    $result = [pscustomobject]@{
        Installed = $false
        Managed = $false
        CanAdopt = $false
        Available = $false
        CanDownload = [bool]($Release -and [string]$Release.SHA256 -match '^[a-fA-F0-9]{64}$')
        InstalledVersion = ''
        LatestVersion = if ($Release) { 'v' + [string]$Release.VersionText } else { '' }
        ReleaseUrl = if ($Release) { [string]$Release.ReleaseUrl } else { '' }
        State = 'Not installed'
    }
    if (-not $Manifest -or -not $Manifest.Game) { return $result }
    $owned = @($Manifest.Files | Where-Object {
        $_.Component -eq 'Cockpit' -and ([string]$_.Path).Replace('\','/') -ieq $script:glassCockpitUpdateAsset
    })
    # An update click can adopt an exact known official legacy copy. Unknown or
    # conflicting records still require review; notification alone never adopts it.
    $result.Managed = $owned.Count -eq 1

    $path = Join-Path ([string]$Manifest.Game) $script:glassCockpitUpdateAsset
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $result.State = 'Installed file missing'
        return $result
    }
    $result.Installed = $true
    $records = @($Manifest.Files | Where-Object { ([string]$_.Path).Replace('\','/') -ieq $script:glassCockpitUpdateAsset })
    $result.CanAdopt = TestGlassCockpitLegacyOwnership $records $path
    $result.CanDownload = $result.CanDownload -and ($result.Managed -or $result.CanAdopt)
    if ($VersionReader) { $versionText = [string](& $VersionReader $path) }
    else {
        $fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($path)
        $versionText = if ($fileVersion.ProductVersion) { [string]$fileVersion.ProductVersion } else { [string]$fileVersion.FileVersion }
    }
    if ($versionText -notmatch '(?<!\d)(\d+\.\d+\.\d+)(?:\.\d+)?(?!\d)') {
        $result.State = 'Version unavailable'
        return $result
    }
    $installedVersion = $null
    try { $installedVersion = [version]$Matches[1] } catch { $result.State = 'Version unavailable'; return $result }
    $result.InstalledVersion = 'v' + $installedVersion.ToString(3)
    if (-not $Release) {
        $result.State = 'Update check pending'
        return $result
    }
    if ($installedVersion -lt [version]$Release.Version) {
        $result.Available = $true
        $result.State = 'Update available'
    } else {
        $result.State = 'Current'
    }
    return $result
}

function AssertGlassCockpitReleaseAsset($Release) {
    if (-not $Release -or [string]$Release.Tag -notmatch '^v?(\d+\.\d+\.\d+)$') {
        throw 'The developer release version is invalid.'
    }
    $versionText = $Matches[1]
    if ([version]$versionText -ne [version]$Release.Version -or [string]$Release.VersionText -ne $versionText) {
        throw 'The developer release version did not match its tag.'
    }
    if ([string]$Release.SHA256 -notmatch '^[a-fA-F0-9]{64}$') {
        throw 'This release does not include a verified SHA-256 digest. Open the official release page to update manually.'
    }
    $assetUri = $null
    try { $assetUri = [uri][string]$Release.AssetUrl } catch { }
    $expectedPath = $script:glassCockpitUpdateRepo + '/releases/download/' + [string]$Release.Tag + '/' + $script:glassCockpitUpdateAsset
    if (-not $assetUri -or $assetUri.Scheme -cne 'https' -or $assetUri.Host -cne 'github.com' -or $assetUri.AbsolutePath -cne $expectedPath) {
        throw 'The developer release asset URL did not match the official GitHub release.'
    }
    $maximumBytes = 50MB
    $declaredSize = 0L
    if ($Release.PSObject.Properties['Size']) { $declaredSize = [long]$Release.Size }
    if ($declaredSize -lt 0 -or $declaredSize -gt $maximumBytes) {
        throw 'The developer release asset has an invalid or oversized download.'
    }
    return [pscustomobject]@{ Uri = $assetUri; VersionText = $versionText; SHA256 = ([string]$Release.SHA256).ToLowerInvariant(); Size = $declaredSize; MaximumBytes = $maximumBytes }
}

function GetGlassCockpitBinaryVersion([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'The downloaded add-on file is missing.' }
    $file = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    $versionText = if ($file.ProductVersion) { [string]$file.ProductVersion } else { [string]$file.FileVersion }
    if ($versionText -notmatch '(?<!\d)(\d+\.\d+\.\d+)(?:\.\d+)?(?!\d)') { throw 'The downloaded add-on does not contain a readable version.' }
    return $Matches[1]
}

function SaveGlassCockpitReleaseAsset($Release, [string]$Destination, [scriptblock]$Progress) {
    $identity = AssertGlassCockpitReleaseAsset $Release
    [void](Add-Type -AssemblyName System.Net.Http)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds(45)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('OptiShade-GlassCockpit-updater/1.0')
    $response = $null
    $inputStream = $null
    $outputStream = $null
    try {
        $response = $client.GetAsync($identity.Uri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $null = $response.EnsureSuccessStatusCode()
        $finalUri = $response.RequestMessage.RequestUri
        if ($finalUri.Scheme -cne 'https' -or $finalUri.Host -notin @('github.com','release-assets.githubusercontent.com','objects.githubusercontent.com')) {
            throw 'The official release download redirected to an unexpected host.'
        }
        $contentLength = if ($response.Content.Headers.ContentLength) { [long]$response.Content.Headers.ContentLength } else { 0L }
        if ($contentLength -gt $identity.MaximumBytes -or ($identity.Size -gt 0 -and $contentLength -gt 0 -and $contentLength -ne $identity.Size)) {
            throw 'The developer release asset size did not match its verified metadata.'
        }
        $parent = Split-Path -Parent $Destination
        if ($parent) { [void][IO.Directory]::CreateDirectory($parent) }
        $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $outputStream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buffer = New-Object byte[] 65536
        $total = 0L
        $lastProgress = 0L
        while (($read = $inputStream.ReadAsync($buffer, 0, $buffer.Length).GetAwaiter().GetResult()) -gt 0) {
            $total += $read
            if ($total -gt $identity.MaximumBytes -or ($identity.Size -gt 0 -and $total -gt $identity.Size)) {
                throw 'The developer release asset exceeded its verified size limit.'
            }
            $outputStream.Write($buffer, 0, $read)
            if ($Progress -and ($total - $lastProgress -ge 262144 -or ($contentLength -gt 0 -and $total -eq $contentLength))) {
                & $Progress ('Downloading Glass Cockpit fix ' + $identity.VersionText) $total $contentLength
                $lastProgress = $total
            }
        }
        $outputStream.Flush()
        $outputStream.Dispose()
        $outputStream = $null
        if ($total -le 0 -or ($identity.Size -gt 0 -and $total -ne $identity.Size) -or ($contentLength -gt 0 -and $total -ne $contentLength)) {
            throw 'The developer release asset download was incomplete.'
        }
        $actualHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -cne $identity.SHA256) { throw 'Glass Cockpit download verification failed. The installed file was not changed.' }
        $binaryVersion = GetGlassCockpitBinaryVersion $Destination
        if ([version]$binaryVersion -ne [version]$identity.VersionText) { throw 'The downloaded add-on version did not match the official release tag.' }
        return [pscustomobject]@{ Path = $Destination; Version = $binaryVersion; SHA256 = $actualHash; Bytes = $total }
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Dispose() }
        $client.Dispose()
    }
}
