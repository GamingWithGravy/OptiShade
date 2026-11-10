param(
 [string]$PackageSetRoot = '.\build\publication-staging\components-1.0.77',
 [string]$OutputRoot = '.\build\local-modular-candidate-1.0.77',
 # Folders to build; publish only the components that changed.
 [string[]]$Only = @('core','effects','optimfg','providers-amd','providers-intel')
)
$ErrorActionPreference = 'Stop'
$MaximumArchiveBytes = 99MB
$components = @(
 [pscustomobject]@{Folder='core';Id='OptiShade.Core'},
 [pscustomobject]@{Folder='effects';Id='OptiShade.Effects'},
 [pscustomobject]@{Folder='optimfg';Id='OptiShade.OptiMFG'},
 [pscustomobject]@{Folder='providers-amd';Id='OptiShade.Providers.AMD'},
 [pscustomobject]@{Folder='providers-intel';Id='OptiShade.Providers.Intel'}
)|Where-Object {$_.Folder -in $Only}
if(-not @($components).Count){throw 'No known component selected.'}

if (-not [IO.Path]::IsPathRooted($PackageSetRoot) -or -not [IO.Path]::IsPathRooted($OutputRoot)) { throw 'Package and output directories must be absolute paths.' }
$PackageSetRoot = (Resolve-Path -LiteralPath $PackageSetRoot).Path
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) { throw "Refusing to overwrite existing candidate output: $OutputRoot" }
$outputParent = Split-Path -Parent $OutputRoot
$parentInfo = Get-Item -LiteralPath $outputParent -Force -ErrorAction Stop
if (-not $parentInfo.PSIsContainer -or ($parentInfo.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Candidate output parent must be an existing normal directory.' }
$tarCommand = Get-Command tar.exe -ErrorAction Stop
$tempRoot = Join-Path $outputParent ('.OptiShade-component-build-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tempRoot)
$promoted = $false
try {

$receipt = [System.Collections.Generic.List[object]]::new()
foreach ($component in $components) {
 $componentRoot = Join-Path $PackageSetRoot $component.Folder
 $packageRoot = Join-Path $componentRoot 'package'
 $metadataPath = Join-Path $packageRoot 'component-package.json'
 if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { throw "Missing package metadata for $($component.Id)" }
 $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
 if ($metadata.schema -ne 1 -or $metadata.componentId -cne $component.Id -or $metadata.version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$') { throw "Unexpected package identity or schema for $($component.Id)" }
 $listed = [System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
 foreach ($entry in $metadata.files) {
  $relative = [string]$entry.path
  if ([string]::IsNullOrWhiteSpace($relative) -or $relative.Contains('\') -or $relative.StartsWith('/') -or $relative.Contains(':') -or @($relative.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) { throw "Unsafe package path in $($component.Id): $relative" }
  if ($relative -ieq 'component-package.json' -or $listed.ContainsKey($relative)) { throw "Reserved or duplicate package path in $($component.Id): $relative" }
  if ([long]$entry.bytes -lt 0 -or [string]$entry.sha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw "Invalid size or digest for $($component.Id): $relative" }
  $source = Join-Path $packageRoot $relative.Replace('/','\')
  $item = Get-Item -LiteralPath $source -Force -ErrorAction Stop
  if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$item.Length -ne [long]$entry.bytes) { throw "Package file type or size differs from inventory: $($component.Id)/$relative" }
  $digest = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
  if ($digest -ine [string]$entry.sha256) { throw "Package file hash differs from inventory: $($component.Id)/$relative" }
  $listed[$relative] = $entry
 }
 $actualFiles = Get-ChildItem -LiteralPath $packageRoot -File -Recurse -Force
 foreach ($item in $actualFiles) {
  if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Package contains a reparse point: $($item.FullName)" }
  $relative = $item.FullName.Substring($packageRoot.Length + 1).Replace('\','/')
  if ($relative -ine 'component-package.json' -and -not $listed.ContainsKey($relative)) { throw "Package has an unlisted file: $($component.Id)/$relative" }
 }
 $actualDirs = Get-ChildItem -LiteralPath $packageRoot -Directory -Recurse -Force
 if (@($actualDirs | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw "Package contains a directory reparse point: $($component.Id)" }

 $archiveName = $component.Id + '-' + [string]$metadata.version + '.tar.gz'
 $archivePath = Join-Path $tempRoot $archiveName
 $output = & $tarCommand.Source -czf $archivePath -C $packageRoot . 2>&1
 if ($LASTEXITCODE -ne 0) { throw "tar failed for $($component.Id): $($output -join ' ')" }
 $archive = Get-Item -LiteralPath $archivePath -Force
 if ($archive.Length -lt 1 -or $archive.Length -gt $MaximumArchiveBytes) { throw "Archive exceeds the regular GitHub-file limit: $archiveName ($($archive.Length) bytes)" }
 $receipt.Add([pscustomobject]@{
  componentId=$component.Id; version=[string]$metadata.version; archive=$archiveName
  bytes=[long]$archive.Length; sha256=(Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
  inventoryFiles=$listed.Count; inventoryVerified=$true
 })
}
$receipt | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $tempRoot 'local-build-receipt.json') -Encoding UTF8
$receipt | Format-Table componentId,version,archive,bytes,inventoryFiles,inventoryVerified -AutoSize
Move-Item -LiteralPath $tempRoot -Destination $OutputRoot
$promoted = $true
Write-Output "Local component candidate archives created and inventory-checked under $OutputRoot. Nothing was installed, committed, or uploaded."
} finally {
 if (-not $promoted -and (Test-Path -LiteralPath $tempRoot)) {
  $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
  $resolvedParent = [IO.Path]::GetFullPath($outputParent).TrimEnd('\') + '\'
  if ($resolvedTemp.StartsWith($resolvedParent,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolvedTemp) -match '^\.OptiShade-component-build-[0-9a-f]{32}$' -and -not ((Get-Item -LiteralPath $resolvedTemp -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
   Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
  }
 }
}
