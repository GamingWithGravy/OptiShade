function GetOptiShadeUpdate([string]$Current='0.20.8',[switch]$ReportErrors){
 [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
 try{
  $release=Invoke-RestMethod 'https://api.github.com/repos/GamingWithGravy/OptiShade/releases/latest' -Headers @{'User-Agent'='OptiShade-update-check'} -TimeoutSec 12
  if($release.draft -or $release.prerelease -or $release.tag_name -notmatch '^v?(\d+\.\d+(?:\.\d+)?)$'){return $null}
  $version=$Matches[1];if([version]$version -le [version]$Current){return $null}
  $asset=@($release.assets|Where-Object {$_.name -eq "OptiShade_Version_$version.exe" -and $_.digest -match '^sha256:[a-fA-F0-9]{64}$'})
  if($asset.Count -ne 1){return $null}
  $url=[uri]$asset[0].browser_download_url
  if($url.Scheme -ne 'https' -or $url.Host -ne 'github.com' -or $url.AbsolutePath -cnotmatch '^/GamingWithGravy/(OptiShade|OptiShade_V0[.]19[.]17)/releases/download/'){return $null}
  [pscustomobject]@{Version=$version;Url=$url.AbsoluteUri;SHA256=$asset[0].digest.Substring(7);Notes=[string]$release.body}
 }catch{if($ReportErrors){throw 'Could not check GitHub. Check your connection and try again.'};return $null}
}
