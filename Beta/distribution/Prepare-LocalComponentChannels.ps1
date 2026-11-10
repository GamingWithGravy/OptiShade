param(
 [string]$PackageSetRoot = '.\build\publication-staging\components-1.0.77',
 [string]$ArchiveRoot = '.\build\local-modular-candidate-1.0.77',
 [string]$OutputRoot = '.\build\local-component-channels-1.0.77',
 [ValidateSet('stable','beta')][string]$Channel = 'stable',
 [string]$LauncherMin = '1.0.0',
 [string]$LauncherMax = '2.0.0',
 # Folders to build; publish only the components that changed.
 [string[]]$Only = @('core','effects','optimfg','providers-amd','providers-intel')
)
$ErrorActionPreference='Stop'
foreach($path in @($PackageSetRoot,$ArchiveRoot,$OutputRoot)){if(-not [IO.Path]::IsPathRooted($path)){throw 'All input and output paths must be absolute.'}}
$PackageSetRoot=(Resolve-Path -LiteralPath $PackageSetRoot).Path
$ArchiveRoot=(Resolve-Path -LiteralPath $ArchiveRoot).Path
$OutputRoot=[IO.Path]::GetFullPath($OutputRoot)
if(Test-Path -LiteralPath $OutputRoot){throw "Refusing to overwrite local branch candidate: $OutputRoot"}
$parent=Get-Item -LiteralPath (Split-Path -Parent $OutputRoot) -Force -ErrorAction Stop
if(-not $parent.PSIsContainer -or ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Candidate parent must be an existing normal directory.'}
$signer=Join-Path $PSScriptRoot 'bootstrapper'
$go=Get-Command go.exe -ErrorAction Stop
$components=@(
 [pscustomobject]@{Folder='core';Id='OptiShade.Core';Branch='core'},
 [pscustomobject]@{Folder='effects';Id='OptiShade.Effects';Branch='effects'},
 [pscustomobject]@{Folder='optimfg';Id='OptiShade.OptiMFG';Branch='optimfg'},
 [pscustomobject]@{Folder='providers-amd';Id='OptiShade.Providers.AMD';Branch='providers-amd'},
 [pscustomobject]@{Folder='providers-intel';Id='OptiShade.Providers.Intel';Branch='providers-intel'}
)|Where-Object {$_.Folder -in $Only}
if(-not @($components).Count){throw 'No known component selected.'}
$tempRoot=Join-Path (Split-Path -Parent $OutputRoot) ('.OptiShade-channel-build-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tempRoot)
$promoted=$false
try{
 foreach($component in $components){
  $packageRoot=Join-Path (Join-Path $PackageSetRoot $component.Folder) 'package'
  $metadata=Get-Content -LiteralPath (Join-Path $packageRoot 'component-package.json') -Raw -Encoding UTF8|ConvertFrom-Json
  if($metadata.schema -ne 1 -or $metadata.componentId -cne $component.Id -or $metadata.channel -cne 'download-only' -or $metadata.installable -ne $false){throw "Unexpected source package identity or activation status: $($component.Id)"}
  if($metadata.version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$' -or $metadata.sourceCommit -notmatch '^[a-fA-F0-9]{40,64}$'){throw "Invalid version or source commit: $($component.Id)"}
  $archiveName=$component.Id+'-'+$metadata.version+'.tar.gz'
  $receipt=@(Get-Content -LiteralPath (Join-Path $ArchiveRoot 'local-build-receipt.json') -Raw -Encoding UTF8|ConvertFrom-Json|Where-Object {$_.componentId -ceq $component.Id})
  if($receipt.Count -ne 1 -or $receipt[0].archive -cne $archiveName -or -not $receipt[0].inventoryVerified){throw "No matching inventory-verified archive receipt: $($component.Id)"}
  $archiveSource=Join-Path $ArchiveRoot $archiveName
  $archiveInfo=Get-Item -LiteralPath $archiveSource -Force
  if($archiveInfo.PSIsContainer -or ($archiveInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$archiveInfo.Length -ne [long]$receipt[0].bytes -or (Get-FileHash -LiteralPath $archiveSource -Algorithm SHA256).Hash -ine [string]$receipt[0].sha256){throw "Local archive no longer matches its inventory receipt: $archiveName"}
  $branchRoot=Join-Path $tempRoot ($component.Branch+'-'+$Channel)
  $packageRelative='packages/'+$archiveName
  $packageDestination=Join-Path $branchRoot ($packageRelative.Replace('/','\'))
  [void][IO.Directory]::CreateDirectory((Split-Path -Parent $packageDestination))
  Copy-Item -LiteralPath $archiveSource -Destination $packageDestination
  $files=@(foreach($entry in $metadata.files){
   $relative=[string]$entry.path
   if([string]::IsNullOrWhiteSpace($relative) -or $relative.Contains('\') -or $relative.StartsWith('/') -or $relative.Contains(':') -or @($relative.Split('/')|Where-Object {$_ -in @('','.','..')}).Count -gt 0){throw "Unsafe package inventory path: $relative"}
   $file=Join-Path $packageRoot ($relative.Replace('/','\'))
   $info=Get-Item -LiteralPath $file -Force
   if($info.PSIsContainer -or ($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$info.Length -ne [long]$entry.bytes -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine [string]$entry.sha256){throw "Component input differs from source inventory: $($component.Id)/$relative"}
   [ordered]@{packagePath=$relative;installPath=$relative;bytes=[long]$entry.bytes;sha256=([string]$entry.sha256).ToLowerInvariant();preconditionSha256=''}
  })
  $dependencies=@()
  if($component.Id -ne 'OptiShade.Core'){$dependencies=@([ordered]@{componentId='OptiShade.Core';minimumVersion='1.0.0'})}
  $payload=[ordered]@{
   schema=1;componentId=$component.Id;version=[string]$metadata.version;channel=$Channel
   publishedUtc=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ');sourceCommit=([string]$metadata.sourceCommit).ToLowerInvariant()
   launcherRange=[ordered]@{minInclusive=$LauncherMin;maxExclusive=$LauncherMax}
   contracts=[ordered]@{};dependencies=$dependencies
   package=[ordered]@{branch=$component.Branch+'-'+$Channel;path=$packageRelative;bytes=[long]$archiveInfo.Length;sha256=(Get-FileHash -LiteralPath $packageDestination -Algorithm SHA256).Hash.ToLowerInvariant()}
   files=$files
  }
  $payloadPath=Join-Path $branchRoot '.payload.json'
  [IO.File]::WriteAllText($payloadPath,(ConvertTo-Json -InputObject $payload -Depth 24)+"`n",[Text.UTF8Encoding]::new($false))
  Push-Location $signer
  try{$signed=& $go.Source run ./tools/sign-component-channel $payloadPath;if($LASTEXITCODE -ne 0){throw "Signing failed for $($component.Id)"}}
  finally{Pop-Location}
  [IO.File]::WriteAllText((Join-Path $branchRoot 'channel.json'),($signed -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
  Remove-Item -LiteralPath $payloadPath -Force
 }
 Move-Item -LiteralPath $tempRoot -Destination $OutputRoot
 $promoted=$true
 Write-Output "Prepared split local signed component branch candidates under $OutputRoot. No game files were changed, and nothing was committed or uploaded."
 Get-ChildItem -LiteralPath $OutputRoot -Directory|ForEach-Object { $channelFile=Join-Path $_.FullName 'channel.json'; [pscustomobject]@{Branch=$_.Name;ManifestBytes=(Get-Item $channelFile).Length;PackageBytes=(Get-ChildItem (Join-Path $_.FullName 'packages') -File|Measure-Object Length -Sum).Sum} }|Format-Table -AutoSize
}finally{
 if(-not $promoted -and (Test-Path -LiteralPath $tempRoot)){
  $resolved=[IO.Path]::GetFullPath($tempRoot);$prefix=[IO.Path]::GetFullPath((Split-Path -Parent $OutputRoot)).TrimEnd('\')+'\'
  if($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^\.OptiShade-channel-build-[0-9a-f]{32}$' -and -not((Get-Item -LiteralPath $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){Remove-Item -LiteralPath $resolved -Recurse -Force}
 }
}
