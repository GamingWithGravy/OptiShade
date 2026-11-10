$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -eq 'Core') { throw 'Run with Windows PowerShell 5.1, matching the packaged host.' }

$root = Split-Path (Split-Path $PSScriptRoot)
$manager = Join-Path $root 'Beta/installer/manager.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($manager, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'The manager script does not parse.' }
$targetFunction = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'GetGlassCockpitUpdateTargets'
}, $true)
if (-not $targetFunction) { throw 'The production Glass Cockpit target function was not found.' }

$fixtureRoot = Join-Path $env:TEMP ('OptiShade-glass-startup-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$script:fixtureManifestPath = Join-Path $fixtureRoot 'manifest.json'
[IO.File]::WriteAllText($script:fixtureManifestPath, '{}')
$script:libraryGames = New-Object 'System.Collections.Generic.List[object]'
$game = [pscustomobject]@{ Name = 'MSFS 2024'; Folder = $fixtureRoot }
$script:libraryGames.Add($game)
$script:glassCockpitLatestRelease = $null
$store = $fixtureRoot

function GetFusionGameTargetFolder { throw 'UI target enumeration must not probe games' }
function ManifestPath { throw 'UI target enumeration must not locate receipts' }
function ReadOptiShadeState { throw 'UI target enumeration must not read receipts' }
function GetGlassCockpitUpdateInfo { throw 'UI target enumeration must not hash the addon' }
$cachedTargets=New-Object 'System.Collections.Generic.List[object]'
$cachedTargets.Add([pscustomobject]@{Game=$game;Manifest=[pscustomobject]@{Game=$fixtureRoot};Info=[pscustomobject]@{Installed=$true;Available=$true}})
$cachedTargets.Add([pscustomobject]@{Game=[pscustomobject]@{Name='Other game';Folder='C:\fixture\other'};Manifest=[pscustomobject]@{Game='C:\fixture\other'};Info=[pscustomobject]@{Installed=$true;Available=$false}})
$script:managerStatusState=[pscustomobject]@{Snapshot=[pscustomobject]@{GlassTargets=$cachedTargets}}

try {
    Invoke-Expression $targetFunction.Extent.Text
    $targets = @(GetGlassCockpitUpdateTargets -AvailableOnly)
    if ($targets.Count -ne 1 -or $targets[0].Game.Name -ne 'MSFS 2024') {
        throw 'Glass Cockpit update target enumeration did not preserve the game entry.'
    }
    if($targets[0].Manifest.Game -ne $fixtureRoot){throw 'Cached target lost its exact installation identity'}
    if(@(GetGlassCockpitUpdateTargets).Count -ne 2){throw 'Installed current addon disappeared from developer release checks'}
    $script:managerStatusState.Snapshot=$null
    if(@(GetGlassCockpitUpdateTargets).Count -ne 0){throw 'Startup without a completed snapshot must not fabricate targets'}
} finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Glass Cockpit startup enumeration passes with Windows PowerShell 5.1 generic lists.'
