function GetOptiShadeSnapshotParent {
 $pictures=[Environment]::GetFolderPath([Environment+SpecialFolder]::MyPictures)
 if([string]::IsNullOrWhiteSpace($pictures)){$pictures=Join-Path $env:USERPROFILE 'Pictures'}
 $parent=$pictures
 $settings=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'OptiShade/Snapshot-settings.ini'
 if(Test-Path -LiteralPath $settings -PathType Leaf){
  foreach($line in [IO.File]::ReadAllLines($settings,[Text.Encoding]::Unicode)){
   if($line -match '^\s*Directory\s*=\s*(.+?)\s*$'){$candidate=$Matches[1].Trim().Trim('"');if($candidate){$parent=$candidate};break}
  }
 }
 return $parent
}
function GetOptiShadeSnapshotRoot([string]$Parent){
 if([string]::IsNullOrWhiteSpace($Parent)){$Parent=GetOptiShadeSnapshotParent}
 if($Parent.Contains("`r") -or $Parent.Contains("`n")){throw 'Snapshot location contains an invalid line break.'}
 $parentPath=[IO.Path]::GetFullPath($Parent.Trim())
 if(-not [IO.Path]::IsPathRooted($parentPath)){throw 'Snapshot location must be an absolute path.'}
 if([string]::Equals((Split-Path -Leaf $parentPath),'OptiShade Snapshots',[StringComparison]::OrdinalIgnoreCase)){$root=$parentPath}
 else{$root=Join-Path $parentPath 'OptiShade Snapshots'}
 return [IO.Path]::GetFullPath($root)
}
function AssertOptiShadeSnapshotPath([string]$Target){
 $targetPath=[IO.Path]::GetFullPath($Target)
 for($probe=$targetPath;$probe;){
  if(Test-Path -LiteralPath $probe){
   $item=Get-Item -LiteralPath $probe -Force -ErrorAction Stop
   if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Snapshot locations cannot use linked or junction paths: $probe"}
   if([string]::Equals($probe,$targetPath,[StringComparison]::OrdinalIgnoreCase) -and -not $item.PSIsContainer){throw "Snapshot location is not a folder: $probe"}
  }
  $next=Split-Path -Parent $probe
  if(-not $next -or $next -eq $probe){break}
  $probe=$next
 }
}
function EnsureOptiShadeSnapshotLibrary([string]$Parent){
 $root=GetOptiShadeSnapshotRoot $Parent
 $parent=[IO.Path]::GetDirectoryName($root)
 if(-not $parent){throw 'Could not resolve the snapshot library parent folder.'}
 AssertOptiShadeSnapshotPath $parent
 [void][IO.Directory]::CreateDirectory($parent)
 AssertOptiShadeSnapshotPath $parent
 AssertOptiShadeSnapshotPath $root
 $created=-not(Test-Path -LiteralPath $root -PathType Container)
 [void][IO.Directory]::CreateDirectory($root)
 AssertOptiShadeSnapshotPath $root
 $probe=Join-Path $root ('.optishade-write-check-'+[guid]::NewGuid().ToString('N')+'.tmp')
 try{
  $stream=[IO.File]::Open($probe,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try{$stream.WriteByte(0)}finally{$stream.Dispose()}
 }finally{if(Test-Path -LiteralPath $probe -PathType Leaf){Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue}}
 return [pscustomobject]@{Parent=$parent;Root=$root;Created=$created;Writable=$true}
}
