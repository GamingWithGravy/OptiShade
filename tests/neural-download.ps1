$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/ownership.ps1"
. "$PSScriptRoot/../installer/nvidia.ps1"
. "$PSScriptRoot/../installer/neural-download.ps1"
function AssertClosed($Game){}
function Get-CimInstance { [pscustomobject]@{Name=$script:gpuName} }
# Use the exact downloaded release archives; verify both archive and extracted DLL hashes.
$script:calls=0
function GetVerifiedDownload($Url,$Path,$Hash){
 $script:calls++
 $name=if($Url -match 'RankFTW'){'optishade-nr-310.8-source.zip'}else{'optishade-nr-compat-v10.zip'}
 Copy-Item -LiteralPath (Join-Path $env:TEMP $name) -Destination $Path
 if((HashFile $Path) -ne $Hash){throw 'Archive hash failed'}
}
$fixture=Join-Path $env:TEMP ('OptiShade-model-install-'+[guid]::NewGuid().ToString('N'))
foreach($card in @('NVIDIA GeForce RTX 5080','NVIDIA GeForce RTX 4090')){
 $script:gpuName=$card;$gpu=[pscustomobject]@{Names=$card}
 $selection=GetNeuralDownload $gpu
 $game=Join-Path $fixture ($card -replace ' ','');New-Item -ItemType Directory -Path $game -Force|Out-Null
 $mp=ManifestPath (Join-Path $fixture 'Store') $game;New-Item -ItemType Directory -Path (Join-Path (Split-Path $mp) 'Backups') -Force|Out-Null
 WriteState @{Game=$game;Status='Installed';Files=@();OwnedDirectories=@('OptiShadeData')} $mp
 EnsureNeuralRuntime $mp $gpu {}
 if((HashFile (Join-Path $game 'nvngx_dlssnr.dll')) -ne $selection.ModelHash){throw 'Wrong installed model'}
 if(@(Get-ChildItem $game -File).Count -ne 1){throw 'Other archive files were installed'}
 $before=$script:calls;EnsureNeuralRuntime $mp $gpu {}
 if($script:calls -ne $before){throw 'Existing correct model downloaded again'}
 "PASS: $card exact model installed, manifest tracked, repeat download skipped"
 RestoreFusion $mp
 if(Test-Path (Join-Path $game 'nvngx_dlssnr.dll')){throw 'Restore did not remove model'}
}
try{GetNeuralDownload ([pscustomobject]@{Names='NVIDIA GeForce RTX 5080, NVIDIA GeForce RTX 4090'});throw 'Unexpected selection'}catch{if($_.Exception.Message -notmatch 'exactly one'){throw}}
'PASS: ambiguous GPU selection does not download a guessed runtime'

# Inject a failure after a copy has altered the destination; the old model and
# ownership record must both survive so Restore remains possible.
$script:gpuName='NVIDIA GeForce RTX 4090'
$source=Join-Path $fixture 'compat-source.dll'
$zip=[IO.Compression.ZipFile]::OpenRead((Join-Path $env:TEMP 'optishade-nr-compat-v10.zip'))
try{[IO.Compression.ZipFileExtensions]::ExtractToFile($zip.GetEntry('package/candidate-susemi-v10/nvngx_dlssnr.dll'),$source,$false)}finally{$zip.Dispose()}
WriteState @{Game=$game;Status='Installed';Files=@();OwnedDirectories=@('OptiShadeData')} $mp
$dest=Join-Path $game 'nvngx_dlssnr.dll'
Set-Content -LiteralPath $dest 'original model'
$beforeManifest=Get-Content -LiteralPath $mp -Raw
$beforeHash=HashFile $dest
$script:failSource=$source
function Copy-Item($LiteralPath,$Destination,[switch]$Force){
 if($LiteralPath -eq $script:failSource){Set-Content -LiteralPath $Destination 'partial copy';throw 'Injected copy failure'}
 Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
}
try{ImportNrRuntime $mp $source;throw 'Failure was not raised'}catch{if($_.Exception.Message -notmatch 'Injected copy failure'){throw}}
if((HashFile $dest) -ne $beforeHash){throw 'Old model was not recovered'}
if((Get-Content -LiteralPath $mp -Raw).Trim() -ne $beforeManifest.Trim()){throw 'Ownership record was not recovered'}
'PASS: failed runtime import recovers model and ownership record'
Remove-Item Function:\Copy-Item
ImportNrRuntime $mp $source
ImportNrRuntime $mp $dest
RestoreFusion $mp
if((HashFile $dest) -ne $beforeHash){throw 'Original model not restored after successful retry'}
'PASS: retry, import from installed location and restore preserve original model'
