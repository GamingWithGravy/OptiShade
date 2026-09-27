param(
 [Parameter(Mandatory=$true)][string]$File,
 [Parameter(Mandatory=$true)][string]$Thumbprint
)
# Sign only OptiShade's manager or installer, never bundled vendor binaries.
$ErrorActionPreference='Stop'
$target=(Get-Item -LiteralPath $File -ErrorAction Stop).FullName
if([IO.Path]::GetFileName($target) -notmatch '^(FusionSetup|OptiShade_Version_[0-9.]+)\.exe$'){throw 'Only the OptiShade manager host and versioned installer may be signed by this script.'}
$thumb=$Thumbprint.Replace(' ','')
if($thumb -notmatch '^[a-fA-F0-9]{40}$'){throw 'Specify a code-signing certificate thumbprint from CurrentUser/My.'}
$certificate=Get-Item -LiteralPath "Cert:/CurrentUser/My/$thumb" -ErrorAction Stop
if(-not $certificate.HasPrivateKey -or $certificate.NotAfter -lt (Get-Date) -or $certificate.NotBefore -gt (Get-Date)){throw 'The signing certificate must be current and have its private key.'}
if('1.3.6.1.5.5.7.3.3' -notin @($certificate.Extensions|Where-Object {$_.Oid.Value -eq '2.5.29.37'}|ForEach-Object {$_.EnhancedKeyUsages}|ForEach-Object {$_.Value})){throw 'The certificate is not a code-signing certificate.'}
$kit=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/bin'
$signtool=Get-ChildItem -LiteralPath $kit -Filter signtool.exe -File -Recurse|Where-Object {$_.Directory.Name -eq 'x64'}|Sort-Object FullName -Descending|Select-Object -First 1
if(-not $signtool){throw 'Install the Windows SDK signing tools before signing a release.'}
& $signtool.FullName sign /sha1 $thumb /s My /fd SHA256 /tr https://timestamp.digicert.com /td SHA256 /d OptiShade $target
if($LASTEXITCODE){throw 'Signing or timestamping failed. Do not publish this artifact.'}
$signature=Get-AuthenticodeSignature -LiteralPath $target
if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ne $thumb -or -not $signature.TimeStamperCertificate){throw 'The signed artifact did not pass publisher and timestamp verification.'}
"Verified signed artifact: $target"
