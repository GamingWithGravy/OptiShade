$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
[xml]$xml=Get-Content "$root/Beta/installer/manager.xaml" -Raw -Encoding UTF8
$form=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xml))
$source=Get-Content "$root/Beta/installer/manager.ps1" -Raw
$start=$source.IndexOf('foreach($pair in @(')
$end=$source.IndexOf('$buttons+=@($form.FindName(''ComponentsNav''))',$start)
$buttons=@();Invoke-Expression $source.Substring($start,$end-$start)
$script:count=0
$form.FindName('SetupNav').Add_Click({$script:count++})
$form.FindName('QuickSetup').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
if($script:count -ne 1){throw 'Quick Setup did not use its canonical action'}
$form.FindName('SetupNav').IsEnabled=$false
$form.FindName('QuickSetup').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
if($script:count -ne 1){throw 'Disabled target was bypassed'}
$script:reports=0;$form.FindName('OpenTroubleshooter').Add_Click({$script:reports++})
$script:launcherExports=0;$form.FindName('ExportLauncherLogs').Add_Click({$script:launcherExports++})
$form.FindName('ExportLauncherLogs').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
if($script:launcherExports -ne 1){throw 'One-click launcher log export action is missing or not reachable.'}
$form.FindName('ComponentDiagnostics').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
$form.FindName('OpenTroubleshooter').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
if($script:reports -ne 2 -or $script:count -ne 1){throw 'Component diagnostics did not route to the canonical troubleshooter action'}
$script:compatibilityChecks=0;$form.FindName('CheckCompatibility').Add_Click({$script:compatibilityChecks++})
$form.FindName('TroubleCompatibility').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
if($script:compatibilityChecks -ne 1){throw 'Troubleshooting compatibility action did not reach its canonical check'}

$script:guides=0;$form.FindName('Help').Add_Click({$script:guides++})
$form.FindName('SetupGuide').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
if($script:guides -ne 1){throw 'Setup guide not wired'}
$form.Close()
'Current quick-action routing, compatibility action and disabled-target guard passed; no installation or external process launched.'
