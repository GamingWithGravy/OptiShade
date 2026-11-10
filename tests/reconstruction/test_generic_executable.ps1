$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Beta/installer/executable.ps1"
. "$root/Beta/installer/ownership.ps1"
. "$root/Beta/installer/library.ps1"
. "$root/Beta/installer/compatibility.ps1"
function Check($ok,$name){if(-not $ok){throw $name};Write-Output "PASS: $name"}
function HashFile([string]$Path){
 if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return ''}
 $sha=[Security.Cryptography.SHA256]::Create()
 try{return [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path))).Replace('-','')}
 finally{$sha.Dispose()}
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('optishade-pe-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temp)
try{
 $exe=Join-Path $temp 'Unlisted-Shipping.exe'
 # Valid bounded PE fixture with a real import directory. Never executed.
 $bytes=New-Object byte[] 1024;$memory=[IO.MemoryStream]::new($bytes,$true);$w=[IO.BinaryWriter]::new($memory)
 $w.Write([uint16]0x5a4d);$memory.Position=0x3c;$w.Write([uint32]0x80)
 $memory.Position=0x80;$w.Write([uint32]0x4550);$w.Write([uint16]0x8664);$w.Write([uint16]1)
 $memory.Position=0x94;$w.Write([uint16]240);$w.Write([uint16]2);$w.Write([uint16]0x20b)
 $memory.Position=0x98+60;$w.Write([uint32]512);$memory.Position=0x98+108;$w.Write([uint32]16)
 $memory.Position=0x98+120;$w.Write([uint32]0x1000);$w.Write([uint32]40)
 $memory.Position=0x98+240+8;$w.Write([uint32]512);$w.Write([uint32]0x1000);$w.Write([uint32]512);$w.Write([uint32]512)
 $memory.Position=512+12;$w.Write([uint32]0x1040)
 $memory.Position=576;$w.Write([Text.Encoding]::ASCII.GetBytes("d3d12.dll`0"));$w.Dispose()
 [IO.File]::WriteAllBytes($exe,$bytes)
 $id=GetOptiShadeExecutableIdentity $exe
 Check ($id.Architecture -eq 'x64' -and $id.ApiCandidates -contains 'DX12' -and $id.ApiObserved -eq 'Unknown') 'PE discovery preserves candidate/observed distinction'
 $delayBytes=[byte[]]$bytes.Clone();$delayMemory=[IO.MemoryStream]::new($delayBytes,$true);$delayWriter=[IO.BinaryWriter]::new($delayMemory)
 try{
  $delayMemory.Position=0x98+216;$delayWriter.Write([uint32]0x1080);$delayWriter.Write([uint32]64)
  $delayMemory.Position=640;$delayWriter.Write([uint32]1);$delayWriter.Write([uint32]0x10C0);1..6|ForEach-Object {$delayWriter.Write([uint32]0)}
  $delayMemory.Position=704;$delayWriter.Write([Text.Encoding]::ASCII.GetBytes("d3d11.dll`0"))
 }finally{$delayWriter.Dispose()}
 $delayExe=Join-Path $temp 'Delay-Load-Shipping.exe';[IO.File]::WriteAllBytes($delayExe,$delayBytes)
 $delayId=GetOptiShadeExecutableIdentity $delayExe
 Check ($delayId.Imports -contains 'd3d12.dll' -and $delayId.DelayImports -contains 'd3d11.dll' -and $delayId.ApiCandidates -contains 'DX12' -and $delayId.ApiCandidates -contains 'DX11' -and $delayId.ApiObserved -eq 'Unknown' -and $delayId.Evidence -match 'delay-load') 'PE discovery reports delay-load renderer candidates separately without treating them as an observed API'
 $actualIdentityReader=${function:GetOptiShadeExecutableIdentity}
 function GetOptiShadeExecutableIdentity([string]$File){throw [UnauthorizedAccessException]::new('Access denied fixture')}
 try{
  $recorded=[pscustomobject]@{Game=$temp;LaunchExe=$exe;Architecture='x64';Status='Installed';RouteDLL='OptiShadeGeneric.dll'}
  $denied=GetOptiShadeRenderingExecutable $recorded -AllowRecordedUnknown
  Check ($denied.Architecture -eq 'x64' -and $denied.SHA256 -eq '' -and $denied.ApiCandidates.Count -eq 0 -and $denied.Evidence -match 'read denied') 'component preparation can use verified installed x64 state when Xbox denies PE reads without inventing API or hash evidence'
  $strictDenied=$false;try{$null=GetOptiShadeRenderingExecutable $recorded}catch{$strictDenied=$true}
  Check $strictDenied 'executable read denial remains blocking for callers that need measured PE identity'
  $xboxGame=Join-Path $temp 'xbox-msfs';[void](New-Item -ItemType Directory -Path $xboxGame)
  $xboxHelper=Join-Path $xboxGame 'gamelaunchhelper.exe';$protectedRenderer=Join-Path $xboxGame 'FlightSimulator2024.exe'
  [IO.File]::WriteAllBytes($xboxHelper,[byte[]](1,2,3,4));[IO.File]::WriteAllBytes($protectedRenderer,[byte[]](5,6,7,8))
  $xboxRecord=[pscustomobject]@{Game=$xboxGame;LaunchExe=$xboxHelper;Architecture='x64';Status='Installed';RouteDLL='OptiShadeMSFS2024.dll'}
  $liveIdentity=GetOptiShadeRenderingExecutable $xboxRecord -AllowRecordedUnknown -ForLiveObservation
  Check ($liveIdentity.Path -ceq $protectedRenderer -and $liveIdentity.SHA256 -eq '' -and $liveIdentity.ApiCandidates.Count -eq 0) 'protected Xbox live observation binds renderer path rather than short-lived helper, without inventing hash/API'
  $liveStrictDenied=$false;try{$null=GetOptiShadeRenderingExecutable $xboxRecord -ForLiveObservation}catch{$liveStrictDenied=$true}
  Check $liveStrictDenied 'observation path selection alone never grants an unreadable-EXE fallback'
  $xboxFallback=GetOptiShadeRenderingExecutable $xboxRecord -AllowRecordedUnknown
  Check ($xboxFallback.Path -ceq $xboxHelper -and $xboxFallback.SHA256 -eq '' -and $xboxFallback.ApiCandidates.Count -eq 0 -and $xboxFallback.Evidence -match 'content launch helper selected' -and $xboxFallback.Evidence -match 'rendering executable read denied') 'Xbox component preparation retains the readable content helper as launch target without reading or misattributing the encrypted renderer PE'
 $autoSource=Get-Content (Join-Path $root 'Beta/installer/auto-compatibility.ps1') -Raw
 Check ($autoSource -match 'GetOptiShadeRenderingExecutable\s+\$Manifest\s+-AllowRecordedUnknown') 'Auto preparation opts into the guarded Xbox helper fallback instead of aborting while reading the encrypted renderer'
  $helper=Join-Path $temp 'gamelaunchhelper.exe';[IO.File]::WriteAllBytes($helper,[byte[]](1,2,3,4))
  $helperRecord=[pscustomobject]@{Game=$temp;LaunchExe=$helper;Architecture='x64';Status='Installed';RouteDLL='OptiShadeGeneric.dll'}
  $unknownHelper=GetOptiShadeRenderingExecutable $helperRecord -AllowRecordedUnknown
  Check ($unknownHelper.Architecture -eq 'x64' -and $unknownHelper.ApiCandidates.Count -eq 0 -and $unknownHelper.SHA256 -eq '' -and $unknownHelper.Evidence -match 'launch helper') 'installed Xbox generic launch helper permits component preparation while preserving unknown renderer and PE identity'
  $unknownLiveDenied=$false;try{$null=GetOptiShadeRenderingExecutable $helperRecord -AllowRecordedUnknown -ForLiveObservation}catch{$unknownLiveDenied=$true}
  Check $unknownLiveDenied 'unknown generic launch helper cannot masquerade as a rendering process for live observation'
  $helperStrict=$false;try{$null=GetOptiShadeRenderingExecutable $helperRecord}catch{$helperStrict=$_.Exception.Message -match 'no recorded qualified rendering executable'}
  Check $helperStrict 'unqualified Xbox helper remains unavailable outside explicit component preparation'
 }finally{Set-Item Function:GetOptiShadeExecutableIdentity $actualIdentityReader}
 Check (@(FindFusionExecutable $temp).Count -eq 0) 'unlisted folder reaches explicit executable selection'
 # Packaged UE launcher target resource: catalogue/root title differs from the
 # codename renderer, four directories below the catalogue root (Seafarer shape).
 $packaged=Join-Path $temp 'Packaged Game';$launchDir=Join-Path $packaged 'Windows';$renderDir=Join-Path $launchDir 'Codename/Binaries/Win64'
 [void][IO.Directory]::CreateDirectory($renderDir)
 $renderExe=Join-Path $renderDir 'Codename-Win64-Shipping.exe';[IO.File]::WriteAllBytes($renderExe,$bytes)
 $bootstrap=Join-Path $launchDir 'Packaged Game.exe'
 function WriteBootstrapFixture([string]$Target){
  $resourceBytes=New-Object byte[] 2048;[Array]::Copy($bytes,$resourceBytes,$bytes.Length)
  $mem=[IO.MemoryStream]::new($resourceBytes,$true);$bw=[IO.BinaryWriter]::new($mem)
  try{
   $mem.Position=0x98+240+8;$bw.Write([uint32]1536);$bw.Write([uint32]0x1000);$bw.Write([uint32]1536)
   $mem.Position=0x98+128;$bw.Write([uint32]0x1080);$bw.Write([uint32]1024)
   foreach($offset in @(0,24,48)){$mem.Position=640+$offset+14;$bw.Write([uint16]1)}
   $mem.Position=656;$bw.Write([uint32]10);$bw.Write([uint32]2147483672)
   $mem.Position=680;$bw.Write([uint32]201);$bw.Write([uint32]2147483696)
   $mem.Position=704;$bw.Write([uint32]1033);$bw.Write([uint32]72)
   $targetBytes=[Text.Encoding]::Unicode.GetBytes($Target+[char]0)
   $mem.Position=712;$bw.Write([uint32]0x10E0);$bw.Write([uint32]$targetBytes.Length)
   $mem.Position=736;$bw.Write($targetBytes)
  }finally{$bw.Dispose()}
  [IO.File]::WriteAllBytes($bootstrap,$resourceBytes)
 }
 WriteBootstrapFixture 'Codename\Binaries\Win64\Codename-Win64-Shipping.exe'
 $choice=@(FindFusionExecutable $packaged 'Steam' 'Packaged Game')
 Check ($choice.Count -eq 1 -and $choice[0].Path -eq $renderExe -and $choice[0].LaunchPath -eq $bootstrap) 'embedded launcher resource selects the nested renderer and retains native launch'
 $target=GetFusionGameTargetFolder ([pscustomobject]@{Folder=$packaged;InstallFolder=$launchDir;Launcher='Steam';Name='Packaged Game'})
 Check ($target -eq $renderDir) 'catalogue and stale bootstrap folder resolve to the same rendering install target'
 Check ((GetFusionNativeLaunchExecutable ([pscustomobject]@{NativeLaunchExe=$bootstrap}) $renderExe) -eq $bootstrap) 'native bootstrap launch is retained only when its target still matches'
 WriteBootstrapFixture '..\Elsewhere\Binaries\Win64\Other.exe'
 $blocked=$false;try{$null=ResolveFusionBootstrapExecutable $bootstrap}catch{$blocked=$true}
 Check $blocked 'escaping embedded target is rejected before installation'
 WriteBootstrapFixture 'Missing\Binaries\Win64\Missing.exe'
 Check (@(FindFusionExecutable $packaged 'Steam' 'Packaged Game').Count -eq 0) 'missing packaged renderer never falls back to installing beside its launcher'
 WriteBootstrapFixture 'Codename\Binaries\Win64\Codename-Win64-Shipping.exe'
 $truckRoot=Join-Path $temp 'Euro Truck Simulator 2';$truckBin=Join-Path $truckRoot 'bin/win_x64';[void](New-Item -ItemType Directory -Path $truckBin -Force)
 $truckExe=Join-Path $truckBin 'eurotrucks2.exe';Copy-Item -LiteralPath $exe -Destination $truckExe
 $truckMatch=@(FindFusionExecutable $truckRoot 'Steam' 'Euro Truck Simulator 2')
 Check ($truckMatch.Count -eq 1 -and $truckMatch[0].Path -eq $truckExe) 'known Steam game executable is selected automatically from its real binary folder'
 $beamRoot=Join-Path $temp 'BeamNG.drive';$beamBin=Join-Path $beamRoot 'bin/win_x64';[void](New-Item -ItemType Directory -Path $beamBin -Force)
 $beamExe=Join-Path $beamBin 'BeamNG.drive.x64.exe';Copy-Item -LiteralPath $exe -Destination $beamExe
 $beamMatch=@(FindFusionExecutable $beamRoot 'Steam' 'BeamNG.drive')
 Check ($beamMatch.Count -eq 1 -and $beamMatch[0].Path -eq $beamExe) 'BeamNG executable is selected automatically by matching its game title'
 $ambiguousRoot=Join-Path $temp 'Euro Truck Simulator 2 - Ambiguous';$ambiguousBin=Join-Path $ambiguousRoot 'bin';[void](New-Item -ItemType Directory -Path $ambiguousBin -Force)
 Copy-Item -LiteralPath $exe -Destination (Join-Path $ambiguousBin 'eurotrucks2.exe');Copy-Item -LiteralPath $exe -Destination (Join-Path $ambiguousBin 'ets2.exe')
 Check (@(FindFusionExecutable $ambiguousRoot 'Steam' 'Euro Truck Simulator 2').Count -eq 0) 'ambiguous game executables remain unselected instead of guessing'
 # Generic executable folders take the nearest real folder name (DCS World report).
 Check ((GetFusionFolderTitle 'F:\Program Files\Eagle Dynamics\DCS World\bin') -eq 'DCS World') 'a game in a bin folder is named after its parent folder'
 Check ((GetFusionFolderTitle 'D:\Games\AC2\Binaries\Win64') -eq 'AC2') 'Unreal Binaries\Win64 folders are skipped for the title'
 Check ((GetFusionFolderTitle 'E:\x64') -eq 'Unidentified game (x64)') 'a generic folder with no real parent stays unidentified'
 # GIANTS' root FarmingSimulator EXE only starts x64\<name>Game.exe (OSD-NXJ5).
 $farmRoot=Join-Path $temp 'Farming Simulator 25';$farmBin=Join-Path $farmRoot 'x64';[void](New-Item -ItemType Directory -Path $farmBin -Force)
 $farmStub=Join-Path $farmRoot 'FarmingSimulator2025.exe';Copy-Item -LiteralPath $exe -Destination $farmStub
 $farmGame=Join-Path $farmBin 'FarmingSimulator2025Game.exe';Copy-Item -LiteralPath $exe -Destination $farmGame
 Check ((ResolveFusionBootstrapExecutable $farmStub) -eq [IO.Path]::GetFullPath($farmGame)) 'Farming Simulator stub launcher resolves to its x64 game executable'
 Check ((ResolveFusionBootstrapExecutable $farmGame) -eq $farmGame) 'Farming Simulator game executable resolves to itself'
 Remove-Item -LiteralPath $farmGame
 Check ((ResolveFusionBootstrapExecutable $farmStub) -eq $farmStub) 'Farming Simulator EXE without an x64 game executable is kept as selected'
 $gpu=[pscustomobject]@{Known=$true;Names='NVIDIA GeForce RTX 5090'}
 $plan=GetFusionCompatibility $temp $exe $gpu
 Check ($plan.RouteDLL -eq 'OptiShadeGeneric.dll' -and $plan.EstimatedNrCandidate -and -not $plan.PossibleInput) 'non-DLSS candidate does not invent a native upscaler'
 Check $plan.DownloadNvidia 'qualified discovery candidate can acquire matching NR dependencies'
 Check ((GetOptiShadeRendererProxy 'vulkan' $plan.Proxy) -eq 'winmm.dll' -and (GetOptiShadeRendererProxy 'directx' $plan.Proxy) -eq 'dxgi.dll') 'explicit renderer selection maps Vulkan to WinMM and DirectX to DXGI'
 Check ((ResolveOptiShadeRendererApi 'vulkan' @('DX11','Vulkan')) -eq 'Vulkan' -and (ResolveOptiShadeRendererApi 'directx' @('DX11','Vulkan')) -eq 'DirectX' -and (ResolveOptiShadeRendererApi 'auto' @('DX11','Vulkan')) -eq 'DirectX' -and (ResolveOptiShadeRendererApi 'auto' @()) -eq 'Auto') 'explicit API selection handles dynamic, dual-API and unknown executables predictably'
 [Array]::Clear($bytes,576,64);$vulkanName=[Text.Encoding]::ASCII.GetBytes("vulkan-1.dll`0");[Array]::Copy($vulkanName,0,$bytes,576,$vulkanName.Length);[IO.File]::WriteAllBytes($exe,$bytes)
 $vulkanId=GetOptiShadeExecutableIdentity $exe;$vulkanPlan=GetFusionCompatibility $temp $exe $gpu
 Check ($vulkanId.ApiCandidates -contains 'Vulkan' -and $vulkanPlan.Proxy -eq 'winmm.dll') 'automatic Vulkan install selects the multimedia entry point used by the generic Vulkan bridge'
 [Array]::Clear($bytes,576,64);$dx11Name=[Text.Encoding]::ASCII.GetBytes("d3d11.dll`0");[Array]::Copy($dx11Name,0,$bytes,576,$dx11Name.Length);[IO.File]::WriteAllBytes($exe,$bytes)
 $dx11Id=GetOptiShadeExecutableIdentity $exe;$dx11Plan=GetFusionCompatibility $temp $exe $gpu
 Check ($dx11Id.ApiCandidates -contains 'DX11' -and $dx11Plan.Proxy -eq 'dxgi.dll' -and $dx11Plan.Performance -match 'one model pass') 'automatic DX11 plan selects DXGI and explains the current experimental one-pass NR route'
 [Array]::Clear($bytes,576,64);$winmmName=[Text.Encoding]::ASCII.GetBytes("winmm.dll`0");[Array]::Copy($winmmName,0,$bytes,576,$winmmName.Length);[IO.File]::WriteAllBytes($exe,$bytes)
 $dynamicId=GetOptiShadeExecutableIdentity $exe;$dynamicPlan=GetFusionCompatibility $temp $exe $gpu
 Check ($dynamicId.ApiCandidates.Count -eq 0 -and $dynamicId.Imports -contains 'winmm.dll' -and $dynamicPlan.Proxy -eq 'winmm.dll') 'dynamically selected renderer with a WinMM import gets a loader that the game will load'
 # Validate generic dual-API Vulkan launch setup without ever starting the fixture process.
 function TestOptiShadeElevated { return $false }
 [Array]::Clear($bytes,576,64);$vulkanName=[Text.Encoding]::ASCII.GetBytes("vulkan-1.dll`0");[Array]::Copy($vulkanName,0,$bytes,576,$vulkanName.Length)
 $bytes[0x98+124]=60;$bytes[0x98+125]=0;$bytes[0x98+126]=0;$bytes[0x98+127]=0
 $bytes[532+12]=0x60;$bytes[532+13]=0x10;$bytes[532+14]=0;$bytes[532+15]=0
 $dx11Name=[Text.Encoding]::ASCII.GetBytes("d3d11.dll`0");[Array]::Copy($dx11Name,0,$bytes,608,$dx11Name.Length)
 $dualExe=Join-Path $temp 'Unlisted-Shipping-Dual-API.exe';[IO.File]::WriteAllBytes($dualExe,$bytes)
 $dualId=GetOptiShadeExecutableIdentity $dualExe
 Check ($dualId.ApiCandidates -contains 'Vulkan' -and $dualId.ApiCandidates -contains 'DX11') 'dual-API executable retains both rendering candidates for runtime selection'
 $launchGame=Join-Path $temp 'vulkan-game';$launchStore=Join-Path $temp 'vulkan-store';[void](New-Item -ItemType Directory -Path $launchGame,$launchStore -Force)
 $launchExe=Join-Path $launchGame 'neutral-vulkan.exe';Copy-Item -LiteralPath $dualExe -Destination $launchExe
 $layerRoot=Join-Path $launchGame 'OptiShadeData/Vulkan';[void](New-Item -ItemType Directory -Path $layerRoot -Force)
 $layerJson=Join-Path $layerRoot 'OptiShade.json';'{"file_format_version":"1.2.0","layer":{"name":"VK_LAYER_OptiShade_effects","type":"GLOBAL","library_path":"..\\..\\ReShade64.dll","api_version":"1.3.268"}}'|Set-Content -LiteralPath $layerJson -Encoding ASCII
 $reshade=Join-Path $launchGame 'ReShade64.dll';[IO.File]::WriteAllBytes($reshade,[byte[]](1,2,3,4))
 $loader=Join-Path $launchGame 'winmm.dll';[IO.File]::WriteAllBytes($loader,[byte[]](5,6,7,8))
 $launchFiles=@(
  [pscustomobject]@{Path='OptiShadeData/Vulkan/OptiShade.json';SourcePath='OptiShadeData/Vulkan/OptiShade.json';Hash=(HashFile $layerJson)},
  [pscustomobject]@{Path='ReShade64.dll';SourcePath='ReShade64.dll';Hash=(HashFile $reshade)},
  [pscustomobject]@{Path='winmm.dll';SourcePath='winmm.dll';Hash=(HashFile $loader)}
 )
 $manifestPath=ManifestPath $launchStore $launchGame;[void](New-Item -ItemType Directory -Path (Split-Path $manifestPath) -Force)
 $manifest=[pscustomobject]@{Version='0.21.7';Game=$launchGame;Status='Installed';RouteDLL='OptiShadeGeneric.dll';LaunchExe=$launchExe;Files=$launchFiles}
 WriteState $manifest $manifestPath
 $startInfo=NewOptiShadeXPlaneStartInfo $launchExe $launchStore
 Check ($startInfo.FileName -eq $launchExe -and $startInfo.EnvironmentVariables['VK_INSTANCE_LAYERS'] -match 'VK_LAYER_OptiShade_effects' -and -not $startInfo.EnvironmentVariables['RESHADE_DISABLE_GRAPHICS_HOOK']) 'generic Vulkan Play accepts an owned winmm.dll bridge and preserves DX11 when the game ships both APIs'
 $gpu.Names='AMD Radeon';$plan=GetFusionCompatibility $temp $exe $gpu
 Check (-not $plan.EstimatedNrCandidate -and -not $plan.DownloadNvidia) 'absent AMD inference backend is not advertised'
 $x86Exe=Join-Path $temp 'SanAndreas.exe';$bytes32=New-Object byte[] 1024;$memory32=[IO.MemoryStream]::new($bytes32,$true);$w32=[IO.BinaryWriter]::new($memory32)
 $w32.Write([uint16]0x5a4d);$memory32.Position=0x3c;$w32.Write([uint32]0x80)
 $memory32.Position=0x80;$w32.Write([uint32]0x4550);$w32.Write([uint16]0x14c);$w32.Write([uint16]1)
 $memory32.Position=0x94;$w32.Write([uint16]224);$w32.Write([uint16]2);$w32.Write([uint16]0x10b)
 $memory32.Position=0x98+60;$w32.Write([uint32]512);$memory32.Position=0x98+92;$w32.Write([uint32]16)
 $memory32.Position=0x98+104;$w32.Write([uint32]0x1000);$w32.Write([uint32]40)
 $memory32.Position=0x98+224+8;$w32.Write([uint32]512);$w32.Write([uint32]0x1000);$w32.Write([uint32]512);$w32.Write([uint32]512)
 $memory32.Position=512+12;$w32.Write([uint32]0x1040);$memory32.Position=576;$w32.Write([Text.Encoding]::ASCII.GetBytes("d3d9.dll`0"));$w32.Dispose()
 [IO.File]::WriteAllBytes($x86Exe,$bytes32);$x86Id=GetOptiShadeExecutableIdentity $x86Exe;$x86Plan=GetFusionCompatibility $temp $x86Exe $gpu
 Check ($x86Id.Architecture -eq 'x86' -and $x86Id.ApiCandidates -contains 'DX9') 'PE32 inspection identifies a 32-bit DirectX 9 game'
 Check ($x86Plan.Proxy -eq 'd3d9.dll' -and -not $x86Plan.DownloadNvidia -and $x86Plan.NeuralRendering -match 'external D3D9-to-D3D11 wrapper') 'native x86 D3D9 keeps the matching ReShade hook and explains the external NR wrapper requirement'
 [IO.File]::WriteAllText((Join-Path $temp 'D3D9.dll'),'external wrapper');[IO.File]::WriteAllText((Join-Path $temp 'dgVoodoo.conf'),"[DirectX]`nDisableAndPassThru=false`nOutputAPI=d3d11_fl11_0`n")
 Check ((TestOptiShadeLegacyD3D9Wrapper $temp) -and (GetFusionCompatibility $temp $x86Exe $gpu).Proxy -eq 'dxgi.dll') 'configured dgVoodoo D3D9-to-D3D11 wrapper selects DXGI without replacing D3D9.dll'
 [Array]::Clear($bytes32,576,64);$dx11x86=[Text.Encoding]::ASCII.GetBytes("d3d11.dll`0");[Array]::Copy($dx11x86,0,$bytes32,576,$dx11x86.Length);[IO.File]::WriteAllBytes($x86Exe,$bytes32)
 Check ((GetFusionCompatibility $temp $x86Exe $gpu).Proxy -eq 'dxgi.dll') '32-bit DirectX 10/11/12 uses the ReShade DXGI hook'
 [Array]::Clear($bytes32,576,64);$openglx86=[Text.Encoding]::ASCII.GetBytes("opengl32.dll`0");[Array]::Copy($openglx86,0,$bytes32,576,$openglx86.Length);[IO.File]::WriteAllBytes($x86Exe,$bytes32)
 Check ((GetFusionCompatibility $temp $x86Exe $gpu).Proxy -eq 'opengl32.dll') '32-bit OpenGL uses its matching ReShade hook'
 [Array]::Clear($bytes32,576,64);$vulkanx86=[Text.Encoding]::ASCII.GetBytes("vulkan-1.dll`0");[Array]::Copy($vulkanx86,0,$bytes32,576,$vulkanx86.Length);[IO.File]::WriteAllBytes($x86Exe,$bytes32)
 $vulkanX86Plan=GetFusionCompatibility $temp $x86Exe $gpu
 Check ($vulkanX86Plan.Proxy -eq 'unsupported' -and -not $vulkanX86Plan.DownloadNvidia) '32-bit Vulkan is blocked clearly instead of receiving an incompatible x64 hook'
 [IO.File]::WriteAllBytes($exe,[byte[]](0x4d,0x5a))
 $rejected=$false;try{$null=GetOptiShadeExecutableIdentity $exe}catch{$rejected=$true}
 Check $rejected 'truncated PE rejected before seeking'
 $ownerTokens=$null;$ownerErrors=$null
 $ownerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Beta/installer/ownership.ps1'),[ref]$ownerTokens,[ref]$ownerErrors)
 if($ownerErrors.Count){throw $ownerErrors[0]}
 $importFunction=$ownerAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'ImportNrRuntime'},$true)
 $identityCall=$importFunction.Find({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'GetOptiShadeRenderingExecutable'},$true)
 Check ($identityCall -and $identityCall.Extent.Text -match '(?i)-AllowRecordedUnknown\b') 'verified Neural model import uses the scoped installed-x64 fallback when the Xbox game EXE cannot be read'
 $importGame=Join-Path $temp 'denied-import-game';[void](New-Item -ItemType Directory -Path $importGame -Force)
 $importExe=Join-Path $importGame 'FlightSimulator2024.exe';Copy-Item -LiteralPath $exe -Destination $importExe
 $importSource=Join-Path $temp 'verified-model.fixture';[IO.File]::WriteAllText($importSource,'pinned model fixture')
 $script:importModelHash=HashFile $importSource;$script:importAfter=$null
 $script:importManifest=[pscustomobject]@{Status='Installed';Game=$importGame;LaunchExe=$importExe;Architecture='x64';RouteDLL='OptiShadeMSFS2024.dll';Files=@()}
 function EnterOptiShadeMutation{return $null};function ExitOptiShadeMutation($Token){}
 function RecoverOptiShadeRouteTransaction($ManifestPath){return $false}
 function ReadOptiShadeState($ManifestPath){return $script:importManifest}
 function AssertClosed([string]$Game){}
 function AssertAntiCheatMutation([string]$Game,[string]$Executable,[string]$Operation){}
 function GetOptiShadeExecutableIdentity([string]$File){
  $denied=[UnauthorizedAccessException]::new('Access denied fixture')
  throw [Management.Automation.MethodInvocationException]::new('Exception calling OpenRead', $denied)
 }
 function ResolveOptiShadeNeuralAdapter($Manifest,$Gpu){
  return [pscustomobject]@{State='candidate';Adapter=[pscustomobject]@{Luid='0x0000000000000001';VendorId=[uint32]0x10de;DeviceId=[uint32]0x2782;SubSystemId=[uint32]0;ComputeMajor=8;ComputeMinor=9;Family=40;DriverVersion='fixture';Name='NVIDIA RTX fixture'}}
 }
 function GetOptiShadeNeuralModelByHash([string]$Hash){
  if($Hash -eq $script:importModelHash){return [pscustomobject]@{Variant='auto';Families=@(40);Signed=$false;Family='RTX 40 fixture model'}}
  return $null
 }
 function InvokeOptiShadeRouteTransaction($ManifestPath,$BeforeReceiptHash,$AfterManifest,$Changes,$RollbackRelative,$Purpose){$script:importAfter=$AfterManifest}
 ImportNrRuntime (Join-Path $temp 'manifest.fixture') $importSource 'auto' ([pscustomobject]@{Adapters=@();PreferredRenderingLuid='0x0000000000000001'})
 Check ($script:importAfter -and $script:importAfter.NeuralPreparation.ExecutableHash -eq '' -and $script:importAfter.NeuralRuntimeHash -eq $script:importModelHash -and $script:importAfter.NeuralAdapter.Family -eq 40) 'verified Neural model import completes with a wrapped Xbox read-denial while recording unknown executable hash'
}finally{
 $resolved=[IO.Path]::GetFullPath($temp);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'optishade-pe-*'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
