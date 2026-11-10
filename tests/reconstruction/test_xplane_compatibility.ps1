param([string]$Root=(Join-Path $PSScriptRoot '../..'))
$ErrorActionPreference='Stop'
. (Join-Path $Root 'Beta/installer/ownership.ps1')
. (Join-Path $Root 'Beta/installer/xplane-compatibility.ps1')
function Check($Value,[string]$Message){if(-not $Value){throw $Message};Write-Output ('PASS: '+$Message)}
$routeUi=[IO.File]::ReadAllText((Join-Path $Root 'Beta/installer/manager.xaml'))
Check ($routeUi.Contains('Use Native Vulkan for XP12 neural rendering.') -and $routeUi.Contains('DXGI compatibility mode disables Vulkan NR; Menu only disables effects and NR.')) 'XP route UI states clearly which routes disable NR and effects'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-XPlaneRoute-'+[guid]::NewGuid().ToString('N'))
try{
 [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'OptiShadeData'))
 [IO.File]::WriteAllText((Join-Path $fixture 'X-Plane.exe'),'fixture')
 [IO.File]::WriteAllText((Join-Path $fixture 'OptiScaler.ini'),'[Menu]')
 $original=(Get-FileHash -LiteralPath (Join-Path $fixture 'OptiScaler.ini')).Hash
 $file=Join-Path $fixture 'OptiShadeData/XPlane-compatibility.ini'
 Check ((GetOptiShadeXPlaneRoute $fixture) -eq 'native-vulkan' -and -not(Test-Path -LiteralPath $file)) 'missing XP route uses native default without writing settings'
 [IO.File]::WriteAllText($file,"; retain comment`r`n[Other]`r`nGraphicsRoute=untouched`r`n[XPlane]`r`nOther=preserve`r`nGraphicsRoute=invalid`r`n",[Text.UTF8Encoding]::new($true))
 Check ((GetOptiShadeXPlaneRoute $fixture) -eq 'native-vulkan') 'invalid route falls back to native'
 foreach($route in @('legacy-dxgi','menu-only','native-vulkan')){
  SetOptiShadeXPlaneRoute $fixture $route
  Check ((GetOptiShadeXPlaneRoute $fixture) -eq $route) "route $route round-trips"
 }
 $bytes=[IO.File]::ReadAllBytes($file);$text=[IO.File]::ReadAllText($file)
 Check ($bytes[0] -eq 239 -and $text.Contains("[Other]`r`nGraphicsRoute=untouched") -and $text.Contains('Other=preserve') -and $text.Contains('; retain comment')) 'route saves preserve BOM, newline style, comments and unrelated INI settings'
 Check ((GetOptiShadeFilePolicy 'OptiShadeData/XPlane-compatibility.ini') -eq 'UserSettings') 'route remains mutable user settings across updates'
 Check ((Get-FileHash -LiteralPath (Join-Path $fixture 'OptiScaler.ini')).Hash -eq $original) 'saving route does not touch OptiScaler.ini'
 Remove-Item -LiteralPath (Join-Path $fixture 'X-Plane.exe')
 $blocked=$false;try{SetOptiShadeXPlaneRoute $fixture menu-only}catch{$blocked=$true}
 Check $blocked 'route writer rejects unrelated game folders'
}finally{if($fixture.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue}}
