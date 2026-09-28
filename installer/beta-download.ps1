# Beta is fetched only from an immutable commit of the opt-in source branch.
function GetOptiShadeBetaCandidate([string]$Current){
 if((GetOptiShadeUpdateChannel) -ne 'beta'){return $null}
 $headers=@{'User-Agent'='OptiShade-beta-branch'}
 $commit=Invoke-RestMethod 'https://api.github.com/repos/GamingWithGravy/OptiShade/commits/beta' -Headers $headers -TimeoutSec 15
 if([string]$commit.sha -notmatch '^[a-fA-F0-9]{40}$'){throw 'Invalid beta branch commit.'}
 $prefix="https://raw.githubusercontent.com/GamingWithGravy/OptiShade/$($commit.sha)/downloads/beta/"
 $manifest=Invoke-RestMethod ($prefix+'manifest.json') -Headers $headers -TimeoutSec 15
 if($manifest.schema -ne 1 -or $manifest.channel -cne 'beta' -or $manifest.version -notmatch '^\d+\.\d+\.\d+-beta\.\d+$' -or $manifest.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $manifest.bytes -le 0 -or $manifest.bytes -gt 512MB){throw 'Invalid beta download manifest.'}
 $key=GetBetaVersionKey $manifest.version;$currentKey=GetBetaVersionKey $Current
 if(-not $key -or -not $currentKey){throw 'Invalid beta version.'}
 # Explicitly changing channel can install the beta of the same stable version.
 if($currentKey.Stage -lt 3 -and ($key.Numeric -lt $currentKey.Numeric -or ($key.Numeric -eq $currentKey.Numeric -and $key.Revision -le $currentKey.Revision))){return $null}
 if($currentKey.Stage -eq 3 -and $key.Numeric -lt $currentKey.Numeric){return $null}
 $parts=@();$bytes=0L;$index=0
 foreach($part in $manifest.parts){
  $index++;$expected='OptiShade-beta.part'+$index.ToString('00')
  if($index -gt 16 -or $part.name -cne $expected -or $part.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $part.bytes -le 0 -or $part.bytes -gt 48MB){throw 'Invalid beta download part.'}
  $bytes+=[long]$part.bytes;$parts+=[pscustomobject]@{Url=$prefix+$part.name;SHA256=[string]$part.sha256;Bytes=[long]$part.bytes}
 }
 if(-not $parts.Count -or $bytes -ne $manifest.bytes){throw 'Incomplete beta download manifest.'}
 [pscustomobject]@{Version=[string]$manifest.version;Source='beta-branch';Commit=[string]$commit.sha;Url=$prefix+'manifest.json';Parts=$parts;Bytes=$bytes;SHA256=[string]$manifest.sha256;Notes=[string]$manifest.notes;Prerelease=$true;Channel='beta';Rollback=$false;ReleaseUrl='https://github.com/GamingWithGravy/OptiShade/tree/beta'}
}
function SaveOptiShadeBetaDownload($Update,[string]$Destination,[string]$Store,[scriptblock]$Progress){
 if(-not(Test-Path -LiteralPath (Join-Path $Store 'beta-updates.txt'))){throw 'Beta opt-in is off. No beta download was started.'}
 if($Update.Source -cne 'beta-branch' -or $Update.Channel -cne 'beta' -or $Update.Commit -notmatch '^[a-fA-F0-9]{40}$' -or $Update.SHA256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'Invalid beta download information.'}
 $prefix="https://raw.githubusercontent.com/GamingWithGravy/OptiShade/$($Update.Commit)/downloads/beta/"
 $parts=@($Update.Parts);$bytes=0L;$index=0
 if(-not $parts.Count -or $parts.Count -gt 16){throw 'Invalid beta part count.'}
 foreach($part in $parts){
  $index++
  if($part.Url -cne ($prefix+'OptiShade-beta.part'+$index.ToString('00')) -or $part.SHA256 -notmatch '^[a-fA-F0-9]{64}$' -or $part.Bytes -le 0 -or $part.Bytes -gt 48MB){throw 'Invalid beta part information.'}
  $bytes+=[long]$part.Bytes
 }
 if($bytes -ne $Update.Bytes -or $bytes -gt 512MB){throw 'Invalid beta download size.'}
 $created=$false;$temporary=$Destination+'.part-'+[guid]::NewGuid().ToString('N');$web=[Net.WebClient]::new();$output=$null;$complete=$false
 try{
  $output=[IO.File]::Open($Destination,[IO.FileMode]::CreateNew);$created=$true
  $index=0;$clock=[Diagnostics.Stopwatch]::StartNew();$web.Headers['User-Agent']='OptiShade-beta-branch'
  foreach($part in $parts){
   $index++;$task=$web.DownloadFileTaskAsync([uri]$part.Url,$temporary)
   while(-not $task.IsCompleted){
    if($clock.Elapsed.TotalMinutes -gt 15 -or ((Test-Path -LiteralPath $temporary) -and (Get-Item -LiteralPath $temporary).Length -gt $part.Bytes)){$web.CancelAsync();throw 'Beta download exceeded its size or time limit.'}
    if($Progress){&$Progress $index $parts.Count};Start-Sleep -Milliseconds 100
   }
   $task.GetAwaiter().GetResult()
   if((Get-Item -LiteralPath $temporary).Length -ne $part.Bytes -or (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -ne $part.SHA256){throw 'Beta download part failed verification.'}
   $input=[IO.File]::OpenRead($temporary);try{$input.CopyTo($output)}finally{$input.Dispose()}
   Remove-Item -LiteralPath $temporary -Force
  }
  $output.Dispose();$output=$null
  if((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ne $Update.SHA256){throw 'Assembled beta installer failed verification.'}
  $complete=$true
 }finally{
  if($output){$output.Dispose()};$web.Dispose()
  if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}
  if($created -and -not $complete -and (Test-Path -LiteralPath $Destination)){Remove-Item -LiteralPath $Destination -Force}
 }
}
