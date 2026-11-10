$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$path=Join-Path $root 'Beta/build-candidate.ps1';$parse=$null;$tokens=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parse)
if($parse.Count){throw $parse[0]}
$node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'InvokeLegacyWorkerBuild'},$true)
if(-not $node){throw 'InvokeLegacyWorkerBuild was not found.'}
Invoke-Expression $node.Extent.Text
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-worker-overlay-'+[guid]::NewGuid().ToString('N'))
$candidate=Join-Path $fixture 'candidate';$stable=Join-Path $fixture 'stable'
$relatives=@('shared/build-version.json','shared/OptiShadeVersion.h')
try{
 foreach($relative in $relatives){
  foreach($base in @($candidate,$stable)){[void][IO.Directory]::CreateDirectory((Split-Path (Join-Path $base $relative) -Parent))}
  [IO.File]::WriteAllText((Join-Path $stable $relative),'stable baseline')
  [IO.File]::WriteAllText((Join-Path $candidate $relative),'private beta overlay')
 }
 $build=Join-Path $candidate 'legacy-nr/build.ps1';[void][IO.Directory]::CreateDirectory((Split-Path $build -Parent))
 $observation=Join-Path $candidate 'legacy-nr/build-observation.txt'
 @'
param([string]$NvidiaDlssSdkPath,[switch]$ReuseVerifiedHost64)
if(-not $ReuseVerifiedHost64){throw 'Test expected verified-host reuse.'}
$base=Split-Path $PSScriptRoot -Parent
$values=@((Get-Content (Join-Path $base 'shared/build-version.json')),(Get-Content (Join-Path $base 'shared/OptiShadeVersion.h')))
[IO.File]::WriteAllLines((Join-Path $PSScriptRoot 'build-observation.txt'),$values)
if($env:OPTISHADE_TEST_FAIL_WORKER_BUILD){throw 'Injected worker-build failure.'}
'@|Set-Content -LiteralPath $build -Encoding UTF8
 InvokeLegacyWorkerBuild $candidate '' $true $stable
 $seen=[IO.File]::ReadAllLines($observation)
 if($seen.Count -ne 2 -or $seen[0] -ne 'stable baseline' -or $seen[1] -ne 'stable baseline'){throw 'Verified worker reuse did not see the original stable version metadata.'}
 foreach($relative in $relatives){if([IO.File]::ReadAllText((Join-Path $candidate $relative)) -ne 'private beta overlay'){throw "Successful build did not restore the private overlay: $relative"}}
 $env:OPTISHADE_TEST_FAIL_WORKER_BUILD='1';$failed=$false
 try{InvokeLegacyWorkerBuild $candidate '' $true $stable}catch{$failed=$_.Exception.Message -eq 'Injected worker-build failure.'}finally{$env:OPTISHADE_TEST_FAIL_WORKER_BUILD=$null}
 if(-not $failed){throw 'Injected worker build failure did not propagate.'}
 foreach($relative in $relatives){if([IO.File]::ReadAllText((Join-Path $candidate $relative)) -ne 'private beta overlay'){throw "Failed build did not restore the private overlay: $relative"}}
 Write-Output 'PASS: private beta native builds verify the stable NR worker against its original version metadata and restore overlays on success or failure.'
}finally{Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue}
