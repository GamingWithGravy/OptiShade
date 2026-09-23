# File discovery is evidence of a possible input, never proof of rendered support.
function GetNeuralRuntimeStatus([string]$Game,$Gpu){
 if($Gpu.Names -notmatch '(?i)NVIDIA.*RTX'){
  return [pscustomobject]@{Family='Non-RTX';Expected='Not applicable';Path='';Version='';SHA256='';State='Unsupported on this hardware';Message='This build does not provide Neural Rendering on AMD/Intel. Image effects and supported FSR/XeSS paths are separate features.';DriverAssessment='No NVIDIA runtime is required for these features.'}
 }
 $cards=@($Gpu.Names -split ',\s*'|Where-Object {$_ -match '(?i)NVIDIA.*RTX'})
 $family=if($cards.Count -ne 1){'Unknown / multiple RTX GPUs'}elseif($cards[0] -match 'RTX\s*50\d\d'){'RTX 50'}elseif($cards[0] -match 'RTX\s*[234]0\d\d'){'RTX 20/30/40'}else{'Unknown RTX family'}
 $expected=if($family -eq 'RTX 50'){'Original verified RTX 50 model'}elseif($family -eq 'RTX 20/30/40'){'Verified 310.8 compatibility model (experimental)'}else{'Identify the GPU used by MSFS before choosing a model'}
 $file=Join-Path $Game 'nvngx_dlssnr.dll';$state='Missing';$version='Unknown';$hash=''
 $message='Model missing beside the game EXE. Add nvngx_dlssnr.dll; nvngx.dll_dlssnr.dll is a different helper and does not replace it.'
 if(Test-Path -LiteralPath $file -PathType Leaf){
  try{
   $hash=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
   $version=[Diagnostics.FileVersionInfo]::GetVersionInfo($file).FileVersion
   $original=$hash -eq 'E16BCF15E16E13F527491CDF7845B2FE6521A738D8F7C9C721866A8496E1FC8E'
   $compat=$hash -eq 'E67DEE209320CDAFE0E93E45675D7AA34323A53ACC57A72B2E40A181581C989A'
   if(-not($original -or $compat)){$state='Unverified';$message='Model found, but its SHA256 is not a runtime verified by this installer. Version alone does not establish compatibility.'}
   elseif($family -eq 'RTX 20/30/40' -and $original){$state='Incompatible';$message='RTX 50 model found on RTX 20/30/40. Use the verified compatibility model.'}
   elseif($family -like 'Unknown*'){$state='GPU selection required';$message='Known model found, but the active RTX GPU cannot be determined.'}
   elseif($original -and (Get-AuthenticodeSignature -LiteralPath $file).Status -ne 'Valid'){$state='Signature failed';$message='Original model signature verification failed.'}
   else{$state='Verified file';$message='Known model found for this GPU family. Loading and rendering still require an in-game check.'}
  }catch{$state='Unreadable';$message='Model exists but could not be inspected. Check file access permissions.'}
 }else{
  foreach($relative in @('OptiShadeData/Engine/nvngx_dlssnr.dll','OptiShadeData/nvngx_dlssnr.dll','streamline/nvngx_dlssnr.dll')){
   $other=Join-Path $Game $relative
   if(Test-Path -LiteralPath $other -PathType Leaf){$state='Alternate location';$message='Model found at '+$other+'. Use Add NVIDIA runtime to validate and place it beside the selected game EXE. This does not confirm the game loads it.';break}
  }
 }
 [pscustomobject]@{Family=$family;Expected=$expected;Path=$file;Version=$version;SHA256=$hash;State=$state;Message=$message;DriverAssessment='Minimum driver requirement for this model is unverified; driver compatibility is not confirmed.'}
}
function GetFusionCompatibility([string]$Game,[string]$Exe,$Gpu,[string]$Launcher=''){
 $rtx=[bool]($Gpu.Known -and $Gpu.Names -match '(?i)NVIDIA[^,]*\bRTX\b')
 $hits=New-Object 'System.Collections.Generic.List[object]'
 $pending=New-Object 'System.Collections.Generic.Queue[object]'
 $complete=$true;$visited=0
 if(Test-Path -LiteralPath $Game -PathType Container){$pending.Enqueue(@([IO.Path]::GetFullPath($Game),0))}else{$complete=$false}
 while($pending.Count -and $visited -lt 400){
  $item=$pending.Dequeue();$visited++
  try{$entries=@(Get-ChildItem -LiteralPath $item[0] -ErrorAction Stop)}catch{$complete=$false;continue}
  foreach($entry in $entries){
   if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
   if($entry.PSIsContainer){
    if($entry.Name -match '^(OptiShadeData|Redist|__Installer|Support|Extras|\.git)$'){continue}
    if($item[1] -lt 6){$pending.Enqueue(@($entry.FullName,($item[1]+1)))}else{$complete=$false}
   }elseif($entry.Name -match '^(nvngx_dlss(d|g)?|libxess(_dx11|_fg)?|amd_fidelityfx_(dx12|vk|upscaler_dx12)|ffx_fsr2_api(_x64)?|ffx_fsr2_api_dx12(_x64)?)\.dll$'){
    $kind=switch -Regex ($entry.Name){'^nvngx_dlss\.dll$'{'DLSS';break};'^libxess(_dx11)?\.dll$'{'XeSS';break};'^(amd_fidelityfx|ffx_fsr2)'{'FSR';break};default{'Companion only'}}
    $version=[Diagnostics.FileVersionInfo]::GetVersionInfo($entry.FullName).FileVersion
    $hits.Add([pscustomobject]@{File=$entry.FullName;Kind=$kind;Version=if($version){$version}else{'Unknown'}})
   }
  }
 }
 if($pending.Count){$complete=$false}
 $inputs=@($hits|Where-Object Kind -ne 'Companion only')
 $msfs=([IO.Path]::GetFileName($Exe) -in @('FlightSimulator2024.exe','FlightSimulator.exe') -or ([IO.Path]::GetFileName($Exe) -eq 'gamelaunchhelper.exe' -and ((Test-Path -LiteralPath (Join-Path (Split-Path $Exe) 'FlightSimulator2024.exe')) -or (Test-Path -LiteralPath (Join-Path (Split-Path $Exe) 'FlightSimulator.exe')))))
 $truck=[IO.Path]::GetFileName($Exe) -in @('eurotrucks2.exe','amtrucks.exe')
 # Truck Simulator's external feed/add-on route is not implemented by this build.
 # Copied NVIDIA DLLs in its EXE folder must not turn this into a positive result.
 $possible=$msfs -or ($inputs.Count -gt 0 -and -not $truck)
 $addons=@()
 if($Exe){$addons=@(Get-ChildItem -LiteralPath (Split-Path $Exe) -Filter '*.addon64' -ErrorAction SilentlyContinue|Where-Object Name -match '(?i)dlss5|renodx')}
 # The selected executable is authoritative; folder names must not override a Steam copy.
 $proxy=if([IO.Path]::GetFileName($Exe) -eq 'gamelaunchhelper.exe' -or ($Launcher -eq 'Xbox' -and [IO.Path]::GetFileName($Exe) -eq 'FlightSimulator.exe')){'winmm.dll'}else{'dxgi.dll'}
 $performance=if($possible){'Possible upscaling connection found. Enable a supported upscaler in the game; this check cannot confirm it is running.'}elseif($truck){'No supported upscaler connection found. Use image effects in this game; installing DLSS files alone will not add DLSS.'}else{'No supported upscaler connection found. Image effects can be tried; upscaling is unconfirmed. Some games hide their upscaler inside the game code.'}
 if(Test-Path -LiteralPath (Join-Path (Split-Path $Exe) 'FlightSimulator.exe')){$performance+=' MSFS 2020 is experimental: select DirectX 12 and DLSS in the simulator, restart, then enter a flight. Test effects and upscaling before enabling optional NR or frame generation.'}
 $neural=if(-not $Gpu.Known){'DLSS neural rendering: graphics card unknown. NVIDIA downloads are skipped.'}elseif(-not $rtx){'DLSS neural rendering is not supported by this build on the detected card. FSR/XeSS are separate options in compatible games.'}elseif(-not $possible){'DLSS neural rendering: no compatible game connection identified. NVIDIA downloads are skipped.'}else{'DLSS neural rendering needs a matching RTX model and a supported rendering path. Files alone do not enable it; it stays off by default.'}
 $generation=if($Gpu.Names -match '(?i)RTX\s*40\d\d'){'RTX 40'}elseif($Gpu.Names -match '(?i)RTX\s*50\d\d'){'RTX 50'}elseif($Gpu.Names -match '(?i)RTX\s*[23]0\d\d'){'RTX 20/30'}else{'Unknown'}
 if($generation -eq 'RTX 40'){$neural+=' RTX 40-series: image effects are supported; neural rendering is experimental and needs the verified 310.8 compatibility runtime. The original RTX 50 model cannot be used. No RTX 40 rendering test is claimed.'}
 if($generation -eq 'RTX 20/30'){$neural+=' RTX 20/30-series: use image effects first. Neural rendering is experimental, requires the compatibility runtime and may be too slow.'}
 if($Gpu.Names -match ',' -and $rtx){$neural+=' More than one GPU was detected; ensure the game actually uses the RTX card.'}
 [pscustomobject]@{Schema=1;Game=$Game;Executable=$Exe;Gpu=$Gpu.Names;Proxy=$proxy;InputEvidence=@($hits.ToArray());ExternalAddons=@($addons|ForEach-Object Name);ScanComplete=$complete;PossibleInput=[bool]$possible;DownloadNvidia=[bool]($rtx -and $possible);Performance=$performance;NeuralRendering=$neural;RuntimeState='Not tested in game';Checked=(Get-Date -Format o)}
}
function FormatFusionCompatibility($Plan){
 $lines=@(('GPU: '+$Plan.Gpu),('Performance: '+$Plan.Performance),$Plan.NeuralRendering)
 if($Plan.PSObject.Properties['DriverVersions']){foreach($driver in $Plan.DriverVersions){$lines+=('Driver: '+$driver.Name+' - '+$driver.Version+' (Windows: '+$driver.WindowsVersion+')')}}
 if($Plan.PSObject.Properties['NeuralRuntime']){$nr=$Plan.NeuralRuntime;$lines+=@(('Required model: '+$nr.Expected),('Model status: '+$nr.State+' - '+$nr.Message),('Checked location: '+$nr.Path),('Model file version: '+$nr.Version),$nr.DriverAssessment)}
 if($Plan.DownloadNvidia){$lines+='Automatic downloads: DLSS 310.9.1 / Streamline 2.14.1. The separate neural-rendering model is chosen by GPU family and verified hash, not driver version alone.'}
 if(-not $Plan.ScanComplete){$lines+='The file check was limited or some folders could not be read.'}
 if($Plan.ExternalAddons.Count){$lines+=('Another DLSS/ReShade add-on setup was found: '+($Plan.ExternalAddons -join ', ')+'. Install will offer to back up and replace it; Restore puts it back.')}
 foreach($hit in $Plan.InputEvidence){$lines+=([IO.Path]::GetFileName($hit.File)+' - found version '+$hit.Version+' (not proof it is used)')}
 $lines -join "`n"
}
function GetFusionInstalledVersions([string]$Game){
 # Installed files are reported separately; they must not count as native game support.
 foreach($relative in @('nvngx_dlssnr.dll','OptiShadeData/Engine/nvngx_dlss.dll','OptiShadeData/Engine/nvngx_dlssd.dll','OptiShadeData/Engine/nvngx_dlssg.dll','OptiShadeData/Engine/streamline/sl.interposer.dll','OptiShadeData/Engine/libxess.dll','OptiShadeData/Engine/amd_fidelityfx_upscaler_dx12.dll')){
  $file=Join-Path $Game $relative
  if(Test-Path -LiteralPath $file -PathType Leaf){
   $version=[Diagnostics.FileVersionInfo]::GetVersionInfo($file).FileVersion
   [pscustomobject]@{File=$relative;Version=if($version){$version}else{'Unknown'};State='Stored file; not proof it is active'}
  }
 }
}
function SaveFusionCompatibility([string]$Game,$Plan){
 $file=OwnedPath $Game 'OptiShadeData/Compatibility.json'
 $Plan|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $file -Encoding UTF8
}
