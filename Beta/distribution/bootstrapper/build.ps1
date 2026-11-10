$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$go=Get-Command go.exe -ErrorAction Stop
Push-Location $root
try{$publicKey=& $go.Source run ./tools/keygen}finally{Pop-Location}
if($LASTEXITCODE -ne 0 -or $publicKey -notmatch '^[A-Za-z0-9+/]{43}=$'){throw 'Could not load or create the local OptiShade publisher key.'}
$keyPath=Join-Path $root '..\release-public-key.json'
$key=[ordered]@{algorithm='Ed25519';keyId='optishade-release-2026';publicKey=$publicKey}
[IO.File]::WriteAllText((Join-Path $root '..\release-public-key.json'),(($key|ConvertTo-Json -Depth 4)+"`n"),[Text.UTF8Encoding]::new($false))
$privatePath=Join-Path $env:LOCALAPPDATA 'OptiShade\Distribution\release-ed25519-private.pem'
if(-not(Test-Path -LiteralPath $privatePath -PathType Leaf)){throw 'Local release private key is missing.'}
# Restrict the signing key to the current Windows account and SYSTEM. It is
# never copied into this checkout or the generated installer.
$null=& icacls.exe $privatePath '/inheritance:r' '/grant:r' ($env:USERDOMAIN+'\'+$env:USERNAME+':F') 'SYSTEM:F'
if($LASTEXITCODE -ne 0){throw 'Could not restrict access to the local signing key.'}
# The installer window uses the launcher's own PowerShell host and icon.
$ui=Join-Path $root 'ui';$installer=Join-Path $root '..\..\installer'
foreach($name in @('FusionSetup.exe','OptiShade-icon.png')){Copy-Item -LiteralPath (Join-Path $installer $name) -Destination (Join-Path $ui $name) -Force}
$outDir=Join-Path $root 'out';[void][IO.Directory]::CreateDirectory($outDir)
$out=Join-Path $outDir 'OptiShade-Installer.exe'
Push-Location $root
try{
 & $go.Source build -trimpath -ldflags ("-s -w -H=windowsgui -X main.releasePublicKeyB64=$publicKey") -o $out .
 if($LASTEXITCODE -ne 0){throw 'Bootstrapper build failed.'}
}finally{Pop-Location}
Write-Output ('Local installer built: '+$out)
Write-Output ('Release public key: '+(Join-Path $root '..\release-public-key.json'))
Write-Output ('Private key remains local: '+$privatePath)
