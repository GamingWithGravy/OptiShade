param(
 [Parameter(Mandatory=$true)][string[]]$Files,
 [Parameter(Mandatory=$true)][string]$Report,
 [switch]$RequireSigned
)
# Local evidence only: no uploads, exclusions, quarantine restoration or AV configuration changes.
$ErrorActionPreference='Stop'
$status=Get-MpComputerStatus
if(-not $status.AntivirusEnabled -or -not $status.AMServiceEnabled){throw 'Defender is not active. Security verification is unavailable, not passed.'}
$platform=Join-Path $env:ProgramData 'Microsoft/Windows Defender/Platform'
$scanner=Get-ChildItem -LiteralPath $platform -Directory|Sort-Object Name -Descending|ForEach-Object {Join-Path $_.FullName 'MpCmdRun.exe'}|Where-Object {Test-Path -LiteralPath $_ -PathType Leaf}|Select-Object -First 1
if(-not $scanner){throw 'Defender command-line scanner is unavailable.'}
$results=@();$failed=$false
foreach($file in $Files){
 $path=(Get-Item -LiteralPath $file -ErrorAction Stop).FullName
 $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
 $signature=Get-AuthenticodeSignature -LiteralPath $path
 # DisableRemediation keeps this scan read-only; detections still fail the check.
 $output=@(& $scanner -Scan -ScanType 3 -File $path -DisableRemediation 2>&1|ForEach-Object {$_.ToString()})
 $exitCode=$LASTEXITCODE
 $unchanged=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $hash
 $passed=$exitCode -eq 0 -and $unchanged -and (-not $RequireSigned -or $signature.Status -eq 'Valid')
 if(-not $passed){$failed=$true}
 $results+=[ordered]@{File=[IO.Path]::GetFileName($path);SHA256=$hash;Bytes=(Get-Item -LiteralPath $path).Length;Signature=[string]$signature.Status;Signer=if($signature.SignerCertificate){$signature.SignerCertificate.Subject}else{''};DefenderExitCode=$exitCode;Unchanged=$unchanged;CheckPassed=$passed;Output=($output -join "`n")}
}
$document=[ordered]@{CheckedAt=(Get-Date).ToUniversalTime().ToString('o');Engine=$status.AMEngineVersion;Signatures=$status.AntivirusSignatureVersion;SignatureDate=$status.AntivirusSignatureLastUpdated;SignedRequired=[bool]$RequireSigned;Limit='Point-in-time local Defender result. Not a safety certification or a substitute for other vendors reviewing their detections.';Files=$results}
$destination=[IO.Path]::GetFullPath($Report);[void][IO.Directory]::CreateDirectory((Split-Path $destination -Parent))
$document|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $destination -Encoding UTF8
if($failed){throw "Security check failed or was incomplete. Review $destination before publishing."}
"Security check completed: $destination"
