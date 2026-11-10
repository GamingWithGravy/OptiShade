$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Beta/installer/components.ps1"
$temp=Join-Path $root ('test-results/legacy-preset-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
foreach($inputText in @("Techniques=`nTechniqueSorting=`n[Other.fx]`nValue=7`n", "[Other.fx]`nValue=7`n", "Techniques=Other@Other.fx`nTechniqueSorting=Other@Other.fx`n[Other.fx]`nValue=7`n")){
 $path=Join-Path $temp ([guid]::NewGuid().ToString('N')+'.ini')
 [IO.File]::WriteAllText($path,$inputText)
 if(-not(SetLegacyNrPresetTechnique $path $true)){throw 'Enable failed'}
 $text=[IO.File]::ReadAllText($path);$rootSection=($text -split '\[Other.fx\]')[0]
 foreach($key in @('Techniques','TechniqueSorting')){if($rootSection -notmatch ($key+'=[^\r\n]*DLSS5_Feed@DLSS5_Feed.fx')){throw "$key missing from preset root"}}
 if(-not $text.Contains('Value=7')){throw 'User setting lost'}
 [void](SetLegacyNrPresetTechnique $path $true)
 if([IO.File]::ReadAllText($path) -cne $text){throw 'Enable is not idempotent'}
 [void](SetLegacyNrPresetTechnique $path $false)
 $disabled=[IO.File]::ReadAllText($path)
 if($disabled.Contains('DLSS5_Feed@')){throw 'Disable left feed enabled'}
 if($inputText.Contains('Other@') -and -not $disabled.Contains('Other@Other.fx')){throw 'User effect removed'}
}
'PASS: empty, missing and populated preset roots; idempotence; disable; user settings retained.'
