$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/library.ps1"
$fixture=Join-Path $env:TEMP ('OptiShade-anticheat-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$fixture/Clean","$fixture/EAC/EasyAntiCheat","$fixture/BE/BattlEye","$fixture/EA/bin" -Force|Out-Null
New-Item -ItemType Directory -Path "$fixture/Clean/Packages/asobo-challenges-rallyrace-base" -Force|Out-Null
Set-Content "$fixture/Clean/AntiCheatExpert-notes.txt" 'ordinary text, not a runtime'
Set-Content "$fixture/EA/bin/EAAntiCheat.GameServiceLauncher.dll" 'detection fixture'
foreach($case in @(@('EAC','Easy Anti-Cheat'),@('BE','BattlEye'),@('EA','EA AntiCheat'))){
 if(@(FindFusionAntiCheat (Join-Path $fixture $case[0])) -notcontains $case[1]){throw "Detection failed: $($case[1])"}
 "PASS: detects game-local $($case[1])"
}
if(@(FindFusionAntiCheat "$fixture/Clean").Count){throw 'Unrelated anti-cheat triggered a clean game warning'}
'PASS: clean game does not inherit anti-cheat warnings from other installations'
'PASS: MSFS rallyrace-base content and text documents do not trigger anti-cheat'
Add-Type -AssemblyName PresentationFramework
$text=Get-Content "$PSScriptRoot/../installer/consent.ps1" -Raw
[xml]$markup=[regex]::Match($text,'(?s)<Window .*?</Window>').Value
$dialog=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $markup))
if($dialog.FindName('AcceptRisk').IsChecked -or $dialog.FindName('AcceptInstall').IsEnabled){throw 'Acknowledgement must start unchecked and installation disabled'}
'PASS: acknowledgement starts unchecked and Install disabled'
"Fixture: $fixture"
