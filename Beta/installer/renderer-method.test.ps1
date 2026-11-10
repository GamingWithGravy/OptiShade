$ErrorActionPreference = 'Stop'
$compatibilityPath = Join-Path $PSScriptRoot 'compatibility.ps1'
. $compatibilityPath

function Assert-Equal([string]$Expected, [string]$Actual, [string]$Name) {
    if ($Expected -cne $Actual) { throw "$Name expected '$Expected' but received '$Actual'." }
}
function Assert-ScriptParses([string]$Path) {
    $tokens = $null; $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count) { throw "$(Split-Path $Path -Leaf) has parse errors: $($parseErrors -join '; ')" }
}

$methods = @('winmm.dll', 'dxgi.dll', 'd3d12.dll', 'version.dll', 'dbghelp.dll')
foreach ($method in $methods) {
    Assert-Equal $method (ResolveOptiShadeInstallMethod $method) "Explicit method $method"
}
Assert-Equal 'winmm.dll' (ResolveOptiShadeInstallMethod 'auto' 'winmm.dll') 'Automatic Vulkan method'
Assert-Equal 'dxgi.dll' (ResolveOptiShadeInstallMethod 'auto' 'dxgi.dll') 'Automatic DirectX method'
Assert-Equal 'Vulkan' (GetOptiShadeMethodRendererApi 'auto' 'winmm.dll') 'Automatic Vulkan route'
Assert-Equal 'DirectX' (GetOptiShadeMethodRendererApi 'auto' 'version.dll') 'Automatic fallback route'
Assert-Equal 'Vulkan' (GetOptiShadeMethodRendererApi 'winmm.dll') 'Explicit Vulkan route'
Assert-Equal 'DirectX' (GetOptiShadeMethodRendererApi 'auto' 'winmm.dll' @('DX12')) 'Automatic Xbox WinMM loader with detected DirectX renderer'
Assert-Equal 'Vulkan' (GetOptiShadeMethodRendererApi 'winmm.dll' 'winmm.dll' @('DX12')) 'Explicit WinMM method selects Vulkan'
Assert-Equal 'DirectX' (GetOptiShadeMethodRendererApi 'd3d12.dll') 'Explicit DirectX route'
Assert-Equal 'Vulkan' (GetOptiShadeMethodRendererApi 'auto' 'auto' @('Vulkan')) 'Uninstalled automatic Vulkan detection'
$singleDxgiReceipt = [pscustomobject]@{ Files=@([pscustomobject]@{SourcePath='winmm.dll';Path='dxgi.dll'}) }
Assert-Equal 'dxgi.dll' (GetOptiShadeInstalledLoaderPath $singleDxgiReceipt) 'Single installed DXGI loader receipt'
$singleWinmmReceipt = [pscustomobject]@{ Files=@([pscustomobject]@{SourcePath='winmm.dll';Path='winmm.dll'}) }
Assert-Equal 'winmm.dll' (GetOptiShadeInstalledLoaderPath $singleWinmmReceipt) 'Single installed Vulkan loader receipt'
Assert-Equal '' (GetOptiShadeInstalledLoaderPath ([pscustomobject]@{Files=@()})) 'Missing installed loader receipt'
$duplicateLoaderReceipt = [pscustomobject]@{ Files=@([pscustomobject]@{SourcePath='winmm.dll';Path='dxgi.dll'},[pscustomobject]@{SourcePath='winmm.dll';Path='version.dll'}) }
Assert-Equal '' (GetOptiShadeInstalledLoaderPath $duplicateLoaderReceipt) 'Ambiguous installed loader receipt'
$legacyDirectX = [pscustomobject]@{ Files=@([pscustomobject]@{SourcePath='winmm.dll';Path='dxgi.dll'}); RendererApi='auto' }
$legacyVulkan = [pscustomobject]@{ RendererApi='vulkan' }
$newAutomatic = [pscustomobject]@{ InstallMethod='auto'; Files=@([pscustomobject]@{SourcePath='winmm.dll';Path='winmm.dll'}); RendererApi='vulkan' }
Assert-Equal 'dxgi.dll' (GetOptiShadeStoredMethod $legacyDirectX) 'Legacy manifest loader migration'
Assert-Equal 'winmm.dll' (GetOptiShadeStoredMethod $legacyVulkan) 'Legacy renderer migration'
Assert-Equal 'auto' (GetOptiShadeStoredMethod $newAutomatic) 'Saved Automatic method preference'

$invalidRejected = $false
try { $null = ResolveOptiShadeInstallMethod 'not-a-method' } catch { $invalidRejected = $true }
if (-not $invalidRejected) { throw 'An unsupported method was accepted.' }

$managerPath = Join-Path $PSScriptRoot 'manager.ps1'
Assert-ScriptParses $managerPath
Assert-ScriptParses (Join-Path $PSScriptRoot 'update-install.ps1')
[xml]$xaml = Get-Content (Join-Path $PSScriptRoot 'manager.xaml') -Raw -Encoding UTF8
$methodControls = $xaml.SelectNodes("//*[local-name()='ComboBox' and @*[local-name()='Name']='Method']")
$rendererControls = $xaml.SelectNodes("//*[@*[local-name()='Name']='RendererApi']")
if ($methodControls.Count -ne 1) { throw "Expected one Method selector; found $($methodControls.Count)." }
if ($rendererControls.Count -ne 0) { throw 'The duplicate RendererApi selector remains in manager.xaml.' }
$methodTags = @($methodControls[0].SelectNodes("./*[local-name()='ComboBoxItem']") | ForEach-Object { $_.GetAttribute('Tag') } | Sort-Object)
$expectedTags = @(@('auto') + $methods | Sort-Object)
if (Compare-Object $expectedTags $methodTags) { throw 'Method selector options do not match the supported installation methods.' }

Write-Output 'Renderer method tests passed.'
