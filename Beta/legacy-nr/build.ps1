param([string]$NvidiaDlssSdkPath=$env:NVIDIA_DLSS_SDK_ROOT,[switch]$ReuseVerifiedHost64)
$ErrorActionPreference='Stop'
$legacy=$PSScriptRoot
if($NvidiaDlssSdkPath){$NvidiaDlssSdkPath=(Resolve-Path -LiteralPath $NvidiaDlssSdkPath -ErrorAction Stop).Path}
. (Join-Path $legacy 'build-identity.ps1')
if($ReuseVerifiedHost64){
 $reused=AssertOptiShadeLegacyWorkerReuse $legacy $NvidiaDlssSdkPath
 Write-Output "Reusing the exact legacy NR x64 worker and source/SDK receipt from verified OptiShade $($reused.Version); SDK evidence: $($reused.SdkEvidence)."
}else{
 if(-not $NvidiaDlssSdkPath){throw 'Set NVIDIA_DLSS_SDK_ROOT to the official NVIDIA DLSS SDK folder before building the x64 worker.'}
 $env:NVIDIA_DLSS_SDK_ROOT=$NvidiaDlssSdkPath
 $before=GetOptiShadeLegacyWorkerInputs $legacy $NvidiaDlssSdkPath
 $workerBuild='build-host64.bat'
 & "$env:ComSpec" /d /c ('"'+(Join-Path $legacy $workerBuild)+'"')
 if($LASTEXITCODE -ne 0){throw "Legacy NR build step failed: $workerBuild ($LASTEXITCODE)."}
 $after=GetOptiShadeLegacyWorkerInputs $legacy $NvidiaDlssSdkPath
 $null=WriteOptiShadeLegacyWorkerIdentity $legacy $before $after
}
foreach($script in @('build-client32.bat')){
 & "$env:ComSpec" /d /c ('"'+(Join-Path $legacy $script)+'"')
 if($LASTEXITCODE -ne 0){throw "Legacy NR build step failed: $script ($LASTEXITCODE)."}
}
$addon=Join-Path $legacy 'build/OptiShadeLegacyNR.addon32'
$worker=Join-Path $legacy 'build/dlss5-feed-host64.exe'
foreach($file in @($addon,$worker)){if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw "Expected legacy NR output is missing: $file"}}
function ReadPeMachine([string]$File){
 $stream=[IO.File]::OpenRead($File);$reader=[IO.BinaryReader]::new($stream)
 try{$stream.Position=0x3c;$pe=$reader.ReadUInt32();$stream.Position=$pe+4;return $reader.ReadUInt16()}finally{$reader.Dispose()}
}
if((ReadPeMachine $addon) -ne 0x14c){throw 'Legacy NR client did not build as x86.'}
if((ReadPeMachine $worker) -ne 0x8664){throw 'Legacy NR worker did not build as x64.'}
Write-Output "Built legacy NR client and worker in $legacy\build"
