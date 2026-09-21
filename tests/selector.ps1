$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework
[xml]$xaml=Get-Content "$PSScriptRoot/../installer/manager.xaml" -Raw -Encoding UTF8
$form=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
$form.FindName('Intro').Visibility='Collapsed';$form.FindName('HomePage').Visibility='Collapsed';$form.FindName('SetupPage').Visibility='Visible'
$combo=$form.FindName('MsfsCopies')
$combo.ItemsSource=@([pscustomobject]@{Label='Xbox — OptiShade Installed';Artwork='MUST_NOT_DISPLAY_IMAGE_DATA';Folder='E:\test';Launcher='Xbox'},[pscustomobject]@{Label='Steam — OptiShade Not installed';Artwork='MUST_NOT_DISPLAY_IMAGE_DATA';Folder='D:\test';Launcher='Steam'})
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
$form.Close()

