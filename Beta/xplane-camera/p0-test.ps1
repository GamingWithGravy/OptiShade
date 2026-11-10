# XP12 camera P0 test install / rollback for the owner's machine only.
#   p0-test.ps1 -Install   back up ReShade64.dll, install the P0 ReShade64.dll and camera plugin
#   p0-test.ps1 -Rollback  restore exactly what -Install replaced (hash-checked)
param([switch]$Install,[switch]$Rollback,[string]$Game='E:\X-Plane 12',
      [string]$Store='.\build\artifacts\xp12-experiment\camera-p0')
$ErrorActionPreference='Stop'
if(Get-Process -Name 'X-Plane' -ErrorAction SilentlyContinue){throw 'Close X-Plane first.'}
$beta=Split-Path $PSScriptRoot
$liveDll=Join-Path $Game 'ReShade64.dll'
$pluginDir=Join-Path $Game 'Resources\plugins\OptiShadeCamera'
$receiptPath=Join-Path $Store 'receipt.json'
function Hash($p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash}
if($Install){
 if(Test-Path -LiteralPath $receiptPath){throw "A P0 install is already recorded in $receiptPath. Roll back first."}
 if(Test-Path -LiteralPath $pluginDir){throw "$pluginDir already exists; inspect it before installing."}
 $newDll=Join-Path $beta 'reshade\bin\x64\Release\ReShade64.dll'
 $newPlugin=Join-Path $PSScriptRoot 'build\64\win.xpl'
 foreach($f in $liveDll,$newDll,$newPlugin){if(-not(Test-Path -LiteralPath $f)){throw "Missing $f"}}
 New-Item -ItemType Directory -Force $Store|Out-Null
 # One backup per install: a later install never overwrites an earlier one.
 $backup=Join-Path $Store ('ReShade64.dll.before-'+[DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))
 Copy-Item -LiteralPath $liveDll -Destination $backup
 $receipt=[ordered]@{installedUtc=[DateTime]::UtcNow.ToString('o');game=$Game
  backup=$backup;originalReShade=Hash $backup;installedReShade=Hash $newDll;plugin=Hash $newPlugin;pluginDir=$pluginDir}
 if($receipt.originalReShade -ne (Hash $liveDll)){throw 'Backup verification failed.'}
 Copy-Item -LiteralPath $newDll -Destination $liveDll -Force
 New-Item -ItemType Directory -Force (Join-Path $pluginDir '64')|Out-Null
 Copy-Item -LiteralPath $newPlugin -Destination (Join-Path $pluginDir '64\win.xpl')
 $receipt|ConvertTo-Json|Set-Content -LiteralPath $receiptPath -Encoding UTF8
 'Installed P0 test build. Receipt: '+$receiptPath
}elseif($Rollback){
 $r=Get-Content -LiteralPath $receiptPath -Raw|ConvertFrom-Json
 $backup=if($r.backup){$r.backup}else{Join-Path $Store 'ReShade64.dll.before'}
 if((Hash $backup) -ne $r.originalReShade){throw 'Backup changed since install; not restoring.'}
 if((Hash $liveDll) -eq $r.installedReShade){Copy-Item -LiteralPath $backup -Destination $liveDll -Force;'Restored original ReShade64.dll'}
 else{'ReShade64.dll is no longer the P0 build (updated since?); left as is.'}
 $xpl=Join-Path $r.pluginDir '64\win.xpl'
 if((Test-Path -LiteralPath $xpl) -and (Hash $xpl) -eq $r.plugin){Remove-Item -LiteralPath $r.pluginDir -Recurse -Force;'Removed camera plugin'}
 elseif(Test-Path -LiteralPath $r.pluginDir){'Camera plugin folder differs from the receipt; left in place for inspection.'}
 Move-Item -LiteralPath $receiptPath -Destination ($receiptPath+'.rolled-back-'+[DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))
}else{'Use -Install or -Rollback.'}
