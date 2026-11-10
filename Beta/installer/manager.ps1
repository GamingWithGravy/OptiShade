param([string]$Payload,[string]$Installer,[switch]$StartInTray,[switch]$UninstallMode)

$ErrorActionPreference='Stop'

# A modular manager deliberately has no embedded game payload. Its verified
# package set is composed into a session-only installer tree on demand.
$script:modularDistribution= -not (Test-Path -LiteralPath (Join-Path $Payload 'files.json') -PathType Leaf)
$script:componentPayloadIds=@()
$script:componentPackageReleases=@()
$script:onlineComponentVersions=@{}
$script:onlineComponentChannelFailures=@()

Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,System.Xaml
# Global anti-cheat consent is the first interactive gate. Do not initialize
# hardware discovery, show patch notes, or perform game/install/update work until accepted.
$store=if($env:OPTISHADE_STORE){$env:OPTISHADE_STORE}else{Join-Path $env:LOCALAPPDATA 'OptiShade'};$env:OPTISHADE_STORE=$store
. "$PSScriptRoot/consent.ps1"
if(-not $UninstallMode -and -not(TestOptiShadeAntiCheatAccepted)){
 try{if(-not(ConfirmOptiShadeAntiCheatAgreement $null)){return}}catch{throw "OptiShade requires anti-cheat risk acceptance before startup: $($_.Exception.Message)"}
}
. "$PSScriptRoot/manager-lifetime.ps1"
. "$PSScriptRoot/manager-status.ps1"
InitializeOptiShadeManagerLifetime
try{
. "$PSScriptRoot/ownership.ps1"
. "$PSScriptRoot/effects.ps1"
. "$PSScriptRoot/nvidia.ps1"
. "$PSScriptRoot/neural-download.ps1"
. "$PSScriptRoot/library.ps1"
. "$PSScriptRoot/dialogs.ps1"
. "$PSScriptRoot/operation-progress-store.ps1"
. "$PSScriptRoot/components.ps1"
. "$PSScriptRoot/component-packages.ps1"
. "$PSScriptRoot/glass-cockpit-update.ps1"
. "$PSScriptRoot/atmosphere-mod.ps1"
. "$PSScriptRoot/compatibility.ps1"
. "$PSScriptRoot/updates.ps1"
. "$PSScriptRoot/recovery.ps1"
. "$PSScriptRoot/menu-settings.ps1"
. "$PSScriptRoot/snapshot-library.ps1"
. "$PSScriptRoot/diagnostics.ps1"
. "$PSScriptRoot/release-notes.ps1"
. "$PSScriptRoot/developer-message.ps1"
. "$PSScriptRoot/support.ps1"
. "$PSScriptRoot/mfg.ps1"
. "$PSScriptRoot/runtime-control.ps1"
. "$PSScriptRoot/auto-compatibility.ps1"
. "$PSScriptRoot/xplane-compatibility.ps1"
InitializeOptiShadeRuntimeControl
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
if(-not ('OptiShadeTrayColors' -as [type])){Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System.Drawing;
using System.Windows.Forms;
// OptiShade colours for the tray icon's menu instead of the default Windows look.
public class OptiShadeTrayColors : ProfessionalColorTable {
 static readonly Color Surface=Color.FromArgb(23,20,32), Hover=Color.FromArgb(90,43,168), Edge=Color.FromArgb(94,62,134);
 public override Color ToolStripDropDownBackground{get{return Surface;}}
 public override Color MenuBorder{get{return Edge;}}
 public override Color MenuItemBorder{get{return Hover;}}
 public override Color MenuItemSelected{get{return Hover;}}
 public override Color MenuItemSelectedGradientBegin{get{return Hover;}}
 public override Color MenuItemSelectedGradientEnd{get{return Hover;}}
 public override Color ImageMarginGradientBegin{get{return Surface;}}
 public override Color ImageMarginGradientMiddle{get{return Surface;}}
 public override Color ImageMarginGradientEnd{get{return Surface;}}
 public override Color SeparatorDark{get{return Edge;}}
 public override Color SeparatorLight{get{return Surface;}}
}
'@}
Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Windows;
using System.Windows.Controls;
public class FusionGameCard { public string ProtectionStatus {get;set;} public string ProtectionDetail {get;set;} public string ProtectionColor {get;set;} public string State {get;set;} public string Name {get;set;} public string DisplayName {get;set;} public string Folder {get;set;} public string Launcher {get;set;} public string StoreDisplay {get;set;} public string FavoriteKey {get;set;} public string FavoriteGlyph {get;set;} public string FavoriteTip {get;set;} public bool IsFavorite {get;set;} public bool Installed {get;set;} public string ActionLabel {get;set;} public string InstallFolder {get;set;} public string Label {get;set;} public string StatusColor {get;set;} public string Artwork {get;set;} public string Description {get;set;} public string UpdateTarget {get;set;} public string[] ComponentUpdateIds {get;set;} public System.Windows.Visibility UpdateButtonVisibility {get;set;} public System.Windows.Media.ImageSource Thumbnail {get;set;} }
public sealed class FusionFocusCaptureGuard {
 private readonly Window _window;
 private readonly IDictionary _state;
 private readonly Button _menu;
 private readonly Button _hotSwap;
 private readonly Button _snapshot;
 private readonly TextBlock _hint;
 private readonly IDictionary _featureButtons;
 public FusionFocusCaptureGuard(Window window, IDictionary state, Button menu, Button hotSwap, Button snapshot, TextBlock hint, IDictionary featureButtons) {
  _window=window; _state=state; _menu=menu; _hotSwap=hotSwap; _snapshot=snapshot; _hint=hint; _featureButtons=featureButtons;
  _window.Deactivated += OnDeactivated;
 }
 private bool IsSet(string key) { object value=_state[key]; return value!=null && Convert.ToBoolean(value); }
 private void OnDeactivated(object sender, EventArgs e) {
  bool menu=IsSet("MenuKey"), hotSwap=IsSet("HotSwap"), snapshot=IsSet("Snapshot");
  _state["MenuKey"]=false; _state["HotSwap"]=false; _state["Snapshot"]=false;
  if(menu && _menu!=null) _menu.Content="Change";
  if(hotSwap && _hotSwap!=null) _hotSwap.Content="Change";
  if(snapshot && _snapshot!=null) _snapshot.Content="Change";
  object featureValue=_state["Feature"];
  string feature=featureValue==null?"":Convert.ToString(featureValue);
  if(!String.IsNullOrEmpty(feature)) {
   _state["Feature"]="";
   Button button=_featureButtons[feature] as Button;
   if(button!=null) button.Content="Change";
  }
  if((menu || hotSwap || snapshot || !String.IsNullOrEmpty(feature)) && _hint!=null) _hint.Text="Key capture cancelled when OptiShade lost focus.";
 }
}
'@ -ReferencedAssemblies @([Windows.Media.ImageSource].Assembly.Location,[Windows.Threading.DispatcherObject].Assembly.Location,[Windows.Window].Assembly.Location,[Windows.Controls.Button].Assembly.Location,[System.Xaml.XamlReader].Assembly.Location)
$script:captureState=@{MenuKey=$false;HotSwap=$false;Snapshot=$false;Feature=''}
$script:diagnosticsDir=Join-Path $store 'Diagnostics';$env:OPTISHADE_DIAGNOSTICS_DIR=$script:diagnosticsDir
$script:libraryPreferencePath=Join-Path $store 'library-preferences.json'
$script:libraryPreferences=@{InstalledFirst=$true;FavoritesOnly=$false}
$script:favoriteGames=@{};$script:removedGames=@{}
try{
 if(Test-Path -LiteralPath $script:libraryPreferencePath){$saved=Get-Content -LiteralPath $script:libraryPreferencePath -Raw -Encoding UTF8|ConvertFrom-Json;if($saved.InstalledFirst -is [bool]){$script:libraryPreferences.InstalledFirst=$saved.InstalledFirst};if($saved.FavoritesOnly -is [bool]){$script:libraryPreferences.FavoritesOnly=$saved.FavoritesOnly};foreach($key in @($saved.Favorites)){if($key){$script:favoriteGames[[string]$key]=$true}};foreach($key in @($saved.RemovedGames)){if($key){$script:removedGames[[string]$key.ToLowerInvariant()]=$true}}}
}catch{$script:favoriteGames=@{};$script:removedGames=@{}}
function SaveLibraryPreferences{
 try{[void][IO.Directory]::CreateDirectory($store);$state=@{InstalledFirst=[bool]$script:libraryPreferences.InstalledFirst;FavoritesOnly=[bool]$script:libraryPreferences.FavoritesOnly;Favorites=@($script:favoriteGames.Keys);RemovedGames=@($script:removedGames.Keys)};WriteState $state $script:libraryPreferencePath}catch{$status.Text='Could not save library preferences: '+$_.Exception.Message}
}
InitializeOptiShadeUpdateChannel -InstalledChannel stable
$script:cachePath=Join-Path $store 'msfs-2020-2024-cache.json'
[xml]$xaml=Get-Content "$PSScriptRoot/manager.xaml" -Raw -Encoding UTF8
$form=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
# Keep the reference composition usable on smaller windows and Windows display scales.
function ResizeManagerLayout {
 $w=$form.ActualWidth-2;$h=$form.ActualHeight-2
 if($w -le 0 -or $h -le 0){return}
 $scale=[Math]::Min(1.0,[Math]::Min($w/1342.0,$h/983.0))
 $layout=$form.FindName('ManagerLayout')
 $layout.LayoutTransform=[Windows.Media.ScaleTransform]::new($scale,$scale)
 $layout.Width=$w/$scale;$layout.Height=$h/$scale
}
 $form.Add_SizeChanged({ResizeManagerLayout})
$form.Add_Loaded({ResizeManagerLayout})
# Manager-only presentation settings; renderer and installation configuration remain independent.
$script:managerPreferences=@{Theme='Dark';Accent=0;Remember=$true;Page='Home';CloseAction='Ask'}
$script:preferencesReady=$false
$script:managerPreferencesPath=Join-Path $store 'manager-interface.json'
try{
 if(Test-Path -LiteralPath $script:managerPreferencesPath){
  $v=Get-Content -LiteralPath $script:managerPreferencesPath -Raw|ConvertFrom-Json
  if($v.Theme -in @('Dark','Light','System')){$script:managerPreferences.Theme=[string]$v.Theme}
  if($v.Accent -is [int] -and $v.Accent -ge 0 -and $v.Accent -lt 8){$script:managerPreferences.Accent=[int]$v.Accent}
  if($v.Remember -is [bool]){$script:managerPreferences.Remember=$v.Remember}
  if($v.CloseAction -in @('Ask','Tray','Exit')){$script:managerPreferences.CloseAction=[string]$v.CloseAction}
  if($v.Page -in @('Home','Setup','Components','Updates','Keybinds','Troubleshooting','Settings','Nvidia')){$script:managerPreferences.Page=[string]$v.Page}
 }
}catch{}
function SaveManagerPreferences{
 if(-not $script:preferencesReady){return}
 try{[void][IO.Directory]::CreateDirectory($store);WriteState $script:managerPreferences $script:managerPreferencesPath}catch{$status.Text='Could not save manager appearance: '+$_.Exception.Message}
}
function ApplyManagerAppearance{
 $light=$script:managerPreferences.Theme -eq 'Light'
 if($script:managerPreferences.Theme -eq 'System'){try{$light=(Get-ItemPropertyValue 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Themes/Personalize' AppsUseLightTheme -ErrorAction Stop) -eq 1}catch{$light=$false}}
 $col=if($light){@('#251A35','#59486E','#EEE8F7','#F5F1FA')}else{@('#F3EFFB','#C0AEDF','#211D30','#100F1D')}
 $keys=@('TextPrimary','TextMuted','ControlSurface','BaseSurface')
 for($i=0;$i -lt 4;$i++){$form.Resources[$keys[$i]]=[Windows.Media.BrushConverter]::new().ConvertFromString($col[$i])}
 foreach($key in @('WindowGlass','CardGlass')){
  $brush=[Windows.Media.LinearGradientBrush]::new();$brush.StartPoint=[Windows.Point]::new(0,0);$brush.EndPoint=[Windows.Point]::new(1,1)
  $cs=if($light){@('#FAF7FF','#E9E2F3')}elseif($key -eq 'CardGlass'){@('#241D34','#10111B')}else{@('#14121F','#0D0E17')}
  $brush.GradientStops.Add([Windows.Media.GradientStop]::new([Windows.Media.ColorConverter]::ConvertFromString($cs[0]),0));$brush.GradientStops.Add([Windows.Media.GradientStop]::new([Windows.Media.ColorConverter]::ConvertFromString($cs[1]),1));$form.Resources[$key]=$brush
 }
 for($i=0;$i -lt 8;$i++){$form.FindName('Accent'+$i).BorderBrush=if($i -eq $script:managerPreferences.Accent){'#B06CFF'}else{'Transparent'}}
 $accent=@('#842BFF','#2477FF','#24BEDB','#23D284','#FFB933','#EA408B','#FF953B','#F04462')[$script:managerPreferences.Accent]
 $c=[Windows.Media.ColorConverter]::ConvertFromString($accent);$dark=[Windows.Media.Color]::FromRgb([byte]($c.R*.58),[byte]($c.G*.58),[byte]($c.B*.72))
 $form.Resources['ActionPurple']=[Windows.Media.LinearGradientBrush]::new($c,$dark,45)
 $navStart=[Windows.Media.Color]::FromRgb([byte]($c.R*.65),[byte]($c.G*.48),[byte]($c.B*.60))
 $navEnd=[Windows.Media.Color]::FromRgb([byte]($c.R*.36),[byte]($c.G*.26),[byte]($c.B*.40))
 $form.Resources['NavPurple']=[Windows.Media.LinearGradientBrush]::new($navStart,$navEnd,0)
 if($script:preferencesReady){ShowPage $script:managerReturnPage}
}
$form.FindName('Theme'+$script:managerPreferences.Theme).IsChecked=$true
foreach($theme in @('Dark','Light','System')){$form.FindName('Theme'+$theme).Tag=$theme;$form.FindName('Theme'+$theme).Add_Checked({param($sender,$eventArgs) $script:managerPreferences.Theme=[string]$sender.Tag;ApplyManagerAppearance;SaveManagerPreferences})}
for($i=0;$i -lt 8;$i++){$form.FindName('Accent'+$i).Tag=$i;$form.FindName('Accent'+$i).Add_Click({param($sender,$eventArgs) $script:managerPreferences.Accent=[int]$sender.Tag;ApplyManagerAppearance;SaveManagerPreferences})}
$script:startupRegistry='HKCU:/Software/Microsoft/Windows/CurrentVersion/Run'
function SyncCloseWindowActionSetting{
 $box=$form.FindName('CloseWindowAction');if(-not $box){return}
 foreach($item in $box.Items){if([string]$item.Tag -eq [string]$script:managerPreferences.CloseAction){$script:syncingCloseAction=$true;$box.SelectedItem=$item;$script:syncingCloseAction=$false}}
}
SyncCloseWindowActionSetting
$form.FindName('CloseWindowAction').Add_SelectionChanged({if($script:syncingCloseAction){return};$item=$form.FindName('CloseWindowAction').SelectedItem;if($item){$script:managerPreferences.CloseAction=[string]$item.Tag;SaveManagerPreferences}})
$existingStartup=Get-ItemProperty -LiteralPath $script:startupRegistry -Name OptiShadeManager -ErrorAction SilentlyContinue
$form.FindName('LaunchWithWindows').IsChecked=[bool]($existingStartup -and $existingStartup.OptiShadeManager)
if($existingStartup -and $existingStartup.OptiShadeManager -and [string]$existingStartup.OptiShadeManager -notmatch '(?i)--tray' -and (Test-Path -LiteralPath $Installer -PathType Leaf)){
 try{[void](New-ItemProperty -LiteralPath $script:startupRegistry -Name OptiShadeManager -Value ('"'+$Installer+'" --tray') -PropertyType String -Force)}catch{WriteInstallerLog ('Could not migrate the existing Windows startup entry to tray mode: '+$_.Exception.Message)}
}
$form.FindName('LaunchWithWindows').Add_Click({
 try{
  if($form.FindName('LaunchWithWindows').IsChecked){
   if(-not (Test-Path -LiteralPath $Installer -PathType Leaf)){throw 'Keep the manager EXE in a permanent location before enabling startup.'}
   if(-not (Test-Path -LiteralPath $script:startupRegistry)){[void](New-Item -Path $script:startupRegistry)};[void](New-ItemProperty -LiteralPath $script:startupRegistry -Name OptiShadeManager -Value ('"'+$Installer+'" --tray') -PropertyType String -Force)
  }else{Remove-ItemProperty -LiteralPath $script:startupRegistry -Name OptiShadeManager -ErrorAction SilentlyContinue}
 }catch{$form.FindName('LaunchWithWindows').IsChecked=-not $form.FindName('LaunchWithWindows').IsChecked;$status.Text=$_.Exception.Message}
})
ApplyManagerAppearance

# Live developer message: the last good copy shows at once, then the newest copy
# from GitHub replaces it. Checked at startup and every 30 minutes while open.
function ApplyOptiShadeDeveloperMessage($Message){
 if(-not $Message){return}
 if($Message.Title){$form.FindName('HomeDeveloperMessage').Text=$Message.Title}
 $form.FindName('HomeDeveloperBody').Text=$Message.Body
 $updated=$form.FindName('HomeDeveloperUpdated')
 if($Message.Updated){$updated.Text='Updated '+$Message.Updated;$updated.Visibility='Visible'}else{$updated.Visibility='Collapsed'}
}
ApplyOptiShadeDeveloperMessage (ReadOptiShadeCachedDeveloperMessage $store)
$script:developerMessageDownload=$null;$script:developerMessageCheckedUtc=[DateTime]::MinValue;$script:developerMessageLastError=''
$script:developerMessageTimer=[Windows.Threading.DispatcherTimer]::new();$script:developerMessageTimer.Interval=[TimeSpan]::FromSeconds(1)
RegisterOptiShadeManagerTimer $script:developerMessageTimer {
 if($script:developerMessageDownload){
  if(-not $script:developerMessageDownload.Task.IsCompleted){return}
  try{$json=CompleteOptiShadeDeveloperMessageDownload $script:developerMessageDownload;ApplyOptiShadeDeveloperMessage (ConvertFromOptiShadeDeveloperMessage $json);SaveOptiShadeDeveloperMessage $store $json;$script:developerMessageLastError=''}
  catch{$text=$_.Exception.Message;if($text -ne $script:developerMessageLastError){$script:developerMessageLastError=$text;WriteInstallerLog ('Developer message not updated: '+$text)}}
  finally{$script:developerMessageDownload=$null}
  return
 }
 if(([DateTime]::UtcNow-$script:developerMessageCheckedUtc).TotalMinutes -lt 30){return}
 $script:developerMessageCheckedUtc=[DateTime]::UtcNow
 try{$script:developerMessageDownload=StartOptiShadeDeveloperMessageDownload}catch{WriteInstallerLog ('Developer message check could not start: '+$_.Exception.Message)}
}
$script:developerMessageTimer.Start()

# A launcher self-update that failed reopens this launcher unchanged. Explain it
# once, in OptiShade's own dialog (or a tray notification when started hidden).
$script:launcherUpdateErrorPath=Join-Path $store 'Launcher-update-error.txt';$script:launcherUpdateError=''
try{if(Test-Path -LiteralPath $script:launcherUpdateErrorPath -PathType Leaf){$script:launcherUpdateError=([IO.File]::ReadAllText($script:launcherUpdateErrorPath)).Trim();Move-Item -LiteralPath $script:launcherUpdateErrorPath -Destination (Join-Path $store 'Launcher-update-error.shown.txt') -Force}}catch{}
if($script:launcherUpdateError){
 $script:launcherUpdateNoticeTimer=[Windows.Threading.DispatcherTimer]::new();$script:launcherUpdateNoticeTimer.Interval=[TimeSpan]::FromSeconds(2)
 RegisterOptiShadeManagerTimer $script:launcherUpdateNoticeTimer {
  $script:launcherUpdateNoticeTimer.Stop()
  $text='The launcher update was not installed, so OptiShade is still on its previous version. Nothing was changed. Use Check for updates to try again.'
  WriteInstallerLog ('Launcher self-update failed: '+$script:launcherUpdateError)
  if($form.IsVisible){[void](ShowOptiShadeDialog ($form) ($text+"`n`nDetails: "+$script:launcherUpdateError) ('Launcher update not installed') ('OK') ('Warning'))}
  elseif($script:trayIcon){$script:trayIcon.BalloonTipTitle='Launcher update not installed';$script:trayIcon.BalloonTipText=$text;$script:trayIcon.BalloonTipIcon=[Windows.Forms.ToolTipIcon]::Warning;$script:trayIcon.ShowBalloonTip(7000)}
 }
 $script:launcherUpdateNoticeTimer.Start()
}

$presentation=GetOptiShadeManagerPresentation $Payload ($env:OPTISHADE_PORTABLE -eq '1') $Installer
$displayVersion=$presentation.Version
$form.Title=$presentation.Title
$form.FindName('ManagerVersion').Text=$presentation.Footer
$form.FindName('HeaderVersion').Text=($presentation.Version -replace '-beta\.1',' beta')
$form.FindName('HeaderVersion').ToolTip=$presentation.Badge+' / '+$presentation.Test+'; click to check for an update.'
# Sidebar availability copy is kept compact beside the brand.

$form.FindName('HomeStableBuild').Text=$presentation.Version+' · Stable release'
$form.FindName('HeaderBuildType').Text='Home'
$form.FindName('IntroVersion').Text=$presentation.Intro
$appFolder=Split-Path (FullPath $Installer) -Parent
$form.FindName('ManagerVersion').ToolTip=$presentation.Badge+' / '+$presentation.Test+"`nApp: "+$appFolder+"`nData: "+$store+"`nThis is the manager build; installed game files may have a different version until updated."
$form.FindName('AppLocation').Text='OptiShade app: '+$appFolder+"`n"+$presentation.Package+' data: '+$store
$form.FindName('GameLocationHint').Text=if($env:OPTISHADE_PORTABLE -eq '1'){'Select the actual game installation below. The portable app can be on another drive. Keep portable.txt and the Data folder beside its EXE when moving it; Data contains your installation records and recovery backups.'}else{'Select the actual game installation below, not the OptiShade app folder. The app and game can be on different drives.'}
$path=$form.FindName('GamePath');$status=$form.FindName('Status')
function SetHeaderVersionState([ValidateSet('Checking','Current','Available','Unavailable','Error')][string]$State){
 $light=$form.FindName('HeaderVersionLight');$label=$form.FindName('HeaderVersionState');$update=$form.FindName('HeaderUpdateAvailable')
 switch($State){
  'Checking' {$light.Fill=[Windows.Media.BrushConverter]::new().ConvertFromString('#A99ABF');$label.Text='Checking';$label.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#C0AEDF');$label.Visibility='Visible';$update.Visibility='Collapsed'}
  'Current' {$light.Fill=[Windows.Media.BrushConverter]::new().ConvertFromString('#56D9A0');$label.Text='Up to date';$label.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#56D9A0');$label.Visibility='Visible';$update.Visibility='Collapsed'}
  'Available' {$light.Fill=[Windows.Media.BrushConverter]::new().ConvertFromString('#FF9E42');$label.Text='Update available';$label.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#FFBE83');$label.Visibility='Visible';$update.Content='OptiShade update available';$update.Visibility='Visible'}
  'Unavailable' {$light.Fill=[Windows.Media.BrushConverter]::new().ConvertFromString('#A99ABF');$label.Text='Updates unavailable';$label.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#C0AEDF');$label.Visibility='Visible';$update.Visibility='Collapsed'}
  'Error' {$light.Fill=[Windows.Media.BrushConverter]::new().ConvertFromString('#A99ABF');$label.Text='Check failed';$label.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#C0AEDF');$label.Visibility='Visible';$update.Visibility='Collapsed'}
 }
}
SetHeaderVersionState 'Checking'
function RefreshUpdateChannelLabel {
 $channel=GetOptiShadeUpdateChannel
 $form.FindName('BetaUpdates').IsChecked=($channel -eq 'beta')
 $form.FindName('StableChannel').IsChecked=($channel -ne 'beta')
 $form.FindName('BetaChannel').IsChecked=($channel -eq 'beta')
 $form.FindName('UpdateChannelStatus').Text='Download channel: '+$channel
}
RefreshUpdateChannelLabel
foreach($channelChoice in @('StableChannel','BetaChannel')){
 $form.FindName($channelChoice).Tag=($channelChoice -eq 'BetaChannel')
 $form.FindName($channelChoice).Add_Click({param($sender,$eventArgs)
  $form.FindName('BetaUpdates').IsChecked=[bool]$sender.Tag
  $form.FindName('BetaUpdates').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.CheckBox]::ClickEvent))
 })
}
$form.FindName('BetaUpdates').Add_Click({
 try{
  SetOptiShadeUpdateChannel ([bool]$form.FindName('BetaUpdates').IsChecked)
  $script:availableUpdate=$null;$form.FindName('UpdateAvailable').Visibility='Collapsed'
  RefreshUpdateChannelLabel
  $status.Text='Download channel saved. Select Check for updates to refresh. Nothing has been installed.'
 }catch{RefreshUpdateChannelLabel;$status.Text='Could not save the update channel. '+$_.Exception.Message}
})
$officialDiscord='https://discord.gg/sq384cjC4N'
$partnerDiscord='https://discord.gg/aWHUGeCqkz'
$form.FindName('PartnerDiscord').Add_Click({
 try{Start-Process $partnerDiscord -ErrorAction Stop}
 catch{$status.Text='Could not open your browser. Visit '+$partnerDiscord;$status.Foreground='#FFBE83'}
})
$form.FindName('PartnerDiscordSidebar').Add_Click({
 try{Start-Process $partnerDiscord -ErrorAction Stop}
 catch{$status.Text='Could not open your browser. Visit '+$partnerDiscord;$status.Foreground='#FFBE83'}
})
$form.FindName('OfficialDiscordSidebar').Add_Click({
 try{Start-Process $officialDiscord -ErrorAction Stop}
 catch{$status.Text='Could not open your browser. Visit '+$officialDiscord;$status.Foreground='#FFBE83'}
})
function OpenBuyMeACoffee{
 try{Start-Process 'https://buymeacoffee.com/GamingWithGravy' -ErrorAction Stop}
 catch{$status.Text='Could not open your browser. Visit https://buymeacoffee.com/GamingWithGravy';$status.Foreground='#FFBE83'}
}
if(Test-Path -LiteralPath (Join-Path $store 'support-hidden.txt')){$form.FindName('SupportDevelopment').Visibility='Collapsed'}
$form.FindName('SupportDevelopment').Add_Click({
 OpenBuyMeACoffee
 if(Test-Path -LiteralPath (Join-Path $store 'support-hidden.txt')){$form.FindName('SupportDevelopment').Visibility='Collapsed'}
})
$form.FindName('HomeCoffee').Add_Click({OpenBuyMeACoffee})
# Idle scan text belongs in the title tooltip; operational/error status keeps its visible footer.
[ComponentModel.DependencyPropertyDescriptor]::FromProperty([Windows.Controls.TextBlock]::TextProperty,[Windows.Controls.TextBlock]).AddValueChanged($status,[EventHandler]{
 $form.FindName('ActionStatusPanel').Visibility=if($status.Text -match '^(Ready when|Simulator detection complete|Showing shortcuts)'){'Collapsed'}else{'Visible'}
})
$buttons=@('Install','Repair','Restore','Runtime','Retry','Uninstall','Scan','Play','LibraryGames','LibraryNav','GamePath','Method','AddGame','ComponentsGame','ComponentsPlay','ComponentsInstallAll','ComponentsApply','ComponentsUninstallSelected','AddonEffectsUninstall','AddonNeuralUninstall','AddonMfgUninstall','AddonMfgStart','AddonCockpitUninstall','AddonCockpitOpenRelease','AddonProvidersUninstall','ComponentsUpdateAll','UpdatesNav','UpdatesRefresh','UpdatesVerify','UpdatesAll','HomeNav','SetupNav','SettingsNav','NvidiaNav','NvidiaGame','NvidiaBrowse','NvidiaRead','NvidiaSave','NvidiaRestore','NvidiaUseGame','KeybindsNav','ChangeMenuKey','ChangeHotSwapKey','ClearHotSwapKey','ChangeSnapshotKey','ClearSnapshotKey','ChangeNrToggleKey','ClearNrToggleKey','ChangeMfgToggleKey','ClearMfgToggleKey','ChangeMfgMultiplierUpKey','ClearMfgMultiplierUpKey','ChangeMfgMultiplierDownKey','ClearMfgMultiplierDownKey','BrowseSnapshots','ChangeSnapshotParent','CheckCompatibility','TroubleshootingNav','ResetDefaults','ResetDownloadCache','ExportLauncherLogs','ImportZip','RecoveryRepair','RecoveryRestore','CheckUpdates','HomeCheckUpdates','HomePatchNotes','RevertUpdate','BetaUpdates','SaveMenuKeys','DefaultMenuKeys','LoadMenuKeys','InstallAllFx','ImportFxIni','PrepareOlderRtx','ChooseNeuralGpu','LibraryInstalledFirst','LibraryFavoritesOnly','HeaderVersionAction','HeaderUpdateAvailable','HeaderComponentUpdateAvailable','XPlaneGraphicsRoute','SaveXPlaneRoute')|ForEach-Object {$form.FindName($_)}|Where-Object {$_}
$componentSelectors=@(@('AddonEffectsSelected','AddonNeuralSelected','AddonMfgSelected','AddonCockpitSelected','AddonProvidersSelected','AddonAtmosphereSelected')|ForEach-Object {$form.FindName($_)})
$form.Icon=[Windows.Media.Imaging.BitmapFrame]::Create([uri](Join-Path $PSScriptRoot 'OptiShade-app.ico'))
$form.FindName('BrandIcon').Source=[Windows.Media.Imaging.BitmapFrame]::Create([uri](Join-Path $PSScriptRoot 'OptiShade-icon.png'))
$form.FindName('BrandIcon').Cursor='SizeAll'
$form.FindName('BrandIcon').Add_MouseLeftButtonDown({if($_.ChangedButton -eq 'Left'){$form.DragMove()}})
$form.FindName('TitleBar').Add_MouseLeftButtonDown({if($_.ChangedButton -eq 'Left'){$form.DragMove()}})
$form.Add_PreviewMouseLeftButtonDown({
 $e=$_;$bottom=$form.FindName('TitleBar').TranslatePoint([Windows.Point]::new(0,$form.FindName('TitleBar').ActualHeight),$form).Y
 if($e.GetPosition($form).Y -gt $bottom){return}
 $node=$e.OriginalSource
 while($node -is [Windows.DependencyObject]){if($node -is [Windows.Controls.Primitives.ButtonBase]){return};if($node -isnot [Windows.Media.Visual]){break};$node=[Windows.Media.VisualTreeHelper]::GetParent($node)}
 if($e.LeftButton -eq 'Pressed'){$e.Handled=$true;$form.DragMove()}
})
$form.FindName('Close').Add_Click({if(-not $script:busy){$form.Close()}})
$form.FindName('Minimize').Add_Click({$form.WindowState='Minimized'})
$form.FindName('Maximize').Add_Click({$form.WindowState=if($form.WindowState -eq 'Maximized'){'Normal'}else{'Maximized'}})
$form.FindName('HomeCheckUpdates').Add_Click({$form.FindName('CheckUpdates').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))})
$form.FindName('HomePatchNotes').Add_Click({ShowReleaseNotes $form $store -Reopen -Payload $Payload -ManagerPath $Installer})
$form.FindName('ExportLauncherLogs').Add_Click({try{OpenDiagnosticTool -LauncherOnly}catch{$status.Text=$_.Exception.Message;$status.Foreground='#FFBE83';WriteInstallerLog ('Unified launcher diagnostics could not be opened: '+$_.Exception.Message)}})
$buttons+=@($form.FindName('StableChannel'),$form.FindName('BetaChannel'))
$script:busy=$false
$form.FindName('RevertUpdate').Add_Click({
 if($script:busy){return}
 if($env:OPTISHADE_PORTABLE -eq '1'){[void](ShowOptiShadeDialog ($form) ('Portable version changes require a separate portable folder. Keep the existing folder and Data as your recovery copy. Extract the selected version to a new folder, copy Data, and keep portable.txt beside its EXE. Update each supported game in Setup. X-Plane requires the beta manager. No game or channel setting has changed.') ('Portable version change'));return}
 try{$selected=ShowOptiShadeRevert $form;if($selected){StartManagerUpdate $selected -ReturnToStable}}
 catch{$status.Text=$_.Exception.Message;$status.Foreground='#FFBE83'}
})
$form.FindName('UpdateAvailable').Add_Click({StartManagerUpdate $script:availableUpdate})
$form.FindName('HeaderUpdateAvailable').Add_Click({if($script:availableUpdate){StartManagerUpdate $script:availableUpdate}})
function StartManagerUpdate($Update,[switch]$ReturnToStable){
 if($script:busy -or -not $Update){return}
 if($Update.Modular){
  try{StartModularManagerUpdate $Update}catch{$status.Text=$_.Exception.Message;$status.Foreground='#FFBE83';[void](ShowOptiShadeDialog $form $status.Text 'OptiShade manager update')}
  return
 }
 $installedChannel=if((GetBundledOptiShadeVersion) -match '-(?:alpha|beta|rc)'){'beta'}else{'stable'}
 $Update|Add-Member -NotePropertyName InstalledChannel -NotePropertyValue $installedChannel -Force
 $Update|Add-Member -NotePropertyName ExplicitReturnToStable -NotePropertyValue ([bool]$ReturnToStable) -Force
 try{[void](AssertOptiShadeUpdateRequest $Update $store)}catch{$status.Text=$_.Exception.Message;return}
 if($env:OPTISHADE_PORTABLE -eq '1'){
  if($Update.Rollback){
   $status.Text='Portable version change: download the selected portable ZIP into a separate folder. Keep your Data folder as a backup; installed game files are not changed automatically.'
   $releasePage=if($Update.ReleaseUrl){$Update.ReleaseUrl}else{'https://github.com/GamingWithGravy/OptiShade/releases'}
   Start-Process $releasePage
   return
  }
  [void](ShowOptiShadeDialog ($form) ('Portable update: download the new portable ZIP from the official releases page. Close OptiShade, extract it, and copy your existing Data folder into the new folder. Keep portable.txt beside the EXE. Game installations still need updating through setup.') ('OptiShade portable update'))
  $releasePage=if($Update.ReleaseUrl){$Update.ReleaseUrl}else{'https://github.com/GamingWithGravy/OptiShade/releases'}
  Start-Process $releasePage
  return
 }
 if(Get-Process FlightSimulator2024,FlightSimulator,X-Plane -ErrorAction SilentlyContinue){$status.Text='Close all simulators before changing versions.';return}
 $channelPlan=$null;$planPath=$null
 try{
  $channelPlan=NewOptiShadeChannelPlan $store ([string]$Update.Version)
  if($channelPlan.RestoreXPlane.Count){
   if(-not $channelPlan.Supported.Count){[void](ShowOptiShadeDialog ($form) ('Only X-Plane installations are recorded. Stable does not support them. Keep this beta manager for Play and Restore; no installation or manager has been changed.') ('Return to stable'));return}
   $review="Stable will update $($channelPlan.Supported.Count) supported installation(s). X-Plane is beta-only. Continue by restoring only the recorded OptiShade files for these X-Plane installations first? Presets are kept. If the later update fails, these games remain restored and this beta manager remains usable.`n`n"+($channelPlan.RestoreXPlane.Game -join "`n")
   if((ShowOptiShadeDialog ($form) ($review) ('Review return to stable') ('YesNo') ('Warning') ('No')) -ne 'Yes'){return}
   $planPath=Join-Path $store ('Updates/plan-'+[guid]::NewGuid().ToString('N')+'.json');[void][IO.Directory]::CreateDirectory((Split-Path $planPath))
   $channelPlan.Phase='Restoring approved X-Plane installations';WriteState $channelPlan $planPath
   foreach($entry in $channelPlan.RestoreXPlane){
    if((Get-FileHash -LiteralPath $entry.Receipt -Algorithm SHA256).Hash -ne $entry.ReceiptHash){throw 'An installation changed after review. Reopen the version-change dialog.'}
    RestoreFusion $entry.Receipt -KeepPresets $true
    $entry['Outcome']='Restored';WriteState $channelPlan $planPath
   }
   $channelPlan.Phase='X-Plane restored; manager update not yet applied';WriteState $channelPlan $planPath
  }
 }catch{if($channelPlan -and $planPath){$channelPlan.Phase='Stopped: '+$_.Exception.Message;WriteState $channelPlan $planPath};$status.Text=$_.Exception.Message;[void](ShowOptiShadeDialog ($form) ($status.Text) ('Version change stopped'));return}

 $updateDir=Join-Path $store ('Updates/'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $updateDir -Force|Out-Null
 $worker=Join-Path $updateDir 'update-worker.ps1';Copy-Item -LiteralPath "$PSScriptRoot/update-worker.ps1" -Destination $worker
 Copy-Item -LiteralPath "$PSScriptRoot/dialog-theme.xaml" -Destination (Join-Path $updateDir 'dialog-theme.xaml')
 Copy-Item -LiteralPath "$PSScriptRoot/update-lifecycle.ps1" -Destination (Join-Path $updateDir 'update-lifecycle.ps1')
 Copy-Item -LiteralPath "$PSScriptRoot/json-state.ps1" -Destination (Join-Path $updateDir 'json-state.ps1')
 $config=Join-Path $updateDir 'update.json';$Update|Add-Member -NotePropertyName Installer -NotePropertyValue $Installer -Force
 $Update|Add-Member -NotePropertyName Desktop -NotePropertyValue ([Environment]::GetFolderPath('DesktopDirectory')) -Force
 $Update|Add-Member -NotePropertyName PreviousHash -NotePropertyValue ((Get-FileHash -LiteralPath $Installer -Algorithm SHA256).Hash) -Force
 $Update|Add-Member -NotePropertyName Store -NotePropertyValue $store -Force
 $Update|Add-Member -NotePropertyName InstallationPlan -NotePropertyValue $channelPlan -Force
 WriteState $Update $config
 $hostExe=Join-Path $updateDir 'OptiShade_updater.exe';Copy-Item -LiteralPath "$PSScriptRoot/FusionSetup.exe" -Destination $hostExe
 try{Start-Process -FilePath $hostExe -ArgumentList @('--update-worker',('"'+$config+'"')) -WindowStyle Hidden -Verb RunAs;$form.Close()}
 catch{$status.Text='The updater could not start or administrator access was cancelled. No update was applied. '+$_.Exception.Message}
}
function StartModularManagerUpdate($Update){
 if($env:OPTISHADE_PORTABLE -eq '1'){throw 'The AppData manager updater cannot update a portable copy.'}
 $app=[IO.Path]::GetFullPath($Installer);$installRoot=[IO.Path]::GetDirectoryName($app)
 $expected=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Programs/OptiShade'
 if(-not [string]::Equals($installRoot.TrimEnd('\'),[IO.Path]::GetFullPath($expected).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($app) -cne 'OptiShade.exe'){throw 'Self-update is available only for the verified per-user OptiShade AppData installation.'}
 $receiptPath=Join-Path $installRoot 'install-receipt.json';$uninstaller=Join-Path $installRoot 'Uninstall.exe'
 if(-not(Test-Path -LiteralPath $receiptPath -PathType Leaf) -or -not(Test-Path -LiteralPath $uninstaller -PathType Leaf)){throw 'The app installation receipt or uninstaller is missing. Use the installer to repair this application before updating.'}
 $receipt=Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
 if($receipt.Schema -ne 1 -or (Get-FileHash -LiteralPath $app -Algorithm SHA256).Hash -ine [string]$receipt.SHA256 -or (Get-FileHash -LiteralPath $uninstaller -Algorithm SHA256).Hash -ine [string]$receipt.UninstallerSHA256){throw 'The manager or uninstaller differs from its installation receipt. Nothing was changed.'}
 $updateDir=Join-Path $store ('Updates/launcher-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($updateDir)
 $helper=Join-Path $updateDir 'OptiShadeLauncherUpdater.exe';Copy-Item -LiteralPath $app -Destination $helper
 $configPath=Join-Path $updateDir 'update.json'
 $config=[ordered]@{Schema=1;InstallDir=$installRoot;ExpectedVersion=[string]$Update.Version;LauncherPID=[int]$env:OPTISHADE_LAUNCHER_PID;HostPID=$PID}
 if($config.LauncherPID -lt 1){throw 'The launcher process handoff could not be verified. No update was started.'}
 [IO.File]::WriteAllText($configPath,($config|ConvertTo-Json -Depth 3),[Text.UTF8Encoding]::new($false))
 Start-Process -FilePath $helper -ArgumentList @('--launcher-apply-update',('"'+$configPath+'"')) -WindowStyle Hidden -ErrorAction Stop|Out-Null
 $status.Text='The verified launcher update will install after OptiShade closes. The previous version will be kept for recovery.'
 $form.Close()
}
function ConfirmManagerCoreInstallation([string]$ManifestPath){
 $record=ReadOptiShadeState $ManifestPath
 if($record.Status -cne 'Installed' -or [IO.Path]::GetFullPath([string]$record.Game) -ine [IO.Path]::GetFullPath([string]$path.Text)){throw 'The core install did not return a matching completed receipt.'}
 $loader=GetOptiShadeInstalledLoaderPath $record
 $owned=@($record.Files|Where-Object {$_.Path -ieq $loader})
 if(-not $loader -or $owned.Count -ne 1 -or (HashFile (OwnedPath $record.Game $loader)) -ine [string]$owned[0].Hash){throw 'The installed core loader did not verify. Repair this game before launching.'}
 foreach($game in @($form.FindName('MsfsCopies').ItemsSource)+@($script:libraryGames)){
  if($game.Folder -and ($record.Game -ieq $game.Folder -or $record.Game.StartsWith($game.Folder+'\',[StringComparison]::OrdinalIgnoreCase))){if($game.PSObject.Properties['InstallFolder']){$game.InstallFolder=$record.Game}else{$game|Add-Member -NotePropertyName InstallFolder -NotePropertyValue $record.Game}}
 }
 RequestManagerStatusScan -Force
}
function CompleteManualManagerInstall([string]$ManifestPath,$PreviousManifest){
 try{
  $cleanup=CompleteOptiShadeManualInstall $ManifestPath $Installer (GetBundledOptiShadeVersion) $store $PreviousManifest { $form.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background) }
  if($cleanup){$status.Text+=' '+$cleanup}
 }catch{$status.Text+=' The installation completed, but manager cleanup was stopped: '+$_.Exception.Message}
}
function StartOperationProgress([string]$Title,[string]$Detail='Preparing...'){
 if($script:operationProgressAttempted){return}
 $script:operationProgressAttempted=$true
 $script:operationProgressPath=$null
 try{
  $operationsDir=Join-Path ([IO.Path]::GetTempPath()) 'OptiShade/Operations'
  [void][IO.Directory]::CreateDirectory($operationsDir)
  Get-ChildItem -LiteralPath $operationsDir -Filter 'operation-*.json' -ErrorAction SilentlyContinue | Where-Object {$_.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddDays(-1)} | Remove-Item -Force -ErrorAction SilentlyContinue
  $id=[guid]::NewGuid().ToString('N')
  $script:operationProgressPath=Join-Path $operationsDir ('operation-'+$id+'.json')
  $configPath=Join-Path $operationsDir ('operation-'+$id+'.config.json')
  $state=@{Title=$Title;Detail=$Detail;Completed=0;Total=0;Status='Running'}
  $script:operationProgressLastState=$state
  # The progress window writes this file when the user presses Cancel.
  $script:operationCancelPath=$script:operationProgressPath+'.cancel'
  if([IO.File]::Exists($script:operationCancelPath)){[IO.File]::Delete($script:operationCancelPath)}
  $config=@{Title=$Title;ProgressPath=$script:operationProgressPath;ParentPid=$PID;CancelPath=$script:operationCancelPath}
  $encoding=[Text.UTF8Encoding]::new($false)
  WriteOptiShadeOperationProgressState $script:operationProgressPath $state
  [IO.File]::WriteAllText($configPath,(ConvertTo-Json $config -Compress),$encoding)
  $arguments=@('--operation-progress',('"'+$configPath+'"'))
  # The EXE may have been moved, deleted or quarantined since it started (OSD-YQ25);
  # progress then stays in this window.
  if(-not [IO.File]::Exists($Installer)){throw 'The OptiShade EXE is no longer where it was started from (moved, deleted or quarantined). Progress stays in this window.'}
  Start-Process -FilePath $Installer -ArgumentList $arguments -WindowStyle Normal | Out-Null
 }catch{
  $script:operationProgressPath=$null
  WriteInstallerLog ('Could not open the separate operation progress window: '+$_.Exception.Message)
 }
}
function UpdateOperationProgress([string]$Detail,[int]$Completed=0,[int]$Total=0){
 if(-not $script:operationProgressPath){return}
 try{
  $state=@{Title=$(if($script:operationTitle){$script:operationTitle}else{'Working on OptiShade'});Detail=$Detail;Completed=[Math]::Max(0,$Completed);Total=[Math]::Max(0,$Total);Status='Running'}
   $script:operationProgressLastState=$state
  WriteOptiShadeOperationProgressState $script:operationProgressPath $state
 }catch{WriteInstallerLog ('Could not update operation progress: '+$_.Exception.Message)}
}
function TestOperationCancelRequested{
 return [bool]($script:operationCancelPath -and [IO.File]::Exists($script:operationCancelPath))
}
# Called only at safe points. Throws once; later checks pass so rollback and
# cleanup code that reports progress can always run to the end.
function AssertOperationNotCancelled{
 if($script:operationCancelled -or -not (TestOperationCancelRequested)){return}
 $script:operationCancelled=$true
 WriteInstallerLog 'Operation cancelled by the user at a safe point.'
 throw 'Cancelled. The step in progress was rolled back; nothing else was changed.'
}
function StopOperationProgress([switch]$Failed,[switch]$Attention,[switch]$Cancelled){
 if(-not $script:operationProgressPath){return}
 try{
   $previous=$script:operationProgressLastState
   $state=@{Title=$(if($script:operationTitle){$script:operationTitle}else{'OptiShade operation'});Detail=$(if($Failed -or $Attention -or $Cancelled){[string]$status.Text}else{'Operation finished.'});Completed=$(if($previous){[Math]::Max(0,[int]$previous.Completed)}else{0});Total=$(if($previous){[Math]::Max(0,[int]$previous.Total)}else{0});Status=$(if($Cancelled){'Cancelled'}elseif($Failed){'Failed'}elseif($Attention){'Attention'}else{'Completed'})}
  WriteOptiShadeOperationProgressState $script:operationProgressPath $state
 }catch{WriteInstallerLog ('Could not finish operation progress: '+$_.Exception.Message)}
 try{if($script:operationCancelPath -and [IO.File]::Exists($script:operationCancelPath)){[IO.File]::Delete($script:operationCancelPath)}}catch{}
 $script:operationProgressPath=$null;$script:operationCancelPath=$null
}
function PumpManagerDispatcher{
 if(-not $form -or -not $form.Dispatcher.CheckAccess()){return}
 if($script:lastManagerPumpAt -and ([DateTime]::UtcNow-$script:lastManagerPumpAt).TotalMilliseconds -lt 33){return}
 $script:lastManagerPumpAt=[DateTime]::UtcNow
 try{
  # RunAction is synchronous for installer mutations. Pump a short bounded
  # dispatcher frame at progress boundaries so WPF can repaint and process
  # window messages instead of showing Windows' "not responding" prompt.
  $frame=[Windows.Threading.DispatcherFrame]::new()
  $stopFrame={ $frame.Continue=$false }.GetNewClosure()
  $pumpOperation=$form.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background,[Action]$stopFrame)
  try{[Windows.Threading.Dispatcher]::PushFrame($frame)}finally{if($pumpOperation.Status -eq 'Pending'){[void]$pumpOperation.Abort()}}
 }catch{WriteInstallerLog ('Could not pump manager UI during progress: '+$_.Exception.Message)}
}
# The user has already accepted at startup. Mutation paths fail closed if this
# session context is lost; they never open a late consent prompt mid-operation.
$script:AntiCheatScanUI=$null
$script:AntiCheatDecision={param($result) ConfirmFusionInstall $form $result}
$script:AntiCheatPump={param($message) $status.Text=$message;PumpManagerDispatcher}
$script:AntiCheatBindContext={param($game)
 $control=$path;$selected=[string]$path.Text;$window=$form
 return {$window.IsLoaded -and [string]::Equals($selected,[string]$control.Text,[StringComparison]::OrdinalIgnoreCase)}.GetNewClosure()
}
function RunAction([scriptblock]$action,[string]$activity='',[switch]$QueueOnly,[switch]$SkipTargetRecovery){
 $script:queueOnlyProgress=$false;$script:operationProgressAttempted=$false
 if(-not $script:startupReady){$status.Text=if($script:startupFailed){'Startup did not finish. Close and reopen the launcher; export launcher diagnostics if it happens again.'}else{'Finishing launcher initialization. Please wait.'};return}
 if($script:busy){return};$script:busy=$true
 $script:operationProgressPath=$null;$script:operationCancelPath=$null
 $script:AntiCheatOperation=@{Name=($activity+' | '+(@($componentSelectors|ForEach-Object {if($_){[string]$_.Name+':'+[string]$_.IsChecked}}) -join ','));Accepted=@{}}
 foreach($control in $buttons+$componentSelectors){if($control){$control.IsEnabled=$false}}
  $script:operationFailed=$false;$script:operationAttention=$false;$script:operationProgressLastState=$null;$managerMutation=$null
  $script:operationCancelled=$false;$script:OptiShadeCancelCheck={AssertOperationNotCancelled}
 try{
  $managerMutation=EnterOptiShadeMutation -StateRoot $store
  $script:operationTitle=if($activity){$activity}else{'Working on OptiShade'}
  # Open progress only on the first execution progress callback, after preflight choices.
  $script:operationProgressPath=$null
  $script:queueOnlyProgress=[bool]$script:operationProgressPath
  if($script:queueOnlyProgress){$form.FindName('InstallProgress').Visibility='Collapsed';$form.FindName('ComponentProgress').Visibility='Collapsed'}
  if($path.Text -and -not $SkipTargetRecovery){
   $path.Text=ResolveFusionInstallFolder $path.Text
   $routeReceipt=ManifestPath $store $path.Text
   if(Test-Path -LiteralPath $routeReceipt){[void](RecoverOptiShadeRouteTransaction $routeReceipt)}
  }
  & $action;$status.Foreground='#BDA0F4'
 }catch{if($script:operationCancelled){$status.Text=$_.Exception.Message;$status.Foreground='#FFBE83'}else{$script:operationFailed=$true;$status.Text=GetOptiShadeFriendlyError $_;$status.Foreground='#FFBE83';WriteInstallerLog ($_.Exception.Message+' | '+$_.ScriptStackTrace)}}
 finally{
  $script:OptiShadeCancelCheck=$null
  ExitOptiShadeMutation $managerMutation
   try{if($script:operationCancelled){StopOperationProgress -Cancelled}elseif($script:operationFailed){StopOperationProgress -Failed}elseif($script:operationAttention){StopOperationProgress -Attention}else{StopOperationProgress}}catch{WriteInstallerLog ('Could not finish operation progress: '+$_.Exception.Message)}
  $script:queueOnlyProgress=$false;$script:busy=$false
  if(-not $script:operationFailed){$script:allFxDraft=$null}
  $script:AntiCheatOperation=$null;$script:AntiCheatContextValid=$null
  try{
   $form.FindName('ComponentProgress').IsIndeterminate=$false;$form.FindName('ComponentProgress').Visibility='Visible'
   $form.FindName('ComponentOperation').Text=$status.Text
   $form.FindName('InstallProgress').IsIndeterminate=$false;$form.FindName('InstallProgress').Visibility='Collapsed'
  }catch{WriteInstallerLog ('Could not refresh operation controls: '+$_.Exception.Message)}
  foreach($control in $buttons){if($control){try{$control.IsEnabled=$true}catch{WriteInstallerLog ('Could not re-enable a manager action: '+$_.Exception.Message)}}}
  foreach($control in $componentSelectors){if($control){try{$control.IsEnabled=$true}catch{WriteInstallerLog ('Could not re-enable a component action: '+$_.Exception.Message)}}}
  if(-not $script:uninstallDone){try{RefreshLibrary}catch{WriteInstallerLog ('Could not refresh the game library after an operation: '+$_.Exception.Message);if(-not $script:operationFailed){$status.Text='The operation finished, but the game list could not refresh. '+$_.Exception.Message;$status.Foreground='#FFBE83'}}}
  try{if($form.FindName('ComponentsPage').Visibility -eq 'Visible' -and -not $script:pathRefreshTimer.IsEnabled -and (Get-Command RefreshAddonCards -ErrorAction SilentlyContinue)){RefreshAddonCards}}catch{WriteInstallerLog ('Could not refresh component cards after an operation: '+$_.Exception.Message)}
 }
}

$form.Add_Closing({param($sender,$e) if($script:busy){$e.Cancel=$true}})
$progress={param($text,[int]$completed=0,[int]$total=0)
 $form.FindName('ComponentOperation').Text=$text;$cp=$form.FindName('ComponentProgress');$cp.IsIndeterminate=($total -le 0);if($total -gt 0){$cp.Maximum=$total;$cp.Value=[Math]::Min($completed,$total)}
 $status.Text=$text
 if($script:busy -and -not $script:operationProgressPath -and -not $script:operationProgressAttempted){$title=if($script:operationTitle){$script:operationTitle}else{'Downloading and installing files'};StartOperationProgress $title $text;$script:queueOnlyProgress=[bool]$script:operationProgressPath}
 if($script:queueOnlyProgress){$form.FindName('InstallProgress').Visibility='Collapsed';$form.FindName('ComponentProgress').Visibility='Collapsed'}
 UpdateOperationProgress $text $completed $total
 if(-not $script:queueOnlyProgress){
  $bar=$form.FindName('InstallProgress');$bar.Visibility='Visible';$bar.IsIndeterminate=($total -le 0)
  if($total -gt 0){$bar.Maximum=$total;$bar.Value=[Math]::Min($completed,$total)}
 }
 PumpManagerDispatcher
}
$script:pendingFxPresetPath=''
$script:pendingFxPresetGame=''
function ShowFxIniPicker{
 $popup=NewManagerPopup 'Choose an FX preset' 'Navigate to an INI file or drag and drop it below.'
 $drop=New-Object Windows.Controls.Border;$drop.Height=154;$drop.Margin='0,6,0,10';$drop.Padding='18';$drop.AllowDrop=$true;$drop.CornerRadius='8';$drop.BorderThickness='1';$drop.BorderBrush=[Windows.Media.BrushConverter]::new().ConvertFromString('#7546A8');$drop.Background=[Windows.Media.BrushConverter]::new().ConvertFromString('#211B2C')
 $dropContent=New-Object Windows.Controls.StackPanel;$dropContent.VerticalAlignment='Center'
 $prompt=New-Object Windows.Controls.TextBlock;$prompt.Text='Drop a ReShade .ini preset here';$prompt.FontSize=17;$prompt.FontWeight='SemiBold';$prompt.HorizontalAlignment='Center'
 $fileLabel=New-Object Windows.Controls.TextBlock;$fileLabel.Text='No file selected';$fileLabel.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#BDA0F4');$fileLabel.HorizontalAlignment='Center';$fileLabel.TextWrapping='Wrap';$fileLabel.Margin='0,8,0,0'
 [void]$dropContent.Children.Add($prompt);[void]$dropContent.Children.Add($fileLabel);$drop.Child=$dropContent;[void]$popup.Body.Children.Add($drop)
 $browse=AddPopupButton $popup 'Browse files...';$cancel=AddPopupButton $popup 'Cancel';$install=AddPopupButton $popup 'Use this preset' $true;$install.IsEnabled=$false
 $state=@{Path='';Chosen=$false;Label=$fileLabel;Install=$install;Window=$popup.Window}
 $setPath={param([string]$candidate)
  if(-not $candidate -or [IO.Path]::GetExtension($candidate) -ine '.ini' -or -not(Test-Path -LiteralPath $candidate -PathType Leaf)){$state.Label.Text='Choose a valid .ini preset file.';$state.Install.IsEnabled=$false;$state.Path='';return}
  $state.Path=[IO.Path]::GetFullPath($candidate);$state.Label.Text=[IO.Path]::GetFileName($state.Path);$state.Install.IsEnabled=$true
 }.GetNewClosure()
 $cancel.Add_Click({$popup.Window.Close()}.GetNewClosure())
 $browse.Add_Click({$picker=New-Object Windows.Forms.OpenFileDialog;$picker.Filter='ReShade preset (*.ini)|*.ini';$picker.Title='Choose an FX preset';try{if($picker.ShowDialog() -eq 'OK'){& $setPath $picker.FileName}}finally{$picker.Dispose()}}.GetNewClosure())
 $drop.Add_DragOver({param($sender,$event) $event.Effects=if($event.Data.GetDataPresent([Windows.DataFormats]::FileDrop)){'Copy'}else{'None'};$event.Handled=$true})
 $drop.Add_Drop({param($sender,$event) if($event.Data.GetDataPresent([Windows.DataFormats]::FileDrop)){$files=@($event.Data.GetData([Windows.DataFormats]::FileDrop));if($files.Count -eq 1){& $setPath ([string]$files[0])}else{$state.Label.Text='Drop one INI preset at a time.'}};$event.Handled=$true}.GetNewClosure())
 $state.Install.Add_Click({if($state.Path){$state.Chosen=$true;$state.Window.Close()}}.GetNewClosure())
 ShowManagerPopup $popup
 if($state.Chosen){return $state.Path}
 return $null
}
function RememberAllFxSelection{
 if($script:refreshingAddonCards){return}
 $script:allFxDraft=[pscustomobject]@{Game=(GetOptiShadeManagerStatusKey $path.Text);Value=[bool]$form.FindName('InstallAllFx').IsChecked}
 UpdateComponentSelection
}
function GetAllFxSelectionForDisplay([bool]$Installed){
 if($script:allFxDraft -and $script:allFxDraft.Game -eq (GetOptiShadeManagerStatusKey $path.Text)){return [bool]$script:allFxDraft.Value}
 return $Installed
}
$form.FindName('InstallAllFx').Add_Checked({RememberAllFxSelection})
$form.FindName('InstallAllFx').Add_Unchecked({RememberAllFxSelection})
$form.FindName('ImportFxIni').Add_Click({
 $selectedIni=ShowFxIniPicker;if(-not $selectedIni){return}
 $script:pendingFxPresetPath=$selectedIni
 $selectionRoot=if($script:gameRoot){$script:gameRoot}else{$path.Text}
 $script:pendingFxPresetGame=[IO.Path]::GetFullPath($selectionRoot).TrimEnd('\')
 $form.FindName('FxIniName').Text='Preset selected: '+[IO.Path]::GetFileName($selectedIni)+' · press Apply selected changes to install'
 $form.FindName('FxIniName').Visibility='Visible'
 $status.Text='Preset selected. Finish choosing components, then press Apply selected changes.'
 UpdateComponentSelection
})
$form.FindName('Install').Add_Click({RunAction {
 $exe=ChooseGameExe; if(-not $exe){return}; AssertFusionExecutable $exe
 if((GetFusionInstallState $store $path.Text) -match '^Installed'){
  EnsureVerifiedModularPayload -RequiredIds @()
  $mp=ManifestPath $store $path.Text;$previous=ReadOptiShadeState $mp
  if(-not(TestBundledUpdateVersion $previous) -and -not(TestOptiShadeChannelChange $previous.Version (GetBundledOptiShadeVersion))){throw 'This manager does not contain a newer version. Use the manager matching the installed version for Repair.'}
  $oldProxy=GetOptiShadeInstalledLoaderPath $previous
  if(-not $oldProxy){throw 'The recorded loader is unknown. Update stopped.'}
  $method=GetSelectedMethod;$proxy=ResolveOptiShadeInstallMethod $method $oldProxy
  $rendererApi=(GetManifestMethodRendererApi $method $proxy $previous).ToLowerInvariant()
   $mp=InstallFusion $path.Text $Payload $store $Installer $proxy @(FindFusionConflicts $path.Text) -ReplaceExisting $true -PreserveConfiguration $true -Progress $progress
  $updated=ReadOptiShadeState $mp
  foreach($key in @('LaunchExe','NativeLaunchExe','Downloads','OptionalDlss','FxPresetRelative','AllFxInstalled','NeuralRuntimeVariant','NeuralRuntimeHash','DlssRuntimeProfile')){if($previous.PSObject.Properties[$key]){$updated|Add-Member -NotePropertyName $key -NotePropertyValue $previous.$key -Force}}
  $updated|Add-Member -NotePropertyName InstallMethod -NotePropertyValue $method -Force
  $updated|Add-Member -NotePropertyName RendererApi -NotePropertyValue $rendererApi -Force
  WriteState $updated $mp;SetOnlineComponentPackageReceipt $mp 'Core';ConfirmManagerCoreInstallation $mp;$status.Text='OptiShade updated from this manager. Settings and presets kept. No Restore is required.';CompleteManualManagerInstall $mp $previous;ShowPage 'Components';return
 }
 if((GetFusionInstallState $store $path.Text) -match '^Installation incomplete'){throw 'An incomplete installation was found. Repair using the matching manager first.'}
 AssertMsfsNvidiaTarget $exe (GetFusionGpu)
 $method=GetSelectedMethod
 $plan=CheckGameCompatibility $exe
 if($plan.Proxy -eq 'unsupported'){throw $plan.Performance}
 WriteInstallerLog (FormatFusionCompatibility $plan)
 $driverNote=GetNvidiaDriverWarning $script:gpu;if($driverNote){WriteInstallerLog $driverNote}
 $proxy=ResolveOptiShadeInstallMethod $method $plan.Proxy
 if((Split-Path $exe -Leaf) -eq 'X-Plane.exe'){$proxy='dxgi.dll'}
 $rendererApi=(GetOptiShadeMethodRendererApi $method $proxy $plan.ExecutableIdentity.ApiCandidates -Executable $exe).ToLowerInvariant()
 $optionalDlss=$false # Optional components are selected after the core install.
 if($null -eq $optionalDlss){return}
 $replace=@(FindFusionConflicts $path.Text)
 $existing=Test-Path -LiteralPath (ManifestPath $store $path.Text)
 $existing=$existing -or (Test-Path -LiteralPath (Join-Path $path.Text 'OptiShadeData'))
 $manualPrevious=$null;$manualRecord=ManifestPath $store $path.Text;if(Test-Path -LiteralPath $manualRecord){$manualPrevious=ReadOptiShadeState $manualRecord}
 EnsureVerifiedModularPayload -RequiredIds @()
  $script:manifest=InstallFusion $path.Text $Payload $store $Installer $proxy $replace -ReplaceExisting $existing -IncludeEffects $false -Executable $exe -Progress $progress
 $m=ReadOptiShadeState $script:manifest;$m|Add-Member -NotePropertyName LaunchExe -NotePropertyValue $exe -Force;$m|Add-Member -NotePropertyName Downloads -NotePropertyValue 'Complete' -Force;$m|Add-Member -NotePropertyName OptionalDlss -NotePropertyValue ([bool]$optionalDlss) -Force;$m|Add-Member -NotePropertyName InstallMethod -NotePropertyValue $method -Force;$m|Add-Member -NotePropertyName RendererApi -NotePropertyValue $rendererApi -Force;WriteState $m $script:manifest
 SaveFusionCompatibility $path.Text $plan
 $m=ReadOptiShadeState $script:manifest
 if($script:selectedNativeLaunchExe){$m|Add-Member -NotePropertyName NativeLaunchExe -NotePropertyValue $script:selectedNativeLaunchExe -Force}
 $m|Add-Member -NotePropertyName DisplayName -NotePropertyValue ([string]$form.FindName('SelectedTitle').Text) -Force
 WriteState $m $script:manifest;SetOnlineComponentPackageReceipt $script:manifest 'Core'
 ConfirmManagerCoreInstallation $script:manifest
 CompleteManualManagerInstall $script:manifest $manualPrevious
 $status.Text='OptiShade core installed. Choose your components below, then start the game and enable the features you want.'
 WriteInstallerLog ('Core install verified: executable='+$exe+'; method='+$proxy+'; receipt='+$script:manifest)
 EnsureOptiShadeCrashDumps $exe
 ShowPage 'Components'
 } 'Installing OptiShade'})
function InvokeRestoreInstall{
 $m=ManifestPath $store $path.Text;if(-not(Test-Path -LiteralPath $m)){throw 'No recorded installation for this game.'}
 RestoreFusion $m -KeepPresets ([bool]$script:restoreKeepPresets) -Progress $progress
 $status.Text='Game restored. Original files are back and OptiShade game files are removed.'
 $restored=ReadOptiShadeState $m
 if($restored.RecoveredShaders){$status.Text+=' Edited shaders saved in: '+$restored.RecoveredShaders}
 if($restored.RecoveredChangedFiles){$status.Text+=' Changed OptiShade-owned files saved in: '+$restored.RecoveredChangedFiles}
 if($restored.UnrestoredOriginalFiles){$names=@($restored.UnrestoredOriginalFiles|ForEach-Object {[IO.Path]::GetFileName($_)}|Select-Object -Unique);$status.Text+=' OptiShade was removed, but its original game backup could not be verified for '+($names -join ', ')+'. Verify these files through the game launcher.'}
 if($restored.RestoreWarnings){$names=@($restored.RestoreWarnings|ForEach-Object {[IO.Path]::GetFileName($_)}|Select-Object -Unique);$status.Text+=' Original preset backup unavailable for '+($names -join ', ')+'. The current saved preset was kept.'}
}
$form.FindName('Restore').Add_Click({RunAction {InvokeRestoreInstall} 'Restoring original game files'})
 $form.FindName('PrepareMfg').IsEnabled=$false
$form.FindName('PrepareFsr').IsEnabled=$false
# A dialog opened during an operation must not sit behind the separate
# progress window: the operation would wait for an answer nobody can see.
# Hide the progress window while the dialog is open, then restore it.
function InvokeWithOperationProgressHidden([scriptblock]$Show){
 $progressPath=$script:operationProgressPath
 if(-not $progressPath){return & $Show}
 $last=$script:operationProgressLastState
 $title=if($script:operationTitle){$script:operationTitle}else{'OptiShade operation'}
 try{WriteOptiShadeOperationProgressState $progressPath @{Title=$title;Detail='Waiting for your choice in the OptiShade window...';Completed=0;Total=0;Status='AwaitingConsent'}}catch{}
 try{return & $Show}
 finally{
  $resume=if($last){$last}else{@{Title=$title;Detail='Continuing...';Completed=0;Total=0;Status='Running'}}
  try{WriteOptiShadeOperationProgressState $progressPath $resume}catch{}
 }
}
function ShowNeuralAdapterPicker([string]$ManifestPath,[string]$Component='Neural'){
 if(-not(Test-Path -LiteralPath $ManifestPath)){throw 'Install OptiShade for this game first.'}
 $record=ReadOptiShadeState $ManifestPath
 AssertClosed $record.Game
 $gpu=GetFusionGpu;$cards=@(GetOptiShadeNeuralAdapterChoices $gpu)
 if(-not $cards.Count){throw 'No supported RTX GPU was detected. Ordinary image effects remain available.'}
 # Same frameless OptiShade chrome as ShowOptiShadeDialog (dialogs.ps1).
 [xml]$markup=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="Neural model GPU" Width="600" SizeToContent="Height" WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" Foreground="#F3EFFB" FontSize="14" ShowInTaskbar="False">
 <Border Background="{DynamicResource WindowGlass}" BorderBrush="#55406C" BorderThickness="1" CornerRadius="10"><Grid Margin="28">
 <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
 <DockPanel Name="Drag" Margin="0,0,0,22"><Button Name="Dismiss" Content="&#x2715;" Background="Transparent" Padding="8" DockPanel.Dock="Right"/><TextBlock FontSize="22" FontWeight="SemiBold" VerticalAlignment="Center"><Run Text="O" Foreground="#AB70FF"/><Run Text="ptiShade"/></TextBlock></DockPanel>
 <TextBlock Name="Heading" Grid.Row="1" Text="Choose the GPU for neural model preparation" FontSize="25" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,0,0,12"/>
 <TextBlock Name="Details" Grid.Row="2" Text="This explicit choice resolves which installed RTX adapter OptiShade prepares the neural model for. It does not claim which adapter the game is currently rendering on; that is checked separately at runtime." TextWrapping="Wrap" Foreground="#C0AEDF" FontSize="14" LineHeight="22" Margin="0,0,0,18"/>
 <ComboBox Name="Cards" Grid.Row="3" Margin="0,0,0,4"/>
 <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,24,0,0"><Button Name="Cancel" Content="Cancel" MinWidth="100" Background="#211D30"/><Button Name="Save" Content="Save GPU choice and continue" Margin="10,0,0,0" IsDefault="True"/></StackPanel>
 </Grid></Border>
</Window>
'@
 if($Component -eq 'OptiMfg'){
  $markup.Window.Title='OptiMFG GPU'
  $markup.Window.Border.Grid.TextBlock[0].Text='Choose the GPU for OptiMFG preparation'
  $markup.Window.Border.Grid.TextBlock[1].Text='Choose the RTX adapter used for this game. OptiMFG prepares the matching backend; the running game must still verify its provider and supported multipliers.'
 }
 $dialog=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup));$dialog.Owner=$form
 $dialog.Resources.MergedDictionaries.Add($form.Resources)
 $dialog.FindName('Dismiss').Add_Click({$dialog.DialogResult=$false})
 $dialog.FindName('Cancel').Add_Click({$dialog.DialogResult=$false})
 $dialog.FindName('Drag').Add_MouseLeftButtonDown({if($_.OriginalSource -is [Windows.Controls.TextBlock]){$dialog.DragMove()}})
 $dialog.Add_PreviewKeyDown({param($sender,$event) if($event.Key -eq 'Escape'){$dialog.DialogResult=$false;$event.Handled=$true}})
 $picker=$dialog.FindName('Cards');$picker.DisplayMemberPath='Label';foreach($card in $cards){[void]$picker.Items.Add($card)}
 $current=if($Component -eq 'OptiMfg'){ResolveOptiMfgComponentAdapter $gpu $record}else{ResolveOptiShadeNeuralAdapter $record $gpu};if($current.State -eq 'candidate'){$matches=@($cards|Where-Object {$_.Luid -ceq $current.Adapter.Luid});if($matches.Count -eq 1){$picker.SelectedItem=$matches[0]}}
 $dialog.FindName('Save').Add_Click({if($picker.SelectedItem){$dialog.DialogResult=$true}})
 $chosen=InvokeWithOperationProgressHidden {$dialog.ShowDialog()}
 if($chosen){
  # Refresh the measured inventory at commit time; the list can become stale
  # while the modal picker is open (for example, after a display reconnect).
  if($Component -eq 'OptiMfg'){SetOptiMfgAdapterSelection $record (GetFusionGpu) ([string]$picker.SelectedItem.Luid)}
  else{SetOptiShadeNeuralAdapterSelection $record (GetFusionGpu) ([string]$picker.SelectedItem.Luid)}
  WriteState $record $ManifestPath
  return $true
 }
 return $false
}
$form.FindName('ChooseNeuralGpu').Add_Click({RunAction {
 $mp=ManifestPath $store $path.Text
 if(ShowNeuralAdapterPicker $mp){$status.Text='NR adapter choice saved. Retry downloads will recheck its model. The selected game renderer is detected separately at runtime.'}
} 'Choosing neural model GPU'})
$form.FindName('PrepareOlderRtx').Add_Click({RunAction {
 $m=ManifestPath $store $path.Text
 if(-not(Test-Path -LiteralPath $m)){throw 'Install OptiShade in this game first.'}
 $gpu=GetFusionGpu;$gpuRecord=ReadOptiShadeState $m;$candidate=ResolveOptiShadeNeuralAdapter $gpuRecord $gpu
 if($candidate.State -ne 'candidate'){throw $candidate.Reason}
 $selection=GetNeuralDownload $gpu '' ([string]$candidate.Adapter.Luid)
 if($selection.Family -notmatch '20/30/40'){throw 'This test is for a selected RTX 20, 30 or 40 GPU. RTX 50 uses its existing runtime.'}
 $record=ReadOptiShadeState $m
 $downloadsBefore=$record.Downloads
 if($record.Status -ne 'Installed'){throw 'Complete or repair this installation before preparing the test.'}
 AssertClosed $path.Text
 InstallOptiShadeAddon $m $Payload 'Neural' $gpu $progress -ExplicitSelection
 SetOlderRtxTestSettings $path.Text
 $record=ReadOptiShadeState $m
 $record|Add-Member -NotePropertyName OptionalDlss -NotePropertyValue $true -Force;WriteState $record $m
 if($downloadsBefore -eq 'Complete'){$record|Add-Member -NotePropertyName Downloads -NotePropertyValue 'Complete' -Force;WriteState $record $m}
  $status.Text='Older RTX model prepared. NR starts Off in each process; Enable it from the in-game menu after runtime checks. Use Retry downloads for unfinished preparation and collect diagnostics from the live game if it fails. Output remains unverified.'
 } 'Preparing Neural Rendering files'})
$script:nrVariantChanged=$false
$form.FindName('NrRuntimeVariant').Add_SelectionChanged({$script:nrVariantChanged=$true})
$form.FindName('Runtime').Add_Click({RunAction {
 $mp=ManifestPath $store $path.Text;$m=ReadOptiShadeState $mp
 $selector=$form.FindName('NrRuntimeVariant')
 if(-not $script:nrVariantChanged -and $m.NeuralRuntimeVariant -in @('compat-3109','official-3109','v7-3109')){
  $idx=switch($m.NeuralRuntimeVariant){'compat-3109'{1};'official-3109'{2};default{3}};$selector.SelectedIndex=$idx;$script:nrVariantChanged=$false
 }
 $plan=CheckGameCompatibility $m.LaunchExe;if(-not $plan.DownloadNvidia){throw $plan.NeuralRendering}
 $variant=[string]$selector.SelectedItem.Tag
 if(-not $variant){$variant='auto'}
 $titles=@{auto='a pinned automatic NR model (310.8)';'compat-3109'='the pinned DLSS-NR 310.9.16 FP16 compatibility DLL';'official-3109'='the NVIDIA-signed DLSS-NR 310.9.16 RTX 50 DLL';'v7-3109'='the pinned DLSS-NR 310.9 V7 RTX 20/30 test DLL'}
 $d=New-Object Windows.Forms.OpenFileDialog;$d.Title='Choose '+$titles[$variant];$d.Filter='Neural rendering runtime (nvngx_dlssnr.dll)|nvngx_dlssnr.dll|DLL files (*.dll)|*.dll'
 try{if($d.ShowDialog() -eq 'OK'){
  $model=$d.FileName
  InvokeAddonTransaction $mp 'Neural' {
   InstallAddonPayload $mp $Payload 'Neural';ImportNrRuntime $mp $model $variant
   $latest=ReadOptiShadeState $mp;$latest|Add-Member OptionalDlss $true -Force
   $latest|Add-Member Components @(@(GetOptiShadeAddonSelection $latest)+'Neural'|Select-Object -Unique) -Force;SetOptiShadeAutoComponentExclusion $latest 'Neural' $false;WriteState $latest $mp
   }
  $label=switch($variant){'compat-3109'{'DLSS-NR 310.9.16 FP16 compatibility'}'official-3109'{'NVIDIA-signed DLSS-NR 310.9.16'}'v7-3109'{'DLSS-NR 310.9 V7'}default{'GPU-matched pinned NR'}};$status.Text=$label+' runtime hash verified and installed for this game. This choice is retained by repair; verify in-game before treating it as working.'
 }}finally{$d.Dispose()}
}})
# The installed app's own uninstaller: it removes the app folder after this manager
# has restored every game, so the system uninstall starts there.
function GetOptiShadeInstalledUninstaller{
 if($env:OPTISHADE_PORTABLE -eq '1'){return ''}
 try{
  $app=[IO.Path]::GetFullPath($Installer);$expected=[IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Programs\OptiShade\OptiShade.exe'))
  $uninstaller=Join-Path (Split-Path $app -Parent) 'Uninstall.exe'
  if([string]::Equals($app,$expected,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $uninstaller -PathType Leaf)){return $uninstaller}
 }catch{}
 return ''
}
function AddOptiShadeCleanupNotes($Result){
 if($Result.RecoveredChangedFiles.Count){$status.Text+=' Changed OptiShade-owned files saved in: '+($Result.RecoveredChangedFiles -join '; ')}
 if($Result.UnrestoredOriginalFiles.Count){$names=@($Result.UnrestoredOriginalFiles|ForEach-Object {[IO.Path]::GetFileName($_)}|Select-Object -Unique);$status.Text+=' Original game backups could not be verified for '+($names -join ', ')+'. Verify these files through the game launcher.'}
}
$form.FindName('RemoveFromAllGames').Add_Click({
 if($script:busy){return};$choice=ShowRemoveFromGamesOptions $form;if(-not $choice){return}
 RunAction {
  $result=RemoveOptiShadeFromAllGames $store -KeepPresets $choice.KeepPresets -Snapshots $choice.Snapshots -Progress $progress
  $status.Text=if($result.Games){'OptiShade was removed from '+$result.Games+' game(s). The OptiShade app is still installed, so you can add it back to any game.'}else{'No games had OptiShade installed. Nothing was changed.'}
  AddOptiShadeCleanupNotes $result
  if($result.RecoveredChangedFiles.Count -or $result.UnrestoredOriginalFiles.Count){[void](ShowOptiShadeDialog ($form) ($status.Text) ('Removed from all games'))}
  try{RefreshLibrary;RequestManagerStatusScan -Force}catch{}
 } 'Removing OptiShade from all games'
})
$form.FindName('Uninstall').Add_Click({
 WriteInstallerLog ('Uninstall requested: uninstall mode='+[bool]$UninstallMode+'; busy='+[bool]$script:busy)
 if($script:busy){return}
 $installedUninstaller=GetOptiShadeInstalledUninstaller
 if(-not $UninstallMode -and $installedUninstaller){
  try{Start-Process -FilePath $installedUninstaller -WorkingDirectory ([IO.Path]::GetTempPath()) -ErrorAction Stop;$script:uninstallDone=$true;$script:trayExitRequested=$true;$form.Close()}
  catch{$status.Text='The OptiShade uninstaller could not start: '+$_.Exception.Message;$status.Foreground='#FFBE83'}
  return
 }
 $choice=ShowOptiShadeUninstallPage $form
 if(-not $choice){
  # Started by Uninstall.exe: tell it the user cancelled, so it closes quietly.
  if($UninstallMode){try{[IO.File]::WriteAllText((Join-Path $store 'Uninstall-Cancelled.json'),'{"schema":1,"cancelled":true}',[Text.UTF8Encoding]::new($false))}catch{};$script:uninstallDone=$true;$form.Close()}
  return
 }
 $feedback=StartOptiShadeUninstallFeedback $choice (GetBundledOptiShadeVersion) 'system'
 RunAction {
 # Read before the receipts go: full uninstall also takes back OptiShade's crash-dump keys.
 $crashDumpExecutables=@();if($choice.AppFiles){try{foreach($record in @(GetOptiShadeCleanupReceipts $store)){$crashDumpExecutables+=[string](ReadOptiShadeState $record.FullName).LaunchExe}}catch{WriteInstallerLog ('Crash dumps: could not list games to clean up ('+$_.Exception.Message+')')}}
 $cleanupResult=RemoveSelectedOptiShadeData $store $Installer $PSScriptRoot -AppFiles $choice.AppFiles -IniFiles $choice.IniFiles -Snapshots $choice.Snapshots -Progress $progress
 if($UninstallMode -and $choice.AppFiles -and -not $cleanupResult.UnrestoredOriginalFiles.Count){$installRoot=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Installer));$completion=[ordered]@{schema=1;complete=$true;installRoot=$installRoot;completedUtc=[DateTime]::UtcNow.ToString('o')};[IO.File]::WriteAllText((Join-Path $store 'Uninstall-Complete.json'),($completion|ConvertTo-Json -Depth 3),[Text.UTF8Encoding]::new($false))}
 if($choice.AppFiles){
  try{Remove-ItemProperty -LiteralPath $script:startupRegistry -Name OptiShadeManager -ErrorAction SilentlyContinue}catch{}
  # WriteInstallerLog recreates the store folder, so this stays out of the log once it is gone.
  try{$status.Text='Windows may ask once to remove the crash-dump setting OptiShade added.';$null=RemoveOptiShadeCrashDumps $crashDumpExecutables}catch{}
 }
 if($choice.AppFiles){$status.Text='OptiShade removed. Your original installer EXE is kept.'}else{$status.Text='Selected OptiShade files removed. The app remains installed.'}
 if($cleanupResult.RecoveredChangedFiles.Count){$status.Text+=' Changed OptiShade-owned files saved in: '+($cleanupResult.RecoveredChangedFiles -join '; ')}
 if($cleanupResult.UnrestoredOriginalFiles.Count){$names=@($cleanupResult.UnrestoredOriginalFiles|ForEach-Object {[IO.Path]::GetFileName($_)}|Select-Object -Unique);$status.Text+=' OptiShade was removed, but original game backups could not be verified for '+($names -join ', ')+'. Verify these files through the game launcher.'}
 WaitOptiShadeUninstallFeedback $feedback
 if($choice.AppFiles){if($cleanupResult.RecoveredChangedFiles.Count -or $cleanupResult.UnrestoredOriginalFiles.Count){[void](ShowOptiShadeDialog ($form) ($status.Text) ('OptiShade uninstall result'))};$script:uninstallDone=$true;$script:trayExitRequested=$true;$script:busy=$false;$form.Close()}
} 'Uninstalling OptiShade'
})
function InvokeManagerRetryDownloads {
 $mp=ManifestPath $store $path.Text;$m=ReadOptiShadeState $mp
 if($m.Status -ne 'Installed'){throw 'Install OptiShade first.'}
 AssertClosed $path.Text
 if($m.AutoCompatibility){
  $prepared=InvokeOptiShadeAutoPreparation $mp $Payload (GetFusionGpu) $progress -RetryFailed
  $status.Text=FormatOptiShadeAutoPreparation $prepared (ManifestPath $store $path.Text)
  if($form.FindName('AutoStatus')){$form.FindName('AutoStatus').Text=$status.Text}
  return
 }
 # Older receipts retain their explicit legacy download choices until Auto
 # setup is requested. They do not create another Auto preparation controller.
 $plan=CheckGameCompatibility $m.LaunchExe;SaveFusionCompatibility $path.Text $plan;FinishOptionalDownloads $m $plan
}
$form.FindName('Retry').Add_Click({RunAction {InvokeManagerRetryDownloads} 'Retrying selected preparation'})
function InvokeRepairInstall([switch]$UpdateApproved,[switch]$ModularPackageApproved){
 $mp=ManifestPath $store $path.Text
 if(-not(Test-Path -LiteralPath $mp)){throw 'No installation record. Use Install to remove conflicting mods and install OptiShade.'}
 $previous=ReadOptiShadeState $mp
 if($previous.Status -notin @('Installed','Installing')){throw 'No repairable installation record. Restore the recorded installation first, then install again.'}
 $repairAction=GetOptiShadeRepairAction $previous
 $repairMessage=if($repairAction -eq 'Repair OptiShade'){'Repair OptiShade from this installer? Core files will be replaced. Existing configuration and menu keys are kept. Your saved INI presets are kept. Original pre-install backups are preserved.'}else{"$repairAction from $($previous.Version) to $(GetBundledOptiShadeVersion) using this installer? This replaces the installed build. Saved presets, settings, menu keys and original backups are kept. Close the game first."}
 if($UpdateApproved -and -not(TestBundledUpdateVersion $previous) -and -not($ModularPackageApproved -and $script:modularDistribution)){throw 'This installation no longer needs a core update.'}
 $oldProxy=GetOptiShadeInstalledLoaderPath $previous
 if(-not $oldProxy){throw 'The recorded loader is unknown. Repair was stopped.'}
 EnsureVerifiedModularPayload -RequiredIds @()
 $method=GetSelectedMethod;$proxy=ResolveOptiShadeInstallMethod $method $oldProxy
 $rendererApi=(GetManifestMethodRendererApi $method $proxy $previous).ToLowerInvariant()
  $mp=InstallFusion $path.Text $Payload $store $Installer $proxy @(FindFusionConflicts $path.Text) -ReplaceExisting $true -PreserveConfiguration $true -Progress $progress
 $repaired=ReadOptiShadeState $mp
 foreach($key in @('LaunchExe','NativeLaunchExe','Downloads','OptionalDlss','FxPresetRelative','AllFxInstalled','NeuralRuntimeVariant','NeuralRuntimeHash','DlssRuntimeProfile')){if($previous.PSObject.Properties[$key]){$repaired|Add-Member -NotePropertyName $key -NotePropertyValue $previous.$key -Force}}
 $repaired|Add-Member -NotePropertyName InstallMethod -NotePropertyValue $method -Force
 $repaired|Add-Member -NotePropertyName RendererApi -NotePropertyValue $rendererApi -Force
 WriteState $repaired $mp;SetOnlineComponentPackageReceipt $mp 'Core';ConfirmManagerCoreInstallation $mp
 $status.Text=if($repairAction -eq 'Repair OptiShade'){'OptiShade repaired from the manager. Saved looks and original backups are kept. You can close the manager and start your game.'}else{'OptiShade '+(GetBundledOptiShadeVersion)+' installed from this manager. Saved looks, settings and original backups are kept.'}
 if($repaired.RecoveredChangedFiles){$status.Text+=' Changed OptiShade-owned files saved in: '+$repaired.RecoveredChangedFiles}
 if($repaired.UnrestoredOriginalFiles){$names=@($repaired.UnrestoredOriginalFiles|ForEach-Object {[IO.Path]::GetFileName($_)}|Select-Object -Unique);$status.Text+=' Repair completed, but original game backups could not be verified for '+($names -join ', ')+'. Verify these files through the game launcher before uninstalling OptiShade.'}
  CompleteManualManagerInstall $mp $previous
}
$form.FindName('Repair').Add_Click({RunAction {InvokeRepairInstall} 'Repairing OptiShade'})
function WriteInstallerLog([string]$Message){try{New-Item -ItemType Directory -Path $store -Force|Out-Null;((Get-Date -Format o)+' '+$Message)|Add-Content -LiteralPath (Join-Path $store 'Installer.log') -Encoding UTF8}catch{}}
function GetOptiShadeManagerCompatibilityVersion{
 $version=''
 try{$info=[Diagnostics.FileVersionInfo]::GetVersionInfo($Installer);$version=[string]$info.ProductVersion;if($version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$'){$version=[string]$info.FileVersion}}catch{}
 if($version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$'){throw 'The manager EXE does not expose a valid semantic version for component compatibility checks.'}
 return $version
}
function RemoveOptiShadeSessionPayload([string]$Candidate){
 try{
  if(-not $Candidate){return}
  $sessions=[IO.Path]::GetFullPath((Join-Path $store 'Sessions')).TrimEnd('\');$candidatePath=[IO.Path]::GetFullPath($Candidate);$parent=[IO.Path]::GetDirectoryName($candidatePath);$leaf=[IO.Path]::GetFileName($candidatePath)
  if(-not [string]::Equals($parent.TrimEnd('\'),$sessions,[StringComparison]::OrdinalIgnoreCase) -or $leaf -notmatch '^PayloadFusion-staged-[0-9a-f]{32}$' -or -not(Test-Path -LiteralPath $sessions -PathType Container) -or -not(Test-Path -LiteralPath $candidatePath -PathType Container)){return}
  if(((Get-Item -LiteralPath $sessions -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -or ((Get-Item -LiteralPath $candidatePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){return}
  Remove-Item -LiteralPath $candidatePath -Recurse -Force -ErrorAction Stop
 }catch{WriteInstallerLog ('A temporary component payload could not be cleaned up: '+$_.Exception.GetBaseException().Message)}
}
function GetComponentPayloadFallbackDescription{
 if($script:modularDistribution){return 'The modular manager has no embedded game-payload fallback; install and repair stay blocked until a complete signed package set is staged.'}
 return 'The embedded game payload remains available.'
}
function RestoreVerifiedComponentPayloadFromCache{
 try{
  if(-not(Test-Path -LiteralPath $Installer -PathType Leaf)){return}
  $cache=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'OptiShade\ComponentPackages'
  $active=Join-Path $cache 'active-set.json';if(-not(Test-Path -LiteralPath $active -PathType Leaf)){return}
  $sessions=Join-Path $store 'Sessions';[void][IO.Directory]::CreateDirectory($sessions)
  $resultPath=Join-Path $sessions ('component-compose-cache-'+[guid]::NewGuid().ToString('N')+'.json')
  $destination=Join-Path $sessions ('PayloadFusion-staged-'+[guid]::NewGuid().ToString('N'))
  $launcherSemVer=GetOptiShadeManagerCompatibilityVersion
  $arguments='--component-compose-cached "'+$resultPath+'" "'+$destination+'" "'+$launcherSemVer+'"'
  $worker=Start-Process -FilePath $Installer -ArgumentList $arguments -WindowStyle Hidden -PassThru -Wait -ErrorAction Stop
  if($worker.ExitCode -ne 0 -or -not(Test-Path -LiteralPath $resultPath -PathType Leaf)){WriteInstallerLog ('Cached signed component set was not activated. '+(GetComponentPayloadFallbackDescription)+' Exit='+[string]$worker.ExitCode);return}
  $result=Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8|ConvertFrom-Json
  if(-not $result.OK -or -not $result.ComposedPayload){WriteInstallerLog ('Cached signed component set failed revalidation. '+(GetComponentPayloadFallbackDescription)+' '+[string]$result.Message);return}
  $composed=[IO.Path]::GetFullPath([string]$result.ComposedPayload);$sessionRoot=[IO.Path]::GetFullPath($sessions).TrimEnd('\')
  if(-not [string]::Equals([IO.Path]::GetDirectoryName($composed).TrimEnd('\'),$sessionRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($composed) -notmatch '^PayloadFusion-staged-[0-9a-f]{32}$' -or -not(Test-Path -LiteralPath $composed -PathType Container) -or ((Get-Item -LiteralPath $composed -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){WriteInstallerLog ('Cached signed component composition returned an unsafe path. '+(GetComponentPayloadFallbackDescription));return}
  $script:Payload=$composed;$script:sessionComposedPayload=$composed
  $script:componentPayloadIds=@($result.Packages|ForEach-Object {[string]$_.Component}|Select-Object -Unique)
  $script:componentPackageReleases=@($result.Packages)
  WriteInstallerLog ('Revalidated cached signed component set for this manager session: '+(@($result.Packages|ForEach-Object {([string]$_.Component)+' '+[string]$_.Version}) -join ', '))
 }catch{WriteInstallerLog ('Cached signed component set could not be restored. '+(GetComponentPayloadFallbackDescription)+' '+$_.Exception.GetBaseException().Message)}
}
RestoreVerifiedComponentPayloadFromCache
function EnsureVerifiedModularPayload([string[]]$RequiredIds){
 if(-not $script:modularDistribution){return}
 $wanted=@('OptiShade.Core')
 foreach($id in @($RequiredIds)){
  if([string]::IsNullOrWhiteSpace([string]$id)){continue}
  if([string]$id -notin @('OptiShade.Effects','OptiShade.OptiMFG','OptiShade.Providers')){throw ('This modular manager has no independently published signed package for '+[string]$id+'. No game files were changed.')}
  if($id -notin $wanted){$wanted+=,[string]$id}
 }
 # Re-read signed channel manifests on each install/update action. A complete
 # cached set is safe to use offline, but cannot prove it is the latest.
 if(-not(Test-Path -LiteralPath $Installer -PathType Leaf)){throw 'The manager executable could not be found to download signed component packages.'}
 $sessionFolder=Join-Path $store 'Sessions';[void][IO.Directory]::CreateDirectory($sessionFolder)
 $resultPath=Join-Path $sessionFolder ('component-stage-test-'+[guid]::NewGuid().ToString('N')+'.json')
 $payloadDestination=Join-Path $sessionFolder ('PayloadFusion-staged-'+[guid]::NewGuid().ToString('N'))
 $launcherSemVer=GetOptiShadeManagerCompatibilityVersion
 $selection=$wanted -join ','
 $arguments='--component-stage-test "'+$resultPath+'" "'+$payloadDestination+'" "'+$selection+'" "'+$launcherSemVer+'"'
 $worker=$null;$completed=$false
 try{
  if($progress){& $progress 'Downloading and verifying signed OptiShade components…' 0 0}
  $worker=Start-Process -FilePath $Installer -ArgumentList $arguments -WindowStyle Hidden -PassThru -ErrorAction Stop
  while(-not $worker.WaitForExit(250)){
   PumpManagerDispatcher
   AssertOperationNotCancelled
  }
  if($worker.ExitCode -ne 0 -or -not(Test-Path -LiteralPath $resultPath -PathType Leaf)){
   $detail='The signed component package download or verification did not complete.'
   if(Test-Path -LiteralPath $resultPath -PathType Leaf){try{$failed=Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8|ConvertFrom-Json;if($failed.Message){$detail=[string]$failed.Message};if(@($failed.Failures).Count){$detail+=' '+(@($failed.Failures) -join '; ')}}catch{}}
   throw $detail
  }
  $result=Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8|ConvertFrom-Json
  if(-not $result.OK -or -not $result.ComposedPayload){throw ('Signed package staging failed: '+[string]$result.Message+' '+(@($result.Failures) -join '; '))}
  $composed=[IO.Path]::GetFullPath([string]$result.ComposedPayload);$sessionRoot=[IO.Path]::GetFullPath($sessionFolder).TrimEnd('\')
  if(-not [string]::Equals([IO.Path]::GetDirectoryName($composed).TrimEnd('\'),$sessionRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($composed) -notmatch '^PayloadFusion-staged-[0-9a-f]{32}$' -or -not(Test-Path -LiteralPath $composed -PathType Container) -or ((Get-Item -LiteralPath $composed -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'The signed package worker returned an unsafe installer payload path.'}
  if(-not(Test-Path -LiteralPath (Join-Path $composed 'files.json') -PathType Leaf) -or -not(Test-Path -LiteralPath (Join-Path $composed 'OptiShadeData/BuildIdentity.json') -PathType Leaf)){throw 'The verified Core package is missing required installer metadata.'}
  $previousPayload=$script:sessionComposedPayload
  $script:Payload=$composed;$script:sessionComposedPayload=$composed
  $script:componentPayloadIds=@($result.Packages|ForEach-Object {[string]$_.Component}|Select-Object -Unique)
  $script:componentPackageReleases=@($result.Packages)
  if($previousPayload -and -not [string]::Equals([IO.Path]::GetFullPath([string]$previousPayload),$composed,[StringComparison]::OrdinalIgnoreCase)){RemoveOptiShadeSessionPayload $previousPayload}
  $completed=$true
  WriteInstallerLog ('Verified online component payload activated: '+($script:componentPayloadIds -join ', '))
 }finally{
  if($worker -and -not $worker.HasExited){try{$worker.Kill();[void]$worker.WaitForExit(5000)}catch{}}
  if(Test-Path -LiteralPath $resultPath -PathType Leaf){Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue}
  if(-not $completed -and (Test-Path -LiteralPath $payloadDestination -PathType Container)){RemoveOptiShadeSessionPayload $payloadDestination}
 }
}
function SetOnlineComponentPackageReceipt([string]$ManifestPath,[string]$Component){
 if(-not $script:modularDistribution){return}
 $id=GetOptiShadeModularUpdatePackageId $Component
 if(-not $id){return}
 $packageIds=if($id -eq 'OptiShade.Providers'){@('OptiShade.Providers.AMD','OptiShade.Providers.Intel')}else{@($id)}
 $releases=@(foreach($packageId in $packageIds){@($script:componentPackageReleases|Where-Object {[string]$_.Component -ceq $packageId}|Select-Object -First 1)})
 if($releases.Count -ne $packageIds.Count){WriteInstallerLog ('Verified online package version was not available for the installed receipt: '+$id);return}
 $m=ReadOptiShadeState $ManifestPath
 $records=@($m.OnlineComponentPackages|Where-Object {$_ -and [string]$_.Id -notin $packageIds})
 foreach($release in $releases){$records+=,[pscustomobject]@{Id=[string]$release.Component;Version=[string]$release.Version;SHA256=([string]$release.SHA256).ToLowerInvariant()}}
 $m|Add-Member -NotePropertyName OnlineComponentPackages -NotePropertyValue $records -Force
 WriteState $m $ManifestPath
}
function RefreshModularComponentChannels{
 $script:onlineComponentVersions=@{};$script:onlineComponentChannelFailures=@()
 if(-not $script:modularDistribution -or -not(Test-Path -LiteralPath $Installer -PathType Leaf)){return}
 $ids=[Collections.Generic.List[string]]::new()
 foreach($game in @($script:libraryGames|Where-Object {$_.Installed})){
  try{
   $target=GetFusionGameTargetFolder $game $store;$mp=ManifestPath $store $target
   if(-not(Test-Path -LiteralPath $mp -PathType Leaf)){continue}
   $m=ReadOptiShadeState $mp
   if($m.Status -cne 'Installed' -or (GetOptiShadeManagerStatusKey $m.Game) -cne (GetOptiShadeManagerStatusKey $target)){continue}
   foreach($component in @('Core')+@(GetOptiShadeAddonSelection $m)){
    $id=GetOptiShadeModularUpdatePackageId ([string]$component)
    if($id -and -not $ids.Contains($id)){$ids.Add($id)}
   }
  }catch{WriteInstallerLog ('Component release check skipped an unverified receipt for '+[string]$game.Name+': '+$_.Exception.GetBaseException().Message)}
 }
 if(-not $ids.Count){return}
 $sessions=Join-Path $store 'Sessions';[void][IO.Directory]::CreateDirectory($sessions)
 $resultPath=Join-Path $sessions ('component-channel-check-'+[guid]::NewGuid().ToString('N')+'.json')
 $arguments='--component-channel-check "'+$resultPath+'" "'+(GetOptiShadeManagerCompatibilityVersion)+'" "'+($ids -join ',')+'"'
 $worker=$null
 try{
  $worker=Start-Process -FilePath $Installer -ArgumentList $arguments -WindowStyle Hidden -PassThru -ErrorAction Stop
  try{$worker.PriorityClass=[Diagnostics.ProcessPriorityClass]::BelowNormal}catch{}
  while(-not $worker.WaitForExit(250)){PumpManagerDispatcher;AssertOperationNotCancelled}
  if(Test-Path -LiteralPath $resultPath -PathType Leaf){
   $result=Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8|ConvertFrom-Json
   foreach($item in @($result.ChannelVersions)){$script:onlineComponentVersions[[string]$item.Component]=$item}
   $script:onlineComponentChannelFailures=@($result.Failures|Where-Object {-not [string]::IsNullOrWhiteSpace([string]$_)})
   WriteInstallerLog ('Signed modular component channels checked: '+(@($result.ChannelVersions|ForEach-Object {([string]$_.Component)+' '+[string]$_.Version}) -join ', ')+'; failures='+($script:onlineComponentChannelFailures -join '; '))
  }else{$script:onlineComponentChannelFailures=@('No component-channel check result was returned.')}
 }catch{$script:onlineComponentChannelFailures=@($_.Exception.GetBaseException().Message);WriteInstallerLog ('Signed component channel check failed: '+$_.Exception.GetBaseException().Message)}
 finally{if($worker -and -not $worker.HasExited){try{$worker.Kill();[void]$worker.WaitForExit(5000)}catch{}};if(Test-Path -LiteralPath $resultPath -PathType Leaf){Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue}}
}
function FinishOptionalDownloads($Manifest,$Plan){
 $presetWarning=''
 $issues=New-Object 'System.Collections.Generic.List[string]'
 if(UseOptionalDlss $Manifest $Plan){try{EnsureNeuralRuntime (ManifestPath $store $path.Text) (GetFusionGpu) $progress}catch{$issues.Add('Neural model: '+$_.Exception.Message)};try{if(-not(Test-Path -LiteralPath (Join-Path $path.Text 'X-Plane.exe'))){$profile=if($Manifest.PSObject.Properties['DlssRuntimeProfile']){[string]$Manifest.DlssRuntimeProfile}else{'nvidia-310.9.16'};InstallNvidia $path.Text $progress $profile}}catch{$issues.Add('NVIDIA files: '+$_.Exception.Message)}}
 if(-not $Manifest.PSObject.Properties['IncludeEffects'] -or $Manifest.IncludeEffects){try{$null=InstallAllEffects $path.Text (Join-Path $PSScriptRoot 'EffectPackages.ini') $progress}catch{$issues.Add('Additional FX: '+$_.Exception.Message)}}
 elseif($Manifest.PSObject.Properties['FxPresetRelative'] -and $Manifest.FxPresetRelative){try{$progress.Invoke('Installing the selected INI shader dependencies...');$presetWarning=InstallPresetDependencies (OwnedPath $path.Text $Manifest.FxPresetRelative) $path.Text (Join-Path $PSScriptRoot 'EffectPackages.ini')}catch{$issues.Add('Preset FX: '+$_.Exception.Message)}}
 if($issues.Count){
   $script:operationAttention=$true
  $mp=ManifestPath $store $path.Text;$m=ReadOptiShadeState $mp
  $m|Add-Member -NotePropertyName Downloads -NotePropertyValue 'Pending' -Force;WriteState $m $mp
  foreach($issue in $issues){WriteInstallerLog $issue}
  $status.Text='OptiShade is installed. Some optional downloads are unfinished; installed effects can still be used. Choose Retry unfinished downloads. Details: %LOCALAPPDATA%\OptiShade\Installer.log'
  }else{CompleteDownloads;if($Manifest.PSObject.Properties['FxPresetRelative'] -and $Manifest.FxPresetRelative){$status.Text='Preset installed. Select '+[IO.Path]::GetFileName($Manifest.FxPresetRelative)+' in game under Image effects > Saved look.'}}
 WriteInstallerLog $status.Text
  try{$updated=CheckGameCompatibility $Manifest.LaunchExe;SaveFusionCompatibility $path.Text $updated;if((UseOptionalDlss $Manifest $Plan) -and $updated.NeuralRuntime.State -ne 'Verified file'){$script:operationAttention=$true;$status.Text='OptiShade image effects are installed. Neural rendering is NOT ready: '+$updated.NeuralRuntime.Message+' Choose Retry unfinished downloads to retry the GPU-matched model download.';if($issues.Count){$status.Text+=' Some optional downloads also failed; use Retry unfinished downloads.'}}}catch{WriteInstallerLog ('Post-install diagnostics: '+$_.Exception.Message)}
  if($presetWarning){$script:operationAttention=$true;$status.Text+=' '+$presetWarning;WriteInstallerLog $presetWarning}
}

function CheckGameCompatibility([string]$exe){
 $script:gpu=GetFusionGpu
 AssertMsfsNvidiaTarget $exe $script:gpu
 $root=$path.Text
 if($script:gameRoot -and $root.StartsWith($script:gameRoot+'\',[StringComparison]::OrdinalIgnoreCase)){$root=$script:gameRoot}
 $plan=GetFusionCompatibility $root $exe $script:gpu $script:gameLauncher
 $plan|Add-Member -NotePropertyName DriverVersions -NotePropertyValue @($script:gpu.Drivers) -Force
 $plan|Add-Member -NotePropertyName NeuralRuntime -NotePropertyValue (GetNeuralRuntimeStatus $path.Text $script:gpu) -Force
 $installed=@(GetFusionInstalledVersions $path.Text)
 $plan|Add-Member -NotePropertyName InstalledRuntimes -NotePropertyValue $installed
 $form.FindName('Compatibility').Text=FormatFusionCompatibility $plan
 foreach($runtime in $installed){$form.FindName('Compatibility').Text+="`nStored: $($runtime.File) - $($runtime.Version) (not proof it is running)"}
 return $plan
}
function GetSelectedMethod{
 $selection=$form.FindName('Method').SelectedItem
 if($selection -and $selection.Tag -in @('auto','winmm.dll','dxgi.dll','d3d12.dll','version.dll','dbghelp.dll')){return [string]$selection.Tag}
 return 'auto'
}
function GetManifestMethodRendererApi([string]$Method,[string]$EffectiveMethod,$Manifest){
 $apiCandidates=@()
 try{if($Manifest.LaunchExe -and (Test-Path -LiteralPath $Manifest.LaunchExe)){$apiCandidates=(GetOptiShadeExecutableIdentity $Manifest.LaunchExe).ApiCandidates}}catch{}
 $renderer=GetOptiShadeMethodRendererApi $Method $EffectiveMethod $apiCandidates -Executable ([string]$Manifest.LaunchExe)
 if($Method -eq 'auto' -and $renderer -eq 'Auto' -and $Manifest.PSObject.Properties['RendererApi']){
  if($Manifest.RendererApi -eq 'directx'){return 'DirectX'}
  if($Manifest.RendererApi -eq 'vulkan'){return 'Vulkan'}
 }
 return $renderer
}
function SyncMethodSelection{
 $choice='auto'
 try{$cached=GetCachedManagerGameStatus $path.Text;if($cached.Manifest){$choice=GetOptiShadeStoredMethod $cached.Manifest}}catch{}
 foreach($item in $form.FindName('Method').Items){if($item.Tag -eq $choice){$form.FindName('Method').SelectedItem=$item;return}}
}
function RefreshXPlaneRouteSelection {
 $panel=$form.FindName('XPlaneRoutePanel');$choice=$form.FindName('XPlaneGraphicsRoute')
 $isXPlane=$false
 try{$isXPlane=$path.Text -and (Test-Path -LiteralPath (OwnedPath $path.Text 'X-Plane.exe') -PathType Leaf)}catch{}
 $panel.Visibility=if($isXPlane){'Visible'}else{'Collapsed'}
 if(-not $isXPlane){return}
 try{
  $route=GetOptiShadeXPlaneRoute $path.Text
  foreach($item in $choice.Items){if($item.Tag -eq $route){$choice.SelectedItem=$item;break}}
  $form.FindName('XPlaneRouteStatus').Text='Saved route: '+$choice.SelectedItem.Content+'. Changes apply after restarting X-Plane.'
 }catch{$form.FindName('XPlaneRouteStatus').Text=$_.Exception.Message}
}
$form.FindName('SaveXPlaneRoute').Add_Click({
 if($script:busy){return}
 try{
  $selected=$form.FindName('XPlaneGraphicsRoute').SelectedItem
  if(-not $selected){throw 'Select a graphics route first.'}
  SetOptiShadeXPlaneRoute $path.Text ([string]$selected.Tag)
  $form.FindName('XPlaneRouteStatus').Text='Saved. Restart X-Plane to use '+$selected.Content+'.'
  $status.Text='X-Plane graphics route saved. Restart X-Plane to apply.'
 }catch{$form.FindName('XPlaneRouteStatus').Text='Not saved: '+$_.Exception.Message}
})
$form.FindName('CheckCompatibility').Add_Click({ShowCompatibilityPopup})
$script:pathRefreshTimer=[Windows.Threading.DispatcherTimer]::new();$script:pathRefreshTimer.Interval=[TimeSpan]::FromMilliseconds(160)
RegisterOptiShadeManagerTimer $script:pathRefreshTimer {
 $script:pathRefreshTimer.Stop()
 $form.FindName('Compatibility').Text='Check this game before installing. Automatic setup also checks again at install time.'
 RequestManagerStatusScan;SyncMethodSelection;RefreshHomeState;RefreshXPlaneRouteSelection
 if($form.FindName('ComponentsPage').Visibility -eq 'Visible'){RefreshComponentsGameSelector;RefreshAddonCards}
 if($form.FindName('KeybindsPage').Visibility -eq 'Visible'){RefreshMenuKeys}
}
$path.Add_TextChanged({if($script:allFxDraft -and $script:allFxDraft.Game -ne (GetOptiShadeManagerStatusKey $path.Text)){$script:allFxDraft=$null};$script:pathRefreshTimer.Stop();$script:pathRefreshTimer.Start()})
$form.FindName('ResetDownloadCache').Add_Click({ShowDownloadCachePopup})
function CompleteDownloads{$mp=ManifestPath $store $path.Text;$m=ReadOptiShadeState $mp;$m|Add-Member -NotePropertyName Downloads -NotePropertyValue 'Complete' -Force;WriteState $m $mp;$status.Text='Install complete. You can close the manager and start your game.'}
function ShowPage([string]$name){
 if($name -ne 'Keybinds'){CancelSnapshotCapture;CancelFeatureCapture;$script:captureState.HotSwap=$false;$form.FindName('ChangeHotSwapKey').Content='Change'}
 if($name -ne 'Keybinds' -and $script:captureState.MenuKey){$script:captureState.MenuKey=$false;$form.FindName('ChangeMenuKey').Content='Change'}
 if($name -ne 'Search'){$script:managerReturnPage=$name}
 foreach($page in @('Home','Library','Setup','Components','Updates','Keybinds','Settings','Nvidia','Troubleshooting','Search')){$form.FindName($page+'Page').Visibility=if($page -eq $name){'Visible'}else{'Collapsed'}}
 $pageTitles=@{Nvidia='NVIDIA settings';Home='Home';Library='Library';Setup='Setup';Components='Components';Updates='Update Manager';Keybinds='Keybinds';Settings='Settings';Troubleshooting='Troubleshooting';Search='Search'}
 $pageSubtitles=@{Nvidia='Review per-game driver presets before launch.';Home='Manage OptiShade across your games from one place.';Library='Find, install and manage OptiShade for your games.';Setup='Install or repair OptiShade for the selected game.';Components='Choose and review the components installed for this game.';Updates='Review and update OptiShade across your installed games.';Keybinds='Set shortcuts for the manager and in-game tools.';Settings='Customize OptiShade and manage app preferences.';Troubleshooting='Diagnose issues and collect a report for a selected game.';Search='Find a setting or tool in OptiShade.'}
 if($pageTitles.ContainsKey($name)){$form.FindName('HeaderBuildType').Text=$pageTitles[$name];$form.FindName('HeaderSubtitle').Text=$pageSubtitles[$name]}
 if($name -eq 'Components' -and $script:pathRefreshTimer){$script:pathRefreshTimer.Stop();$script:pathRefreshTimer.Start()}
 foreach($entry in @(@('HomeNav','Home'),@('LibraryNav','Library'),@('SetupNav','Setup'),@('ComponentsNav','Components'),@('UpdatesNav','Updates'),@('KeybindsNav','Keybinds'),@('TroubleshootingNav','Troubleshooting'),@('SettingsNav','Settings'),@('NvidiaNav','Nvidia'))){$nav=$form.FindName($entry[0]);$nav.Background=if($entry[1] -eq $name){$form.FindResource('NavPurple')}else{'Transparent'};$nav.BorderBrush=if($entry[1] -eq $name){'#9652EB'}else{'Transparent'}}
 if($name -eq 'Updates'){RefreshUpdateManager}
 RefreshUpdateNavigation
}
$script:libraryGames=@()
# Search indexes page metadata and the already-scanned library, never filesystem contents.
$script:runtimeTask=$null;$script:autoIntent=$null;$script:runtimeTaskIntent=$null;$script:runtimeTaskOperation=''
$runtimeTimer=[Windows.Threading.DispatcherTimer]::new();$runtimeTimer.Interval=[TimeSpan]::FromMilliseconds(200)
function StartManagerAutoSession($Manifest,[switch]$CurrentSession,[switch]$Off,[switch]$ObserveOnly){
 if($Manifest.Status -ne 'Installed'){
  $observedStatus=if($Manifest -and $Manifest.Status){[string]$Manifest.Status}else{'missing'}
  throw ("Live monitoring requires a completed installation receipt; recorded status='{0}', game='{1}'. Install and prepare OptiShade before requesting Auto." -f $observedStatus,[string]$Manifest.Game)
 }
 $bound=$script:autoIntent
 $reuse=$CurrentSession -and $bound -and -not $bound.Terminal -and $bound.Pid -and [string]::Equals([string]$Manifest.Game,[string]$bound.Game,[StringComparison]::OrdinalIgnoreCase)
 $identity=if($reuse){[pscustomobject]@{Path=$bound.Executable;SHA256=$bound.ExecutableHash}}else{GetOptiShadeRenderingExecutable $Manifest -AllowRecordedUnknown:$ObserveOnly -ForLiveObservation:$ObserveOnly}
 # Observe-only binds the rendering process path/PID/birth, never the launch helper.
 # A denied PE read leaves its hash unknown; feature-changing paths stay strict.
 $desired=if($Off){CopyOptiShadeAutoDesired}else{GetOptiShadeAutoDesiredForManifest $Manifest $Manifest.AutoCompatibility.Desired}
 if($CurrentSession){$desired.enabled=$true}
 if($Off){$desired.enabled=$false;foreach($name in @('nr','upscaling','frameGeneration')){$desired.$name='off'}}
 $minimum=if($CurrentSession){'0'}else{[DateTime]::UtcNow.ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture)}
 $script:autoIntent=NewOptiShadeAutoSessionIntent $Manifest.Game $identity $desired $minimum
 if($reuse){$script:autoIntent.Pid=$bound.Pid;$script:autoIntent.Birth=$bound.Birth}
 $script:autoIntent|Add-Member HintContext '' -Force
 $script:autoIntent|Add-Member ObserveOnly ([bool]$ObserveOnly) -Force
 $runtimeTimer.Start()
}
function StartManagerRuntimeSnapshot($Intent=$null){
 if($script:runtimeTask){return}
 $script:runtimeTaskPath=$path.Text;$script:runtimeTaskIntent=$Intent;$script:runtimeTaskOperation='snapshot'
 $receiptPath=ManifestPath $store $script:runtimeTaskPath
 if($Intent){$script:runtimeTask=[OptiShadeControlClient]::BeginSnapshot($Intent.Game,$Intent.Executable,$Intent.NotBeforeBirth,[uint32]$Intent.Pid,$Intent.Birth,$receiptPath)}
 else{$script:runtimeTask=[OptiShadeControlClient]::BeginSnapshot($script:runtimeTaskPath,$null,'0',[uint32]0,$null,$receiptPath)}
 $form.FindName('RefreshRuntimeStatus').IsEnabled=$false;$runtimeTimer.Start()
}
$form.FindName('RefreshRuntimeStatus').Add_Click({
 if($script:runtimeTask -or $script:busy){return}
 StartManagerRuntimeSnapshot $script:autoIntent
 $form.FindName('RuntimeStatus').Text='Reading the selected game session...'
})
RegisterOptiShadeManagerTimer $runtimeTimer {
 if($script:runtimeTask -and $script:runtimeTask.IsCompleted){
  $task=$script:runtimeTask;$intent=$script:runtimeTaskIntent;$operation=$script:runtimeTaskOperation
  $script:runtimeTask=$null;$script:runtimeTaskIntent=$null;$script:runtimeTaskOperation=''
  try{
   if($script:runtimeTaskPath -cne $path.Text){throw 'Selected installation changed. The previous Auto monitor has ended.'}
   $value=$task.GetAwaiter().GetResult()|ConvertFrom-Json
   if($operation -eq 'snapshot' -and $value.mfg -and $value.installerReceipt){
    $value=AddOptiShadeRuntimeInstallerEvidence $value $value.installerReceipt $script:runtimeTaskPath
    $value.PSObject.Properties.Remove('installerReceipt')
   }
   if($intent -and -not [object]::ReferenceEquals($intent,$script:autoIntent)){return}
   if($intent -and $operation -eq 'configure'){
    CompleteOptiShadeAutoSessionCommand $intent $value
    $intent.NextPollUtc=[DateTime]::UtcNow.AddSeconds(1)
    $form.FindName('RuntimeStatus').Text='Auto request: '+$intent.State+'. '+$intent.Reason
   }else{
    $form.FindName('RuntimeStatus').Text=FormatOptiShadeAutoRuntimeSnapshot $value
    if($intent){
     $action=GetOptiShadeAutoSessionAction $intent $value;$intent.SnapshotFailures=0
     $hintContext=GetOptiShadeAutoPreparationHintContext $value
     if(-not $script:busy -and $value.auto.renderingAdapterLuid -and $hintContext -cne $intent.HintContext){
      try{[void](SaveOptiShadeAutoRenderingHint (ManifestPath $store $intent.Game) $intent $value $script:gpu);$intent.HintContext=$hintContext}catch{WriteInstallerLog ('Auto preparation hint was not saved: '+$_.Exception.Message)}
     }
     if($action.Operation -eq 'configure'){
      $script:runtimeTaskPath=$path.Text;$script:runtimeTaskIntent=$intent;$script:runtimeTaskOperation='configure'
      $script:runtimeTask=[OptiShadeControlClient]::Begin([uint32]$intent.Pid,[string]$action.Request)
     }else{$intent.NextPollUtc=[DateTime]::UtcNow.AddSeconds(2)}
    }
   }
  }catch{
   $reason=$_.Exception.GetBaseException().Message
   if($intent -and [object]::ReferenceEquals($intent,$script:autoIntent)){
    if($script:runtimeTaskPath -cne $path.Text){$intent.Terminal=$true;$intent.State='selection_changed'}
    elseif($operation -eq 'configure' -and $intent.LastRequest -and $intent.TransportRetries -lt 2){
     # Retrying a transport failure reuses the exact serialized command/id.
     # A revised context is only submitted after a new bound snapshot.
     $intent.TransportRetries++;$intent.State='retrying_transport';$intent.NextPollUtc=[DateTime]::UtcNow.AddSeconds(1)
    }elseif($intent.Pid){$intent.SnapshotFailures++;if($operation -eq 'configure' -or $intent.SnapshotFailures -ge 3){$intent.Terminal=$true;$intent.State='session_unavailable'}else{$intent.NextPollUtc=[DateTime]::UtcNow.AddSeconds(2);$intent.State='retrying_bound_session'}}
    elseif([DateTime]::UtcNow -ge $intent.DiscoveryDeadlineUtc){$intent.Terminal=$true;$intent.State='session_unavailable'}
    else{$intent.NextPollUtc=[DateTime]::UtcNow.AddSeconds(2);$intent.State='waiting_for_runtime'}
    $intent.Reason=$reason
   }
   $form.FindName('RuntimeStatus').Text='Auto/runtime status: '+$reason
  }finally{if(-not $script:runtimeTask){$form.FindName('RefreshRuntimeStatus').IsEnabled=$true}}
 }
 if($script:busy -or $script:runtimeTask){return}
 $intent=$script:autoIntent
 if(-not $intent -or $intent.Terminal){$runtimeTimer.Stop();return}
 if(-not [string]::Equals([string]$path.Text,[string]$intent.Game,[StringComparison]::OrdinalIgnoreCase)){$intent.Terminal=$true;$intent.State='selection_changed';$runtimeTimer.Stop();return}
 if([DateTime]::UtcNow -lt $intent.NextPollUtc){return}
 if($intent.State -eq 'retrying_transport' -and $intent.LastRequest){
  $script:runtimeTaskPath=$path.Text;$script:runtimeTaskIntent=$intent;$script:runtimeTaskOperation='configure';$script:runtimeTask=[OptiShadeControlClient]::Begin([uint32]$intent.Pid,[string]$intent.LastRequest)
 }else{StartManagerRuntimeSnapshot $intent}
}
$form.Add_Closed({$runtimeTimer.Stop();$script:autoIntent=$null})

function UpdateManagerSearch {
 $query=$form.FindName('ManagerSearch').Text.Trim()
 $items=@(
  @{Title='My games - launch and installation';Terms='library play setup install';Page='Home'},
  @{Title='Components - FG, MFG and NVIDIA runtime';Terms='frame generation multiplier older gpu neural rendering dlss';Page='Components'},
  @{Title='Update Manager';Terms='updates components glass cockpit versions update all';Page='Updates'},
  @{Title='Help & recovery - reports, repair and restore';Terms='diagnostics troubleshooter zip crash black screen flicker reset uninstall';Page='Troubleshooting'},
  @{Title='Game shortcuts';Terms='keys insert menu hotswap snapshot';Page='Keybinds'},
  @{Title='Settings & shortcuts';Terms='update beta stable channel discord';Page='Settings'})
 foreach($game in @($script:libraryGames)){if($game){$items+=@{Title=$game.Name+' - manage installation';Terms=$game.Launcher+' '+$game.InstallFolder;Page='Setup';Game=$game}}}
 $results=@($items|Where-Object {(-not $query) -or ($_.Title+' '+$_.Terms).IndexOf($query,[StringComparison]::OrdinalIgnoreCase) -ge 0}|ForEach-Object {[pscustomobject]$_})
 $form.FindName('ManagerSearchResults').ItemsSource=$results
 $form.FindName('ManagerSearchResults').SelectedIndex=if($results.Count){0}else{-1}
 $form.FindName('OpenSearchResult').IsEnabled=$results.Count -gt 0
 $form.FindName('ManagerSearchStatus').Text=if($results.Count){'Select a result and press Open, or double-click it.'}else{'No matching page or scanned game. Try NR, MFG, report, keys or update.'}
}
function OpenManagerSearchResult {
 $item=$form.FindName('ManagerSearchResults').SelectedItem
 if(-not $item){return}
 if($item.PSObject.Properties['Game'] -and $item.Game){SelectGame $item.Game}else{ShowPage $item.Page}
}
$form.FindName('FindControl').Add_Click({ShowPage 'Search';UpdateManagerSearch;[void]$form.FindName('ManagerSearch').Focus()})
$form.FindName('ManagerSearch').Add_TextChanged({UpdateManagerSearch})
$form.FindName('OpenSearchResult').Add_Click({OpenManagerSearchResult})
$form.FindName('ManagerSearchResults').Add_MouseDoubleClick({OpenManagerSearchResult})
$form.FindName('CloseSearch').Add_Click({ShowPage $(if($script:managerReturnPage){$script:managerReturnPage}else{'Home'});[void]$form.FindName('FindControl').Focus()})
$form.FindName('SearchPage').Add_PreviewKeyDown({param($sender,$event)
 if($event.Key -eq 'Escape'){$event.Handled=$true;ShowPage $(if($script:managerReturnPage){$script:managerReturnPage}else{'Home'});[void]$form.FindName('FindControl').Focus()}
 elseif($event.Key -eq 'Return'){$event.Handled=$true;OpenManagerSearchResult}
})
function GetDetectedStoreDisplay($game){
 $source=[string]$game.Launcher;$folder=[string]$game.Folder
 if($source -match '(?i)^steam$'){return 'Steam'}
 if($source -match '(?i)^epic$|epic games'){return 'Epic Games'}
 if($source -match '(?i)^xbox$|microsoft|store'){return 'Xbox / Microsoft Store'}
 if($source -match '(?i)^gog|good old games'){return 'GOG Galaxy'}
 if($source -match '(?i)^ubisoft|uplay'){return 'Ubisoft Connect'}
 if($source -match '(?i)^ea app|^origin$'){return 'EA app'}
 if($source -match '(?i)^battle\.net|^blizzard$'){return 'Battle.net'}
 if($source -match '(?i)^amazon'){return 'Amazon Games'}
 if($source -match '(?i)^rockstar'){return 'Rockstar Games Launcher'}
 if($source -match '(?i)^laminar'){return 'Laminar Research'}
 if($folder -match '(?i)\\steamapps\\common\\'){return 'Steam'}
 if($folder -match '(?i)\\Epic Games\\'){return 'Epic Games'}
 if($folder -match '(?i)\\XboxGames\\|\\WindowsApps\\|\\MSIXVC\\'){return 'Xbox / Microsoft Store'}
 if($folder -match '(?i)\\GOG Galaxy\\Games\\|\\GOG Games\\'){return 'GOG Galaxy'}
 if($folder -match '(?i)\\Ubisoft Game Launcher\\games\\|\\Ubisoft Connect\\games\\'){return 'Ubisoft Connect'}
 if($folder -match '(?i)\\EA Games\\|\\Origin Games\\'){return 'EA app'}
 if($folder -match '(?i)\\Battle\.net\\Games\\|\\Battle\.net\\'){return 'Battle.net'}
 if($folder -match '(?i)\\Amazon Games\\(Library|Games)\\'){return 'Amazon Games'}
 if($folder -match '(?i)\\Rockstar Games\\'){return 'Rockstar Games Launcher'}
 if($source -and $source -notmatch '(?i)^added by you$'){return $source}
 return 'Custom location'
}
function SetSelectedFusionGame($game){
 if(-not $game){return ''}
 $libraryKey=GetFusionLibraryGameKey $game;if($libraryKey -and $script:removedGames.ContainsKey($libraryKey)){[void]$script:removedGames.Remove($libraryKey);SaveLibraryPreferences}
 $cached=GetCachedManagerGameStatus $game;$target=if($cached){$cached.Folder}else{[string]$game.Folder}
 $script:gameRoot=[string]$game.Folder;$script:gameLauncher=[string]$game.Launcher;$path.Text=$target
 $title=[string]$game.Name;if(-not $title){$title=[IO.Path]::GetFileName($target)}
 $form.FindName('SelectedTitle').Text=$title
 if($game.Thumbnail){$form.FindName('SelectedIcon').Source=$game.Thumbnail}
 $storeText=GetDetectedStoreDisplay $game
 $detectedStore=$form.FindName('DetectedStore');if($detectedStore){$detectedStore.Text=$storeText}
 $componentGame=$form.FindName('ComponentsSelectedGame');if($componentGame){$componentGame.Text=$title+' · '+$storeText}
 $componentPath=$form.FindName('ComponentsTargetPath');if($componentPath){$componentPath.Text='Install target: '+$target}
 return $target
}
function ClearComponentsTargetSummary{
 $componentGame=$form.FindName('ComponentsSelectedGame');if($componentGame){$componentGame.Text='Choose a game'}
 $componentPath=$form.FindName('ComponentsTargetPath');if($componentPath){$componentPath.Text='Install target: choose a game'}
}
# Update Manager coordinates the existing installers; it never writes game files itself.
$script:updateResults=@{}
$script:updateResultScanGeneration=@{}
# Completed updates whose fresh scan finished but could not confirm the
# installation, with the reason, so the banner never says Verifying forever.
$script:updateResultUnconfirmed=@{}
$script:updateBatchKeys=@()
$script:updateFollowUp=$null
$script:localComponentPackage=$null
# One worker owns status verification. Navigation only uses its last snapshot.
$script:managerStatusRevision=0
$script:managerStatusState=NewOptiShadeManagerStatusState {
 param($context)
 $shell=NewOptiShadeManagerWorker
 try{
  [void]$shell.AddScript({param($module,$context) . $module;InvokeOptiShadeManagerSnapshot $context}).AddArgument((Join-Path $PSScriptRoot 'manager-status.ps1')).AddArgument($context)
  [pscustomobject]@{Shell=$shell;Async=$shell.BeginInvoke()}
 }catch{RemoveOptiShadeManagerWorker $shell;throw}
} {param($handle) RemoveOptiShadeManagerWorker $handle.Shell} {param($handle) [void]$script:managerWorkers.Remove($handle.Shell);[OptiShadeManagerWorkerCleanup]::Release($handle.Shell)}
function GetCachedManagerGameStatus($GameOrFolder){
 if(-not $script:managerStatusState -or -not $script:managerStatusState.Snapshot){return $null}
 $folder=if($GameOrFolder -is [string]){$GameOrFolder}else{[string]$GameOrFolder.Folder}
 $key=GetOptiShadeManagerStatusKey $folder
 if($key -and $script:managerStatusState.Snapshot.ByPath.ContainsKey($key)){return $script:managerStatusState.Snapshot.ByPath[$key]}
 return $null
}
function RequestManagerStatusScan([switch]$Force,[switch]$DuringOperation){
 if(-not $script:managerStatusState -or $script:managerStatusState.Stopped -or ($script:busy -and -not $DuringOperation)){return}
 if($Force){$script:managerStatusRevision++}
 $games=[Collections.Generic.List[object]]::new()
 foreach($game in $script:libraryGames){$games.Add([pscustomobject]@{Name=[string]$game.Name;Folder=[string]$game.Folder;InstallFolder=[string]$game.InstallFolder;Launcher=[string]$game.Launcher})}
 $selected=[string]$path.Text
 if($selected -and -not @($games|Where-Object { (GetOptiShadeManagerStatusKey $_.Folder) -eq (GetOptiShadeManagerStatusKey $selected) -or (GetOptiShadeManagerStatusKey $_.InstallFolder) -eq (GetOptiShadeManagerStatusKey $selected)}).Count){$games.Add([pscustomobject]@{Name=[IO.Path]::GetFileName($selected.TrimEnd('\'));Folder=$selected;InstallFolder=$selected;Launcher=''})}
 # The worker fills this in while it scans; the Update Manager shows it live.
 $script:managerStatusProgress=[hashtable]::Synchronized(@{Total=$games.Count;Done=0;Current=''})
 $script:managerStatusRequestedUtc=[DateTime]::UtcNow
 $context=[pscustomobject]@{Progress=$script:managerStatusProgress;Key=([string]$script:managerStatusRevision+'|'+(GetOptiShadeManagerStatusKey $selected));ModuleRoot=$PSScriptRoot;Payload=$Payload;Store=$store;Games=$games.ToArray();SelectedFolder=$selected;Release=$script:glassCockpitLatestRelease;AtmosphereRelease=$script:atmosphereLatestRelease;LocalPackage=$script:localComponentPackage;Gpu=$script:gpu;OnlineComponentVersions=$script:onlineComponentVersions;ModularDistribution=[bool]$script:modularDistribution;ComponentCheck=(Get-Command GetComponentUpdateIds).Definition}
 RequestOptiShadeManagerStatus $script:managerStatusState $context
}
$script:managerStatusTimer=[Windows.Threading.DispatcherTimer]::new();$script:managerStatusTimer.Interval=[TimeSpan]::FromMilliseconds(100)
$script:managerStatusOrphanSince=$null;$script:managerStatusOrphanRetries=0
RegisterOptiShadeManagerTimer $script:managerStatusTimer {
 if($script:busy){return}
 if(StopStalledOptiShadeManagerStatus $script:managerStatusState ([TimeSpan]::FromMinutes(3))){WriteInstallerLog 'Component verification worker exceeded 3 minutes and was stopped.'}
 # Self-heal a verification that no running or queued work can complete.
 if(TestOptiShadeManagerStatusOrphaned $script:managerStatusState){
  $now=[DateTime]::UtcNow
  if(-not $script:managerStatusOrphanSince){$script:managerStatusOrphanSince=$now}
  elseif(($now-$script:managerStatusOrphanSince).TotalSeconds -ge 3){
   $script:managerStatusOrphanSince=$null
   $state=$script:managerStatusState
   WriteInstallerLog ('Component verification had no current result (requested key='+[string]$state.Key+'; snapshot key='+$(if($state.Snapshot){[string]$state.Snapshot.Key}else{'none'})+'); retry '+($script:managerStatusOrphanRetries+1)+'.')
   if($script:managerStatusOrphanRetries -lt 3){$script:managerStatusOrphanRetries++;RequestManagerStatusScan -Force}
   else{$state.Error='Component verification did not produce a current result. Use Check for updates to retry.';RefreshHeaderComponentUpdateState}
  }
 }else{$script:managerStatusOrphanSince=$null}
 if(TestManagerStatusCurrent){$script:managerStatusOrphanRetries=0}
 if(-not $script:busy -and $form.FindName('UpdatesPage').Visibility -eq 'Visible' -and (GetManagerScanProgressText)){
  if(-not $script:managerLiveTextAt -or ([DateTime]::UtcNow-$script:managerLiveTextAt).TotalMilliseconds -ge 500){
   $script:managerLiveTextAt=[DateTime]::UtcNow
   if($script:manualVerification){$form.FindName('UpdatesActivity').Text='Verifying installations: '+(GetManagerScanProgressText);$form.FindName('UpdatesActivity').Foreground='#BDA0F4'}
   else{RefreshUpdateBatchSummary}
  }
 }
 $result=ReceiveOptiShadeManagerStatus $script:managerStatusState
 if(-not $result){return}
 ProcessManagerStatusResult $result
}
function ShowOptiShadeTrayUpdateNotice($result){
 if(-not $script:trayEnabled -or -not $script:trayIcon){return}
 # Component rows come from the latest status scan; the launcher update from its own check.
 if($result -and $result.Snapshot){$script:trayComponentRows=@($result.Snapshot.Rows|Where-Object {-not $_.Manual})}
 $items=@($script:trayComponentRows|ForEach-Object {[string]$_.Game+'|'+[string]$_.Id+'|'+[string]$_.Detail})
 if($script:availableUpdate -and -not $script:availableUpdate.Rollback -and -not $script:availableUpdate.ChannelUnavailable){$items+='Launcher|'+[string]$script:availableUpdate.Version}
 if(-not $items.Count){$script:trayLastUpdateNotice='';return}
 # Notify once per distinct set, so a newly published update notifies again.
 $signature=(@($items|Sort-Object) -join "`n")
 if($script:trayLastUpdateNotice -ceq $signature){return}
 $script:trayLastUpdateNotice=$signature
 $launcher=@($items|Where-Object {$_ -like 'Launcher|*'}).Count
 $components=$items.Count-$launcher
 $parts=@();if($launcher){$parts+='a new OptiShade launcher'};if($components){$parts+="$components component update(s)"}
 $script:trayIcon.BalloonTipTitle='OptiShade updates available'
 $script:trayIcon.BalloonTipText=(($parts -join ' and ').Substring(0,1).ToUpper()+($parts -join ' and ').Substring(1))+' available. Click to open Update Manager.'
 $script:trayIcon.BalloonTipIcon=[Windows.Forms.ToolTipIcon]::Info
 $script:trayIcon.ShowBalloonTip(7000)
}
function ProcessManagerStatusResult($result){
 if($result.Error){$script:updateFollowUp=$null;WriteInstallerLog ('Background component check failed: '+$result.Error);$status.Text='Component check unavailable. Use Check for updates to retry.';$status.Foreground='#FFBE83'}
 else{$selectedStatus=GetCachedManagerGameStatus $path.Text;if($selectedStatus -and -not $selectedStatus.Error -and $selectedStatus.Folder -and (GetOptiShadeManagerStatusKey $result.Context.SelectedFolder) -eq (GetOptiShadeManagerStatusKey $path.Text)){$path.Text=$selectedStatus.Folder};RefreshLibrary -FromSnapshot;RefreshHeaderComponentUpdateState;SyncMethodSelection;if($form.FindName('ComponentsPage').Visibility -eq 'Visible'){RefreshAddonCards};StartGlassCockpitReleaseCheck}
 if($form.FindName('UpdatesPage').Visibility -eq 'Visible'){RefreshUpdateManager}
 ShowOptiShadeTrayUpdateNotice $result
 if($script:manualVerification -and -not $script:managerStatusState.Busy){CompleteManualVerification $result}
 if(-not $result.Error){InvokeManagedUpdateFollowUp}
}
# Runs the post-update check while the update window is still open, so an
# update only reports finished once its files have been checked.
function WaitForManagerVerification([int]$TimeoutSeconds=180){
 if(-not $script:managerStatusState -or $script:managerStatusState.Stopped){return $false}
 RequestManagerStatusScan -Force -DuringOperation
 $generation=[int]$script:managerStatusState.Generation
 $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
 while([DateTime]::UtcNow -lt $deadline){
  $result=ReceiveOptiShadeManagerStatus $script:managerStatusState
  if($result){ProcessManagerStatusResult $result;if([int]$result.Generation -ge $generation){return -not $result.Error}}
  $live=GetManagerScanProgressText
  UpdateOperationProgress ('Verifying installed files: '+$(if($live){$live}else{'finishing'}))
  PumpManagerDispatcher;Start-Sleep -Milliseconds 100
 }
 WriteInstallerLog 'Post-update verification did not finish while the update window was open; it continues in the background.'
 return $false
}
# Verify installations: a fresh check of every detected game, reported here.
function StartManualVerification{
 if($script:busy -or ($script:managerStatusState -and $script:managerStatusState.Busy)){return}
 $script:manualVerification=$true
 WriteInstallerLog 'Manual verification requested.'
 RequestManagerStatusScan -Force
 $form.FindName('UpdatesActivity').Text='Verifying installations: starting the check';$form.FindName('UpdatesActivity').Foreground='#BDA0F4'
}
function CompleteManualVerification($Result){
 $script:manualVerification=$false
 $activity=$form.FindName('UpdatesActivity')
 if($Result.Error -or -not $Result.Snapshot){$activity.Text='Verification could not finish: '+[string]$Result.Error;$activity.Foreground='#FFBE83';return}
 $records=@($Result.Snapshot.ByPath.Values|Select-Object -Unique)
 $installed=@($records|Where-Object {$_.Manifest -and [string]$_.Manifest.Status -ceq 'Installed' -and -not $_.Error})
 $problems=@($records|Where-Object {$_.Error})
 $updates=@($Result.Snapshot.Rows).Count
 $text="Verification finished: $($installed.Count) installation(s) checked"
 if($problems.Count){$text+=", $($problems.Count) need attention (details below)"}
 if($updates){$text+=", $updates update(s) available"}
 if(-not $problems.Count -and -not $updates){$text+='. No problems or updates found.'}else{$text+='.'}
 $activity.Text=$text;$activity.Foreground=$(if($problems.Count){'#FFBE83'}else{'#56D9A0'})
 WriteInstallerLog ($text)
}
$script:managerStatusTimer.Start()
function RefreshUpdateNavigation{
 $nav=$form.FindName('UpdatesNav');if(-not $nav){return}
 $failed=@($script:updateResults.Keys|Where-Object {[string]$script:updateResults[$_] -cne 'Complete'}).Count -gt 0
 $pending=@($script:componentUpdateGames).Count -gt 0 -or @($script:glassCockpitUpdateGames).Count -gt 0 -or $failed -or [bool]$script:componentCheckWarning
 $nav.Foreground=if($pending){'#FFD16A'}else{$form.FindResource('TextPrimary')}
 if($pending){$nav.Background='#35271C';$nav.BorderBrush='#D99136'}
 elseif($form.FindName('UpdatesPage').Visibility -eq 'Visible'){$nav.Background=$form.FindResource('NavPurple');$nav.BorderBrush='#9652EB'}
 else{$nav.Background='Transparent';$nav.BorderBrush='Transparent'}
 $form.FindName('UpdatesNavLabel').Text=if($failed){'Update Manager •'}elseif($pending){'Update Manager •'}else{'Update Manager'}
}
function GetManagedUpdateRows{
 if(TestManagerStatusCurrent){
  $rows=@($script:managerStatusState.Snapshot.Rows)
  ReconcileCompletedUpdateResults $rows ([int]$script:managerStatusState.Generation)
  return $rows
 }
 return @()
}
# Live description of the running component check, or '' when none is running.
function GetManagerScanProgressText{
 $state=$script:managerStatusState
 if(-not $state -or (-not $state.Busy -and -not $state.Pending) -or -not $script:managerStatusProgress){return ''}
 $p=$script:managerStatusProgress;$total=[int]$p.Total;$done=[Math]::Min([int]$p.Done,$total)
 $elapsed=if($script:managerStatusRequestedUtc){[int]([DateTime]::UtcNow-$script:managerStatusRequestedUtc).TotalSeconds}else{0}
 $where=if($p.Current -and $total){'checking '+[string]$p.Current+' ('+[Math]::Min($done+1,$total)+' of '+$total+')'}else{'starting the check'}
 return $where+' · '+$elapsed+' s'
}
function TestManagerStatusCurrent{
 $state=$script:managerStatusState
 return [bool]($state -and $state.Snapshot -and -not $state.Busy -and -not $state.Error -and [string]$state.Snapshot.Key -ceq [string]$state.Key)
}
function GetUpdateResultPresentation([string]$Result){
 if($Result -ceq 'Complete'){return [pscustomobject]@{Text='Complete';Color='#56D9A0';Button='Complete';IsComplete=$true}}
 if($Result -like 'Update completed, but verification still finds*'){return [pscustomobject]@{Text='Verification still finds an update';Color='#FFBE83';Button='Retry update';IsComplete=$false}}
 if($Result){return [pscustomobject]@{Text=$Result;Color='#FFBE83';Button='Retry update';IsComplete=$false}}
 return [pscustomobject]@{Text='';Color='';Button='Update component';IsComplete=$false}
}
# Empty when the latest scan confirms the updated installation; otherwise why not.
function GetManagerUpdateVerificationGap([string]$UpdateKey){
 $state=$script:managerStatusState
 if(-not $state -or -not $state.Snapshot -or -not $state.Snapshot.ByPath){return 'no completed component check is available'}
 $separator=$UpdateKey.LastIndexOf('|')
 if($separator -le 0){return 'the update result has no installation folder'}
 $folder=$UpdateKey.Substring(0,$separator)
 $record=GetCachedManagerGameStatus $folder
 if(-not $record){return 'the latest check did not include '+$folder}
 if($record.Error){return 'the latest check reported: '+[string]$record.Error}
 if(-not $record.Manifest){return 'no OptiShade installation receipt was found for '+$folder}
 $manifest=$record.Manifest
 if([string]$manifest.Status -cne 'Installed'){return 'the installation receipt reports status '+[string]$manifest.Status}
 if((GetOptiShadeManagerStatusKey ([string]$manifest.Game)) -ne (GetOptiShadeManagerStatusKey ([string]$record.Folder))){return 'the installation receipt names '+[string]$manifest.Game+' instead of '+[string]$record.Folder}
 return ''
}
function TestManagerUpdateInstallationVerified([string]$UpdateKey){return -not (GetManagerUpdateVerificationGap $UpdateKey)}
function ReconcileCompletedUpdateResults($Rows,[int]$Generation){
 if(-not $script:updateResults){$script:updateResults=@{}}
 if(-not $script:updateResultScanGeneration){$script:updateResultScanGeneration=@{}}
 if(-not $script:updateResultUnconfirmed){$script:updateResultUnconfirmed=@{}}
 if(-not $script:updateResultLogged){$script:updateResultLogged=@{}}
 $pendingKeys=@($Rows|ForEach-Object {[string]$_.Key})
 foreach($key in @($script:updateResults.Keys)){
  if([string]$script:updateResults[$key] -cne 'Complete' -or -not $script:updateResultScanGeneration.ContainsKey([string]$key)){continue}
  $scan=$script:updateResultScanGeneration[[string]$key]
  if($scan -is [string] -and $scan -ceq 'verified'){
   if($key -in $pendingKeys){$script:updateResults.Remove([string]$key);$script:updateResultScanGeneration.Remove([string]$key)}
   continue
  }
  if([int]$scan -gt $Generation){continue}
  $script:updateResultUnconfirmed.Remove([string]$key)
  if($key -in $pendingKeys){$script:updateResults[$key]='Update completed, but verification still finds an available update.';$script:updateResultScanGeneration.Remove([string]$key);continue}
  $gap=GetManagerUpdateVerificationGap ([string]$key)
  if(-not $gap){$script:updateResultScanGeneration[[string]$key]='verified';$script:updateResultLogged.Remove([string]$key);continue}
  # The scan for this update finished without confirming it. Report why
  # instead of waiting; later scans still turn it green once confirmed.
  $script:updateResultScanGeneration[[string]$key]=$Generation
  $script:updateResultUnconfirmed[[string]$key]=$gap
  if([string]$script:updateResultLogged[[string]$key] -cne $gap){$script:updateResultLogged[[string]$key]=$gap;$null=WriteInstallerLog ('Update verification could not confirm '+$key+': '+$gap)}
 }
}
function RefreshUpdateBatchSummary{
 $keys=@($script:updateBatchKeys|ForEach-Object {[string]$_}|Select-Object -Unique)
 if(-not $keys.Count){return}
 if(-not (TestManagerStatusCurrent)){
  # The check after the update is still running: say how far it has got.
  $live=GetManagerScanProgressText
  if($live -and $script:updateResults.Count){$activity=$form.FindName('UpdatesActivity');if($activity){$activity.Text='Update operations finished. Verifying installed files: '+$live;$activity.Foreground='#FFBE83'}}
  return
 }
 $failed=0;$mismatched=0;$unverified=0;$verificationErrors=0;$unconfirmed=@()
 foreach($key in $keys){
  if(-not $script:updateResults.ContainsKey($key)){$unverified++;continue}
  $result=[string]$script:updateResults[$key]
  if($result -like 'Update completed, but verification still finds*'){$mismatched++;continue}
  if($result -cne 'Complete'){$failed++;continue}
  $separator=$key.LastIndexOf('|');$record=if($separator -gt 0){GetCachedManagerGameStatus $key.Substring(0,$separator)}else{$null}
  if($record -and $record.Error){$verificationErrors++;continue}
  if($script:updateResultScanGeneration.ContainsKey($key) -and [string]$script:updateResultScanGeneration[$key] -ceq 'verified'){continue}
  if($script:updateResultUnconfirmed -and $script:updateResultUnconfirmed.ContainsKey($key)){$unconfirmed+=[string]$script:updateResultUnconfirmed[$key];continue}
  $unverified++
 }
 if($unverified){$message='Update operations finished. Verifying installed files...';$color='#FFBE83'}
 elseif($unconfirmed.Count){$message="Update operations finished, but the check afterwards could not confirm $($unconfirmed.Count) installation(s): $($unconfirmed[0]). The update itself completed; use Check for updates to recheck, or export launcher logs.";$color='#FFBE83'}
 elseif($verificationErrors){$message="Update operations finished, but installed files could not be verified for $verificationErrors game(s). Review the scan errors and export launcher logs.";$color='#FFBE83'}
 elseif($mismatched){$message="Update operations finished, but verification still finds an update for $mismatched item(s). Review the yellow items and retry if needed.";$color='#FFBE83'}
 elseif($failed){$message="Finished with $failed update(s) needing attention. Review the results and retry.";$color='#FFBE83'}
 else{$message='Updates completed and verified. You can start your games.';$color='#56D9A0'}
 $activity=$form.FindName('UpdatesActivity');if($activity){$activity.Text=$message;$activity.Foreground=$color}
 $script:updateBatchMessage=$message
 if($status){$status.Text=$message;$status.Foreground=$color}
}
function AddUpdateText($Panel,[string]$Text,[string]$Color='',[double]$Size=14){
 $textBlock=New-Object Windows.Controls.TextBlock;$textBlock.Text=$Text;$textBlock.TextWrapping='Wrap';$textBlock.FontSize=$Size;$textBlock.Margin='0,0,0,7'
 if($Color){$textBlock.Foreground=$Color};[void]$Panel.Children.Add($textBlock)
}
function RefreshUpdateManager{
 $panel=$form.FindName('UpdatesGames');if(-not $panel){return};$panel.Children.Clear()
 $rows=@(GetManagedUpdateRows);$automatic=@($rows|Where-Object {-not $_.Manual -and -not ($_.LocalPackage -and $script:localComponentPackage -and $script:localComponentPackage.Catalog.Schema -eq 2)})
 RefreshUpdateBatchSummary
 $checking=-not $script:managerStatusState -or -not $script:managerStatusState.Snapshot -or $script:managerStatusState.Busy -or $script:managerStatusState.Snapshot.Key -cne $script:managerStatusState.Key
 $script:managedUpdateRows=$rows
 $form.FindName('LocalPackageStatus').Text=if($script:localComponentPackage -and $script:localComponentPackage.Catalog.Schema -eq 2){$stage=if($script:localComponentPackage.Stage){'Complete set staged in local cache; provenance is unverified and no game files were changed.'}else{'Read-only compatibility check; select a matching game below to stage the package or complete set locally.'};$script:localComponentPackage.Catalog.Id+' v'+$script:localComponentPackage.Catalog.Version+' · '+$stage}else{if($script:localComponentPackage){$script:localComponentPackage.Catalog.Id+' v'+$script:localComponentPackage.Catalog.Version+' · '+$script:localComponentPackage.Root+' · Only matching installed baselines are offered.'}else{'Updates come from OptiShade''s signed releases on GitHub and are verified before anything is installed.'}}
 $form.FindName('UpdatesAll').IsEnabled=$automatic.Count -gt 0 -and -not $script:busy -and -not $checking
 $form.FindName('UpdatesRefresh').IsEnabled=-not $script:busy
 $form.FindName('UpdatesVerify').IsEnabled=-not $script:busy -and -not ($script:managerStatusState -and $script:managerStatusState.Busy)
 $hasFailedResults=@($script:updateResults.Keys|Where-Object {[string]$script:updateResults[$_] -cne 'Complete'}).Count -gt 0
 $form.FindName('UpdatesSummary').Text=if($script:managerStatusState -and $script:managerStatusState.Error){'Component check unavailable; retry Check for updates.'}elseif($checking){'Checking installed components…'}elseif($rows.Count){"$($rows.Count) component update(s) across $(@($rows.Folder|Select-Object -Unique).Count) game installation(s)."}elseif(-not $script:managerStatusState -or -not $script:managerStatusState.Snapshot -or $script:managerStatusState.Busy){'Checking installed components…'}elseif($script:managerStatusState.Error){'Component check unavailable; retry Check for updates.'}elseif($script:managerStatusState.Snapshot.Errors.Count){'Some installations could not be checked. Review the details below.'}elseif($script:glassCockpitReleaseCheckRunning){'Checking developer releases…'}elseif($hasFailedResults){'No pending updates found. Earlier update attempts still need attention below.'}else{'No updates found for the detected installations.'}
 if($script:onlineComponentChannelFailures.Count){$form.FindName('UpdatesSummary').Text+=' Some component channels could not be checked: '+($script:onlineComponentChannelFailures -join '; ')+'. Other components remain available.'}
 if($script:atmosphereReleaseCheckRunning){$form.FindName('UpdatesSummary').Text+=' Checking AtmosphereMod releases...'}elseif($script:atmosphereLastCheckUtc -and -not $script:atmosphereLatestRelease){$form.FindName('UpdatesSummary').Text+=' AtmosphereMod release check unavailable; check your connection and retry.'}
 if($script:glassCockpitLastCheckUtc -and -not $script:glassCockpitLatestRelease){$form.FindName('UpdatesSummary').Text+=' Glass Cockpit release check unavailable; check your connection and retry.'}
 foreach($group in @($rows|Group-Object Folder)){
  $border=New-Object Windows.Controls.Border;$border.Background=$form.FindResource('ControlSurface');$border.BorderBrush='#40314F';$border.BorderThickness='1';$border.CornerRadius='10';$border.Padding='16';$border.Margin='0,0,0,12'
  $body=New-Object Windows.Controls.StackPanel;$border.Child=$body;[void]$panel.Children.Add($border)
  AddUpdateText $body ([string]$group.Group[0].Game.Name) '' 19
  AddUpdateText $body $group.Name '#BDAFCF' 12
  $gameButton=New-Object Windows.Controls.Button;$gameButton.Content='Update this game';$gameButton.Tag=[pscustomobject]@{Folder=$group.Name;Id=''};$gameButton.HorizontalAlignment='Left';$gameButton.Margin='0,4,0,12';$gameButton.Padding='12,7';$gameButton.IsEnabled=(@($group.Group|Where-Object {-not $_.Manual}).Count -gt 0 -and -not $script:busy -and -not $checking)
  $gameButton.Add_Click({param($sender,$event) StartManagedUpdates ([string]$sender.Tag.Folder)});[void]$body.Children.Add($gameButton)
  foreach($row in $group.Group){
   AddUpdateText $body $row.Label '#FFD16A' 16
   AddUpdateText $body $row.Detail '#BDAFCF' 13
   $result=GetUpdateResultPresentation $(if($script:updateResults.ContainsKey($row.Key)){[string]$script:updateResults[$row.Key]}else{''})
   if($result.Text){AddUpdateText $body $result.Text $result.Color 13}
   $actions=New-Object Windows.Controls.WrapPanel;$actions.Margin='0,0,0,16';[void]$body.Children.Add($actions)
   $button=New-Object Windows.Controls.Button;$button.Tag=$row;$button.Content=if($row.LocalPackage -and (TestLocalComponentPackageSelectionSet $script:localComponentPackage)){'Stage package set'}elseif($row.LocalPackage -and $script:localComponentPackage -and $script:localComponentPackage.Catalog.Schema -eq 2){'Stage package'}else{$result.Button};$button.HorizontalAlignment='Left';$button.Margin='0,0,10,0';$button.Padding='12,6';$button.IsEnabled=-not $script:busy -and -not $row.Manual -and -not $checking -and -not $result.IsComplete
   if($row.Manual){$button.ToolTip=$row.Detail;[Windows.Controls.ToolTipService]::SetShowOnDisabled($button,$true)}
   $button.Add_Click({param($sender,$event)
    if($script:busy){return};$item=$sender.Tag
    if($item.Manual){return}
    StartManagedUpdates ([string]$item.Folder) ([string]$item.Id)
   });[void]$actions.Children.Add($button)
   if($row.Id -eq 'Cockpit'){
    $releaseButton=New-Object Windows.Controls.Button;$releaseButton.Content='Open official release';$releaseButton.Padding='12,6';$releaseButton.IsEnabled=-not $script:busy
    $releaseButton.Add_Click({if(-not $script:busy){Start-Process -FilePath 'https://github.com/IFreemz/msfs2024-glass-cockpit-dlss-fix/releases'}})
    [void]$actions.Children.Add($releaseButton)
   }
  }
 }
 if($script:localComponentPackage){
  AddUpdateText $panel 'Local package compatibility' '' 18
  if($script:managerStatusState -and $script:managerStatusState.Snapshot){
   foreach($check in $script:managerStatusState.Snapshot.LocalCompatibility){AddUpdateText $panel $check.Text $(if($check.Error){'#FFBE83'}else{'#BDAFCF'}) 13}
  }else{AddUpdateText $panel 'Checking local package compatibility…' '#BDAFCF' 13}
 }
 if($script:managerStatusState -and $script:managerStatusState.Snapshot){foreach($failure in $script:managerStatusState.Snapshot.Errors){AddUpdateText $panel $failure '#FFBE83' 13}}
 if($script:updateResults.Count){
  AddUpdateText $panel 'Last update results' '' 18
  foreach($key in $script:updateResults.Keys|Sort-Object){AddUpdateText $panel (GetUpdateResultLabel $key ([string]$script:updateResults[$key])) '#BDAFCF' 13}
 }
}
# 'folder|Component' -> 'Microsoft Flight Simulator 2024 · OptiMFG — Updated'
function GetUpdateResultLabel([string]$Key,[string]$Result){
 $folder,$component=$Key.Split('|',2)
 $names=@{Core='OptiShade core';Effects='Image effects';OptiMfg='OptiMFG';Mfg='OptiMFG';Neural='Neural rendering';Providers='FSR / XeSS support';Cockpit='Glass cockpit correction';Atmosphere='AtmosphereMod'}
 $part=if($component -and $names.ContainsKey($component)){$names[$component]}elseif($component){$component}else{'Component'}
 $game=$null
 foreach($g in @($script:libraryGames)){foreach($candidate in @([string]$g.Folder,[string]$g.InstallFolder)){if($candidate -and $folder -and [string]::Equals($candidate.TrimEnd('\'),$folder.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)){$game=[string]$g.Name;break}};if($game){break}}
 if(-not $game){$game=if($folder -match '(?i)flight simulator 2024'){'Microsoft Flight Simulator 2024'}elseif($folder -match '(?i)flight simulator'){'Microsoft Flight Simulator 2020'}else{Split-Path ($folder.TrimEnd('\')) -Leaf}}
 $outcome=switch($Result){'Complete'{'Updated'};'Cancelled'{'Not updated (cancelled)'};default{$Result}}
 return ($game+' · '+$part+' — '+$outcome)
}
function InvokeManagedUpdateFollowUp{
 $pending=$script:updateFollowUp
 if(-not $pending -or $script:busy -or -not(TestManagerStatusCurrent)){return}
 if([int]$script:managerStatusState.Generation -lt [int]$pending.Generation){return}
 # Consume before dispatch: there can be only one follow-up, never an update loop.
 $script:updateFollowUp=$null
 $keys=@(GetManagedUpdateRows|Where-Object {
  -not $_.Manual -and -not $_.LocalPackage -and
  [string]$_.Key -in $pending.Allowed -and [string]$_.Key -notin $pending.Attempted
 }|ForEach-Object {[string]$_.Key})
 WriteInstallerLog ('Update batch follow-up: newly available authorised rows='+($keys -join ', '))
 if($keys.Count){StartManagedUpdates -FollowUp -AllowedKeys $keys}
}

function StartManagedUpdates([string]$Folder='',[string]$Id='',[switch]$FollowUp,[string[]]$AllowedKeys=@()){
 if($script:busy){return}
 if($script:managerStatusState -and ($script:managerStatusState.Busy -or $script:managerStatusState.Error -or -not $script:managerStatusState.Snapshot -or $script:managerStatusState.Snapshot.Key -cne $script:managerStatusState.Key)){$status.Text='Checking installed components. Wait for the current check before updating.';return}
 $work=@(GetManagedUpdateRows|Where-Object {-not $_.Manual -and (-not ($_.LocalPackage -and $script:localComponentPackage -and $script:localComponentPackage.Catalog.Schema -eq 2) -or $Id) -and (-not $Folder -or $_.Folder -eq $Folder) -and (-not $Id -or $_.Id -eq $Id) -and (-not $FollowUp -or [string]$_.Key -in $AllowedKeys)})
 if(-not $work.Count){RefreshUpdateManager;return}
 if(-not $FollowUp){
  $script:updateFollowUp=$null
  if(-not $Id){
   $allowed=@(foreach($row in $work){
    $receipt=ReadOptiShadeState $row.ManifestPath
    foreach($component in @('Core')+@($receipt.Components)){
     ([string]$row.Folder).ToLowerInvariant()+'|'+[string]$component
    }
   })
   $script:updateFollowUp=[pscustomobject]@{Allowed=$allowed;Attempted=@($work|ForEach-Object {[string]$_.Key});Generation=[int]::MaxValue}
  }
 }
 $previousBatchKeys=if($FollowUp){@($script:updateBatchKeys)}else{@()}
 $script:updateBatchKeys=@($previousBatchKeys+@($work|ForEach-Object {[string]$_.Key})|Select-Object -Unique)
 WriteInstallerLog ('Update batch begin: followUp='+[bool]$FollowUp+'; rows='+(@($work|ForEach-Object {$_.Key}) -join ', '))
 # One run for every game. A component update that only becomes available
 # once that game's earlier update lands (OptiMFG after Core) joins this run
 # right after it, instead of starting a second update afterwards.
 $queue=[Collections.Generic.List[object]]::new();foreach($row in $work){$queue.Add($row)}
 $script:updateVerifiedInRun=$false
 $followOnAllowed=if(-not $FollowUp -and -not $Id -and $script:updateFollowUp){@($script:updateFollowUp.Allowed)}else{@()}
 $priorAntiCheatUpdateMode=$script:AntiCheatUpdateMode
 $script:AntiCheatUpdateMode=$true
 try{RunAction {
   $completed=0;$failed=0;$succeeded=0;$staged=0;$notStarted=0
  for($index=0;$index -lt $queue.Count;$index++){
   $item=$queue[$index]
   if($script:operationCancelled -or (TestOperationCancelRequested)){
    $script:operationCancelled=$true
    for($rest=$index;$rest -lt $queue.Count;$rest++){$script:updateResults[[string]$queue[$rest].Key]='Not updated: cancelled before it started.';$notStarted++}
    WriteInstallerLog ('Update batch cancelled; not started: '+$notStarted)
    break
   }
   $form.FindName('UpdatesActivity').Text='Updating '+$item.Game.Name+' · '+$item.Label+' ('+($index+1)+' of '+$queue.Count+')'
   & $progress $form.FindName('UpdatesActivity').Text $completed $queue.Count
   PumpManagerDispatcher
   try{
    $applied=$false
    WriteInstallerLog ('Update row begin: '+$item.Key)
    # Re-read before each mutation. Never trust a stale UI row or install an absent component.
    $m=ReadOptiShadeState $item.ManifestPath
    if($m.Status -ne 'Installed'){throw 'Installation changed. Repair or scan this game before retrying.'}
    if((GetOptiShadeManagerStatusKey $m.Game) -ne (GetOptiShadeManagerStatusKey $item.Folder)){throw 'Installation receipt changed to a different game. Rescan before retrying.'}
    AssertClosed $m.Game
    if($item.LocalPackage){
     $applied=$true
     $localResult=InstallLocalComponentPackage $item.ManifestPath $script:localComponentPackage $progress
     if($localResult.State -eq 'staged'){$script:localComponentPackage|Add-Member -NotePropertyName Stage -NotePropertyValue $localResult -Force;[void]$script:updateResults.Remove([string]$item.Key);[void]$script:updateResultScanGeneration.Remove([string]$item.Key);$script:updateBatchKeys=@($script:updateBatchKeys|Where-Object {[string]$_ -cne [string]$item.Key});$staged++;$succeeded++}
    }elseif($item.Id -eq 'Core'){
     $onlineCore=[bool]$item.OnlinePackageId
     if((TestBundledUpdateVersion $m) -or $onlineCore){[void](SetSelectedFusionGame $item.Game);SyncMethodSelection;InvokeRepairInstall -UpdateApproved -ModularPackageApproved:$onlineCore;if($onlineCore){SetOnlineComponentPackageReceipt $item.ManifestPath 'Core'};$applied=$true}
     if(-not $onlineCore -and (TestBundledUpdateVersion (ReadOptiShadeState $item.ManifestPath))){throw 'Core update verification still reports an older installed build.'}
    }elseif($item.Id -eq 'Atmosphere'){
     $check=GetAtmosphereModUpdateInfo (GetAtmosphereModState $m.Game) $script:atmosphereLatestRelease
     if(-not $check.Installed){throw 'AtmosphereMod is no longer installed for this game.'}
     if($check.UnknownVersion -or -not $script:atmosphereLatestRelease){throw 'Refresh the AtmosphereMod release check before updating.'}
     if($check.Available){
      $updated=InstallAtmosphereMod $m.Game {PumpManagerDispatcher} $script:atmosphereLatestRelease
      if(-not $updated.Installed -or [string]$updated.Version -cne [string]$script:atmosphereLatestRelease.VersionText){throw 'AtmosphereMod update did not confirm the requested version.'}
      $applied=$true
     }
    }elseif($item.Id -eq 'Cockpit'){
     $check=GetGlassCockpitUpdateInfo $m $script:glassCockpitLatestRelease
     if($check.Available){$null=UpdateGlassCockpitAddon $item.ManifestPath $script:glassCockpitLatestRelease $progress;$applied=$true}
    }elseif($item.Id -in @(GetComponentUpdateIds $m) -or $item.OnlinePackageId){
     if($script:modularDistribution){
      $packageId=if($item.OnlinePackageId){[string]$item.OnlinePackageId}else{GetOptiShadeModularUpdatePackageId ([string]$item.Id)}
      if($packageId){EnsureVerifiedModularPayload -RequiredIds @($packageId)}
     }
     $applied=$true
     $skipFx=$item.Id -eq 'Effects' -and -not [bool]$m.AllFxInstalled
     if($item.Id -eq 'OptiMfg'){InstallSelectedOptiMfgComponent $item.ManifestPath}
     else{InstallOptiShadeAddon $item.ManifestPath $Payload $item.Id (GetFusionGpu) $progress -SkipAllFx:$skipFx}
     if($item.OnlinePackageId){SetOnlineComponentPackageReceipt $item.ManifestPath ([string]$item.Id)}
    }
    if(-not ($item.LocalPackage -and $script:localComponentPackage.Catalog.Schema -eq 2)){
     if($applied){$script:updateResults[$item.Key]='Complete';$succeeded++;WriteInstallerLog ('Update row applied: '+$item.Key)}
     else{[void]$script:updateResults.Remove([string]$item.Key);[void]$script:updateResultScanGeneration.Remove([string]$item.Key);$script:updateBatchKeys=@($script:updateBatchKeys|Where-Object {$_ -ne $item.Key});WriteInstallerLog ('Update row skipped (already current): '+$item.Key)}
    }
   }catch{
    # A protected game folder (DCS under Program Files, OSD-AZH3) needs the
    # Run as administrator help here too, not only on install.
    $failure=GetOptiShadeFriendlyError $_;$retried=$false
    # An ambiguous multi-NVIDIA inventory is actionable: let the user pick
    # the model-preparation adapter here, then retry only this component once.
    # The independently observed live renderer remains a runtime decision.
    if($item.Id -eq 'Neural' -and $failure -like '*Multiple physical NVIDIA adapters remain possible*'){
     try{
      if(ShowNeuralAdapterPicker $item.ManifestPath){
       $retryManifest=ReadOptiShadeState $item.ManifestPath
       if($retryManifest.Status -ne 'Installed'){throw 'Installation changed. Repair or scan this game before retrying.'}
       if((GetOptiShadeManagerStatusKey $retryManifest.Game) -ne (GetOptiShadeManagerStatusKey $item.Folder)){throw 'Installation receipt changed to a different game. Rescan before retrying.'}
       AssertClosed $retryManifest.Game
       if('Neural' -notin @(GetComponentUpdateIds $retryManifest)){throw 'The Neural update is no longer available. Refresh the component list before retrying.'}
       InstallOptiShadeAddon $item.ManifestPath $Payload $item.Id (GetFusionGpu) $progress
        $script:updateResults[$item.Key]='Complete';$retried=$true;$succeeded++;WriteInstallerLog ('Update row applied after adapter selection: '+$item.Key)
      }
     }catch{$failure=$_.Exception.Message}
    }
    if(-not $retried){$failed++;$script:updateResults[$item.Key]='Not updated: '+$failure;WriteInstallerLog ('Update Manager: '+$item.Key+' | '+$failure)}
   }
   if($followOnAllowed.Count -and -not $item.LocalPackage -and [string]$script:updateResults[[string]$item.Key] -ceq 'Complete'){
    try{
     $prefix=([string]$item.Key).Substring(0,([string]$item.Key).LastIndexOf('|'))
     $insertAt=$index+1
     foreach($nextId in @(GetComponentUpdateIds (ReadOptiShadeState $item.ManifestPath)|Where-Object {$_ -ne 'Mfg'})){
      $nextKey=$prefix+'|'+[string]$nextId
      if($nextKey -notin $followOnAllowed -or @($queue|Where-Object {[string]$_.Key -eq $nextKey}).Count){continue}
      $label=switch([string]$nextId){'Effects'{'Image effects'}'Neural'{'Neural rendering'}'OptiMfg'{'OptiMFG'}'Providers'{'FSR / XeSS support'}default{[string]$nextId}}
      $queue.Insert($insertAt,[pscustomobject]@{Folder=$item.Folder;ManifestPath=$item.ManifestPath;Id=[string]$nextId;Key=$nextKey;Label=$label;Detail='Available after the earlier update in this run';Game=$item.Game;Manual=$false;LocalPackage=$null});$insertAt++
      $script:updateBatchKeys=@(@($script:updateBatchKeys)+$nextKey|Select-Object -Unique)
      if($script:updateFollowUp){$script:updateFollowUp.Attempted=@(@($script:updateFollowUp.Attempted)+$nextKey)}
      WriteInstallerLog ('Update batch: added '+$nextKey+' to this run after '+$item.Key)
     }
    }catch{WriteInstallerLog ('Could not check for follow-on updates after '+$item.Key+': '+$_.Exception.Message)}
   }
   $completed++;UpdateOperationProgress ('Processed '+$completed+' of '+$queue.Count+' updates') $completed $queue.Count
  }
  if($script:operationCancelled){$form.FindName('UpdatesActivity').Text="Update cancelled: $succeeded finished, $notStarted not started. Any step that was running was rolled back.";$status.Text=$form.FindName('UpdatesActivity').Text;$form.FindName('UpdatesActivity').Foreground='#FFBE83';return}
  if($succeeded -and -not $staged){
   foreach($row in $queue){if([string]$script:updateResults[[string]$row.Key] -ceq 'Complete'){$script:updateResultScanGeneration[[string]$row.Key]=[int]$script:managerStatusState.Generation+1;if($script:updateResultUnconfirmed){$script:updateResultUnconfirmed.Remove([string]$row.Key)}}}
   if(WaitForManagerVerification){
    $script:updateVerifiedInRun=$true
    [void](GetManagedUpdateRows);$script:updateBatchMessage='';RefreshUpdateBatchSummary
    if($failed){$form.FindName('UpdatesActivity').Text="Finished with $failed update(s) needing attention. Review the results and retry.";$form.FindName('UpdatesActivity').Foreground='#FFBE83'}
    $status.Text=$form.FindName('UpdatesActivity').Text
    if(-not $failed -and $script:updateBatchMessage -cne 'Updates completed and verified. You can start your games.'){$script:operationAttention=$true}
    if($failed){if($succeeded){$script:operationAttention=$true}else{$script:operationFailed=$true}}
    return
   }
  }
  $form.FindName('UpdatesActivity').Text=if($failed){"Finished with $failed update(s) needing attention. Review the results and retry."}elseif($staged){'Package staged in the local cache. Provenance is unverified; no game files were changed.'}else{'Update operations finished. Verifying installed files...'}
  $status.Text=$form.FindName('UpdatesActivity').Text
  $form.FindName('UpdatesActivity').Foreground='#FFBE83'
   if($failed){if($succeeded){$script:operationAttention=$true}else{$script:operationFailed=$true}}
 } 'Updating game installations'}finally{$script:AntiCheatUpdateMode=$priorAntiCheatUpdateMode}
	# The status snapshot that supplied these rows predates the writes above.
	# Invalidate it and take a fresh receipt/file scan before reconciling any
	# successful operation; otherwise the old row is misreported as a failed
	# post-update verification and stays yellow until some unrelated rescan.
	if(-not $script:updateVerifiedInRun){RequestManagerStatusScan -Force}
 if(-not $FollowUp -and $script:updateFollowUp){$script:updateFollowUp.Generation=[int]$script:managerStatusState.Generation}
 if(-not $script:updateVerifiedInRun){foreach($item in $queue){if($script:updateResults.ContainsKey([string]$item.Key) -and [string]$script:updateResults[$item.Key] -ceq 'Complete'){$script:updateResultScanGeneration[[string]$item.Key]=[int]$script:managerStatusState.Generation;if($script:updateResultUnconfirmed){$script:updateResultUnconfirmed.Remove([string]$item.Key)}}}}
 RefreshHeaderGlassCockpitUpdateState;RefreshUpdateManager
 if($script:updateVerifiedInRun){InvokeManagedUpdateFollowUp}
}

function GetGlassCockpitUpdateTargets([switch]$AvailableOnly){
 if(-not $script:managerStatusState -or -not $script:managerStatusState.Snapshot){return @()}
 foreach($target in $script:managerStatusState.Snapshot.GlassTargets){if(-not $AvailableOnly -or $target.Info.Available){$target}}
}
function RefreshHeaderGlassCockpitUpdateState{
 $script:glassCockpitUpdateGames=@(GetGlassCockpitUpdateTargets -AvailableOnly)
 RefreshHeaderComponentUpdateState
}
function GetAtmosphereUpdateTargets{
 if($script:managerStatusState -and $script:managerStatusState.Snapshot -and $script:managerStatusState.Snapshot.PSObject.Properties['AtmosphereTargets']){return @($script:managerStatusState.Snapshot.AtmosphereTargets)}
 return @()
}
function StartAtmosphereReleaseCheck([switch]$Force){
 if($script:atmosphereReleaseCheckRunning -or @(GetAtmosphereUpdateTargets).Count -eq 0){return}
 if(-not(TestGlassCockpitCheckDue $script:atmosphereLastCheckUtc ([bool]$script:atmosphereLatestRelease) ([bool]$Force))){return}
 $script:atmosphereReleaseCheckRunning=$true
 $script:atmosphereWorker=NewOptiShadeManagerWorker
 [void]$script:atmosphereWorker.AddScript({param($modulePath) . $modulePath; GetAtmosphereModLatestRelease}).AddArgument((Join-Path $PSScriptRoot 'atmosphere-mod.ps1'))
 $script:atmosphereResult=$script:atmosphereWorker.BeginInvoke()
 $script:atmospherePollTimer=New-Object Windows.Threading.DispatcherTimer
 $script:atmospherePollTimer.Interval=[TimeSpan]::FromMilliseconds(250)
 RegisterOptiShadeManagerTimer $script:atmospherePollTimer {
  if(-not $script:atmosphereResult.IsCompleted){return}
  $script:atmospherePollTimer.Stop()
  try{
   $items=@($script:atmosphereWorker.EndInvoke($script:atmosphereResult))
   if($script:atmosphereWorker.Streams.Error.Count -or -not $items.Count){throw 'GitHub release check failed.'}
   $script:atmosphereLatestRelease=$items[-1];$script:atmosphereReleaseError=''
  }catch{$script:atmosphereLatestRelease=$null;$script:atmosphereReleaseError=$_.Exception.Message;WriteInstallerLog ('AtmosphereMod update check: '+$script:atmosphereReleaseError)}
  finally{RemoveOptiShadeManagerWorker $script:atmosphereWorker;UnregisterOptiShadeManagerTimer $script:atmospherePollTimer;$script:atmosphereReleaseCheckRunning=$false;$script:atmosphereLastCheckUtc=[DateTime]::UtcNow}
  RequestManagerStatusScan -Force
  RefreshHeaderComponentUpdateState
  if($form.FindName('ComponentsPage').Visibility -eq 'Visible'){RefreshAddonCards}
 }
 $script:atmospherePollTimer.Start()
}
function StartGlassCockpitReleaseCheck([switch]$Force){
 StartAtmosphereReleaseCheck -Force:$Force
 if($script:glassCockpitReleaseCheckRunning -or @((GetGlassCockpitUpdateTargets)).Count -eq 0){return}
 if(-not(TestGlassCockpitCheckDue $script:glassCockpitLastCheckUtc ([bool]$script:glassCockpitLatestRelease) ([bool]$Force))){return}
 $script:glassCockpitReleaseCheckRunning=$true
 # Keep the callback in this script's scope. GetNewClosure creates a dynamic
 # module: writing $script: there never updates the manager's release state.
 $script:glassCockpitWorker=(NewOptiShadeManagerWorker)
 [void]$script:glassCockpitWorker.AddScript({param($modulePath) . $modulePath; GetGlassCockpitLatestRelease}).AddArgument((Join-Path $PSScriptRoot 'glass-cockpit-update.ps1'))
 $script:glassCockpitResult=$script:glassCockpitWorker.BeginInvoke()
 $script:glassCockpitPollTimer=New-Object Windows.Threading.DispatcherTimer
 $script:glassCockpitPollTimer.Interval=[TimeSpan]::FromMilliseconds(250)
 RegisterOptiShadeManagerTimer $script:glassCockpitPollTimer {
  if(-not $script:glassCockpitResult.IsCompleted){return}
  $script:glassCockpitPollTimer.Stop()
  try{$result=@($script:glassCockpitWorker.EndInvoke($script:glassCockpitResult));$script:glassCockpitLatestRelease=if($result.Count){$result[-1]}else{$null}}
  catch{$script:glassCockpitLatestRelease=$null}
  finally{RemoveOptiShadeManagerWorker $script:glassCockpitWorker;UnregisterOptiShadeManagerTimer $script:glassCockpitPollTimer;$script:glassCockpitReleaseCheckRunning=$false;$script:glassCockpitLastCheckUtc=[DateTime]::UtcNow}
  RequestManagerStatusScan -Force
  RefreshHeaderGlassCockpitUpdateState
  if($form.FindName('ComponentsPage').Visibility -eq 'Visible'){RefreshAddonCards}
 }
 $script:glassCockpitPollTimer.Start()
}
# Keep a manager left open informed about new official cockpit releases.
# Component and upstream release checks run during startup, on explicit refresh,
# or when the user opens the relevant page. Do not keep polling while idle.
function GetStartupComponentCheckState{
 $state=$script:managerStatusState
 if(-not $state -or $state.Busy -or $state.Pending -or $state.Completion -or $script:glassCockpitReleaseCheckRunning -or $script:atmosphereReleaseCheckRunning){return 'Checking installed components and official releases...'}
 if($state.Error){return 'Component verification failed. Open Update Manager and refresh to retry.'}
 if(-not(TestManagerStatusCurrent)){return 'Waiting for component verification...'}
 if(@($state.Snapshot.Errors).Count){return 'Some installations could not be checked. Open Update Manager and refresh to retry.'}
 if(@(GetAtmosphereUpdateTargets).Count){
  if(-not $script:atmosphereLastCheckUtc){return 'Waiting for the AtmosphereMod release check...'}
  if(-not $script:atmosphereLatestRelease){return 'The AtmosphereMod release check was unavailable. Open Update Manager and refresh to retry.'}
  if(@(GetAtmosphereUpdateTargets|Where-Object {$_.Info.UnknownVersion}).Count){return 'The installed AtmosphereMod version could not be read. Review its installation record before updating.'}
 }
 if(@(GetGlassCockpitUpdateTargets).Count){
  if(-not $script:glassCockpitLastCheckUtc){return 'Waiting for the Glass Cockpit release check...'}
  if(-not $script:glassCockpitLatestRelease){return 'The Glass Cockpit release check was unavailable. Open Update Manager and refresh to retry.'}
 }
 return ''
}
function RefreshHeaderComponentUpdateState{
 if($script:startupReady -and $script:startupComponentChecksStarted){$script:componentCheckWarning=GetStartupComponentCheckState}

 # Derive all badges from the same current receipts as the update page, not
 # cached library card flags left behind after a multi-game update.
 $currentRows=@(GetManagedUpdateRows)
 RefreshUpdateBatchSummary
 $script:componentUpdateGames=@($currentRows|Where-Object {$_.Id -ne 'Cockpit'}|Select-Object -ExpandProperty Folder -Unique)
 $script:glassCockpitUpdateGames=@($currentRows|Where-Object {$_.Id -eq 'Cockpit'}|Select-Object -ExpandProperty Folder -Unique)
 $button=$form.FindName('HeaderComponentUpdateAvailable')
 if(-not $button){return}
 $glassCount=@($script:glassCockpitUpdateGames).Count;$componentCount=@($script:componentUpdateGames).Count
 $failed=@($script:updateResults.Keys|Where-Object {[string]$script:updateResults[$_] -cne 'Complete'}).Count -gt 0
 $button.Visibility=if($componentCount -or $glassCount -or $failed -or $script:componentCheckWarning){'Visible'}else{'Collapsed'}
 $button.Content=if($failed){'Update results need attention'}elseif($componentCount -or $glassCount){'Component updates available'}elseif($script:componentCheckWarning){'Component update check incomplete'}else{'Component updates available'}
 $button.ToolTip=if($script:componentCheckWarning){$script:componentCheckWarning}elseif($failed){'Previous update attempts need attention; open Update Manager to review the recorded results'}elseif($glassCount -and $componentCount){"Review component updates and the Glass Cockpit developer update across $([Math]::Max($componentCount,$glassCount)) games"}elseif($glassCount){'A Glass Cockpit developer update is available; review it in Update Manager'}elseif($componentCount -gt 1){"Review component updates for $componentCount games"}else{'Review updates for installed game components'}
 RefreshUpdateNavigation
 if($form.FindName('UpdatesPage').Visibility -eq 'Visible' -and -not $script:busy){RefreshUpdateManager}
}
function GetStartupLibraryStatus([string]$ScanError,[string]$SnapshotError,[int]$GameCount,[int]$ProtectionIncomplete=0){
 if($ScanError){if($GameCount){return ('Game scan failed; showing saved entries. Open Library and select Scan for games to retry. '+$ScanError)};return ('Game scan failed. Open Library and select Scan for games to retry. '+$ScanError)}
 if($SnapshotError){return ('Snapshot library needs attention: '+$SnapshotError)}
 if($ProtectionIncomplete -gt 0){return ("Game library scan complete. $ProtectionIncomplete game(s) still need the pre-install protection check.")}
 return 'Game scan complete. Open the library to install or manage a game.'
}

function SetFusionCardProtectionResult($Card,[string]$Status,[string]$Detail){
 $Card.ProtectionDetail=$Detail
 if($Status -eq 'Checking'){$Card.ProtectionStatus='Checking anti-cheat…';$Card.ProtectionColor='#B5A9C8';return}
 if($Status -eq 'Quick check: none found'){$Card.ProtectionStatus='Quick check: no indicators';$Card.ProtectionColor='#B5A9C8';return}
 if($Status -match '^Detected:\s*(.+)$'){$Card.ProtectionStatus=('Anti-cheat detected · '+$Matches[1]);$Card.ProtectionColor='#FF9292';return}
 if($Status -match '^Possible indicator:\s*(.+)$'){$Card.ProtectionStatus=('Possible anti-cheat · '+$Matches[1]);$Card.ProtectionColor='#F2C35C';return}
 if($Status -in @('Check incomplete','Not checked')){$Card.ProtectionStatus='Anti-cheat check incomplete';$Card.ProtectionColor='#F2C35C';return}
 $Card.ProtectionStatus='Anti-cheat status unavailable';$Card.ProtectionColor='#B5A9C8'
}

function StartLibraryProtectionCheck($Cards){
 $worker=NewOptiShadeManagerWorker
 $targets=@($Cards|Select-Object Folder,Name)
 [void]$worker.AddScript({param($root,$targets)
  . (Join-Path $root 'ownership.ps1');. (Join-Path $root 'anti-cheat.ps1')
  foreach($game in $targets){
   try{
    $target=GetAntiCheatTarget ([string]$game.Folder)
    GetAntiCheatLibraryCardResult $target (Join-Path $root 'anti-cheat-rules.json') 1500 -Folder ([string]$game.Folder)
   }catch{[pscustomobject]@{Folder=$game.Folder;Label='Not checked';Detail='The startup check was unavailable. The install check runs before making changes.'}}
  }
 }).AddArgument($PSScriptRoot).AddArgument($targets)
 $job=$worker.BeginInvoke();$timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(300)
 $commands=@{};foreach($name in @('UnregisterOptiShadeManagerTimer','UpdateLibraryGrid','RemoveOptiShadeManagerWorker','SetFusionCardProtectionResult')){$commands[$name]=(Get-Command $name -CommandType Function).ScriptBlock}
 $handler={
  if(-not $job.IsCompleted){return}
  & $commands.UnregisterOptiShadeManagerTimer $timer
  try{
   $results=@($worker.EndInvoke($job))
   foreach($card in $Cards){$found=$results|Where-Object Folder -eq $card.Folder|Select-Object -First 1;if($found){& $commands.SetFusionCardProtectionResult $card ([string]$found.Label) ([string]$found.Detail)}else{& $commands.SetFusionCardProtectionResult $card 'Not checked' 'The startup check did not return a result. The install check runs before making changes.'}}
   & $commands.UpdateLibraryGrid
  }catch{foreach($card in $Cards){& $commands.SetFusionCardProtectionResult $card 'Not checked' 'The startup check was unavailable. The install check runs before making changes.'};& $commands.UpdateLibraryGrid}
  finally{& $commands.RemoveOptiShadeManagerWorker $worker}
 }.GetNewClosure()
 RegisterOptiShadeManagerTimer $timer $handler;$timer.Start()
}

function ShowGames($games,[switch]$SkipUpdateCheck,[switch]$SkipProtectionCheck){
 # The scan requested by this render is asynchronous. Never reuse update badges
 # from the previous game snapshot; RefreshLibrary applies them after the new
 # receipt scan completes.
 $SkipUpdateCheck=$true
 $games=@(FilterFusionLibraryGames $games $script:removedGames)
 $selector=$form.FindName('MsfsCopies');if($selector){$selector.ItemsSource=$games}
 $cards=New-Object Collections.Generic.List[FusionGameCard]
 foreach($game in @($games | Sort-Object @{Expression={if($_.Name -match '2024'){0}elseif($_.Name -match '2020'){1}else{2}}})){
  $image=$form.FindName('BrandIcon').Source;if(-not $image){$image=$form.Icon}
  if($game.Artwork){try{$bytes=[Convert]::FromBase64String($game.Artwork);$memory=New-Object IO.MemoryStream(,$bytes);$image=New-Object Windows.Media.Imaging.BitmapImage;$image.BeginInit();$image.CacheOption='OnLoad';$image.StreamSource=$memory;$image.EndInit();$image.Freeze();$memory.Dispose()}catch{$image=$form.Icon}}
  $card=New-Object FusionGameCard;SetFusionCardProtectionResult $card 'Checking' 'Checking standard anti-cheat locations. A deeper check runs before installation.';$card.Name=$game.Name;$card.DisplayName=if($game.Name -match '2024'){'MSFS 2024'}elseif($game.Name -match '2020'){'MSFS 2020'}elseif($game.Name -match 'X.?Plane'){'X-Plane 12'}else{$game.Name};$card.Folder=$game.Folder;$card.Launcher=$game.Launcher;$card.InstallFolder=$game.InstallFolder;$card.StoreDisplay=GetDetectedStoreDisplay $game;$card.FavoriteKey=GetFusionLibraryGameKey $game;$card.IsFavorite=$script:favoriteGames.ContainsKey($card.FavoriteKey);$card.FavoriteGlyph=if($card.IsFavorite){'★'}else{'☆'};$card.FavoriteTip=if($card.IsFavorite){'Remove from favorites'}else{'Add to favorites'};$card.State=$game.State;$card.StatusColor=if($game.State -match '^Installed'){'#56D9A0'}elseif($game.State -match 'incomplete|not tracked|attention'){'#F2C35C'}else{'#A398BD'};$card.Label=$game.Label;$card.Artwork=$game.Artwork;$card.Thumbnail=$image;$card.Installed=($game.State -match '^Installed');$card.ActionLabel=if($card.Installed){'Manage'}elseif($game.State -match 'incomplete'){'Repair'}else{'Install'};$card.Description=if($card.Installed){'OptiShade is installed for this game.'}elseif($game.State -match 'incomplete|not tracked'){'Review the detected files before installing.'}else{'OptiShade is not yet installed for this game.'};$info=if($SkipUpdateCheck){[pscustomobject]@{Components=@();Target='';Text=''}}else{GetGameUpdateInfo $game};$card.ComponentUpdateIds=@($info.Components);$card.UpdateButtonVisibility=if($info.Target){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed};$card.UpdateTarget=$info.Target;if($info.Target){$card.State=$info.Text;$card.StatusColor='#FFBE83';$card.Description='Select Update available to review this game.'};$cards.Add($card)
 }
 $script:libraryGames=$cards;if(-not $SkipProtectionCheck){StartLibraryProtectionCheck $cards};$script:componentsGameSource=@($cards.ToArray());UpdateLibraryGrid;RequestManagerStatusScan -Force;RefreshHeaderComponentUpdateState;StartGlassCockpitReleaseCheck
 $componentPicker=$form.FindName('ComponentsGame');if($componentPicker){$componentPicker.ItemsSource=$script:componentsGameSource}
 if(Get-Command RefreshComponentsGameSelector -ErrorAction SilentlyContinue){RefreshComponentsGameSelector}
 if((Get-Command RefreshNvidiaGames -ErrorAction SilentlyContinue) -and $form.FindName('NvidiaPage').Visibility -eq 'Visible'){RefreshNvidiaGames}
}
function GetComponentUpdateIds($Manifest){
 if(-not $Manifest -or $Manifest.Status -ne 'Installed'){return @()}
 if($script:modularDistribution){return @()}
 try{
  if(-not $script:bundleCatalog){$script:bundleCatalog=ReadOptiShadeJson (Join-Path $Payload 'files.json') 'Bundled component catalogue' -Shape Array}
  $selected=@(GetOptiShadeAddonSelection $Manifest);$updates=New-Object 'System.Collections.Generic.List[string]'
  # Glass Cockpit versions are checked against the developer's release feed.
  # The manager's bundled copy may lag that feed, so never offer a bundle-based
  # component update that could replace a newer developer release with an older one.
  foreach($id in @('Effects','Neural','OptiMfg','Cockpit','Providers')|Where-Object {$selected -contains $_ -and $_ -ne 'Cockpit'}){
   if($id -eq 'OptiMfg' -and (TestOptiMfgComponentNeedsRepair $Manifest)){$updates.Add($id);continue}
   if(TestLocalComponentReceipt $Manifest $id){continue}
  # Verify only files this architecture's installer actually selects. In
  # particular x64 installations intentionally omit the x86 Legacy NR bridge
  # and its host64 worker; treating those absent files as stale caused every
  # successful x64 Neural update to remain yellow.
  $entries=@(GetOptiShadeAddonPayloadEntries $script:bundleCatalog $Manifest $id);$needsUpdate=$false
   foreach($entry in $entries){
    $relative=([string]$entry.Path).Replace('\','/')
    if($id -eq 'Mfg'){
     if($Manifest.Sm86Mfg){
      $identity=GetSm86MfgReleaseIdentity;$plan=@(GetSm86MfgInstallPlan ([string]$Manifest.Sm86MfgLoader))
      if([string]$Manifest.Sm86MfgVersion -ne $identity.Version -or [string]$Manifest.Sm86MfgSHA256 -cne $identity.SHA256 -or [string]$Manifest.Sm86MfgLoader -notin (GetSm86MfgLoaderAliases)){$needsUpdate=$true;break}
      $mfgPaths=@($Manifest.Sm86MfgFiles);if($mfgPaths.Count -ne $plan.Count -or @($mfgPaths|ForEach-Object {([string]$_).Replace('\','/')}|Select-Object -Unique).Count -ne $plan.Count){$needsUpdate=$true;break}
      foreach($mfgPath in $mfgPaths){$normalized=([string]$mfgPath).Replace('\','/');$expected=@($plan|Where-Object {$_.Path.Replace('\','/') -eq $normalized});$record=@($Manifest.Files|Where-Object {$_.Path.Replace('\','/') -eq $normalized -and $_.Component -eq 'Mfg'});if($expected.Count -ne 1 -or $record.Count -ne 1 -or -not $identity.Files.Contains($expected[0].Entry) -or [string]$record[0].Hash -cne [string]$identity.Files[$expected[0].Entry] -or [bool]$record[0].Mutable -ne [bool]$expected[0].Mutable){$needsUpdate=$true;break};$current=HashFile (OwnedPath $Manifest.Game $mfgPath);if(-not $current -or ($current -and -not $record[0].Mutable -and $current -cne [string]$identity.Files[$expected[0].Entry])){$needsUpdate=$true;break}}
     }else{
      try{$gpuNames=GetFusionGpu;$channel=GetOptiShadeMfgPolicyChannel;$route=GetOptiShadeInstallProviderDecision $Manifest $Payload $gpuNames $channel;if($route -eq 'sm86'){$needsUpdate=$true}}catch{}
     }
     if($needsUpdate){break};continue
    }
    $owned=@($Manifest.Files|Where-Object {$_.Path.Replace('\','/') -eq $relative}|Select-Object -First 1)
    $current=HashFile (OwnedPath $Manifest.Game $entry.Path)
    # Shared files may predate this component's receipt. Matching bytes need
    # no update; this comparison does not adopt ownership of those files.
    if($current -and $current -ieq $entry.Hash){continue}
    if($owned.Count -eq 1 -and (TestOptiShadeMutableFile $relative) -and (Test-Path -LiteralPath (OwnedPath $Manifest.Game $entry.Path))){continue} # Mutable data need not match bundled defaults.
    if($owned.Count){$current=HashFile (OwnedPath $Manifest.Game $entry.Path);if(-not $current -or ($current -ceq $owned[0].Hash -and $current -cne $entry.Hash)){$needsUpdate=$true;break}}
    elseif($id -ne 'Effects' -or $Manifest.AllFxInstalled){$needsUpdate=$true;break}
   }
   if($needsUpdate){$updates.Add($id)}
  }
  $local=GetLocalComponentPackageState $Manifest $script:localComponentPackage
  if($local.Available -and $script:localComponentPackage.Catalog.Id -ne 'Core' -and -not $updates.Contains([string]$script:localComponentPackage.Catalog.Id)){$updates.Add([string]$script:localComponentPackage.Catalog.Id)}
  return @($updates)
 }catch{throw ('Could not check component updates: '+$_.Exception.Message)}
}
function GetGameUpdateInfo($Game){
 if(-not (TestManagerStatusCurrent)){return [pscustomobject]@{Core=$false;Components=@();Target='';Text=''}}
 $cached=GetCachedManagerGameStatus $Game
 if($cached){return $cached.Info}
 return [pscustomobject]@{Core=$false;Components=@();Target='';Text=''}
}
function RefreshComponentsGameSelector{
 $selector=$form.FindName('ComponentsGame');if(-not $selector){return}
 $script:refreshingComponentsGame=$true
 try{
  if(-not $script:componentsGameSource -or $script:componentsGameSource.Count -ne @($script:libraryGames).Count){$script:componentsGameSource=@($script:libraryGames);$selector.ItemsSource=$script:componentsGameSource}
  $target='';try{if($path.Text){$target=[IO.Path]::GetFullPath($path.Text).TrimEnd('\')}}catch{}
  $selected=$null
  foreach($game in @($script:libraryGames)){
   $candidate='';try{$cached=GetCachedManagerGameStatus $game;$candidate=GetOptiShadeManagerStatusKey $(if($cached){$cached.Folder}else{$game.Folder})}catch{}
   if($target -and $candidate -and ([string]::Equals($candidate,$target,[StringComparison]::OrdinalIgnoreCase) -or (GetOptiShadeManagerStatusKey $game.Folder) -eq (GetOptiShadeManagerStatusKey $target))){$selected=$game;break}
  }
  if(-not $selected -and -not $target -and $script:gameRoot){$selected=@($script:libraryGames|Where-Object {[string]::Equals([string]$_.Folder,[string]$script:gameRoot,[StringComparison]::OrdinalIgnoreCase)}|Select-Object -First 1)[0]}
  $selector.SelectedItem=$selected
 }finally{$script:refreshingComponentsGame=$false}
 if($selected){[void](SetSelectedFusionGame $selected)}else{
  ClearComponentsTargetSummary
  if($path.Text){$path.Text=''}
  $script:gameRoot='';$script:gameLauncher=''
 }
}
function UpdateLibraryGrid{
 $all=@($script:libraryGames)
 if($script:libraryPreferences.FavoritesOnly){$all=@($all|Where-Object IsFavorite)}
 if($script:libraryPreferences.InstalledFirst){$all=@($all|Sort-Object @{Expression={if($_.Installed){0}else{1}}},DisplayName)}else{$all=@($all|Sort-Object DisplayName)}
 $form.FindName('LibraryGames').ItemsSource=$all
 $allCount=@($script:libraryGames).Count;$installedCount=@($script:libraryGames|Where-Object Installed).Count;$favoriteCount=@($script:libraryGames|Where-Object IsFavorite).Count
 $form.FindName('LibraryPageStatus').Text=if(-not $allCount){'No games found. Scan for games or add one manually.'}elseif($script:libraryPreferences.FavoritesOnly){"$allCount detected | $installedCount installed | showing $($all.Count) favorite(s)"}else{"$allCount detected game(s) · $installedCount with OptiShade installed · $favoriteCount favorite(s)"}
 $form.FindName('LibraryInstalledFirst').IsChecked=[bool]$script:libraryPreferences.InstalledFirst;$form.FindName('LibraryFavoritesOnly').IsChecked=[bool]$script:libraryPreferences.FavoritesOnly
}
function RemoveLibraryGameEntry($Game){
 if(-not $Game){return}
 $key=GetFusionLibraryGameKey $Game;if(-not $key){throw 'This library entry has no stable game location and cannot be removed.'}
 $gamePaths=@([string]$Game.Folder,[string]$Game.InstallFolder)|Where-Object {$_}
 $managed=@(GetManagedInstallations|Where-Object {$record=$_;$gamePaths|Where-Object {[string]::Equals([string]$_,[string]$record.Game,[StringComparison]::OrdinalIgnoreCase)}|Select-Object -First 1})
 $removedMissingInstall=$false;$gameExecutableMissing=$false
 if($managed.Count){
  $item=$managed[0]
  $gameExecutableMissing=TestFusionMissingSimulatorExecutable $Game
  if(-not(Test-Path -LiteralPath ([string]$item.Game) -PathType Container)){
   $prompt="The recorded game folder is missing. If you uninstalled the game, remove this library entry and permanently delete OptiShade's saved restore record and original-file backups? The game folder will not be recreated. If the drive is disconnected, choose No and reconnect it."
   if((ShowOptiShadeDialog $form $prompt 'Remove records' 'YesNo' 'Warning' 'No') -ne 'Yes'){return}
   RunAction {RemoveMissingOptiShadeInstallRecord $store ([string]$item.Game) -MutationHeld} 'Removing OptiShade records for an uninstalled game' -SkipTargetRecovery
   if($script:operationFailed){return}
   $removedMissingInstall=$true

  }else{
   $prompt=if($gameExecutableMissing){"No simulator executable is accessible in the recorded folder. If the game was uninstalled, remove OptiShade from the leftover folder and this library? Its tracked original files will be restored, saved presets will be kept, and the game will not be reinstalled. If the game or drive is still present elsewhere, choose No."}else{"Remove OptiShade from $($item.Title) and remove it from this library? The game itself will be kept, original game files will be restored, and saved presets will be kept. Close the game before continuing."}
   if((ShowOptiShadeDialog $form $prompt 'Restore game and remove' 'YesNo' 'Warning' 'No') -ne 'Yes'){return}
   SetManagerGame $item;$script:restoreKeepPresets=$true
   RunAction {InvokeRestoreInstall} 'Restoring OptiShade before removing game'
   if($script:operationFailed){return}
  }
 }
 $script:removedGames[$key]=$true;[void]$script:favoriteGames.Remove($key);SaveLibraryPreferences
 $script:libraryGames=@($script:libraryGames|Where-Object {$_.FavoriteKey -cne $key})
 $selector=$form.FindName('MsfsCopies');$selector.ItemsSource=@(FilterFusionLibraryGames @($selector.ItemsSource) $script:removedGames)
 $script:componentsGameSource=@($script:libraryGames);$target='';try{$target=[IO.Path]::GetFullPath($path.Text).TrimEnd('\')}catch{}
 if($target -and [string]::Equals($target,[string]$Game.Folder,[StringComparison]::OrdinalIgnoreCase)){
  $selector.SelectedItem=$null;$path.Text='';$script:gameRoot='';$script:gameLauncher='';$form.FindName('SelectedTitle').Text='Choose a game';$form.FindName('SelectedIcon').Source=$form.Icon;UpdateDetectedStore;ClearComponentsTargetSummary
 }
 UpdateLibraryGrid;RefreshHomeState;RefreshComponentsGameSelector
  $status.Text=if($removedMissingInstall){'The missing game and its OptiShade restore record were removed. The game folder was not recreated.'}elseif($gameExecutableMissing){'No game executable was found. OptiShade was removed from the leftover folder, original tracked files were restored, saved presets were kept, and the library entry was removed.'}elseif($managed.Count){'OptiShade was removed from the game and its library entry was hidden. The game and saved presets were kept.'}else{'Removed from the OptiShade library. No managed OptiShade installation was found for this game.'}
}
function RefreshHomeState{
 $knownGames=@($form.FindName('MsfsCopies').ItemsSource)
 $managedGames=@($knownGames|Where-Object {$_.State -match '^Installed'})
 $homeLibrary=$form.FindName('HomeLibraryStatus')
 if($homeLibrary){$homeLibrary.Text=if($knownGames.Count){"$($knownGames.Count) game(s) detected | $($managedGames.Count) with OptiShade installed"}else{'No games detected yet. Open the library and scan again, or add a game manually.'}}
 $form.FindName('MfgStatus').Text='Install the MFG component now. Live provider compatibility and activation are checked in-game; installation does not prove generated output.'
  try{if($path.Text){$mfgRecord=(GetCachedManagerGameStatus $path.Text).Manifest;if($mfgRecord.AutomaticMfgStatus){$form.FindName('MfgStatus').Text=$mfgRecord.AutomaticMfgStatus}elseif($mfgRecord.Sm86Mfg){$form.FindName('MfgStatus').Text="DLSSG for SM86 v$($mfgRecord.Sm86MfgVersion) is installed under $($mfgRecord.Sm86MfgLoader). The OptiScaler UI still needs a live game/provider report."}elseif($mfgRecord.OptionalMfg){$loader=GetOptiShadeMfgLoaderName $mfgRecord;$form.FindName('MfgStatus').Text="RTX 40 upstream MFG is recorded under $loader. Live game/provider support still needs testing."}}}catch{}
 $cached=GetCachedManagerGameStatus $path.Text
 $state=if($cached){$cached.State}elseif($path.Text){'Checking installation…'}else{'Not installed'}
 $form.FindName('SetupSelectionStatus').Text=$state
 if($form.FindName('AutoStatus')){$form.FindName('AutoStatus').Text=if($state -match '^Installed'){'Choose components, then start the game. Enable features from the in-game menu.'}else{'Install OptiShade to set up this game automatically.'}}
    $form.FindName('SetupSelectionStatus').Foreground=if($state -match '^Installed'){'#55DCA5'}elseif($state -match 'not tracked|incomplete'){'#F2C35C'}else{'#A99ABF'}
 $installed=$state -match '^Installed';$incomplete=$state -match '^Installation incomplete'
 $upgrade=$false;$channelChange=$false
 if($installed){try{$record=$cached.Manifest;$channelChange=TestOptiShadeChannelChange $record.Version (GetBundledOptiShadeVersion);$upgrade=(TestBundledUpdateVersion $record) -or $channelChange}catch{}}
 $install=$form.FindName('Install');$install.Content=if($channelChange){GetOptiShadeChannelChangeLabel $record.Version (GetBundledOptiShadeVersion)}elseif($upgrade){'Update OptiShade'}elseif($installed){'Already installed'}elseif($incomplete){'Repair required'}else{'Install OptiShade'}
 $install.IsEnabled=(-not $script:busy -and (-not $installed -or $upgrade) -and -not $incomplete -and [bool]$cached -and -not $cached.Error -and -not [string]::IsNullOrWhiteSpace($path.Text))
  $title=if($cached){[string]$cached.Game.Name}else{''}
 if($title){$form.FindName('SelectedTitle').Text=$title}
}

function RefreshLibrary([switch]$FromSnapshot){
 # Render the most recent snapshot immediately; verification runs off dispatcher.
 if(-not $FromSnapshot){RequestManagerStatusScan -Force}
 $selector=$form.FindName('MsfsCopies');$items=@($selector.ItemsSource)
 foreach($game in $items){
  $cached=GetCachedManagerGameStatus $game;if(-not $cached){continue};$state=$cached.State
  $game.State=$state;$game.Label="$($game.Name) / $($game.Launcher) - OptiShade $state"
  foreach($card in $script:libraryGames){
   if(-not [string]::Equals([string]$card.Folder,[string]$game.Folder,[StringComparison]::OrdinalIgnoreCase)){continue}
    $card.State=$state;$card.Installed=([bool]$cached.GameMissing -or $state -match '^Installed');$card.StatusColor=if($cached.GameMissing){'#F2C35C'}elseif($card.Installed){'#56D9A0'}elseif($state -match 'incomplete|not tracked|attention'){'#F2C35C'}else{'#A398BD'}
   $card.ActionLabel=if($card.Installed){'Manage'}elseif($state -match 'incomplete'){'Repair'}else{'Install'}
    $card.Description=if($cached.GameMissing){[string]$cached.Error}elseif($card.Installed){'OptiShade is installed for this game.'}elseif($state -match 'incomplete|not tracked'){'Review the detected files before installing.'}else{'OptiShade is not yet installed for this game.'}
    if($cached.GameMissing){$card.UpdateButtonVisibility=[Windows.Visibility]::Collapsed;$card.UpdateTarget='';$card.ComponentUpdateIds=@();continue}
   $info=GetGameUpdateInfo $game;$card.UpdateButtonVisibility=if($info.Target){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed};$card.UpdateTarget=$info.Target;$card.ComponentUpdateIds=@($info.Components)
   if($info.Target){$card.State=$info.Text;$card.StatusColor='#FFBE83';$card.Description='Select Update available to review this game.'}
  }
 }
 try{$selector.Items.Refresh()}catch{}
 UpdateLibraryGrid
 RefreshHomeState
}
function SelectGame($game){
 $matchingCopy=@($form.FindName('MsfsCopies').ItemsSource | Where-Object {$_.Folder -eq $game.Folder -and $_.Launcher -eq $game.Launcher}) | Select-Object -First 1
 if($matchingCopy){$form.FindName('MsfsCopies').SelectedItem=$matchingCopy}
 [void](SetSelectedFusionGame $game)
 $status.Text=$game.Label;ShowPage 'Setup'
}
$form.FindName('Help').Add_Click({
 [xml]$markup=@"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="OptiShade guides" Width="800" Height="700" MinWidth="600" MinHeight="450" WindowStyle="None" AllowsTransparency="True" ResizeMode="CanResizeWithGrip" WindowStartupLocation="CenterOwner" Background="Transparent" Foreground="#F3EFFB" FontFamily="Segoe UI">
<Border Background="{DynamicResource WindowGlass}" BorderBrush="#49355F" BorderThickness="1" CornerRadius="10"><Grid>
<Grid.RowDefinitions><RowDefinition Height="64"/><RowDefinition Height="Auto"/><RowDefinition/></Grid.RowDefinitions>
<Border Name="GuideHeader" Background="#11101E" CornerRadius="10,10,0,0"><Grid Margin="24,0,12,0"><TextBlock Text="OptiShade / Guides" FontSize="20" Foreground="#CEB5FA" VerticalAlignment="Center"/><Button Name="GuideClose" HorizontalAlignment="Right" VerticalAlignment="Center" Width="40" Height="36" Padding="12" Background="Transparent" ToolTip="Close"><Path Data="M0,0 L10,10 M10,0 L0,10" Stroke="#EEE8FA" StrokeThickness="1.3" Stretch="Uniform"/></Button></Grid></Border>
<ComboBox Name="Guide" Grid.Row="1" Margin="24,16,24,16" Foreground="#F3EFFB"/>
<Border Grid.Row="2" Margin="24,0,24,24" Background="{DynamicResource CardGlass}" BorderBrush="#40314F" BorderThickness="1" CornerRadius="10" Padding="18"><TextBox Name="Reading" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Hidden" HorizontalScrollBarVisibility="Hidden" Background="Transparent" Foreground="#EAE1F6" BorderThickness="0" Padding="0,0,12,0" FontSize="14"/></Border>
</Grid></Border></Window>
"@
 $helpWindow=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup));$helpWindow.Owner=$form;$helpWindow.Icon=$form.Icon
 $helpWindow.Height=[Math]::Min($helpWindow.Height,[Windows.SystemParameters]::WorkArea.Height-24)
 [xml]$guideTheme=Get-Content "$PSScriptRoot/dialog-theme.xaml" -Raw
 $helpWindow.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($guideTheme)))
 $helpWindow.FindName('GuideClose').Add_Click({$helpWindow.Close()})
 $helpWindow.FindName('GuideHeader').Add_MouseLeftButtonDown({if($_.ChangedButton -eq 'Left'){$helpWindow.DragMove()}})
 $guide=$helpWindow.FindName('Guide');$guide.Style=$form.FindResource([Windows.Controls.ComboBox]);$guide.ItemsSource=@('Tutorial','How it works','Features')
 $guide.Add_SelectionChanged({$file=@('Tutorial.txt','How-it-works.txt','Features.txt')[$guide.SelectedIndex];$helpWindow.FindName('Reading').Text=Get-Content -LiteralPath (Join-Path $PSScriptRoot ('Help/'+$file)) -Raw -Encoding UTF8})
 $guide.SelectedIndex=0;[void]$helpWindow.ShowDialog()
})
$form.FindName('HomeNav').Add_Click({ShowPage 'Home'})
$form.FindName('LibraryNav').Add_Click({ShowPage 'Library'})
$form.FindName('HomeOpenLibrary').Add_Click({ShowPage 'Library'})
$form.FindName('GitHub').Add_Click({Start-Process 'https://github.com/GamingWithGravy/OptiShade/releases/latest'})
$form.FindName('KeybindsNav').Add_Click({RefreshMenuKeys;ShowPage 'Keybinds'})
$form.FindName('SettingsNav').Add_Click({ShowPage 'Settings'})
. "$PSScriptRoot/driver-settings.ps1"
foreach($pair in @(@('SetupGuide','Help'),@('QuickSetup','SetupNav'),@('QuickUpdates','CheckUpdates'),@('ComponentCore','SetupNav'),@('ComponentDiagnostics','OpenTroubleshooter'),@('KeysChooseGame','SetupNav'),@('TroubleCompatibility','CheckCompatibility'))){
 $sourceControl=$form.FindName([string]$pair[0])
 $targetControl=$form.FindName([string]$pair[1])
 if(-not $sourceControl -or -not $targetControl){
  WriteInstallerLog ('Skipped optional home shortcut {0} -> {1}: named control was not present in the loaded manager window.' -f $pair[0],$pair[1])
  continue
 }
 $sourceControl.Add_Click({if($targetControl.IsEnabled){$targetControl.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}}.GetNewClosure())
 $buttons+=@($sourceControl)
}
$buttons+=@($form.FindName('ComponentsNav'))
$form.FindName('CopyHardware').Add_Click({[Windows.Clipboard]::SetText($form.FindName('Hardware').Text)})
$form.FindName('SetupNav').Add_Click({ShowPage 'Setup'})
$form.FindName('ComponentsNav').Add_Click({StartGlassCockpitReleaseCheck;ShowPage 'Components'})
$form.FindName('ComponentsPlay').Add_Click({
 if($script:busy){return}
 try{
  $game=$form.FindName('ComponentsGame').SelectedItem;if(-not $game){throw 'Choose a game first.'}
  [void](SetSelectedFusionGame $game);SyncMethodSelection
  $receipt=ReadOptiShadeState (ManifestPath $store $path.Text)
  if(-not $receipt -or $receipt.Status -ne 'Installed'){throw 'Finish installing or repairing this game before launching.'}
  $form.FindName('Play').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
 }catch{$status.Text=$_.Exception.Message}
})
$form.FindName('ComponentsGame').Add_SelectionChanged({
 if($script:refreshingComponentsGame){return}
 $game=$form.FindName('ComponentsGame').SelectedItem
 if(-not $game){return}
 $script:componentSelections=@{}
 if($script:pendingFxPresetPath){ClearPendingFxPreset;$status.Text='The queued preset was cleared because the selected game changed.'}
 try{[void](SetSelectedFusionGame $game)}catch{$path.Text='';ClearComponentsTargetSummary;$status.Text=$_.Exception.Message;$status.Foreground='#FFBE83';return}
 SyncMethodSelection;RefreshAddonCards
})
$form.FindName('HeaderComponentUpdateAvailable').Add_Click({ShowPage 'Updates'})
$form.FindName('AddonCockpitOpenRelease').Add_Click({ShowPage 'Updates'})
$form.FindName('UpdatesNav').Add_Click({ShowPage 'Updates';StartGlassCockpitReleaseCheck})
$form.FindName('UpdatesRefresh').Add_Click({
 if($script:busy){return}
 if($script:modularDistribution){
  RunAction {
   # Refresh is an inventory operation only. Check small signed manifests;
   # archive downloads happen at the selected update row, so one missing
   # optional channel cannot block unrelated components.
   RefreshModularComponentChannels
   RefreshLibrary;StartGlassCockpitReleaseCheck -Force;RefreshUpdateManager
  } 'Checking online component updates'
 }else{RefreshLibrary;StartGlassCockpitReleaseCheck -Force;RefreshUpdateManager}
})
$form.FindName('UpdatesVerify').Add_Click({if(-not $script:busy){StartManualVerification}})
$form.FindName('UpdatesAll').Add_Click({StartManagedUpdates})
$form.FindName('UpdatesManagerSettings').Add_Click({if(-not $script:busy){ShowPage 'Settings'}})
$form.FindName('UpdatesLoadPackage').Add_Click({
 if($script:busy){return}
 $picker=New-Object Microsoft.Win32.OpenFileDialog;$picker.Title='Select one package or a complete OptiShade package set';$picker.Filter='Component package|component-package.json';$picker.Multiselect=$true
 if($picker.ShowDialog($form)){
  try{
   $candidates=@($picker.FileNames|ForEach-Object {ReadLocalComponentPackageCandidate (Split-Path $_)})
   if($candidates.Count -eq 1){$candidate=$candidates[0]}
   else{
    if(@($candidates|Where-Object {$_.Schema -ne 2}).Count){throw 'Select one schema-1 package at a time. Multiple package selection is supported for schema-2 sets only.'}
    $setError=TestLocalComponentPackageSetContract $candidates;if($setError){throw $setError}
    $candidate=[pscustomobject]@{Schema=2;Catalog=[pscustomobject]@{Schema=2;Id='PackageSet';Version=([string]$candidates.Count+' packages')};Packages=@($candidates);Identity=(@($candidates|ForEach-Object {[string]$_.Identity}|Sort-Object) -join ':');Stage=$null;StageCacheRoot=''}
   }
   $script:localComponentPackage=$candidate;RequestManagerStatusScan -Force
   $form.FindName('UpdatesActivity').Text=if(TestLocalComponentPackageSelectionSet $candidate){'Complete schema-2 set selected. Review the matching installed game, then choose Stage package set; game files remain untouched.'}elseif($candidate.Catalog.Schema -eq 2){'Read-only package selected. Review the matching installed game, then choose Stage package; this does not change game files.'}else{'Local package selected. Review the matching game updates below, then choose Update component.'}
   RefreshHeaderComponentUpdateState;RefreshUpdateManager
  }catch{$form.FindName('UpdatesActivity').Text='Package not selected: '+$_.Exception.Message}
 }
})
$form.FindName('UpdatesClearPackage').Add_Click({if(-not $script:busy){$script:localComponentPackage=$null;RequestManagerStatusScan -Force;RefreshHeaderComponentUpdateState;RefreshUpdateManager}})
function AddManualGameToLibrary{
 $picker=New-Object Windows.Forms.FolderBrowserDialog
 $picker.Description='Choose the game folder or a library root. OptiShade will search for the simulator and guide you if it finds more than one.'
 $picker.ShowNewFolderButton=$false
 try{
  if($picker.ShowDialog() -ne 'OK'){return}
  $selectedRoot=ResolveOptiShadeLibraryPath $picker.SelectedPath
  $folder=ResolveFusionInstallFolder $selectedRoot
  AssertFusionPhysicalFolder $folder
  $title=GetMsfsTitle $folder
  if(-not $title){$title=GetFusionFolderTitle $folder}
  $launcher=if(($selectedRoot+' '+$folder) -match '(?i)\\steamapps\\common\\'){'Steam'}elseif(($selectedRoot+' '+$folder) -match '(?i)\\XboxGames?\\' -or (Test-Path -LiteralPath (Join-Path $folder 'gamelaunchhelper.exe')) -or (Test-Path -LiteralPath (Join-Path $folder 'MicrosoftGame.Config'))){'Xbox'}else{'Added by you'}
  $executables=@(FindFusionExecutable $folder $launcher $title)
  if($executables.Count -ne 1){
   $known=@(GetFusionKnownSimulatorExecutableCandidates $selectedRoot)
   if($known.Count -eq 1){
    $candidate=$known[0].Path;$candidateFolder=Split-Path $candidate -Parent
    $title=GetMsfsTitle $candidateFolder;if(-not $title){$title=[IO.Path]::GetFileNameWithoutExtension($candidate)}
    $folder=$candidateFolder;$launcher=if(($selectedRoot+' '+$candidateFolder) -match '(?i)\\steamapps\\common\\'){'Steam'}elseif(($selectedRoot+' '+$candidateFolder) -match '(?i)\\XboxGames?\\' -or (Test-Path -LiteralPath (Join-Path $candidateFolder 'gamelaunchhelper.exe')) -or (Test-Path -LiteralPath (Join-Path $candidateFolder 'MicrosoftGame.Config'))){'Xbox'}else{'Added by you'}
    $executables=@([pscustomobject]@{Path=$candidate;Score=1000})
   }else{
    $exePicker=New-Object Windows.Forms.OpenFileDialog;$exePicker.Title=if($known.Count){'Select the game to add'}else{'Select the game executable'};$exePicker.Filter='Game executable (*.exe)|*.exe';$exePicker.InitialDirectory=$selectedRoot
    try{
     if($exePicker.ShowDialog() -ne 'OK'){throw 'No game executable was selected. Choose a game folder or library root to try again.'}
     $selectedExe=ResolveOptiShadeLibraryPath $exePicker.FileName
     if(-not $selectedExe.StartsWith($selectedRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Choose an executable inside the folder you selected.'}
     AssertFusionPhysicalFolder (Split-Path $selectedExe -Parent);AssertFusionExecutable $selectedExe
     $selectedExe=ResolveFusionBootstrapExecutable $selectedExe;$folder=Split-Path $selectedExe -Parent
     $title=GetMsfsTitle $folder
     if(-not $title){$product=[Diagnostics.FileVersionInfo]::GetVersionInfo($selectedExe).ProductName;$title=if($product -and $product -notmatch '(?i)Microsoft Windows'){[string]$product}else{[IO.Path]::GetFileNameWithoutExtension($selectedExe)}}
     $launcher=if(($selectedRoot+' '+$folder) -match '(?i)\\steamapps\\common\\'){'Steam'}elseif(($selectedRoot+' '+$folder) -match '(?i)\\XboxGames?\\' -or (Test-Path -LiteralPath (Join-Path $folder 'gamelaunchhelper.exe')) -or (Test-Path -LiteralPath (Join-Path $folder 'MicrosoftGame.Config'))){'Xbox'}else{'Added by you'}
     $executables=@([pscustomobject]@{Path=$selectedExe;Score=1000})
    }finally{$exePicker.Dispose()}
   }
  }
  if($executables.Count -ne 1){throw "OptiShade could not identify one game executable under '$selectedRoot'. Select the game's own folder or choose its executable when prompted."}
  $folder=Split-Path ([string]$executables[0].Path) -Parent
  $entry=[pscustomobject]@{Name=$title;Folder=$folder;Launcher=$launcher;State=(GetFusionInstallState $store $folder);Label=''}
  $key=GetFusionLibraryGameKey $entry
  if($script:removedGames -and $script:removedGames.ContainsKey($key)){[void]$script:removedGames.Remove($key);SaveLibraryPreferences}
  $all=@($script:libraryGames|ForEach-Object {[pscustomobject]@{Name=$_.Name;Folder=$_.Folder;Launcher=$_.Launcher;State=$_.State;Label=$_.Label;InstallFolder=$_.InstallFolder;Artwork=$_.Artwork}})
  if(-not @($all|Where-Object {(GetFusionLibraryGameKey $_) -eq $key}).Count){$all+= $entry}
  ShowGames $all
  $added=@($form.FindName('MsfsCopies').ItemsSource|Where-Object {(GetFusionLibraryGameKey $_) -eq $key}|Select-Object -First 1)
  if($added.Count){SelectGame $added[0];$status.Text='Game added to your library. Review the selected install folder, then choose Install OptiShade.'}
 }catch{$status.Text='Could not add game: '+$_.Exception.Message;$status.Foreground='#FFBE83'}finally{$picker.Dispose()}
}
$form.FindName('AddGame').Add_Click({AddManualGameToLibrary})
$form.FindName('LibraryGames').AddHandler([Windows.Controls.Button]::ClickEvent,[Windows.RoutedEventHandler]{param($sender,$e)
 try{$source=$e.OriginalSource;while($source -and -not($source -is [Windows.Controls.Button])){$source=[Windows.Media.VisualTreeHelper]::GetParent($source)};if($source -and $source.DataContext){$game=$source.DataContext;if($source.Tag -eq 'remove'){RemoveLibraryGameEntry $game;$e.Handled=$true;return};if($source.Tag -eq 'favorite'){$key=[string]$game.FavoriteKey;if($script:favoriteGames.ContainsKey($key)){$script:favoriteGames.Remove($key)}else{$script:favoriteGames[$key]=$true};foreach($card in $script:libraryGames){if($card.FavoriteKey -eq $key){$card.IsFavorite=$script:favoriteGames.ContainsKey($key);$card.FavoriteGlyph=if($card.IsFavorite){'★'}else{'☆'};$card.FavoriteTip=if($card.IsFavorite){'Remove from favorites'}else{'Add to favorites'}}};SaveLibraryPreferences;UpdateLibraryGrid;$e.Handled=$true;return};if($source.Tag -eq 'update'){SelectGame $game;if($game.UpdateTarget){ShowPage 'Updates'};$e.Handled=$true;return};SelectGame $game;if($source.Tag -eq 'primary' -and $game.Installed -and -not $script:busy){$form.FindName('Play').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}}}catch{$status.Text=$_.Exception.Message}
},$true)
$form.FindName('LibraryInstalledFirst').Add_Click({$script:libraryPreferences.InstalledFirst=[bool]$form.FindName('LibraryInstalledFirst').IsChecked;SaveLibraryPreferences;UpdateLibraryGrid})
$form.FindName('LibraryFavoritesOnly').Add_Click({$script:libraryPreferences.FavoritesOnly=[bool]$form.FindName('LibraryFavoritesOnly').IsChecked;SaveLibraryPreferences;UpdateLibraryGrid})
function ChooseGameExe{
 $launcher=if($script:gameRoot -and (($path.Text -eq $script:gameRoot) -or $path.Text.StartsWith($script:gameRoot+'\',[StringComparison]::OrdinalIgnoreCase))){$script:gameLauncher}else{''};$gameTitle=[string]$form.FindName('SelectedTitle').Text;$searchRoot=if($launcher -and $script:gameRoot){$script:gameRoot}else{$path.Text};$files=@(FindFusionExecutable $searchRoot $launcher $gameTitle);$script:selectedNativeLaunchExe=$null
 if($files.Count -eq 1 -or ($files.Count -gt 1 -and $files[0].Score -gt $files[1].Score)){$path.Text=Split-Path $files[0].Path;$script:selectedNativeLaunchExe=$files[0].LaunchPath;return $files[0].Path}
 $dialog=New-Object Windows.Forms.OpenFileDialog;$dialog.Filter='Game executable|*.exe';$dialog.Title='Choose the actual game EXE';$dialog.InitialDirectory=$path.Text;if($files.Count){$dialog.InitialDirectory=Split-Path $files[0].Path;$dialog.FileName=$files[0].Path}
 try{if($dialog.ShowDialog() -eq 'OK'){$resolved=ResolveFusionBootstrapExecutable $dialog.FileName;$script:selectedNativeLaunchExe=$dialog.FileName;$path.Text=Split-Path $resolved;return $resolved}}finally{$dialog.Dispose()}
 return $null
}
$form.FindName('Scan').Add_Click({RunAction {
 $status.Text='Refreshing your game library...';$form.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)
  $found=@(GetFusionGameArtwork @(FindFusionGames $store $progress));$form.FindName('MsfsCopies').ItemsSource=$found;ShowGames $found
 if($script:cachedSystem){$script:cachedSystem.Games=$found;SaveStartupCache $script:cachedSystem}
  $status.Text='Library refreshed. Use Add a game for any title the scan missed.'
 } 'Scanning installed games'})
function StartOptiMfgController($Manifest){
 if(-not $Manifest -or 'OptiMfg' -notin @(GetOptiShadeAddonSelection $Manifest)){throw 'Install the OptiMFG component for this game first.'}
 if(-not(Test-Path -LiteralPath (OwnedPath $Manifest.Game 'FlightSimulator2024.exe')) -and -not(Test-Path -LiteralPath (OwnedPath $Manifest.Game 'FlightSimulator.exe'))){throw 'This bundled OptiMFG build currently detects Microsoft Flight Simulator 2020 and 2024 only.'}
 if(TestOptiMfgComponentNeedsRepair $Manifest){throw 'OptiMFG backend preparation is incomplete. Close the game, open Update Manager and update the OptiMFG component before starting it.'}
 $exe=OwnedPath $Manifest.Game 'OptiShadeData/OptiMFG/Runtime/OptiMFG_Live.exe'
 if(-not(Test-Path -LiteralPath $exe -PathType Leaf)){throw 'The installed OptiMFG controller is missing. Reinstall the component before starting it.'}
 if(@(Get-Process -Name 'OptiMFG_Live' -ErrorAction SilentlyContinue).Count){WriteInstallerLog ('OptiMFG already running for '+$Manifest.Game);return 'already running'}
 Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe -Parent) -ArgumentList '--tray' -WindowStyle Hidden -ErrorAction Stop
 WriteInstallerLog ('OptiMFG controller started in tray mode for '+$Manifest.Game)
 return 'started'
}
$form.FindName('Play').Add_Click({RunAction {
 $mp=ManifestPath $store $path.Text;$exe=$null;$m=$null
 if(Test-Path -LiteralPath $mp){$m=ReadOptiShadeState $mp;$exe=$m.LaunchExe}
 if(-not $exe -or -not(Test-Path -LiteralPath $exe)){$exe=ChooseGameExe}
 if($exe){
  AssertFusionExecutable $exe
  $leaf=Split-Path $exe -Leaf
  $identity=GetOptiShadeExecutableIdentity $exe
  $method=GetSelectedMethod
  $installedMethod=GetOptiShadeInstalledLoaderPath $m
  if($leaf -eq 'X-Plane.exe'){$effectiveMethod='dxgi.dll';$renderer='Vulkan'}
  else{
   if($method -eq 'auto'){
    if($installedMethod -in @('winmm.dll','dxgi.dll','d3d12.dll','version.dll','dbghelp.dll','d3d9.dll','opengl32.dll')){$effectiveMethod=$installedMethod}
    else{$detected=ResolveOptiShadeRendererApi 'auto' $identity.ApiCandidates;$effectiveMethod=if($detected -eq 'Auto'){'dxgi.dll'}else{GetOptiShadeRendererProxy $detected 'dxgi.dll' ($identity.Architecture -eq 'x86')}}
   }else{$effectiveMethod=ResolveOptiShadeInstallMethod $method}
   $renderer=GetOptiShadeMethodRendererApi $method $effectiveMethod $identity.ApiCandidates -Executable $exe
  }
  $autoMfgMessage=''
  if($m){
   if($leaf -ne 'X-Plane.exe' -and $leaf -ne 'gamelaunchhelper.exe' -and
      (-not $installedMethod -or $installedMethod -ne $effectiveMethod)){
    throw "This installation uses a different OptiShade method. Click Repair to install the selected method ($effectiveMethod) before Play."
   }
   $m|Add-Member -NotePropertyName InstallMethod -NotePropertyValue $method -Force
   $m|Add-Member -NotePropertyName RendererApi -NotePropertyValue $renderer.ToLowerInvariant() -Force
   WriteState $m $mp

  }
   # Launch never installs optional components or enables rendering features.
   if($m){
    WriteInstallerLog ("Play receipt: path={0}; status={1}; game={2}; launchExe={3}" -f $mp,[string]$m.Status,[string]$m.Game,[string]$m.LaunchExe)
    try{StartManagerAutoSession $m -ObserveOnly}catch{WriteInstallerLog ('Live status observation unavailable: '+$_.Exception.Message)}
   }
  WriteInstallerLog ("Play requested renderer={0}; method={1}; installedMethod={2}; executable={3}" -f $renderer,$method,$effectiveMethod,[IO.Path]::GetFileName($exe))
  try{
   if($renderer -eq 'Vulkan' -and $leaf -ne 'gamelaunchhelper.exe'){StartOptiShadeXPlane $exe $store}
   elseif($leaf -eq 'gamelaunchhelper.exe'){Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) -ErrorAction Stop}
   else{StartOptiShadeDirectGame (GetFusionNativeLaunchExecutable $m $exe)}
  }catch{$script:autoIntent=$null;throw}
   $launchMessage=if($leaf -eq 'gamelaunchhelper.exe'){'Launch requested using the clean Xbox/MS Store helper path. No custom arguments were added.'}elseif($leaf -eq 'X-Plane.exe'){'Launch requested with OptiShade Vulkan/OpenXR process layers. Restore only after closing the game.'}elseif($renderer -eq 'Vulkan'){'Launch requested with the OptiShade process-scoped Vulkan layer. Restore only after closing the game.'}else{'Launch requested through the DirectX graphics entry point. Runtime attachment is still unconfirmed.'}
   $status.Text=$launchMessage+$autoMfgMessage
 }
}})
# Library, hardware and update checks run in another runspace so the splash stays responsive.
$script:startupReady=$false;$script:startupFailed=$false;$script:startupComponentChecksStarted=$null;$script:componentCheckWarning=''
$script:gpu=[pscustomobject]@{Names='Checking';Nvidia=$false;Known=$false}
$script:startupProgress=[hashtable]::Synchronized(@{Stage='Loading your saved setup...'})
$script:startup=(NewOptiShadeManagerWorker)
function SaveStartupCache($data){
 New-Item -ItemType Directory -Path $store -Force|Out-Null
 WriteState $data $script:cachePath
}
function RestoreStartupCache{
 try{
  if(-not(Test-Path -LiteralPath $script:cachePath -PathType Leaf)){return}
  $saved=Get-Content -LiteralPath $script:cachePath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
  $cachedGames=@($saved.Games)
  if(-not $cachedGames.Count){return}
  $script:cachedSystem=$saved
  if($saved.Gpu){$script:gpu=$saved.Gpu}
  $form.FindName('MsfsCopies').ItemsSource=$cachedGames
  $form.FindName('MsfsCopies').SelectedIndex=0
  ShowGames $cachedGames -SkipUpdateCheck -SkipProtectionCheck
  RefreshComponentsGameSelector
 }catch{WriteInstallerLog ('Saved game list could not be loaded: '+$_.Exception.Message)}
}
[void]$script:startup.AddScript({param($lib,$store,$cache,$progress,$snapshotModule,$ownershipModule,$antiCheatModule,$rulesPath,$managerPath,$managerVersion,$modular)
 . $lib
 . $snapshotModule
 . $ownershipModule
 . $antiCheatModule
 $progress.Stage='Loading your saved setup...';$saved=$null
 if(Test-Path -LiteralPath $cache){try{$saved=Get-Content -LiteralPath $cache -Raw -Encoding UTF8|ConvertFrom-Json}catch{}}
 $snapshotError='';try{$null=EnsureOptiShadeSnapshotLibrary (GetOptiShadeSnapshotParent)}catch{$snapshotError=$_.Exception.Message}
 $games=@();$scanError='';$progress.Stage='Scanning libraries...'
 try{$games=@(GetFusionGameArtwork @(FindFusionGames $store))}catch{$scanError=$_.Exception.Message;if($saved -and @($saved.Games).Count){$games=@($saved.Games)}}
 $protection=[Collections.Generic.List[object]]::new()
 if($games.Count){
  $progress.Stage='Checking library protection...'
  $protectionWatch=[Diagnostics.Stopwatch]::StartNew();$protectionBudgetMs=12000
  foreach($game in $games){
   if($protectionWatch.ElapsedMilliseconds -ge $protectionBudgetMs){$protection.Add([pscustomobject]@{Folder=[string]$game.Folder;Label='Check incomplete';Detail='The quick check reached its time limit. Anti-cheat status is unknown until the install check completes.';State='Check incomplete';Completed=$false});continue}
   try{$target=GetAntiCheatTarget ([string]$game.Folder);$protection.Add((GetAntiCheatLibraryCardResult $target $rulesPath 1500 -Folder ([string]$game.Folder)))}
   catch{$protection.Add([pscustomobject]@{Folder=[string]$game.Folder;Label='Check incomplete';Detail='The quick check was unavailable. Anti-cheat status is unknown until the install check completes.';State='Check incomplete';Completed=$false})}
  }
  $protectionWatch.Stop()
 }
 $progress.Stage='Checking hardware...';$gpu=[pscustomobject]@{Names='Unavailable';Nvidia=$false;Known=$false};$cpu='';$driver='';$ram=0;$os='';$hardwareError=''
 try{$gpu=GetFusionGpu}catch{$hardwareError=$_.Exception.Message}
 try{$cpu=@(Get-CimInstance Win32_Processor -OperationTimeoutSec 5 -ErrorAction Stop|ForEach-Object {$_.Name}) -join ', '}catch{if(-not $hardwareError){$hardwareError=$_.Exception.Message}}
 try{$driver=@(Get-CimInstance Win32_VideoController -OperationTimeoutSec 5 -ErrorAction Stop|ForEach-Object {$_.Name+': '+$_.DriverVersion}) -join "`n"}catch{if(-not $hardwareError){$hardwareError=$_.Exception.Message}}
 try{
  $moduleMemory=@(Get-CimInstance Win32_PhysicalMemory -OperationTimeoutSec 5 -ErrorAction Stop|Where-Object {[double]$_.Capacity -gt 0})
  if($moduleMemory.Count){$ramBytes=($moduleMemory|Measure-Object -Property Capacity -Sum).Sum}
  else{$ramBytes=(Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 5 -ErrorAction Stop).TotalPhysicalMemory}
  $ram=[math]::Round([double]$ramBytes/1GB,0,[MidpointRounding]::AwayFromZero)
 }catch{
  try{$ramBytes=(Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 5 -ErrorAction Stop).TotalPhysicalMemory;$ram=[math]::Round([double]$ramBytes/1GB,0,[MidpointRounding]::AwayFromZero)}catch{if(-not $hardwareError){$hardwareError=$_.Exception.Message}}
 }
 try{$os=(Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 5 -ErrorAction Stop).Caption}catch{if(-not $hardwareError){$hardwareError=$_.Exception.Message}}
 $update=$null;$updateError='';$progress.Stage='Checking for OptiShade updates...'
 try{. (Join-Path (Split-Path $lib) 'updates.ps1');if($modular){$update=GetOptiShadeModularUpdate -Current $managerVersion -ManagerPath $managerPath}else{$update=GetOptiShadeUpdate -ReportErrors}}catch{$updateError=$_.Exception.Message}
 $progress.Stage='Opening the main app...'
 [pscustomobject]@{Version=1;Gpu=$gpu;Cpu=$cpu;Driver=$driver;Ram=[math]::Round([double]$ram/1GB);OS=$os;Games=$games;ProtectionResults=@($protection.ToArray());ScanError=$scanError;HardwareError=$hardwareError;Update=$update;UpdateError=$updateError;SnapshotError=$snapshotError}
}).AddArgument("$PSScriptRoot/library.ps1").AddArgument($store).AddArgument($script:cachePath).AddArgument($script:startupProgress).AddArgument("$PSScriptRoot/snapshot-library.ps1").AddArgument("$PSScriptRoot/ownership.ps1").AddArgument("$PSScriptRoot/anti-cheat.ps1").AddArgument("$PSScriptRoot/anti-cheat-rules.json").AddArgument($Installer).AddArgument((GetOptiShadeManagerCompatibilityVersion)).AddArgument([bool]$script:modularDistribution)
$script:startupResult=$script:startup.BeginInvoke()
$script:introStart=Get-Date
$script:startupTimer=New-Object Windows.Threading.DispatcherTimer
$script:startupTimer.Interval=[TimeSpan]::FromMilliseconds(150)

function CompleteManagerStartup{
 $script:startupTimer.Stop()
 $script:startupReady=-not $script:startupFailed
 RefreshHeaderComponentUpdateState
 $form.FindName('IntroProgress').IsIndeterminate=$false;$form.FindName('IntroProgress').Value=100
 $form.FindName('StartupNavigation').IsEnabled=$true;$form.FindName('StartupContent').IsEnabled=$true
 $form.FindName('Intro').Visibility='Collapsed'
 try{RefreshHomeState;if(-not $UninstallMode){ShowReleaseNotes $form $store -Payload $Payload -ManagerPath $Installer}}catch{WriteInstallerLog ('Startup display failed: '+$_.Exception.Message);$status.Text='Startup display needs attention: '+$_.Exception.Message;$status.Foreground='#FFBE83'}
 if($UninstallMode){WriteInstallerLog 'Uninstall mode: startup finished, opening the uninstall page.';$form.Dispatcher.BeginInvoke([Action]{try{$button=$form.FindName('Uninstall');$button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))}catch{WriteInstallerLog ('Uninstall wizard could not open: '+$_.Exception.Message);[void](ShowOptiShadeDialog ($form) ($_.Exception.Message) ('OptiShade uninstall') ('OK') ('Error'))}},[Windows.Threading.DispatcherPriority]::Normal)|Out-Null}
}
RegisterOptiShadeManagerTimer $script:startupTimer {
 if($script:busy){return}
 if(-not $script:startupResult -and $script:startupComponentChecksStarted){
  $check=GetStartupComponentCheckState
  $waiting=$check -like 'Checking*' -or $check -like 'Waiting*'
  $form.FindName('IntroStatus').Text='Checking component updates...'
  if($waiting -and ([DateTime]::UtcNow-$script:startupComponentChecksStarted).TotalSeconds -lt 60){return}
  $script:componentCheckWarning=$check
  CompleteManagerStartup
  return
 }
 if($script:startupProgress.Stage -and $form.FindName('IntroStatus').Text -ne $script:startupProgress.Stage){$form.FindName('IntroStatus').Text=$script:startupProgress.Stage}
 if($script:startupResult -and $script:startupResult.IsCompleted){
  try{
   $result=@($script:startup.EndInvoke($script:startupResult))[-1];$script:gpu=$result.Gpu;$script:cachedSystem=$result;SaveStartupCache $result
   $form.FindName('Hardware').Text="$($script:gpu.Names) | $($result.Ram) GB RAM | $($result.OS)"
   $form.FindName('HardwareGpu').Text=if($script:gpu.Names){$script:gpu.Names}else{'Unavailable'}
   $form.FindName('HardwareCpu').Text=if($result.Cpu){$result.Cpu}else{'Unavailable'}
   $form.FindName('HardwareRam').Text=if($result.Ram){[string]$result.Ram+' GB RAM'}else{'Unavailable'}
   $form.FindName('HardwareDriver').Text=if($result.Driver){$result.Driver}else{'Unavailable'}
   $form.FindName('IntroStatus').Text='Checking component updates...'
   $copies=@($result.Games)
   if($result.Update -and $result.Update.ChannelUnavailable){$script:availableUpdate=$null;$form.FindName('UpdateAvailable').Visibility='Collapsed';SetHeaderVersionState 'Unavailable'}elseif($result.Update -and -not $result.Update.Rollback -and $result.Update.Channel -eq (GetOptiShadeUpdateChannel)){$script:availableUpdate=$result.Update;$form.FindName('UpdateAvailable').Content=GetOptiShadeUpdateLabel $result.Update;$form.FindName('UpdateAvailable').Visibility='Visible';SetHeaderVersionState 'Available'}elseif($result.UpdateError){SetHeaderVersionState 'Error'}else{SetHeaderVersionState 'Current'}
   ApplyStartupGameResults $copies @($result.ProtectionResults)
   $script:startupComponentChecksStarted=[DateTime]::UtcNow
   $protectionIncomplete=@($result.ProtectionResults|Where-Object {-not $_.Completed}).Count
   $status.Text=GetStartupLibraryStatus $result.ScanError $result.SnapshotError $copies.Count $protectionIncomplete
   if($result.SnapshotError){$status.Foreground='#FFBE83'}else{$status.Foreground='#BDA0F4'}
  }catch{$script:startupReady=$false;$script:startupFailed=$true;WriteInstallerLog ('Startup refresh failed: '+$_.Exception.Message+' '+$_.ScriptStackTrace);$status.Text='Startup refresh needs attention: '+$_.Exception.Message;$status.Foreground='#FFBE83';$form.FindName('Hardware').Text='Hardware detection was unavailable. Choose settings in game after checking your graphics card.';foreach($name in @('HardwareGpu','HardwareCpu','HardwareRam','HardwareDriver')){$form.FindName($name).Text='Unavailable'}}
  finally{RemoveOptiShadeManagerWorker $script:startup;$script:startupResult=$null;if($script:startupFailed){CompleteManagerStartup}}
 }
}
function ApplyStartupGameResults($Copies,$ProtectionResults=@()){
 # Preserve a cached selection/path while the startup splash covers discovery.
 $selector=$form.FindName('MsfsCopies');$previous=$selector.SelectedItem;$previousPath=[string]$path.Text
 $selector.ItemsSource=@($Copies)
 $matching=@($Copies|Where-Object {$previous -and [string]::Equals([string]$_.Folder,[string]$previous.Folder,[StringComparison]::OrdinalIgnoreCase)}|Select-Object -First 1)
 if($matching.Count){$selector.SelectedItem=$matching[0]}
 elseif(-not $previousPath -and @($Copies).Count){$selector.SelectedIndex=0}
 ShowGames $Copies -SkipProtectionCheck
 foreach($card in $script:libraryGames){
  $found=@($ProtectionResults|Where-Object {[string]::Equals([string]$_.Folder,[string]$card.Folder,[StringComparison]::OrdinalIgnoreCase)}|Select-Object -First 1)
  if($found.Count){SetFusionCardProtectionResult $card ([string]$found[0].Label) ([string]$found[0].Detail)}
  else{SetFusionCardProtectionResult $card 'Check incomplete' 'The quick check did not return a result. Anti-cheat status is unknown until the install check completes.'}
 }
 UpdateLibraryGrid
 if($previousPath){$path.Text=$previousPath}
 RequestManagerStatusScan
}
function UpdateDetectedStore {
 $selected=$form.FindName('MsfsCopies').SelectedItem
 if($selected){$card=@($script:libraryGames|Where-Object Folder -eq $selected.Folder)|Select-Object -First 1;$form.FindName('SelectedIcon').Source=if($card){$card.Thumbnail}else{$form.Icon}}
 $form.FindName('DetectedStore').Text=if($selected){GetDetectedStoreDisplay $selected}else{'Choose a game'}
}
$form.FindName('MsfsCopies').Add_SelectionChanged({$copy=$form.FindName('MsfsCopies').SelectedItem;if($copy){try{[void](SetSelectedFusionGame $copy)}catch{$path.Text='';$status.Text=$_.Exception.Message;$status.Foreground='#FFBE83'}};UpdateDetectedStore})

$form.FindName('TroubleshootingNav').Add_Click({ShowPage 'Troubleshooting'})
$buttons+=@($form.FindName('OpenTroubleshooter'))
function OpenDiagnosticTool([switch]$LauncherOnly) {
 $tool=Join-Path $PSScriptRoot 'OptiShade-Troubleshooter.exe'
 if(-not(Test-Path -LiteralPath $tool -PathType Leaf)){throw 'The troubleshooting tool is missing from this manager package. Re-download this build.'}
 $arguments=@();if($LauncherOnly){$arguments+='--launcher-only'}
 if($LauncherOnly){Start-Process -FilePath $tool -ArgumentList '--launcher-only' -WindowStyle Normal -ErrorAction Stop | Out-Null}
 else{Start-Process -FilePath $tool -WindowStyle Normal -ErrorAction Stop | Out-Null}
 $status.Text=if($LauncherOnly){'Troubleshooter opened with launcher and installer logs selected.'}else{'Troubleshooter opened. Choose the game and diagnostic sources, then collect one report.'}
}
$script:restoreKeepPresets=$true
function NewManagerPopup([string]$Title,[string]$Subtitle=''){
 $workHeight=[double][Windows.SystemParameters]::WorkArea.Height;$maxHeight=[Math]::Max(380,[Math]::Min(760,$workHeight-48));$window=New-Object Windows.Window;$window.Title=$Title;$window.Width=[double]680;$window.Height=[double][Math]::Min(500,$maxHeight);$window.MinWidth=[double]560;$window.MaxWidth=[double]760;$window.MinHeight=[double][Math]::Min(380,$maxHeight);$window.MaxHeight=[double]$maxHeight;$window.SizeToContent=[Windows.SizeToContent]::Manual;$window.Owner=$form;$window.WindowStartupLocation='CenterOwner';$window.ShowInTaskbar=$false;$window.WindowStyle='None';$window.ResizeMode='NoResize';$window.AllowsTransparency=$true;$window.Background=[Windows.Media.BrushConverter]::new().ConvertFromString('Transparent');$window.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#F3EFFB');$window.FontFamily='Segoe UI';$window.UseLayoutRounding=$true
 $window.Resources.MergedDictionaries.Add($form.Resources)
 foreach($type in @([Windows.Controls.Button],[Windows.Controls.CheckBox],[Windows.Controls.ComboBox],[Windows.Controls.ComboBoxItem])){try{$window.Resources[$type]=$form.FindResource($type)}catch{}}
 $grid=New-Object Windows.Controls.Grid;$grid.Margin='22';[void]$grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{Height='Auto'}));[void]$grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{Height='Auto'}));[void]$grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{Height='*'}));[void]$grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{Height='Auto'}))
 $heading=New-Object Windows.Controls.DockPanel;$heading.LastChildFill=$true
 $close=New-Object Windows.Controls.Button;$close.Content='Close';$close.Padding='12,6';$close.Margin='12,0,0,0';$close.MinWidth=68;$close.Background=[Windows.Media.BrushConverter]::new().ConvertFromString('#282136');$close.BorderBrush=[Windows.Media.BrushConverter]::new().ConvertFromString('#634878');[Windows.Controls.DockPanel]::SetDock($close,'Right');[void]$heading.Children.Add($close)
 $titleText=New-Object Windows.Controls.TextBlock;$titleText.Text=$Title;$titleText.FontSize=22;$titleText.FontWeight='SemiBold';$titleText.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#F3EFFB');[void]$heading.Children.Add($titleText);[Windows.Controls.Grid]::SetRow($heading,0);[void]$grid.Children.Add($heading)
 $subtitleText=New-Object Windows.Controls.TextBlock;$subtitleText.Text=$Subtitle;$subtitleText.TextWrapping='Wrap';$subtitleText.Margin='0,8,0,14';$subtitleText.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#C0AEDF');[Windows.Controls.Grid]::SetRow($subtitleText,1);[void]$grid.Children.Add($subtitleText)
 $scroll=New-Object Windows.Controls.ScrollViewer;$scroll.VerticalScrollBarVisibility='Auto';$scroll.HorizontalScrollBarVisibility='Disabled';$body=New-Object Windows.Controls.StackPanel;$scroll.Content=$body;[Windows.Controls.Grid]::SetRow($scroll,2);[void]$grid.Children.Add($scroll)
 $footer=New-Object Windows.Controls.StackPanel;$footer.Orientation='Horizontal';$footer.HorizontalAlignment='Right';$footer.Margin='0,16,0,0';[Windows.Controls.Grid]::SetRow($footer,3);[void]$grid.Children.Add($footer)
 $frame=New-Object Windows.Controls.Border;$frame.Background=[Windows.Media.BrushConverter]::new().ConvertFromString('#14121F');$frame.BorderBrush=[Windows.Media.BrushConverter]::new().ConvertFromString('#55406C');$frame.BorderThickness='1';$frame.CornerRadius='12';$frame.Child=$grid
 $window.Content=$frame;$close.Add_Click({$window.Close()}.GetNewClosure());$heading.Add_MouseLeftButtonDown({if($_.ChangedButton -eq 'Left' -and $_.OriginalSource -is [Windows.Controls.TextBlock]){$window.DragMove()}}.GetNewClosure())
 return [pscustomobject]@{Window=$window;Body=$body;Footer=$footer;Subtitle=$subtitleText}
}
function ShowManagerPopup($Popup){
 try{[void](InvokeWithOperationProgressHidden {$Popup.Window.ShowDialog()})}
 catch{$message='Could not open '+$Popup.Window.Title+': '+$_.Exception.Message;WriteInstallerLog ($message+' | '+$_.ScriptStackTrace);$status.Text=$message;$status.Foreground='#FFBE83'}
}
function NewPopupComboBox($Popup,$Items,[string]$DisplayMemberPath){
 $picker=New-Object Windows.Controls.ComboBox;$picker.Style=$form.FindResource([Windows.Controls.ComboBox]);$picker.Margin='0,0,0,12';$picker.MinHeight=40;$picker.DisplayMemberPath=$DisplayMemberPath;$picker.ItemsSource=$Items;[void]$Popup.Body.Children.Add($picker);return $picker
}
function AddPopupText($Popup,[string]$Text,$FontSize=14,[string]$Color='#C0AEDF'){
 $font=14.0;$parsed=0.0
 if([double]::TryParse([string]$FontSize,[ref]$parsed) -and $parsed -ge 8 -and $parsed -le 48){$font=$parsed}
 elseif([string]$FontSize -match '^#[0-9A-Fa-f]{6,8}$' -and $Color -eq '#C0AEDF'){$Color=[string]$FontSize}
 $label=New-Object Windows.Controls.TextBlock;$label.Text=$Text;$label.FontSize=$font;$label.TextWrapping='Wrap';$label.Margin='0,4,0,10';$label.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString($Color);[void]$Popup.Body.Children.Add($label);return $label
}
function AddPopupButton($Popup,[string]$Text,[bool]$Primary=$false){
 $button=New-Object Windows.Controls.Button;$button.Style=$form.FindResource([Windows.Controls.Button]);$button.Content=$Text;$button.Padding='14,8';$button.Margin='8,0,0,0';$button.MinWidth=90;$button.MinHeight=38;$button.Background=[Windows.Media.BrushConverter]::new().ConvertFromString($(if($Primary){'#7624E8'}else{'#282136'}));$button.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#F3EFFB');$button.BorderBrush=[Windows.Media.BrushConverter]::new().ConvertFromString($(if($Primary){'#A267F4'}else{'#634878'}));[void]$Popup.Footer.Children.Add($button);return $button
}
function GetManagedInstallations{
 $list=New-Object 'System.Collections.Generic.List[object]';$root=Join-Path $store 'Games'
 if(-not(Test-Path -LiteralPath $root)){return @()}
 foreach($file in GetFusionInstallationReceipts $store){
  try{$m=ReadOptiShadeState $file.FullName;if($m.Status -notin @('Installed','Installing')){continue};$expected=ManifestPath $store $m.Game;if((FullPath $file.FullName) -ine (FullPath $expected)){continue}
   $title=GetMsfsTitle $m.Game;if(-not $title){$match=@($script:libraryGames|Where-Object {($_.InstallFolder -and $_.InstallFolder -ieq $m.Game) -or $_.Folder -ieq $m.Game}|Select-Object -First 1);$title=if($match.Count){$match[0].DisplayName}else{Split-Path $m.Game -Leaf}}
   $state=GetFusionInstallState $store $m.Game;$list.Add([pscustomobject]@{Title=[string]$title;Game=[string]$m.Game;Manifest=[string]$file.FullName;State=[string]$state;Version=[string]$m.Version;Components=@(GetOptiShadeAddonSelection $m);Record=$m;Display=([string]$title+'  ·  '+[string]$state)})
  }catch{}
 }
 return @($list|Sort-Object Title,Game)
}
function SetManagerGame($Record){
 $script:componentSelections=@{}
 $script:gameRoot=[string]$Record.Game;$script:gameLauncher='';$path.Text=[string]$Record.Game;$form.FindName('SelectedTitle').Text=[string]$Record.Title;SyncMethodSelection;RefreshHomeState;RefreshMenuKeys
}
# GetNewClosure() runs popup callbacks in a dynamic module that cannot see
# functions or variables in this script's scope, and its $script: writes land in
# that module. Capture what the callbacks need before wiring them.
function NewManagerClosureContext([string[]]$Commands){
 $resolved=@{}
 foreach($name in $Commands){$resolved[$name]=(Get-Command $name -CommandType Function -ErrorAction Stop).ScriptBlock}
 return [pscustomobject]@{
  Commands=$resolved;Form=$form;Status=$status;Path=$path;Store=$store;Payload=$Payload
  SetScript={param([string]$Name,$Value) Set-Variable -Scope Script -Name $Name -Value $Value}
 }
}
function ShowInstalledGamePopup([ValidateSet('Repair','Restore')][string]$Action){
 $installed=@(GetManagedInstallations);$caption=if($Action -eq 'Repair'){'Repair a game installation'}else{'Restore original game files'}
 $description=if($Action -eq 'Repair'){'Choose one recorded installation. Repair verifies and replaces only OptiShade-owned files, keeps original backups and saved looks, and checks unfinished component downloads.'}else{'Choose one recorded game to remove OptiShade and restore its original files. This is independent of the manager uninstall. You can choose whether to keep that saved presets for that game.'}
 $popup=NewManagerPopup $caption $description
 if(-not $installed.Count){[void](AddPopupText $popup 'No tracked game installations were found. Scan the library or install the core for a game first.' 14 '#FFBE83');$close=AddPopupButton $popup 'Close';$close.Add_Click({$popup.Window.Close()}.GetNewClosure());ShowManagerPopup $popup;return}
 $picker=NewPopupComboBox $popup $installed 'Display';$picker.SelectedIndex=0
 $detail=AddPopupText $popup '' 13
 $keep=$null;if($Action -eq 'Restore'){$keep=New-Object Windows.Controls.CheckBox;$keep.Style=$form.FindResource([Windows.Controls.CheckBox]);$keep.Content='Keep saved presets for this game';$keep.IsChecked=$true;$keep.Margin='0,4,0,12';$keep.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#C0AEDF');[void]$popup.Body.Children.Add($keep)}
 $refresh={if($picker.SelectedItem){$item=$picker.SelectedItem;$components=if($item.Components.Count){$item.Components -join ', '}else{'Core only'};$detail.Text="Game folder: $($item.Game)`nState: $($item.State)`nInstalled build: $($item.Version)`nComponents: $components`nVerified original-file backups are checked before restore."}}.GetNewClosure();$picker.Add_SelectionChanged($refresh);&$refresh
 $run=AddPopupButton $popup $(if($Action -eq 'Repair'){'Repair selected game'}else{'Restore selected game'}) $true
 $manager=NewManagerClosureContext @('ShowOptiShadeDialog','SetManagerGame','RunAction','InvokeRepairInstall','InvokeRestoreInstall')
  $run.Add_Click({
  $item=$picker.SelectedItem;if(-not $item){return}
  if($Action -eq 'Restore'){$presetChoice=if($keep.IsChecked){'kept.'}else{'removed.'};$prompt="Restore original files for $($item.Title)? This removes this game's OptiShade files and recovery backups. Saved presets are $presetChoice";if((& $manager.Commands.ShowOptiShadeDialog ($manager.Form) ($prompt) ('Restore this game') ('YesNo') ('Warning') ('No')) -ne 'Yes'){return}}
  & $manager.SetScript 'restoreKeepPresets' $(if($Action -eq 'Restore'){[bool]$keep.IsChecked}else{$true});$popup.Window.Close();& $manager.Commands.SetManagerGame $item
   if($Action -eq 'Repair'){& $manager.Commands.RunAction {& $manager.Commands.InvokeRepairInstall} 'Repairing OptiShade'}else{& $manager.Commands.RunAction {& $manager.Commands.InvokeRestoreInstall} 'Restoring original game files'}
 }.GetNewClosure())
 ShowManagerPopup $popup
}
function ShowDownloadCachePopup{
 $folder=Join-Path $store 'Downloads';$files=@();$bytes=[long]0
 if(Test-Path -LiteralPath $folder -PathType Container){try{$files=@(Get-ChildItem -LiteralPath $folder -File -Recurse -Force -ErrorAction Stop);$bytes=[long](($files|Measure-Object Length -Sum).Sum)}catch{}}
 $popup=NewManagerPopup 'Reset manager download cache' 'Remove temporary manager downloads from the active cache. Existing cached data is moved into a local recovery folder so failed downloads can be retried safely.'
 [void](AddPopupText $popup ('Cache location: '+$folder+"`nFiles: $($files.Count)  ·  Size: $([Math]::Round($bytes/1MB,1)) MB`nInstalled game files, presets, and original-file backups are not part of this cache."))
 $cancel=AddPopupButton $popup 'Cancel';$cancel.Add_Click({$popup.Window.Close()}.GetNewClosure());$clear=AddPopupButton $popup 'Reset cache' $true;$clear.IsEnabled=[bool](Test-Path -LiteralPath $folder -PathType Container)
 $manager=NewManagerClosureContext @('RunAction','ResetOptiShadeDownloadCache')
 $clear.Add_Click({$popup.Window.Close();& $manager.Commands.RunAction {$manager.Status.Text=& $manager.Commands.ResetOptiShadeDownloadCache $manager.Store} 'Resetting manager download cache'}.GetNewClosure());ShowManagerPopup $popup
}
function ShowSettingsBackupPopup{
 $installed=@(GetManagedInstallations);$popup=NewManagerPopup 'Back up and reset settings' 'Settings are saved per game. Reset creates a verified recovery copy first; you can remove old settings backups here.'
 if(-not $installed.Count){[void](AddPopupText $popup 'No tracked game installations were found.' 14 '#FFBE83');$done=AddPopupButton $popup 'Close';$done.Add_Click({$popup.Window.Close()}.GetNewClosure());ShowManagerPopup $popup;return}
 $picker=NewPopupComboBox $popup $installed 'Display';$picker.SelectedIndex=0
 $backups=New-Object Windows.Controls.ListBox;$backups.MinHeight=84;$backups.MaxHeight=160;$backups.Margin='0,4,0,10';$backups.Background=[Windows.Media.BrushConverter]::new().ConvertFromString('#201A2B');$backups.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#F3EFFB');[void]$popup.Body.Children.Add($backups)
 $refresh={if($picker.SelectedItem){$root=Split-Path $picker.SelectedItem.Manifest -Parent;$backups.ItemsSource=@(Get-ChildItem -LiteralPath $root -Directory -Filter 'Settings-*' -ErrorAction SilentlyContinue|Where-Object {$_.Name -match '^Settings-[a-fA-F0-9-]{36}$'}|ForEach-Object {$_.FullName});$backups.DisplayMemberPath='Name'}}.GetNewClosure();$picker.Add_SelectionChanged($refresh);&$refresh
 [void](AddPopupText $popup 'Saved settings backups are kept beside each game record. Select one to remove it, or back up and reset OptiShade settings for the selected game.')
 $manager=NewManagerClosureContext @('ShowOptiShadeDialog','SetManagerGame','RunAction','ResetOptiShadeSettings')
 $remove=AddPopupButton $popup 'Remove selected backup';$remove.IsEnabled=$false;$backups.Add_SelectionChanged({$remove.IsEnabled=[bool]$backups.SelectedItem}.GetNewClosure())
 $remove.Add_Click({$target=[string]$backups.SelectedItem;if(-not $target){return};$root=Split-Path $picker.SelectedItem.Manifest -Parent;if(-not $target.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $target -Leaf) -notmatch '^Settings-[a-fA-F0-9-]{36}$'){return};if((& $manager.Commands.ShowOptiShadeDialog $manager.Form ('Permanently remove this saved settings backup? '+(Split-Path $target -Leaf)) 'Remove settings backup' 'YesNo' 'Warning' 'No') -ne 'Yes'){return};try{Get-ChildItem -LiteralPath $target -Force -Recurse|ForEach-Object {if($_.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked backup content was found. Nothing was deleted.'}};Remove-Item -LiteralPath $target -Recurse -Force;&$refresh;$manager.Status.Text='Settings backup removed.'}catch{$manager.Status.Text=$_.Exception.Message;$manager.Status.Foreground='#FFBE83'}}.GetNewClosure())
 $cancel=AddPopupButton $popup 'Close';$cancel.Add_Click({$popup.Window.Close()}.GetNewClosure());$reset=AddPopupButton $popup 'Back up and reset selected game' $true
 $reset.Add_Click({$item=$picker.SelectedItem;if(-not $item){return};if((& $manager.Commands.ShowOptiShadeDialog $manager.Form ("Back up and reset OptiShade settings for $($item.Title)? Game-specific settings and saved looks are handled independently.") 'Reset game settings' 'YesNo' 'Question' 'No') -ne 'Yes'){return};$popup.Window.Close();& $manager.Commands.SetManagerGame $item;& $manager.Commands.RunAction {$saved=& $manager.Commands.ResetOptiShadeSettings $manager.Path.Text $manager.Payload $manager.Store;$manager.Status.Text='Settings backed up and reset. Previous files: '+$saved} 'Backing up and resetting game settings'}.GetNewClosure());ShowManagerPopup $popup
}
function ShowCompatibilityPopup{
 $games=@($script:libraryGames);$popup=NewManagerPopup 'Check game compatibility' 'Choose a detected game to inspect its executable, runtime, hardware and OptiShade files. This is evidence only; it cannot confirm an in-game feature is working.'
 if(-not $games.Count){[void](AddPopupText $popup 'No detected games are available. Scan the library or add a game first.' 14 '#FFBE83');$close=AddPopupButton $popup 'Close';$close.Add_Click({$popup.Window.Close()}.GetNewClosure());ShowManagerPopup $popup;return}
 $picker=NewPopupComboBox $popup $games 'DisplayName'
 $activeFolder='';try{$activeFolder=[IO.Path]::GetFullPath($path.Text).TrimEnd('\')}catch{}
 $activeGame=@($games|Where-Object {$candidate='';try{$candidate=[IO.Path]::GetFullPath((GetFusionGameTargetFolder $_)).TrimEnd('\')}catch{};$activeFolder -and [string]::Equals($candidate,$activeFolder,[StringComparison]::OrdinalIgnoreCase)}|Select-Object -First 1)
 if($activeGame.Count){$picker.SelectedItem=$activeGame[0]}elseif($games.Count){$picker.SelectedIndex=0}
 $report=New-Object Windows.Controls.TextBox;$report.IsReadOnly=$true;$report.TextWrapping='Wrap';$report.AcceptsReturn=$true;$report.MinHeight=180;$report.MaxHeight=300;$report.VerticalScrollBarVisibility='Auto';$report.Background=[Windows.Media.BrushConverter]::new().ConvertFromString('#1A1624');$report.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#E7DDF5');$report.Padding='12';$report.BorderBrush=[Windows.Media.BrushConverter]::new().ConvertFromString('#49355F');[void]$popup.Body.Children.Add($report)
 $reportBox=$report;$gamePicker=$picker
 # GetNewClosure() isolates these delayed WPF callbacks in a dynamic module.
 # Capture the manager functions dot-sourced into script scope before wiring
 # callbacks so compatibility preview, scanning and troubleshooting resolve.
 $getGameTargetFolderCommand=(Get-Command GetFusionGameTargetFolder -CommandType Function).ScriptBlock
 $setSelectedGameCommand=(Get-Command SetSelectedFusionGame -CommandType Function).ScriptBlock
 $manifestPathCommand=(Get-Command ManifestPath -CommandType Function).ScriptBlock
 $readStateCommand=(Get-Command ReadOptiShadeState -CommandType Function).ScriptBlock
 $findGameExecutableCommand=(Get-Command FindFusionExecutable -CommandType Function).ScriptBlock
 $chooseGameExecutableCommand=(Get-Command ChooseGameExe -CommandType Function).ScriptBlock
 $checkCompatibilityCommand=(Get-Command CheckGameCompatibility -CommandType Function).ScriptBlock
 $formatCompatibilityCommand=(Get-Command FormatFusionCompatibility -CommandType Function).ScriptBlock
 $writeInstallerLogCommand=(Get-Command WriteInstallerLog -CommandType Function).ScriptBlock
 $openDiagnosticToolCommand=(Get-Command OpenDiagnosticTool -CommandType Function).ScriptBlock
 $manager=NewManagerClosureContext @()
 $setReport={param([string]$Text) $reportBox.SetCurrentValue([Windows.Controls.TextBox]::TextProperty,$Text)}.GetNewClosure()
 $preview={if($gamePicker.SelectedItem){$game=$gamePicker.SelectedItem;$folder=& $getGameTargetFolderCommand $game;&$setReport "Game: $($game.DisplayName)`nStore: $($game.StoreDisplay)`nFolder: $folder`nChoose Check selected game to inspect the executable and runtime."}}.GetNewClosure()
 $picker.Add_SelectionChanged($preview);&$preview
 $check=AddPopupButton $popup 'Check selected game' $true
 $check.Add_Click({
  $game=$gamePicker.SelectedItem;if(-not $game){return}
  try{
   $folder=& $getGameTargetFolderCommand $game;[void](& $setSelectedGameCommand $game)
   $mp=& $manifestPathCommand $manager.Store $folder;$exe=''
   if(Test-Path -LiteralPath $mp){$record=& $readStateCommand $mp;$exe=[string]$record.LaunchExe}
   if(-not $exe -or -not(Test-Path -LiteralPath $exe -PathType Leaf)){$found=@(& $findGameExecutableCommand $folder $game.Launcher $game.Name);if($found.Count -eq 1){$exe=$found[0].Path}else{$exe=& $chooseGameExecutableCommand}}
   if(-not $exe){&$setReport 'No executable was selected. No compatibility scan was run.';return}
   $plan=& $checkCompatibilityCommand $exe
   &$setReport ((& $formatCompatibilityCommand $plan)+"`n`nGame: $($game.DisplayName)`nStore: $($game.StoreDisplay)`nExecutable: $exe`nExecutable evidence: $($plan.ExecutableEvidence)`nScan complete: $($plan.ScanComplete)`nRuntime state: Not tested in game. A found DLL does not prove it is loaded or producing output.")
   $manager.Status.Text='Compatibility evidence collected. Open the troubleshooting tool for a diagnostic report.'
  }catch{$message=$_.Exception.Message;&$setReport ('Compatibility check could not complete: '+$message);$manager.Status.Text=$message;$manager.Status.Foreground='#FFBE83';& $writeInstallerLogCommand ('Compatibility check failed: '+$message+' | '+$_.ScriptStackTrace)}
 }.GetNewClosure())
 $tool=AddPopupButton $popup 'Open troubleshooting tool';$tool.Add_Click({$popup.Window.Close();try{& $openDiagnosticToolCommand}catch{$manager.Status.Text=$_.Exception.Message;$manager.Status.Foreground='#FFBE83'}}.GetNewClosure());$close=AddPopupButton $popup 'Close';$close.Add_Click({$popup.Window.Close()}.GetNewClosure());ShowManagerPopup $popup
}
$form.FindName('OpenTroubleshooter').Add_Click({try{OpenDiagnosticTool}catch{$status.Text=$_.Exception.Message;$status.Foreground='#FFBE83'}})
$form.FindName('RecoveryRepair').Add_Click({ShowInstalledGamePopup 'Repair'})
$form.FindName('RecoveryRestore').Add_Click({ShowInstalledGamePopup 'Restore'})
$form.FindName('ResetDefaults').Add_Click({ShowSettingsBackupPopup})
$form.FindName('ImportZip').Add_Click({RunAction {
 AssertClosed $path.Text
 $dialog=New-Object Windows.Forms.OpenFileDialog;$dialog.Filter='FX and INI packages (*.zip)|*.zip'
 try{if($dialog.ShowDialog() -eq 'OK'){$count=ImportEffectsZip $dialog.FileName $path.Text;$status.Text="Imported $count files into OptiShadeData. In game, choose your imported INI under Image effects > Saved look. Required FX must be installed and compile. Your current look is unchanged. ZIPs containing DLLs do not install those DLLs."}}finally{$dialog.Dispose()}
}})
$script:updateCheckPowerShell=$null;$script:updateCheckResult=$null
$script:updateCheckTimer=[Windows.Threading.DispatcherTimer]::new();$script:updateCheckTimer.Interval=[TimeSpan]::FromMilliseconds(120)
RegisterOptiShadeManagerTimer $script:updateCheckTimer {
 if(-not $script:updateCheckResult -or -not $script:updateCheckResult.IsCompleted){return}
 $script:updateCheckTimer.Stop()
 try{
  $result=$null
  try{$result=@($script:updateCheckPowerShell.EndInvoke($script:updateCheckResult))|Select-Object -Last 1}catch{if($script:updateCheckQuiet){WriteInstallerLog ('Scheduled launcher check failed: '+$_.Exception.GetBaseException().Message);return};throw}
  if($script:updateCheckQuiet -and -not ($result -and -not $result.ChannelUnavailable)){if($result -and $result.ChannelUnavailable){WriteInstallerLog ('Scheduled launcher check: '+[string]$result.Message)};return}
  if($result -and $result.ChannelUnavailable){$script:availableUpdate=$null;$form.FindName('UpdateAvailable').Visibility='Collapsed';$status.Text=[string]$result.Message;$status.Foreground='#C0AEDF';SetHeaderVersionState 'Unavailable'}
  elseif($result){$script:availableUpdate=$result;ShowOptiShadeTrayUpdateNotice $null;$form.FindName('UpdateAvailable').Content=GetOptiShadeUpdateLabel $result;$form.FindName('UpdateAvailable').Visibility='Visible';$status.Text=if($result.Rollback){'Stable was selected. Use Return to stable to leave beta; this is a channel change, not a newer beta update.'}else{'An update is available. Use the update button to install it.'}}
  else{$script:availableUpdate=$null;$form.FindName('UpdateAvailable').Visibility='Collapsed';$status.Text=if((GetOptiShadeUpdateChannel) -eq 'beta'){'No newer beta release is available.'}else{'You are up to date on the stable channel.'}}
  if($result -and $result.ChannelUnavailable){SetHeaderVersionState 'Unavailable'}elseif($result -and -not $result.Rollback -and $result.Channel -eq (GetOptiShadeUpdateChannel)){SetHeaderVersionState 'Available'}else{SetHeaderVersionState 'Current'}
 }catch{$status.Text=$_.Exception.Message;$status.Foreground='#FFBE83';SetHeaderVersionState 'Error'}
 finally{RemoveOptiShadeManagerWorker $script:updateCheckPowerShell;$script:updateCheckPowerShell=$null;$script:updateCheckResult=$null;$script:updateCheckQuiet=$false;$form.FindName('CheckUpdates').IsEnabled=$true;$form.FindName('HeaderVersionAction').IsEnabled=$true}
}
$form.FindName('CheckUpdates').Add_Click({
 # A scheduled check sets quietUpdateCheck: no status text or disabled buttons unless an update is found.
 $quiet=[bool]$script:quietUpdateCheck;$script:quietUpdateCheck=$false
 if($quiet){StartGlassCockpitReleaseCheck}else{StartGlassCockpitReleaseCheck -Force}
 if($script:updateCheckResult){return}
 $script:updateCheckQuiet=$quiet
 if(-not $quiet){SetHeaderVersionState 'Checking';$status.Text=if($script:modularDistribution){'Checking the signed launcher channel...'}else{'Checking GitHub releases...'};$form.FindName('CheckUpdates').IsEnabled=$false;$form.FindName('HeaderVersionAction').IsEnabled=$false}
 $script:updateCheckPowerShell=(NewOptiShadeManagerWorker)
 if($script:modularDistribution){[void]$script:updateCheckPowerShell.AddScript({param($module,$current,$manager);. $module;GetOptiShadeModularUpdate -Current $current -ManagerPath $manager}).AddArgument((Join-Path $PSScriptRoot 'updates.ps1')).AddArgument((GetOptiShadeManagerCompatibilityVersion)).AddArgument($Installer)}
 else{[void]$script:updateCheckPowerShell.AddScript({param($module);. $module;GetOptiShadeUpdate -ReportErrors}).AddArgument((Join-Path $PSScriptRoot 'updates.ps1'))}
 $script:updateCheckResult=$script:updateCheckPowerShell.BeginInvoke();$script:updateCheckTimer.Start()
})
$form.FindName('HeaderVersionAction').Add_Click({$form.FindName('CheckUpdates').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))})

function CancelSnapshotCapture {$script:captureState.Snapshot=$false;$form.FindName('ChangeSnapshotKey').Content='Change'}
function CancelFeatureCapture { $feature=[string]$script:captureState.Feature;if($feature){$buttonId=$script:featureButtonIds[$feature];if($buttonId){$form.FindName($buttonId).Content='Change'}};$script:captureState.Feature='' }
function GetSnapshotLibraryLocation{
 $value=[Environment]::GetFolderPath([Environment+SpecialFolder]::MyPictures)
 $settings=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'OptiShade/Snapshot-settings.ini'
 try{if(Test-Path -LiteralPath $settings){foreach($line in [IO.File]::ReadAllLines($settings,[Text.Encoding]::Unicode)){if($line -match '^\s*Directory\s*=\s*(.+?)\s*$'){$value=$Matches[1].Trim().Trim('"');break}}}
  elseif($path.Text){$legacy=OwnedPath $path.Text 'OptiShadeData/Snapshot-settings.ini';if(Test-Path -LiteralPath $legacy){foreach($line in [IO.File]::ReadAllLines($legacy,[Text.Encoding]::Unicode)){if($line -match '^\s*Directory\s*=\s*(.+?)\s*$'){$value=$Matches[1].Trim().Trim('"');break}}}}
 }catch{}
 return $value
}
function SaveSnapshotLibraryLocation([string]$Parent){
 $parent=[IO.Path]::GetFullPath($Parent.Trim())
 if($parent.Contains("`r") -or $parent.Contains("`n") -or -not(Test-Path -LiteralPath $parent -PathType Container)){throw 'Choose an existing snapshot folder.'}
 for($probe=$parent;$probe;){$item=Get-Item -LiteralPath $probe -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Snapshot folders cannot use linked or junction paths.'};if([IO.Path]::GetPathRoot($probe) -eq $probe){break};$probe=Split-Path $probe -Parent}
 $file=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'OptiShade/Snapshot-settings.ini'
 $jpeg='0';$quality='90'
 if(Test-Path -LiteralPath $file){foreach($line in [IO.File]::ReadAllLines($file,[Text.Encoding]::Unicode)){if($line -match '^\s*JPEG\s*=\s*([01])\s*$'){$jpeg=$Matches[1]};if($line -match '^\s*JPEGQuality\s*=\s*(\d+)\s*$' -and [int]$Matches[1] -ge 1 -and [int]$Matches[1] -le 100){$quality=$Matches[1]}}}
 [void][IO.Directory]::CreateDirectory((Split-Path $file -Parent))
 $content="[SnapShot]`r`nDirectory=$parent`r`nJPEG=$jpeg`r`nJPEGQuality=$quality`r`n"
 [IO.File]::WriteAllText($file,$content,[Text.UnicodeEncoding]::new($false,$true))
 $form.FindName('SnapshotParent').Text=$parent
}
function RefreshMenuKeys {
 CancelSnapshotCapture
 CancelFeatureCapture
 $script:captureState.HotSwap=$false;$form.FindName('ChangeHotSwapKey').Content='Change'
 $script:captureState.MenuKey=$false;$form.FindName('ChangeMenuKey').Content='Change'
 $form.FindName('KeybindsGame').Text=if([string]::IsNullOrWhiteSpace($path.Text)){'Select your installation on Setup.'}else{'Selected game: '+$path.Text}
 $keys=@{ShortcutKey=45;BackupShortcutKey=79;PresetHotSwapKey=0;SnapshotKey=0;DlssNrToggleKey=-1;MfgToggleKey=-1;MfgMultiplierUpKey=-1;MfgMultiplierDownKey=-1;SupportsOptiScalerShortcuts=$true;MenuRuntime='OptiScaler'};$script:menuKeyCandidate=0
 try{if(-not [string]::IsNullOrWhiteSpace($path.Text)){$keys=GetMenuSettings $path.Text}}
 catch{$form.FindName('PrimaryMenuKey').Text='Unavailable';$form.FindName('KeyCaptureHint').Text='Unable to read shortcuts: '+$_.Exception.Message;return}
 $script:snapshotCandidate=[int]$keys.SnapshotKey
 $supportsOptiScalerShortcuts=[bool]$keys.SupportsOptiScalerShortcuts
 $form.FindName('SnapshotKey').Text=if(-not $supportsOptiScalerShortcuts){'Not available'}elseif($script:snapshotCandidate -gt 0){([Windows.Forms.Keys]$script:snapshotCandidate).ToString()}else{'Not set'}
 $script:hotSwapCandidate=[int]$keys.PresetHotSwapKey
 $form.FindName('HotSwapKey').Text=if(-not $supportsOptiScalerShortcuts){'Not available'}elseif($script:hotSwapCandidate -gt 0){([Windows.Forms.Keys]$script:hotSwapCandidate).ToString()}else{'Not set'}
 $script:featureKeyCandidate=@{DlssNrToggleKey=[int]$keys.DlssNrToggleKey;MfgToggleKey=[int]$keys.MfgToggleKey;MfgMultiplierUpKey=[int]$keys.MfgMultiplierUpKey;MfgMultiplierDownKey=[int]$keys.MfgMultiplierDownKey}
 foreach($name in $script:featureKeyCandidate.Keys){$control=$name -replace 'DlssNrToggleKey','NrToggleKey';$value=[int]$script:featureKeyCandidate[$name];$form.FindName($control).Text=if(-not $supportsOptiScalerShortcuts){'Not available'}elseif($value -gt 0){([Windows.Forms.Keys]$value).ToString()}else{'Not set'}}
 foreach($name in @('ChangeSnapshotKey','ClearSnapshotKey','ChangeHotSwapKey','ClearHotSwapKey','ChangeNrToggleKey','ClearNrToggleKey','ChangeMfgToggleKey','ClearMfgToggleKey','ChangeMfgMultiplierUpKey','ClearMfgMultiplierUpKey','ChangeMfgMultiplierDownKey','ClearMfgMultiplierDownKey')){$form.FindName($name).IsEnabled=$supportsOptiScalerShortcuts}
 $script:menuKeyCandidate=[int]$keys.ShortcutKey
 $form.FindName('PrimaryMenuKey').Text=([Windows.Forms.Keys]$script:menuKeyCandidate).ToString()
 $form.FindName('KeyCaptureHint').Text=if($supportsOptiScalerShortcuts){'Click Change, press one key, then Save shortcuts. Escape cancels. Turn Num Lock on for number-pad digits.'}else{'This 32-bit game uses ReShade. Its menu key is synchronized here; OptiScaler recovery, snapshots and preset hotswap are unavailable.'}
 $form.FindName('BackupMenuKeyLabel').Text=if($supportsOptiScalerShortcuts){'Ctrl + Shift + '+([Windows.Forms.Keys][int]$keys.BackupShortcutKey).ToString()}else{'Not available'}
 $form.FindName('BackupMenuHint').Text=if($supportsOptiScalerShortcuts){'Recovery shortcut: Ctrl+Shift+'+([Windows.Forms.Keys][int]$keys.BackupShortcutKey).ToString()+' (no Insert or numpad needed). Saving the primary key keeps this shortcut.'}else{'The 32-bit ReShade route has no OptiScaler recovery shortcut.'}
 $form.FindName('BackupMenuDescription').Text=if($supportsOptiScalerShortcuts){'Opens the menu if your main shortcut fails.'}else{'Not available in the 32-bit ReShade route.'}
 $form.FindName('SnapshotDescription').Text=if($supportsOptiScalerShortcuts){'Takes a screenshot with OptiShade applied.'}else{'Requires the 64-bit OptiScaler menu.'}
 $form.FindName('HotSwapDescription').Text=if($supportsOptiScalerShortcuts){'Cycles between your two saved looks.'}else{'Requires the 64-bit OptiScaler menu.'}
  $form.FindName('SnapshotParent').Text=GetSnapshotLibraryLocation
}
function BeginMenuKeyCapture {
 CancelSnapshotCapture;CancelFeatureCapture
 $script:captureState.HotSwap=$false;$form.FindName('ChangeHotSwapKey').Content='Change'
 $script:captureState.MenuKey=$true;$form.FindName('ChangeMenuKey').Content='Press a key...'
 $form.FindName('KeyCaptureHint').Text='Press one key for the menu. Escape cancels; modifier combinations are not supported for the primary key.'
 [void]$form.FindName('ChangeMenuKey').Focus()
}
function CaptureMenuKey($event) {
 if(-not $script:captureState.MenuKey){return};$event.Handled=$true
 $key=$event.Key;if($key -eq [Windows.Input.Key]::System){$key=$event.SystemKey}
 if($key -eq [Windows.Input.Key]::Escape){$script:captureState.MenuKey=$false;$form.FindName('ChangeMenuKey').Content='Change';$form.FindName('KeyCaptureHint').Text='Cancelled. The selected key is unchanged.';return}
 $code=[Windows.Input.KeyInterop]::VirtualKeyFromKey($key)
 if([Windows.Input.Keyboard]::Modifiers -ne [Windows.Input.ModifierKeys]::None -or $code -notin (@(33..40)+@(45,46)+@(48..57)+@(65..90)+@(96..111)+@(112..123))){$form.FindName('KeyCaptureHint').Text='Choose a letter, number, function or navigation key without modifiers. Escape cancels.';return}
 $script:menuKeyCandidate=$code;$script:captureState.MenuKey=$false
 $form.FindName('PrimaryMenuKey').Text=([Windows.Forms.Keys]$code).ToString();$form.FindName('ChangeMenuKey').Content='Change'
 $form.FindName('KeyCaptureHint').Text='Not saved yet. Click Save shortcuts to apply this key after restarting the game.'
}
$script:featureButtonIds=@{DlssNrToggleKey='ChangeNrToggleKey';MfgToggleKey='ChangeMfgToggleKey';MfgMultiplierUpKey='ChangeMfgMultiplierUpKey';MfgMultiplierDownKey='ChangeMfgMultiplierDownKey'}
$script:featureButtons=@{};foreach($name in $script:featureButtonIds.Keys){$script:featureButtons[$name]=$form.FindName($script:featureButtonIds[$name])}
$script:focusCaptureGuard=[FusionFocusCaptureGuard]::new($form,$script:captureState,$form.FindName('ChangeMenuKey'),$form.FindName('ChangeHotSwapKey'),$form.FindName('ChangeSnapshotKey'),$form.FindName('KeyCaptureHint'),$script:featureButtons)
$form.FindName('ChangeMenuKey').Add_Click({BeginMenuKeyCapture})
$form.Add_PreviewKeyDown({CaptureMenuKey $_})
$form.FindName('ChangeHotSwapKey').Add_Click({CancelSnapshotCapture;CancelFeatureCapture;$script:captureState.MenuKey=$false;$form.FindName('ChangeMenuKey').Content='Change';$script:captureState.HotSwap=$true;$form.FindName('ChangeHotSwapKey').Content='Press a key...';$form.FindName('KeyCaptureHint').Text='Press a hotswap key. Escape cancels; Backspace clears. Then Save shortcuts. Turn Num Lock on for number-pad digits.'})
$form.FindName('ClearHotSwapKey').Add_Click({$script:captureState.HotSwap=$false;$script:hotSwapCandidate=0;$form.FindName('HotSwapKey').Text='Not set';$form.FindName('ChangeHotSwapKey').Content='Change';$form.FindName('KeyCaptureHint').Text='Click Save shortcuts to keep this change.'})
$form.FindName('ChangeNrToggleKey').Add_Click({BeginFeatureCapture 'DlssNrToggleKey'})
$form.FindName('ClearNrToggleKey').Add_Click({$script:featureKeyCandidate.DlssNrToggleKey=-1;$form.FindName('NrToggleKey').Text='Not set';$form.FindName('KeyCaptureHint').Text='Click Save shortcuts to keep this change.'})
$form.FindName('ChangeMfgToggleKey').Add_Click({BeginFeatureCapture 'MfgToggleKey'})
$form.FindName('ClearMfgToggleKey').Add_Click({$script:featureKeyCandidate.MfgToggleKey=-1;$form.FindName('MfgToggleKey').Text='Not set';$form.FindName('KeyCaptureHint').Text='Click Save shortcuts to keep this change.'})
$form.FindName('ChangeMfgMultiplierUpKey').Add_Click({BeginFeatureCapture 'MfgMultiplierUpKey'})
$form.FindName('ClearMfgMultiplierUpKey').Add_Click({$script:featureKeyCandidate.MfgMultiplierUpKey=-1;$form.FindName('MfgMultiplierUpKey').Text='Not set';$form.FindName('KeyCaptureHint').Text='Click Save shortcuts to keep this change.'})
$form.FindName('ChangeMfgMultiplierDownKey').Add_Click({BeginFeatureCapture 'MfgMultiplierDownKey'})
$form.FindName('ClearMfgMultiplierDownKey').Add_Click({$script:featureKeyCandidate.MfgMultiplierDownKey=-1;$form.FindName('MfgMultiplierDownKey').Text='Not set';$form.FindName('KeyCaptureHint').Text='Click Save shortcuts to keep this change.'})
$form.FindName('ChangeSnapshotKey').Add_Click({CancelFeatureCapture;$script:captureState.MenuKey=$false;$script:captureState.HotSwap=$false;$form.FindName('ChangeMenuKey').Content='Change';$form.FindName('ChangeHotSwapKey').Content='Change';$script:captureState.Snapshot=$true;$form.FindName('ChangeSnapshotKey').Content='Press a key...';$form.FindName('KeyCaptureHint').Text='Press a SnapShot key. Escape cancels; Backspace clears. Then Save shortcuts. Turn Num Lock on for number-pad digits.'})
$form.FindName('ClearSnapshotKey').Add_Click({CancelSnapshotCapture;$script:snapshotCandidate=0;$form.FindName('SnapshotKey').Text='Not set'})
function BeginFeatureCapture([string]$Name){
 CancelSnapshotCapture;CancelFeatureCapture;$script:captureState.HotSwap=$false;$script:captureState.MenuKey=$false;$form.FindName('ChangeHotSwapKey').Content='Change';$form.FindName('ChangeMenuKey').Content='Change';$script:captureState.Feature=$Name
 $button=$form.FindName($script:featureButtonIds[$Name]);$button.Content='Press a key...';$form.FindName('KeyCaptureHint').Text='Press a key for this in-game action. Escape cancels; Backspace clears. Then Save shortcuts.'
 [void]$button.Focus()
}
function CaptureActionKey($event,[bool]$KeyUp=$false) {
 if(-not $script:captureState.Snapshot -and -not $script:captureState.HotSwap -and -not [string]$script:captureState.Feature){return}
 $key=$event.Key;if($key -eq [Windows.Input.Key]::System){$key=$event.SystemKey}
 $code=[Windows.Input.KeyInterop]::VirtualKeyFromKey($key)
 # Windows may send only key-up for Print Screen. A down that completed capture
 # already clears the flag, so its later key-up cannot bind or trigger twice.
 if($KeyUp -and $code -ne 44){return}
 $event.Handled=$true
 $feature=[string]$script:captureState.Feature;$isFeature=[bool]$feature;$isSnapshot=[bool]$script:captureState.Snapshot
 $button=if($isFeature){$script:featureButtonIds[$feature]}elseif($isSnapshot){'ChangeSnapshotKey'}else{'ChangeHotSwapKey'}
 $label=if($isFeature){$feature -replace 'DlssNrToggleKey','NrToggleKey'}elseif($isSnapshot){'SnapshotKey'}else{'HotSwapKey'}
 if($key -eq [Windows.Input.Key]::Escape){if($isFeature){CancelFeatureCapture}else{$script:captureState.Snapshot=$false;$script:captureState.HotSwap=$false;$form.FindName($button).Content='Change'};$form.FindName('KeyCaptureHint').Text='Cancelled. The selected key is unchanged.';return}
 if($code -eq 8){$code=if($isFeature){-1}else{0}}
 elseif([Windows.Input.Keyboard]::Modifiers -ne [Windows.Input.ModifierKeys]::None -or $code -notin (@(33..40)+@(44,45,46)+@(48..57)+@(65..90)+@(96..111)+@(112..123))){$form.FindName('KeyCaptureHint').Text='Unsupported key. Choose a letter, number, function, navigation or Print Screen key without modifiers. Turn Num Lock on for number-pad digits.';return}
 $other=if($isSnapshot){$script:hotSwapCandidate}else{$script:snapshotCandidate}
 $keys=GetMenuSettings $path.Text
 try{$conflict=if($isFeature){GetActionKeyConflict $path.Text $code $script:menuKeyCandidate $script:snapshotCandidate $feature}else{GetActionKeyConflict $path.Text $code $script:menuKeyCandidate $other}}catch{$form.FindName('KeyCaptureHint').Text='Unable to check shortcuts: '+$_.Exception.Message;return}
 if($isFeature -and $code -gt 0){if($code -eq [int]$keys.BackupShortcutKey){$conflict='the recovery shortcut'}elseif($code -eq [int]$script:hotSwapCandidate){$conflict='Preset hotswap'}elseif($code -eq [int]$script:snapshotCandidate){$conflict='SnapShot'};if(-not $conflict){foreach($otherName in $script:featureKeyCandidate.Keys){if($otherName -ne $feature -and [int]$script:featureKeyCandidate[$otherName] -eq $code){$conflict=$otherName;break}}}}
 if($conflict){$form.FindName('KeyCaptureHint').Text='That key is already assigned to '+$conflict+'. Choose another key. Turn Num Lock on for number-pad digits.';return}
 if($isFeature){$script:featureKeyCandidate[$feature]=$code}else{if($isSnapshot){$script:snapshotCandidate=$code}else{$script:hotSwapCandidate=$code}}
 $script:captureState.Snapshot=$false;$script:captureState.HotSwap=$false;$script:captureState.Feature='';$form.FindName($button).Content='Change'
 $form.FindName($label).Text=if($code -eq 44){'Print Screen'}elseif($code -gt 0){([Windows.Forms.Keys]$code).ToString()}else{'Not set'}
 $form.FindName('KeyCaptureHint').Text='Click Save shortcuts to keep this change. Turn Num Lock on for number-pad digits.'
}
$form.Add_PreviewKeyDown({CaptureActionKey $_})
$form.Add_PreviewKeyUp({CaptureActionKey $_ $true})
$form.FindName('ChangeSnapshotParent').Add_Click({$dialog=New-Object Windows.Forms.FolderBrowserDialog;$dialog.Description='Choose the shared parent folder for OptiShade Snapshots';$dialog.ShowNewFolderButton=$true;if(Test-Path -LiteralPath $form.FindName('SnapshotParent').Text -PathType Container){$dialog.SelectedPath=$form.FindName('SnapshotParent').Text};try{if($dialog.ShowDialog() -eq 'OK'){SaveSnapshotLibraryLocation $dialog.SelectedPath;$null=EnsureOptiShadeSnapshotLibrary $dialog.SelectedPath;$status.Text='Snapshot location changed. The shared folder is ready; game folders are created when a snapshot is taken.';$status.Foreground='#BDA0F4'}}catch{$status.Text='Could not change the snapshot location: '+$_.Exception.Message;$status.Foreground='#FFBE83'}finally{$dialog.Dispose()}})
$form.FindName('BrowseSnapshots').Add_Click({try{$library=EnsureOptiShadeSnapshotLibrary (GetSnapshotLibraryLocation);$folder=$library.Root;if($path.Text){$gameFolder=Join-Path $folder (Split-Path ([IO.Path]::GetFullPath($path.Text)) -Leaf);if(Test-Path -LiteralPath $gameFolder -PathType Container){$folder=$gameFolder}};Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList ('"'+$folder+'"')}catch{$status.Text='Could not open the snapshot folder: '+$_.Exception.Message;$status.Foreground='#FFBE83'}})
$form.FindName('LoadMenuKeys').Add_Click({RunAction {RefreshMenuKeys;$status.Text='Showing shortcuts for the selected game folder.'}})
$form.FindName('SaveMenuKeys').Add_Click({RunAction {
 if($script:captureState.MenuKey -or $script:captureState.Feature -or -not $script:menuKeyCandidate){throw 'Finish choosing the active shortcut and press a primary menu key first.'}
 $keys=GetMenuSettings $path.Text
 if($script:captureState.Snapshot){throw 'Finish choosing the SnapShot key first.'}
 if($script:captureState.HotSwap){throw 'Finish choosing the hotswap key first.'}
 SetMenuSettings $path.Text $script:menuKeyCandidate ([int]$keys.BackupShortcutKey) $script:hotSwapCandidate $script:snapshotCandidate $script:featureKeyCandidate
 RefreshMenuKeys;$status.Text=if($keys.SupportsOptiScalerShortcuts){'Shortcuts saved. Restart the game to use them. Your recovery shortcut is unchanged.'}else{'Menu shortcut saved to this 32-bit ReShade installation. Restart the game to use it.'}
}})
$form.FindName('DefaultMenuKeys').Add_Click({RunAction {$keys=GetMenuSettings $path.Text;SetMenuSettings $path.Text 45 79 0 0;RefreshMenuKeys;$status.Text=if($keys.SupportsOptiScalerShortcuts){'Default shortcuts saved: Insert and Ctrl+Shift+O. Restart the selected game.'}else{'Default menu shortcut saved: Insert. Restart the selected game.'}}})
RefreshMenuKeys
$script:preferencesReady=$true
# The manager always opens on Home.
ShowPage 'Home'
# Raise the shared splash/installer window once, without keeping it above other apps.
$form.Add_Loaded({if(-not $script:trayEnabled){$form.Topmost=$true;[void]$form.Activate()}})
$form.Add_ContentRendered({[void]$form.Activate();$script:startupDisplayOperation=$form.Dispatcher.BeginInvoke([Action]{$form.Topmost=$false},[Windows.Threading.DispatcherPriority]::ApplicationIdle);$script:introStart=Get-Date;$script:startupProgress.Stage='Loading your saved setup...';$form.FindName('IntroStatus').Text=$script:startupProgress.Stage;$status.Text=$form.FindName('IntroStatus').Text;RestoreStartupCache;$form.FindName('Intro').Visibility='Visible';$script:startupTimer.Start();if($script:trayEnabled -and -not $UninstallMode){$form.Hide()}})
$script:trayEnabled=[bool]$StartInTray -and -not $UninstallMode;$script:trayExitRequested=$false;$script:trayIcon=$null;$script:trayLastUpdateNotice=''
# The tray icon exists from start-up when OptiShade starts with Windows, and is
# created on demand when the window is closed to the tray.
function EnsureOptiShadeTray{
 if($script:trayIcon){return}
 $script:trayEnabled=$true
 $script:trayIcon=New-Object Windows.Forms.NotifyIcon
 $script:trayIcon.Icon=[Drawing.SystemIcons]::Application
 $trayIconPath=Join-Path $PSScriptRoot 'OptiShade.ico'
 if(Test-Path -LiteralPath $trayIconPath -PathType Leaf){try{$script:trayIcon.Icon=New-Object Drawing.Icon($trayIconPath,[Windows.Forms.SystemInformation]::SmallIconSize)}catch{}}
 $script:trayIcon.Text='OptiShade '+$presentation.Version
 $trayMenu=New-Object Windows.Forms.ContextMenuStrip;$trayMenu.Renderer=[Windows.Forms.ToolStripProfessionalRenderer]::new([OptiShadeTrayColors]::new());$trayMenu.BackColor=[Drawing.Color]::FromArgb(23,20,32);$trayMenu.ForeColor=[Drawing.Color]::FromArgb(243,239,251);$trayMenu.ShowImageMargin=$false;$trayMenu.Font=[Drawing.Font]::new('Segoe UI',9.5);$trayOpen=$trayMenu.Items.Add('Open OptiShade');$trayUpdates=$trayMenu.Items.Add('Open Update Manager');$trayExit=$trayMenu.Items.Add('Exit')
 $trayOpen.Add_Click({$form.Dispatcher.BeginInvoke([Action]{$form.Show();$form.WindowState='Normal';$form.Activate()})})
 $trayUpdates.Add_Click({$form.Dispatcher.BeginInvoke([Action]{$form.Show();$form.WindowState='Normal';ShowPage 'Updates';$form.Activate()})})
 $trayExit.Add_Click({$script:trayExitRequested=$true;$form.Dispatcher.BeginInvoke([Action]{$form.Close()})})
 $script:trayIcon.ContextMenuStrip=$trayMenu;$script:trayIcon.Visible=$true
 $script:trayIcon.Add_DoubleClick({$form.Dispatcher.BeginInvoke([Action]{$form.Show();$form.WindowState='Normal';$form.Activate()})})
 $script:trayIcon.Add_BalloonTipClicked({$form.Dispatcher.BeginInvoke([Action]{$form.Show();$form.WindowState='Normal';ShowPage 'Updates';$form.Activate()})})
}
if($script:trayEnabled){EnsureOptiShadeTray}
# Closing the window: keep running in the tray or close, as the user chose (asked once
# unless remembered). Tray Exit, uninstall and an operation in progress are not asked.
$form.Add_Closing({param($sender,$eventArgs)
 if($eventArgs.Cancel -or $script:trayExitRequested -or $UninstallMode -or $script:uninstallDone){return}
 $action=[string]$script:managerPreferences.CloseAction
 if($action -notin @('Tray','Exit')){
  $answer=ShowOptiShadeCloseChoice $form
  if($answer.Choice -eq 'Cancel'){$eventArgs.Cancel=$true;return}
  $action=$answer.Choice
  if($answer.Remember){$script:managerPreferences.CloseAction=$action;SaveManagerPreferences;SyncCloseWindowActionSetting}
 }
 if($action -eq 'Tray'){
  EnsureOptiShadeTray
  $eventArgs.Cancel=$true;$form.Hide()
  if(-not $script:trayHiddenNoticeShown -and $script:trayIcon){$script:trayHiddenNoticeShown=$true;$script:trayIcon.BalloonTipTitle='OptiShade is still running';$script:trayIcon.BalloonTipText='Open it again from this tray icon. Right-click it to exit.';$script:trayIcon.BalloonTipIcon=[Windows.Forms.ToolTipIcon]::Info;$script:trayIcon.ShowBalloonTip(5000)}
 }
})
# Online update checks without a click: 20 s after startup, then every 10 minutes,
# so a tray-only session can notify about new component and launcher releases.
# Each check only reads the small signed channel files from the public GitHub
# repository (at below-normal priority). Installed game files are re-verified only
# when a channel version actually changes, never on every check.
$script:onlineCheckDueUtc=[DateTime]::UtcNow.AddSeconds(20);$script:onlineChannelSignature=$null
$script:onlineCheckTimer=[Windows.Threading.DispatcherTimer]::new();$script:onlineCheckTimer.Interval=[TimeSpan]::FromSeconds(30)
RegisterOptiShadeManagerTimer $script:onlineCheckTimer {
 if($script:busy -or [DateTime]::UtcNow -lt $script:onlineCheckDueUtc -or -not $script:managerStatusState){return}
 $script:onlineCheckDueUtc=[DateTime]::UtcNow.AddMinutes(10)
 try{
  if($script:modularDistribution){
   RefreshModularComponentChannels
   $signature=(@($script:onlineComponentVersions.Keys|Sort-Object|ForEach-Object {$_+'='+[string]$script:onlineComponentVersions[$_].Version+'@'+[string]$script:onlineComponentVersions[$_].SHA256}) -join ';')
   if($signature -cne $script:onlineChannelSignature){$script:onlineChannelSignature=$signature;RequestManagerStatusScan -Force}
  }
  if(-not $script:updateCheckResult){$script:quietUpdateCheck=$true;$form.FindName('CheckUpdates').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
 }catch{WriteInstallerLog ('Scheduled update check failed: '+$_.Exception.GetBaseException().Message)}
}
$script:onlineCheckTimer.Start()
$form.Add_Closed({StopOptiShadeManagerLifetime;if($script:trayIcon){$script:trayIcon.Visible=$false;$script:trayIcon.Dispose();$script:trayIcon=$null}})

$form.FindName('SetupComponents').Add_Click({ShowPage 'Components'})
$script:componentSelections=@{}
function GetOptiMfgCardComponentId{
 $cached=GetCachedManagerGameStatus $path.Text;$current=if($cached -and $cached.Manifest){@(GetOptiShadeAddonSelection $cached.Manifest)}else{@()}
 if('Mfg' -in $current){return 'Mfg'}
 if('OptiMfg' -in $current){return 'OptiMfg'}
 return 'OptiMfg'
}
# AtmosphereMod is not in the receipt; its own install record says whether it is installed.
function GetManagerComponentSelection($Manifest){
 $ids=@(GetOptiShadeAddonSelection $Manifest)
 if($Manifest -and $Manifest.Game){try{if((GetAtmosphereModState ([string]$Manifest.Game)).Installed){$ids+='Atmosphere'}}catch{}}
 return $ids
}
function GetSelectedComponentIds{
 $ids=@(@('Effects','Neural','Cockpit','Providers','Atmosphere')|Where-Object {$form.FindName('Addon'+$_+'Selected').IsChecked -eq $true})
 if($form.FindName('AddonMfgSelected').IsChecked -eq $true){$ids+=,(GetOptiMfgCardComponentId)}
 return $ids
}
function ClearPendingFxPreset{
 $script:pendingFxPresetPath='';$script:pendingFxPresetGame=''
 $form.FindName('FxIniName').Visibility='Collapsed'
}
function GetPendingFxPresetForSelectedGame{
 if(-not $script:pendingFxPresetPath){return ''}
 $selectionRoot=if($script:gameRoot){$script:gameRoot}else{$path.Text}
 $selected='';try{$selected=[IO.Path]::GetFullPath($selectionRoot).TrimEnd('\')}catch{}
 if(-not $selected -or -not [string]::Equals($selected,$script:pendingFxPresetGame,[StringComparison]::OrdinalIgnoreCase)){
  ClearPendingFxPreset;$status.Text='The queued preset was cleared because the selected game changed.';return ''
 }
 return $script:pendingFxPresetPath
}
function InstallSelectedOptiMfgComponent([string]$ManifestPath){
 $original=ReadOptiShadeState $ManifestPath
 $approvedVersionDllHash='';$gpuPrompted=$false;$foreignPromptCount=0
 while($true){
  try{
   InstallOptiShadeAddon $ManifestPath $Payload 'OptiMfg' (GetFusionGpu) $progress -ExplicitSelection -ApprovedForeignVersionDllHash $approvedVersionDllHash
   return
  }catch{
   $failure=$_.Exception.GetBaseException().Message
   if($failure -match '^OPTIMFG_FOREIGN_VERSION_DLL_CONSENT_REQUIRED:([A-Fa-f0-9]{64})$'){
    $foundHash=$Matches[1].ToUpperInvariant();$foreignPromptCount++
    if($foreignPromptCount -gt 2 -or $foundHash -ceq $approvedVersionDllHash){throw 'The game-folder version.dll changed during OptiMFG setup. No replacement was made; rescan the game and retry.'}
    $game=ReadOptiShadeState $ManifestPath
    if($game.Status -ne 'Installed' -or (GetOptiShadeManagerStatusKey $game.Game) -cne (GetOptiShadeManagerStatusKey $original.Game)){throw 'Installation changed. Rescan this game before retrying OptiMFG.'}
    $versionDll=OwnedPath $game.Game 'version.dll'
    $message="A version.dll that OptiShade does not own is present in this game's folder:`n`n$versionDll`n`nIt may belong to another game add-on and can prevent OptiMFG from loading. If you continue, OptiShade will save a verified recovery copy and replace it with the OptiMFG backend. This may disable the add-on that installed it. Choose No to leave the file untouched and cancel OptiMFG setup."
    $consent=[string](ShowOptiShadeDialog $form $message 'Replace conflicting version.dll?' 'YesNo' 'Warning' 'No')
    if($consent -cne 'Yes'){throw 'OptiMFG setup cancelled. The unowned version.dll was left untouched.'}
    $approvedVersionDllHash=$foundHash
    continue
   }
   if($failure -like '*OPTIMFG_GPU_SELECTION_REQUIRED:*' -and -not $gpuPrompted){
    $gpuPrompted=$true
    if(-not(ShowNeuralAdapterPicker $ManifestPath 'OptiMfg')){throw 'OptiMFG GPU selection cancelled; no backend files were changed.'}
    $retry=ReadOptiShadeState $ManifestPath
    if($retry.Status -ne 'Installed' -or (GetOptiShadeManagerStatusKey $retry.Game) -cne (GetOptiShadeManagerStatusKey $original.Game)){throw 'Installation changed. Rescan this game before retrying OptiMFG.'}
    AssertClosed $retry.Game
    continue
   }
   throw
  }
 }
}
function InstallSelectedNeuralComponent([string]$ManifestPath,[string]$GameKey,[string]$DlssRuntimeProfile){
 $gpu=GetFusionGpu
 try{
  InstallOptiShadeAddon $ManifestPath $Payload 'Neural' $gpu $progress -ExplicitSelection -DlssRuntimeProfile $DlssRuntimeProfile
 }catch{
  $failure=$_.Exception.Message
  if($failure -notlike '*Multiple physical NVIDIA adapters remain possible*'){throw}
  if(-not(ShowNeuralAdapterPicker $ManifestPath)){throw 'Neural Rendering needs a measured GPU choice before its model can be installed. No component files were changed.'}
  # The picker can remain open while display topology changes. Re-read and
  # validate the selected game's receipt and adapter before the one retry.
  $retryManifest=ReadOptiShadeState $ManifestPath
  if($retryManifest.Status -ne 'Installed'){throw 'Installation changed. Repair or scan this game before retrying.'}
  if((GetOptiShadeManagerStatusKey $retryManifest.Game) -cne $GameKey){throw 'Installation changed to a different game. Rescan before retrying.'}
  AssertClosed $retryManifest.Game
  $gpu=GetFusionGpu
  $candidate=ResolveOptiShadeNeuralAdapter $retryManifest $gpu
  if($candidate.State -ne 'candidate'){throw ('The selected neural adapter is no longer available: '+$candidate.Reason)}
  InstallOptiShadeAddon $ManifestPath $Payload 'Neural' $gpu $progress -ExplicitSelection -DlssRuntimeProfile $DlssRuntimeProfile
 }
}
function UpdateComponentSelection{
 $cached=GetCachedManagerGameStatus $path.Text;$m=if($cached){$cached.Manifest}else{$null}
 $ready=$m -and $m.Status -eq 'Installed';$current=@(GetManagerComponentSelection $m);$selected=@(GetSelectedComponentIds)
 $selectedForRemoval=@($selected|Where-Object {$_ -in $current})
 $selectedForInstall=@($selected|Where-Object {$_ -notin $current})
 $profileSelector=$form.FindName('DlssRuntimeProfile');$gameKey=GetOptiShadeManagerStatusKey $path.Text
 if($script:dlssProfileDraftGame -and $script:dlssProfileDraftGame -cne $gameKey){$script:dlssRuntimeProfileChanged=$false}
 $script:dlssProfileDraftGame=$gameKey
 $storedProfile=if($ready -and $m.PSObject.Properties['DlssRuntimeProfile'] -and $m.DlssRuntimeProfile){[string]$m.DlssRuntimeProfile}else{'nvidia-310.9.16'}
 if(-not $script:dlssRuntimeProfileChanged){$profileItem=@($profileSelector.Items|Where-Object {$_.Tag -ceq $storedProfile})|Select-Object -First 1;if($profileItem){$script:syncingDlssRuntimeProfile=$true;try{$profileSelector.SelectedItem=$profileItem}finally{$script:syncingDlssRuntimeProfile=$false}}}
 $selectedProfile=[string]$profileSelector.SelectedValue;if($selectedProfile -cne 'nvidia-310.9.16'){$selectedProfile='nvidia-310.9.16'}
 $dlssProfileChanged=($ready -and 'Neural' -in $current -and 'Neural' -notin $selectedForRemoval -and $storedProfile -cne $selectedProfile)
 $pending=GetPendingFxPresetForSelectedGame
 $allFxInstalled=$false
 if($ready -and 'Effects' -in $current){$allFxInstalled=if($m.PSObject.Properties['AllFxInstalled']){[bool]$m.AllFxInstalled}else{[bool]$m.IncludeEffects}}
 $effectsModeChanged=($ready -and 'Effects' -in $current -and $form.FindName('InstallAllFx').IsChecked -eq $true -and -not $allFxInstalled)
 $canApply=($selectedForInstall.Count -gt 0 -or [bool]$pending -or $effectsModeChanged -or $dlssProfileChanged)
 $summary=$form.FindName('ComponentSelectionSummary')
 if(-not $ready){$summary.Text='Install the OptiShade core for this game before choosing optional components.'}
 else{
   $text=if($m.Architecture -eq 'x86'){'32-bit game: Image Effects plus experimental Legacy NR on D3D10/11 or OpenGL. D3D9 requires dgVoodoo configured before OptiShade, then Repair using DXGI. Vulkan needs an external 32-bit ReShade layer.'}else{"$($current.Count) optional component(s) installed"}
  if($selectedForInstall.Count){$text+=' · '+$selectedForInstall.Count+' selected to install'}
  if($selectedForRemoval.Count){$text+=' · '+$selectedForRemoval.Count+' selected to uninstall'}
  if($pending){$text+=' · preset queued; press Apply selected changes when ready'}
  if($effectsModeChanged){$text+=' · all FX will be added'}
  if($dlssProfileChanged){$text+=' · DLSS SR/RR '+$selectedProfile+' selected; press Apply selected changes to install'}
  if(-not $selectedForInstall.Count -and -not $selectedForRemoval.Count -and -not $pending -and -not $effectsModeChanged -and -not $dlssProfileChanged){$text+=' · select a component to install or mark one for removal'}
  if('Providers' -in $selectedForRemoval -and 'Mfg' -in $current){$text+=' · uninstall the frame generation add-on before its FSR / XeSS support'}
  $summary.Text=$text
 }
 $blockedProvider=('Providers' -in $selectedForRemoval -and 'Mfg' -in $current -and 'Mfg' -notin $selectedForRemoval)
 $form.FindName('ComponentsPlay').IsEnabled=([bool]$ready -and -not $script:busy)
 $form.FindName('ComponentsApply').IsEnabled=([bool]$ready -and -not $script:busy -and $canApply)
 $form.FindName('ComponentsUninstallSelected').IsEnabled=([bool]$ready -and -not $script:busy -and $selectedForRemoval.Count -gt 0 -and -not $blockedProvider)
 $availableToInstall=@($componentSelectors|Where-Object {$_.IsEnabled -and $_.Tag -notin $current})
 $form.FindName('ComponentsInstallAll').IsEnabled=([bool]$ready -and -not $script:busy -and $availableToInstall.Count -gt 0)
 $effectsSelected=([bool]('Effects' -in $current) -or [bool]('Effects' -in $selectedForInstall))
 $form.FindName('InstallAllFx').IsEnabled=([bool]$ready -and $effectsSelected -and -not $script:busy)
 $form.FindName('ImportFxIni').IsEnabled=([bool]$ready -and $effectsSelected -and -not $script:busy)
}
$form.FindName('DlssRuntimeProfile').Add_SelectionChanged({if($script:syncingDlssRuntimeProfile){return};$script:dlssRuntimeProfileChanged=$true;$script:dlssProfileDraftGame=GetOptiShadeManagerStatusKey $path.Text;UpdateComponentSelection})
function InstallLatestGlassCockpitRelease([string]$ManifestPath){
 try{
  $release=GetGlassCockpitLatestRelease -ReportErrors
  $script:glassCockpitLatestRelease=$release;$script:glassCockpitLastCheckUtc=[DateTime]::UtcNow
  $info=GetGlassCockpitUpdateInfo (ReadOptiShadeState $ManifestPath) $release
  if($info.Available -and $info.CanDownload){
   & $progress ('Updating the Glass Cockpit fix to '+$info.LatestVersion+' from the developer release...') 0 0
   $null=UpdateGlassCockpitAddon $ManifestPath $release $progress
   WriteInstallerLog ('Glass Cockpit fix installed at the latest developer release '+$info.LatestVersion+' (bundled '+$info.InstalledVersion+')')
  }
 }catch{WriteInstallerLog ('Glass Cockpit fix: the latest developer release was not installed; the bundled copy remains. '+$_.Exception.GetBaseException().Message)}
}
function InvokeComponentSelection{
 $mp=ManifestPath $store $path.Text
 if(-not(Test-Path -LiteralPath $mp)){throw 'Install the OptiShade core for this game before choosing components.'}
 $record=ReadOptiShadeState $mp;if($record.Status -ne 'Installed'){throw 'Repair the OptiShade core before changing components.'}
 AssertAntiCheatMutation $record.Game $record.LaunchExe 'Apply selected components'
 $current=@(GetManagerComponentSelection $record);$checked=@(GetSelectedComponentIds);$desired=@($checked|Where-Object {$_ -notin $current});$presetToApply=GetPendingFxPresetForSelectedGame;$installAllFx=($form.FindName('InstallAllFx').IsChecked -eq $true)
 $selectedProfile=[string]$form.FindName('DlssRuntimeProfile').SelectedValue;if($selectedProfile -cne 'nvidia-310.9.16'){$selectedProfile='nvidia-310.9.16'}
 $storedProfile=if($record.PSObject.Properties['DlssRuntimeProfile'] -and $record.DlssRuntimeProfile){[string]$record.DlssRuntimeProfile}else{'nvidia-310.9.16'}
 if('Neural' -in $current -and 'Neural' -notin $checked -and $selectedProfile -cne $storedProfile -and 'Neural' -notin $desired){$desired+=,'Neural'}
 $allFxInstalled=$false
 if('Effects' -in $current){$allFxInstalled=if($record.PSObject.Properties['AllFxInstalled']){[bool]$record.AllFxInstalled}else{[bool]$record.IncludeEffects}}
 if('Effects' -in $current -and $installAllFx -and -not $allFxInstalled){$desired+=,'Effects'}
 if($presetToApply -and 'Effects' -notin $current -and 'Effects' -notin $desired){$desired+=,'Effects'}
 $mfgDeferredMessage=''
 if('Mfg' -in $desired){
  try{$mfgDecision=GetOptiShadeInstallProviderDecision $record $Payload (GetFusionGpu) (GetOptiShadeMfgPolicyChannel) -AllowPreinstall}
  catch{$mfgDecision='unknown_adapter';$mfgDeferredMessage='MFG is selected for an in-game compatibility check. Setup could not verify the live game/provider in advance; it will stage what is safe and report the runtime result after launch. '+$_.Exception.GetBaseException().Message}
  if($mfgDecision -notin @('source','legacy','sm86','native')){
   if(-not $mfgDeferredMessage){$mfgDeferredMessage='MFG is selected for an in-game compatibility check. Setup could not establish the live provider in advance; the running game will determine whether it can activate.'}
   $mfgDecision='deferred'
   WriteInstallerLog ('MFG component retained for an in-game compatibility check without provider mutation. '+$mfgDeferredMessage)
  }
 }
 if('Mfg' -in $desired -and $mfgDecision -notin @('native','deferred') -and 'Providers' -notin $current -and 'Providers' -notin $desired){$desired+=,'Providers'}
 if('Cockpit' -in $desired -and -not(Test-Path -LiteralPath (OwnedPath $record.Game 'FlightSimulator2024.exe'))){throw 'Glass cockpit correction is available for MSFS 2024 only.'}
 if('Atmosphere' -in $desired){
  if(-not(Test-Path -LiteralPath (OwnedPath $record.Game 'FlightSimulator2024.exe'))){throw 'AtmosphereMod is available for MSFS 2024 only.'}
  # A third-party experimental mod downloaded from its author: ask once, as the author's installer does.
  if((ShowOptiShadeDialog $form "AtmosphereMod is an experimental mod by tomwhoca. OptiShade downloads its latest official release from GitHub and installs it: it patches shaders from your copy of MSFS 2024 (about a minute; the game files are not changed), adds AtmosphereMod.addon64 beside OptiShade's ReShade, an [ATMOSPHEREMOD] section to ReShade.ini and its EFB sim bridge to your Community folder. Use it at your own risk; Ctrl+Shift+F9 switches it off in the sim.`n`nInstall AtmosphereMod?" 'AtmosphereMod' 'YesNo' 'Question' 'No') -ne 'Yes'){$desired=@($desired|Where-Object {$_ -ne 'Atmosphere'});[void]$script:componentSelections.Remove('Atmosphere')}
 }
 if('Neural' -in $desired){
  $gpu=GetFusionGpu
  $nr=(GetNeuralAddonCardState $true ('Neural' -in $current) (GetNeuralRuntimeStatus $record.Game $gpu $record).State)
  if(-not $nr.Available -and 'Neural' -notin $current){throw $nr.Text}
 }
 if($script:modularDistribution){
  # Neural rendering, Glass Cockpit and AtmosphereMod retain their existing
  # independent download/install routes. Only legacy MFG is not modularized.
  $notYetOnline=@($desired|Where-Object {$_ -eq 'Mfg'})
  if($notYetOnline.Count){throw ('These selected components still depend on payload files that are not in the online signed package set: '+($notYetOnline -join ', ')+'. No game files were changed. Use the full bundled R build until their independent delivery paths are complete.')}
 }
 $onlinePayloadIds=@()
 if('Effects' -in $desired){$onlinePayloadIds+=,'OptiShade.Effects'}
 if('OptiMfg' -in $desired){$onlinePayloadIds+=,'OptiShade.OptiMFG'}
 if('Providers' -in $desired){$onlinePayloadIds+=,'OptiShade.Providers'}
 # Glass Cockpit ships in Core and then refreshes from IFreemz's verified
 # release. Neural Rendering and AtmosphereMod use direct publisher/model
 # routes and therefore need no Core payload re-download.
 $needsCorePayload=('Cockpit' -in $desired)
 if($script:modularDistribution -and ($onlinePayloadIds.Count -or $needsCorePayload)){EnsureVerifiedModularPayload $onlinePayloadIds}
 # Selecting Neural Rendering is the explicit install choice. The component
 # card describes its runtime/model downloads, so don't ask for a second Yes.
 $added=@();$componentIssues=@()
 foreach($id in @('Effects','Neural','Providers','OptiMfg','Mfg','Cockpit','Atmosphere')|Where-Object {$desired -contains $_}){
  try{
   if($id -eq 'Effects'){$skipAllFx=(-not $installAllFx);InstallOptiShadeAddon $mp $Payload $id (GetFusionGpu) $progress -SkipAllFx:$skipAllFx -ExplicitSelection}
   elseif($id -eq 'OptiMfg'){InstallSelectedOptiMfgComponent $mp}
   elseif($id -eq 'Neural'){InstallSelectedNeuralComponent $mp (GetOptiShadeManagerStatusKey $record.Game) $selectedProfile}
   elseif($id -eq 'Atmosphere'){& $progress 'Downloading and installing AtmosphereMod...' 0 0;$null=InstallAtmosphereMod $record.Game {$form.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)}}
   else{$componentResult=InstallOptiShadeAddon $mp $Payload $id (GetFusionGpu) $progress -ExplicitSelection;if($id -eq 'Mfg' -and ($mfgDecision -eq 'deferred' -or $componentResult -match 'in-game')){$mfgDeferredMessage=$componentResult}}
   # The bundled Glass Cockpit fix can lag the developer's release: install
   # the latest verified official release straight away when it is newer. The
   # bundled copy stays if GitHub is unreachable.
   if($id -eq 'Cockpit'){InstallLatestGlassCockpitRelease $mp}
   $added+=,$id;[void]$script:componentSelections.Remove($id)
  }catch{
   if($id -eq 'Providers' -and 'Mfg' -in $desired -and 'Mfg' -notin $current -and 'Providers' -notin $selectedForInstall){
    $failure=$_.Exception.GetBaseException().Message
    $mfgDeferredMessage='MFG remains selected for an in-game compatibility check. Its optional provider dependency could not be installed: '+$failure
    [void]$script:componentSelections.Remove('Providers')
    WriteInstallerLog ('MFG selection retained; optional provider dependency installation failed: '+$failure)
    continue
   }
   if($id -ne 'Mfg'){throw}
   $failure=$_.Exception.GetBaseException().Message;$pending=$false
   try{$pending=[bool](GetOptiShadeRouteRecovery $mp)}catch{$pending=$true;$failure+=' Recovery state could not be verified: '+$_.Exception.GetBaseException().Message}
   if($pending){throw ('MFG installation stopped with a pending recovery that needs review. '+$failure)}
   $componentIssues+=,$failure;$script:operationAttention=$true
   WriteInstallerLog ('MFG component deferred after a safe rollback; other selected components may continue. '+$failure)
  }
 }
 $presetWarning=''
 if($presetToApply){
  $script:applyPresetWarning=''
  InvokeAddonTransaction $mp 'Effects' {
   $relative=''
   try{
    $relative=SaveOwnPreset $presetToApply $path.Text (Join-Path $PSScriptRoot 'EffectPackages.ini')
    $script:applyPresetWarning=InstallPresetDependencies (OwnedPath $path.Text $relative) $path.Text (Join-Path $PSScriptRoot 'EffectPackages.ini')
    SetOptiShadeReShadePreset $path.Text $relative
    $m=ReadOptiShadeState $mp;$m|Add-Member IncludeEffects $true -Force;$m|Add-Member AllFxInstalled ([bool]$installAllFx) -Force;$m|Add-Member FxPresetRelative $relative -Force
    $m|Add-Member Components @(@(GetOptiShadeAddonSelection $m)+'Effects'|Select-Object -Unique) -Force;SetOptiShadeAutoComponentExclusion $m 'Effects' $false;WriteState $m $mp
   }catch{if($relative){$created=OwnedPath $path.Text $relative;if(Test-Path -LiteralPath $created -PathType Leaf){Remove-Item -LiteralPath $created -Force -ErrorAction SilentlyContinue}};throw}
  }
  $presetWarning=$script:applyPresetWarning;ClearPendingFxPreset;[void]$script:componentSelections.Remove('Effects')
 }
 if($componentIssues.Count){$status.Text=if($added.Count){'Other selected components were applied. MFG was not installed: '+($componentIssues -join ' | ')}else{'MFG was not installed: '+($componentIssues -join ' | ')}}
 elseif($mfgDeferredMessage){$status.Text=if($added.Count){'Other selected components were installed. '+$mfgDeferredMessage}else{$mfgDeferredMessage}}
 elseif($added.Count){$status.Text='Selected components installed or refreshed. To remove an installed component, mark it for uninstall and use Uninstall selected.'}
 else{$status.Text='No new component installation was needed.'}
 if('Effects' -in $added -and $installAllFx){$status.Text+=' All FX are installed.'}
 if($presetToApply){$status.Text+=' Saved look '+[IO.Path]::GetFileName((ReadOptiShadeState $mp).FxPresetRelative)+' is set to load automatically when the game starts.'}
 if($presetWarning){$status.Text+=' '+$presetWarning}
 if('Neural' -in $added){
  $script:dlssRuntimeProfileChanged=$false
  $m=ReadOptiShadeState $mp;$gpu=GetFusionGpu;$nr=GetNeuralRuntimeStatus $m.Game $gpu $m
   if($m.Architecture -eq 'x86'){$status.Text+=' Legacy NR bridge installed. '+[string]$m.LegacyNrPresetMessage+' Game output still needs testing.'}
  $status.Text+=if($nr.State -in @('Verified file','Experimental community build')){' Neural model hash recognized; game testing is still required. '+$nr.Message}else{' Neural Rendering is not ready: '+$nr.Message}
 }
}
function ConfirmAndUninstallComponents([string[]]$Ids){
 $mp=ManifestPath $store $path.Text
 if(-not(Test-Path -LiteralPath $mp)){throw 'Install the OptiShade core for this game first.'}
 $record=ReadOptiShadeState $mp;if($record.Status -ne 'Installed'){throw 'Repair the OptiShade core before removing components.'}
 $current=@(GetManagerComponentSelection $record);$chosen=@($Ids|Where-Object {$_ -in $current}|Select-Object -Unique)
 if(-not $chosen.Count){$status.Text='No installed components were selected for removal.';return}
 if('Providers' -in $chosen -and 'Mfg' -in $current -and 'Mfg' -notin $chosen){[void](ShowOptiShadeDialog $form 'Remove the frame generation add-on first; it still depends on FSR / XeSS support.' 'Component still required');return}
 $order=@('Atmosphere','OptiMfg','Mfg','Cockpit','Neural','Effects','Providers')|Where-Object {$chosen -contains $_}
 $labels=@{Effects='Image effects';Neural='Neural rendering';Mfg='Legacy frame generation';OptiMfg='OptiMFG';Cockpit='Glass cockpit correction';Providers='FSR / XeSS support';Atmosphere='AtmosphereMod'}
 $list=($order|ForEach-Object {'• '+$labels[$_]}) -join "`n"
 if((ShowOptiShadeDialog $form ("Uninstall these selected components from this game?`n`n$list`n`nRecorded original files will be restored where available. Edited or unowned files are protected. Close the game first.") 'Uninstall selected components' 'YesNo' 'Question' 'No') -ne 'Yes'){return}
 RunAction {
  foreach($id in $order){& $progress ('Removing '+$labels[$id]+'...') 0 0;if($id -eq 'Atmosphere'){$null=UninstallAtmosphereMod $record.Game {$form.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)}}else{RemoveOptiShadeAddon $mp $id};[void]$script:componentSelections.Remove($id)}
  $status.Text='Uninstalled '+(($order|ForEach-Object {$labels[$_]}) -join ', ')+'. Recorded original files were restored; saved looks are kept.'
 } 'Uninstalling selected components'
}
function RefreshAddonCards {
 $script:refreshingAddonCards=$true
 try{
  $cached=GetCachedManagerGameStatus $path.Text;$m=if($cached){$cached.Manifest}else{$null}
  $ready=$m -and $m.Status -eq 'Installed';$x86Only=$ready -and $m.Architecture -eq 'x86';$selected=@(GetOptiShadeAddonSelection $m)
  $coreStatus=$form.FindName('AddonCoreStatus');$coreDot=$form.FindName('AddonCoreStatusDot')
  if($ready){$coreStatus.Text='Installed • required • managed in Setup';$coreStatus.Foreground='#55DCA5';$coreDot.Fill='#55DCA5'}
  else{$coreStatus.Text='Not installed • required • managed in Setup';$coreStatus.Foreground='#CBB2F3';$coreDot.Fill='#A99ABF'}
  # Keep an explicit MFG test selection even for a 32-bit renderer. It will be
  # recorded as deferred without staging a 64-bit provider, then runtime
  # capability can be observed if the game exposes a compatible path.
  if($x86Only){foreach($id in @('Cockpit','Providers')){[void]$script:componentSelections.Remove($id)}}
  $outdated=if($cached){@($cached.Info.Components)}else{@()}
  $updateRow=$form.FindName('ComponentUpdateRow');$updateButton=$form.FindName('ComponentsUpdateAll')
  if($outdated.Count){$updateRow.Visibility='Visible';$updateButton.Content='Open Update Manager';$labels=@{Effects='Image effects';Neural='Neural rendering';Mfg='Frame generation';OptiMfg='OptiMFG';Cockpit='Glass cockpit correction';Providers='FSR / XeSS support'};$form.FindName('ComponentUpdatesStatus').Text='Update available: '+(($outdated|ForEach-Object {$labels[$_]}) -join ', ')}else{$updateRow.Visibility='Collapsed'}
  $allFx=$false
  if($ready -and 'Effects' -in $selected){$allFx=if($m.PSObject.Properties['AllFxInstalled']){[bool]$m.AllFxInstalled}else{[bool]$m.IncludeEffects}}
  $form.FindName('InstallAllFx').IsChecked=GetAllFxSelectionForDisplay ([bool]$allFx)
  $pending=GetPendingFxPresetForSelectedGame
  if($pending){$form.FindName('FxIniName').Text='Preset selected: '+[IO.Path]::GetFileName($pending)+' · press Apply selected changes to install';$form.FindName('FxIniName').Visibility='Visible'}
  elseif($ready -and $m.PSObject.Properties['FxPresetRelative'] -and $m.FxPresetRelative){$form.FindName('FxIniName').Text='Preset on file: '+[IO.Path]::GetFileName([string]$m.FxPresetRelative);$form.FindName('FxIniName').Visibility='Visible'}
  else{$form.FindName('FxIniName').Visibility='Collapsed'}
  foreach($id in @('Effects','Neural','Mfg','Cockpit','Providers')){
   $componentId=if($id -eq 'Mfg'){GetOptiMfgCardComponentId}else{$id};$on=$componentId -in $selected;$isOptiMfg=($id -eq 'Mfg' -and $componentId -eq 'OptiMfg');$statusControl=$form.FindName('Addon'+$id+'Status');$selector=$form.FindName('Addon'+$id+'Selected');$uninstallButton=$form.FindName('Addon'+$id+'Uninstall')
   $selector.IsChecked=[bool]$script:componentSelections[$componentId];$selector.Tag=$componentId;$selector.Content=if($on){'Select to uninstall'}elseif($isOptiMfg){'Install OptiMFG'}else{'Select to install'}
   $selector.ToolTip=if($on){'Mark this installed component, then press Uninstall selected.'}else{'Select this component, then press Apply selected changes to install it.'}
   $uninstallButton.Visibility=if($ready -and $on){'Visible'}else{'Collapsed'};$uninstallButton.Tag=$componentId;$uninstallButton.IsEnabled=([bool]$ready -and [bool]$on -and -not $script:busy)
   if($id -eq 'Mfg'){
    $startButton=$form.FindName('AddonMfgStart');$startButton.Visibility=if($ready -and $on -and $isOptiMfg){'Visible'}else{'Collapsed'};$startButton.IsEnabled=([bool]$ready -and [bool]$on -and $isOptiMfg -and -not $script:busy)
   }
   if($id -eq 'Neural'){
    $runtimeState='Unavailable'
    if($ready){$runtimeState=$cached.RuntimeState}
    $card=GetNeuralAddonCardState ([bool]$ready) ([bool]$on) $runtimeState
    $statusControl.Foreground=$card.Foreground;$statusControl.Text=$card.Text
    # MFG selection is a durable test request. Do not let a stale, missing or
    # negative install-time compatibility result disable its card; provider
    # discovery and activation are evaluated by the live game session.
    $selector.IsEnabled=if($id -eq 'Mfg'){[bool]$ready -and -not $script:busy}else{[bool]$ready -and ([bool]$on -or [bool]$card.Available) -and -not $script:busy}
    $description=$form.FindName('AddonNeuralDescription')
    if($x86Only){
      $description.Text='Experimental x86-to-x64 NR bridge for D3D10/11 and OpenGL. Installing the component prepares its worker and matching model. Enable NR in game after input checks. Existing presets and external guide choices are kept. Native D3D9 needs a configured D3D9-to-D3D11 wrapper and DXGI attachment.'
      $gameApi=$cached.GameApi
      if($gameApi -and $gameApi.ApiCandidates -contains 'DX9' -and (-not([bool]$cached.LegacyWrapper) -or $cached.InstalledLoader -ne 'dxgi.dll')){$statusControl.Text=if(-not([bool]$cached.LegacyWrapper)){'D3D9 wrapper required before Legacy NR'}else{'Repair OptiShade using DXGI before Legacy NR'};$statusControl.Foreground='#FFBE83';if(-not $on){$selector.IsEnabled=$false}}
      elseif($on -and $runtimeState -eq 'Verified file'){$statusControl.Text='Installed • model verified; game test required'}
     elseif(-not $on -and $card.Available){$statusControl.Text='Available • experimental x86 bridge'}
    }else{$description.Text='Experimental NVIDIA Neural Rendering target: RTX 20, 30, 40 and 50 series. The compatible model, game, graphics API and runtime input path must still match.'}
   }else{
    $statusControl.Foreground=if($on){'#55DCA5'}else{'#A99ABF'}
    $statusControl.Text=if(-not $ready){'Install core first'}elseif($isOptiMfg -and $on -and (TestOptiMfgComponentNeedsRepair $m)){'Update required • backend preparation incomplete'}elseif($isOptiMfg -and $on){'Installed • controller and GPU backend prepared'}elseif($isOptiMfg -and $ready -and $m.Architecture -eq 'x64' -and ((Test-Path -LiteralPath (OwnedPath $m.Game 'FlightSimulator2024.exe')) -or (Test-Path -LiteralPath (OwnedPath $m.Game 'FlightSimulator.exe')))){'Optional • external live MFG controls'}elseif($isOptiMfg){'Unavailable • this build currently supports MSFS only'}elseif($id -eq 'Mfg' -and $m.NativeMfg){'Legacy MFG • native game route'}elseif($id -eq 'Mfg' -and $m.PreparedMfg){'Legacy MFG • prepared; inactive'}elseif($id -eq 'Mfg' -and $m.DeferredMfg){'Legacy MFG • provider check deferred'}elseif($id -eq 'Mfg' -and ($m.Sm86Mfg -or $m.OptionalMfg -or $m.SourceMfg)){'Legacy MFG provider installed • uninstall before OptiMFG'}elseif($on){'Installed • optional'}else{'Not installed'}
    $selector.IsEnabled=([bool]$ready -and -not $script:busy)
   }
   if($id -eq 'Mfg' -and $isOptiMfg -and $ready -and -not $on){
    $selector.IsEnabled=([bool]$ready -and -not $script:busy -and $m.Architecture -eq 'x64' -and ((Test-Path -LiteralPath (OwnedPath $m.Game 'FlightSimulator2024.exe')) -or (Test-Path -LiteralPath (OwnedPath $m.Game 'FlightSimulator.exe'))))
   }elseif($id -eq 'Mfg' -and $ready -and -not $on){
    # MFG remains selectable when setup-time checks cannot identify a provider.
    # Runtime compatibility is checked in-game; no guessed DLL is installed.
    $selector.IsEnabled=([bool]$ready -and -not $script:busy)
    $statusControl.Foreground='#A99ABF'
    $route=[string]$cached.MfgRoute
    switch($route){
     'native' {$statusControl.Text='Ready to select • native MFG checked in-game';$selector.ToolTip=[string]$cached.MfgAdmissionReason}
     'sm86' {$statusControl.Text='Available • RTX 20/30 provider; output checked in-game';$selector.ToolTip=[string]$cached.MfgAdmissionReason}
     'legacy' {$statusControl.Text='Available • RTX 40 provider; output checked in-game';$selector.ToolTip=[string]$cached.MfgAdmissionReason+' '+[string]$cached.MfgLoaderReason}
     'source' {$statusControl.Text='Available • OptiShade MFG provider; output checked in-game';$selector.ToolTip=[string]$cached.MfgAdmissionReason}
     default {$statusControl.Text='Ready to install • compatibility checked in-game';$selector.ToolTip='Install the MFG component now. Live game/provider compatibility is checked after the game starts. '+[string]$cached.MfgAdmissionReason+' '+[string]$cached.MfgLoaderReason}
    }
   }   if($id -eq 'Cockpit' -and $ready -and -not([bool]$cached.CockpitAvailable)){
    $statusControl.Foreground=if($on){'#55DCA5'}else{'#A99ABF'};$statusControl.Text=if($on){'Installed • MSFS 2024 only'}else{'MSFS 2024 only'}
    $cockpitAvailable=[bool]$cached.CockpitAvailable
    $selector.IsEnabled=([bool]$ready -and ([bool]$on -or [bool]$cockpitAvailable) -and -not $script:busy)
   }
   if($id -eq 'Cockpit'){
    $releaseButton=$form.FindName('AddonCockpitOpenRelease');$releaseState=$form.FindName('AddonCockpitUpdateState')
    $releaseButton.Visibility='Collapsed';$releaseButton.IsEnabled=$false;$releaseState.Visibility='Collapsed';$releaseState.Text=''
    if($ready -and ([bool]$cached.CockpitAvailable)){
     $cockpitInfo=$cached.Glass
     if($cockpitInfo.Installed){$statusControl.Text='Installed '+$cockpitInfo.InstalledVersion+$(if($cockpitInfo.Available){' · Update available'}else{''});$statusControl.Foreground=if($cockpitInfo.Available){'#FFBE83'}else{'#55DCA5'}}
     if($cockpitInfo.Available){
      $releaseButton.Content='Open Update Manager';$releaseButton.ToolTip='Review this Glass Cockpit update in Update Manager'
      $releaseButton.IsEnabled=$true;$releaseButton.Visibility='Visible'
       $releaseState.Text='Installed '+$cockpitInfo.InstalledVersion+' | Available '+$cockpitInfo.LatestVersion;$releaseState.Visibility='Visible'
     }elseif($cockpitInfo.Installed -and $cockpitInfo.State -eq 'Current'){
      $releaseState.Text=$cockpitInfo.InstalledVersion+' · up to date with the developer release';$releaseState.Visibility='Visible'
     }elseif($cockpitInfo.Installed -and $script:glassCockpitLastCheckUtc -and -not $script:glassCockpitLatestRelease){
      $releaseState.Text='Could not check developer updates. Open the official releases to check manually.';$releaseState.Visibility='Visible'
      $releaseButton.Content='Open Update Manager';$releaseButton.Tag='https://github.com/IFreemz/msfs2024-glass-cockpit-dlss-fix/releases';$releaseButton.IsEnabled=$true;$releaseButton.Visibility='Visible'
     }elseif($cockpitInfo.Installed){
      $releaseState.Text='Checking the developer release feed…';$releaseState.Visibility='Visible'
     }
    }
   }
   if($id -eq 'Providers' -and $ready -and 'Mfg' -in $selected){$selector.IsEnabled=$false;$uninstallButton.IsEnabled=$false;$selector.ToolTip='Remove the frame generation add-on first; it still needs FSR / XeSS support.'}
   if($x86Only -and $id -in @('Cockpit','Providers')){
    $statusControl.Foreground='#A99ABF';$statusControl.Text='Unavailable • needs a 64-bit game build'
    $selector.IsEnabled=$false;$selector.IsChecked=$false;$selector.ToolTip='This component loads inside the game and is available only for supported 64-bit builds.'
    $uninstallButton.Visibility='Collapsed';$uninstallButton.IsEnabled=$false
    if($id -eq 'Cockpit'){$form.FindName('AddonCockpitOpenRelease').Visibility='Collapsed';$form.FindName('AddonCockpitUpdateState').Visibility='Collapsed'}
   }
   if($x86Only -and $id -eq 'Mfg'){
    $statusControl.Foreground='#FFBE83';$statusControl.Text=if($on){'Selected • provider needs 64-bit game'}else{'Selectable • provider needs 64-bit game'}
    $selector.IsEnabled=([bool]$ready -and -not $script:busy)
    $selector.ToolTip='You can record the MFG test selection, but a 64-bit rendering executable is required to load any MFG provider. No provider files are installed for a 32-bit renderer.'
   }
   if($on -and $id -in $outdated){$statusControl.Foreground='#FFBE83';$statusControl.Text='Update available · files differ from this build'}
   # MFG install selection is intentionally independent of the asynchronous
   # provider scan. A missing/stale adapter or game API report must not hide
   # the component; its live provider check happens after the game starts.
   if(($ready -and -not $cached.DetailReady -and $id -in @('Neural','Cockpit')) -or (-not $cached -and $path.Text)){$statusControl.Text='Checking installed components…';$statusControl.Foreground='#A99ABF';$selector.IsEnabled=$false;$uninstallButton.IsEnabled=$false}
   elseif($ready -and -not $cached.DetailReady -and $id -eq 'Mfg' -and -not $on){$statusControl.Text='Ready to install • compatibility checked in-game';$statusControl.Foreground='#A99ABF';$selector.ToolTip='Install the MFG component now. Live game/provider compatibility and activation are checked in-game.';$selector.IsEnabled=(-not $script:busy)}
  }
  RefreshAtmosphereModCard $ready
 }finally{$script:refreshingAddonCards=$false}
 $count=if($ready){1+$selected.Count+$(if('Atmosphere' -in @(GetManagerComponentSelection $m)){1}else{0})}else{0}
 $free=if($cached){$cached.FreeSpace}else{'Checking'}
 $form.FindName('ComponentSummary').Text=('Installed components: '+$count+' / 7'+[Environment]::NewLine+'Available disk space: '+$free)
 UpdateComponentSelection
 StartGlassCockpitReleaseCheck
}
# AtmosphereMod is installed by OptiShade outside the receipt. It uses
# the same tick box, bulk install and uninstall as the other cards; whether it
# is installed comes from the mod's own install record.
function RefreshAtmosphereModCard($ready){
 $statusControl=$form.FindName('AddonAtmosphereStatus');$detail=$form.FindName('AddonAtmosphereDetail')
 $selector=$form.FindName('AddonAtmosphereSelected');$remove=$form.FindName('AddonAtmosphereUninstall')
 $detail.Visibility='Collapsed';$remove.Visibility='Collapsed';$remove.Tag='Atmosphere';$selector.Tag='Atmosphere'
 $state=if($path.Text){try{GetAtmosphereModState $path.Text}catch{$null}}else{$null}
 $on=[bool]($ready -and $state -and $state.Installed)
 $selector.IsChecked=[bool]$script:componentSelections['Atmosphere']
 $selector.Content=if($on){'Select to uninstall'}else{'Select to install'}
 $selector.ToolTip=if($on){'Mark this installed component, then press Uninstall selected.'}else{'Select this component, then press Apply selected changes to download and install it.'}
 if(-not $ready -or -not $state){$statusControl.Text='Not installed';$statusControl.Foreground='#A99ABF';$selector.IsEnabled=$false;return}
 if(-not $state.Supported){$statusControl.Text='MSFS 2024 only';$statusControl.Foreground='#A99ABF';$selector.IsEnabled=$false;$selector.IsChecked=$false;$selector.ToolTip='AtmosphereMod is for Microsoft Flight Simulator 2024 only.';return}
 $selector.IsEnabled=-not $script:busy
 if($on){
  $remove.Visibility='Visible';$remove.IsEnabled=-not $script:busy
  $version=if($state.Version){' '+$state.Version}else{''}
  # There is no re-patch step for the player: after a sim update, or when the
  # EFB app or the ReShade.ini settings are missing, OptiShade installs it
  # again by itself, once per game each time the launcher runs.
  # Only the missing step runs: a full re-patch only after a sim update.
  $missingBridge=(-not $state.Community) -and $state.CommunityAvailable
  if($state.NeedsRepatch -or -not $state.SectionPresent -or $missingBridge){
   $step=if($state.NeedsRepatch -or -not $state.Version){'re-patching for the sim update (a few minutes)'}elseif($missingBridge){'adding the EFB app'}else{'restoring its ReShade.ini settings'}
   $statusControl.Text='Installed'+$version+' · '+$step;$statusControl.Foreground='#FFBE83'
   StartAtmosphereModAutoRepair $path.Text $step
  }
  else{
   $update=GetAtmosphereModUpdateInfo $state $script:atmosphereLatestRelease
   if($update.Available){$statusControl.Text='Installed'+$version+' · Update '+$update.LatestVersion+' available in Update Manager';$statusControl.Foreground='#FFBE83'}
   elseif($script:atmosphereLastCheckUtc -and -not $script:atmosphereLatestRelease){$statusControl.Text='Installed'+$version+' · Update check unavailable';$statusControl.Foreground='#FFBE83'}
   elseif($update.UnknownVersion){$statusControl.Text='Installed · Version unknown';$statusControl.Foreground='#FFBE83'}
   else{$statusControl.Text='Installed'+$version;$statusControl.Foreground='#55DCA5'}
  }
  $lines=@()
  if($state.Patched -or $state.Failed){$lines+=('Shaders patched: '+$state.Patched+$(if($state.Failed){' · '+$state.Failed+' left stock'}else{''}))}
  $lines+=if($state.Community){'EFB app installed: METAR haze and the tablet settings are on'}else{'EFB app not installed (Community folder not found): METAR features are off'}
  $detail.Text=$lines -join [Environment]::NewLine;$detail.Visibility='Visible'
 }else{
  $statusControl.Text='Not installed';$statusControl.Foreground='#CBB2F3'
  if($state.OtherGame){$detail.Text='AtmosphereMod is installed for another copy of the sim: '+$state.OtherGame;$detail.Visibility='Visible'}
 }
}
$script:atmosphereAutoRepairTried=@{}
function StartAtmosphereModAutoRepair([string]$Game,[string]$Step='finishing the install'){
 if(-not $Game -or $script:busy -or -not $script:startupReady -or $script:atmosphereAutoRepairTried.ContainsKey($Game.ToLowerInvariant())){return}
 $script:atmosphereAutoRepairTried[$Game.ToLowerInvariant()]=$true;$script:atmosphereAutoRepairGame=$Game;$script:atmosphereAutoRepairStep=$Step
 $null=$form.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background,[Action]{
  RunAction {
   $Game=$script:atmosphereAutoRepairGame
   $state=RepairAtmosphereMod $Game {$form.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)}
   WriteInstallerLog ('AtmosphereMod finished automatically for '+$Game+': '+$state.Patched+' shaders patched; EFB app '+$(if($state.Community){'in '+$state.Community}else{'not installed (Community folder not found)'}))
   $status.Text='AtmosphereMod is installed'+$(if($state.Version){' ('+$state.Version+')'}else{''})+'. Start the sim; Ctrl+Shift+F9 switches it on and off.'
  } ('AtmosphereMod: '+$script:atmosphereAutoRepairStep)
 })
}
$form.FindName('ComponentsUpdateAll').Add_Click({ShowPage 'Updates'})
$componentHandlers=@('AddonEffectsSelected','AddonNeuralSelected','AddonMfgSelected','AddonCockpitSelected','AddonProvidersSelected','AddonAtmosphereSelected')
foreach($name in $componentHandlers){
 $selector=$form.FindName($name);$selector.Tag=$name.Substring(5,$name.Length-13)
 $selector.Add_Checked({param($sender,$event) if($script:refreshingAddonCards){return};$script:componentSelections[[string]$sender.Tag]=$true;UpdateComponentSelection})
 $selector.Add_Unchecked({param($sender,$event) if($script:refreshingAddonCards){return};[void]$script:componentSelections.Remove([string]$sender.Tag);UpdateComponentSelection})
}
$form.FindName('ComponentsApply').Add_Click({RunAction {InvokeComponentSelection} 'Applying selected components'})
$form.FindName('ComponentsUninstallSelected').Add_Click({try{$mp=ManifestPath $store $path.Text;$m=ReadOptiShadeState $mp;$current=@(GetManagerComponentSelection $m);$ids=@(GetSelectedComponentIds|Where-Object {$_ -in $current});ConfirmAndUninstallComponents $ids}catch{$status.Text=$_.Exception.Message;$status.Foreground='#FFBE83'}})
$componentUninstallButtons=@('AddonEffectsUninstall','AddonNeuralUninstall','AddonMfgUninstall','AddonCockpitUninstall','AddonProvidersUninstall','AddonAtmosphereUninstall')
foreach($name in $componentUninstallButtons){$form.FindName($name).Add_Click({param($sender,$event)try{ConfirmAndUninstallComponents ([string[]]@([string]$sender.Tag))}catch{$status.Text=$_.Exception.Message;$status.Foreground='#FFBE83'}})}
$form.FindName('AddonMfgStart').Add_Click({
 try{
  $mp=ManifestPath $store $path.Text;if(-not(Test-Path -LiteralPath $mp -PathType Leaf)){throw 'Install the OptiShade core and OptiMFG component first.'}
  $m=ReadOptiShadeState $mp;$result=StartOptiMfgController $m
  $status.Text=if($result -eq 'already running'){'OptiMFG is already running in the system tray. It will connect when MSFS is ready and close when the simulator exits.'}else{'OptiMFG started in the system tray. It will detect MSFS 2020 / 2024 when ready, then close when the simulator exits.'};$status.Foreground='#55DCA5'
 }catch{$status.Text='Could not start OptiMFG: '+$_.Exception.GetBaseException().Message;$status.Foreground='#FFBE83';WriteInstallerLog ('OptiMFG start failed: '+$_.Exception.GetBaseException().Message)}
})
$form.FindName('ComponentsInstallAll').Add_Click({RunAction {
 $mp=ManifestPath $store $path.Text;$m=ReadOptiShadeState $mp;$current=@(GetManagerComponentSelection $m)
 foreach($selector in $componentSelectors){if($selector.IsEnabled -and $selector.Tag -notin $current){$script:componentSelections[[string]$selector.Tag]=$true;$selector.IsChecked=$true}}
 $form.FindName('InstallAllFx').IsChecked=$true
 InvokeComponentSelection
} 'Installing all available components'})
$form.FindName('SelectNativeFg').IsEnabled=$false
RefreshAddonCards

# An error that escapes a window callback (outside RunAction) used to end the
# manager with a bare "OptiShade could not open: exit status 1" and nothing in
# the log. Log where it came from and keep the window running.
$form.Dispatcher.Add_UnhandledException({param($sender,$e)
 try{
  $record=if($e.Exception -is [Management.Automation.IContainsErrorRecord]){$e.Exception.ErrorRecord}else{$null}
  $where=if($record){$record.InvocationInfo.PositionMessage+' | '+$record.ScriptStackTrace}else{$e.Exception.StackTrace}
  WriteInstallerLog ('Unexpected launcher error (the launcher kept running): '+$e.Exception.GetBaseException().Message+' | '+$where)
  $status.Text='Something went wrong in the launcher; it was logged. Export launcher diagnostics from Troubleshooting if it happens again.';$status.Foreground='#FFBE83'
 }catch{}
 $e.Handled=$true
})
# Show, then keep the dispatcher running until the window is really closed. With
# ShowDialog, hiding the window to the system tray ended the dialog and the app.
$script:mainWindowFrame=[Windows.Threading.DispatcherFrame]::new()
$form.Add_Closed({$script:mainWindowFrame.Continue=$false})
if($script:trayEnabled -and $StartInTray){
 # Started with Windows: load invisibly (start-up checks still run), then hide to the tray.
 $form.ShowActivated=$false;$form.ShowInTaskbar=$false;$form.WindowState='Minimized'
 $form.Add_Loaded({$form.Hide();$form.WindowState='Normal';$form.ShowInTaskbar=$true})
}
$form.Show()
[Windows.Threading.Dispatcher]::PushFrame($script:mainWindowFrame)
}finally{
 # A failed ShowDialog can leave a native window or a queued startup action.
 # Close while the runspace is still valid, then detach every timer/worker.
 try{if($script:startupDisplayOperation -and $script:startupDisplayOperation.Status -eq 'Pending'){[void]$script:startupDisplayOperation.Abort()}}catch{}
 try{if($form -and $form.IsVisible){$script:busy=$false;$form.Close()}}catch{}
 StopOptiShadeManagerStatus $script:managerStatusState
 StopOptiShadeManagerLifetime
 RemoveOptiShadeSessionPayload $script:sessionComposedPayload
 $script:AntiCheatSessionAccepted=$false;$env:OPTISHADE_ANTICHEAT_SESSION_ACCEPTED=$null
}
