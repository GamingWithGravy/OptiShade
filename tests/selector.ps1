$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework
[xml]$xaml=Get-Content "$PSScriptRoot/../installer/manager.xaml" -Raw -Encoding UTF8
$form=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
$form.FindName('Intro').Visibility='Collapsed';$form.FindName('HomePage').Visibility='Collapsed';$form.FindName('SetupPage').Visibility='Visible'
$combo=$form.FindName('MsfsCopies')
$combo.ItemsSource=@([pscustomobject]@{Label='Xbox — OptiShade Installed';State='Not installed';Artwork='MUST_NOT_DISPLAY_IMAGE_DATA';Folder='E:\test';Launcher='Xbox';Name='Microsoft Flight Simulator 2024'},[pscustomobject]@{Label='Steam — OptiShade Not installed';State='Not installed';Artwork='MUST_NOT_DISPLAY_IMAGE_DATA';Folder='D:\test';Launcher='Steam';Name='Microsoft Flight Simulator 2024'})
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
function GetMsfsTitle($Game){'Microsoft Flight Simulator 2024'}
function GetFusionInstallState($Store,$Game){'Installed'}
$store='fixture';$path=$form.FindName('GamePath');$path.Text='D:\test'
RefreshLibrary
$form.UpdateLayout();$texts=@(GetTexts $combo)
if($texts -notcontains 'Microsoft Flight Simulator 2024 / Steam - OptiShade Installed'){throw 'Selected installation text did not refresh immediately'}
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


$combo.ItemsSource=@([pscustomobject]@{Name='Microsoft Flight Simulator 2024';State='Installed';Folder='D:\2024';Launcher='Xbox'},[pscustomobject]@{Name='Microsoft Flight Simulator 2020';State='Not installed';Folder='D:\2020';Launcher='Steam'})
function GetMsfsTitle($Game){if($Game -match '2020'){'Microsoft Flight Simulator 2020'}else{'Microsoft Flight Simulator 2024'}}
foreach($selected in @('D:\2020','D:\2024')){
 $path.Text=$selected;RefreshHomeState
 if($form.FindName('HomeDetection').Text -ne 'MSFS 2024 detected' -or $form.FindName('Home2020Detection').Text -ne 'MSFS 2020 detected'){throw 'Detection label follows selected game instead of its own card'}
}
$combo.ItemsSource=@();$path.Text='D:\2020';RefreshHomeState
if($form.FindName('HomeDetection').Text -ne 'MSFS 2024 not detected' -or $form.FindName('Home2020Detection').Text -ne 'MSFS 2020 detected'){throw 'Single manually selected simulator is attributed to the wrong card'}
'PASS: each Home card reports its own simulator, with both installed or one manually selected'
if($form.FindName('HomeDetection').Foreground.Color.ToString() -ne '#FFC9B6DF' -or $form.FindName('Home2020Detection').Foreground.Color.ToString() -ne '#FFC9B6DF'){throw 'Detection colors do not match detection state'}
'PASS: detection labels use muted colours'
