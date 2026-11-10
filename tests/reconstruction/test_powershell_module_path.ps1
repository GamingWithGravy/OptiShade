$ErrorActionPreference='Stop'
$repository=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$empty=Join-Path ([IO.Path]::GetTempPath()) ('optishade-empty-modules-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($empty)
try{
 $env:PSModulePath=$empty
 . (Join-Path $repository 'Beta/build-identity.ps1')
 InitializeOptiShadeWindowsPowerShellModules
 if(-not (Get-Command Get-FileHash -ErrorAction SilentlyContinue)){throw 'The standard Windows PowerShell utility module was not restored.'}
 $file=Join-Path $empty 'sha256.txt';[IO.File]::WriteAllText($file,'abc',[Text.Encoding]::ASCII)
 $actual=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
 if($actual -cne 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD'){throw 'Get-FileHash returned an unexpected SHA-256 digest.'}
 Write-Output 'PASS: a poisoned module path is repaired and SHA-256 hashing is available.'
}finally{Remove-Item -LiteralPath $empty -Recurse -Force}
