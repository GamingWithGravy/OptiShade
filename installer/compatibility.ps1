# File discovery is evidence of a possible input, never proof of rendered support.
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
 $msfs=([IO.Path]::GetFileName($Exe) -eq 'FlightSimulator2024.exe' -or ([IO.Path]::GetFileName($Exe) -eq 'gamelaunchhelper.exe' -and (Test-Path -LiteralPath (Join-Path (Split-Path $Exe) 'FlightSimulator2024.exe'))))
 $truck=[IO.Path]::GetFileName($Exe) -in @('eurotrucks2.exe','amtrucks.exe')
 # Truck Simulator's external feed/add-on route is not implemented by this build.
 # Copied NVIDIA DLLs in its EXE folder must not turn this into a positive result.
 $possible=$msfs -or ($inputs.Count -gt 0 -and -not $truck)
 $addons=@()
 if($Exe){$addons=@(Get-ChildItem -LiteralPath (Split-Path $Exe) -Filter '*.addon64' -ErrorAction SilentlyContinue|Where-Object Name -match '(?i)dlss5|renodx')}
 $proxy=if($Launcher -eq 'Xbox' -or $Game -match '(?i)Xbox.?games' -or [IO.Path]::GetFileName($Exe) -eq 'gamelaunchhelper.exe'){'winmm.dll'}else{'dxgi.dll'}
 $performance=if($possible){'Possible upscaling connection found. Enable a supported upscaler in the game; this check cannot confirm it is running.'}elseif($truck){'No supported upscaler connection found. Use image effects in this game; installing DLSS files alone will not add DLSS.'}else{'No supported upscaler connection found. Image effects can be tried; upscaling is unconfirmed. Some games hide their upscaler inside the game code.'}
 $neural=if(-not $Gpu.Known){'DLSS neural rendering: graphics card unknown. NVIDIA downloads are skipped.'}elseif(-not $rtx){'DLSS neural rendering is not supported by this build on the detected card. FSR/XeSS are separate options in compatible games.'}elseif(-not $possible){'DLSS neural rendering: no compatible game connection identified. NVIDIA downloads are skipped.'}else{'DLSS neural rendering needs a matching RTX model and a supported rendering path. Files alone do not enable it; it stays off by default.'}
 if($Gpu.Names -match ',' -and $rtx){$neural+=' More than one GPU was detected; ensure the game actually uses the RTX card.'}
 [pscustomobject]@{Schema=1;Game=$Game;Executable=$Exe;Gpu=$Gpu.Names;Proxy=$proxy;InputEvidence=@($hits.ToArray());ExternalAddons=@($addons|ForEach-Object Name);ScanComplete=$complete;PossibleInput=[bool]$possible;DownloadNvidia=[bool]($rtx -and $possible);Performance=$performance;NeuralRendering=$neural;RuntimeState='Not tested in game';Checked=(Get-Date -Format o)}
}
function FormatFusionCompatibility($Plan){
 $lines=@(('Performance: '+$Plan.Performance),$Plan.NeuralRendering)
 if($Plan.DownloadNvidia){$lines+='Automatic downloads: tested DLSS 310.9.1 / Streamline 2.14.1. The separate neural-rendering model is 310.8 and must match the RTX card.'}
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
