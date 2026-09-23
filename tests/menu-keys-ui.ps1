$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,System.Windows.Forms
. "$PSScriptRoot/../installer/ownership.ps1"
. "$PSScriptRoot/../installer/menu-settings.ps1"
[xml]$xaml=Get-Content "$PSScriptRoot/../installer/manager.xaml" -Raw -Encoding UTF8
$form=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xaml))
$path=$form.FindName('GamePath')
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/../installer/manager.ps1",[ref]$tokens,[ref]$errors)
foreach($name in @('RefreshMenuKeys','BeginMenuKeyCapture','CaptureMenuKey')){$fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true);Invoke-Expression $fn.Extent.Text}
RefreshMenuKeys
$picker=$form.FindName('PrimaryMenuKey')
if($picker.Text -ne 'Insert'){throw 'Default Insert missing'}
if($form.FindName('BackupMenuKey')){throw 'Backup dropdown still present'}
$fixture=Join-Path $env:TEMP ('OptiShade-keys-ui-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $fixture|Out-Null
Set-Content "$fixture/OptiScaler.ini" "[Menu]`nShortcutKey=118`nBackupShortcutKey=75"
$path.Text=$fixture;RefreshMenuKeys
if($picker.Text -ne 'F7' -or $form.FindName('BackupMenuHint').Text -notmatch 'Ctrl\+Shift\+K'){throw 'Installed shortcuts not displayed'}
$before=HashFile "$fixture/OptiScaler.ini"
BeginMenuKeyCapture
$event=[pscustomobject]@{Key=[Windows.Input.Key]::F9;SystemKey=[Windows.Input.Key]::None;Handled=$false}
CaptureMenuKey $event
if($picker.Text -ne 'F9' -or $script:capturingMenuKey -or -not $event.Handled){throw 'Key capture failed'}
if((HashFile "$fixture/OptiScaler.ini") -ne $before){throw 'Key capture saved without Save'}
BeginMenuKeyCapture
CaptureMenuKey ([pscustomobject]@{Key=[Windows.Input.Key]::Escape;SystemKey=[Windows.Input.Key]::None;Handled=$false})
if($picker.Text -ne 'F9' -or $script:capturingMenuKey){throw 'Escape changed pending selection'}
BeginMenuKeyCapture
CaptureMenuKey ([pscustomobject]@{Key=[Windows.Input.Key]::LeftCtrl;SystemKey=[Windows.Input.Key]::None;Handled=$false})
if(-not $script:capturingMenuKey -or $picker.Text -ne 'F9'){throw 'Modifier accepted as primary key'}
RefreshMenuKeys
$form.FindName('Intro').Visibility='Collapsed';$form.FindName('HomePage').Visibility='Collapsed';$form.FindName('KeybindsPage').Visibility='Visible'
function Expand($node){if($node -is [Windows.Controls.Expander] -and $node.Header -eq 'Menu keyboard shortcuts'){$node.IsExpanded=$true};foreach($child in [Windows.LogicalTreeHelper]::GetChildren($node)){if($child -is [Windows.DependencyObject]){Expand $child}}}
Expand $form.Content
$form.Content.Measure([Windows.Size]::new(1100,1100));$form.Content.Arrange([Windows.Rect]::new(0,0,1100,1100));$form.Content.UpdateLayout()
function Texts($node){if($node -is [Windows.Controls.TextBlock]){$node.Text};for($i=0;$i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($node);$i++){Texts ([Windows.Media.VisualTreeHelper]::GetChild($node,$i))}}
if(@(Texts $picker) -notcontains 'F7'){throw 'Selected key not visibly rendered'}
$check=$form.FindName('IncludeEffects');$own=$form.FindName('OwnIniMode')
$check.IsChecked=$true;$check.ApplyTemplate()|Out-Null;$own.ApplyTemplate()|Out-Null
$choice=$check.Template.FindName('Choice',$check)
if($choice.Background.ToString() -ne '#FF54346F'){throw 'Selected FX option not highlighted'}
$own.IsChecked=$true
if($check.IsChecked -or $choice.Background.ToString() -ne '#FF282238'){throw 'FX options are not mutually exclusive'}
$check.IsChecked=$true
$bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new(1100,1100,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($form.Content)
$encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
$stream=[IO.File]::Create((Join-Path $PSScriptRoot '../test-run/menu-keys-ui.png'));try{$encoder.Save($stream)}finally{$stream.Dispose()}
$form.Close()
'PASS: visible default and installed key labels, retained fallback, no backup picker, exclusive FX selection states'
