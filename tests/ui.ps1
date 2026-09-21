$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework
[xml]$xaml=Get-Content "$PSScriptRoot/../installer/manager.xaml" -Raw -Encoding UTF8
$form=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
if($form.FindName('LibraryNav').Visibility -ne 'Collapsed'){throw 'Library visible'}
foreach($name in @('MsfsCopies','Install','Restore','Runtime','SettingsPage','TroubleshootingNav','TroubleshootingPage','IncludeCinema','InstallCinema','ResetDefaults','ImportZip','CheckUpdates','RecoveryRepair','RecoveryRestore')){if(-not $form.FindName($name)){throw "Missing $name"}}
$tokens=$null;$errors=$null
[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../installer/manager.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
$source=Get-Content "$PSScriptRoot/../installer/manager.ps1" -Raw
foreach($match in [regex]::Matches($source,'\$form\.FindName\(''([^'']+)''\)')){if(-not $form.FindName($match.Groups[1].Value)){throw ('Missing handler control: '+$match.Groups[1].Value)}}
$form.FindName('Intro').Visibility='Collapsed'
$form.FindName('HomePage').Visibility='Collapsed'
$form.FindName('TroubleshootingPage').Visibility='Visible'
$form.Content.Measure([Windows.Size]::new(1100,780));$form.Content.Arrange([Windows.Rect]::new(0,0,1100,780));$form.Content.UpdateLayout()
foreach($name in @('CheckUpdates','TroubleshootingNav','ResetDefaults','RecoveryRestore')){
 $control=$form.FindName($name);$point=$control.TranslatePoint([Windows.Point]::new(0,0),$form.Content)
 if($point.Y+$control.ActualHeight -gt 780 -or $control.ActualHeight -lt 1){throw ('Control cropped: '+$name)}
}
$form.Close()
'PASS: WPF layout loaded, edition controls present, library hidden, manager syntax valid'
