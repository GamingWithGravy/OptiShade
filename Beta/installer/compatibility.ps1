# File discovery is evidence of a possible input, never proof of rendered support.
. "$PSScriptRoot/gpu-identity.ps1"
function GetNeuralRuntimeStatus([string]$Game,$Gpu,$Manifest=$null){
 $candidate=ResolveOptiShadeNeuralAdapter $Manifest $Gpu
 $family=if($candidate.State -eq 'candidate'){'RTX '+[string]$candidate.Adapter.Family+' architecture'}else{'Unknown rendering architecture'}
 $expected=if($candidate.State -eq 'candidate'){@(GetOptiShadeNeuralModelCatalog|Where-Object {$_.Variant -eq 'auto' -and [int]$candidate.Adapter.Family -in $_.Families}|ForEach-Object Family) -join ', '}else{$candidate.Reason}
 $file=Join-Path $Game 'nvngx_dlssnr.dll';$state='Missing';$version='Unknown';$hash=''
 $message='Model missing beside the game EXE. Auto can prepare the pinned model after the adapter architecture is identified.'
 if(Test-Path -LiteralPath $file -PathType Leaf){
  try{
   $hash=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash;$version=[Diagnostics.FileVersionInfo]::GetVersionInfo($file).FileVersion
   $model=GetOptiShadeNeuralModelByHash $hash
   if(-not $model){$state='Unverified';$message='Model found, but its SHA256 is not in the installer catalogue. Version alone does not establish compatibility.'}
   elseif($candidate.State -ne 'candidate'){$state='Waiting for rendering adapter';$message='A pinned model is present. '+$candidate.Reason}
   elseif([int]$candidate.Adapter.Family -notin $model.Families){$state='Incompatible';$message='This pinned model does not match the measured adapter architecture. Existing model retained for review.'}
   elseif($model.Signed -and (Get-AuthenticodeSignature -LiteralPath $file).Status -ne 'Valid'){$state='Signature failed';$message='Original model signature verification failed.'}
   elseif($model.Variant -ne 'auto'){$state='Experimental community build';$message=$model.Family+' model found. It is locally supplied and rendering remains unverified.'}
   else{$state='Verified file';$message='Pinned model matches the measured adapter candidate. Loading, successful inference and presented output remain separate runtime checks.'}
  }catch{$state='Unreadable';$message='Model exists but could not be inspected. Check file access permissions.'}
 }else{
  foreach($relative in @('OptiShadeData/Engine/nvngx_dlssnr.dll','OptiShadeData/nvngx_dlssnr.dll','streamline/nvngx_dlssnr.dll')){
   $other=Join-Path $Game $relative
   if(Test-Path -LiteralPath $other -PathType Leaf){$state='Alternate location';$message='Model found at '+$other+'. Auto must validate ownership and place the matching model beside the rendering EXE. This does not confirm the game loads it.';break}
  }
 }
 [pscustomobject]@{Family=$family;Expected=$expected;Path=$file;Version=$version;SHA256=$hash;State=$state;Message=$message;Adapter=$(if($candidate.Adapter){GetOptiShadeAdapterReceipt $candidate.Adapter}else{$null});DriverAssessment='Driver architecture was queried where available; model runtime compatibility and output remain unverified.'}
}
function TestOptiShadeLegacyD3D9Wrapper([string]$Game){
 $wrapper=Get-ChildItem -LiteralPath $Game -File -Force -ErrorAction SilentlyContinue|Where-Object Name -ieq 'D3D9.dll'|Select-Object -First 1
 $config=Join-Path $Game 'dgVoodoo.conf'
 if(-not $wrapper -or -not(Test-Path -LiteralPath $config -PathType Leaf)){return $false}
 try{$text=[IO.File]::ReadAllText($config);return ($text -match '(?im)^\s*DisableAndPassThru\s*=\s*false\s*(?:;.*)?$' -and $text -match '(?im)^\s*OutputAPI\s*=\s*d3d11(?:_fl\d+_\d+)?\s*(?:;.*)?$')}catch{return $false}
}
function GetFusionCompatibility([string]$Game,[string]$Exe,$Gpu,[string]$Launcher=''){
 $rtx=[bool]($Gpu.Known -and $Gpu.Names -match '(?i)NVIDIA[^,]*\bRTX\b')
 $hits=New-Object 'System.Collections.Generic.List[object]'
 $pending=New-Object 'System.Collections.Generic.Queue[object]'
 $complete=$true;$visited=0
 if(Test-Path -LiteralPath $Game -PathType Container){$pending.Enqueue(@((FullPath $Game),0))}else{$complete=$false}
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
 $xp12=[IO.Path]::GetFileName($Exe) -eq 'X-Plane.exe'
 $possible=$msfs -or $xp12 -or $inputs.Count -gt 0
 $identity=$null;$identityReason='Executable not inspected'
 try{$identity=GetOptiShadeExecutableIdentity $Exe;$identityReason=$identity.Evidence}catch{$identityReason=$_.Exception.Message}
 $isX86=$identity -and $identity.Architecture -eq 'x86'
 # DX12 imports are a candidate, not proof of the active API or valid depth.
 # Dynamic API loaders remain Unknown until the runtime observes a device.
 # Their optional model may be acquired, but this never confirms runtime support.
 $estimatedCandidate=[bool](-not $isX86 -and $rtx -and $identity -and (($identity.ApiCandidates.Count -eq 0 -or $identity.ApiCandidates -contains 'DX12' -or $identity.ApiCandidates -contains 'DX11' -or $identity.ApiCandidates -contains 'Vulkan') -or $msfs -or $xp12))
 $route=if([IO.Path]::GetFileName($Exe) -eq 'FlightSimulator2024.exe' -or ($msfs -and (Test-Path -LiteralPath (Join-Path $Game 'FlightSimulator2024.exe')))){'OptiShadeMSFS2024.dll'}elseif($msfs){'OptiShadeMSFS2020.dll'}elseif($xp12){'OptiShadeXPlane12.dll'}else{'OptiShadeGeneric.dll'}
 $addons=@()
 if($Exe){$addons=@(Get-ChildItem -LiteralPath (Split-Path $Exe) -Filter '*.addon64' -ErrorAction SilentlyContinue|Where-Object Name -match '(?i)dlss5|renodx')}
 # The selected executable is authoritative; folder names must not override a Steam copy.
 $hasDirectX=$identity -and (($identity.ApiCandidates -contains 'DX9') -or ($identity.ApiCandidates -contains 'DX10') -or ($identity.ApiCandidates -contains 'DX11') -or ($identity.ApiCandidates -contains 'DX12'))
 $hasVulkan=$identity -and ($identity.ApiCandidates -contains 'Vulkan')
 $hasOpenGL=$identity -and ($identity.ApiCandidates -contains 'OpenGL')
 $usesWinmm=$identity -and ($identity.Imports -contains 'winmm.dll')
 $automaticRenderer=if($identity -and $identity.ApiCandidates -contains 'DX9'){'DirectX9'}elseif($hasOpenGL -and -not $hasDirectX -and -not $hasVulkan){'OpenGL'}elseif([IO.Path]::GetFileName($Exe) -eq 'gamelaunchhelper.exe' -or ($Launcher -eq 'Xbox' -and [IO.Path]::GetFileName($Exe) -eq 'FlightSimulator.exe') -or ($hasVulkan -and -not $hasDirectX) -or (-not $hasVulkan -and -not $hasDirectX -and -not $hasOpenGL -and $usesWinmm)){'Vulkan'}else{'DirectX'}
 $proxy=GetOptiShadeRendererProxy $automaticRenderer 'dxgi.dll' ([bool]$isX86)
 $performance=if($possible){'Possible upscaling connection found. Enable a supported upscaler in the game; this check cannot confirm it is running.'}else{'No supported upscaler connection found. Image effects can be tried; upscaling is unconfirmed. Some games hide their upscaler inside the game code.'}
 if($isX86){
  $possible=$false;$estimatedCandidate=$false
  if($hasVulkan -and -not $hasDirectX -and -not $hasOpenGL){$proxy='unsupported';$performance='This installer does not include the 32-bit ReShade Vulkan layer. The experimental x86 NR bridge needs an external, compatible ReShade Vulkan installation for Vulkan games.'}
  elseif($identity -and $identity.ApiCandidates -contains 'DX9'){
   if(TestOptiShadeLegacyD3D9Wrapper $Game){$proxy='dxgi.dll';$performance='A configured dgVoodoo D3D9-to-D3D11 wrapper was detected. Install OptiShade through DXGI so it does not replace the wrapper; Legacy NR remains experimental.'}
   else{$proxy='d3d9.dll';$performance='32-bit DirectX 9 image effects are available. Legacy NR needs a configured external D3D9-to-D3D11 wrapper before OptiShade is installed; native D3D9 is not supported by the NR bridge.'}
  }
  else{$performance='32-bit DirectX and OpenGL image effects are available. Experimental Legacy NR can use D3D10/11 or OpenGL; Vulkan needs an external 32-bit ReShade layer. Glass Cockpit requires a 64-bit game.'}
 }
 if($identity -and $identity.ApiCandidates -contains 'DX11'){$performance+=' DX11 NR is an experimental TAA-guide route and currently uses one model pass; image effects remain separate.'}
 if($identity -and $identity.ApiCandidates -contains 'Vulkan'){$performance+=' Vulkan is a PE import candidate, not proof of the active API. Use OptiShade Play to request the game-local Vulkan layer and capture runtime diagnostics.'}
 if(Test-Path -LiteralPath (Join-Path (Split-Path $Exe) 'FlightSimulator.exe')){$performance+=' MSFS 2020: select DirectX 12 and DLSS in the simulator, restart, then enter a flight. Test effects and upscaling before enabling optional NR.'}
 $neural=if($isX86){'Experimental x86-to-x64 Legacy NR is available for D3D10/11 and OpenGL, with an externally installed 32-bit ReShade Vulkan layer as an advanced option. It needs a matching RTX model and the Legacy NR feed effect plus a supported motion-vector provider. D3D9 needs a configured external D3D9-to-D3D11 wrapper and DXGI attachment. No game-output test is claimed.'}elseif(-not $Gpu.Known){'DLSS neural rendering: graphics card unknown. NVIDIA downloads are skipped.'}elseif(-not $rtx){'DLSS neural rendering is not supported by this build on the detected card. FSR/XeSS are separate options in compatible games.'}elseif($estimatedCandidate -and -not $possible){'Experimental non-DLSS NR candidate. Keep the game AA mode; Auto requires valid captured colour/depth and estimated motion, a matching RTX model and completed inference. Actual output is untested.'}elseif(-not $possible){'NR input is unconfirmed. This build needs DX12, the experimental DX11 transport or the Vulkan bridge and a matching RTX model. Runtime device/input inspection is authoritative.'}else{'DLSS neural rendering needs a matching RTX model and a supported rendering path. Files alone do not enable it; it stays off by default.'}
 if($xp12){$performance='X-Plane 12 Vulkan: image effects and experimental NR input. No DLSS upscaling connection is claimed. Launch through OptiShade Play.';$neural+=' XP12 NR: SDR up to 3840x2160, one full-resolution pass; enable the guide technique and NR in game.'}
  # Model numbers are not architecture: e.g. RTX 5000 Ada is family 40,
  # Quadro RTX 5000 is family 20, and RTX PRO 5000 Blackwell is family 50.
  # Reuse the same measured DXGI/CUDA-LUID identity that authorizes provider
  # preparation, and leave this summary unknown if hardware evidence is weak.
  $familyCandidate=ResolveOptiShadeAdapterCandidate $Gpu
  $generation=if($familyCandidate.State -eq 'candidate'){switch([int]$familyCandidate.Adapter.Family){40{'RTX 40'}50{'RTX 50'}20{ 'RTX 20/30'}30{'RTX 20/30'}default{'Unknown'}}}else{'Unknown'}
 if($generation -eq 'RTX 40'){$neural+=' RTX 40-series: image effects are supported; neural rendering is experimental and needs the verified 310.8 compatibility runtime. The original RTX 50 model cannot be used. No RTX 40 rendering test is claimed.'}
 if($generation -eq 'RTX 20/30'){$neural+=' RTX 20/30-series: use image effects first. Neural rendering is experimental, requires the compatibility runtime and may be too slow.'}
 if($Gpu.Names -match ',' -and $rtx){$neural+=' Multiple GPUs were detected. This scan lists hardware only and cannot identify the game renderer. Start the game from OptiShade to detect its rendering adapter automatically.'}
  [pscustomobject]@{Schema=2;RouteDLL=$route;ExecutableIdentity=$identity;ExecutableEvidence=$identityReason;EstimatedNrCandidate=$estimatedCandidate;Game=$Game;Executable=$Exe;Gpu=$Gpu.Names;NvidiaArchitecture=$generation;Proxy=$proxy;InputEvidence=@($hits.ToArray());ExternalAddons=@($addons|ForEach-Object Name);ScanComplete=$complete;PossibleInput=[bool]$possible;DownloadNvidia=[bool](-not $isX86 -and $rtx -and ($possible -or $estimatedCandidate));Performance=$performance;NeuralRendering=$neural;RuntimeState='Not tested in game';Checked=(Get-Date -Format o)}
}
$script:OptiShadeInstallMethods=@('winmm.dll','dxgi.dll','d3d12.dll','version.dll','dbghelp.dll','d3d9.dll','opengl32.dll')
function ResolveOptiShadeInstallMethod([string]$Method,[string]$AutomaticMethod='dxgi.dll'){
 $choice=if([string]::IsNullOrWhiteSpace($Method)){'auto'}else{$Method.Trim().ToLowerInvariant()}
 if($choice -eq 'auto'){
  $automatic=if([string]::IsNullOrWhiteSpace($AutomaticMethod)){'dxgi.dll'}else{$AutomaticMethod.Trim().ToLowerInvariant()}
  if($script:OptiShadeInstallMethods -contains $automatic){return $automatic}
  return 'dxgi.dll'
 }
 if($script:OptiShadeInstallMethods -contains $choice){return $choice}
 throw 'Choose Automatic or one of the supported OptiShade installation methods.'
}
function GetOptiShadeRendererProxy([string]$RendererApi,[string]$AutomaticMethod='dxgi.dll',[bool]$X86=$false){
 switch($RendererApi.ToLowerInvariant()){
  'vulkan'{return 'winmm.dll'}
  'directx9'{if($X86){return 'd3d9.dll'};return 'dxgi.dll'}
  'opengl'{if($X86){return 'opengl32.dll'};return 'dxgi.dll'}
  'directx'{return 'dxgi.dll'}
  default{return ResolveOptiShadeInstallMethod 'auto' $AutomaticMethod}
 }
}
function GetOptiShadeInstalledLoaderPath($Manifest){
 $entries=@()
 if($Manifest -and $Manifest.PSObject.Properties['Files']){
  $entries=@($Manifest.Files|Where-Object {$_.SourcePath -in @('winmm.dll','ReShade32.dll')})
 }
 if($entries.Count -eq 1 -and $entries[0].Path -in @($script:OptiShadeInstallMethods+'wininet.dll'+'winhttp.dll')){return [string]$entries[0].Path}
 return ''
}
function GetOptiShadeMethodRendererApi([string]$Method,[string]$EffectiveMethod='',[string[]]$ApiCandidates=@(),[string]$Executable=''){
 $choice=if([string]::IsNullOrWhiteSpace($Method)){'auto'}else{$Method.Trim().ToLowerInvariant()}
 if($choice -eq 'auto'){
  # Xbox's bootstrap EXE has no rendering imports. A winmm alias does not
  # make MSFS Vulkan; identify this known title without reading protected PE data.
  $leaf=[IO.Path]::GetFileName($Executable)
  if($leaf -in @('FlightSimulator2024.exe','FlightSimulator.exe')){return 'DirectX'}
  if($leaf -eq 'gamelaunchhelper.exe'){
   $folder=Split-Path $Executable -Parent
   if((Test-Path -LiteralPath (Join-Path $folder 'FlightSimulator2024.exe') -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $folder 'FlightSimulator.exe') -PathType Leaf)){return 'DirectX'}
  }
  # DXGI attachment on a D3D9-importing executable uses a translation layer.
  if($EffectiveMethod -eq 'dxgi.dll' -and $ApiCandidates -contains 'DX9'){return 'DirectX'}
  $detected=ResolveOptiShadeRendererApi 'auto' $ApiCandidates
  if($detected -ne 'Auto'){return $detected}
  $effective=if([string]::IsNullOrWhiteSpace($EffectiveMethod)){'auto'}else{$EffectiveMethod.Trim().ToLowerInvariant()}
  if($effective -eq 'winmm.dll'){return 'Vulkan'}
  if($effective -eq 'd3d9.dll'){return 'DirectX9'}
  if($effective -eq 'opengl32.dll'){return 'OpenGL'}
  if($script:OptiShadeInstallMethods -contains $effective){return 'DirectX'}
  return 'Auto'
 }
 if($script:OptiShadeInstallMethods -notcontains $choice){throw 'The selected OptiShade installation method is not supported.'}
 if($choice -eq 'winmm.dll'){return 'Vulkan'}
 if($choice -eq 'd3d9.dll'){return 'DirectX9'}
 if($choice -eq 'opengl32.dll'){return 'OpenGL'}
 return 'DirectX'
}
function GetOptiShadeStoredMethod($Manifest){
 $allowed=@('auto')+$script:OptiShadeInstallMethods
 if($Manifest -and $Manifest.PSObject.Properties['InstallMethod'] -and $Manifest.InstallMethod -in $allowed){return [string]$Manifest.InstallMethod}
 if($Manifest -and $Manifest.PSObject.Properties['Files']){
  $loader=@($Manifest.Files|Where-Object {$_.SourcePath -eq 'winmm.dll'}|Select-Object -First 1)
  if($loader.Count -eq 1 -and $loader[0].Path -in $script:OptiShadeInstallMethods){return [string]$loader[0].Path}
 }
 if($Manifest -and $Manifest.PSObject.Properties['RendererApi']){
  if($Manifest.RendererApi -eq 'vulkan'){return 'winmm.dll'}
  if($Manifest.RendererApi -eq 'directx'){return 'dxgi.dll'}
 }
 return 'auto'
}
function ResolveOptiShadeRendererApi([string]$RendererApi,[string[]]$ApiCandidates=@()){
 switch($RendererApi.ToLowerInvariant()){
  'vulkan'{return 'Vulkan'}
  'directx'{return 'DirectX'}
  'directx9'{return 'DirectX9'}
  'opengl'{return 'OpenGL'}
  default{
   if($ApiCandidates -contains 'DX9'){return 'DirectX9'}
   if($ApiCandidates -contains 'OpenGL' -and -not (($ApiCandidates -contains 'DX10') -or ($ApiCandidates -contains 'DX11') -or ($ApiCandidates -contains 'DX12') -or ($ApiCandidates -contains 'Vulkan'))){return 'OpenGL'}
   $hasDirectX=($ApiCandidates -contains 'DX10') -or ($ApiCandidates -contains 'DX11') -or ($ApiCandidates -contains 'DX12')
   if(($ApiCandidates -contains 'Vulkan') -and -not $hasDirectX){return 'Vulkan'}
   if($hasDirectX){return 'DirectX'}
   return 'Auto'
  }
 }
}
function FormatFusionCompatibility($Plan){
 $lines=@(('GPU: '+$Plan.Gpu),('Performance: '+$Plan.Performance),$Plan.NeuralRendering)
 if($Plan.PSObject.Properties['DriverVersions']){foreach($driver in $Plan.DriverVersions){$lines+=('Driver: '+$driver.Name+' - '+$driver.Version+' (Windows: '+$driver.WindowsVersion+')')}}
 if($Plan.PSObject.Properties['NeuralRuntime']){$nr=$Plan.NeuralRuntime;$lines+=@(('Required model: '+$nr.Expected),('Model status: '+$nr.State+' - '+$nr.Message),('Checked location: '+$nr.Path),('Model file version: '+$nr.Version),$nr.DriverAssessment)}
 if($Plan.DownloadNvidia -and [IO.Path]::GetFileName($Plan.Executable) -ne 'X-Plane.exe'){$lines+='Automatic downloads: DLSS SR/RR 310.9.16 with Streamline 2.14.16. DLSS 4.5 activation depends on game and NVIDIA integration. The neural-rendering model may be selected locally per game; the installer accepts only a pinned SHA-256 and reports experimental builds separately.'}
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
