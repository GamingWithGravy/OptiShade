param(
 [Parameter(Mandatory=$true)][string]$BaselinePayload,
 [Parameter(Mandatory=$true)][string]$UpdatedPayload,
 [Parameter(Mandatory=$true)][string]$Output,
 [Parameter(Mandatory=$true)][ValidateSet('Core','Effects','Neural','Providers')][string]$Component,
 [Parameter(Mandatory=$true)][string]$Version,
 [Parameter(Mandatory=$true)][ValidateSet('x86','x64')][string]$Architecture,
 [Parameter(Mandatory=$true)][string[]]$Files
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/installer/ownership.ps1"
. "$PSScriptRoot/installer/component-packages.ps1"
if(Test-Path -LiteralPath $Output){throw 'Output already exists; choose a new package folder.'}
$entries=@()
foreach($relative in $Files){
 if((GetOptiShadeAddonId $relative) -ne $Component){throw 'File belongs to a different component: '+$relative}
 $before=HashFile (OwnedPath $BaselinePayload $relative);$after=HashFile (OwnedPath $UpdatedPayload $relative)
 if(-not $before -or -not $after -or $before -eq $after){throw 'Each selected file must exist in both payloads and have changed: '+$relative}
 $entries+=[pscustomobject]@{Path=$relative.Replace('\','/');PreviousHash=$before;Hash=$after}
}
$outputRoot=FullPath $Output;[void][IO.Directory]::CreateDirectory($outputRoot)
foreach($entry in $entries){$target=OwnedPath $outputRoot $entry.Path;[void][IO.Directory]::CreateDirectory((Split-Path $target));Copy-Item -LiteralPath (OwnedPath $UpdatedPayload $entry.Path) -Destination $target}
$catalog=[ordered]@{Schema=1;Id=$Component;Version=$Version;ManagerVersion=(GetBundledOptiShadeVersion);Architecture=$Architecture;Files=$entries}
[IO.File]::WriteAllText((Join-Path $outputRoot 'component-package.json'),($catalog|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
$verified=ReadLocalComponentPackage $outputRoot
Write-Output ('Created '+$Component+' v'+$Version+' local package: '+$verified.Root)
