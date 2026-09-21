$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/ownership.ps1"
. "$PSScriptRoot/../installer/nvidia.ps1"
function AssertClosed($Game){}
function AssertNvidiaFile($Path){}
function Invoke-RestMethod($Uri){[pscustomobject]@{tag_name=if($Uri -match 'Streamline'){'v2.14.1'}else{'v310.9.1'}}}
$fixture=Join-Path $env:TEMP ('OptiShade-NVIDIA-reuse-'+[guid]::NewGuid().ToString('N'))
$engine=Join-Path $fixture 'OptiShadeData/Engine'
New-Item -ItemType Directory -Path "$engine/streamline" -Force|Out-Null
$files=Get-Content "$PSScriptRoot/../installer/nvidia-files.json" -Raw|ConvertFrom-Json
$sl=Get-Content "$PSScriptRoot/../installer/streamline-files.json" -Raw|ConvertFrom-Json
$script:hashes=@{}
foreach($file in $files){$script:hashes[$file.Name]=$file.SHA256;Set-Content (Join-Path $engine $file.Name) 'fixture'}
foreach($file in $sl.files){$script:hashes[$file.name]=$file.sha256;Set-Content (Join-Path "$engine/streamline" $file.name) 'fixture'}
# Inject verification results to test download scheduling without loading vendor binaries.
function HashFile($Path){if(Test-Path -LiteralPath $Path){$script:hashes[[IO.Path]::GetFileName($Path)]}else{''}}
$script:downloads=0
function GetVerifiedDownload($Url,$Path,$Hash){$script:downloads++;if($Url -like '*.zip'){throw 'Unchanged Streamline must not download'};Set-Content -LiteralPath $Path 'download fixture'}
InstallNvidia $fixture {}
if($script:downloads){throw 'Verified files downloaded again'}
'PASS: complete NVIDIA and Streamline installation makes no binary downloads'
Remove-Item -LiteralPath (Join-Path $engine 'nvngx_dlss.dll')
InstallNvidia $fixture {}
if($script:downloads -ne 1 -or -not(Test-Path (Join-Path $engine 'nvngx_dlss.dll'))){throw 'Missing DLSS repair failed'}
'PASS: only missing DLSS runtime downloaded; intact Streamline kept'
