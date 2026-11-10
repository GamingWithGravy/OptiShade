# Content identity for the x64 worker. This deliberately includes the shared
# client/worker contract closure: rebuilding only one side cannot admit an old
# host merely because a copied source file kept its previous timestamp.
function ResolveOptiShadeLegacyBuildFile([string]$Root,[string]$Relative){
 if(-not $Relative -or [IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)|[\r\n\t]'){throw ('Legacy worker input is outside its recorded root: '+$Relative)}
 $base=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
 $path=[IO.Path]::GetFullPath((Join-Path $base $Relative));$prefix=$base+[IO.Path]::DirectorySeparatorChar
 if(-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw ('Legacy worker input escaped its root: '+$Relative)}
 $check=$path
 while($check -and $check.Length -ge $base.Length){
  if((Test-Path -LiteralPath $check) -and ((Get-Item -LiteralPath $check -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw ('Linked legacy worker input requires an ordinary source path: '+$Relative)}
  $next=Split-Path $check -Parent;if($next -eq $check){break};$check=$next
 }
 if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw ('Required legacy worker build input is missing: '+$Relative)}
 return $path
}
function GetOptiShadeLegacyIdentityDigest([string]$Text){
 $sha=[Security.Cryptography.SHA256]::Create()
 try{return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','')}finally{$sha.Dispose()}
}
function GetOptiShadeLegacyEntriesDigest([object[]]$Files){
 if(-not $Files.Count -or $Files.Count -gt 20000){throw 'Legacy worker input inventory is missing or excessive.'}
 $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$map=@{}
 foreach($entry in $Files){
  $relative=[string]$entry.Path
  if(-not $relative -or $relative.Contains('\') -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|/)\.\.?(/|$)|[\r\n\t]' -or [string]$entry.SHA256 -cnotmatch '^[A-F0-9]{64}$' -or $entry.Size -isnot [ValueType] -or $entry.Size -lt 0 -or [decimal]$entry.Size -ne [long]$entry.Size -or -not $seen.Add($relative)){throw 'Legacy worker input inventory contains an invalid or duplicate identity.'}
  $map[$relative]=$entry
 }
 $ordered=[string[]]@($map.Keys);[Array]::Sort($ordered,[StringComparer]::Ordinal);$lines=[Collections.Generic.List[string]]::new()
 foreach($relative in $ordered){$entry=$map[$relative];$lines.Add($relative+"`t"+([long]$entry.Size).ToString([Globalization.CultureInfo]::InvariantCulture)+"`t"+[string]$entry.SHA256)}
 return GetOptiShadeLegacyIdentityDigest ($lines -join "`n")
}
function GetOptiShadeLegacyFileIdentity([string]$Root,[string[]]$Paths){
 $unique=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
 foreach($relative in $Paths){[void]$unique.Add($relative.Replace('\','/'))}
 $ordered=[string[]]@($unique);[Array]::Sort($ordered,[StringComparer]::Ordinal);$files=@()
 foreach($relative in $ordered){
  $path=ResolveOptiShadeLegacyBuildFile $Root $relative;$stream=[IO.File]::OpenRead($path);$sha=[Security.Cryptography.SHA256]::Create()
  try{$files+=[pscustomobject]@{Path=$relative;Size=[long]$stream.Length;SHA256=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','')}}finally{$sha.Dispose();$stream.Dispose()}
 }
 return [pscustomobject]@{SHA256=(GetOptiShadeLegacyEntriesDigest $files);Files=$files}
}
function GetOptiShadeLegacyTreePaths([string]$Root,[string]$Relative,[string[]]$Extensions){
 $directory=Join-Path $Root $Relative
 if(-not(Test-Path -LiteralPath $directory -PathType Container)){throw ('Required legacy worker input directory is missing: '+$Relative)}
 if((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Linked legacy worker input directory is not admitted: '+$Relative)}
 $prefix=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
 $queue=[Collections.Generic.Queue[string]]::new();$queue.Enqueue($directory);$paths=@()
 while($queue.Count){foreach($item in @(Get-ChildItem -LiteralPath $queue.Dequeue() -Force)){
  if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Linked legacy worker input is not admitted: '+$item.FullName)}
  if($item.PSIsContainer){$queue.Enqueue($item.FullName)}elseif($item.Extension.ToLowerInvariant() -in $Extensions){$paths+=,$item.FullName.Substring($prefix.Length).Replace('\','/')}
 }}
 if(-not $paths.Count){throw ('Required legacy worker input directory is empty: '+$Relative)}
 return $paths
}
function GetOptiShadeLegacyWorkerSourceIdentity([string]$LegacyRoot){
 $beta=Split-Path ([IO.Path]::GetFullPath($LegacyRoot)) -Parent
 $required=@(
  'legacy-nr/build.ps1','legacy-nr/build-identity.ps1','legacy-nr/build-host64.bat','legacy-nr/upstream/tools/vcvars.bat','legacy-nr/upstream/host/dlss5-feed-host64.cpp',
  'shared/AutoCompatibility.h','shared/RuntimeControlProtocol.h','shared/MfgControlWin.h','shared/NeuralRuntimeReceipt.h','shared/NeuralModelPolicy.generated.h','shared/RenderingGpuProbeWin.h','shared/RenderingGpuPolicy.h',
  'shared/neural-model-policy.json','shared/provider-policy.json','reconstruction/generate_provider_policy.py','optiscaler/external/nlohmann/json.hpp',
  'reshade/res/shaders/optishade_guides.hlsl','reshade/res/shaders/optishade_guides.dxbc.h','reshade/res/shaders/optishade_guides.generated.h','reshade/res/shaders/optishade_guides.glsl.h'
 )
 foreach($relative in $required){[void](ResolveOptiShadeLegacyBuildFile $beta $relative)}
 $paths=@($required)
 $paths+=@(GetOptiShadeLegacyTreePaths $beta 'legacy-nr/upstream/host' @('.c','.cc','.cpp','.cxx','.h','.hh','.hpp','.hxx','.inl','.inc'))
 $paths+=@(GetOptiShadeLegacyTreePaths $beta 'legacy-nr/upstream/src' @('.h','.hh','.hpp','.hxx','.inl','.inc'))
 $paths+=@(GetOptiShadeLegacyTreePaths $beta 'shared' @('.h','.hh','.hpp','.hxx','.inl','.inc','.json'))
 $paths+=@(GetOptiShadeLegacyTreePaths $beta 'optiscaler/external/nlohmann' @('.h','.hh','.hpp','.hxx','.inl','.inc'))
 # Discover literal project includes from the worker. Enumerating a directory
 # alone must not let a missing direct/transitive header silently disappear.
 $prefix=[IO.Path]::GetFullPath($beta).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
 $pending=[Collections.Generic.Queue[string]]::new();$pending.Enqueue('legacy-nr/upstream/host/dlss5-feed-host64.cpp')
 $visited=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 while($pending.Count){
  $relative=$pending.Dequeue();if(-not $visited.Add($relative)){continue}
  $path=ResolveOptiShadeLegacyBuildFile $beta $relative;$paths+=,$relative
  foreach($include in [regex]::Matches([IO.File]::ReadAllText($path),'(?m)^\s*#\s*include\s*(["<])([^">]+)[">]')){
   $name=$include.Groups[2].Value;$quoted=$include.Groups[1].Value -eq '"';$candidate=$null
   if($quoted){$candidate=[IO.Path]::GetFullPath((Join-Path (Split-Path $path -Parent) $name))}
   if(-not $candidate -or -not(Test-Path -LiteralPath $candidate -PathType Leaf)){
    $jsonCandidate=Join-Path $beta ('optiscaler/external/nlohmann/'+$name)
    if(Test-Path -LiteralPath $jsonCandidate -PathType Leaf){$candidate=[IO.Path]::GetFullPath($jsonCandidate)}elseif(-not $quoted){continue}
   }
   if(-not $candidate -or -not $candidate.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw ('Worker project include escapes the source tree: '+$name)}
   $next=$candidate.Substring($prefix.Length).Replace('\','/');[void](ResolveOptiShadeLegacyBuildFile $beta $next);$pending.Enqueue($next)
  }
 }
 return GetOptiShadeLegacyFileIdentity $beta $paths
}
function AssertOptiShadeLegacySdkIdentity($Identity){
 if(-not $Identity -or [string]$Identity.Kind -cne 'NVIDIA_DLSS_SDK_x64' -or [string]$Identity.SHA256 -cnotmatch '^[A-F0-9]{64}$' -or [string]$Identity.SHA256 -cne (GetOptiShadeLegacyEntriesDigest @($Identity.Files))){throw 'The original NVIDIA SDK content identity is missing or malformed. Build the worker with the official SDK.'}
 $required=@('include/nvsdk_ngx.h','include/nvsdk_ngx_helpers.h','include/nvsdk_ngx_defs_dlssd.h','lib/Windows_x86_64/x64/nvsdk_ngx_d.lib')
 foreach($path in $required){if(@($Identity.Files|Where-Object {$_.Path -ceq $path -and $_.Size -gt 0}).Count -ne 1){throw ('The original NVIDIA SDK provenance is incomplete: '+$path)}}
 foreach($entry in @($Identity.Files)){if([string]$entry.Path -cne $required[-1] -and [string]$entry.Path -cnotmatch '^include/.+\.(?:h|hh|hpp|hxx|inl|inc|cuh)$'){throw 'The recorded NVIDIA SDK identity contains an unexpected input.'}}
}
function GetOptiShadeLegacySdkIdentity([string]$NvidiaDlssSdkPath){
 if(-not $NvidiaDlssSdkPath -or -not(Test-Path -LiteralPath $NvidiaDlssSdkPath -PathType Container)){throw 'Set NVIDIA_DLSS_SDK_ROOT to the official NVIDIA DLSS SDK folder. Its headers and x64 link library are required for a fresh worker build.'}
 $paths=@(GetOptiShadeLegacyTreePaths $NvidiaDlssSdkPath 'include' @('.h','.hh','.hpp','.hxx','.inl','.inc','.cuh'))+@('lib/Windows_x86_64/x64/nvsdk_ngx_d.lib')
 $identity=GetOptiShadeLegacyFileIdentity $NvidiaDlssSdkPath $paths;$identity|Add-Member Kind 'NVIDIA_DLSS_SDK_x64'
 AssertOptiShadeLegacySdkIdentity $identity;return $identity
}
function GetOptiShadeLegacyWorkerInputs([string]$LegacyRoot,[string]$NvidiaDlssSdkPath,$RecordedSdk=$null){
 $source=GetOptiShadeLegacyWorkerSourceIdentity $LegacyRoot
 if($NvidiaDlssSdkPath){$sdk=GetOptiShadeLegacySdkIdentity $NvidiaDlssSdkPath}else{AssertOptiShadeLegacySdkIdentity $RecordedSdk;$sdk=$RecordedSdk}
 $identity=GetOptiShadeLegacyIdentityDigest ("OptiShadeLegacyWorkerInputs/1`n"+$source.SHA256+"`n"+$sdk.SHA256)
 return [pscustomobject]@{SHA256=$identity;Sources=$source;NvidiaDlssSdk=$sdk}
}
function GetOptiShadeLegacyWorkerMachine([string]$Path){
 $stream=[IO.File]::OpenRead($Path);$reader=[IO.BinaryReader]::new($stream)
 try{if($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5a4d){throw 'Legacy worker output is not a PE executable.'};$stream.Position=0x3c;$pe=$reader.ReadUInt32();if([long]$pe+24 -gt $stream.Length){throw 'Legacy worker PE header is truncated.'};$stream.Position=$pe;if($reader.ReadUInt32() -ne 0x4550){throw 'Legacy worker PE signature is invalid.'};return $reader.ReadUInt16()}finally{$reader.Dispose()}
}
function WriteOptiShadeLegacyWorkerIdentity([string]$LegacyRoot,$Before,$After){
 if(-not $Before -or -not $After -or [string]$Before.SHA256 -cnotmatch '^[A-F0-9]{64}$' -or [string]$Before.SHA256 -cne [string]$After.SHA256){throw 'Legacy worker source or SDK inputs changed while compiling. Rebuild before recording or reusing this worker.'}
 if($After.Sources.SHA256 -cne (GetOptiShadeLegacyEntriesDigest @($After.Sources.Files))){throw 'The worker source identity does not match its input inventory.'};AssertOptiShadeLegacySdkIdentity $After.NvidiaDlssSdk
 $expected=GetOptiShadeLegacyIdentityDigest ("OptiShadeLegacyWorkerInputs/1`n"+$After.Sources.SHA256+"`n"+$After.NvidiaDlssSdk.SHA256)
 if($expected -cne [string]$After.SHA256){throw 'The worker input identity is inconsistent.'}
 $worker=ResolveOptiShadeLegacyBuildFile $LegacyRoot 'build/dlss5-feed-host64.exe'
 if((GetOptiShadeLegacyWorkerMachine $worker) -ne 0x8664){throw 'Legacy NR worker did not build as x64.'}
 $receipt=[ordered]@{Schema=1;Kind='OptiShadeLegacyWorkerBuild';InputsSHA256=$After.SHA256;Sources=$After.Sources;NvidiaDlssSdk=$After.NvidiaDlssSdk;WorkerPath='legacy-nr/build/dlss5-feed-host64.exe';WorkerSHA256=(Get-FileHash -LiteralPath $worker -Algorithm SHA256).Hash;BuiltUtc=[DateTime]::UtcNow.ToString('o')}
 $path=Join-Path $LegacyRoot 'build/worker-identity.json';$temporary=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 try{
  [IO.File]::WriteAllText($temporary,($receipt|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
  $stream=[IO.File]::Open($temporary,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);try{$stream.Flush($true)}finally{$stream.Dispose()}
  if(Test-Path -LiteralPath $path){[IO.File]::Replace($temporary,$path,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temporary,$path)}
 }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
 return $receipt
}
function ReadOptiShadeLegacyBuildJson([string]$Path){
 $stream=[IO.File]::OpenRead($Path)
 try{
  if($stream.Length -lt 2 -or $stream.Length -gt 16777216){throw 'Legacy build evidence is empty or excessive.'}
  $memory=[IO.MemoryStream]::new();try{$stream.CopyTo($memory);$bytes=$memory.ToArray()}finally{$memory.Dispose()}
 }finally{$stream.Dispose()}
 $sha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')}finally{$sha.Dispose()}
 $text=[Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xfeff)
 return [pscustomobject]@{SHA256=$hash;Value=($text|ConvertFrom-Json)}
}
function AssertOptiShadeLegacyWorkerReuse([string]$LegacyRoot,[string]$NvidiaDlssSdkPath='', [string]$VerificationRoot=''){
 $worker=ResolveOptiShadeLegacyBuildFile $LegacyRoot 'build/dlss5-feed-host64.exe';$identityPath=ResolveOptiShadeLegacyBuildFile $LegacyRoot 'build/worker-identity.json'
 $document=ReadOptiShadeLegacyBuildJson $identityPath;$record=$document.Value;$workerHash=(Get-FileHash -LiteralPath $worker -Algorithm SHA256).Hash
 if($record.Schema -ne 1 -or [string]$record.Kind -cne 'OptiShadeLegacyWorkerBuild' -or [string]$record.WorkerPath -cne 'legacy-nr/build/dlss5-feed-host64.exe' -or [string]$record.WorkerSHA256 -cne $workerHash -or (GetOptiShadeLegacyWorkerMachine $worker) -ne 0x8664){throw 'The existing legacy NR worker does not match its content build receipt.'}
 if(-not $record.Sources -or [string]$record.Sources.SHA256 -cne (GetOptiShadeLegacyEntriesDigest @($record.Sources.Files))){throw 'Legacy worker source provenance is missing or malformed.'}
 AssertOptiShadeLegacySdkIdentity $record.NvidiaDlssSdk
 $current=GetOptiShadeLegacyWorkerInputs $LegacyRoot $NvidiaDlssSdkPath $record.NvidiaDlssSdk
 if($current.SHA256 -cne [string]$record.InputsSHA256 -or $current.Sources.SHA256 -cne [string]$record.Sources.SHA256 -or $current.NvidiaDlssSdk.SHA256 -cne [string]$record.NvidiaDlssSdk.SHA256){throw 'Legacy worker source or SDK content changed since its verified build. Build a fresh x64 worker.'}
 if(-not $VerificationRoot){$VerificationRoot=Join-Path (Split-Path $LegacyRoot -Parent) 'dist'}
 $verified=$null
 foreach($file in @(Get-ChildItem -LiteralPath $VerificationRoot -Filter 'OptiShade_Version_*.exe.verification.json' -File -ErrorAction SilentlyContinue)){
  try{$package=(ReadOptiShadeLegacyBuildJson $file.FullName).Value}catch{continue}
  if($package.Passed -isnot [bool] -or -not $package.Passed -or -not $package.Build -or -not $package.Build.NativeBinaries){continue}
  $hostEntry=$package.Build.NativeBinaries.PSObject.Properties['legacy-nr/build/dlss5-feed-host64.exe'];$identityEntry=$package.Build.NativeBinaries.PSObject.Properties['legacy-nr/build/worker-identity.json']
  if($hostEntry -and $identityEntry -and [string]$hostEntry.Value -ceq $workerHash -and [string]$identityEntry.Value -ceq $document.SHA256){$verified=[pscustomobject]@{Path=$file.FullName;Version=[string]$package.Build.Version};break}
 }
 if(-not $verified){throw 'The worker EXE and worker-identity.json do not both match the same previously verified local OptiShade package.'}
 # Validate again after scanning package evidence. No old timestamp or partial
 # package match can hide a source, SDK, EXE or receipt change during reuse.
 $after=GetOptiShadeLegacyWorkerInputs $LegacyRoot $NvidiaDlssSdkPath $record.NvidiaDlssSdk
 if($current.SHA256 -cne $after.SHA256 -or (Get-FileHash -LiteralPath $worker -Algorithm SHA256).Hash -cne $workerHash -or (Get-FileHash -LiteralPath $identityPath -Algorithm SHA256).Hash -cne $document.SHA256){throw 'Legacy worker inputs or build evidence changed during reuse validation.'}
 return [pscustomobject]@{Version=$verified.Version;VerificationPath=$verified.Path;InputsSHA256=$current.SHA256;SdkEvidence=$(if($NvidiaDlssSdkPath){'current_sdk_verified'}else{'original_sdk_bound_to_verified_package'})}
}
