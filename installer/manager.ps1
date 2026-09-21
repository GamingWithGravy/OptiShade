param([string]$Payload,[string]$Installer)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/ownership.ps1"
. "$PSScriptRoot/effects.ps1"
. "$PSScriptRoot/nvidia.ps1"
. "$PSScriptRoot/library.ps1"
. "$PSScriptRoot/consent.ps1"
. "$PSScriptRoot/compatibility.ps1"
. "$PSScriptRoot/updates.ps1"
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
Add-Type -TypeDefinition 'public class FusionGameCard { public string Name {get;set;} public string Folder {get;set;} public string Launcher {get;set;} public string State {get;set;} public string InstallFolder {get;set;} public string Label {get;set;} public string Artwork {get;set;} public System.Windows.Media.ImageSource Thumbnail {get;set;} }' -ReferencedAssemblies @([Windows.Media.ImageSource].Assembly.Location,[Windows.Threading.DispatcherObject].Assembly.Location)
$store=Join-Path $env:LOCALAPPDATA 'OptiShade'
$script:cachePath=Join-Path $store 'msfs24-cache.json'
[xml]$xaml=Get-Content "$PSScriptRoot/manager.xaml" -Raw -Encoding UTF8
$form=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
$path=$form.FindName('GamePath');$status=$form.FindName('Status')
$buttons=@('Browse','Install','Repair','Restore','Runtime','Retry','Uninstall','Scan','Play','LibraryGames','GamePath','Method','AddGame','HomeNav','LibraryNav','SetupNav','SettingsNav','OpenLibrary','CheckCompatibility')|ForEach-Object {$form.FindName($_)}
$form.Icon=[Windows.Media.Imaging.BitmapFrame]::Create([uri](Join-Path $PSScriptRoot 'OptiShade-app.ico'))
$form.FindName('BrandIcon').Source=[Windows.Media.Imaging.BitmapFrame]::Create([uri](Join-Path $PSScriptRoot 'OptiShade-icon.png'))
$form.FindName('TitleBar').Add_MouseLeftButtonDown({if($_.ChangedButton -eq 'Left'){$form.DragMove()}})
$form.FindName('Close').Add_Click({if(-not $script:busy){$form.Close()}})
$form.FindName('Minimize').Add_Click({$form.WindowState='Minimized'})
$script:busy=$false
$form.FindName('UpdateAvailable').Add_Click({
 if($script:busy -or -not $script:availableUpdate){return}
 if(Get-Process FlightSimulator2024 -ErrorAction SilentlyContinue){$status.Text='Close Microsoft Flight Simulator 2024 before updating.';return}
 $updateDir=Join-Path $store ('Updates/'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $updateDir -Force|Out-Null
 $worker=Join-Path $updateDir 'update-worker.ps1';Copy-Item -LiteralPath "$PSScriptRoot/update-worker.ps1" -Destination $worker
 $config=Join-Path $updateDir 'update.json';$script:availableUpdate|Add-Member -NotePropertyName Installer -NotePropertyValue $Installer -Force
 $script:availableUpdate|ConvertTo-Json|Set-Content -LiteralPath $config -Encoding UTF8
 Start-Process -FilePath "$env:SystemRoot/System32/WindowsPowerShell/v1.0/powershell.exe" -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"'+$worker+'"'),'-Config',('"'+$config+'"')) -WindowStyle Hidden
 $form.Close()
})
function RunAction([scriptblock]$action){
 if($script:startupResult -and -not $script:startupResult.IsCompleted){$status.Text='Finishing the hardware check. Please try again in a moment.';return}
 if($script:busy){return};$script:busy=$true
 foreach($control in $buttons){if($control){$control.IsEnabled=$false}}
 try{& $action;$status.Foreground='#BDA0F4'}catch{$status.Text=$_.Exception.Message;$status.Foreground='#FFBE83';WriteInstallerLog $_.Exception.Message}
 finally{$form.FindName('InstallProgress').IsIndeterminate=$false;$form.FindName('InstallProgress').Visibility='Collapsed';if(-not $script:uninstallDone){RefreshLibrary};$script:busy=$false;foreach($control in $buttons){if($control){$control.IsEnabled=$true}}}
}

$form.Add_Closing({param($sender,$e) if($script:busy){$e.Cancel=$true}})
$progress={param($text,[int]$completed=0,[int]$total=0)
 $status.Text=$text;$bar=$form.FindName('InstallProgress');$bar.Visibility='Visible'
 $bar.IsIndeterminate=($total -le 0)
 if($total -gt 0){$bar.Maximum=$total;$bar.Value=[Math]::Min($completed,$total)}
 $form.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)
}
$form.FindName('Browse').Add_Click({$d=New-Object Windows.Forms.FolderBrowserDialog;if($d.ShowDialog() -eq 'OK'){$path.Text=$d.SelectedPath};$d.Dispose()})
$form.FindName('Install').Add_Click({RunAction {
 $exe=ChooseGameExe; if(-not $exe){return}; AssertFusionExecutable $exe
 AssertMsfsNvidiaTarget $exe (GetFusionGpu)
 $proxy=[string]$form.FindName('Method').SelectedItem.Tag
 $plan=CheckGameCompatibility $exe
 if($proxy -eq 'auto'){$proxy=$plan.Proxy}
 $optionalDlss=ConfirmOptionalDlss $form $plan.DownloadNvidia
 if($null -eq $optionalDlss){return}
 if(-not $plan.PossibleInput){if([Windows.MessageBox]::Show($form,(FormatFusionCompatibility $plan)+"`n`nContinue with image effects?",'Image effects only','YesNo','Information','No') -ne 'Yes'){return}}
 $replace=@(FindFusionConflicts $path.Text)
 $existing=Test-Path -LiteralPath (ManifestPath $store $path.Text)
 $existing=$existing -or (Test-Path -LiteralPath (Join-Path $path.Text 'OptiShadeData'))
 if($replace.Count -or $existing){
  $message="Files already in this game folder:`n"+(($replace|ForEach-Object { $_.Path+' - '+$(if($_.Recognised){$_.Description}else{'Unidentified loader; may belong to the game or another tool'}) }) -join "`n")+"`n`nBack up and replace this setup with OptiShade? Conflicting add-ons will be disabled. Restore will put these exact files back. Existing shader folders and presets are kept. Unidentified loaders may be needed by the game; choose No if unsure."
  $message="ReShade / OptiShade files detected. Would you like to back up and replace conflicting files, then install OptiShade? Saved INI files are kept.`n`n"+$message
  if([Windows.MessageBox]::Show($form,$message,'Reinstall or replace graphics mods','YesNo','Question','No') -ne 'Yes'){return}
 }
 $script:manifest=InstallFusion $path.Text $Payload $store $Installer $proxy $replace -ReplaceExisting $existing
 $m=Get-Content $script:manifest -Raw|ConvertFrom-Json;$m|Add-Member -NotePropertyName LaunchExe -NotePropertyValue $exe -Force;$m|Add-Member -NotePropertyName Downloads -NotePropertyValue 'Pending' -Force;$m|Add-Member -NotePropertyName OptionalDlss -NotePropertyValue ([bool]$optionalDlss) -Force;WriteState $m $script:manifest
 SaveFusionCompatibility $path.Text $plan
 FinishOptionalDownloads $m $plan
}})
$form.FindName('Restore').Add_Click({RunAction {$m=ManifestPath $store $path.Text;if(-not(Test-Path $m)){throw 'No recorded installation for this game.'};RestoreFusion $m;$status.Text='Game restored. Original files are back and OptiShade game files are removed.'}})
$form.FindName('Runtime').Add_Click({RunAction {$m=ManifestPath $store $path.Text;if(-not(Test-Path $m)){throw 'Install OptiShade first.'};$installed=Get-Content $m -Raw|ConvertFrom-Json;$plan=CheckGameCompatibility $installed.LaunchExe;if(-not $plan.DownloadNvidia){throw $plan.NeuralRendering};$d=New-Object Windows.Forms.OpenFileDialog;$d.Filter='NVIDIA NR runtime|nvngx_dlssnr.dll';if($d.ShowDialog() -eq 'OK'){ImportNrRuntime $m $d.FileName;$installed|Add-Member -NotePropertyName OptionalDlss -NotePropertyValue $true -Force;$latest=Get-Content $m -Raw|ConvertFrom-Json;$latest|Add-Member -NotePropertyName OptionalDlss -NotePropertyValue $true -Force;WriteState $latest $m;$status.Text='Model file added. It is not running yet: a supported game connection is still required.'};$d.Dispose()}})
$form.FindName('Uninstall').Add_Click({RunAction {$choice=[Windows.MessageBox]::Show($form,'Would you like to keep your saved INI files? Yes keeps presets in each game folder for later. No removes them with OptiShade.','Keep saved presets?','YesNoCancel','Question','Yes');if($choice -eq 'Cancel'){return};UninstallFusion $store $Installer $PSScriptRoot -KeepPresets ($choice -eq 'Yes');$script:uninstallDone=$true;$status.Text='OptiShade removed. Closing setup; your original installer EXE is kept.';$script:busy=$false;$form.Close()}})
$form.FindName('Retry').Add_Click({RunAction {$m=Get-Content (ManifestPath $store $path.Text) -Raw|ConvertFrom-Json;if($m.Status -ne 'Installed'){throw 'Install OptiShade first.'};AssertClosed $path.Text;$plan=CheckGameCompatibility $m.LaunchExe;SaveFusionCompatibility $path.Text $plan;FinishOptionalDownloads $m $plan}})
$form.FindName('Repair').Add_Click({RunAction {
 $mp=ManifestPath $store $path.Text
 if(-not(Test-Path -LiteralPath $mp)){throw 'No installation record. Use Install to back up and replace detected files.'}
 $previous=Get-Content -LiteralPath $mp -Raw|ConvertFrom-Json
 if($previous.Status -ne 'Installed'){throw 'Use Install OptiShade to install first.'}
 if([Windows.MessageBox]::Show($form,'Repair OptiShade from this installer? Core files and default configuration will be replaced. Your saved INI presets are kept. Original pre-install backups are preserved.','Repair OptiShade','YesNo','Question','No') -ne 'Yes'){return}
 $proxy=@($previous.Files|Where-Object SourcePath -eq 'winmm.dll'|Select-Object -First 1).Path
 if(-not $proxy){throw 'The recorded loader is unknown. Repair was stopped.'}
 $mp=InstallFusion $path.Text $Payload $store $Installer $proxy @(FindFusionConflicts $path.Text) -ReplaceExisting $true
 $repaired=Get-Content -LiteralPath $mp -Raw|ConvertFrom-Json
 foreach($key in @('LaunchExe','Downloads','OptionalDlss')){if($previous.PSObject.Properties[$key]){$repaired|Add-Member -NotePropertyName $key -NotePropertyValue $previous.$key -Force}}
 WriteState $repaired $mp
 $status.Text='OptiShade repaired from the installer. Saved looks and original backups are kept. You can close the installer and start your game.'
}})
function WriteInstallerLog([string]$Message){try{New-Item -ItemType Directory -Path $store -Force|Out-Null;((Get-Date -Format o)+' '+$Message)|Add-Content -LiteralPath (Join-Path $store 'Installer.log') -Encoding UTF8}catch{}}
function FinishOptionalDownloads($Manifest,$Plan){
 $issues=New-Object 'System.Collections.Generic.List[string]'
 if(UseOptionalDlss $Manifest $Plan){try{$nr=FindNrRuntime $Installer;if($nr){ImportNrRuntime (ManifestPath $store $path.Text) $nr};InstallNvidia $path.Text $progress}catch{$issues.Add('NVIDIA files: '+$_.Exception.Message)}}
 try{$null=InstallAllEffects $path.Text (Join-Path $PSScriptRoot 'EffectPackages.ini') $progress}catch{$issues.Add('Additional FX: '+$_.Exception.Message)}
 if($issues.Count){
  $mp=ManifestPath $store $path.Text;$m=Get-Content -LiteralPath $mp -Raw|ConvertFrom-Json
  $m|Add-Member -NotePropertyName Downloads -NotePropertyValue 'Pending' -Force;WriteState $m $mp
  foreach($issue in $issues){WriteInstallerLog $issue}
  $status.Text='OptiShade is installed. Some optional downloads are unfinished; installed effects can still be used. Choose Retry unfinished downloads. Details: %LOCALAPPDATA%\OptiShade\Installer.log'
 }else{CompleteDownloads}
 WriteInstallerLog $status.Text
}

function CheckGameCompatibility([string]$exe){
 $script:gpu=GetFusionGpu
 AssertMsfsNvidiaTarget $exe $script:gpu
 $root=$path.Text
 if($script:gameRoot -and $root.StartsWith($script:gameRoot+'\',[StringComparison]::OrdinalIgnoreCase)){$root=$script:gameRoot}
 $plan=GetFusionCompatibility $root $exe $script:gpu $script:gameLauncher
 $installed=@(GetFusionInstalledVersions $path.Text)
 $plan|Add-Member -NotePropertyName InstalledRuntimes -NotePropertyValue $installed
 $form.FindName('Compatibility').Text=FormatFusionCompatibility $plan
 foreach($runtime in $installed){$form.FindName('Compatibility').Text+="`nStored: $($runtime.File) - $($runtime.Version) (not proof it is running)"}
 return $plan
}
$form.FindName('CheckCompatibility').Add_Click({RunAction {$exe=ChooseGameExe;if($exe){$plan=CheckGameCompatibility $exe;$status.Text='Check complete. Found files are clues, not confirmation a feature works in game.'}}})
$path.Add_TextChanged({$form.FindName('Compatibility').Text='Check this game before installing. Automatic setup also checks again at install time.'})
function CompleteDownloads{$mp=ManifestPath $store $path.Text;$m=Get-Content $mp -Raw|ConvertFrom-Json;$m|Add-Member -NotePropertyName Downloads -NotePropertyValue 'Complete' -Force;WriteState $m $mp;$status.Text='Install complete. You can close the installer and start your game.'}
function ShowPage([string]$name){
 if($name -eq 'Library'){$name='Setup'}
 foreach($page in @('Home','Library','Setup','Settings')){$form.FindName($page+'Page').Visibility=if($page -eq $name){'Visible'}else{'Collapsed'}}
}
function ShowGames($games){
 $cards=New-Object Collections.Generic.List[FusionGameCard]
 foreach($game in $games){
  $image=$form.Icon
  if($game.Artwork){try{$bytes=[Convert]::FromBase64String($game.Artwork);$memory=New-Object IO.MemoryStream(,$bytes);$image=New-Object Windows.Media.Imaging.BitmapImage;$image.BeginInit();$image.CacheOption='OnLoad';$image.StreamSource=$memory;$image.EndInit();$image.Freeze();$memory.Dispose()}catch{$image=$form.Icon}}
  $card=New-Object FusionGameCard;$card.Name=$game.Name;$card.Folder=$game.Folder;$card.Launcher=$game.Launcher;$card.InstallFolder=$game.InstallFolder;$card.State='OptiShade '+$game.State;$card.Label=$game.Label;$card.Artwork=$game.Artwork;$card.Thumbnail=$image;$cards.Add($card)
 }
 $script:libraryGames=$cards;$form.FindName('LibraryGames').ItemsSource=$cards
}
function RefreshLibrary{
 $selector=$form.FindName('MsfsCopies');$items=@($selector.ItemsSource)
 foreach($game in $items){
  $installPath=if($game.InstallFolder){$game.InstallFolder}else{$game.Folder}
  $state=GetFusionInstallState $store $installPath
  $game.State=$state;$game.Label="$($game.Launcher) - OptiShade $state"
 }
 $selector.Items.Refresh()
}
function SelectGame($game){
 $script:gameRoot=$game.Folder;$script:gameLauncher=$game.Launcher;$path.Text=if($game.InstallFolder){$game.InstallFolder}else{$game.Folder}
 $form.FindName('SelectedTitle').Text=$game.Name;$form.FindName('SelectedIcon').Source=$game.Thumbnail
 $status.Text=$game.Label;ShowPage 'Setup'
}
$form.FindName('Help').Add_Click({
 [xml]$markup=@"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="Optishade guides" Width="760" Height="650" WindowStartupLocation="CenterOwner" Background="#17121F" Foreground="#F3EFFB" FontFamily="Segoe UI"><DockPanel Margin="24"><ComboBox Name="Guide" DockPanel.Dock="Top" Margin="0,0,0,16"/><TextBox Name="Reading" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Background="#100E17" Foreground="#EAE1F6" BorderThickness="0" Padding="18" FontSize="14"/></DockPanel></Window>
"@
 $helpWindow=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup));$helpWindow.Owner=$form;$helpWindow.Icon=$form.Icon
 $guide=$helpWindow.FindName('Guide');$guide.Style=$form.FindResource([Windows.Controls.ComboBox]);$guide.ItemsSource=@('Tutorial','How it works','Features')
 $guide.Add_SelectionChanged({$file=@('Tutorial.txt','How-it-works.txt','Features.txt')[$guide.SelectedIndex];$helpWindow.FindName('Reading').Text=Get-Content -LiteralPath (Join-Path $PSScriptRoot ('Help/'+$file)) -Raw -Encoding UTF8})
 $guide.SelectedIndex=0;[void]$helpWindow.ShowDialog()
})
$form.FindName('HomeNav').Add_Click({ShowPage 'Home'})
$form.FindName('GitHub').Add_Click({Start-Process 'https://github.com/GamingWithGravy/OptiShade_V0.19.17/releases/latest'})
$form.FindName('LibraryNav').Add_Click({ShowPage 'Library'})
$form.FindName('OpenLibrary').Add_Click({ShowPage 'Library'})
$form.FindName('SettingsNav').Add_Click({ShowPage 'Settings'})
$form.FindName('SetupNav').Add_Click({ShowPage 'Setup'})
$form.FindName('AddGame').Add_Click({$path.Text='';$script:gameRoot='';$script:gameLauncher='';$form.FindName('SelectedTitle').Text='Add a game';$form.FindName('SelectedIcon').Source=$form.Icon;ShowPage 'Setup'})
$form.FindName('LibraryGames').AddHandler([Windows.Controls.Button]::ClickEvent,[Windows.RoutedEventHandler]{param($sender,$e)
 try{$source=$e.OriginalSource;while($source -and -not($source -is [Windows.Controls.Button])){$source=[Windows.Media.VisualTreeHelper]::GetParent($source)};if($source -and $source.DataContext){SelectGame $source.DataContext}}catch{$status.Text=$_.Exception.Message}
},$true)
function ChooseGameExe{
 $launcher=if($script:gameRoot -and (($path.Text -eq $script:gameRoot) -or $path.Text.StartsWith($script:gameRoot+'\',[StringComparison]::OrdinalIgnoreCase))){$script:gameLauncher}else{''};$files=@(FindFusionExecutable $path.Text $launcher)
 if($files.Count -eq 1 -or ($files.Count -gt 1 -and $files[0].Score -gt $files[1].Score)){$path.Text=Split-Path $files[0].Path;return $files[0].Path}
 $dialog=New-Object Windows.Forms.OpenFileDialog;$dialog.Filter='Game executable|*.exe';$dialog.Title='Choose the actual game EXE';$dialog.InitialDirectory=$path.Text;if($files.Count){$dialog.InitialDirectory=Split-Path $files[0].Path;$dialog.FileName=$files[0].Path}
 try{if($dialog.ShowDialog() -eq 'OK'){$path.Text=Split-Path $dialog.FileName;return $dialog.FileName}}finally{$dialog.Dispose()}
 return $null
}
$form.FindName('Scan').Add_Click({RunAction {
 $status.Text='Refreshing your game library...';$form.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)
 $found=@(GetFusionGameArtwork @(FindFusionGames $store));ShowGames $found
 if($script:cachedSystem){$script:cachedSystem.Games=$found;SaveStartupCache $script:cachedSystem}
 $status.Text='Library refreshed. Use Add a game for anything the scan missed.'
}})
$form.FindName('Play').Add_Click({RunAction {
 $mp=ManifestPath $store $path.Text;$exe=$null
 if(Test-Path -LiteralPath $mp){$m=Get-Content $mp -Raw|ConvertFrom-Json;$exe=$m.LaunchExe}
 if(-not $exe -or -not(Test-Path -LiteralPath $exe)){$exe=ChooseGameExe}
 if($exe){AssertFusionExecutable $exe;Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe);$status.Text='Launch requested. If the game needs its launcher, open it there. Restore after closing the game.'}
}})
# Hardware and launcher discovery run in another runspace so the intro remains skippable.
$script:gpu=[pscustomobject]@{Names='Checking';Nvidia=$false;Known=$false}
$script:startup=[PowerShell]::Create()
function SaveStartupCache($data){
 New-Item -ItemType Directory -Path $store -Force|Out-Null
 $data|ConvertTo-Json -Depth 7|Set-Content -LiteralPath ($script:cachePath+'.tmp') -Encoding UTF8
 Move-Item -LiteralPath ($script:cachePath+'.tmp') -Destination $script:cachePath -Force
}
[void]$script:startup.AddScript({param($lib,$store,$cache)
 . $lib
 $gpu=GetFusionGpu;$ram=(Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).TotalPhysicalMemory;$os=(Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
 . (Join-Path (Split-Path $lib) 'updates.ps1')
 [pscustomobject]@{Version=1;Gpu=$gpu;Ram=[math]::Round($ram/1GB);OS=$os;Games=@(GetFusionGameArtwork @(FindFusionGames $store));Update=(GetOptiShadeUpdate)}
}).AddArgument("$PSScriptRoot/library.ps1").AddArgument($store).AddArgument($script:cachePath)
$script:startupResult=$script:startup.BeginInvoke()
$script:introStart=Get-Date
$script:startupTimer=New-Object Windows.Threading.DispatcherTimer
$script:startupTimer.Interval=[TimeSpan]::FromMilliseconds(150)

$script:startupTimer.Add_Tick({
 $elapsed=((Get-Date)-$script:introStart).TotalSeconds
 if($elapsed -ge 10){$form.FindName('Intro').Visibility='Collapsed'}
 if($script:startupResult -and $script:startupResult.IsCompleted -and $elapsed -ge 6){
  try{
   $result=@($script:startup.EndInvoke($script:startupResult))[-1];$script:gpu=$result.Gpu;$script:cachedSystem=$result;SaveStartupCache $result
   $advice=if($script:gpu.Nvidia){'Start with image effects or DLSS upscaling where the game supports it. Neural rendering needs the matching RTX hardware and runtime.'}else{'NVIDIA graphics card not detected. Installation is unavailable. Restore and uninstall remain available.'}
   $form.FindName('Hardware').Text="$($script:gpu.Names) | $($result.Ram) GB RAM | $($result.OS)`n$advice"
   $form.FindName('IntroStatus').Text='Your setup is ready.'
   $form.FindName('IntroProgress').IsIndeterminate=$false;$form.FindName('IntroProgress').Value=100
   $copies=@($result.Games)
   if($result.Update){$script:availableUpdate=$result.Update;$form.FindName('UpdateAvailable').Content='Update available - '+$result.Update.Version;$form.FindName('UpdateAvailable').Visibility='Visible'}
   $form.FindName('MsfsCopies').ItemsSource=$copies
   if($copies.Count){$form.FindName('MsfsCopies').SelectedIndex=0}else{$path.Text=''}
   $status.Text='Microsoft Flight Simulator 2024 detection complete. Open Setup to install, play or restore.'
  }catch{$form.FindName('Hardware').Text='Hardware detection was unavailable. Choose settings in game after checking your graphics card.'}
  finally{$script:startup.Dispose();$script:startupResult=$null;$script:startupTimer.Stop();$form.FindName('Intro').Visibility='Collapsed'}
 }
})
$form.FindName('MsfsCopies').Add_SelectionChanged({$copy=$form.FindName('MsfsCopies').SelectedItem;if($copy){$script:gameRoot=$copy.Folder;$script:gameLauncher=$copy.Launcher;$path.Text=if($copy.InstallFolder){$copy.InstallFolder}else{$copy.Folder};$form.FindName('SelectedTitle').Text='Microsoft Flight Simulator 2024'}})
ShowPage 'Home'
$form.Add_ContentRendered({$script:introStart=Get-Date;$form.FindName('IntroStatus').Text=if(Test-Path -LiteralPath $script:cachePath){'Loading your saved setup...'}else{'Checking NVIDIA hardware and finding Microsoft Flight Simulator 2024...'};$status.Text=$form.FindName('IntroStatus').Text;$script:startupTimer.Start()})
$form.Add_Closed({$script:startupTimer.Stop();if($script:startupResult){$script:startup.BeginStop($null,$null)|Out-Null}})
[void]$form.ShowDialog()


