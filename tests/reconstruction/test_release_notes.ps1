$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../../Beta/installer/release-notes.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('optishade-release-notes-'+[guid]::NewGuid().ToString('N'))
$checks=0
function Assert([bool]$Condition,[string]$Message){$script:checks++;if(-not $Condition){throw $Message}}
try{
 [void][IO.Directory]::CreateDirectory($root)
 $key='1.0.77-Rebuild R106';$marker=Join-Path $root 'release-notes-dismissed.txt'
 Assert (-not (TestOptiShadeReleaseNotesDismissed $root $key)) 'Release notes should show automatically before dismissal.'
 Set-Content -LiteralPath $marker -Value $key -Encoding utf8
 Assert (TestOptiShadeReleaseNotesDismissed $root $key) 'A matching dismissal marker should suppress automatic display.'
 Assert (-not (TestOptiShadeReleaseNotesDismissed $root $key -Reopen)) 'Explicit reopen must bypass the matching startup dismissal marker.'
 Assert (-not (TestOptiShadeReleaseNotesDismissed $root '1.0.78-Rebuild R107')) 'A new build key should show its notes automatically.'
 Set-Content -LiteralPath $marker -Value '1.0.76-Rebuild R104' -Encoding utf8
 Assert (-not (TestOptiShadeReleaseNotesDismissed $root $key)) 'A marker for an older build must not suppress current notes.'
 Write-Output "Release-notes dismissal and explicit reopen policy: $checks assertions passed; no popup was shown."
}finally{
 if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
