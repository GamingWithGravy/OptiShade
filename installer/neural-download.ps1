function GetNeuralDownload($Gpu){
 $cards=@($Gpu.Names -split ',\s*'|Where-Object {$_ -match '(?i)NVIDIA.*RTX'})
 if($cards.Count -ne 1){throw 'Automatic model selection needs exactly one detected RTX GPU. Use Add NVIDIA runtime after identifying the GPU used by MSFS.'}
 if($cards[0] -match 'RTX\s*50\d\d'){
  return [pscustomobject]@{Family='RTX 50';Url='https://github.com/RankFTW/rhi-repo/releases/download/dlssnr-310.8.0/nvngx_dlssnr_310.8.0.zip';ArchiveHash='388C0A7912E15EC911B9C9E11A692142B11FE387DDF2B637D8C358138FFFB3AC';ModelHash='E16BCF15E16E13F527491CDF7845B2FE6521A738D8F7C9C721866A8496E1FC8E';Entry='nvngx_dlssnr.dll';Signed=$true}
 }
 if($cards[0] -match 'RTX\s*[234]0\d\d'){
  return [pscustomobject]@{Family='RTX 20/30/40 experimental';Url='https://github.com/grim-susemi/OptiScaler-Susemi/releases/download/v10/optiscaler-susemi-v10-bin64-bundle.zip';ArchiveHash='0DE10C4DB5780FF33BE19D42FA1855D3370853CBDEA4C04C7FF92E455159856A';ModelHash='E67DEE209320CDAFE0E93E45675D7AA34323A53ACC57A72B2E40A181581C989A';Entry='package/candidate-susemi-v10/nvngx_dlssnr.dll';Signed=$false}
 }
 throw 'No verified model download is configured for this GPU family.'
}
function EnsureNeuralRuntime([string]$ManifestPath,$Gpu,[scriptblock]$Progress={param($text)}){
 $selection=GetNeuralDownload $Gpu
 $manifest=Get-Content -LiteralPath $ManifestPath -Raw|ConvertFrom-Json
 AssertClosed $manifest.Game
 $target=OwnedPath $manifest.Game 'nvngx_dlssnr.dll'
 if((HashFile $target) -eq $selection.ModelHash){if($selection.Signed){AssertNvidiaFile $target};&$Progress 'Correct neural model already installed; download skipped.';return}
 $temp=Join-Path $env:LOCALAPPDATA ('OptiShade/Downloads/NR-'+[guid]::NewGuid().ToString('N'))
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
