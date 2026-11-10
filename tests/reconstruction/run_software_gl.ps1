param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$MesaDirectory
)

$ErrorActionPreference = 'Stop'
$egl = Join-Path $MesaDirectory 'libEGL.dll'
if (-not (Test-Path -LiteralPath $egl -PathType Leaf)) {
    throw "MesaDirectory must point to the extracted x64 folder containing libEGL.dll: $MesaDirectory"
}

# Keep the portable Mesa runtime isolated to these Python child processes.
# This does not change the system OpenGL loader or touch any game directory.
$env:OPTISHADE_EGL_LIBRARY = $egl
$env:OPTISHADE_EGL_DLL_DIR = (Resolve-Path -LiteralPath $MesaDirectory).Path
$env:GALLIUM_DRIVER = 'llvmpipe'
$env:LIBGL_ALWAYS_SOFTWARE = '1'

$python = Get-Command python -ErrorAction Stop

& $python.Source (Join-Path $PSScriptRoot 'test_core_guides_glsl.py') --software-gl
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& $python.Source (Join-Path $PSScriptRoot 'test_guide_depth_transfer.py') --software-gl
exit $LASTEXITCODE
