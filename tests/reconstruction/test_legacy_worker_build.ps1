$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Beta/legacy-nr/build-identity.ps1"
. "$PSScriptRoot/fixtures/windows_pe.ps1"
$script:checks=0
function Check($Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Reject([scriptblock]$Action,[string]$Reason){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Check $failed $Reason}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-worker-build-'+[guid]::NewGuid().ToString('N'))
$beta=Join-Path $fixture 'Beta';$legacy=Join-Path $beta 'legacy-nr';$sdk=Join-Path $fixture 'sdk';$dist=Join-Path $beta 'dist'
function Put([string]$Base,[string]$Relative,[string]$Content){$path=Join-Path $Base $Relative;[void][IO.Directory]::CreateDirectory((Split-Path $path -Parent));[IO.File]::WriteAllText($path,$Content,[Text.UTF8Encoding]::new($false));return $path}
function SaveJson([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))}
function VerifyPackage([string]$Name,[string]$WorkerHash,[string]$IdentityHash,$Passed=$true){
 $map=[ordered]@{'legacy-nr/build/dlss5-feed-host64.exe'=$WorkerHash;'legacy-nr/build/worker-identity.json'=$IdentityHash}
 $path=Join-Path $dist ('OptiShade_Version_'+$Name+'.exe.verification.json')
 SaveJson $path ([pscustomobject]@{Passed=$Passed;Build=[pscustomobject]@{Version='fixture';BuiltUtc='2000-01-01T00:00:00Z';NativeBinaries=[pscustomobject]$map}})
}
try{
 $required=@(
  'legacy-nr/build.ps1','legacy-nr/build-identity.ps1','legacy-nr/build-host64.bat','legacy-nr/upstream/tools/vcvars.bat','legacy-nr/upstream/host/dlss5-feed-host64.cpp','legacy-nr/upstream/src/feed_ipc.h',
  'shared/AutoCompatibility.h','shared/RuntimeControlProtocol.h','shared/MfgControlWin.h','shared/NeuralRuntimeReceipt.h','shared/NeuralModelPolicy.generated.h','shared/RenderingGpuProbeWin.h','shared/RenderingGpuPolicy.h',
  'shared/neural-model-policy.json','shared/provider-policy.json','reconstruction/generate_provider_policy.py','optiscaler/external/nlohmann/json.hpp',
  'reshade/res/shaders/optishade_guides.hlsl','reshade/res/shaders/optishade_guides.dxbc.h','reshade/res/shaders/optishade_guides.generated.h','reshade/res/shaders/optishade_guides.glsl.h'
 )
 foreach($relative in $required){$null=Put $beta $relative ('fixture input '+$relative)}
 $null=Put $beta 'legacy-nr/upstream/host/dlss5-feed-host64.cpp' "#include `"../src/feed_ipc.h`"`n#include <json.hpp>`n"
 $null=Put $beta 'legacy-nr/upstream/src/feed_ipc.h' "#include `"../../support/transitive.custom`"`n// fixture protocol"
 $transitive=Put $beta 'legacy-nr/support/transitive.custom' '// project dependency outside enumerated trees'
 foreach($relative in @('include/nvsdk_ngx.h','include/nvsdk_ngx_helpers.h','include/nvsdk_ngx_defs_dlssd.h','include/detail/transitive.hpp','lib/Windows_x86_64/x64/nvsdk_ngx_d.lib')){$null=Put $sdk $relative ('SDK fixture bytes only: '+$relative)}
 [void][IO.Directory]::CreateDirectory((Join-Path $legacy 'build'));[void][IO.Directory]::CreateDirectory($dist)
 $worker=Join-Path $legacy 'build/dlss5-feed-host64.exe';WriteOptiShadeFixtureExecutable $worker
 $identityPath=Join-Path $legacy 'build/worker-identity.json'
 $before=GetOptiShadeLegacyWorkerInputs $legacy $sdk;$after=GetOptiShadeLegacyWorkerInputs $legacy $sdk
 Check ($before.SHA256 -ceq $after.SHA256) 'Unchanged source/SDK input identity is not deterministic.'
 Check (@($before.Sources.Files|Where-Object Path -ceq 'legacy-nr/support/transitive.custom').Count -eq 1) 'Literal transitive project input was omitted from worker identity.'
 $permuted=[object[]]@($before.Sources.Files);[Array]::Reverse($permuted)
 Check ((GetOptiShadeLegacyEntriesDigest $permuted) -ceq $before.Sources.SHA256) 'Input identity depends on enumeration order.'
 $culture=[Globalization.CultureInfo]::CurrentCulture
 try{[Globalization.CultureInfo]::CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('tr-TR');Check ((GetOptiShadeLegacyWorkerInputs $legacy $sdk).SHA256 -ceq $before.SHA256) 'Input identity depends on the current culture.'}finally{[Globalization.CultureInfo]::CurrentCulture=$culture}
 $receipt=WriteOptiShadeLegacyWorkerIdentity $legacy $before $after
 Check ($receipt.InputsSHA256 -ceq $before.SHA256 -and $receipt.WorkerSHA256 -ceq (Get-FileHash -LiteralPath $worker -Algorithm SHA256).Hash) 'Fresh worker receipt did not bind source, SDK and actual EXE bytes.'
 $identityBytes=[IO.File]::ReadAllBytes($identityPath);$identityHash=(Get-FileHash -LiteralPath $identityPath -Algorithm SHA256).Hash;$workerHash=(Get-FileHash -LiteralPath $worker -Algorithm SHA256).Hash
 VerifyPackage 'paired' $workerHash $identityHash
 $verified=AssertOptiShadeLegacyWorkerReuse $legacy $sdk
 Check ($verified.SdkEvidence -ceq 'current_sdk_verified') 'Matching current source, SDK and paired package receipt did not admit reuse.'
 $verified=AssertOptiShadeLegacyWorkerReuse $legacy ''
 Check ($verified.SdkEvidence -ceq 'original_sdk_bound_to_verified_package') 'No-SDK reuse did not preserve its original verified SDK provenance.'
 # Timestamp alone is neither sufficient nor necessary for reuse.
 foreach($relative in $required){(Get-Item -LiteralPath (Join-Path $beta $relative)).LastWriteTimeUtc=[DateTime]::UtcNow.AddYears(2)}
 Check ((AssertOptiShadeLegacyWorkerReuse $legacy '').InputsSHA256 -ceq $before.SHA256) 'Unchanged bytes with newer timestamps were wrongly rejected.'
 foreach($relative in @('legacy-nr/upstream/host/dlss5-feed-host64.cpp','legacy-nr/upstream/src/feed_ipc.h','legacy-nr/support/transitive.custom','shared/AutoCompatibility.h','shared/RuntimeControlProtocol.h','shared/neural-model-policy.json','shared/NeuralModelPolicy.generated.h','shared/RenderingGpuProbeWin.h','optiscaler/external/nlohmann/json.hpp','reshade/res/shaders/optishade_guides.hlsl','reshade/res/shaders/optishade_guides.dxbc.h','reshade/res/shaders/optishade_guides.glsl.h','reconstruction/generate_provider_policy.py','legacy-nr/build-host64.bat','legacy-nr/upstream/tools/vcvars.bat','legacy-nr/build.ps1','legacy-nr/build-identity.ps1')){
  $path=Join-Path $beta $relative;$saved=[IO.File]::ReadAllBytes($path)
  try{[IO.File]::AppendAllText($path,"`n// changed bytes with backdated timestamp");(Get-Item -LiteralPath $path).LastWriteTimeUtc=[DateTime]'1999-01-01';Reject {AssertOptiShadeLegacyWorkerReuse $legacy ''} ('Backdated changed input was reused: '+$relative)}finally{[IO.File]::WriteAllBytes($path,$saved)}
 }
 $extra=Put $beta 'shared/new_dependency.h' '// newly present shared contract';Reject {AssertOptiShadeLegacyWorkerReuse $legacy ''} 'A newly present shared dependency was ignored.';Remove-Item -LiteralPath $extra
 $saved=[IO.File]::ReadAllBytes($transitive);Remove-Item -LiteralPath $transitive
 try{Reject {GetOptiShadeLegacyWorkerSourceIdentity $legacy} 'A missing transitive project include silently disappeared from identity.'}finally{[IO.File]::WriteAllBytes($transitive,$saved)}
 foreach($relative in @('include/detail/transitive.hpp','lib/Windows_x86_64/x64/nvsdk_ngx_d.lib')){
  $path=Join-Path $sdk $relative;$saved=[IO.File]::ReadAllBytes($path)
  try{[IO.File]::AppendAllText($path,'modified SDK bytes');(Get-Item -LiteralPath $path).LastWriteTimeUtc=[DateTime]'1999-01-01';Reject {AssertOptiShadeLegacyWorkerReuse $legacy $sdk} ('Explicitly supplied changed SDK was accepted: '+$relative)}finally{[IO.File]::WriteAllBytes($path,$saved)}
 }
 Reject {GetOptiShadeLegacySdkIdentity (Join-Path $fixture 'missing-sdk')} 'Fresh worker identity accepted an absent official SDK.'
 $lib=Join-Path $sdk 'lib/Windows_x86_64/x64/nvsdk_ngx_d.lib';$saved=[IO.File]::ReadAllBytes($lib);Remove-Item -LiteralPath $lib
 try{Reject {GetOptiShadeLegacySdkIdentity $sdk} 'Fresh worker identity omitted its required SDK link library.';Check ((AssertOptiShadeLegacyWorkerReuse $legacy '').SdkEvidence -ceq 'original_sdk_bound_to_verified_package') 'No-SDK reuse incorrectly required a new SDK copy.'}finally{[IO.File]::WriteAllBytes($lib,$saved)}
 $path=Join-Path $beta 'shared/AutoCompatibility.h';$saved=[IO.File]::ReadAllBytes($path);[IO.File]::AppendAllText($path,'mid-build change');$changed=GetOptiShadeLegacyWorkerInputs $legacy $sdk
 try{Reject {WriteOptiShadeLegacyWorkerIdentity $legacy $before $changed} 'Changed input during compilation produced fresh worker evidence.';Check ((Get-FileHash -LiteralPath $identityPath -Algorithm SHA256).Hash -ceq $identityHash) 'Rejected build overwrote previous worker evidence.'}finally{[IO.File]::WriteAllBytes($path,$saved)}
 $saved=[IO.File]::ReadAllBytes($worker);WriteOptiShadeFixtureExecutable $worker x86
 try{Reject {WriteOptiShadeLegacyWorkerIdentity $legacy $before $after} 'An x86 worker was stamped as x64.'}finally{[IO.File]::WriteAllBytes($worker,$saved)}
 $bytes=[IO.File]::ReadAllBytes($worker);$bytes[1000]=1;[IO.File]::WriteAllBytes($worker,$bytes)
 try{Reject {AssertOptiShadeLegacyWorkerReuse $legacy ''} 'A changed worker EXE reused old evidence.'}finally{[IO.File]::WriteAllBytes($worker,$saved)}
 [IO.File]::AppendAllText($identityPath,"`n")
 try{Reject {AssertOptiShadeLegacyWorkerReuse $legacy ''} 'A changed worker identity file was accepted by an old package hash.'}finally{[IO.File]::WriteAllBytes($identityPath,$identityBytes)}
 Remove-Item -LiteralPath (Join-Path $dist 'OptiShade_Version_paired.exe.verification.json')
 VerifyPackage 'host-only' $workerHash ('0'*64);VerifyPackage 'identity-only' ('0'*64) $identityHash
 Reject {AssertOptiShadeLegacyWorkerReuse $legacy ''} 'EXE and identity hashes from different packages were combined.'
 Remove-Item -LiteralPath (Join-Path $dist 'OptiShade_Version_host-only.exe.verification.json');Remove-Item -LiteralPath (Join-Path $dist 'OptiShade_Version_identity-only.exe.verification.json')
 VerifyPackage 'string-passed' $workerHash $identityHash 'true';Reject {AssertOptiShadeLegacyWorkerReuse $legacy ''} 'A string Passed value was treated as verified package evidence.';Remove-Item -LiteralPath (Join-Path $dist 'OptiShade_Version_string-passed.exe.verification.json')
 VerifyPackage 'failed' $workerHash $identityHash $false;Reject {AssertOptiShadeLegacyWorkerReuse $legacy ''} 'A failed package receipt qualified the worker.';Remove-Item -LiteralPath (Join-Path $dist 'OptiShade_Version_failed.exe.verification.json')
 $bad=(ReadOptiShadeLegacyBuildJson $identityPath).Value;$bad.NvidiaDlssSdk.Files=@($bad.NvidiaDlssSdk.Files|Where-Object Path -cne 'include/nvsdk_ngx_helpers.h');$bad.NvidiaDlssSdk.SHA256=GetOptiShadeLegacyEntriesDigest @($bad.NvidiaDlssSdk.Files);$bad.InputsSHA256=GetOptiShadeLegacyIdentityDigest ("OptiShadeLegacyWorkerInputs/1`n"+$bad.Sources.SHA256+"`n"+$bad.NvidiaDlssSdk.SHA256);SaveJson $identityPath $bad
 VerifyPackage 'incomplete-sdk' $workerHash (Get-FileHash -LiteralPath $identityPath -Algorithm SHA256).Hash
 Reject {AssertOptiShadeLegacyWorkerReuse $legacy ''} 'Incomplete original SDK provenance qualified no-SDK reuse even when its file hash was paired.'
 [IO.File]::WriteAllBytes($identityPath,$identityBytes)
 $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Beta/legacy-nr/build.ps1'),[ref]$tokens,[ref]$errors);Check (-not $errors.Count) 'Production legacy build.ps1 does not parse.'
 # Also enumerate the actual repository worker closure, without SDK or native
 # execution. Missing direct source dependencies must be reported honestly.
 $actual=GetOptiShadeLegacyWorkerSourceIdentity (Join-Path $root 'Beta/legacy-nr')
 Check (@($actual.Files|Where-Object Path -ceq 'legacy-nr/upstream/src/feed_preparation.h').Count -eq 1 -and @($actual.Files|Where-Object Path -ceq 'shared/NeuralRuntimeReceipt.h').Count -eq 1 -and @($actual.Files|Where-Object Path -ceq 'optiscaler/external/nlohmann/json.hpp').Count -eq 1) 'Production worker input closure omitted current preparation/receipt/JSON dependencies.'
 "Legacy worker build identity: $script:checks assertions passed against production content, receipt and reuse helpers. Actual source closure: $($actual.Files.Count) files. SDK/PE fixture bytes are data only; no MSVC build or proprietary SDK execution is claimed."
}finally{if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue}}
