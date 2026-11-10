$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$library=Join-Path $root 'Beta/installer/library.ps1'
. $library
$source=Join-Path $root 'Beta/installer/manager.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
$function=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'AddPopupText'},$true)
if(-not $function){throw 'The production popup text helper was not found.'}
. ([scriptblock]::Create($function.Extent.Text))
$popup=[pscustomobject]@{Body=(New-Object Windows.Controls.StackPanel)}
$normal=AddPopupText $popup 'Settings backup details.' 13
$invalid=AddPopupText $popup 'Settings backup details.' 's'
if($normal.FontSize -ne 13 -or $invalid.FontSize -ne 14 -or $popup.Body.Children.Count -ne 2){throw 'Popup text rejected a non-numeric optional font size instead of using its safe default.'}
$manager=Get-Content $source -Raw -Encoding UTF8
$compatStart=$manager.IndexOf('function ShowCompatibilityPopup{')
$compatEnd=$manager.IndexOf('$form.FindName(''OpenTroubleshooter'').Add_Click')
if($compatStart -lt 0 -or $compatEnd -le $compatStart){throw 'Could not locate the compatibility popup source.'}
$compatibility=$manager.Substring($compatStart,$compatEnd-$compatStart)
if($compatibility -notmatch '\$reportBox=\$report;\$gamePicker=\$picker' -or $compatibility -notmatch '\$reportBox\.SetCurrentValue\(\[Windows\.Controls\.TextBox\]::TextProperty,\$Text\)' -or $compatibility -match '\$state\.Report\.Text='){throw 'Compatibility popup event handlers must update the captured TextBox through its typed Text dependency property.'}
$reportBox=New-Object Windows.Controls.TextBox
$setReport={param([string]$Text) $reportBox.SetCurrentValue([Windows.Controls.TextBox]::TextProperty,$Text)}.GetNewClosure()
&$setReport 'Compatibility evidence test.'
if($reportBox.Text -ne 'Compatibility evidence test.'){throw 'The compatibility report closure did not update its captured TextBox.'}
# Exercise the actual compatibility popup and its WPF event closures with a
# detected-game fixture. The scanner deliberately fails so the error-report
# path is verified without touching a game or launching an external tool.
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
[xml]$xaml=Get-Content (Join-Path (Split-Path $source -Parent) 'manager.xaml') -Raw -Encoding UTF8
$form=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xaml))
# Create the owner off-screen, transparent, and without a taskbar button so WPF
# permits production Owner wiring without flashing a window on the desktop.
$form.WindowStartupLocation='Manual';$form.Left=-32000;$form.Top=-32000;$form.Width=1;$form.Height=1;$form.Opacity=0;$form.ShowInTaskbar=$false;$form.ShowActivated=$false;$form.Show();$form.Hide()
$path=$form.FindName('GamePath');$status=$form.FindName('Status');$store=Join-Path $env:TEMP ('optishade-popup-'+[guid]::NewGuid().ToString('N'));$script:removedGames=@{};$script:favoriteGames=@{};$script:libraryPreferences=@{InstalledFirst=$true;FavoritesOnly=$false}
$fixtureGame=Join-Path $env:TEMP ('optishade-game-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($fixtureGame)
$script:libraryGames=@([pscustomobject]@{DisplayName='Popup fixture game';StoreDisplay='Fixture store';Folder=$fixtureGame;InstallFolder=$fixtureGame;Name='Popup fixture game';Launcher='Fixture';Thumbnail=$null})
$script:lastPopup=$null
$functionNames=@('NewManagerPopup','NewPopupComboBox','AddPopupText','AddPopupButton','GetDetectedStoreDisplay','GetCachedManagerGameStatus','SetSelectedFusionGame','ClearComponentsTargetSummary','ShowCompatibilityPopup','ShowSettingsBackupPopup')
foreach($name in $functionNames){$node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true);if(-not $node){throw "Production helper $name was not found."};. ([scriptblock]::Create($node.Extent.Text))}
function ShowManagerPopup($Popup){
 $script:lastPopup=$Popup;$timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(200);$target=$Popup
 $target.Window.WindowStartupLocation='Manual';$target.Window.Left=-32000;$target.Window.Top=-32000;$target.Window.Width=1;$target.Window.Height=1;$target.Window.Opacity=0;$target.Window.ShowInTaskbar=$false;$target.Window.ShowActivated=$false
 $timer.Add_Tick({$timer.Stop();if($target.Window.Title -eq 'Check game compatibility'){$button=@($target.Footer.Children|Where-Object {$_ -is [Windows.Controls.Button] -and $_.Content -eq 'Check selected game'})[0];if($button){$button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}};$target.Window.Close()}.GetNewClosure())
 $timer.Start();try{[void]$Popup.Window.ShowDialog()}finally{$timer.Stop()}
}function ManifestPath($StateRoot,$Game){return (Join-Path $StateRoot 'missing-fixture-manifest.json')}
function FindFusionExecutable($Folder,$Launcher,$Name){return @([pscustomobject]@{Path=(Join-Path $Folder 'Fixture.exe')})}
function global:GetFusionGameTargetFolder($Game){return [string]$Game.Folder}
function SetSelectedFusionGame($Game){return $true}
function ReadOptiShadeState($Manifest){return [pscustomobject]@{LaunchExe=''}}
function ChooseGameExe{return $null}
function FormatFusionCompatibility($Plan){return 'fixture compatibility report'}
function OpenDiagnosticTool{}
function CheckGameCompatibility($Exe){throw 'Injected compatibility scan failure.'}
function WriteInstallerLog($Message){}
function GetManagedInstallations{return @([pscustomobject]@{Title='Settings fixture game';Game=$fixtureGame;Manifest=(Join-Path $store 'Games/fixture/manifest.json');State='Installed';Version='fixture';Components=@();Display='Settings fixture game'})}
ShowCompatibilityPopup
$popup=$script:lastPopup
if(-not $popup -or $popup.Window.Title -ne 'Check game compatibility'){throw 'The production compatibility popup did not open.'}
$reportControl=@($popup.Body.Children|Where-Object {$_ -is [Windows.Controls.TextBox]})[0]
if(-not $reportControl -or $reportControl.Text -ne 'Compatibility check could not complete: Injected compatibility scan failure.'){throw "The scan error was not rendered after the real modal callback: $($reportControl.Text)"}
ShowSettingsBackupPopup
if(-not $script:lastPopup -or $script:lastPopup.Window.Title -ne 'Back up and reset settings' -or $script:lastPopup.Window.SizeToContent -ne [Windows.SizeToContent]::Manual){throw 'The production settings backup popup did not initialize with its explicit window size.'}

Remove-Item -LiteralPath $fixtureGame -Force -ErrorAction SilentlyContinue
'Production compatibility popup preview and scan-error callbacks passed.'
'Popup helper and compatibility report reference checks passed.'
