$ErrorActionPreference='Stop'

# AtmosphereMod by tomwhoca (owner agreement with the author, 2 Nov 2026),
# installed by OptiShade itself in one step, like the Glass Cockpit fix. The
# latest official release zip is downloaded from GitHub, checked against
# GitHub's SHA-256 digest (and the hash the author prints in the release
# notes) and opened in a temporary folder. OptiShade then does what the mod's
# own installer does, nothing more:
#  - patches the sim's shaders from the player's own shader pack with the
#    author's extract_pak.py and patch_dxil.patch_all(), run by the release's
#    bundled Python and Microsoft-signed DXC (the only step that needs them);
#  - keeps the player's tunables.ini, adding settings new in the release;
#  - puts AtmosphereMod.addon64 beside OptiShade's ReShade64.dll;
#  - writes the [ATMOSPHEREMOD] keys into ReShade.ini (backed up once);
#  - copies the EFB sim bridge (atmospheremod-weather) into the Community folder;
#  - writes the same install.json record as the mod's installer.
# None of these files are in OptiShade's receipt, so Repair and Restore never
# touch them; Uninstall removes exactly them. The add-on files are not changed.
# The add-on's METAR feature uses SimConnect itself; OptiShade adds no
# SimConnect code.
$script:AtmosphereModAddon='AtmosphereMod.addon64'
$script:AtmosphereModEfb='atmospheremod-weather'
$script:AtmosphereModSection='ATMOSPHEREMOD'
$script:AtmosphereModIniBackup='ReShade.ini.atmospheremod.bak'
$script:AtmosphereModRepo='/tomwhoca/AtmosphereMod'
$script:AtmosphereModApi='https://api.github.com/repos/tomwhoca/AtmosphereMod/releases/latest'
$script:AtmosphereModMaximumBytes=100MB
$script:AtmosphereModDxcVersion='1.8.2502'

function GetAtmosphereModDataFolder{Join-Path $env:LOCALAPPDATA 'AtmosphereMod'}
function GetAtmosphereModBackupFolder{Join-Path $env:LOCALAPPDATA 'OptiShade\Backups\AtmosphereMod'}

# The official release: tag vX.Y.Z with exactly one AtmosphereMod-X.Y.Z.zip,
# served from this repository, with GitHub's SHA-256 digest. When the notes
# also state "SHA-256 of AtmosphereMod-X.Y.Z.zip: <hash>", both must agree.
function ConvertFromAtmosphereModRelease($Release){
 if(-not $Release -or [bool]$Release.draft -or [bool]$Release.prerelease){return $null}
 $tag=[string]$Release.tag_name
 if($tag -notmatch '^v(\d+\.\d+\.\d+)$'){return $null}
 $versionText=$Matches[1];$name='AtmosphereMod-'+$versionText+'.zip'
 $assets=@($Release.assets|Where-Object {[string]$_.name -ceq $name})
 if($assets.Count -ne 1){return $null}
 $uri=$null;try{$uri=[uri][string]$assets[0].browser_download_url}catch{return $null}
 if($uri.Scheme -cne 'https' -or $uri.Host -cne 'github.com' -or $uri.AbsolutePath -cne ($script:AtmosphereModRepo+'/releases/download/'+$tag+'/'+$name)){return $null}
 $digest=[string]$assets[0].digest
 if($digest -notmatch '^sha256:([a-fA-F0-9]{64})$'){return $null}
 $sha=$Matches[1].ToLowerInvariant()
 $stated=[regex]::Match([string]$Release.body,'(?i)SHA-256 of '+[regex]::Escape($name)+':\s*([a-f0-9]{64})')
 if($stated.Success -and $stated.Groups[1].Value.ToLowerInvariant() -cne $sha){return $null}
 $size=[long]$assets[0].size
 if($size -le 0 -or $size -gt $script:AtmosphereModMaximumBytes){return $null}
 return [pscustomobject]@{Version=[version]$versionText;VersionText=$versionText;Tag=$tag;Name=$name;AssetUrl=$uri.AbsoluteUri;SHA256=$sha;Size=$size
  ReleaseUrl='https://github.com'+$script:AtmosphereModRepo+'/releases/tag/'+[uri]::EscapeDataString($tag)}
}

# The latest release, or with -Version the installed one (its EFB app must
# match the installed add-on).
function GetAtmosphereModLatestRelease([scriptblock]$Request,[string]$Version){
 [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
 if($Version -and $Version -notmatch '^\d+\.\d+\.\d+$'){throw 'The installed AtmosphereMod version is not recognised.'}
 $api=if($Version){$script:AtmosphereModApi -replace '/latest$',('/tags/v'+$Version)}else{$script:AtmosphereModApi}
 try{
  $release=if($Request){& $Request $api}else{Invoke-RestMethod -Uri $api -Headers @{'User-Agent'='OptiShade-AtmosphereMod';'Accept'='application/vnd.github+json'} -TimeoutSec 15 -ErrorAction Stop}
 }catch{throw 'Could not reach the AtmosphereMod releases on GitHub. Check your connection and try again.'}
 $latest=ConvertFromAtmosphereModRelease $release
 if(-not $latest -or ($Version -and $latest.VersionText -cne $Version)){throw 'The AtmosphereMod release on GitHub has no verifiable AtmosphereMod-<version>.zip (GitHub SHA-256 digest required). Nothing was installed.'}
 return $latest
}

function WaitAtmosphereModTask($Task,[scriptblock]$Pump){while(-not $Task.IsCompleted){if($Pump){& $Pump};Start-Sleep -Milliseconds 100};return $Task.GetAwaiter().GetResult()}

function SaveAtmosphereModRelease($Release,[string]$Destination,[scriptblock]$Pump){
 [void](Add-Type -AssemblyName System.Net.Http)
 $client=[Net.Http.HttpClient]::new();$client.Timeout=[TimeSpan]::FromMinutes(5)
 $client.DefaultRequestHeaders.UserAgent.ParseAdd('OptiShade-AtmosphereMod/1.0')
 try{
  $response=WaitAtmosphereModTask ($client.GetAsync([uri]$Release.AssetUrl,[Net.Http.HttpCompletionOption]::ResponseHeadersRead)) $Pump
  try{
   $null=$response.EnsureSuccessStatusCode()
   $final=$response.RequestMessage.RequestUri
   if($final.Scheme -cne 'https' -or $final.Host -notin @('github.com','release-assets.githubusercontent.com','objects.githubusercontent.com')){throw 'The AtmosphereMod download was redirected away from GitHub. Nothing was installed.'}
   $length=$response.Content.Headers.ContentLength
   if($length -and ($length -gt $script:AtmosphereModMaximumBytes -or $length -ne $Release.Size)){throw 'The AtmosphereMod download size does not match the release. Nothing was installed.'}
   $bytes=WaitAtmosphereModTask ($response.Content.ReadAsByteArrayAsync()) $Pump
  }finally{$response.Dispose()}
 }finally{$client.Dispose()}
 if($bytes.Length -ne $Release.Size){throw 'The AtmosphereMod download was incomplete. Nothing was installed.'}
 $sha=[Security.Cryptography.SHA256]::Create();try{$actual=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
 if($actual -cne $Release.SHA256){throw 'The AtmosphereMod download does not match GitHub''s SHA-256 for the release. Nothing was installed.'}
 [IO.File]::WriteAllBytes($Destination,$bytes)
}

function TestAtmosphereModSameFolder([string]$A,[string]$B){
 if(-not $A -or -not $B){return $false}
 try{return [string]::Equals([IO.Path]::GetFullPath($A).TrimEnd('\'),[IO.Path]::GetFullPath($B).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)}catch{return $false}
}

# State from the files the install writes; nothing of OptiShade's receipt.
function GetAtmosphereModState([string]$Game,[string]$DataFolder=(GetAtmosphereModDataFolder)){
 $exe=Join-Path $Game 'FlightSimulator2024.exe'
 $state=[ordered]@{Supported=(Test-Path -LiteralPath $exe -PathType Leaf);ReShade=(Test-Path -LiteralPath (Join-Path $Game 'ReShade64.dll') -PathType Leaf)
  Installed=$false;Version='';Patched=0;Failed=0;Community='';CommunityAvailable=$false;SectionPresent=$false;NeedsRepatch=$false;OtherGame=''}
 $state.Installed=$state.Supported -and (Test-Path -LiteralPath (Join-Path $Game $script:AtmosphereModAddon) -PathType Leaf)
 $ini=Join-Path $Game 'ReShade.ini'
 if(Test-Path -LiteralPath $ini -PathType Leaf){$state.SectionPresent=[IO.File]::ReadAllText($ini) -match ('(?m)^\['+$script:AtmosphereModSection+'\]')}
 $recordPath=Join-Path $DataFolder 'install.json'
 if(Test-Path -LiteralPath $recordPath -PathType Leaf){
  try{
   $record=Get-Content -LiteralPath $recordPath -Raw|ConvertFrom-Json
   if(TestAtmosphereModSameFolder ([string]$record.sim) $Game){
    $state.Version=[string]$record.version;$state.Patched=[int]$record.patched;$state.Failed=[int]$record.failed;$state.Community=[string]$record.community
    # The patched shaders are made from this sim version; a newer game EXE
    # means a sim update, and the mod falls back to stock until re-patched.
    if($state.Installed -and (Test-Path -LiteralPath $exe -PathType Leaf)){$state.NeedsRepatch=(Get-Item -LiteralPath $exe).LastWriteTimeUtc -gt (Get-Item -LiteralPath $recordPath).LastWriteTimeUtc}
   }elseif($record.sim){$state.OtherGame=[string]$record.sim}
  }catch{}
 }
 # The EFB app may come from the mod's own installer, or be gone although the
 # record names it: look in the sim's Community folder.
 if($state.Installed){
  if($state.Community -and -not(Test-Path -LiteralPath (Join-Path $state.Community $script:AtmosphereModEfb))){$state.Community=''}
  $found=GetAtmosphereModCommunityFolder $Game
  $state.CommunityAvailable=[bool]$found
  if(-not $state.Community -and $found -and (Test-Path -LiteralPath (Join-Path $found $script:AtmosphereModEfb))){$state.Community=$found}
 }
 return [pscustomobject]$state
}

# Downloads the latest release and opens it; the caller removes .Work.
function ExpandAtmosphereModRelease([scriptblock]$Pump,$Release=$null){
 if(-not $Release){$Release=GetAtmosphereModLatestRelease}
 $work=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-AtmosphereMod-'+[guid]::NewGuid().ToString('N'))
 New-Item -ItemType Directory -Path $work -Force|Out-Null
 try{
  $zip=Join-Path $work $Release.Name
  SaveAtmosphereModRelease $Release $zip $Pump
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $extracted=Join-Path $work 'release'
  [IO.Compression.ZipFile]::ExtractToDirectory($zip,$extracted)
  $root=@(Get-ChildItem -LiteralPath $extracted -Directory|Where-Object {Test-Path -LiteralPath (Join-Path $_.FullName ('payload\'+$script:AtmosphereModAddon)) -PathType Leaf})
  if($root.Count -ne 1){throw 'The AtmosphereMod release layout is not recognised. Nothing was installed.'}
  return [pscustomobject]@{Work=$work;Root=$root[0].FullName;Release=$Release}
 }catch{Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue;throw}
}

# The parts of the release OptiShade installs, checked before anything is copied.
function GetAtmosphereModParts([string]$Root){
 $parts=[pscustomobject]@{
  Addon=Join-Path $Root ('payload\'+$script:AtmosphereModAddon);Efb=Join-Path $Root ('payload\efb\'+$script:AtmosphereModEfb)
  Tunables=Join-Path $Root 'payload\tunables.ini';Shaders=Join-Path $Root 'payload\shaders'
  Installer=Join-Path $Root 'installer';Python=Join-Path $Root 'installer\python\python.exe';Dxc=Join-Path $Root 'installer\dxc\bin\x64\dxc.exe'
  Manifest=Join-Path $Root 'installer\manifest.json';Version=''}
 foreach($required in @($parts.Addon,$parts.Tunables,$parts.Python,$parts.Manifest,(Join-Path $parts.Installer 'extract_pak.py'),(Join-Path $parts.Installer 'patch_dxil.py'))){
  if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw ('The AtmosphereMod release is missing '+[IO.Path]::GetFileName($required)+'. Nothing was installed.')}
 }
 if(-not(Test-Path -LiteralPath $parts.Efb -PathType Container)){throw 'The AtmosphereMod release is missing its EFB sim bridge. Nothing was installed.'}
 $versionFile=Join-Path $parts.Installer 'VERSION'
 $parts.Version=if(Test-Path -LiteralPath $versionFile){([IO.File]::ReadAllText($versionFile)).Trim()}else{''}
 return $parts
}

# The shader compiler runs on the player's PC: Microsoft's signed build of the
# version the author's patcher was written against, as its installer requires.
function AssertAtmosphereModCompiler($Parts){
 foreach($file in @('dxc.exe','dxcompiler.dll','dxil.dll')){
  $path=Join-Path (Split-Path $Parts.Dxc) $file
  if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'The AtmosphereMod release is missing Microsoft''s shader compiler. Nothing was installed.'}
  $signature=Get-AuthenticodeSignature -LiteralPath $path
  if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation'){throw ('The shader compiler in the AtmosphereMod release is not signed by Microsoft ('+$file+'). Nothing was installed.')}
  if(-not ([string][Diagnostics.FileVersionInfo]::GetVersionInfo($path).ProductVersion).StartsWith($script:AtmosphereModDxcVersion)){throw ('The AtmosphereMod release has an unexpected shader compiler version ('+$file+'). Nothing was installed.')}
 }
}

# The newest SM6 shader pack in the sim's Shaders folder, as the mod's installer picks it.
function GetAtmosphereModShaderPack([string]$Game){
 $packs=@(@(Get-ChildItem -LiteralPath $Game -Filter 'SHADERSPAK.*.SM6.PC.PAK' -File -ErrorAction SilentlyContinue)+@(Get-ChildItem -LiteralPath (Join-Path $Game 'Shaders') -Filter 'SHADERSPAK.*.SM6.PC.PAK' -File -ErrorAction SilentlyContinue))
 if(-not $packs.Count){throw 'MSFS 2024''s shader pack (Shaders\SHADERSPAK.*.SM6.PC.PAK) was not found in the game folder. Nothing was installed.'}
 return ($packs|Sort-Object LastWriteTimeUtc|Select-Object -Last 1).FullName
}

# <InstalledPackagesPath>\Community from the sim's UserCfg.opt: the Steam copy
# for a Steam install, the Microsoft Store copy otherwise, then the other.
function GetAtmosphereModCommunityFolder([string]$Game){
 $store=Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.Limitless_8wekyb3d8bbwe\LocalCache\UserCfg.opt'
 $steam=Join-Path $env:APPDATA 'Microsoft Flight Simulator 2024\UserCfg.opt'
 $order=if($Game -match '(?i)\\steamapps\\'){@($steam,$store)}else{@($store,$steam)}
 foreach($cfg in $order){
  if(-not(Test-Path -LiteralPath $cfg -PathType Leaf)){continue}
  # The sim may hold UserCfg.opt open, or it may be unreadable: an unread
  # file means "not found", never an error in the card refresh.
  $text=try{$stream=[IO.File]::Open($cfg,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete);try{[IO.StreamReader]::new($stream).ReadToEnd()}finally{$stream.Dispose()}}catch{''}
  $m=[regex]::Match($text,'(?m)^InstalledPackagesPath\s+"([^"]+)"')
  if($m.Success -and (Test-Path -LiteralPath $m.Groups[1].Value -PathType Container)){return (Join-Path $m.Groups[1].Value 'Community')}
 }
 return ''
}

# Runs one of the author's patch scripts with the release's bundled Python.
function StopAtmosphereModProcessTree([int]$Id){try{$null=& "$env:SystemRoot\System32\taskkill.exe" /PID $Id /T /F 2>&1}catch{}}
function InvokeAtmosphereModPython($Parts,[string[]]$Arguments,[scriptblock]$Pump,[double]$TimeoutMinutes=30){
 $quoted=@('-X','utf8')+$Arguments|ForEach-Object {if($_ -match '[\s"]'){'"'+($_ -replace '"','\"')+'"'}else{$_}}
 $info=New-Object Diagnostics.ProcessStartInfo($Parts.Python,($quoted -join ' '))
 $info.WorkingDirectory=$Parts.Installer;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
 $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.RedirectStandardInput=$true
 $p=[Diagnostics.Process]::Start($info)
 try{
  $p.StandardInput.Close()
  $out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
  $deadline=[DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
  while(-not $p.HasExited){
   if([DateTime]::UtcNow -gt $deadline){StopAtmosphereModProcessTree $p.Id;throw ('AtmosphereMod''s shader patcher did not finish within '+$TimeoutMinutes+' minutes and was stopped. Nothing was changed; try again, and send a report if it happens again.')}
   if($Pump){& $Pump};Start-Sleep -Milliseconds 150
  }
  $p.WaitForExit()
  return [pscustomobject]@{ExitCode=$p.ExitCode;Output=($out.Result+$err.Result).Trim()}
 }finally{if(-not $p.HasExited){StopAtmosphereModProcessTree $p.Id};$p.Dispose()}
}

# The patch driver: patch_all(root=work, dxc=dxc, strict=False), as the mod's
# installer calls it. 0.6.0 patches in "spawn" worker processes, which import
# this script again: without the __main__ guard every worker restarted the
# whole patch, forever.
function GetAtmosphereModPatchDriver{return "import sys, contextlib, io, multiprocessing`nfrom pathlib import Path`nif __name__ == '__main__':`n    multiprocessing.freeze_support()`n    sys.path.insert(0, sys.argv[1])`n    import patch_dxil`n    buffer = io.StringIO()`n    with contextlib.redirect_stdout(buffer):`n        failed = patch_dxil.patch_all(root=Path(sys.argv[2]), dxc=Path(sys.argv[3]), strict=False)`n    print(buffer.getvalue())`n    print('OPTISHADE-FAILED', failed)`n"}

# Extracts the sim's shaders from its pack and patches them, exactly as the
# mod's installer does; the patched shaders go to <data>\shaders.
function InvokeAtmosphereModPatch($Parts,[string]$Pack,[string]$Data,[scriptblock]$Pump,[IO.TextWriter]$Log){
 AssertAtmosphereModCompiler $Parts
 $work=Join-Path $Data 'work'
 if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force}
 New-Item -ItemType Directory -Path (Join-Path $work 'shaders') -Force|Out-Null
 Copy-Item -LiteralPath $Parts.Manifest -Destination (Join-Path $work 'shaders\manifest.json')
 try{
  $extract=InvokeAtmosphereModPython $Parts @((Join-Path $Parts.Installer 'extract_pak.py'),'--pak',$Pack,'--out',(Join-Path $work 'extracted')) $Pump
  $Log.WriteLine($extract.Output)
  if($extract.ExitCode -ne 0){throw ('Extracting the sim''s shaders failed: '+(@($extract.Output -split "`r?`n"|Where-Object {$_.Trim()})|Select-Object -Last 1))}
  # The installer's own call: patch_all(root=work, dxc=dxc, strict=False).
  $driver=Join-Path $work 'optishade_patch.py'
  [IO.File]::WriteAllText($driver,(GetAtmosphereModPatchDriver),[Text.UTF8Encoding]::new($false))
  $patch=InvokeAtmosphereModPython $Parts @($driver,$Parts.Installer,$work,$Parts.Dxc) $Pump
  $Log.WriteLine($patch.Output)
  $failedLine=[regex]::Match($patch.Output,'(?m)^OPTISHADE-FAILED (\d+)')
  if($patch.ExitCode -ne 0 -or -not $failedLine.Success){throw ('Patching the sim''s shaders failed: '+(@($patch.Output -split "`r?`n"|Where-Object {$_.Trim()})|Select-Object -Last 1))}
  $shaders=Join-Path $Data 'shaders'
  if(Test-Path -LiteralPath $shaders){Remove-Item -LiteralPath $shaders -Recurse -Force}  # stale patches from an older sim version
  New-Item -ItemType Directory -Path $shaders -Force|Out-Null
  $made=@(Get-ChildItem -LiteralPath (Join-Path $work 'build\shaders') -Filter '*.cso' -File -ErrorAction SilentlyContinue)
  foreach($f in $made){Move-Item -LiteralPath $f.FullName -Destination (Join-Path $shaders $f.Name)}
  $rows=@(Import-Csv -LiteralPath (Join-Path $work 'extracted\index.csv'))
  $names=@($rows|ForEach-Object {[string]$_.crc32+"`t"+[string]$_.entry}|Sort-Object -Unique)
  [IO.File]::WriteAllText((Join-Path $Data 'shader_names.tsv'),($names -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
  # A release may also carry replacement shaders of its own.
  $packCrcs=@{};foreach($r in $rows){$packCrcs[[string]$r.crc32]=$true}
  $ours=@(Get-ChildItem -LiteralPath $Parts.Shaders -Filter '*.cso' -File -ErrorAction SilentlyContinue)
  foreach($f in $ours){Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $shaders $f.Name) -Force}
  return [pscustomobject]@{Patched=$made.Count;Failed=[int]$failedLine.Groups[1].Value;Replaced=@($ours|Where-Object {$packCrcs.ContainsKey($_.BaseName)}).Count}
 }finally{Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}  # the extracted game shaders are not kept
}

# The player's tunables.ini, plus every setting of the new defaults it lacks
# (with the comment lines above it), as the mod's installer merges them.
function MergeAtmosphereModTunables([string]$New,[string]$Old,[string]$Version){
 $key='^\s*([TRC]\d+)\s*='
 $have=@{};foreach($m in [regex]::Matches($Old,'(?m)'+$key)){$have[$m.Groups[1].Value]=$true}
 $added=@();$block=@();$out=@()
 foreach($line in ($New -split "`r?`n")){
  $m=[regex]::Match($line,$key)
  if(-not $m.Success){if($line.Trim().StartsWith(';')){$block=@($block)+@($line)}else{$block=@()};continue}
  if(-not $have.ContainsKey($m.Groups[1].Value)){$added+=$m.Groups[1].Value;$out+=@($block)+@($line)}
  $block=@()
 }
 if(-not $added.Count){return [pscustomobject]@{Text=$Old;Added=@()}}
 return [pscustomobject]@{Text=($Old.TrimEnd("`r","`n")+"`n`n; ---- added by OptiShade for AtmosphereMod "+$Version+' ('+(Get-Date -Format 'yyyy-MM-dd')+"): settings new in this version`n"+($out -join "`n")+"`n");Added=$added}
}

# Sets one key in [ATMOSPHEREMOD], adding the section at the end if needed.
function SetAtmosphereModIniKey([string]$Text,[string]$Key,[string]$Value){
 $line=$Key+'='+$Value
 $section=[regex]::Match($Text,'(?m)^\['+$script:AtmosphereModSection+'\][^\[]*')
 if(-not $section.Success){return $Text.TrimEnd("`r","`n")+"`n`n["+$script:AtmosphereModSection+"]`n"+$line+"`n"}
 $body=$section.Value
 if([regex]::IsMatch($body,'(?m)^'+[regex]::Escape($Key)+'=.*$')){$body=[regex]::Replace($body,'(?m)^'+[regex]::Escape($Key)+'=.*$',$line.Replace('$','$$'))}
 else{$body=$body.TrimEnd("`r","`n")+"`n"+$line+"`n`n"}
 return $Text.Substring(0,$section.Index)+$body+$Text.Substring($section.Index+$section.Length)
}
function RemoveAtmosphereModIniSection([string]$Text){return [regex]::Replace($Text,'(?m)^\['+$script:AtmosphereModSection+'\][^\[]*','')}

# Removes the EFB app. A link (an add-on linker's) is removed as a link: its
# target folder, the player's add-on library, is never deleted through it.
function RemoveAtmosphereModPackage([string]$Target){
 if(-not(Test-Path -LiteralPath $Target)){return $null}
 $item=Get-Item -LiteralPath $Target -Force
 if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){$linked=[string]$item.Target;[IO.Directory]::Delete($Target,$false);return $(if($linked){$linked}else{'another folder'})}
 Remove-Item -LiteralPath $Target -Recurse -Force;return $null
}
function InstallAtmosphereModEfb([string]$Source,[string]$Community){
 $target=Join-Path $Community $script:AtmosphereModEfb
 New-Item -ItemType Directory -Path $Community -Force|Out-Null
 $linked=RemoveAtmosphereModPackage $target
 Copy-Item -LiteralPath $Source -Destination $target -Recurse
 if($linked -and (Get-Command WriteInstallerLog -ErrorAction SilentlyContinue)){WriteInstallerLog ('AtmosphereMod EFB app: '+$target+' was a link to '+$linked+'; the link was replaced by a real folder and the linked folder was not changed')}
}
# The EFB app's presets (0.6.0): Default is this version's defaults; the
# player's own presets get the settings new in this version.
function UpdateAtmosphereModPresets([string]$Defaults,[string]$DataFolder,[string]$Version){
 $presets=Join-Path $DataFolder 'presets';New-Item -ItemType Directory -Path $presets -Force|Out-Null
 [IO.File]::WriteAllText((Join-Path $presets 'Default.ini'),$Defaults,[Text.UTF8Encoding]::new($false))
 foreach($preset in @(Get-ChildItem -LiteralPath $presets -Filter '*.ini' -File|Where-Object {$_.Name -ne 'Default.ini'})){
  try{$merged=MergeAtmosphereModTunables $Defaults ([IO.File]::ReadAllText($preset.FullName)) $Version;if($merged.Added.Count){[IO.File]::WriteAllText($preset.FullName,$merged.Text,[Text.UTF8Encoding]::new($false))}}catch{}
 }
}

function AssertAtmosphereModTarget([string]$Game){
 if(-not(Test-Path -LiteralPath (Join-Path $Game 'FlightSimulator2024.exe') -PathType Leaf)){throw 'AtmosphereMod is for Microsoft Flight Simulator 2024 only.'}
 if(-not(Test-Path -LiteralPath (Join-Path $Game 'ReShade64.dll') -PathType Leaf)){throw 'Install OptiShade for this game first: AtmosphereMod loads through OptiShade''s ReShade.'}
 if(Get-Command AssertClosed -ErrorAction SilentlyContinue){AssertClosed $Game}
}

# Install, or re-patch after a sim update. $Patcher is replaced only by tests.
function InstallAtmosphereMod([string]$Game,[scriptblock]$Pump,$Release=$null,[string]$DataFolder=(GetAtmosphereModDataFolder),[scriptblock]$Patcher={param($parts,$pack,$data,$pump,$log) InvokeAtmosphereModPatch $parts $pack $data $pump $log},[string]$Community=$null,$Expanded=$null){
 AssertAtmosphereModTarget $Game
 $pack=GetAtmosphereModShaderPack $Game
 $opened=if($Expanded){$Expanded}else{ExpandAtmosphereModRelease $Pump $Release}
 try{
  $parts=GetAtmosphereModParts $opened.Root
  New-Item -ItemType Directory -Path (Join-Path $DataFolder 'logs') -Force|Out-Null
  $log=[IO.StreamWriter]::new((Join-Path $DataFolder 'logs\install.log'),$false,[Text.UTF8Encoding]::new($false))
  try{
   $log.WriteLine('AtmosphereMod '+$parts.Version+' installed by OptiShade, '+(Get-Date -Format 'yyyy-MM-dd HH:mm'));$log.WriteLine('sim '+$Game);$log.WriteLine('pak '+$pack);$log.WriteLine('reshade ReShade64.dll (OptiShade)');$log.WriteLine('dxc '+$parts.Dxc);$log.WriteLine('')
   $result=& $Patcher $parts $pack $DataFolder $Pump $log
   $log.WriteLine('Shaders: '+$result.Patched+' patched, '+$result.Failed+' not patched, '+$result.Replaced+' replaced')
  }finally{$log.Dispose()}

  # Settings: keep the player's; restore the copy kept by an earlier Uninstall.
  $defaults=[IO.File]::ReadAllText($parts.Tunables)
  Copy-Item -LiteralPath $parts.Tunables -Destination (Join-Path $DataFolder 'tunables.default.ini') -Force
  $tunables=Join-Path $DataFolder 'tunables.ini';$saved=Join-Path (GetAtmosphereModBackupFolder) 'tunables.ini'
  if(-not(Test-Path -LiteralPath $tunables) -and (Test-Path -LiteralPath $saved -PathType Leaf)){Copy-Item -LiteralPath $saved -Destination $tunables}
  if(Test-Path -LiteralPath $tunables -PathType Leaf){$merged=MergeAtmosphereModTunables $defaults ([IO.File]::ReadAllText($tunables)) $parts.Version;[IO.File]::WriteAllText($tunables,$merged.Text,[Text.UTF8Encoding]::new($false))}
  else{[IO.File]::WriteAllText($tunables,$defaults,[Text.UTF8Encoding]::new($false))}
  UpdateAtmosphereModPresets $defaults $DataFolder $parts.Version

  # The add-on beside OptiShade's ReShade, and its settings in ReShade.ini.
  Copy-Item -LiteralPath $parts.Addon -Destination (Join-Path $Game $script:AtmosphereModAddon) -Force
  $ini=Join-Path $Game 'ReShade.ini'
  if((Test-Path -LiteralPath $ini) -and -not(Test-Path -LiteralPath (Join-Path $Game $script:AtmosphereModIniBackup))){Copy-Item -LiteralPath $ini -Destination (Join-Path $Game $script:AtmosphereModIniBackup)}
  $text=if(Test-Path -LiteralPath $ini){[IO.File]::ReadAllText($ini)}else{''}
  foreach($pair in @(@('DataPath',$DataFolder),@('TunablesPath',$tunables),@('InjectRootSignature','1'),@('InjectGraphicsRootSignature','1'))){$text=SetAtmosphereModIniKey $text $pair[0] $pair[1]}
  [IO.File]::WriteAllText($ini,$text,[Text.UTF8Encoding]::new($false))

  # The EFB sim bridge: METAR passing and the tablet settings.
  # [string] turns an omitted $null into '', so test for empty, not $null: the
  # first manager installs skipped the lookup and never installed the bridge.
  if([string]::IsNullOrEmpty($Community)){$Community=GetAtmosphereModCommunityFolder $Game}
  if($Community){InstallAtmosphereModEfb $parts.Efb $Community}

  # The same record the mod's installer writes, so its own uninstaller works too.
  $record=[ordered]@{version=$parts.Version;date=(Get-Date -Format 'yyyy-MM-dd HH:mm');sim=$Game;reshade='ReShade64.dll, loaded by OptiShade';community=$(if($Community){$Community}else{$null})
   data=$DataFolder;pak=[IO.Path]::GetFileName($pack);patched=$result.Patched;failed=$result.Failed;installedBy='OptiShade'}
  [IO.File]::WriteAllText((Join-Path $DataFolder 'install.json'),($record|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
  if(Get-Command WriteInstallerLog -ErrorAction SilentlyContinue){WriteInstallerLog ('AtmosphereMod '+$parts.Version+' installed for '+$Game+': '+$result.Patched+' shaders patched, '+$result.Failed+' left stock; EFB bridge '+$(if($Community){$Community}else{'not installed (Community folder not found)'}))}
 }finally{if(-not $Expanded){Remove-Item -LiteralPath $opened.Work -Recurse -Force -ErrorAction SilentlyContinue}}
 return GetAtmosphereModState $Game $DataFolder
}

# Finishes an existing install (OptiShade's or the mod's own installer's) with
# the least work: missing ReShade.ini settings are written in place, a missing
# EFB app comes from the installed version's release, and only a sim update
# re-patches the shaders.
function RepairAtmosphereMod([string]$Game,[scriptblock]$Pump,[string]$DataFolder=(GetAtmosphereModDataFolder),[scriptblock]$Request=$null,[scriptblock]$Install={param($game,$pump,$data) InstallAtmosphereMod $game $pump $null $data}){
 $state=GetAtmosphereModState $Game $DataFolder
 if(-not $state.Installed){throw 'AtmosphereMod is not installed for this game.'}
 if($state.NeedsRepatch -or -not $state.Version){return & $Install $Game $Pump $DataFolder}
 AssertAtmosphereModTarget $Game
 $done=@()
 if(-not $state.SectionPresent){
  $ini=Join-Path $Game 'ReShade.ini';$text=if(Test-Path -LiteralPath $ini){[IO.File]::ReadAllText($ini)}else{''}
  foreach($pair in @(@('DataPath',$DataFolder),@('TunablesPath',(Join-Path $DataFolder 'tunables.ini')),@('InjectRootSignature','1'),@('InjectGraphicsRootSignature','1'))){$text=SetAtmosphereModIniKey $text $pair[0] $pair[1]}
  [IO.File]::WriteAllText($ini,$text,[Text.UTF8Encoding]::new($false));$done+='ReShade.ini settings restored'
 }
 if(-not $state.Community -and $state.CommunityAvailable){
  $community=GetAtmosphereModCommunityFolder $Game
  $opened=ExpandAtmosphereModRelease $Pump (GetAtmosphereModLatestRelease $Request $state.Version)
  try{InstallAtmosphereModEfb (GetAtmosphereModParts $opened.Root).Efb $community}finally{Remove-Item -LiteralPath $opened.Work -Recurse -Force -ErrorAction SilentlyContinue}
  $recordPath=Join-Path $DataFolder 'install.json'
  try{$record=Get-Content -LiteralPath $recordPath -Raw|ConvertFrom-Json;$record.community=$community;[IO.File]::WriteAllText($recordPath,($record|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}catch{}
  $done+=('EFB app installed in '+$community)
 }
 if($done.Count -and (Get-Command WriteInstallerLog -ErrorAction SilentlyContinue)){WriteInstallerLog ('AtmosphereMod '+$state.Version+' finished for '+$Game+': '+($done -join '; '))}
 return GetAtmosphereModState $Game $DataFolder
}

# Removes exactly what the install added. The player's tunables.ini is kept in
# OptiShade's backups and comes back on the next install.
function UninstallAtmosphereMod([string]$Game,[scriptblock]$Pump,[string]$DataFolder=(GetAtmosphereModDataFolder)){
 if(Get-Command AssertClosed -ErrorAction SilentlyContinue){AssertClosed $Game}
 $recordPath=Join-Path $DataFolder 'install.json';$record=$null
 if(Test-Path -LiteralPath $recordPath -PathType Leaf){try{$record=Get-Content -LiteralPath $recordPath -Raw|ConvertFrom-Json}catch{}}
 $addon=Join-Path $Game $script:AtmosphereModAddon
 if(Test-Path -LiteralPath $addon){Remove-Item -LiteralPath $addon -Force}
 $ini=Join-Path $Game 'ReShade.ini'
 if(Test-Path -LiteralPath $ini -PathType Leaf){$text=[IO.File]::ReadAllText($ini);if($text -match ('(?m)^\['+$script:AtmosphereModSection+'\]')){[IO.File]::WriteAllText($ini,(RemoveAtmosphereModIniSection $text),[Text.UTF8Encoding]::new($false))}}
 $community=if($record -and $record.community){[string]$record.community}else{GetAtmosphereModCommunityFolder $Game}
 if($community){$null=RemoveAtmosphereModPackage (Join-Path $community $script:AtmosphereModEfb)}
 $tunables=Join-Path $DataFolder 'tunables.ini'
 if(Test-Path -LiteralPath $tunables -PathType Leaf){
  $backup=GetAtmosphereModBackupFolder;New-Item -ItemType Directory -Path $backup -Force|Out-Null
  Copy-Item -LiteralPath $tunables -Destination (Join-Path $backup 'tunables.ini') -Force
 }
 # Only the record's own sim: another copy of the sim may still use the data folder.
 if(-not $record -or (TestAtmosphereModSameFolder ([string]$record.sim) $Game)){if(Test-Path -LiteralPath $DataFolder){Remove-Item -LiteralPath $DataFolder -Recurse -Force}}
 if(Get-Command WriteInstallerLog -ErrorAction SilentlyContinue){WriteInstallerLog ('AtmosphereMod removed from '+$Game+'; tunables.ini kept in OptiShade backups')}
 return GetAtmosphereModState $Game $DataFolder
}

# Read-only comparison; AtmosphereMod maintains its own installation record.
function GetAtmosphereModUpdateInfo($State,$Release){
 $installed=[bool]($State -and $State.Installed)
 $version=$null
 $known=$installed -and [version]::TryParse([string]$State.Version,[ref]$version)
 [pscustomobject]@{Installed=$installed;InstalledVersion=$(if($State){[string]$State.Version}else{''});LatestVersion=$(if($Release){[string]$Release.VersionText}else{''});Available=[bool]($known -and $Release -and $version -lt [version]$Release.VersionText);UnknownVersion=[bool]($installed -and -not $known)}
}
