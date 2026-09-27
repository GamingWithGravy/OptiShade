param([Parameter(Mandatory=$true)][string]$Executable,[Parameter(Mandatory=$true)][string]$OutputDirectory,[Parameter(Mandatory=$true)][string]$Version)
$ErrorActionPreference='Stop'
if($Version -notmatch '^[a-zA-Z0-9._-]+$'){throw 'Invalid package version'}
$Executable=(Resolve-Path -LiteralPath $Executable).Path
$folder=Join-Path $OutputDirectory ('OptiShade-Portable-'+$Version)
if(Test-Path -LiteralPath $folder){throw 'Portable output already exists. Choose a fresh output directory.'}
New-Item -ItemType Directory -Path $folder -Force|Out-Null
Copy-Item -LiteralPath $Executable -Destination (Join-Path $folder 'OptiShade.exe')
Set-Content -LiteralPath (Join-Path $folder 'portable.txt') -Value 'Keep this file beside OptiShade.exe to use Data in this folder.' -Encoding UTF8
@'
OPTISHADE PORTABLE MANAGER
Extract the entire ZIP into a writable folder before running OptiShade.exe.
Keep portable.txt beside the EXE. Manager settings, installation records, backups,
downloads and extraction sessions are stored in Data beside the EXE.
Game effects and presets remain in each game's OptiShadeData folder. Windows and
graphics drivers may create their own caches. Diagnostics still export to Desktop.

Keep your Data folder: it contains records/backups needed to restore installed games.
Moving between PCs does not migrate games, their presets, or make paths portable.
Use setup to select and install each game on the destination PC.

To update, close the manager, extract the new portable ZIP, and copy your existing
Data folder into the new folder. Do not run it from inside the ZIP. Use setup to
update game files; Repair only supports a matching installed version.
The portable manager uses separate records from the regular manager. Do not install
both over the same game: restore with the original manager before switching modes.
All bundled third-party licences remain applicable. This archive contains the same
runtime payload as its companion EXE; portable packaging adds no GPU capabilities.
'@ | Set-Content -LiteralPath (Join-Path $folder 'README.txt') -Encoding UTF8
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'installer/PayloadFusion/OptiShadeData/Licenses') -Destination (Join-Path $folder 'Licenses') -Recurse
$zip=$folder+'.zip'
if(Test-Path -LiteralPath $zip){throw 'ZIP already exists'}
Compress-Archive -LiteralPath $folder -DestinationPath $zip
Write-Output $zip
