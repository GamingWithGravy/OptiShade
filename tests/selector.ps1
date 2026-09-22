$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework
[xml]$xaml=Get-Content "$PSScriptRoot/../installer/manager.xaml" -Raw -Encoding UTF8
$form=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
$form.FindName('Intro').Visibility='Collapsed';$form.FindName('HomePage').Visibility='Collapsed';$form.FindName('SetupPage').Visibility='Visible'
$combo=$form.FindName('MsfsCopies')
$combo.ItemsSource=@([pscustomobject]@{Label='Xbox — OptiShade Installed';State='Not installed';Artwork='MUST_NOT_DISPLAY_IMAGE_DATA';Folder='E:\test';Launcher='Xbox'},[pscustomobject]@{Label='Steam — OptiShade Not installed';State='Not installed';Artwork='MUST_NOT_DISPLAY_IMAGE_DATA';Folder='D:\test';Launcher='Steam'})
$combo.SelectedIndex=0
$form.Opacity=0;$form.ShowInTaskbar=$false;$form.Show();$form.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
$form.Measure([Windows.Size]::new(1100,780));$form.Arrange([Windows.Rect]::new(0,0,1100,780));$form.UpdateLayout()
function GetTexts($node){if($node -is [Windows.Controls.TextBlock]){$node.Text};for($i=0;$i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($node);$i++){GetTexts ([Windows.Media.VisualTreeHelper]::GetChild($node,$i))}}
foreach($index in @(0,1)){
 $combo.SelectedIndex=$index;$form.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle);$form.UpdateLayout();$texts=@(GetTexts $combo)
 if($texts -notcontains $combo.SelectedItem.Label){throw "Selected label not rendered: $texts"}
 if(($texts -join ' ') -match 'MUST_NOT_DISPLAY|Artwork=|Folder='){throw 'Internal record leaked'}
 "PASS: rendered label: $($combo.SelectedItem.Label)"
}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/../installer/manager.ps1",[ref]$tokens,[ref]$errors)
$fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'RefreshLibrary'},$true)
. ([scriptblock]::Create($fn.Extent.Text))
$homeFn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'RefreshHomeState'},$true)
. ([scriptblock]::Create($homeFn.Extent.Text))
function GetFusionInstallState($Store,$Game){'Installed'}
$store='fixture';$path=$form.FindName('GamePath');$path.Text='D:\test'
RefreshLibrary
$form.UpdateLayout();$texts=@(GetTexts $combo)
if($texts -notcontains 'Steam - OptiShade Installed'){throw 'Selected installation text did not refresh immediately'}
'PASS: selected installation label updates without restarting the launcher'
if($form.FindName('HomeInstallState').Text -ne 'OptiShade installed'){throw 'Home installed label missing'}
function GetFusionInstallState($Store,$Game){'Not installed (restored)'}
RefreshLibrary
if($form.FindName('HomeInstallState').Text -ne 'Install OptiShade'){throw 'Home label did not reset after restore'}
if($form.FindName('TitleBar').ToolTip){throw 'Drag tooltip remains'}
'PASS: Home install state tracks installed and restored states; no drag tooltip'
$actionFn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'RunAction'},$true)
. ([scriptblock]::Create($actionFn.Extent.Text))
function ResolveFusionInstallFolder($Game){$Game}
function GetFusionInstallState($Store,$Game){$script:fixtureState}
$buttons=@('Install','Repair','Restore','Retry','TroubleshootingNav')|ForEach-Object {$form.FindName($_)}
$status=$form.FindName('Status');$script:startupResult=$null;$script:uninstallDone=$false
foreach($case in @(@{State='Installed';Enabled=$false;Label='Already installed'},@{State='Installed - downloads pending';Enabled=$false;Label='Already installed'},@{State='Installation incomplete - repair required';Enabled=$false;Label='Repair required'},@{State='Not installed (restored)';Enabled=$true;Label='Install OptiShade'},@{State='Not installed';Enabled=$true;Label='Install OptiShade'})){
 $script:fixtureState=$case.State
 RunAction {}
 $install=$form.FindName('Install')
 if($install.IsEnabled -ne $case.Enabled -or $install.Content -ne $case.Label){throw "Wrong Install state after action: $($case.State)"}
 foreach($name in @('Repair','Restore','Retry','TroubleshootingNav')){if(-not $form.FindName($name).IsEnabled){throw "Recovery control unavailable: $name"}}
}
$script:fixtureState='Not installed';$script:busy=$true;RefreshHomeState
if($form.FindName('Install').IsEnabled){throw 'Install was re-enabled during a busy operation'}
$script:busy=$false;$path.Text='';RefreshHomeState
if($form.FindName('Install').IsEnabled){throw 'Install enabled without a game path'}
'PASS: Install button stays disabled after actions for installed/incomplete states, enables after restore, and leaves recovery controls usable'
$form.Close()

