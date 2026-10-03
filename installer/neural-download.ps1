function GetObservedNeuralGpu([string]$Game,$Gpu){
 # Evidence from the previous selected-game session. Never treat a closed-game
 # log as live telemetry or resolve a different installation's adapter from it.
 $path=OwnedPath $Game 'OptiScaler.log'
 if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $null}
 $item=Get-Item -LiteralPath $path
 if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddDays(-7)){return $null}
 $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
 try{
  $n=[int][Math]::Min(262144,$stream.Length);[void]$stream.Seek(-$n,[IO.SeekOrigin]::End)
  $bytes=New-Object byte[] $n;$count=$stream.Read($bytes,0,$n);$text=[Text.Encoding]::UTF8.GetString($bytes,0,$count)
 }finally{$stream.Dispose()}
 $matches=[regex]::Matches($text,'(?m)NR rendering adapter: luid=([A-Fa-f0-9]{16}); vendor=10DE; device=([A-Fa-f0-9]{4}); software=false; name=([^\r\n]{1,160})\r?$')
 if(-not $matches.Count){return $null}
 $last=$matches[$matches.Count-1];$name=$last.Groups[3].Value.Trim()
 $cards=@($Gpu.Names -split ',\s*'|Where-Object {$_ -match '(?i)NVIDIA.*RTX'})
 if(@($cards|Where-Object {$_ -eq $name}).Count -ne 1){return $null}
 return [pscustomobject]@{Name=$name;Luid=$last.Groups[1].Value;Evidence='Previous selected-game rendering device; not live';ModifiedUtc=$item.LastWriteTimeUtc.ToString('o')}
}
function ResolveNeuralGpuChoice($Manifest,$Gpu){
 $observed=GetObservedNeuralGpu ([string]$Manifest.Game) $Gpu
 $selected=[string]$Manifest.NeuralGpuName
 if($observed){
  if($selected -and $selected -ne $observed.Name){throw ('The last recorded rendering GPU for this game is '+$observed.Name+', but '+$selected+' is selected. Choose the game GPU again before installing a model. No model was changed.')}
  return $observed.Name
 }
 return $selected
}
function GetNeuralDownload($Gpu,[string]$SelectedName){
 $cards=@($Gpu.Names -split ',\s*'|Where-Object {$_ -match '(?i)NVIDIA.*RTX'})
 if($SelectedName){if($SelectedName -notin $cards){throw 'The selected game GPU is no longer detected. Choose the game GPU again before downloading a model.'};$cards=@($SelectedName)}
 if($cards.Count -ne 1){throw 'Choose this game GPU in Advanced options before downloading its neural model. No model was changed.'}
 if($cards[0] -match 'RTX\s*50\d\d'){
  return [pscustomobject]@{Family='RTX 50';Url='https://github.com/RankFTW/rhi-repo/releases/download/dlssnr-310.8.0/nvngx_dlssnr_310.8.0.zip';ArchiveHash='388C0A7912E15EC911B9C9E11A692142B11FE387DDF2B637D8C358138FFFB3AC';ModelHash='E16BCF15E16E13F527491CDF7845B2FE6521A738D8F7C9C721866A8496E1FC8E';Entry='nvngx_dlssnr.dll';Signed=$true}
 }
 if($cards[0] -match 'RTX\s*[234]0\d\d'){
  return [pscustomobject]@{Family='RTX 20/30/40 experimental';Url='https://github.com/grim-susemi/OptiScaler-Susemi/releases/download/v10/optiscaler-susemi-v10-bin64-bundle.zip';ArchiveHash='0DE10C4DB5780FF33BE19D42FA1855D3370853CBDEA4C04C7FF92E455159856A';ModelHash='E67DEE209320CDAFE0E93E45675D7AA34323A53ACC57A72B2E40A181581C989A';Entry='package/candidate-susemi-v10/nvngx_dlssnr.dll';Signed=$false}
 }
 throw 'No verified model download is configured for this GPU family.'
}
function EnsureNeuralRuntime([string]$ManifestPath,$Gpu,[scriptblock]$Progress={param($text)}){
 $manifest=ReadOptiShadeState $ManifestPath
 AssertClosed $manifest.Game
 $selection=GetNeuralDownload $Gpu (ResolveNeuralGpuChoice $manifest $Gpu)
 $target=OwnedPath $manifest.Game 'nvngx_dlssnr.dll'
 if((HashFile $target) -eq $selection.ModelHash){if($selection.Signed){AssertNvidiaFile $target};&$Progress 'Correct neural model already installed; download skipped.';return}
 $downloadStore=if($env:OPTISHADE_STORE){$env:OPTISHADE_STORE}else{Join-Path $env:LOCALAPPDATA 'OptiShade'}
 $temp=Join-Path $downloadStore ('Downloads/NR-'+[guid]::NewGuid().ToString('N'))
 New-Item -ItemType Directory -Path $temp -Force|Out-Null
 $archivePath=Join-Path $temp 'model.zip';$modelPath=Join-Path $temp 'nvngx_dlssnr.dll'
 try{
  &$Progress ('Downloading verified '+$selection.Family+' model from a community GitHub release...')
  GetVerifiedDownload $selection.Url $archivePath $selection.ArchiveHash
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip=[IO.Compression.ZipFile]::OpenRead($archivePath)
  try{
   $entry=$zip.GetEntry($selection.Entry)
   if(-not $entry -or $entry.Length -gt 256MB){throw 'Expected neural model is missing or has an invalid size.'}
   # Extract only the pinned model; never install any bundled third-party loaders.
   [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$modelPath,$false)
  }finally{$zip.Dispose()}
  if((HashFile $modelPath) -ne $selection.ModelHash){throw 'Neural model hash verification failed. Existing model was left unchanged.'}
  if($selection.Signed){AssertNvidiaFile $modelPath}
  ImportNrRuntime $ManifestPath $modelPath
  if((HashFile $target) -ne $selection.ModelHash){throw 'Installed neural model verification failed.'}
  &$Progress 'GPU-matched model installed and verified. Rendering remains off until enabled in game.'
 }finally{
  foreach($file in @($archivePath,$modelPath)){if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file -Force}}
  if(-not(Get-ChildItem -LiteralPath $temp -Force)){Remove-Item -LiteralPath $temp}
 }
}

function SetOlderRtxTestSettings([string]$Game){
 AssertClosed $Game
 $file=OwnedPath $Game 'OptiScaler.ini'
 if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw 'Install OptiShade before preparing a compatibility test.'}
 $settings=@{Enabled='false';Passes='1';UnlockPasses='false'};$seen=@{};$section=''
 $lines=New-Object 'System.Collections.Generic.List[string]'
 foreach($line in [IO.File]::ReadAllLines($file)){
  if($line -match '^\s*\[([^]]+)\]'){
   if($section -eq 'DlssNr'){foreach($key in $settings.Keys){if(-not $seen[$key]){$lines.Add("$key=$($settings[$key])");$seen[$key]=$true}}}
   $section=$Matches[1]
  }
  if($section -eq 'DlssNr' -and $line -match '^\s*(Enabled|Passes|UnlockPasses)\s*='){
   $key=$Matches[1];if(-not $seen[$key]){$lines.Add("$key=$($settings[$key])");$seen[$key]=$true}
  }else{$lines.Add($line)}
 }
 if(-not $seen.Count -and $section -ne 'DlssNr'){$lines.Add('[DlssNr]')}
 foreach($key in $settings.Keys){if(-not $seen[$key]){$lines.Add("$key=$($settings[$key])")}}
 $tmp=$file+'.nr-test-'+[guid]::NewGuid().ToString('N')
 try{[IO.File]::WriteAllLines($tmp,$lines,[Text.UTF8Encoding]::new($false));[IO.File]::Replace($tmp,$file,$tmp+'.backup');Remove-Item -LiteralPath ($tmp+'.backup')}finally{if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp}}
}
