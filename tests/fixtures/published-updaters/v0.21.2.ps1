# Exact function bodies from GamingWithGravy/OptiShade v0.21.2.
# Source commit: d212ebea17a53646f94ccf8c9a6a36d00c4135fa
# Tests deliberately preserve historical client behavior.
function GetOptiShadeUpdateChannel {
 $root=if($env:OPTISHADE_STORE){$env:OPTISHADE_STORE}else{Join-Path $env:LOCALAPPDATA 'OptiShade'}
 if(Test-Path -LiteralPath (Join-Path $root 'beta-updates.txt')){'beta'}else{'stable'}
}
function SetOptiShadeUpdateChannel([bool]$Beta){
 $root=if($env:OPTISHADE_STORE){$env:OPTISHADE_STORE}else{Join-Path $env:LOCALAPPDATA 'OptiShade'}
 $marker=Join-Path $root 'beta-updates.txt'
 if($Beta){[void][IO.Directory]::CreateDirectory($root);[IO.File]::WriteAllText($marker,'Opted into prerelease update offers')}
 elseif(Test-Path -LiteralPath $marker){Remove-Item -LiteralPath $marker -Force}
}
function GetBetaVersionKey([string]$Value){
 if($Value -notmatch '^v?(\d+\.\d+(?:\.\d+){0,2})(?:-(alpha|beta|rc)[.-]?(\d*))?$'){return $null}
 $stage=if($Matches[2]){@{alpha=0;beta=1;rc=2}[$Matches[2]]}else{3}
 $revision=if($Matches[3]){[int]$Matches[3]}else{0}
 [pscustomobject]@{Numeric=[version]$Matches[1];Stage=$stage;Revision=$revision}
}
function GetOptiShadeUpdate([string]$Current='0.21.2',[switch]$ReportErrors,[ValidateSet('stable','beta')][string]$InstalledChannel='stable'){
 [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
 try{
  $channel=GetOptiShadeUpdateChannel
  $currentKey=GetBetaVersionKey $Current
  if(-not $currentKey){throw 'Invalid current version'}
  $releases=@(Invoke-RestMethod 'https://api.github.com/repos/GamingWithGravy/OptiShade/releases?per_page=100' -Headers @{'User-Agent'='OptiShade-beta-update-check'} -TimeoutSec 12)
  $candidates=@(foreach($release in $releases){
   if($release.draft -or ([bool]$release.prerelease -ne ($channel -eq 'beta'))){continue}
   $version=([string]$release.tag_name) -replace '^v','';$key=GetBetaVersionKey $version
   if(-not $key -or ($channel -eq 'beta' -and $key.Stage -eq 3) -or ($channel -eq 'stable' -and $key.Stage -ne 3)){continue}
   if(-not ($channel -eq 'stable' -and ($InstalledChannel -eq 'beta' -or $currentKey.Stage -ne 3)) -and ($key.Numeric -lt $currentKey.Numeric -or ($key.Numeric -eq $currentKey.Numeric -and ($key.Stage -lt $currentKey.Stage -or ($key.Stage -eq $currentKey.Stage -and $key.Revision -le $currentKey.Revision))))){continue}
   $assets=@($release.assets|Where-Object {$_.name -eq "OptiShade_Version_$version.exe" -and $_.digest -match '^sha256:[a-fA-F0-9]{64}$'})
   if($assets.Count -ne 1){continue}
   $url=[uri]$assets[0].browser_download_url
   if($url.Scheme -ne 'https' -or $url.Host -ne 'github.com' -or $url.AbsolutePath -cne "/GamingWithGravy/OptiShade/releases/download/$($release.tag_name)/OptiShade_Version_$version.exe"){continue}
   [pscustomobject]@{Version=$version;Url=$url.AbsoluteUri;SHA256=$assets[0].digest.Substring(7);Notes=[string]$release.body;Prerelease=[bool]$release.prerelease;Channel=$channel;ReleaseUrl="https://github.com/GamingWithGravy/OptiShade/releases/tag/$($release.tag_name)";Rollback=($channel -eq 'stable' -and ($InstalledChannel -eq 'beta' -or $currentKey.Stage -ne 3));Numeric=$key.Numeric;Stage=$key.Stage;Revision=$key.Revision}
  })
  $candidates|Sort-Object Numeric,Stage,Revision -Descending|Select-Object -First 1
 }catch{if($ReportErrors){throw 'Could not check the selected update channel on GitHub. Check your connection and try again.'};return $null}
}
