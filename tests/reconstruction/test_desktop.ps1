param([string]$Screenshot,[ValidateSet("Home","Library","Components","Setup","Settings","Troubleshooting","Keybinds","Search")][string]$Page="Home",[int]$Width=1100,[int]$Height=930,[switch]$ShowUpdateAvailable,[switch]$ShowComponentOptions,[switch]$ShowXPlaneRoute)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source=Join-Path $root 'Beta/installer/manager.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
if(-not $ast.ParamBlock -or $ast.ParamBlock.Parameters.Count -ne 2){throw 'Manager script must bind Payload and Installer; check its encoding and parameter declaration.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
[xml]$xml=Get-Content (Join-Path $root 'Beta/installer/manager.xaml') -Raw -Encoding UTF8
$window=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xml))
$names=@([regex]::Matches((Get-Content $source -Raw),'\$form\.FindName\(''([^'']+)''\)')|ForEach-Object {$_.Groups[1].Value}|Select-Object -Unique)
foreach($name in $names){if(-not $window.FindName($name)){throw "Missing production binding: $name"}}
$shortcutSource=Get-Content $source -Raw
if($shortcutSource -notmatch 'if\(-not \$sourceControl -or -not \$targetControl\)'){throw 'Home shortcut registration must tolerate a missing optional control instead of aborting manager startup.'}
foreach($name in @('SetupGuide','Help','QuickSetup','SetupNav','QuickUpdates','CheckUpdates','ComponentCore','ComponentDiagnostics','OpenTroubleshooter','KeysChooseGame','TroubleCompatibility','CheckCompatibility')){if(-not $window.FindName($name)){throw "Missing home shortcut binding: $name"}}
if($window.FindName('HomeNav').Content.Children[1].Text -ne 'Home'){throw 'Wrong library navigation'}
if($xml.OuterXml -match 'Text="Working"'){throw 'Unobserved Working badge remains'}

foreach($action in @('PrepareMfg','PrepareOlderRtx','Runtime','CheckCompatibility')){
 $node=$window.FindName($action);$inside=$false
 while($node){if($node -eq $window.FindName('ComponentsPage')){$inside=$true;break};$node=[Windows.LogicalTreeHelper]::GetParent($node)}
 if(-not $inside){throw "Component action remains outside Components: $action"}
}
foreach($component in @('Effects','Neural','Mfg','Cockpit','Providers')){
 if(-not ($window.FindName('Addon'+$component+'Selected') -is [Windows.Controls.CheckBox])){throw "Missing checkbox component selector: $component"}
 if($window.FindName('Addon'+$component+'Install') -or $window.FindName('Addon'+$component+'Remove')){throw "Individual component buttons remain for: $component"}
}
foreach($control in @('ComponentsApply','ComponentsInstallAll','InstallAllFx','ImportFxIni','DlssRuntimeProfile','LibraryPageStatus','ComponentOptions','RenderingComponentOptions','CompatibilityOptions')){if(-not $window.FindName($control)){throw "Missing component or continuous-library control: $control"}}
if($window.FindName('DlssRuntimeProfile').Items.Count -ne 1 -or $window.FindName('DlssRuntimeProfile').SelectedValue -ne 'nvidia-310.9.16'){throw 'The per-game DLSS SR/RR selector must offer only the current verified NVIDIA release.'}
if(-not($window.FindName('InstallAllFx') -is [Windows.Controls.CheckBox])){throw 'Install all FX must be a component-selection checkbox.'}
if($window.MinHeight -lt 930){throw 'Manager minimum height no longer keeps the main launcher layout stable.'}
foreach($pageName in @('SettingsPage','TroubleshootingPage','KeybindsPage')){if($window.FindName($pageName).VerticalScrollBarVisibility -ne [Windows.Controls.ScrollBarVisibility]::Disabled){throw "Fixed-height launcher page can still scroll: $pageName"}}
if($window.FindName('HomePage').VerticalScrollBarVisibility -ne [Windows.Controls.ScrollBarVisibility]::Auto){throw 'The expanded Home page must remain reachable on scaled or shorter displays.'}
if($window.FindName('SetupPage').VerticalScrollBarVisibility -ne [Windows.Controls.ScrollBarVisibility]::Auto){throw 'Setup actions must remain reachable on short or scaled displays.'}
if($window.FindName('LibraryPage').VerticalScrollBarVisibility -ne [Windows.Controls.ScrollBarVisibility]::Auto){throw 'The game library must keep its continuous scroll bar.'}
if($window.FindName('ComponentsPage').VerticalScrollBarVisibility -ne [Windows.Controls.ScrollBarVisibility]::Auto){throw 'The components page should show a scrollbar only when expanded content needs scrolling.'}
$comboScroll=$xml.OuterXml.Contains('MaxHeight="280" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"')
if(-not $comboScroll){throw 'Scrollable dropdown content must show its scrollbar.'}
$searchResults=$window.FindName('ManagerSearchResults')
if($searchResults.GetValue([Windows.Controls.ScrollViewer]::VerticalScrollBarVisibilityProperty) -ne [Windows.Controls.ScrollBarVisibility]::Auto){throw 'Scrollable search results must show their scrollbar.'}
$libraryPanel=$xml.OuterXml
if($libraryPanel -notmatch '<UniformGrid Columns="3"') {throw 'Game library must use a three-column grid.'}
$window.FindName('Intro').Visibility='Collapsed'
$activeNav=$window.FindName($Page+'Nav');if($activeNav){$activeNav.Background=$window.FindResource('NavPurple')}
$window.FindName('LibraryGames').ItemsSource=@(
 [pscustomobject]@{Name='MSFS 2024 - UI fixture';Launcher='Fixture only';State='Installed files; activity unconfirmed';InstallFolder='Fixture path';ActionLabel='Launch game'},
 [pscustomobject]@{Name='MSFS 2020 - UI fixture';Launcher='Fixture only';State='Not installed';InstallFolder='Fixture path';ActionLabel='Set up'},
 [pscustomobject]@{Name='X-Plane 12 - UI fixture';Launcher='Fixture only';State='Experimental installation';InstallFolder='Fixture path';ActionLabel='Launch game'})
foreach($name in @('Home','Library','Components','Setup','Settings','Troubleshooting','Keybinds','Search')){$window.FindName($name+'Page').Visibility=if($name -eq $Page){'Visible'}else{'Collapsed'}}
$headerTitles=@{Home='Home';Library='Library';Setup='Setup';Components='Components';Keybinds='Keybinds';Settings='Settings';Troubleshooting='Troubleshooting';Search='Search'}
$headerSubtitles=@{Home='Manage OptiShade across your games from one place.';Library='Find, install and manage OptiShade for your games.';Setup='Install or repair OptiShade for the selected game.';Components='Choose and update the components installed for this game.';Keybinds='Set shortcuts for the manager and in-game tools.';Settings='Customize OptiShade and manage app preferences.';Troubleshooting='Diagnose issues and collect a report for a selected game.';Search='Find a setting or tool in OptiShade.'}
$window.FindName('HeaderBuildType').Text=$headerTitles[$Page];$window.FindName('HeaderSubtitle').Text=$headerSubtitles[$Page]
if($ShowUpdateAvailable){$window.FindName('HeaderVersionLight').Fill=[Windows.Media.BrushConverter]::new().ConvertFromString('#FF9E42');$window.FindName('HeaderVersionState').Text='Update available';$window.FindName('HeaderVersionState').Visibility='Visible';$window.FindName('HeaderUpdateAvailable').Visibility='Visible'}
$fixtureGames=@($window.FindName('LibraryGames').ItemsSource)
foreach($game in $fixtureGames){$game | Add-Member Thumbnail $null;$game | Add-Member DisplayName ($game.Name -replace ' - UI fixture','')}
$window.FindName('LibraryGames').ItemsSource=$null;$window.FindName('LibraryGames').ItemsSource=$fixtureGames
$window.FindName('LibraryPageStatus').Text='3 detected games - scroll to see all'
$componentStart=$xml.OuterXml.IndexOf('x:Name="ComponentsPage"');$componentEnd=$xml.OuterXml.IndexOf('</ScrollViewer>',$componentStart);$componentXaml=$xml.OuterXml.Substring($componentStart,$componentEnd-$componentStart)
if(([regex]::Matches($componentXaml,'<ProgressBar ')).Count -ne 1 -or $componentXaml -notmatch 'x:Name="ComponentProgress"'){throw 'Components must use only the Download queue progress bar.'}
if($ShowComponentOptions){$window.FindName('ComponentOptions').IsExpanded=$true;$window.FindName('RenderingComponentOptions').IsExpanded=$true;$window.FindName('CompatibilityOptions').IsExpanded=$true}
$window.FindName('SelectedIcon').Source=$null
$window.FindName('MsfsCopies').ItemsSource=$fixtureGames;$window.FindName('MsfsCopies').SelectedIndex=0
$componentPicker=$window.FindName('ComponentsGame');$componentPicker.ItemsSource=$fixtureGames;$componentPicker.SelectedIndex=0
if($componentPicker.SelectedItem.Name -ne $fixtureGames[0].Name){throw 'The components game selector did not retain the chosen game.'}
$window.FindName('ComponentSummary').Text="Installed components: 4 / 6`nAvailable disk space: 146.6 GB"
$window.FindName('GamePath').Text='UI fixture only - no installation selected'
if($ShowXPlaneRoute){$window.FindName('XPlaneRoutePanel').Visibility='Visible'}
if($Screenshot){
 $layout=$window.FindName('ManagerLayout');$scale=[Math]::Min(1.0,[Math]::Min(($Width-2)/1342.0,($Height-2)/983.0));$layout.LayoutTransform=[Windows.Media.ScaleTransform]::new($scale,$scale);$layout.Width=($Width-2)/$scale;$layout.Height=($Height-2)/$scale
 $surface=$window.Content
 $surface.Measure([Windows.Size]::new($Width,$Height));$surface.Arrange([Windows.Rect]::new(0,0,$Width,$Height));$surface.UpdateLayout()
 if($Page -eq 'Components' -and -not $ShowComponentOptions -and $window.FindName('ComponentsPage').ScrollableHeight -gt 1){throw "The default Components layout still overflows by $($window.FindName('ComponentsPage').ScrollableHeight) pixels."}
 $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new($Width,$Height,96,96,[Windows.Media.PixelFormats]::Pbgra32)
 $bitmap.Render($surface);$encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
 $stream=[IO.File]::Create($Screenshot);try{$encoder.Save($stream)}finally{$stream.Dispose()}
}
$window.Close()
"Desktop XAML loaded; $($names.Count) literal production bindings checked. Fixture rendering only; no game launched or installation modified."
