$ErrorActionPreference='Stop'
$root=Resolve-Path (Join-Path $PSScriptRoot '..\..')
$installer=Join-Path $root 'Beta/installer'
. (Join-Path $installer 'json-state.ps1')
. (Join-Path $installer 'ownership.ps1')
function Assert($condition,$message){if(-not $condition){throw $message}}

# What counts as regenerated cache: only files under OptiShadeData\Cache, never its
# owned marker, a look, a shader or a user file.
Assert (TestOptiShadeRegeneratedData 'OptiShadeData\Cache\reshade-3DFX-49152-1-0-F.asm') 'A cache file is not recognised'
Assert (TestOptiShadeRegeneratedData 'OptiShadeData/Cache/reshade-3DFX.cso') 'A cache file with forward slashes is not recognised'
foreach($kept in 'OptiShadeData\Cache\.keep','OptiShadeData\Presets\Mine.ini','OptiShadeData\Shaders\Cache\a.fx','ReShade.ini','Cache\a.asm'){
 Assert (-not (TestOptiShadeRegeneratedData $kept)) ("Not cache, but treated as cache: "+$kept)
}

# OSD-9BB5: a 5.3 MB receipt from repeated repairs is readable again, keeps every
# owned file, and shrinks on the next save.
$work=Join-Path ([IO.Path]::GetTempPath()) ('osreceipt-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $work|Out-Null
try{
 $path=Join-Path $work 'manifest.json'
 $files=New-Object System.Collections.ArrayList
 [void]$files.Add([pscustomobject]@{Path='OptiShadeData\Cache\.keep';SourcePath='OptiShadeData\Cache\.keep';Hash='81B2';PreviousHash='';Backup='';Mutable=$false;Retained=$false})
 [void]$files.Add([pscustomobject]@{Path='OptiShadeData\Presets\Mine.ini';SourcePath='';Hash='AAAA';PreviousHash='AAAA';Backup='Backups/1';Mutable=$true;Retained=$true})
 [void]$files.Add([pscustomobject]@{Path='OptiShadeData\Cache\kept-hash.cso';SourcePath='';Hash='BBBB';PreviousHash='';Backup='';Mutable=$true;Retained=$false})
 foreach($i in 1..11000){[void]$files.Add([pscustomobject]@{Path=('OptiShadeData\Cache\reshade-3DFX-49152-10295674789262886441-0-F__PostProcessVS-'+$i+'.asm');SourcePath='';Hash='';PreviousHash='';Backup='';Mutable=$true;Retained=$false})}
 $receipt=[pscustomobject]@{Version='P1.0.77';Game='C:\Games\Sim';Status='Installed';OwnedDirectories=@('OptiShadeData');Files=$files}
 [IO.File]::WriteAllText($path,($receipt|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($true))
 $before=(Get-Item -LiteralPath $path).Length
 Assert ($before -gt 4MB) ('The fixture must exceed the old limit, but is '+$before+' bytes')
 $read=ReadOptiShadeState $path
 Assert (@($read.Files).Count -eq 3) ('Expected 3 entries after compaction, got '+@($read.Files).Count)
 foreach($expected in 'OptiShadeData\Cache\.keep','OptiShadeData\Presets\Mine.ini','OptiShadeData\Cache\kept-hash.cso'){
  Assert (@($read.Files|Where-Object Path -eq $expected).Count -eq 1) ('An owned entry was lost: '+$expected)
 }
 WriteState $read $path
 Assert ((Get-Item -LiteralPath $path).Length -lt 4KB) 'The next save did not write the smaller receipt'
 Assert (@((ReadOptiShadeState $path).Files).Count -eq 3) 'The saved receipt does not read back'
 # A small receipt is left exactly as it is; the limit itself still stands.
 Assert (((Get-Content -LiteralPath $path -Raw|ConvertFrom-Json).Files).Count -eq 3) 'The saved receipt is not valid JSON'
}finally{Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}
'PASS: an oversized receipt reads again, keeps owned entries and shrinks on save; only regenerated cache files are dropped.'
