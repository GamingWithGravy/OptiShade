param(
 [Parameter(Mandatory=$true)][ValidateSet('stable','beta')][string]$Channel,
 [Parameter(Mandatory=$true)][string]$Version,
 [Parameter(Mandatory=$true)][string]$SourceCommit,
 [Parameter(Mandatory=$true)][string]$LauncherExe
)
$ErrorActionPreference='Stop'
if($Version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$'){throw 'Version must be semantic version text.'}
if($SourceCommit -notmatch '^[a-fA-F0-9]{40,64}$'){throw 'SourceCommit must be a Git commit hash.'}
$exe=(Resolve-Path -LiteralPath $LauncherExe).Path
if([IO.Path]::GetFileName($exe) -notmatch '\.exe$'){throw 'Select the built OptiShade launcher EXE.'}
$dist=Join-Path $PSScriptRoot 'bootstrapper'
$branch='launcher-'+$Channel
$staging=Join-Path $PSScriptRoot ('staging/'+$branch)
[void][IO.Directory]::CreateDirectory($staging)
$attributes=Join-Path $staging '.gitattributes'
if(Test-Path -LiteralPath $attributes -PathType Leaf){
 $oldAttributes=(Get-Content -LiteralPath $attributes -Raw -Encoding UTF8).Trim()
 if($oldAttributes -ceq '*.exe filter=lfs diff=lfs merge=lfs -text'){Remove-Item -LiteralPath $attributes -Force}
 else{throw 'The launcher branch staging folder has custom Git attributes. Review them manually; this generator will not overwrite them.'}
}
$relative='launcher/'+$Version+'/OptiShade.exe'
$destination=Join-Path $staging ($relative.Replace('/','\'))
[void][IO.Directory]::CreateDirectory((Split-Path $destination -Parent))
Copy-Item -LiteralPath $exe -Destination $destination -Force
$hash=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
$size=(Get-Item -LiteralPath $destination).Length
if($size -lt 1 -or $size -gt (99MB)){Remove-Item -LiteralPath $destination -Force;throw "Launcher EXE is $size bytes; ordinary GitHub branch downloads are limited to files below 100 MiB. Split or reduce the package before preparing the channel."}
$payload=[ordered]@{
 schema=1;componentId='OptiShade.Launcher';version=$Version;channel=$Channel;sourceCommit=$SourceCommit.ToLowerInvariant()
 contracts=[ordered]@{launcher='standalone-exe/v1'};dependencies=@()
 package=[ordered]@{path=$relative;bytes=$size;sha256=$hash}
}
$payloadPath=Join-Path $staging '.launcher-payload.json'
$channelPath=Join-Path $staging 'channel.json'
[IO.File]::WriteAllText($payloadPath,(ConvertTo-Json -InputObject $payload -Depth 8)+"`n",[Text.UTF8Encoding]::new($false))
Push-Location $dist
try{
 $signed=& go.exe run ./tools/sign-channel $payloadPath
 if($LASTEXITCODE -ne 0){throw 'Could not sign launcher channel. Check the local OptiShade signing key.'}
 [IO.File]::WriteAllText($channelPath,($signed -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
}finally{Pop-Location;Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue}
Write-Output ('Prepared local channel branch contents: '+$staging)
Write-Output ('Branch: '+$branch+'; signed channel manifest: channel.json; ordinary GitHub file bytes: '+$size)
Write-Output 'No GitHub branch or release was created or changed.'
