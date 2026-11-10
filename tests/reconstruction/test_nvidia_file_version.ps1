$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'Beta/installer/nvidia.ps1')
$versionInfo=[pscustomobject]@{FileMajorPart=310;FileMinorPart=9;FileBuildPart=16;FilePrivatePart=0;FileVersion='310,9,16,0'}
if(-not (TestNvidiaFileVersion $versionInfo '310.9.16.0')){throw 'Comma-formatted NVIDIA resource version must match its four numeric version fields.'}
if(TestNvidiaFileVersion $versionInfo '310.9.1.0'){throw 'A different NVIDIA runtime version must not match.'}
if(TestNvidiaFileVersion $versionInfo '310.9.16'){throw 'A malformed catalogue version must not match.'}
$dll=$env:OPTISHADE_NVIDIA_TEST_DLL
if($dll -and (Test-Path -LiteralPath $dll)){
    $actual=(Get-Item -LiteralPath $dll).VersionInfo
    if(-not (TestNvidiaFileVersion $actual '310.9.16.0')){throw "Pinned official NVIDIA DLL failed numeric version validation: $($actual.FileVersion)."}
}
Write-Output 'NVIDIA runtime file-version comparison passed.'
