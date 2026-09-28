# Resolve only known simulator package aliases, never arbitrary linked data folders.
function ResolveSimulatorStoreTarget([string]$Folder){
 $path=[IO.Path]::GetFullPath($Folder).TrimEnd('\','/')
 $leaf=[IO.Path]::GetFileName($path)
 if($leaf -notmatch '^Microsoft\.(FlightSimulator|Limitless)_[^\\/]+$'){throw 'Unsupported simulator package alias.'}
 $seen=@{}
 for($hop=0;$hop -lt 8;$hop++){
  if($seen.ContainsKey($path)){throw 'A loop was found in the simulator package links.'};$seen[$path]=$true
  if($path -notmatch '(?i)[\\/]WindowsApps[\\/][^\\/]+$' -or [IO.Path]::GetFileName($path) -ne $leaf){throw 'The simulator package link changed identity.'}
  $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
  $targets=@($item.Target|Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
  if(-not($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $targets.Count -ne 1){throw 'The simulator package does not expose an accessible game-folder link.'}
  $target=[string]$targets[0]
  if($target.StartsWith('\??\') -or $target.StartsWith('\\?\')){$target=$target.Substring(4)}
  if($target -notmatch '^[A-Za-z]:[\\/]'){throw 'The simulator link does not point to a local drive folder.'}
  $path=[IO.Path]::GetFullPath($target).TrimEnd('\','/')
  if($path -notmatch '(?i)[\\/]WindowsApps(?:[\\/]|$)'){return $path}
 }
 throw 'The simulator package link chain is too long.'
}
