$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework
foreach($scriptFile in @('manager.ps1','library.ps1','support.ps1')){
 $tokens=$null;$errors=$null
 [void][Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/../installer/$scriptFile",[ref]$tokens,[ref]$errors)
 if($errors.Count){throw ($errors|Out-String)}
}
# Validate and measure the actual markup without showing a window or opening a browser.
[xml]$markup=Get-Content "$PSScriptRoot/../installer/manager.xaml" -Raw -Encoding UTF8
$manager=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup))
$manager.FindName('UpdateAvailable').Visibility='Visible'
$content=$manager.Content
$content.Measure([Windows.Size]::new(1000,740));$content.Arrange([Windows.Rect]::new(0,0,1000,740));$content.UpdateLayout()
$button=$manager.FindName('DiscordCommunity');$update=$manager.FindName('UpdateAvailable')
$bp=$button.TranslatePoint([Windows.Point]::new(0,0),$content)
$up=$update.TranslatePoint([Windows.Point]::new(0,$update.ActualHeight),$content)
if($bp.Y -lt $up.Y -or $bp.Y+$button.ActualHeight -gt 740){throw "Sidebar overlaps at minimum height: $($bp.Y) / $($up.Y)"}
$scriptText=Get-Content "$PSScriptRoot/../installer/support.ps1" -Raw -Encoding UTF8
$dialogMarkup=[regex]::Match($scriptText,"(?s)<Window .*?</Window>").Value
$dialog=[Windows.Markup.XamlReader]::Parse($dialogMarkup)
foreach($name in @('Continue','Close','Dismiss','Notes')){if(-not $dialog.FindName($name)){throw "Missing support control: $name"}}
'PASS: PowerShell parsing, support dialog markup and minimum-height sidebar layout'
