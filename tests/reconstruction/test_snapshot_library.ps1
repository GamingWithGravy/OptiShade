$ErrorActionPreference='Stop'
$module=Join-Path (Split-Path $PSScriptRoot -Parent | Split-Path -Parent) 'Beta/installer/snapshot-library.ps1'
. $module
$temp=Join-Path ([IO.Path]::GetTempPath()) ('optishade-snapshot-test-'+[guid]::NewGuid().ToString('N'))
try{
 $defaultParent=Join-Path $temp 'Pictures'
 $first=EnsureOptiShadeSnapshotLibrary $defaultParent
 $expected=Join-Path $defaultParent 'OptiShade Snapshots'
 if($first.Root -ne [IO.Path]::GetFullPath($expected) -or -not $first.Created -or -not $first.Writable){throw 'Default snapshot library was not created and validated.'}
 if(-not(Test-Path -LiteralPath $expected -PathType Container)){throw 'Default snapshot root is missing.'}
 if(@(Get-ChildItem -LiteralPath $expected -Force).Count){throw 'Startup validation left files or eagerly created game folders.'}
 $again=EnsureOptiShadeSnapshotLibrary $defaultParent
 if($again.Created){throw 'Existing snapshot root was incorrectly reported as new.'}
 $customParent=Join-Path $temp 'Custom drive\OptiShade Snapshots'
 $custom=EnsureOptiShadeSnapshotLibrary $customParent
 if($custom.Root -ne [IO.Path]::GetFullPath($customParent)){throw 'Custom snapshot root was duplicated.'}
 if(@(Get-ChildItem -LiteralPath $custom.Root -Force).Count){throw 'Custom startup validation left files or game folders.'}
 Write-Output 'Default and custom snapshot roots are created, writable, and game-folder-free.'
}finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}
