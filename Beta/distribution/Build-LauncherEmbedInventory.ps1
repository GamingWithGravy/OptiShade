param(
 [string]$InstallerRoot = (Join-Path $PSScriptRoot '..\installer'),
 [string]$InventoryPath = (Join-Path $PSScriptRoot 'LAUNCHER-EMBED-INVENTORY.csv'),
 [string]$ReportPath = (Join-Path $PSScriptRoot 'LAUNCHER-EMBED-AUDIT.md')
)
$ErrorActionPreference = 'Stop'
$InstallerRoot = (Resolve-Path -LiteralPath $InstallerRoot).Path
$directive = Get-Content -LiteralPath (Join-Path $InstallerRoot 'public_bundle.go') | Where-Object { $_ -match '^//go:embed\s' } | Select-Object -First 1
if (-not $directive) { throw 'Could not find the public_bundle.go embed directive.' }
$patterns = ($directive -replace '^//go:embed\s+', '').Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
$paths = [System.Collections.Generic.Dictionary[string,bool]]::new([StringComparer]::OrdinalIgnoreCase)
$payloadCategoryByPath = @{}
$payloadInventory = Join-Path $PSScriptRoot 'PAYLOAD-TEARDOWN-INVENTORY.csv'
if (Test-Path -LiteralPath $payloadInventory -PathType Leaf) {
 foreach ($row in (Import-Csv -LiteralPath $payloadInventory)) { $payloadCategoryByPath[[string]$row.RelativePath] = [string]$row.Category }
}
foreach ($rawPattern in $patterns) {
 $includeHidden = $rawPattern.StartsWith('all:')
 $pattern = if ($includeHidden) { $rawPattern.Substring(4) } else { $rawPattern }
 $target = Join-Path $InstallerRoot $pattern
 $items = @()
 if ($pattern.Contains('*')) {
  $items = @(Get-ChildItem -Path $target -Force -ErrorAction Stop)
 } elseif (Test-Path -LiteralPath $target -PathType Leaf) {
  $items = @(Get-Item -LiteralPath $target -Force)
 } elseif (Test-Path -LiteralPath $target -PathType Container) {
  $items = @(Get-Item -LiteralPath $target -Force)
 } else { throw "Embed pattern does not resolve: $rawPattern" }
 foreach ($item in $items) {
  if ($item.PSIsContainer) {
   $nested = Get-ChildItem -LiteralPath $item.FullName -File -Recurse -Force
   foreach ($file in $nested) {
    $relative = $file.FullName.Substring($InstallerRoot.Length + 1).Replace('\','/')
    $segments = $relative.Split('/')
    if ($includeHidden -or -not ($segments | Where-Object { $_ -match '^[._]' })) { $paths[$relative] = $includeHidden }
   }
  } else {
   $relative = $item.FullName.Substring($InstallerRoot.Length + 1).Replace('\','/')
   $paths[$relative] = $includeHidden
  }
 }
}

function Get-BinaryArchitecture([string]$path) {
 if ([IO.Path]::GetExtension($path).ToLowerInvariant() -notin @('.exe','.dll')) { return 'not a PE binary' }
 $stream = [IO.File]::OpenRead($path)
 try {
  if ($stream.Length -lt 64) { return 'invalid/short PE file' }
  $reader = [IO.BinaryReader]::new($stream)
  if ($reader.ReadUInt16() -ne 0x5A4D) { return 'not PE (MZ signature missing)' }
  $stream.Position = 0x3C
  $peOffset = $reader.ReadInt32()
  if ($peOffset -lt 64 -or $peOffset -gt ($stream.Length - 6)) { return 'invalid PE header offset' }
  $stream.Position = $peOffset
  if ($reader.ReadUInt32() -ne 0x00004550) { return 'invalid PE signature' }
  $machine = $reader.ReadUInt16()
  switch ($machine) {
   0x014c { return 'x86 (I386)' }
   0x8664 { return 'x64 (AMD64)' }
   0xAA64 { return 'ARM64' }
   0x01c0 { return 'ARM (legacy)' }
   0x01c4 { return 'ARMv7' }
   default { return ('unknown PE machine 0x{0:X4}' -f $machine) }
  }
 } finally { $stream.Dispose() }
}

function Get-Audit([string]$relative) {
 $p = $relative.ToLowerInvariant()
 if ($p.StartsWith('payloadfusion/')) {
  $sub = $relative.Substring('PayloadFusion/'.Length).Replace('\','/')
  if (-not $payloadCategoryByPath.ContainsKey($sub)) { throw "Payload path is missing from the reviewed payload inventory: $sub" }
  $category = 'Payload: ' + $payloadCategoryByPath[$sub]
  return @($category,'Game/runtime payload selected by game route, graphics API, GPU architecture and enabled component.','The payload must remain version-coherent with files.json, BuildIdentity, installer policy, receipts, rollback and third-party licences.','Retain until a signed independent replacement is composed and every dependent install/recovery route consumes it.')
 }
 if ($p -match '\.ps1$|\.psm1$|\.cs$|\.json$|\.ini$|\.xaml$|\.txt$|\.md$') {
  $role = if ($p -match 'anti-cheat|consent') {'Install warning/consent and game protection detection'} elseif ($p -match 'diagnostic|troubleshoot|crash|dump') {'Diagnostics, hang/crash capture and troubleshooting'} elseif ($p -match 'mfg|runtime-control|gpu-identity') {'Live control, GPU identification or OptiMFG integration'} elseif ($p -match 'neural|provider|streamline') {'Neural/provider compatibility and download policy'} elseif ($p -match 'glass|atmosphere') {'Third-party component install/update/provenance integration'} elseif ($p -match 'manager|library|setup|update|ownership|recovery|compatibility|effect|package|component|store-path|operation') {'Launcher UI, install/update/repair/restore/uninstall workflow'} elseif ($p -match 'release-notes|help') {'User help and release information'} else {'Launcher configuration, policy or UI resource'}
  return @('Launcher: Source/metadata',$role,'Behavior and compatibility are determined by the scripts and UI loaded by the bundled FusionSetup host; removing a file may fail only on a particular game, store, graphics API, recovery or diagnostics route.','Keep unless call-site tracing proves it is dead and a clean install/update/repair/uninstall plus affected feature checks pass.')
 }
 if ($p -match '\.exe$|\.dll$') {
  $role = if ($p -match 'troubleshooter') {'Troubleshooter executable invoked by manager support flows'} elseif ($p -match 'driver') {'NVIDIA driver profile helper invoked by driver settings'} elseif ($p -match 'fusionsetup') {'Windows GUI host that executes the manager scripts and UI'} else {'Helper/runtime executable; specific callers must be traced'}
  return @('Launcher: Helper executable',$role,'Architecture, Windows runtime dependencies, invocation arguments, elevation, code-signing/AV behavior and process lifetime may differ by user/game path.','Keep until every invocation is replaced and the manager, updater and recovery flows pass on clean Windows accounts.')
 }
 if ($p -match '\.ico$|\.png$|\.svg$') { return @('Launcher: Branding asset','Used by window/taskbar/shortcut branding; not a game runtime dependency.','Potentially replace with a smaller reviewed asset if all app windows, shortcuts and installer branding remain correct.') }
 return @('Launcher: Other embedded resource','Consumer must be identified from its call site before removal.','Retain until a source reference and runtime compatibility review proves the resource unnecessary.')
}

$rows = foreach ($relative in ($paths.Keys | Sort-Object)) {
 $full = Join-Path $InstallerRoot $relative.Replace('/','\')
 $item = Get-Item -LiteralPath $full -Force
 if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Embedded path is not a regular file: $relative" }
 $review = Get-Audit $relative
 [pscustomobject]@{
  RelativePath=$relative; Bytes=[long]$item.Length; MiB=[math]::Round($item.Length / 1MB,4)
  SHA256=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
  BinaryArchitecture=(Get-BinaryArchitecture $full)
  Category=$review[0]; RuntimeRole=$review[1]; CompatibilityRisk=$review[2]; RemovalGate=$review[3]
 }
}
if (-not $rows.Count) { throw 'Embed inventory is empty.' }
$rows | Export-Csv -LiteralPath $InventoryPath -NoTypeInformation -Encoding UTF8
$sum = [long](($rows | Measure-Object Bytes -Sum).Sum)
$payload = [long](($rows | Where-Object Category -like 'Payload:*' | Measure-Object Bytes -Sum).Sum)
$other = $sum - $payload
$largest = $rows | Sort-Object Bytes -Descending | Select-Object -First 12
$byCategory = $rows | Group-Object Category | Sort-Object { [long](($_.Group | Measure-Object Bytes -Sum).Sum) } -Descending
$binaryArchitectures = $rows | Where-Object BinaryArchitecture -like '*(*' | Group-Object BinaryArchitecture | Sort-Object Name
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('# Launcher embedded-file audit')
$lines.Add('')
$lines.Add('Generated from the actual `//go:embed` patterns in `Beta/installer/public_bundle.go`. Each resolved file is recorded with its byte size and SHA-256. This inventory is descriptive; it removes nothing and does not treat a small file as safe to delete.')
$lines.Add('')
$lines.Add(('Embedded files: **{0}**; total source bytes: **{1:N0} ({2:N1} MiB)**.' -f $rows.Count,$sum,($sum/1MB)))
$lines.Add(('`PayloadFusion`: **{0:N0} bytes ({1:N1} MiB, {2:P1})**. All other embedded launcher resources: **{3:N0} bytes ({4:N1} MiB)**.' -f $payload,($payload/1MB),($payload/[double]$sum),$other,($other/1MB)))
$lines.Add('')
$lines.Add('The local R381 executable observed during this audit is 296,325,120 bytes (282.6 MiB). This is a different measurement from the raw file sum above: the final executable includes linker/build overhead and may share identical embedded byte content across duplicate install paths. Measure a new build directly before quoting its final size or promised reduction.')
$lines.Add('')
$lines.Add('PE compatibility scan: the inventory records the PE machine architecture for every embedded EXE and DLL (x86, x64, ARM64, or an explicit invalid/unknown result). This is a static format check, not proof that a binary loads on a given Windows build, GPU, game or graphics API. Before removal or replacement, compare architecture and dependencies with every invocation and loader path, then exercise the affected install, launch, update, repair, rollback and uninstall routes.')
$lines.Add('')
$lines.Add('## PE architecture counts')
$lines.Add('')
$lines.Add('| PE machine | Files |')
$lines.Add('|---|---:|')
foreach ($group in $binaryArchitectures) { $lines.Add(('| {0} | {1} |' -f $group.Name,$group.Count)) }
$lines.Add('')
$lines.Add('## Size by category')
$lines.Add('')
$lines.Add('| Category | Files | MiB |')
$lines.Add('|---|---:|---:|')
foreach ($group in $byCategory) { $bytes=[long](($group.Group | Measure-Object Bytes -Sum).Sum); $lines.Add(('| {0} | {1} | {2:N2} |' -f $group.Name,$group.Count,($bytes/1MB))) }
$lines.Add('')
$lines.Add('## Largest embedded files')
$lines.Add('')
$lines.Add('| File | MiB | Current disposition |')
$lines.Add('|---|---:|---|')
foreach ($row in $largest) { $lines.Add(('| `{0}` | {1:N2} | {2} |' -f $row.RelativePath,$row.MiB,$row.Category)) }
$lines.Add('')
$lines.Add('## Removal and compatibility rule')
$lines.Add('')
$lines.Add('The only high-impact size reduction is to stop embedding `PayloadFusion` after online component selection, integrity checks, compatibility gating and transactional install/recovery all use the verified staged package. Do not remove just a DLL or payload group based on one GPU/game result. Preserve legacy API and architecture variants, helper binaries, installer/manager scripts, signatures, ownership records, required notices and backups until their consumers are replaced and verified. The per-file role, compatibility risk and removal gate are recorded in `LAUNCHER-EMBED-INVENTORY.csv`; detailed game-payload analysis remains in `PAYLOAD-TEARDOWN-AUDIT.md`.')
$lines.Add('')
$lines.Add('No file was removed by this audit.')
$lines | Set-Content -LiteralPath $ReportPath -Encoding UTF8
Write-Output "Inventoried $($rows.Count) files from public_bundle.go: $($sum.ToString('N0')) bytes; $($payload.ToString('N0')) bytes are PayloadFusion. No file was removed."
