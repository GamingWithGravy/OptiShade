# Keep the app and Desktop names readable. Public asset names also retain the
# legacy variant understood by already-installed launchers.
function GetOptiShadeManagerName([string]$Version,[string]$Channel){
 if($Version -notmatch '^\d+\.\d+(?:\.\d+){0,2}(?:-(?:alpha|beta|rc)(?:[.-]?\d+)?)?$' -or $Channel -notin @('stable','beta')){throw 'Invalid manager version or channel.'}
 $display=if($Channel -eq 'beta'){$Version -replace '-beta(?:[.-]?\d+)?$',''}else{$Version}
 return "Optishade $display $Channel.exe"
}
function GetOptiShadeReleaseAssetNames([string]$Version,[string]$Channel){
 $readable=GetOptiShadeManagerName $Version $Channel
 $legacyReadable="Optishade $Version $Channel.exe"
 @($readable,$readable.Replace(' ','.'),$legacyReadable,$legacyReadable.Replace(' ','.'),"OptiShade_Version_$Version.exe")|Select-Object -Unique
}
function GetOptiShadeDisplayVersion([string]$Version){
 return $Version -replace '-beta(?:[.-]?\d+)?$',' beta'
}
function TestOptiShadeChannelChange([string]$InstalledVersion,[string]$BundledVersion){
 foreach($version in @($InstalledVersion,$BundledVersion)){if($version -notmatch '^P?\d+\.\d+(?:\.\d+){0,2}(?:-(?:alpha|beta|rc)(?:[.-]?\d+)?)?(?:-MSFS24)?$'){return $false}}
 return (($InstalledVersion -match '-(?:alpha|beta|rc)') -ne ($BundledVersion -match '-(?:alpha|beta|rc)'))
}
function AssertOptiShadeDownloadChannel([string]$Channel,[string]$Store){
 if($Channel -notin @('stable','beta')){throw 'Invalid download channel.'}
 if($Channel -eq 'beta' -and -not(Test-Path -LiteralPath (Join-Path $Store 'beta-updates.txt'))){throw 'Beta opt-in is off. No beta download was started.'}
}
function AssertOptiShadeUpdateRequest($Settings,[string]$Store){
 $version=[string]$Settings.Version
 $channel=if($version -match '-(?:alpha|beta|rc)'){'beta'}else{'stable'}
 $name=GetOptiShadeManagerName $version $channel
 if($Settings.InstalledChannel -notin @('stable','beta') -or $Settings.Channel -ne $channel){throw 'The update channel information is invalid. Check for updates again.'}
 $explicitReturn=$Settings.ExplicitReturnToStable -eq $true
 if($explicitReturn -and ($channel -ne 'stable' -or $Settings.Rollback -ne $true)){throw 'Invalid return-to-stable request.'}
 if($Settings.InstalledChannel -eq 'beta' -and $channel -eq 'stable' -and -not $explicitReturn){throw 'Beta checks only download beta builds. Use Return to stable to leave beta.'}
 if(-not $explicitReturn){
  $selected=if(Test-Path -LiteralPath (Join-Path $Store 'beta-updates.txt')){'beta'}else{'stable'}
  if($selected -ne $channel){throw 'The download channel changed. Check for updates again.'}
 }
 AssertOptiShadeDownloadChannel $channel $Store
 $uri=[uri]$Settings.Url
 $validPath=$false
 foreach($asset in (GetOptiShadeReleaseAssetNames $version $channel)){
  foreach($tag in @($version,('v'+$version))){if([uri]::UnescapeDataString($uri.AbsolutePath) -ceq "/GamingWithGravy/OptiShade/releases/download/$tag/$asset"){$validPath=$true}}
 }
 if($uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or -not $validPath -or $Settings.SHA256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'Invalid release download information.'}
 return $channel
}
function TestOptiShadeManagerFile([string]$Path,[string]$Hash){
 if(-not [IO.Path]::IsPathRooted($Path) -or [IO.Path]::GetExtension($Path) -ne '.exe' -or $Hash -notmatch '^[a-fA-F0-9]{64}$'){return $false}
 $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
 if($item.PSIsContainer){return $false}
 $part=$item
 while($part){
  if($part.Attributes -band [IO.FileAttributes]::ReparsePoint){return $false}
  $part=if($part -is [IO.FileInfo]){$part.Directory}else{$part.Parent}
 }
 return (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash -eq $Hash
}
function CompleteOptiShadeManagerUpdate([string]$Previous,[string]$PreviousHash,[string]$Destination,[string]$ExpectedHash,[string]$Store,[string]$Channel,[scriptblock]$OnWait={},[string]$Version=''){
 if($Channel -notin @('stable','beta')){throw 'Invalid update channel.'}
 $dest=[IO.Path]::GetFullPath($Destination)
 if(-not(TestOptiShadeManagerFile $dest $ExpectedHash)){throw 'New manager verification failed; previous manager retained.'}
 if($Version){WriteOptiShadeManagerReceipt $dest $ExpectedHash $Store $Channel $Version}
 $marker=Join-Path $Store 'beta-updates.txt'
 $stable=Join-Path $Store 'stable-updates.txt'
 [void][IO.Directory]::CreateDirectory($Store)
 if($Channel -eq 'beta'){[IO.File]::WriteAllText($marker,'Opted into prerelease update offers');if(Test-Path -LiteralPath $stable){Remove-Item -LiteralPath $stable -Force}}
 else{[IO.File]::WriteAllText($stable,'Explicitly selected stable updates');if(Test-Path -LiteralPath $marker){Remove-Item -LiteralPath $marker -Force}}
 if(-not $Previous){return ''}
 $old=[IO.Path]::GetFullPath($Previous)
 if($old -eq $dest -or -not(Test-Path -LiteralPath $old)){return ''}
 if([IO.Path]::GetExtension($old) -ne '.exe' -or $PreviousHash -notmatch '^[a-fA-F0-9]{64}$'){return 'The previous EXE could not be verified and was kept at: '+$old}
 for($attempt=0;$attempt -lt 150;$attempt++){
  try{
   if(-not(Test-Path -LiteralPath $old)){return ''}
   if(-not(TestOptiShadeManagerFile $old $PreviousHash)){return 'The previous EXE changed or is linked and was kept at: '+$old}
   Remove-Item -LiteralPath $old -Force -ErrorAction Stop;return ''
  }catch{& $OnWait;Start-Sleep -Milliseconds 200}
 }
 return 'The previous EXE is still open and could not be removed: '+$old
}
function AssertOptiShadeReceiptPath([string]$Path){
 $part=[IO.Path]::GetFullPath($Path)
 while($part){
  if(Test-Path -LiteralPath $part){if((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The manager receipt location is linked. Manager cleanup was stopped.'}}
  $parent=Split-Path $part -Parent;if($parent -eq $part){break};$part=$parent
 }
}
function WriteOptiShadeManagerReceipt([string]$Installer,[string]$Hash,[string]$Store,[string]$Channel,[string]$Version){
 [void](GetOptiShadeManagerName $Version $Channel)
 $expectedChannel=if($Version -match '-(?:alpha|beta|rc)'){'beta'}else{'stable'}
 if($Channel -ne $expectedChannel -or -not(TestOptiShadeManagerFile $Installer $Hash)){throw 'The installed manager could not be verified. Previous manager retained.'}
 $path=Join-Path $Store 'manager-installed.json';AssertOptiShadeReceiptPath $path
 [void][IO.Directory]::CreateDirectory($Store)
 $temporary=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 try{
  @{Schema=1;Status='Installed';Installer=[IO.Path]::GetFullPath($Installer);SHA256=$Hash;Version=$Version;Channel=$Channel;CompletedUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath $temporary -Encoding UTF8
  Move-Item -LiteralPath $temporary -Destination $path -Force
 }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
}
function CompleteOptiShadeManualInstall([string]$ManifestPath,[string]$Installer,[string]$Version,[string]$Store,$PreviousManifest,[scriptblock]$OnWait={}){
 if($env:OPTISHADE_PORTABLE -eq '1'){return ''}
 $manifest=Get-Content -LiteralPath $ManifestPath -Raw|ConvertFrom-Json
 if($manifest.Status -ne 'Installed' -or $manifest.Version -cne $Version -or [IO.Path]::GetFullPath($manifest.Installer) -ne [IO.Path]::GetFullPath($Installer)){throw 'Installation did not confirm this manager. Previous manager retained.'}
 $path=Join-Path $Store 'manager-installed.json';AssertOptiShadeReceiptPath $path
 $previous='';$previousHash='';$notice=''
 if(Test-Path -LiteralPath $path){
  $record=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
  if($record.Schema -ne 1 -or $record.Status -ne 'Installed' -or $record.Channel -notin @('stable','beta') -or $record.SHA256 -notmatch '^[a-fA-F0-9]{64}$' -or -not [IO.Path]::IsPathRooted([string]$record.Installer)){throw 'The previous manager receipt is invalid. Previous manager retained.'}
  $previous=[string]$record.Installer;$previousHash=[string]$record.SHA256
 }elseif($PreviousManifest.Installer -and [IO.Path]::GetFullPath($PreviousManifest.Installer) -ne [IO.Path]::GetFullPath($Installer)){
  $notice='The previous EXE has no recorded verification hash and was kept at: '+$PreviousManifest.Installer
 }
 $channel=if($Version -match '-(?:alpha|beta|rc)'){'beta'}else{'stable'}
 $hash=(Get-FileHash -LiteralPath $Installer -Algorithm SHA256).Hash
 $cleanup=CompleteOptiShadeManagerUpdate $previous $previousHash $Installer $hash $Store $channel $OnWait ($Version -replace '^P','')
 return (($notice,$cleanup|Where-Object {$_}) -join ' ')
}
