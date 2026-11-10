$ErrorActionPreference = 'Stop'
$env:OPTISHADE_ANTICHEAT_SESSION_ACCEPTED='1'
$root = Split-Path (Split-Path $PSScriptRoot)
. (Join-Path $root 'Beta/installer/ownership.ps1')
. (Join-Path $root 'Beta/installer/components.ps1')
. (Join-Path $root 'Beta/installer/glass-cockpit-update.ps1')

function Assert-Equal($Expected,$Actual,[string]$Message) {
    if ($Expected -ne $Actual) { throw "$Message (expected '$Expected', got '$Actual')" }
}

function New-Release([string]$Tag,[string]$AssetUrl,[bool]$Draft=$false) {
    [pscustomobject]@{
        tag_name = $Tag
        draft = $Draft
        published_at = '2026-10-17T10:00:00Z'
        assets = @([pscustomobject]@{
            name = 'glass-cockpit-dlss-fix.addon64'
            browser_download_url = $AssetUrl
            digest = 'sha256:a637456d2a93780ccfea73043f428e4f2a0f5f009423a3ca22b694b198565517'
        })
    }
}

$older = New-Release 'v1.0.0' 'https://github.com/IFreemz/msfs2024-glass-cockpit-dlss-fix/releases/download/v1.0.0/glass-cockpit-dlss-fix.addon64'
$newer = New-Release 'v1.0.10' 'https://github.com/IFreemz/msfs2024-glass-cockpit-dlss-fix/releases/download/v1.0.10/glass-cockpit-dlss-fix.addon64'
$draft = New-Release 'v9.0.0' 'https://github.com/IFreemz/msfs2024-glass-cockpit-dlss-fix/releases/download/v9.0.0/glass-cockpit-dlss-fix.addon64' $true
$latest = ConvertFromGlassCockpitReleaseList @($older,$newer,$draft)
Assert-Equal '1.0.10' $latest.VersionText 'Release versions are ordered numerically and drafts are ignored'
Assert-Equal 'https://github.com/IFreemz/msfs2024-glass-cockpit-dlss-fix/releases/tag/v1.0.10' $latest.ReleaseUrl 'Release URL is derived from the validated repository/tag'
    Assert-Equal '1.0.10' (AssertGlassCockpitReleaseAsset $latest).VersionText 'A download requires a matching release tag and verified digest'

$future = ConvertFromGlassCockpitReleaseList @((New-Release 'v99.12.100' 'https://github.com/IFreemz/msfs2024-glass-cockpit-dlss-fix/releases/download/v99.12.100/glass-cockpit-dlss-fix.addon64'))
Assert-Equal '99.12.100' (AssertGlassCockpitReleaseAsset $future).VersionText 'Verified official future release numbers have no hardcoded version ceiling'

$bad = New-Release 'v0.8.11' 'https://example.com/attacker.addon64'
$safe = ConvertFromGlassCockpitReleaseList @($bad)
Assert-Equal $null $safe 'An asset URL outside the official GitHub release path is rejected'

$unreachable = GetGlassCockpitLatestRelease -Request { param($uri) throw 'offline fixture' }
Assert-Equal $null $unreachable 'Network failure is non-fatal for the manager'

$cockpitFolder = Join-Path $root 'Beta/installer/GlassCockpit'
$manifest = [pscustomobject]@{
    Game = $cockpitFolder
    Files = @([pscustomobject]@{Path='glass-cockpit-dlss-fix.addon64';Component='Cockpit'})
}
$installed = GetGlassCockpitUpdateInfo $manifest $latest
Assert-Equal $true $installed.Installed 'The owned add-on file is recognized'
Assert-Equal $true $installed.Available 'An older installed version is reported as update available'
$bundledVersion=GetGlassCockpitBinaryVersion (Join-Path $cockpitFolder 'glass-cockpit-dlss-fix.addon64')
Assert-Equal ('v'+$bundledVersion) $installed.InstalledVersion 'Installed version comes from the official binary version resource'

$sameVersion = ConvertFromGlassCockpitReleaseList @((New-Release ('v'+$bundledVersion) ('https://github.com/IFreemz/msfs2024-glass-cockpit-dlss-fix/releases/download/v'+$bundledVersion+'/glass-cockpit-dlss-fix.addon64')))
$current = GetGlassCockpitUpdateInfo $manifest $sameVersion
Assert-Equal $false $current.Available 'A matching release version does not show an update notice'

$notOwned = [pscustomobject]@{Game=$cockpitFolder;Files=@()}
$absent = GetGlassCockpitUpdateInfo $notOwned $latest
Assert-Equal $true $absent.Installed 'An existing legacy or manual add-on is detected'
Assert-Equal $true $absent.Available 'An untracked older add-on receives a release notification'
Assert-Equal $false $absent.Managed 'Detection does not invent file ownership'
Assert-Equal $true $absent.CanAdopt 'The exact official legacy bytes can be adopted by an explicit update action'
Assert-Equal $true $absent.CanDownload 'A verified official legacy copy can use the verified updater'

$provenance=Get-Content (Join-Path $cockpitFolder 'PROVENANCE.json') -Raw|ConvertFrom-Json
$bundledHash=(Get-FileHash -LiteralPath (Join-Path $cockpitFolder 'glass-cockpit-dlss-fix.addon64') -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-Equal 'v1.0.3' $provenance.Version 'The bundled official addon is the current developer release'
Assert-Equal $provenance.SHA256 $bundledHash 'The bundled official add-on matches its provenance pin'

$official100=Join-Path $PSScriptRoot 'data/glass-cockpit-dlss-fix-v1.0.0.addon64'
Assert-Equal '2c27d7b6a956d939fb29af3b55ccf3f1714cf06ff9e32a80498343cd4aedd2a2' (HashFile $official100) 'The v1.0.0 legacy fixture matches the official GitHub release digest'
Assert-Equal $true (TestGlassCockpitOfficialLegacyCopy $official100) 'The exact official v1.0.0 bytes are recognized as a safe legacy copy'
$staleOfficialReceipt=@{Path='glass-cockpit-dlss-fix.addon64';Hash='84f0c261183309f153ae837e6a721d23e574255618a2523b41d0ba846801a65d';Component=''}
Assert-Equal $true (TestGlassCockpitLegacyOwnership @($staleOfficialReceipt) $official100) 'A stale v0.8.3 receipt can reconcile an exact official v1.0.0 replacement'
$wrongOwner=$staleOfficialReceipt.Clone();$wrongOwner.Component='Neural'
Assert-Equal $false (TestGlassCockpitLegacyOwnership @($wrongOwner) $official100) 'Official bytes do not override a conflicting component owner'

$txRoot=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-glass-update-fixture-'+[guid]::NewGuid().ToString('N'))
$env:OPTISHADE_STORE=Join-Path $txRoot 'owner-store'
$txGame=Join-Path $txRoot 'game';$txState=Join-Path $txRoot 'state';[void][IO.Directory]::CreateDirectory($txGame);[void][IO.Directory]::CreateDirectory($txState)
$txManifest=Join-Path $txState 'manifest.json';$addon='glass-cockpit-dlss-fix.addon64'
$oldBytes='fixture old official add-on';$newBytes='fixture verified developer update';$originalBytes='third-party original file'
[IO.File]::WriteAllText((Join-Path $txGame 'FlightSimulator2024.exe'),'fixture game')
[IO.File]::WriteAllText((Join-Path $txGame $addon),$oldBytes)
[IO.File]::WriteAllText((Join-Path $txState 'original'),$originalBytes)
$txOldHash=HashFile (Join-Path $txGame $addon);$txOriginalHash=HashFile (Join-Path $txState 'original')
$txRecord=@{Path=$addon;SourcePath=$addon;Hash=$txOldHash;PreviousHash=$txOriginalHash;Backup='original';Mutable=$false;Retained=$true;Component='Cockpit'}
WriteState @{Status='Installed';Game=$txGame;Files=@($txRecord);Components=@('Cockpit')} $txManifest
$newDigest=[Security.Cryptography.SHA256]::Create();try{$newHash=[BitConverter]::ToString($newDigest.ComputeHash([Text.Encoding]::UTF8.GetBytes($newBytes))).Replace('-','').ToLowerInvariant()}finally{$newDigest.Dispose()}
$txRelease=[pscustomobject]@{Tag='v0.8.3';Version=[version]'0.8.3';VersionText='0.8.3';AssetUrl='https://github.com/IFreemz/msfs2024-glass-cockpit-dlss-fix/releases/download/v0.8.3/glass-cockpit-dlss-fix.addon64';ReleaseUrl='https://github.com/IFreemz/msfs2024-glass-cockpit-dlss-fix/releases/tag/v0.8.3';SHA256=$newHash;Size=[long][Text.Encoding]::UTF8.GetByteCount($newBytes)}
$download={param($release,$destination,$progress)[IO.File]::WriteAllText($destination,$newBytes)}.GetNewClosure()
$versionReader={param($file) if([IO.File]::ReadAllText($file) -eq $newBytes){'0.8.3'}else{'0.8.0'}}.GetNewClosure()
try{
    $updated=UpdateGlassCockpitAddon $txManifest $txRelease {} $download $versionReader
    $txAfter=ReadOptiShadeState $txManifest;$newRecord=@($txAfter.Files|Where-Object {$_.Component -eq 'Cockpit' -and $_.Path -eq $addon})
    Assert-Equal '0.8.3' $updated.Version 'The manager update installs the release after digest and version checks'
    Assert-Equal $newHash (HashFile (Join-Path $txGame $addon)) 'The installed component bytes match the verified release'
    Assert-Equal $newHash $newRecord[0].Hash 'The ownership manifest tracks the updated official asset'
    Assert-Equal $txOriginalHash $newRecord[0].PreviousHash 'Updating retains the original pre-OptiShade backup'
    Assert-Equal $originalBytes ([IO.File]::ReadAllText((Join-Path $txState 'original'))) 'The original file backup remains unchanged'
    $badRelease=$txRelease.PSObject.Copy();$badRelease.Tag='v0.8.4';$badRelease.Version=[version]'0.8.4';$badRelease.VersionText='0.8.4';$badRelease.AssetUrl='https://github.com/IFreemz/msfs2024-glass-cockpit-dlss-fix/releases/download/v0.8.4/glass-cockpit-dlss-fix.addon64';$badRelease.ReleaseUrl='https://github.com/IFreemz/msfs2024-glass-cockpit-dlss-fix/releases/tag/v0.8.4';$badRelease.SHA256=('0'*64)
    $blocked=$false;try{UpdateGlassCockpitAddon $txManifest $badRelease {} $download $versionReader|Out-Null}catch{$blocked=$true}
    Assert-Equal $true $blocked 'A digest mismatch is refused before changing the installed file'
    Assert-Equal $newHash (HashFile (Join-Path $txGame $addon)) 'A failed verification leaves the installed add-on unchanged'

    # Legacy migration uses real pinned official bytes and the real transaction.
    Copy-Item -LiteralPath (Join-Path $cockpitFolder $addon) -Destination (Join-Path $txGame $addon) -Force
    WriteState @{Status='Installed';Game=$txGame;Files=@();Components=@('Effects')} $txManifest
    $beforeManifest=[IO.File]::ReadAllText($txManifest)
    $blocked=$false;try{UpdateGlassCockpitAddon $txManifest $badRelease {} $download $versionReader|Out-Null}catch{$blocked=$true}
    Assert-Equal $true $blocked 'Bad download is refused before legacy adoption'
    Assert-Equal $beforeManifest ([IO.File]::ReadAllText($txManifest)) 'Failed legacy download leaves ownership untouched'
    Assert-Equal $bundledHash (HashFile (Join-Path $txGame $addon)) 'Failed legacy download preserves official older bytes'
    $updated=UpdateGlassCockpitAddon $txManifest $txRelease {} $download $versionReader
    $adopted=ReadOptiShadeState $txManifest;$record=@($adopted.Files|Where-Object {$_.Path -eq $addon})
    Assert-Equal 1 $record.Count 'Legacy update creates exactly one ownership record'
    Assert-Equal $newHash $record[0].Hash 'Adopted ownership identifies the verified replacement'
    Assert-Equal $bundledHash $record[0].PreviousHash 'Legacy original identity is preserved'
    Assert-Equal $bundledHash (HashFile (OwnedPath $txState $record[0].Backup)) 'Original official addon has a verified recovery copy'
    Assert-Equal $true ('Cockpit' -in @(GetOptiShadeAddonSelection $adopted)) 'Updated cockpit appears installed in Components'
    Assert-Equal $true ('Effects' -in @(GetOptiShadeAddonSelection $adopted)) 'Migration preserves other selected components'

    # A user may update the official add-on outside OptiShade, leaving an old
    # official hash and no component tag in the saved receipt. Verify that the
    # update manager can reconcile that exact v1.0.0 -> v1.0.3 transition.
    $officialAsset=Join-Path $cockpitFolder $addon
    $officialRelease=ConvertFromGlassCockpitReleaseList @([pscustomobject]@{
        tag_name='v1.0.3';draft=$false;published_at='2026-10-20T20:56:55Z'
        assets=@([pscustomobject]@{
            name=$addon
            browser_download_url='https://github.com/IFreemz/msfs2024-glass-cockpit-dlss-fix/releases/download/v1.0.3/glass-cockpit-dlss-fix.addon64'
            digest='sha256:524cbd27601bc8e1904e76ecf7f0702cdef8dbc81f089a8c88adf622a66f16e3'
            size=(Get-Item -LiteralPath $officialAsset).Length
        })
    })
    Copy-Item -LiteralPath $official100 -Destination (Join-Path $txGame $addon) -Force
    $officialManifest=ManifestPath $env:OPTISHADE_STORE $txGame
    $officialStateFolder=Split-Path $officialManifest
    [void][IO.Directory]::CreateDirectory($officialStateFolder)
    $officialOriginal=Join-Path $officialStateFolder 'original'
    [IO.File]::WriteAllText($officialOriginal,'official receipt recovery fixture')
    $officialOriginalHash=HashFile $officialOriginal
    $staleReceipt=@{Path=$addon;SourcePath=$addon;Hash='84f0c261183309f153ae837e6a721d23e574255618a2523b41d0ba846801a65d';PreviousHash=$officialOriginalHash;Backup='original';Mutable=$false;Retained=$true;Component=''}
    WriteState @{Status='Installed';Game=$txGame;Files=@($staleReceipt);Components=@('Effects')} $officialManifest
    $officialDownload={param($release,$destination,$progress)Copy-Item -LiteralPath $officialAsset -Destination $destination -Force}.GetNewClosure()
    $null=UpdateGlassCockpitAddon $officialManifest $officialRelease {} $officialDownload
    $reconciled=ReadOptiShadeState $officialManifest;$reconciledRecord=@($reconciled.Files|Where-Object {$_.Path -eq $addon})
    Assert-Equal 'Cockpit' $reconciledRecord[0].Component 'Stale official receipt is assigned to the Glass Cockpit component after verified update'
    Assert-Equal $provenance.SHA256 $reconciledRecord[0].Hash 'Receipt reconciliation records only the verified v1.0.3 hash'
    Assert-Equal $provenance.SHA256 (HashFile (Join-Path $txGame $addon)) 'The update action installs the verified official v1.0.3 asset'
    Assert-Equal $officialOriginalHash $reconciledRecord[0].PreviousHash 'Stale-receipt reconciliation preserves the prior original-file recovery chain'

    # Match the hosted manager: helpers live in a script/module scope, not global.
    # A GetNewClosure mutation creates a dynamic module that cannot resolve HashFile.
    $hosted=New-Module -ArgumentList $root -ScriptBlock {
        param($repo)
        . (Join-Path $repo 'Beta/installer/ownership.ps1')
        . (Join-Path $repo 'Beta/installer/components.ps1')
        . (Join-Path $repo 'Beta/installer/glass-cockpit-update.ps1')
        Export-ModuleMember -Function UpdateGlassCockpitAddon
    }
    try{
        foreach($legacyTag in @('', 'Core')){
            Copy-Item -LiteralPath (Join-Path $cockpitFolder $addon) -Destination (Join-Path $txGame $addon) -Force
            $legacyRecord=@{Path=$addon;Hash=$bundledHash;PreviousHash=$txOriginalHash;Backup='original';Mutable=$false;Retained=$true;Component=$legacyTag}
            WriteState @{Status='Installed';Game=$txGame;Files=@($legacyRecord);Components=@('Effects')} $txManifest
            Assert-Equal $true (GetGlassCockpitUpdateInfo (ReadOptiShadeState $txManifest) $txRelease $versionReader).CanAdopt 'Official older receipt can migrate its missing/core component label'
            $null=& $hosted {param($mp,$rel,$dl,$vr) UpdateGlassCockpitAddon $mp $rel {} $dl $vr} $txManifest $txRelease $download $versionReader
            $afterHosted=ReadOptiShadeState $txManifest
            $hostedRecord=@($afterHosted.Files|Where-Object {$_.Path -eq $addon})
            Assert-Equal 'Cockpit' $hostedRecord[0].Component 'Hosted updater labels the migrated addon'
            Assert-Equal $newHash (HashFile (Join-Path $txGame $addon)) 'Hosted manager callback actually replaces the file'
            Assert-Equal $txOriginalHash $hostedRecord[0].PreviousHash 'Legacy receipt retains original recovery identity'
        }
        [IO.File]::WriteAllText((Join-Path $txGame $addon),'unknown modified addon')
        $legacyRecord.Hash='0'*64
        Assert-Equal $false (TestGlassCockpitLegacyOwnership @($legacyRecord) (Join-Path $txGame $addon)) 'Unknown modified bytes are not adopted'
        Copy-Item -LiteralPath (Join-Path $cockpitFolder $addon) -Destination (Join-Path $txGame $addon) -Force
        $legacyRecord.Hash=$bundledHash;$legacyRecord.Component='Neural'
        Assert-Equal $false (TestGlassCockpitLegacyOwnership @($legacyRecord) (Join-Path $txGame $addon)) 'Conflicting component owner is not adopted'
        Assert-Equal $false (TestGlassCockpitLegacyOwnership @($legacyRecord,$legacyRecord) (Join-Path $txGame $addon)) 'Duplicate ownership is not adopted'
    }finally{Remove-Module $hosted -Force}
    [IO.File]::WriteAllText((Join-Path $txGame $addon),'unknown modified addon')
    WriteState @{Status='Installed';Game=$txGame;Files=@();Components=@()} $txManifest
    $unknown=GetGlassCockpitUpdateInfo (ReadOptiShadeState $txManifest) $txRelease $versionReader
    Assert-Equal $false $unknown.CanDownload 'Matching name/version alone cannot authorize replacement'
    $blocked=$false;try{UpdateGlassCockpitAddon $txManifest $txRelease {} $download $versionReader|Out-Null}catch{$blocked=$true}
    Assert-Equal $true $blocked 'Unknown legacy bytes are refused'
    Assert-Equal 'unknown modified addon' ([IO.File]::ReadAllText((Join-Path $txGame $addon))) 'Unknown addon remains unchanged'
    # Component install/repair must agree with the official download updater.
    $official104=Join-Path $PSScriptRoot 'data/glass-cockpit-dlss-fix-v1.0.4.addon64'
    $official104Hash='1ADF8771FB050572D01D0628D9E7A75A60F07BB890AD98D770FD7CD0DB4EAFAA'
    Assert-Equal $official104Hash (HashFile $official104) 'Regression binary matches the official v1.0.4 release digest'
    $payload=Join-Path $txRoot 'component-payload';[void][IO.Directory]::CreateDirectory($payload)
    [IO.File]::WriteAllText((Join-Path $payload $addon),'older bundled fixture')
    ConvertTo-Json -InputObject @(@{Path=$addon;Hash=(HashFile (Join-Path $payload $addon))})|Set-Content (Join-Path $payload 'files.json') -Encoding UTF8
    Copy-Item -LiteralPath $official104 -Destination (Join-Path $txGame $addon) -Force
    WriteState @{Status='Installed';Game=$txGame;Files=@();Components=@()} $txManifest
    InvokeAddonTransaction $txManifest Cockpit {InstallAddonPayload $txManifest $payload Cockpit}
    $adopted=ReadOptiShadeState $txManifest;$record=@($adopted.Files|Where-Object Path -eq $addon)[0]
    Assert-Equal $official104Hash (HashFile (Join-Path $txGame $addon)) 'Component install preserves an unowned pinned official download'
    Assert-Equal 'Cockpit' $record.Component 'Unchanged official download is registered to the component'
    Assert-Equal $official104Hash (HashFile (OwnedPath $txState $record.Backup)) 'Adoption retains a verified original backup'
    InvokeAddonTransaction $txManifest Cockpit {InstallAddonPayload $txManifest $payload Cockpit}
    Assert-Equal $official104Hash (HashFile (Join-Path $txGame $addon)) 'Repeated component install does not downgrade the official download'
    # A future release already verified by the updater need not be in the old pin list.
    [IO.File]::WriteAllText((Join-Path $txGame $addon),$newBytes)
    $adopted.Files[0].Hash=HashFile (Join-Path $txGame $addon);WriteState $adopted $txManifest
    InvokeAddonTransaction $txManifest Cockpit {InstallAddonPayload $txManifest $payload Cockpit}
    Assert-Equal $newHash (HashFile (Join-Path $txGame $addon)) 'Receipt-verified future download is not replaced by bundled payload'
    Copy-Item -LiteralPath $official104 -Destination (Join-Path $txGame $addon) -Force
    $adopted.Files[0].Component='Core';$adopted.Files[0].Hash='0'*64;WriteState $adopted $txManifest
    InvokeAddonTransaction $txManifest Cockpit {InstallAddonPayload $txManifest $payload Cockpit}
    Assert-Equal $official104Hash (ReadOptiShadeState $txManifest).Files[0].Hash 'Stale legacy receipt reconciles against exact official bytes'
    Assert-Equal 'Cockpit' (ReadOptiShadeState $txManifest).Files[0].Component 'Legacy component tag is reconciled'
    $prior=[IO.File]::ReadAllText($txManifest)
    $failed=$false;try{InvokeAddonTransaction $txManifest Cockpit {InstallAddonPayload $txManifest $payload Cockpit;throw 'fixture failure'}}catch{$failed=$true}
    Assert-Equal $true $failed 'Post-install failure is reported'
    Assert-Equal $prior ([IO.File]::ReadAllText($txManifest)) 'Failed reconciliation rolls back receipt bytes'
    Assert-Equal $official104Hash (HashFile (Join-Path $txGame $addon)) 'Failed reconciliation preserves addon bytes'
    [IO.File]::WriteAllText((Join-Path $txGame $addon),'unknown foreign bytes')
    WriteState @{Status='Installed';Game=$txGame;Files=@();Components=@()} $txManifest
    $blocked=$false;try{InvokeAddonTransaction $txManifest Cockpit {InstallAddonPayload $txManifest $payload Cockpit}}catch{$blocked=$true}
    Assert-Equal $true $blocked 'Component installation still refuses an unknown unowned addon'
    Assert-Equal 'unknown foreign bytes' ([IO.File]::ReadAllText((Join-Path $txGame $addon))) 'Foreign addon is preserved'
}finally{Remove-Item -LiteralPath $txRoot -Recurse -Force -ErrorAction SilentlyContinue}



$now=[DateTime]::UtcNow
Assert-Equal $false (TestGlassCockpitCheckDue $now.AddMinutes(-1) $true $false $now) 'Background checks respect the cache'
Assert-Equal $true (TestGlassCockpitCheckDue $now.AddMinutes(-1) $true $true $now) 'Manual refresh bypasses the successful cache'
Assert-Equal $true (TestGlassCockpitCheckDue $now.AddMinutes(-6) $true $false $now) 'Open managers recheck after five minutes'
Assert-Equal $false (TestGlassCockpitCheckDue $now.AddSeconds(-30) $false $false $now) 'Failed requests use backoff'
Assert-Equal $true (TestGlassCockpitCheckDue $null $false $false $now) 'The first check runs immediately'

Write-Host 'Glass Cockpit detection, cache refresh and ownership-safe update tests passed.'
