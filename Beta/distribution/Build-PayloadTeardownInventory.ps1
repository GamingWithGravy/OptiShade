param(
 [string]$InventoryPath = (Join-Path $PSScriptRoot 'PAYLOAD-TEARDOWN-INVENTORY.csv'),
 [string]$PayloadRoot = (Join-Path $PSScriptRoot '..\installer\PayloadFusion')
)
$ErrorActionPreference = 'Stop'

function Get-Review([string]$category,[string]$path) {
 $p=$path.Replace('\','/')
 switch ($category) {
  'Cockpit' { return @('Third-party Glass Cockpit runtime add-on','Must use the official verified source, retain attribution/licence, and keep its install/update/repair/uninstall routes consistent.','Move only after all lifecycle routes use the official verified package; never leave a stale embedded copy that masks a failed download.') }
  'OptiMfg' { return @('OptiMFG controller, runtime helper, backend, VC runtime or licence notice','The controller/helper/backend and runtime dependencies are version-coupled; old/new location duplication or mismatched helper/backend versions can prevent live connection or cause loader conflicts.','Remove only after signed independent package install, migration/adoption, rollback, repair and uninstall are proven.') }
  'Neural' { return @('Neural Rendering loader, host, model or model-support asset','Game/API/architecture/GPU and model/runtime contracts matter. Host64 files and model assets cannot be dropped globally based on one machine; mismatches can disable NR or crash a route.','Remove only after variant-specific signed delivery and compatibility selection cover every supported NR route and retain offline recovery.') }
  'Providers' { return @('Optional AMD FidelityFX or Intel XeSS provider runtime','Provider support is route- and API-dependent. Removing these breaks FSR/XeSS choices, including on non-NVIDIA GPUs; including unused providers increases downloads and can cause loader/version conflicts.','Split into optional signed provider packages selected by game/API/GPU; verify ownership, compatibility and rollback before unembedding.') }
  'Effects' { return @('ReShade effect, shader header, texture or bundled look preset','Effects can depend on shared headers/textures and preset names. Partial delivery can cause compile/index failures or effects stuck at installed-but-not-loaded.','Remove only after the complete effects dependency set has independent delivery and verified install, indexing, repair and rollback.') }
  default {
   if ($p -eq 'files.json') { return @('Payload installation/ownership catalogue','The catalogue drives file selection and ownership receipts; a stale or partial version can make installs omit files or make repair/uninstall unsafe.','Keep a complete version-matched catalogue available to every transaction before removing its embedded copy.') }
   if ($p -match '(^|/)BuildIdentity\.json$') { return @('Build and compatibility identity metadata','Manager/core identity and private/stable channel decisions depend on this metadata; losing it can misclassify upgrades or accept incompatible payloads.','Provide authenticated, version-matched identity metadata to bootstrap, setup, updates and recovery.') }
   if ($p -match '(^|/)Licen[cs]es?/') { return @('Third-party or project licence/attribution notice','Not executable, but may be required for redistribution or source compliance. Do not count licence files as runtime waste.','Retain required notices in the correct installed component or a consolidated notices package after licence review.') }
   if ($p -match '(^|/)Tools/') { return @('Installer, compatibility, diagnostics or recovery tool/resource','These tools are called by setup, manager, diagnostics or rollback workflows; a missing script/resource may fail only on particular game/store/architecture paths.','Trace callers and exercise the dependent workflow before moving/removing; retain a signed recovery copy.') }
   if ($p -match '(^|/)Engine/Routes/') { return @('Game-specific OptiShade route DLL','The route is selected by simulator/game and graphics API; removing or mixing versions can prevent initialization for only that title.','Preserve all advertised game routes as independently versioned files and test each route before pruning.') }
   if ($p -match '(^|/)Engine/') { return @('Shared OptiShade/OptiScaler runtime or graphics provider support','Shared proxy/runtime files affect renderer selection and may be loaded under alternate names or host paths. A duplicate hash does not prove the path is redundant.','Keep required loader paths; only remove a path after call-site, architecture/API and clean-game compatibility checks.') }
   if ($p -match '(^|/)Shaders/|(^|/)Textures/') { return @('Image-effects dependency asset','May be referenced by effects or preset configuration even if no direct executable import exists; missing assets can break compile or visual output.','Move with the complete effect package and validate indexing/compilation against clean and existing user presets.') }
   if ($p -match '(^|/)Presets/') { return @('Default or bundled preset','May be user-facing default content; overwriting/removing can lose expected first-run appearance or user edits.','Keep user-writable presets separate from immutable downloaded defaults and preserve existing user files during update/uninstall.') }
   if ($p -match '\.(dll|exe|asi|addon32|addon64)$') { return @('Executable/runtime payload; exact role requires dependency/call-site confirmation','Architecture, loader name, game/API route and VC runtime dependencies may be significant; filename/hash similarity alone is not a safe removal basis.','Do not remove until static dependency and runtime loading checks identify consumers and all supported routes pass.') }
   return @('Configuration, data or marker file','May control default behavior, package discovery, migration or empty-directory initialization; omission can cause route-specific failures.','Trace readers/writers and migration behavior; preserve user state and validate repair/uninstall before moving.')
  }
 }
}

if (-not (Test-Path -LiteralPath $InventoryPath -PathType Leaf)) { throw "Inventory does not exist: $InventoryPath" }
$rows = @(Import-Csv -LiteralPath $InventoryPath)
if (-not $rows.Count) { throw 'Inventory is empty.' }
foreach ($row in $rows) {
 $review=Get-Review ([string]$row.Category) ([string]$row.RelativePath)
 $row | Add-Member -NotePropertyName RuntimeRole -NotePropertyValue $review[0] -Force
 $row | Add-Member -NotePropertyName CompatibilityRisk -NotePropertyValue $review[1] -Force
 $row | Add-Member -NotePropertyName RemovalDecision -NotePropertyValue 'Retain in manager bundle until its signed remote replacement and all dependent lifecycle paths are verified.' -Force
 $row | Add-Member -NotePropertyName RemovalGate -NotePropertyValue $review[2] -Force
 $full=Join-Path $PayloadRoot ([string]$row.RelativePath)
 if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Payload file is missing; refresh the inventory before removal: $($row.RelativePath)" }
 $item=Get-Item -LiteralPath $full -Force
 if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Payload file is a reparse point; review it before removal: $($row.RelativePath)" }
 if ([long]$item.Length -ne [long]$row.Bytes) { throw "Payload size changed; refresh the audit before removal: $($row.RelativePath)" }
 $digest=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
 if ($digest -cne [string]$row.SHA256) { throw "Payload hash changed; refresh the audit before removal: $($row.RelativePath)" }
}
$rows | Export-Csv -LiteralPath $InventoryPath -NoTypeInformation -Encoding UTF8
Write-Output "Reviewed $($rows.Count) payload files. Each hash/size matched the local payload; no file was removed."
