$ErrorActionPreference='Stop'
$root=Resolve-Path (Join-Path $PSScriptRoot '..\..')
. (Join-Path $root 'Beta/installer/atmosphere-mod.ps1')
function Assert($condition,$message){if(-not $condition){throw $message}}

# Release selection: only the official asset with GitHub's SHA-256 digest.
$hash='0d46acf43a8b363c1eb31f6054b443c8176f8c6053614c183478ba44b42bd7ac'
function Release($tag='v0.5.1',$name='AtmosphereMod-0.5.1.zip',$url="https://github.com/tomwhoca/AtmosphereMod/releases/download/v0.5.1/AtmosphereMod-0.5.1.zip",$digest="sha256:$hash",$body="SHA-256 of AtmosphereMod-0.5.1.zip: $hash",$size=21712546,$draft=$false,$pre=$false){
 [pscustomobject]@{tag_name=$tag;draft=$draft;prerelease=$pre;body=$body;assets=@([pscustomobject]@{name=$name;browser_download_url=$url;digest=$digest;size=$size})}
}
$r=ConvertFromAtmosphereModRelease (Release)
Assert ($r -and $r.VersionText -eq '0.5.1' -and $r.SHA256 -eq $hash -and $r.Name -eq 'AtmosphereMod-0.5.1.zip') 'The official release is not accepted'
Assert (-not (ConvertFromAtmosphereModRelease (Release -digest ''))) 'A release without GitHub''s SHA-256 digest is accepted'
Assert (-not (ConvertFromAtmosphereModRelease (Release -url 'https://example.com/tomwhoca/AtmosphereMod/releases/download/v0.5.1/AtmosphereMod-0.5.1.zip'))) 'A release asset off GitHub is accepted'
Assert (-not (ConvertFromAtmosphereModRelease (Release -body ('SHA-256 of AtmosphereMod-0.5.1.zip: '+('0'*64))))) 'A digest that disagrees with the author''s stated hash is accepted'
Assert (-not (ConvertFromAtmosphereModRelease (Release -pre $true))) 'A pre-release is accepted'
Assert (-not (ConvertFromAtmosphereModRelease (Release -size (200MB)))) 'An oversized release is accepted'
Assert ((ConvertFromAtmosphereModRelease (Release -body 'Notes without a hash')).SHA256 -eq $hash) 'Release notes without a stated hash block the GitHub digest'
Assert ((GetAtmosphereModLatestRelease {param($u) Release}).Tag -eq 'v0.5.1') 'The latest-release lookup does not use the GitHub releases API result'
$threw=$false;try{$null=GetAtmosphereModLatestRelease {param($u) Release -digest ''}}catch{$threw=$_.Exception.Message -match 'verifiable'};Assert $threw 'An unverifiable latest release does not stop the install'

$work=Join-Path ([IO.Path]::GetTempPath()) ('osatmo-'+[guid]::NewGuid().ToString('N'));$savedLocal=$env:LOCALAPPDATA;$savedRoaming=$env:APPDATA
try{
 # Never the PC's own sim settings: its Community folder may hold the EFB app.
 $env:LOCALAPPDATA=Join-Path $work 'local';$env:APPDATA=Join-Path $work 'roaming'
 $game=Join-Path $work 'Content';$data=Join-Path $work 'data';New-Item -ItemType Directory -Path $game,$data -Force|Out-Null
 Set-Content -LiteralPath (Join-Path $game 'FlightSimulator2024.exe') -Value 'x'
 Set-Content -LiteralPath (Join-Path $game 'ReShade64.dll') -Value 'x'
 $state=GetAtmosphereModState $game $data
 Assert ($state.Supported -and $state.ReShade -and -not $state.Installed -and -not $state.NeedsRepatch) 'A game without the add-on is reported installed'

 Set-Content -LiteralPath (Join-Path $game 'AtmosphereMod.addon64') -Value 'x'
 Set-Content -LiteralPath (Join-Path $game 'ReShade.ini') -Value "[GENERAL]`r`nPresetPath=.\x.ini`r`n`r`n[ATMOSPHEREMOD]`r`nDataPath=$data`r`n"
 (Get-Item (Join-Path $game 'FlightSimulator2024.exe')).LastWriteTimeUtc=[DateTime]::UtcNow.AddHours(-2)
 $recordCommunity=Join-Path $work 'Community';New-Item -ItemType Directory -Path (Join-Path $recordCommunity 'atmospheremod-weather') -Force|Out-Null
 @{version='0.5.1';sim=$game+'\';community=$recordCommunity;patched=41;failed=2}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $data 'install.json')
 $state=GetAtmosphereModState $game $data
 Assert ($state.Installed -and $state.SectionPresent -and $state.Version -eq '0.5.1' -and $state.Patched -eq 41 -and $state.Failed -eq 2 -and $state.Community) 'Installed state is not read from the mod''s own record'
 Assert (-not $state.NeedsRepatch) 'A current install is reported as needing a re-patch'
 Remove-Item -LiteralPath (Join-Path $recordCommunity 'atmospheremod-weather') -Recurse -Force
 Assert (-not (GetAtmosphereModState $game $data).Community) 'An EFB app the record names but that is gone is reported installed'
 (Get-Item (Join-Path $game 'FlightSimulator2024.exe')).LastWriteTimeUtc=[DateTime]::UtcNow.AddHours(1)
 Assert ((GetAtmosphereModState $game $data).NeedsRepatch) 'A sim update after the patch is not reported'

 @{version='0.5.1';sim='D:\Other\Content'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $data 'install.json')
 $state=GetAtmosphereModState $game $data
 Assert ($state.OtherGame -eq 'D:\Other\Content' -and -not $state.Version) 'A record for another sim copy is attributed to this game'
}finally{$env:LOCALAPPDATA=$savedLocal;$env:APPDATA=$savedRoaming;Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}

# OptiShade's own install and uninstall, against a fake sim and release with a
# stand-in shader patcher. LOCALAPPDATA points at the fixture so OptiShade's
# backups stay inside it.
$work=Join-Path ([IO.Path]::GetTempPath()) ('osatmo-'+[guid]::NewGuid().ToString('N'));$savedLocal=$env:LOCALAPPDATA
try{
 $env:LOCALAPPDATA=Join-Path $work 'local';$savedRoaming=$env:APPDATA;$env:APPDATA=Join-Path $work 'roaming'
 $game=Join-Path $work 'Content';$data=Join-Path $work 'local\AtmosphereMod';$community=Join-Path $work 'Packages\Community';$rel=Join-Path $work 'release\AtmosphereMod-0.5.1'
 foreach($d in @($game,(Join-Path $game 'Shaders'),(Join-Path $rel 'payload\efb\atmospheremod-weather'),(Join-Path $rel 'payload\shaders'),(Join-Path $rel 'installer\python'))){New-Item -ItemType Directory -Path $d -Force|Out-Null}
 Set-Content -LiteralPath (Join-Path $game 'FlightSimulator2024.exe') -Value 'x';Set-Content -LiteralPath (Join-Path $game 'ReShade64.dll') -Value 'x'
 Set-Content -LiteralPath (Join-Path $game 'Shaders\SHADERSPAK.1.SM6.PC.PAK') -Value 'pak'
 [IO.File]::WriteAllText((Join-Path $game 'ReShade.ini'),"[GENERAL]`nPresetPath=.\OptiShadeData\Presets\My look.ini`n")
 Set-Content -LiteralPath (Join-Path $rel 'payload\AtmosphereMod.addon64') -Value 'addon'
 Set-Content -LiteralPath (Join-Path $rel 'payload\efb\atmospheremod-weather\layout.json') -Value '{}'
 [IO.File]::WriteAllText((Join-Path $rel 'payload\tunables.ini'),"; atmosphere`nT1=1`n; haze`nT2=2`n")
 foreach($f in 'python\python.exe','manifest.json','extract_pak.py','patch_dxil.py'){Set-Content -LiteralPath (Join-Path $rel ('installer\'+$f)) -Value 'x'}
 Set-Content -LiteralPath (Join-Path $rel 'installer\VERSION') -Value '0.5.1'
 $opened=[pscustomobject]@{Work=(Join-Path $work 'release');Root=$rel}
 $script:patchCalls=0
 $patcher={param($parts,$pack,$dataFolder,$pump,$log) $script:patchCalls++;Assert ($pack -like '*SHADERSPAK.1.SM6.PC.PAK') 'The sim''s shader pack is not the one patched';New-Item -ItemType Directory -Path (Join-Path $dataFolder 'shaders') -Force|Out-Null;Set-Content -LiteralPath (Join-Path $dataFolder 'shaders\a.cso') -Value 'cso';[pscustomobject]@{Patched=3;Failed=1;Replaced=0}}

 $state=InstallAtmosphereMod $game $null $null $data $patcher $community $opened
 $ini=[IO.File]::ReadAllText((Join-Path $game 'ReShade.ini'))
 Assert ($state.Installed -and $state.Version -eq '0.5.1' -and $state.Patched -eq 3 -and $state.Failed -eq 1 -and $script:patchCalls -eq 1) 'OptiShade''s install did not produce an installed state from its record'
 Assert ((Test-Path (Join-Path $game 'AtmosphereMod.addon64')) -and (Test-Path (Join-Path $game 'ReShade.ini.atmospheremod.bak'))) 'The add-on or the one-time ReShade.ini backup is missing'
 Assert ($ini -match '(?m)^\[GENERAL\]' -and $ini -match '(?m)^\[ATMOSPHEREMOD\]' -and $ini.Contains('DataPath='+$data) -and $ini -match '(?m)^InjectRootSignature=1' -and $ini -match '(?m)^InjectGraphicsRootSignature=1') 'ReShade.ini does not carry the mod''s settings beside OptiShade''s'
 Assert (Test-Path (Join-Path $community 'atmospheremod-weather\layout.json')) 'The EFB sim bridge is not in the Community folder'
 Assert ((Get-Content -LiteralPath (Join-Path $data 'install.json') -Raw|ConvertFrom-Json).community -eq $community) 'The install record has no Community folder'

 # Re-patch: the player's settings stay, new defaults are added once.
 [IO.File]::WriteAllText((Join-Path $data 'tunables.ini'),"; atmosphere`nT1=5`n; haze`nT2=2`n")
 [IO.File]::WriteAllText((Join-Path $rel 'payload\tunables.ini'),"; atmosphere`nT1=1`n; haze`nT2=2`n; new`nC9=7`n")
 $null=InstallAtmosphereMod $game $null $null $data $patcher $community $opened
 $tun=[IO.File]::ReadAllText((Join-Path $data 'tunables.ini'))
 Assert ($tun -match '(?m)^T1=5' -and $tun -match '(?m)^C9=7' -and ([regex]::Matches($tun,'(?m)^\[ATMOSPHEREMOD\]').Count -eq 0)) 'A re-patch did not keep the player''s tunables and add the new setting'
 Assert ([regex]::Matches([IO.File]::ReadAllText((Join-Path $game 'ReShade.ini')),'(?m)^\[ATMOSPHEREMOD\]').Count -eq 1) 'A re-patch duplicated the ReShade.ini section'

 # Uninstall removes exactly the install, keeps the settings for a reinstall.
 $state=UninstallAtmosphereMod $game $null $data
 $ini=[IO.File]::ReadAllText((Join-Path $game 'ReShade.ini'))
 Assert (-not $state.Installed -and -not (Test-Path (Join-Path $game 'AtmosphereMod.addon64')) -and $ini -notmatch 'ATMOSPHEREMOD' -and $ini -match '(?m)^PresetPath=') 'Uninstall left the add-on or its ReShade.ini section, or removed OptiShade''s settings'
 Assert (-not (Test-Path (Join-Path $community 'atmospheremod-weather')) -and -not (Test-Path $data)) 'Uninstall left the EFB bridge or the patched shaders'
 Assert ((Get-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'OptiShade\Backups\AtmosphereMod\tunables.ini') -Raw) -match '(?m)^T1=5') 'Uninstall did not keep the player''s tunables.ini'
 $null=InstallAtmosphereMod $game $null $null $data $patcher $community $opened
 Assert ([IO.File]::ReadAllText((Join-Path $data 'tunables.ini')) -match '(?m)^T1=5') 'A reinstall did not bring the player''s tunables.ini back'
 # The manager passes no Community folder: it must come from the sim's UserCfg.opt.
 $packages=Join-Path $work 'StorePackages';New-Item -ItemType Directory -Path $packages -Force|Out-Null
 $cfg=Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.Limitless_8wekyb3d8bbwe\LocalCache';New-Item -ItemType Directory -Path $cfg -Force|Out-Null
 [IO.File]::WriteAllText((Join-Path $cfg 'UserCfg.opt'),"Version 1`r`nInstalledPackagesPath `"$packages`"`r`n")
 $state=InstallAtmosphereMod $game $null $null $data $patcher $null $opened
 Assert ((Test-Path (Join-Path $packages 'Community\atmospheremod-weather\layout.json')) -and $state.Community -eq (Join-Path $packages 'Community')) 'Without an explicit Community folder the EFB bridge was not installed from UserCfg.opt'
 # Already installed (by OptiShade or the mod's own installer): finishing it
 # does only the missing step. No Community record, EFB app present: found.
 $record=Get-Content -LiteralPath (Join-Path $data 'install.json') -Raw|ConvertFrom-Json;$record.community=$null
 [IO.File]::WriteAllText((Join-Path $data 'install.json'),($record|ConvertTo-Json))
 $state=GetAtmosphereModState $game $data
 Assert ($state.Community -eq (Join-Path $packages 'Community') -and $state.CommunityAvailable) 'An EFB app already in Community is not detected without the record'
 # EFB app missing: it comes from the installed version's release; no re-patch.
 Remove-Item -LiteralPath (Join-Path $packages 'Community\atmospheremod-weather') -Recurse -Force
 $state=GetAtmosphereModState $game $data
 Assert (-not $state.Community -and $state.CommunityAvailable) 'A missing EFB app is not reported'
 function ExpandAtmosphereModRelease($Pump,$Release){$script:expandedVersion=$Release.VersionText;$w=Join-Path $work ('x'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $w|Out-Null;[pscustomobject]@{Work=$w;Root=$rel}}
 $script:requested='';$calls=$script:patchCalls
 $state=RepairAtmosphereMod $game $null $data {param($u) $script:requested=$u;Release} {throw 'A full install ran for a missing EFB app'}
 Assert ($state.Community -eq (Join-Path $packages 'Community') -and (Test-Path (Join-Path $packages 'Community\atmospheremod-weather\layout.json'))) 'Finishing did not install the missing EFB app'
 Assert ($script:requested -like '*/releases/tags/v0.5.1' -and $script:expandedVersion -eq '0.5.1' -and $script:patchCalls -eq $calls) 'The EFB app did not come from the installed version''s release, or the shaders were re-patched'
 Assert ((Get-Content -LiteralPath (Join-Path $data 'install.json') -Raw|ConvertFrom-Json).community -eq (Join-Path $packages 'Community')) 'The record does not name the EFB app''s Community folder'
 # ReShade.ini settings missing (ReShade.ini replaced): written in place, no download.
 [IO.File]::WriteAllText((Join-Path $game 'ReShade.ini'),"[GENERAL]`nPresetPath=x.ini`n")
 $state=RepairAtmosphereMod $game $null $data {throw 'A release was fetched to restore ReShade.ini settings'} {throw 'A full install ran to restore ReShade.ini settings'}
 $ini=[IO.File]::ReadAllText((Join-Path $game 'ReShade.ini'))
 Assert ($state.SectionPresent -and $ini.Contains('DataPath='+$data) -and $ini -match '(?m)^PresetPath=x.ini') 'Finishing did not restore the ReShade.ini settings in place'
 # A sim update: only then the full install.
 (Get-Item (Join-Path $game 'FlightSimulator2024.exe')).LastWriteTimeUtc=[DateTime]::UtcNow.AddHours(1)
 $script:full=$false;$null=RepairAtmosphereMod $game $null $data $null {param($g,$p,$d) $script:full=$true;GetAtmosphereModState $g $d}
 Assert $script:full 'A sim update did not re-patch'
 # An EFB app linked by an add-on linker: replaced by a real folder, the
 # player's library it pointed to is untouched.
 $library=Join-Path $work 'Library\atmospheremod-weather';New-Item -ItemType Directory -Path $library -Force|Out-Null;Set-Content -LiteralPath (Join-Path $library 'mine.txt') -Value 'keep'
 $link=Join-Path $packages 'Community\atmospheremod-weather';Remove-Item -LiteralPath $link -Recurse -Force
 $null=cmd /c mklink /J "$link" "$library"
 Assert ((Get-Item -LiteralPath $link -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) 'The test junction was not created'
 InstallAtmosphereModEfb (Join-Path $rel 'payload\efb\atmospheremod-weather') (Join-Path $packages 'Community')
 Assert ((Test-Path (Join-Path $library 'mine.txt')) -and -not ((Get-Item -LiteralPath $link -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -and (Test-Path (Join-Path $link 'layout.json'))) 'Replacing a linked EFB app deleted the linked folder or kept the link'
 # 0.6.0's presets: Default is this version's defaults; the player's get new settings.
 [IO.File]::WriteAllText((Join-Path $data 'presets\Mine.ini'),"T1=9`n")
 UpdateAtmosphereModPresets "; atmosphere`nT1=1`n; new`nC9=7`n" $data '0.6.0'
 Assert (([IO.File]::ReadAllText((Join-Path $data 'presets\Default.ini')) -match '(?m)^C9=7') -and ([IO.File]::ReadAllText((Join-Path $data 'presets\Mine.ini')) -match '(?s)^T1=9.*C9=7')) 'The EFB presets were not updated'
}finally{$env:LOCALAPPDATA=$savedLocal;$env:APPDATA=$savedRoaming;Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}

# 0.6.0 patches in "spawn" worker processes. A real Python runs OptiShade's
# driver against a patcher that does the same; a stuck patcher is stopped,
# workers included.
$python=(Get-Command python -ErrorAction SilentlyContinue).Source
if($python -and $python -notlike '*WindowsApps*'){
 $work=Join-Path ([IO.Path]::GetTempPath()) ('osatmo-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $work|Out-Null
 try{
  [IO.File]::WriteAllText((Join-Path $work 'patch_dxil.py'),"import multiprocessing`nfrom pathlib import Path`ndef _job(n):`n    return n * 2`ndef patch_all(root=None, dxc=None, strict=True):`n    pool = multiprocessing.get_context('spawn').Pool(2)`n    try:`n        out = list(pool.imap(_job, range(16), chunksize=4))`n    finally:`n        pool.terminate()`n    (root / 'done.txt').write_text(str(sum(out)))`n    return 0`n")
  $driver=Join-Path $work 'driver.py';[IO.File]::WriteAllText($driver,(GetAtmosphereModPatchDriver))
  $parts=[pscustomobject]@{Python=$python;Installer=$work}
  $run=InvokeAtmosphereModPython $parts @($driver,$work,$work,'dxc') $null 2
  Assert ($run.ExitCode -eq 0 -and $run.Output -match '(?m)^OPTISHADE-FAILED 0' -and ([IO.File]::ReadAllText((Join-Path $work 'done.txt')) -eq '240')) ('The patch driver did not finish with a spawn worker pool: '+$run.Output)
  [IO.File]::WriteAllText((Join-Path $work 'hang.py'),"import multiprocessing, time`ndef _sleep(n):`n    time.sleep(600)`nif __name__ == '__main__':`n    pool = multiprocessing.get_context('spawn').Pool(1)`n    pool.apply_async(_sleep, (1,))`n    time.sleep(600)`n")
  $before=@(Get-CimInstance Win32_Process -Filter "Name='python.exe'"|ForEach-Object {$_.ProcessId})
  $threw=$false;try{$null=InvokeAtmosphereModPython $parts @((Join-Path $work 'hang.py')) $null 0.1}catch{$threw=$_.Exception.Message -match 'did not finish'}
  Start-Sleep -Milliseconds 500
  $left=@(Get-CimInstance Win32_Process -Filter "Name='python.exe'"|Where-Object {$_.ProcessId -notin $before -and $_.ExecutablePath -eq $python})
  Assert ($threw -and -not $left.Count) 'A stuck patcher was not stopped with its worker processes'
 }finally{Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}
}else{'SKIP: no Python on PATH for the spawn-worker check'}
'PASS: AtmosphereMod release verification, installed state (EFB app found in Community), install, uninstall, finishing an existing install with only the missing step, linked EFB app kept, presets, and the spawn-worker patch driver and time limit.'

# R353: installed-version comparison and the shared Update Manager row.
function GetBundledOptiShadeVersion { '1.0.77' }
. (Join-Path $root 'Beta/installer/manager-status.ps1')
$release=[pscustomobject]@{VersionText='0.6.1';Version=[version]'0.6.1'}
foreach($case in @(@('0.5.1',$true),@('0.6.0',$true),@('0.6.1',$false),@('0.7.0',$false))){
 $info=GetAtmosphereModUpdateInfo ([pscustomobject]@{Installed=$true;Version=$case[0]}) $release
 Assert ($info.Available -eq $case[1]) ('Incorrect update comparison for '+$case[0])
}
Assert (-not (GetAtmosphereModUpdateInfo ([pscustomobject]@{Installed=$false;Version='0.5.1'}) $release).Available) 'Absent AtmosphereMod offered for update'
Assert ((GetAtmosphereModUpdateInfo ([pscustomobject]@{Installed=$true;Version=''}) $release).UnknownVersion) 'Missing installation version hidden'
Assert (-not (GetAtmosphereModUpdateInfo ([pscustomobject]@{Installed=$true;Version='0.5.1'}) $null).Available) 'Failed release lookup offered an update'
$info=GetAtmosphereModUpdateInfo ([pscustomobject]@{Installed=$true;Version='0.5.1'}) $release
$context=[pscustomobject]@{LocalPackage=$null;Release=$null}
$record=[pscustomobject]@{Game=[pscustomobject]@{Name='MSFS'};Folder='C:\Fixture';ManifestPath='fixture.json';Manifest=[pscustomobject]@{};Info=[pscustomobject]@{Core=$false;Components=@()};Glass=[pscustomobject]@{Available=$false};Atmosphere=$info}
$rows=@(GetOptiShadeManagerSnapshotRows $context $record ([pscustomobject]@{Available=$false}))
Assert ($rows.Count -eq 1 -and $rows[0].Id -eq 'Atmosphere' -and -not $rows[0].Manual -and $rows[0].Detail -match '0.6.1') 'AtmosphereMod missing from actionable Update All rows'
$record.Atmosphere=GetAtmosphereModUpdateInfo ([pscustomobject]@{Installed=$true;Version='0.6.1'}) $release
Assert (@(GetOptiShadeManagerSnapshotRows $context $record ([pscustomobject]@{Available=$false})).Count -eq 0) 'Updated AtmosphereMod row did not clear'
Write-Output 'PASS: AtmosphereMod update comparison and shared update rows'
