param([string]$ComponentDirectory=$PSScriptRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$dll=Join-Path $ComponentDirectory 'RTXMFG.dll'
$receipt=Join-Path $ComponentDirectory 'controls-only-approved.json'
if(!(Test-Path -LiteralPath $receipt -PathType Leaf)) {
    throw 'Optional MFG packaging is held: the controls-only DLL and its verified input-isolation/backend receipt are not available. The existing Backspace-menu DLL must not be packaged as controls-only.'
}
$approved=Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
$hash=(Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
if($hash -eq 'E9CA3587854EEB723E0579F7DDF6CFB1E6CF4BED79B0D75BC716003ED98FE040') {
    throw 'The unchanged upstream DLL still has its Backspace menu and is not a controls-only build.'
}
$patchHash=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'controls-only.patch') -Algorithm SHA256).Hash
if($approved.Schema -ne 1 -or $approved.UpstreamCommit -cne '53e3311157140df7b72a6cf0c76fb4e93c44fc04' -or
   $approved.SourceArchiveSha256 -cne '8F7C530CEE0D733C8A7E26FD2F808DBFA5ED68DA7C47952D7F9F5BBCADB047B6' -or
   $approved.PatchSha256 -cne $patchHash -or $approved.DllSha256 -cne $hash -or
   $approved.MenuDraw -isnot [bool] -or $approved.MenuDraw -or
   $approved.RuntimeGpuSelection -isnot [bool] -or !$approved.RuntimeGpuSelection -or
   $approved.EmbeddedKernelValidation -isnot [bool] -or !$approved.EmbeddedKernelValidation -or
   $approved.InputIsolationVerified -isnot [bool] -or !$approved.InputIsolationVerified -or
   $approved.BackendRegressionVerified -isnot [bool] -or !$approved.BackendRegressionVerified) {
    throw 'The controls-only MFG verification receipt is incomplete or does not match the reviewed candidate.'
}
Write-Output 'Controls-only MFG candidate matches the reviewed verification receipt.'
