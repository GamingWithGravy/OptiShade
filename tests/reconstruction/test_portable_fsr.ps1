$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1') -Force
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Beta/installer/ownership.ps1"
. "$root/Beta/installer/mfg.ps1"
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-fsr-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
# Transactions target only generated fixtures; never inspect or change the running simulator.
function AssertClosed([string]$Game){
 $fixtureBase=[IO.Path]::GetFullPath($testRoot).TrimEnd('\')+'\'
 if(-not ([IO.Path]::GetFullPath($Game)).StartsWith($fixtureBase,[StringComparison]::OrdinalIgnoreCase)){throw 'Transaction escaped isolated fixture root.'}
}
$count=0
function Check($value,$message){if(-not $value){throw $message};$script:count++}
function Fixture {
 $f=Join-Path $testRoot ([guid]::NewGuid().ToString('N'));$game=Join-Path $f 'game';$payload=Join-Path $f 'payload'
 [void][IO.Directory]::CreateDirectory((Join-Path $game 'OptiShadeData/Engine'));[void][IO.Directory]::CreateDirectory($payload)
 $fixtureExe=Join-Path $game 'FlightSimulator2024.exe'
 # A bounded x64 PE fixture proves the existing qualified route identity; it
 # is data only and is never executed.
 $bytes=New-Object byte[] 1024;$memory=[IO.MemoryStream]::new($bytes,$true);$writer=[IO.BinaryWriter]::new($memory)
 $writer.Write([uint16]0x5a4d);$memory.Position=0x3c;$writer.Write([uint32]0x80)
 $memory.Position=0x80;$writer.Write([uint32]0x4550);$writer.Write([uint16]0x8664);$writer.Write([uint16]1)
 $memory.Position=0x94;$writer.Write([uint16]240);$writer.Write([uint16]2);$writer.Write([uint16]0x20b)
 $memory.Position=0x98+60;$writer.Write([uint32]512);$memory.Position=0x98+108;$writer.Write([uint32]16)
 $memory.Position=0x98+120;$writer.Write([uint32]0x1000);$writer.Write([uint32]40)
 $memory.Position=0x98+240+8;$writer.Write([uint32]512);$writer.Write([uint32]0x1000);$writer.Write([uint32]512);$writer.Write([uint32]512)
 $memory.Position=512+12;$writer.Write([uint32]0x1040);$memory.Position=576;$writer.Write([Text.Encoding]::ASCII.GetBytes("d3d12.dll`0"));$writer.Dispose()
 [IO.File]::WriteAllBytes($fixtureExe,$bytes)
 [IO.File]::WriteAllText((Join-Path $game 'OptiScaler.ini'),"[FrameGen]`nExternal=true`n[DlssNR]`nStrength=0.6`n[fakenvapi]`nForceXeLL=true")
 $files=@();foreach($name in @('amd_fidelityfx_loader_dx12.dll','amd_fidelityfx_framegeneration_dx12.dll')){
  $relative='OptiShadeData/Engine/'+$name;$p=Join-Path $game $relative;[IO.File]::WriteAllText($p,'fixture '+$name)
  $files+=[pscustomobject]@{Path=$relative;Hash=(HashFile $p);SourcePath=$relative;Mutable=$false;Backup='';PreviousHash='';Retained=$false}
 }
 $manifest=Join-Path $f 'manifest.json'
 WriteState @{Game=$game;LaunchExe=$fixtureExe;Architecture='x64';RouteDLL='OptiShadeMSFS2024.dll';Status='Installed';Files=$files;SourceMfg=$false;OptionalMfg=$false} $manifest
 ConvertTo-Json -InputObject @($files) -Depth 5 | Set-Content (Join-Path $payload 'files.json') -Encoding UTF8
 return @{Game=$game;Payload=$payload;Manifest=$manifest}
}
try {
 $f=Fixture
 SelectPortableFsr2x $f.Manifest $f.Payload
 $m=ReadOptiShadeState $f.Manifest;$ini=[IO.File]::ReadAllText((Join-Path $f.Game 'OptiScaler.ini'))
 Check ($m.FrameGenerationRoute -eq 'portable-fsr2x' -and -not $m.SourceMfg -and -not $m.OptionalMfg) 'Route ownership mismatch'
 foreach($setting in @('External=false','FGInput=DLSSG','FGOutput=FSRFG','Enabled=true','ForceXeLL=false','OverrideInterpolationCount=1','Strength=0.6')){Check ($ini.Contains($setting)) ('Missing or lost '+$setting)}
 Check (Test-Path -LiteralPath (Join-Path $m.FrameGenerationRouteRollback 'manifest.json')) 'No rollback manifest'
 $message=EnsureAutomaticMfg $f.Manifest $f.Payload @('NVIDIA RTX 4090')
 Check ($message -like 'Portable FSR*') 'Automatic MFG overwrote explicit route'
 $f=Fixture;$foreign=Join-Path $f.Game 'version.dll';[IO.File]::WriteAllText($foreign,'foreign')
 $before=HashFile $f.Manifest;$failed=$false;try{SelectPortableFsr2x $f.Manifest $f.Payload}catch{$failed=$true}
 Check ($failed -and (HashFile $f.Manifest) -eq $before -and [IO.File]::ReadAllText($foreign) -eq 'foreign') 'Foreign loader not preserved'
 $f=Fixture;[IO.File]::WriteAllText((Join-Path $f.Game 'OptiShadeData/Engine/amd_fidelityfx_framegeneration_dx12.dll'),'changed')
 $before=HashFile $f.Manifest;$failed=$false;try{SelectPortableFsr2x $f.Manifest $f.Payload}catch{$failed=$true}
 Check ($failed -and (HashFile $f.Manifest) -eq $before) 'Changed provider admitted'
 $f=Fixture;$m=ReadOptiShadeState $f.Manifest
 $receipt=Join-Path $f.Game 'OptiShadeData/MFG/source-backend.json';[void][IO.Directory]::CreateDirectory((Split-Path $receipt));[IO.File]::WriteAllText($receipt,'{"fixture":true}')
 $m.SourceMfg=$true;$m.Files+= [pscustomobject]@{Path='OptiShadeData/MFG/source-backend.json';Hash=(HashFile $receipt);SourcePath='';Mutable=$false;Backup='original-backup';PreviousHash='original-hash';Retained=$true};WriteState $m $f.Manifest
 SelectPortableFsr2x $f.Manifest $f.Payload
 Check (-not(Test-Path -LiteralPath $receipt)) 'Source activation remains alongside FSR'
 $m=ReadOptiShadeState $f.Manifest;$r=@($m.Files|Where-Object Path -like '*source-backend.json')[0]
 Check ($r.Backup -eq 'original-backup' -and $r.PreviousHash -eq 'original-hash' -and -not $r.Hash) 'Original restore chain lost'
 # Inject a failure after files/settings change, at manifest commit.
 $f=Fixture;$before=HashFile $f.Manifest;$iniBefore=HashFile (Join-Path $f.Game 'OptiScaler.ini')
 $realWrite=${function:WriteState};$script:failPath=$f.Manifest
 function WriteState($Object,[string]$Path){if($Path -eq $script:failPath){throw 'injected manifest failure'};& $realWrite $Object $Path}
 $failed=$false;try{SelectPortableFsr2x $f.Manifest $f.Payload}catch{$failed=$true}finally{Set-Item Function:WriteState $realWrite}
 Check ($failed -and (HashFile $f.Manifest) -eq $before -and (HashFile (Join-Path $f.Game 'OptiScaler.ini')) -eq $iniBefore) 'Transaction rollback failed'
 "Portable FSR: $count assertions passed; installer fixtures only, no simulator output inferred."
} finally {
 $resolved=[IO.Path]::GetFullPath($testRoot);$base=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $resolved.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup path'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
