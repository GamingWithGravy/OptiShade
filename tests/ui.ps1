$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework
[xml]$xaml=Get-Content "$PSScriptRoot/../installer/manager.xaml" -Raw -Encoding UTF8
$form=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
if($form.FindName('LibraryNav').Visibility -ne 'Collapsed'){throw 'Library visible'}
foreach($name in @('MsfsCopies','Install','Restore','Runtime','SettingsPage')){if(-not $form.FindName($name)){throw "Missing $name"}}
$tokens=$null;$errors=$null
[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../installer/manager.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
$form.Close()
'PASS: WPF layout loaded, edition controls present, library hidden, manager syntax valid'
