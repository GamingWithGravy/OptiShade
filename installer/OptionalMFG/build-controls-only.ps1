param(
    [Parameter(Mandatory=$true)][string]$SourceArchive,
    [Parameter(Mandatory=$true)][string]$NativeCacheRoot,
    [Parameter(Mandatory=$true)][string]$StreamlineRoot,
    [Parameter(Mandatory=$true)][string]$ImGuiRoot,
    [Parameter(Mandatory=$true)][string]$VulkanIncludeDirectory,
    [Parameter(Mandatory=$true)][string]$CMakeExecutable,
    [Parameter(Mandatory=$true)][string]$VisualStudioInstance,
    [Parameter(Mandatory=$true)][string]$CandidateDirectory
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
# The immutable upstream archive contains the original licence and source.
# No source, GPU gate, SDK or native-kernel validation is substituted here.
$sourceCommit='53e3311157140df7b72a6cf0c76fb4e93c44fc04'
$sourceHash='8F7C530CEE0D733C8A7E26FD2F808DBFA5ED68DA7C47952D7F9F5BBCADB047B6'
if((Get-FileHash -LiteralPath $SourceArchive -Algorithm SHA256).Hash -cne $sourceHash) {
    throw 'The RTXMFG source archive does not match the pinned upstream commit.'
}
# Check the unavailable inputs before creating any candidate output. The
# upstream script checks the remaining toolchain/SDK/kernel image hashes too.
$required=@{
    'native-cache/ampere_native_manifest.inc'='4C8765C79A4947A7F3A79EC98DB2DB7E3E95584621E853909BF5EDB2DA7D2C24'
    'native-cache-3109/ampere_native_manifest.inc'='90E3E797B5121B6FFBF52C1765FAC9683A9C1641363EE0CC669296754B4B2291'
    'native-cache/manifest.json'='B90F4131CD7E9E93C164FE2680C29475EFA2434DD6CF343C8713FCE4E2557E09'
    'native-cache-3109/manifest.json'='D6D42F8BC002B29833EDE69E27DBC00E6E2913716BC6131DBAE19D02215E58D9'
    'all-provider-layouts/native-cache-complete/ampere_native_manifest_additional.inc'='1E0770EA6C85B4267E1068D16A723845D4AB949FA0BC142D2DFF2C24E88C9F64'
    'all-provider-layouts/native-cache-complete/additional-resources.json'='0007B3CCBC3D3B3ACE90DF4B438050013EE31DE8B6069AF1A39DCA5B7DAE7EDD'
}
foreach($relative in $required.Keys) {
    $path=Join-Path $NativeCacheRoot $relative
    if(!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Controls-only MFG build blocked: missing original upstream input $relative" }
    if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $required[$relative]) {
        throw "Controls-only MFG build blocked: original upstream input differs: $relative"
    }
}
if(Test-Path -LiteralPath $CandidateDirectory) { throw 'Use a fresh candidate directory; existing output is never replaced.' }
$candidate=[IO.Path]::GetFullPath($CandidateDirectory)
New-Item -ItemType Directory -Path $candidate | Out-Null
Expand-Archive -LiteralPath $SourceArchive -DestinationPath $candidate
$source=Join-Path $candidate ('RTX40MFG-Unlock-'+$sourceCommit)
$patch=Join-Path $PSScriptRoot 'controls-only.patch'
& git -C $source -c core.autocrlf=false apply --check -- $patch
if($LASTEXITCODE -ne 0) { throw 'The controls-only patch does not apply to the pinned upstream source.' }
& git -C $source -c core.autocrlf=false apply -- $patch
if($LASTEXITCODE -ne 0) { throw 'Applying the controls-only patch failed.' }
$build=Join-Path $candidate 'build'
$arguments=@{
    NativeCacheRoot=$NativeCacheRoot; StreamlineRoot=$StreamlineRoot; ImGuiRoot=$ImGuiRoot
    VulkanIncludeDirectory=$VulkanIncludeDirectory; CMakeExecutable=$CMakeExecutable
    VisualStudioInstance=$VisualStudioInstance; MsvcToolsVersion='14.38.33130'; WindowsSdkVersion='10.0.22621.0'
    BuildDirectory=$build; EnableGpuFaultCapture=$false; SkipOverlayGpuWork=$false
    EnableNgxCreateResultDiagnostics=$false; DisableSingleOverlay=$false
    EnableBoundedOverlayRedesign=$true; EnableOverlayMenuDraw=$false; EnableOverlayTestFaults=$false
}
& (Join-Path $source 'source/native/build.ps1') @arguments
$dll=Join-Path $build 'Release/RTXMFG.dll'
if(!(Test-Path -LiteralPath $dll -PathType Leaf)) { throw 'Upstream build did not produce the candidate DLL.' }
# Compilation alone cannot certify input isolation or generated-frame output.
# This deliberately is NOT the reviewed controls-only-approved.json receipt.
[ordered]@{
    Schema=1; UpstreamCommit=$sourceCommit; SourceArchiveSha256=$sourceHash
    PatchSha256=(Get-FileHash -LiteralPath $patch -Algorithm SHA256).Hash
    DllSha256=(Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
    MenuDraw=$false; RuntimeGpuSelection=$true; EmbeddedKernelValidation=$true
    InputIsolationVerified=$false; BackendRegressionVerified=$false
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $candidate 'controls-only-candidate.json') -Encoding UTF8
Write-Output "Candidate built at $dll. DLL input-isolation and backend regression verification are still required before packaging."
