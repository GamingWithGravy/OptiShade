. "$PSScriptRoot/anti-cheat.ps1"
. "$PSScriptRoot/gpu-identity.ps1"
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
 # OptiScaler's LOG_INFO macro prefixes the message with __FUNCTION__, and
 # the configured spdlog sink may add timestamp/severity text as well. Match
 # the structured identity within a bounded log line, not only at column zero.
 $matches=[regex]::Matches($text,'(?m)^[^\r\n]{0,512}?\bNR rendering adapter: luid=([A-Fa-f0-9]{16}); vendor=10DE; device=([A-Fa-f0-9]{4}); software=false; name=([^\r\n]{1,160})\r?$')
 if(-not $matches.Count){return $null}
 $last=$matches[$matches.Count-1];$hex=$last.Groups[1].Value.ToUpperInvariant()
 $device=[Convert]::ToUInt32($last.Groups[2].Value,16)
 $cards=@($Gpu.Adapters|Where-Object {-not $_.Software -and [uint32]$_.VendorId -eq 0x10DE -and [uint32]$_.DeviceId -eq $device -and [string]$_.LuidHex -ceq $hex})
 if($cards.Count -ne 1){return $null}
 return [pscustomobject]@{Name=[string]$cards[0].Name;Luid=[string]$cards[0].Luid;Evidence='Previous selected-game rendering device matched to current DXGI identity; not live';ModifiedUtc=$item.LastWriteTimeUtc.ToString('o')}
}
function ResolveOptiShadeNeuralPreparationAdapter($Manifest,$Gpu){
 # Share this resolution between the component preflight and the actual
 # preparation transaction. Otherwise the preflight can reject a multi-GPU
 # machine before EnsureNeuralRuntime reaches its previous-renderer fallback.
 # An explicit NR-device choice controls model preparation even when the game
 # last rendered on another adapter. Keep the observed renderer hint intact for
 # runtime/status checks; only omit it from this preparation-only resolution.
 $preparationGpu=$Gpu
 $explicitSelection=$Manifest -and $Manifest.NeuralAdapterSelection -ceq 'explicit' -and $Manifest.NeuralAdapter
 if($explicitSelection -and $Gpu -and $Gpu.PSObject.Properties['PreferredRenderingLuid']){
  $preparationGpu=[pscustomobject]@{Adapters=@($Gpu.Adapters);Names=[string]$Gpu.Names;Known=[bool]$Gpu.Known;Complete=$Gpu.Complete}
 }
 $candidate=ResolveOptiShadeNeuralAdapter $Manifest $preparationGpu
 # An exact rendering hint belongs to this preparation context. If it points
 # at an unsupported/non-NVIDIA renderer, do not let an older NVIDIA log pick
 # a different adapter and prepare a model for a GPU the game is not using.
 if(-not $explicitSelection -and $Gpu -and $Gpu.PSObject.Properties['PreferredRenderingLuid'] -and $Gpu.PreferredRenderingLuid){return $candidate}
 if($candidate.State -eq 'candidate' -or $Manifest.NeuralAdapterSelection -ceq 'explicit' -or $Manifest.NeuralAdapter -or $Manifest.NeuralGpuName){return $candidate}
 $previous=GetObservedNeuralGpu ([string]$Manifest.Game) $Gpu
 if(-not $previous){return $candidate}
 $matched=ResolveOptiShadeAdapterCandidate $Gpu '' ([string]$previous.Luid)
 if($matched.State -eq 'candidate'){
  $matched=GetOptiShadeNeuralAdapterEligibility $matched
  if($matched.State -ne 'candidate'){return $matched}
  $matched|Add-Member Evidence $previous.Evidence -Force
  $matched|Add-Member EvidenceModifiedUtc $previous.ModifiedUtc -Force
  return $matched
 }
 return $candidate
}
function GetNeuralDownload($Gpu,[string]$SelectedName,[string]$SelectedLuid=''){
 $candidate=GetOptiShadeNeuralAdapterEligibility (ResolveOptiShadeAdapterCandidate $Gpu $SelectedName $SelectedLuid)
 if($candidate.State -ne 'candidate'){throw ('Neural model preparation is waiting for a measured adapter: '+$candidate.Reason)}
 $models=@(GetOptiShadeNeuralModelCatalog|Where-Object {$_.Variant -eq 'auto' -and [int]$candidate.Adapter.Family -in $_.Families})
 if($models.Count -ne 1){throw 'No pinned model download is configured for this measured architecture.'}
 $selection=$models[0];$selection|Add-Member Adapter (GetOptiShadeAdapterReceipt $candidate.Adapter) -Force
 return $selection
}
function GetVerifiedNeuralCache($selection,[scriptblock]$Progress={param($text)}){
 [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
 $downloadStore=if($env:OPTISHADE_STORE){$env:OPTISHADE_STORE}else{Join-Path $env:LOCALAPPDATA 'OptiShade'}
 $cacheRoot=OwnedPath $downloadStore ('Downloads/NR-cache/'+$selection.ModelHash)
 New-Item -ItemType Directory -Path $cacheRoot -Force|Out-Null
 $cached=OwnedPath $cacheRoot 'nvngx_dlssnr.dll'
 if((HashFile $cached) -eq $selection.ModelHash){if($selection.Signed){AssertNvidiaFile $cached};return $cached}
 $temp=OwnedPath $downloadStore ('Downloads/NR-'+[guid]::NewGuid().ToString('N'))
 New-Item -ItemType Directory -Path $temp -Force|Out-Null
 $archivePath=Join-Path $temp 'model.zip';$modelPath=Join-Path $temp 'nvngx_dlssnr.dll'
 try{
  [void](&$Progress ('Downloading verified '+$selection.Family+' model from a community GitHub release...'))
  GetVerifiedDownload $selection.Url $archivePath $selection.ArchiveHash | Out-Null
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
  Copy-Item -LiteralPath $modelPath -Destination $cached -Force
  if((HashFile $cached) -ne $selection.ModelHash){throw 'Neural cache verification failed.'}
  return $cached
 }finally{
  foreach($file in @($archivePath,$modelPath)){if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file -Force}}
  if(-not(Get-ChildItem -LiteralPath $temp -Force)){Remove-Item -LiteralPath $temp}
 }
}

function EnsureNeuralRuntime([string]$ManifestPath,$Gpu,[scriptblock]$Progress={param($text)}){
 $storeMutation=EnterOptiShadeMutation -ManifestPath $ManifestPath
 try{
 $manifest=ReadOptiShadeState $ManifestPath
 AssertClosed $manifest.Game
 AssertAntiCheatMutation $manifest.Game $manifest.LaunchExe 'Install Neural'
 $target=OwnedPath $manifest.Game 'nvngx_dlssnr.dll'
 $candidate=ResolveOptiShadeNeuralPreparationAdapter $manifest $Gpu
 if($candidate.State -ne 'candidate'){throw ('Neural model preparation is waiting for this game adapter: '+$candidate.Reason)}
 $variant=[string]$manifest.NeuralRuntimeVariant
 if($variant -in @('compat-3109','official-3109','v7-3109')){
  $local=@(GetOptiShadeNeuralModelCatalog|Where-Object Variant -eq $variant)
  if($local.Count -ne 1 -or [int]$candidate.Adapter.Family -notin $local[0].Families){throw 'The retained local NR model is not admitted for the measured adapter architecture. Existing model retained.'}
  if((HashFile $target) -cne $local[0].ModelHash){throw 'The selected local NR runtime is missing or changed. Re-import that version from the manager; automatic repair will not replace it.'}
  $importGpu=[pscustomobject]@{Adapters=@($Gpu.Adapters);PreferredRenderingLuid=[string]$candidate.Adapter.Luid}
  ImportNrRuntime $ManifestPath $target $variant $importGpu
  &$Progress 'Selected local NR version and owned preparation identity verified; automatic model replacement skipped.';return
 }
 $selection=GetNeuralDownload $Gpu '' ([string]$candidate.Adapter.Luid)
 if((HashFile $target) -eq $selection.ModelHash){
  if($selection.Signed){AssertNvidiaFile $target}
  $importGpu=[pscustomobject]@{Adapters=@($Gpu.Adapters);PreferredRenderingLuid=[string]$candidate.Adapter.Luid}
  ImportNrRuntime $ManifestPath $target auto $importGpu
  &$Progress 'Correct neural model and owned preparation identity verified; download skipped.';return
 }
 $model=GetVerifiedNeuralCache $selection $Progress
 $importGpu=[pscustomobject]@{Adapters=@($Gpu.Adapters);PreferredRenderingLuid=[string]$candidate.Adapter.Luid}
 ImportNrRuntime $ManifestPath $model auto $importGpu
 if((HashFile $target) -ne $selection.ModelHash){throw 'Installed neural model verification failed.'}
 &$Progress 'GPU-matched model installed and verified.'
 }finally{ExitOptiShadeMutation $storeMutation}
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
