# A candidate is assembled from declared inputs into an empty directory.
# Preserve previous disposable staging for local comparison; never ingest it.
function AssertPackagePath([string]$Path,[string]$Root){
 $full=[IO.Path]::GetFullPath($Path);$base=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
 if(-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){throw 'Package path escapes its build root'}
 for($item=$full;$item -and $item.Length -ge $base.TrimEnd('\').Length;$item=[IO.Path]::GetDirectoryName($item)){
  if(Test-Path -LiteralPath $item){if((Get-Item -LiteralPath $item -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked package inputs/staging are not supported'}}
 }
 return $full
}
function NewOptiShadePackageStaging([string]$Root){
 $payload=AssertPackagePath (Join-Path $Root 'installer/PayloadFusion') $Root
 if(Test-Path -LiteralPath $payload){
  $previous=AssertPackagePath (Join-Path $Root ('test-run/package-staging/previous-'+[Guid]::NewGuid().ToString('N'))) $Root
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($previous))
  Move-Item -LiteralPath $payload -Destination $previous -ErrorAction Stop
 }
 [void][IO.Directory]::CreateDirectory($payload)
 return $payload
}
function CopyOptiShadePackageInputs([string]$Root,[string]$Group,[string]$Destination){
 $definition=Get-Content -LiteralPath (Join-Path $Root 'package-inputs.json') -Raw|ConvertFrom-Json
 if($definition.Version -ne 1){throw 'Unsupported package input manifest'}
 $entries=@($definition.Groups.PSObject.Properties|Where-Object Name -eq $Group)
 if($entries.Count -ne 1){throw 'Missing package input group'}
 foreach($entry in $entries[0].Value){
  $source=AssertPackagePath (Join-Path $Root $entry.Source) $Root
  $target=AssertPackagePath (Join-Path $Destination $entry.Target) $Root
  if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw ('Missing declared package input: '+$entry.Source)}
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
  Copy-Item -LiteralPath $source -Destination $target -ErrorAction Stop
 }
}
