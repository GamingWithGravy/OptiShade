param([string]$Payload,[string]$Installer)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/ownership.ps1"
. "$PSScriptRoot/effects.ps1"
. "$PSScriptRoot/nvidia.ps1"
. "$PSScriptRoot/neural-download.ps1"
. "$PSScriptRoot/library.ps1"
. "$PSScriptRoot/consent.ps1"
. "$PSScriptRoot/compatibility.ps1"
. "$PSScriptRoot/updates.ps1"
. "$PSScriptRoot/recovery.ps1"
. "$PSScriptRoot/menu-settings.ps1"
. "$PSScriptRoot/diagnostics.ps1"
. "$PSScriptRoot/release-notes.ps1"
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
Add-Type -TypeDefinition 'public class FusionGameCard { public string Name {get;set;} public string Folder {get;set;} public string Launcher {get;set;} public string State {get;set;} public string InstallFolder {get;set;} public string Label {get;set;} public string Artwork {get;set;} public System.Windows.Media.ImageSource Thumbnail {get;set;} }' -ReferencedAssemblies @([Windows.Media.ImageSource].Assembly.Location,[Windows.Threading.DispatcherObject].Assembly.Location)
$store=Join-Path $env:LOCALAPPDATA 'OptiShade'
$script:cachePath=Join-Path $store 'msfs-2020-2024-cache.json'
[xml]$xaml=Get-Content "$PSScriptRoot/manager.xaml" -Raw -Encoding UTF8
$form=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
$path=$form.FindName('GamePath');$status=$form.FindName('Status')
$buttons=@('Browse','Install','Repair','Restore','Runtime','Retry','Uninstall','Scan','Play','LibraryGames','GamePath','Method','AddGame','HomeNav','LibraryNav','SetupNav','SettingsNav','KeybindsNav','ChangeMenuKey','ChangeHotSwapKey','ClearHotSwapKey','OpenLibrary','CheckCompatibility','TroubleshootingNav','ResetDefaults','ImportZip','RecoveryRepair','RecoveryRestore','CheckUpdates','SaveMenuKeys','DefaultMenuKeys','LoadMenuKeys','IncludeEffects','OwnIniMode','ChooseOwnIni','ApplyFxChoice','PrepareOlderRtx','OpenMsfs2020')|ForEach-Object {$form.FindName($_)}
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
$script:busy=$false
$form.FindName('UpdateAvailable').Add_Click({
 if($script:busy -or -not $script:availableUpdate){return}
 if(Get-Process FlightSimulator2024,FlightSimulator -ErrorAction SilentlyContinue){$status.Text='Close Microsoft Flight Simulator before updating.';return}
 $updateDir=Join-Path $store ('Updates/'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $updateDir -Force|Out-Null
 $worker=Join-Path $updateDir 'update-worker.ps1';Copy-Item -LiteralPath "$PSScriptRoot/update-worker.ps1" -Destination $worker
 Copy-Item -LiteralPath "$PSScriptRoot/dialog-theme.xaml" -Destination (Join-Path $updateDir 'dialog-theme.xaml')
 $config=Join-Path $updateDir 'update.json';$script:availableUpdate|Add-Member -NotePropertyName Installer -NotePropertyValue $Installer -Force
 $script:availableUpdate|ConvertTo-Json|Set-Content -LiteralPath $config -Encoding UTF8
 $hostExe=Join-Path $updateDir 'OptiShade_updater.exe';Copy-Item -LiteralPath "$PSScriptRoot/FusionSetup.exe" -Destination $hostExe
 try{Start-Process -FilePath $hostExe -ArgumentList @('--update-worker',('"'+$config+'"')) -WindowStyle Hidden -Verb RunAs;$form.Close()}
 catch{$status.Text='The updater could not start or administrator access was cancelled. No update was applied. '+$_.Exception.Message}
})
function RunAction([scriptblock]$action){
 if($script:startupResult -and -not $script:startupResult.IsCompleted){$status.Text='Finishing the hardware check. Please try again in a moment.';return}
 if($script:busy){return};$script:busy=$true
 foreach($control in $buttons){if($control){$control.IsEnabled=$false}}
 try{if($path.Text){$path.Text=ResolveFusionInstallFolder $path.Text};& $action;$status.Foreground='#BDA0F4'}catch{$status.Text=$_.Exception.Message;$status.Foreground='#FFBE83';WriteInstallerLog $_.Exception.Message}
 finally{$form.FindName('InstallProgress').IsIndeterminate=$false;$form.FindName('InstallProgress').Visibility='Collapsed';$script:busy=$false;foreach($control in $buttons){if($control){$control.IsEnabled=$true}};if(-not $script:uninstallDone){RefreshLibrary}}
}

$form.Add_Closing({param($sender,$e) if($script:busy){$e.Cancel=$true}})
$progress={param($text,[int]$completed=0,[int]$total=0)
 $status.Text=$text;$bar=$form.FindName('InstallProgress');$bar.Visibility='Visible'
 $bar.IsIndeterminate=($total -le 0)
 if($total -gt 0){$bar.Maximum=$total;$bar.Value=[Math]::Min($completed,$total)}
 $form.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)
}
$form.FindName('Browse').Add_Click({$d=New-Object Windows.Forms.FolderBrowserDialog;if($d.ShowDialog() -eq 'OK'){$path.Text=$d.SelectedPath};$d.Dispose()})
$script:ownIni=''
$form.FindName('OwnIniMode').Add_Checked({$form.FindName('OwnIniPicker').Visibility='Visible'})
$form.FindName('IncludeEffects').Add_Checked({$form.FindName('OwnIniPicker').Visibility='Collapsed'})
$form.FindName('ChooseOwnIni').Add_Click({$d=New-Object Windows.Forms.OpenFileDialog;$d.Filter='ReShade look preset (*.ini)|*.ini';try{if($d.ShowDialog() -eq 'OK'){$script:ownIni=$d.FileName;$form.FindName('OwnIniName').Text=[IO.Path]::GetFileName($d.FileName)}}finally{$d.Dispose()}})
$form.FindName('ApplyFxChoice').Add_Click({RunAction {
 AssertClosed $path.Text;$mp=ManifestPath $store $path.Text;$m=Get-Content -LiteralPath $mp -Raw|ConvertFrom-Json
 if($m.Status -ne 'Installed'){throw 'Complete the OptiShade installation first.'}
 $relative='';if($form.FindName('OwnIniMode').IsChecked){$relative=SaveOwnPreset $script:ownIni $path.Text (Join-Path $PSScriptRoot 'EffectPackages.ini')}
 $m|Add-Member -NotePropertyName IncludeEffects -NotePropertyValue ([bool]$form.FindName('IncludeEffects').IsChecked) -Force
 $m|Add-Member -NotePropertyName FxPresetRelative -NotePropertyValue $relative -Force;WriteState $m $mp
 FinishOptionalDownloads $m (CheckGameCompatibility $m.LaunchExe)
}})
$form.FindName('Install').Add_Click({RunAction {
 if((GetFusionInstallState $store $path.Text) -match '^Installed|^Installation incomplete'){$status.Text='OptiShade is already installed. Use Repair, Restore or Troubleshooting to manage it.';return}
 if($form.FindName('OwnIniMode').IsChecked){TestOwnPreset $script:ownIni $path.Text (Join-Path $PSScriptRoot 'EffectPackages.ini')}
 $exe=ChooseGameExe; if(-not $exe){return}; AssertFusionExecutable $exe
 AssertMsfsNvidiaTarget $exe (GetFusionGpu)
 if((GetMsfsTitle $path.Text) -match '2020'){if([Windows.MessageBox]::Show($form,'Use DirectX 12 and DLSS in MSFS 2020. Start with Neural Rendering and frame generation off, then configure them in game. Install into this selected MSFS 2020 folder?','MSFS 2020 installation','YesNo','Question','No') -ne 'Yes'){return}}
 $proxy=[string]$form.FindName('Method').SelectedItem.Tag
 $plan=CheckGameCompatibility $exe
 if(-not(ConfirmNvidiaDriver $form $script:gpu)){$status.Text='Installation cancelled. Update your NVIDIA driver, then run setup again.';return}
 if($proxy -eq 'auto'){$proxy=$plan.Proxy}
 if(ShouldWarnAmdExperimental $script:gpu){if(-not(ConfirmAmdExperimental $form)){return}}
 $optionalDlss=if($plan.DownloadNvidia){ConfirmOptionalDlss $form $true}else{$false}
 if($null -eq $optionalDlss){return}
 if(-not $plan.PossibleInput){if([Windows.MessageBox]::Show($form,(FormatFusionCompatibility $plan)+"`n`nContinue with image effects?",'Image effects only','YesNo','Information','No') -ne 'Yes'){return}}
 $replace=@(FindFusionConflicts $path.Text)
 $existing=Test-Path -LiteralPath (ManifestPath $store $path.Text)
 $existing=$existing -or (Test-Path -LiteralPath (Join-Path $path.Text 'OptiShadeData'))
 if($replace.Count -or $existing){
  $message="Files already in this game folder:`n"+(($replace|ForEach-Object { $_.Path+' - '+$(if($_.Recognised){$_.Description}else{'Unidentified loader; may belong to the game or another tool'}) }) -join "`n")+"`n`nReplace this setup with OptiShade? Conflicting loaders will be removed from the game folder. Existing graphics loaders are backed up before replacement and restored by Restore. Avoid replacing an intentionally working mod setup. Existing shader folders and presets are kept. Unidentified loaders may be needed by the game; choose No if unsure."
  $message="ReShade / OptiShade files detected. Remove conflicting files from the game folder, then install OptiShade? Replaced files will be included in the restore backup. Saved INI files are kept.`n`n"+$message
  if([Windows.MessageBox]::Show($form,$message,'Reinstall or replace graphics mods','YesNo','Question','No') -ne 'Yes'){return}
 }
 $script:manifest=InstallFusion $path.Text $Payload $store $Installer $proxy $replace -ReplaceExisting $existing -IncludeEffects ([bool]$form.FindName('IncludeEffects').IsChecked)
 $m=Get-Content $script:manifest -Raw|ConvertFrom-Json;$m|Add-Member -NotePropertyName LaunchExe -NotePropertyValue $exe -Force;$m|Add-Member -NotePropertyName Downloads -NotePropertyValue 'Pending' -Force;$m|Add-Member -NotePropertyName OptionalDlss -NotePropertyValue ([bool]$optionalDlss) -Force;WriteState $m $script:manifest
 SaveFusionCompatibility $path.Text $plan
 if($form.FindName('OwnIniMode').IsChecked){$relative=SaveOwnPreset $script:ownIni $path.Text (Join-Path $PSScriptRoot 'EffectPackages.ini');$m|Add-Member -NotePropertyName FxPresetRelative -NotePropertyValue $relative -Force;WriteState $m $script:manifest}
 FinishOptionalDownloads $m $plan
}})
$form.FindName('Restore').Add_Click({RunAction {$m=ManifestPath $store $path.Text;if(-not(Test-Path $m)){throw 'No recorded installation for this game.'};RestoreFusion $m;$status.Text='Game restored. Original files are back and OptiShade game files are removed.'}})
$form.FindName('PrepareOlderRtx').Add_Click({RunAction {
 $m=ManifestPath $store $path.Text
 if(-not(Test-Path -LiteralPath $m)){throw 'Install OptiShade in this game first.'}
 $gpu=GetFusionGpu;$selection=GetNeuralDownload $gpu
 if($selection.Family -notmatch '20/30/40'){throw 'This test is for a single detected RTX 20, 30 or 40 GPU. RTX 50 uses its existing runtime.'}
 if([Windows.MessageBox]::Show($form,'Prepare the hash-verified community compatibility model (not NVIDIA-signed) for older RTX hardware? This is experimental and may fail initialization or run too slowly. It is not native RTX 50 support. The test uses one pass and keeps Neural Rendering off at startup. Other picture settings are kept.','Older RTX compatibility test','YesNo','Question','No') -ne 'Yes'){return}
 $record=Get-Content -LiteralPath $m -Raw|ConvertFrom-Json
 $downloadsBefore=$record.Downloads
 if($record.Status -ne 'Installed'){throw 'Complete or repair this installation before preparing the test.'}
 AssertClosed $path.Text
 $record|Add-Member -NotePropertyName OptionalDlss -NotePropertyValue $true -Force
 $record|Add-Member -NotePropertyName Downloads -NotePropertyValue 'Pending' -Force;WriteState $record $m
 EnsureNeuralRuntime $m $gpu $progress
 InstallNvidia $path.Text $progress
 SetOlderRtxTestSettings $path.Text
 $record=Get-Content -LiteralPath $m -Raw|ConvertFrom-Json
 $record|Add-Member -NotePropertyName OptionalDlss -NotePropertyValue $true -Force;WriteState $record $m
 if($downloadsBefore -eq 'Complete'){$record|Add-Member -NotePropertyName Downloads -NotePropertyValue 'Complete' -Force;WriteState $record $m}
 $status.Text='Older RTX model prepared. Use Retry unfinished downloads if other optional packages remain pending. Start DX12 with DLSS, enter a flight, then enable Neural Rendering manually. If it fails, leave it off and export diagnostics. No native older-RTX support is claimed.'
}})
$form.FindName('Runtime').Add_Click({RunAction {$m=ManifestPath $store $path.Text;if(-not(Test-Path $m)){throw 'Install OptiShade first.'};$installed=Get-Content $m -Raw|ConvertFrom-Json;$plan=CheckGameCompatibility $installed.LaunchExe;if(-not $plan.DownloadNvidia){throw $plan.NeuralRendering};$d=New-Object Windows.Forms.OpenFileDialog;$d.Title='Choose '+$plan.NeuralRuntime.Expected;$d.Filter='NVIDIA NR model (not the helper)|nvngx_dlssnr.dll';if($d.ShowDialog() -eq 'OK'){ImportNrRuntime $m $d.FileName;$installed|Add-Member -NotePropertyName OptionalDlss -NotePropertyValue $true -Force;$latest=Get-Content $m -Raw|ConvertFrom-Json;$latest|Add-Member -NotePropertyName OptionalDlss -NotePropertyValue $true -Force;WriteState $latest $m;$status.Text='Model file added. It is not running yet: a supported game connection is still required.'};$d.Dispose()}})
$form.FindName('Uninstall').Add_Click({RunAction {$choice=[Windows.MessageBox]::Show($form,'Would you like to keep your saved INI files? Yes keeps presets in each game folder for later. No removes them with OptiShade.','Keep saved presets?','YesNoCancel','Question','Yes');if($choice -eq 'Cancel'){return};UninstallFusion $store $Installer $PSScriptRoot -KeepPresets ($choice -eq 'Yes');$script:uninstallDone=$true;$status.Text='OptiShade removed. Closing setup; your original installer EXE is kept.';$script:busy=$false;$form.Close()}})
$form.FindName('Retry').Add_Click({RunAction {$m=Get-Content (ManifestPath $store $path.Text) -Raw|ConvertFrom-Json;if($m.Status -ne 'Installed'){throw 'Install OptiShade first.'};AssertClosed $path.Text;$plan=CheckGameCompatibility $m.LaunchExe;SaveFusionCompatibility $path.Text $plan;FinishOptionalDownloads $m $plan}})
$form.FindName('Repair').Add_Click({RunAction {
 $mp=ManifestPath $store $path.Text
 if(-not(Test-Path -LiteralPath $mp)){throw 'No installation record. Use Install to remove conflicting mods and install OptiShade.'}
 $previous=Get-Content -LiteralPath $mp -Raw|ConvertFrom-Json
 if($previous.Status -notin @('Installed','Installing')){throw 'No repairable installation record. Restore the recorded installation first, then install again.'}
 if([Windows.MessageBox]::Show($form,'Repair OptiShade from this installer? Core files will be replaced. Existing configuration and menu keys are kept. Your saved INI presets are kept. Original pre-install backups are preserved.','Repair OptiShade','YesNo','Question','No') -ne 'Yes'){return}
 $proxy=@($previous.Files|Where-Object SourcePath -eq 'winmm.dll'|Select-Object -First 1).Path
 if(-not $proxy){throw 'The recorded loader is unknown. Repair was stopped.'}
 $mp=InstallFusion $path.Text $Payload $store $Installer $proxy @(FindFusionConflicts $path.Text) -ReplaceExisting $true -PreserveConfiguration $true
 $repaired=Get-Content -LiteralPath $mp -Raw|ConvertFrom-Json
 foreach($key in @('LaunchExe','Downloads','OptionalDlss','FxPresetRelative')){if($previous.PSObject.Properties[$key]){$repaired|Add-Member -NotePropertyName $key -NotePropertyValue $previous.$key -Force}}
 WriteState $repaired $mp
 $status.Text='OptiShade repaired from the manager. Saved looks and original backups are kept. You can close the manager and start your game.'
}})
function WriteInstallerLog([string]$Message){try{New-Item -ItemType Directory -Path $store -Force|Out-Null;((Get-Date -Format o)+' '+$Message)|Add-Content -LiteralPath (Join-Path $store 'Installer.log') -Encoding UTF8}catch{}}
function FinishOptionalDownloads($Manifest,$Plan){
 $issues=New-Object 'System.Collections.Generic.List[string]'
 if(UseOptionalDlss $Manifest $Plan){try{EnsureNeuralRuntime (ManifestPath $store $path.Text) (GetFusionGpu) $progress}catch{$issues.Add('Neural model: '+$_.Exception.Message)};try{InstallNvidia $path.Text $progress}catch{$issues.Add('NVIDIA files: '+$_.Exception.Message)}}
 if(-not $Manifest.PSObject.Properties['IncludeEffects'] -or $Manifest.IncludeEffects){try{$null=InstallAllEffects $path.Text (Join-Path $PSScriptRoot 'EffectPackages.ini') $progress}catch{$issues.Add('Additional FX: '+$_.Exception.Message)}}
 elseif($Manifest.PSObject.Properties['FxPresetRelative'] -and $Manifest.FxPresetRelative){try{$progress.Invoke('Installing the selected INI shader dependencies...');InstallPresetDependencies (OwnedPath $path.Text $Manifest.FxPresetRelative) $path.Text (Join-Path $PSScriptRoot 'EffectPackages.ini')}catch{$issues.Add('Preset FX: '+$_.Exception.Message)}}
 if($issues.Count){
  $mp=ManifestPath $store $path.Text;$m=Get-Content -LiteralPath $mp -Raw|ConvertFrom-Json
  $m|Add-Member -NotePropertyName Downloads -NotePropertyValue 'Pending' -Force;WriteState $m $mp
  foreach($issue in $issues){WriteInstallerLog $issue}
  $status.Text='OptiShade is installed. Some optional downloads are unfinished; installed effects can still be used. Choose Retry unfinished downloads. Details: %LOCALAPPDATA%\OptiShade\Installer.log'
 }else{CompleteDownloads;if($Manifest.PSObject.Properties['FxPresetRelative'] -and $Manifest.FxPresetRelative){$status.Text='Preset and required FX installed. Select '+[IO.Path]::GetFileName($Manifest.FxPresetRelative)+' in game under Image effects > Saved look.'}}
 WriteInstallerLog $status.Text
 try{$updated=CheckGameCompatibility $Manifest.LaunchExe;SaveFusionCompatibility $path.Text $updated;if((UseOptionalDlss $Manifest $Plan) -and $updated.NeuralRuntime.State -ne 'Verified file'){$status.Text='OptiShade image effects are installed. Neural rendering is NOT ready: '+$updated.NeuralRuntime.Message+' Choose Retry unfinished downloads to retry the GPU-matched model download.';if($issues.Count){$status.Text+=' Some optional downloads also failed; use Retry unfinished downloads.'}}}catch{WriteInstallerLog ('Post-install diagnostics: '+$_.Exception.Message)}
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
$form.FindName('CheckCompatibility').Add_Click({RunAction {$exe=ChooseGameExe;if($exe){$plan=CheckGameCompatibility $exe;$status.Text='Check complete. Found files are clues, not confirmation a feature works in game.'}}})
$path.Add_TextChanged({$form.FindName('Compatibility').Text='Check this game before installing. Automatic setup also checks again at install time.';RefreshHomeState})
function CompleteDownloads{$mp=ManifestPath $store $path.Text;$m=Get-Content $mp -Raw|ConvertFrom-Json;$m|Add-Member -NotePropertyName Downloads -NotePropertyValue 'Complete' -Force;WriteState $m $mp;$status.Text='Install complete. You can close the manager and start your game.'}
function ShowPage([string]$name){
 if($name -ne 'Keybinds'){$script:capturingHotSwap=$false;$form.FindName('ChangeHotSwapKey').Content='Change'}
 if($name -ne 'Keybinds' -and $script:capturingMenuKey){$script:capturingMenuKey=$false;$form.FindName('ChangeMenuKey').Content='Change'}
 if($name -eq 'Library'){$name='Setup'}
 foreach($page in @('Home','Library','Setup','Keybinds','Settings','Troubleshooting')){$form.FindName($page+'Page').Visibility=if($page -eq $name){'Visible'}else{'Collapsed'}}
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
function RefreshHomeState{
 try{$state=if($path.Text){GetFusionInstallState $store $path.Text}else{'Not installed'}}catch{$state='Invalid path'}
 $installed=$state -match '^Installed';$incomplete=$state -match '^Installation incomplete'
 $install=$form.FindName('Install');$install.Content=if($installed){'Already installed'}elseif($incomplete){'Repair required'}else{'Install OptiShade'}
 $install.IsEnabled=(-not $script:busy -and -not $installed -and -not $incomplete -and $state -ne 'Invalid path' -and -not [string]::IsNullOrWhiteSpace($path.Text))
 $form.FindName('ApplyFxChoice').Visibility=if($installed){'Visible'}else{'Collapsed'}
 $title=GetMsfsTitle $path.Text
 if($title){$form.FindName('SelectedTitle').Text=$title}
 foreach($entry in @(@('2024','HomeInstallState','HomeDetection'),@('2020','Home2020State','Home2020Detection'))){
  $homeState='Not installed'
  $homeCopy=@($form.FindName('MsfsCopies').ItemsSource|Where-Object {$_.Name -match $entry[0]})|Select-Object -First 1
  $detected=($title -match $entry[0]) -or ($null -ne $homeCopy)
  $form.FindName($entry[2]).Text=if($detected){'MSFS '+$entry[0]+' detected'}else{'MSFS '+$entry[0]+' not detected'}
  $form.FindName($entry[2]).Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#C9B6DF')
  if($title -match $entry[0]){$homeState=$state}else{
   if($homeCopy){$homeState=$homeCopy.State}
  }
  $form.FindName($entry[1]).Text=if($homeState -match '^Installed'){'OptiShade installed'}elseif($homeState -match 'incomplete'){'OptiShade needs repair'}else{'Install OptiShade'}
 }

}
function RefreshLibrary{
 $selector=$form.FindName('MsfsCopies');$items=@($selector.ItemsSource)
 foreach($game in $items){
  $installPath=if($game.InstallFolder){$game.InstallFolder}else{$game.Folder}
  $state=GetFusionInstallState $store $installPath
  $game.State=$state;$game.Label="$($game.Name) / $($game.Launcher) - OptiShade $state"
 }
 $selected=$selector.SelectedIndex;$savedPath=$path.Text
 $selector.ItemsSource=$null;$selector.ItemsSource=$items;$selector.SelectedIndex=$selected;$path.Text=$savedPath
 RefreshHomeState
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
$form.FindName('HomeNav').Add_Click({RefreshHomeState;ShowPage 'Home'})
$form.FindName('GitHub').Add_Click({Start-Process 'https://github.com/GamingWithGravy/OptiShade/releases/latest'})
$form.FindName('LibraryNav').Add_Click({ShowPage 'Library'})
function OpenSimulator([bool]$Legacy){
 $wanted=if($Legacy){'2020'}else{'2024'}
 $copy=@($form.FindName('MsfsCopies').ItemsSource|Where-Object {$_.Name -match $wanted})|Select-Object -First 1
 if($copy){$form.FindName('MsfsCopies').SelectedItem=$copy;$path.Text=$copy.InstallFolder}
 else{$form.FindName('MsfsCopies').SelectedIndex=-1;$script:gameRoot='';$script:gameLauncher='';$path.Text=''}
 $form.FindName('SelectedTitle').Text=if($Legacy){'Microsoft Flight Simulator 2020'}else{'Microsoft Flight Simulator 2024'}
 $status.Text=if($Legacy){'MSFS 2020: choose the EXE folder, not Community/Official packages. Use DX12 and DLSS; restart after changing API. Xbox copies need an accessible executable folder; protected WindowsApps installs are not unlocked by this manager.'}else{'Select your MSFS 2024 copy below.'}
 ShowPage 'Setup'
}
$form.FindName('OpenLibrary').Add_Click({OpenSimulator $false})
$form.FindName('OpenMsfs2020').Add_Click({OpenSimulator $true})
$form.FindName('KeybindsNav').Add_Click({RefreshMenuKeys;ShowPage 'Keybinds'})
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
   $form.FindName('Hardware').Text="$($script:gpu.Names) | $($result.Ram) GB RAM | $($result.OS)"
   $form.FindName('IntroStatus').Text='Your setup is ready.'
   $form.FindName('IntroProgress').IsIndeterminate=$false;$form.FindName('IntroProgress').Value=100
   $copies=@($result.Games)
   if($result.Update){$script:availableUpdate=$result.Update;$form.FindName('UpdateAvailable').Content='Update available - '+$result.Update.Version;$form.FindName('UpdateAvailable').Visibility='Visible'}
   $form.FindName('MsfsCopies').ItemsSource=$copies
   if($copies.Count){$form.FindName('MsfsCopies').SelectedIndex=0}else{$path.Text=''}
   $status.Text='Microsoft Flight Simulator detection complete. Open Setup to install, play or restore.'
  }catch{$form.FindName('Hardware').Text='Hardware detection was unavailable. Choose settings in game after checking your graphics card.'}
  finally{$script:startup.Dispose();$script:startupResult=$null;$script:startupTimer.Stop();RefreshHomeState;$form.FindName('Intro').Visibility='Collapsed';ShowReleaseNotes $form $store}
 }
})
$form.FindName('MsfsCopies').Add_SelectionChanged({$copy=$form.FindName('MsfsCopies').SelectedItem;if($copy){$script:gameRoot=$copy.Folder;$script:gameLauncher=$copy.Launcher;$path.Text=if($copy.InstallFolder){$copy.InstallFolder}else{$copy.Folder};$form.FindName('SelectedTitle').Text=$copy.Name;RefreshHomeState}})

$form.FindName('TroubleshootingNav').Add_Click({ShowPage 'Troubleshooting'})
$buttons+=@($form.FindName('ExportSupport'),$form.FindName('ExportDetailedSupport'))
$script:additionalCrashDump=''
$form.FindName('AddCrashDump').Add_Click({
 $pick=New-Object Windows.Forms.OpenFileDialog;$pick.Filter='Crash dumps (*.dmp;*.mdmp)|*.dmp;*.mdmp'
 try{if($pick.ShowDialog() -eq 'OK'){$script:additionalCrashDump=$pick.FileName;$form.FindName('IncludeCrashDumps').IsChecked=$true;$status.Text='Crash dump selected for the next diagnostic ZIP. Its crash details will be extracted into text; the raw dump stays on your PC.'}}finally{$pick.Dispose()}
})
$form.FindName('ExportDetailedSupport').Add_Click({RunAction {
 $dialog=New-Object Windows.Forms.SaveFileDialog;$dialog.Filter='Discord diagnostic ZIP (*.zip)|*.zip|Plain text report (*.txt)|*.txt';$dialog.DefaultExt='zip';$dialog.FileName='OptiShade-diagnostics-'+(Get-Date -Format 'yyyyMMdd-HHmmss')
 try{if($dialog.ShowDialog() -eq 'OK'){
  $format=if($dialog.FilterIndex -eq 2){'txt'}else{'zip'}
  $report=GetDetailedSupportReport $path.Text $store
  $bytes=ExportDiagnosticReport $report $dialog.FileName $format $path.Text ([bool]$form.FindName('IncludeCrashDumps').IsChecked) $script:additionalCrashDump
  $status.Text=('Diagnostics saved locally ({0:N0} KB). Review the report and crash-dump index. Share privately with support: {1}' -f ($bytes/1KB),$dialog.FileName)
 }}finally{$dialog.Dispose()}
}})
$form.FindName('ExportSupport').Add_Click({RunAction {
 $dialog=New-Object Windows.Forms.SaveFileDialog
 $dialog.Filter='Support report (*.json)|*.json';$dialog.FileName='OptiShade-support-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.json'
 try{if($dialog.ShowDialog() -eq 'OK'){
  GetOptiShadeSupportReport $path.Text $store|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $dialog.FileName -Encoding UTF8
  $status.Text='Support report saved. Review it before sharing: '+$dialog.FileName
 }}finally{$dialog.Dispose()}
}})
$form.FindName('RecoveryRepair').Add_Click({$form.FindName('Repair').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))})
$form.FindName('RecoveryRestore').Add_Click({$form.FindName('Restore').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))})
$form.FindName('ResetDefaults').Add_Click({RunAction {
 if([Windows.MessageBox]::Show($form,'Back up and reset OptiShade Performance and image-effect settings? This selects a new empty look. Saved presets and MSFS settings are kept. Close MSFS first.','Reset OptiShade settings','YesNo','Question','No') -ne 'Yes'){return}
 $saved=ResetOptiShadeSettings $path.Text $Payload $store;$status.Text='Defaults restored; effects are off. Previous settings saved at '+$saved
}})
$form.FindName('ImportZip').Add_Click({RunAction {
 AssertClosed $path.Text
 $dialog=New-Object Windows.Forms.OpenFileDialog;$dialog.Filter='FX and INI packages (*.zip)|*.zip'
 try{if($dialog.ShowDialog() -eq 'OK'){$count=ImportEffectsZip $dialog.FileName $path.Text;$status.Text="Imported $count files into OptiShadeData. In game, choose your imported INI under Image effects > Saved look. Required FX must be installed and compile. Your current look is unchanged. ZIPs containing DLLs do not install those DLLs."}}finally{$dialog.Dispose()}
}})
$form.FindName('CheckUpdates').Add_Click({RunAction {
 $status.Text='Checking GitHub releases...';$form.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)
 $script:availableUpdate=GetOptiShadeUpdate -ReportErrors
 if($script:availableUpdate){$form.FindName('UpdateAvailable').Content='Update available - '+$script:availableUpdate.Version;$form.FindName('UpdateAvailable').Visibility='Visible';$status.Text='An update is available. Use the update button to install it.'}
 else{$form.FindName('UpdateAvailable').Visibility='Collapsed';$status.Text='No newer stable release is available.'}
}})

function RefreshMenuKeys {
 $script:capturingHotSwap=$false;$form.FindName('ChangeHotSwapKey').Content='Change'
 $script:capturingMenuKey=$false;$form.FindName('ChangeMenuKey').Content='Change'
 $form.FindName('KeybindsGame').Text=if([string]::IsNullOrWhiteSpace($path.Text)){'Select your installation on Setup.'}else{'Selected game: '+$path.Text}
 $keys=@{ShortcutKey=45;BackupShortcutKey=79};$script:menuKeyCandidate=0
 try{if(-not [string]::IsNullOrWhiteSpace($path.Text)){$keys=GetMenuSettings $path.Text}}
 catch{$form.FindName('PrimaryMenuKey').Text='Unavailable';$form.FindName('KeyCaptureHint').Text='Unable to read shortcuts: '+$_.Exception.Message;return}
 $script:hotSwapCandidate=[int]$keys.PresetHotSwapKey
 $form.FindName('HotSwapKey').Text=if($script:hotSwapCandidate -gt 0){([Windows.Forms.Keys]$script:hotSwapCandidate).ToString()}else{'Not set'}
 $script:menuKeyCandidate=[int]$keys.ShortcutKey
 $form.FindName('PrimaryMenuKey').Text=([Windows.Forms.Keys]$script:menuKeyCandidate).ToString()
 $form.FindName('KeyCaptureHint').Text='Click Change, press one key, then Save shortcuts. Escape cancels.'
 $form.FindName('BackupMenuHint').Text='Recovery shortcut: Ctrl+Shift+'+([Windows.Forms.Keys][int]$keys.BackupShortcutKey).ToString()+' (no Insert or numpad needed). Saving the primary key keeps this shortcut.'
}
function BeginMenuKeyCapture {
 $script:capturingHotSwap=$false;$form.FindName('ChangeHotSwapKey').Content='Change'
 $script:capturingMenuKey=$true;$form.FindName('ChangeMenuKey').Content='Press a key...'
 $form.FindName('KeyCaptureHint').Text='Press one key for the menu. Escape cancels; modifier combinations are not supported for the primary key.'
 [void]$form.FindName('ChangeMenuKey').Focus()
}
function CaptureMenuKey($event) {
 if(-not $script:capturingMenuKey){return};$event.Handled=$true
 $key=$event.Key;if($key -eq [Windows.Input.Key]::System){$key=$event.SystemKey}
 if($key -eq [Windows.Input.Key]::Escape){$script:capturingMenuKey=$false;$form.FindName('ChangeMenuKey').Content='Change';$form.FindName('KeyCaptureHint').Text='Cancelled. The selected key is unchanged.';return}
 $code=[Windows.Input.KeyInterop]::VirtualKeyFromKey($key)
 if([Windows.Input.Keyboard]::Modifiers -ne [Windows.Input.ModifierKeys]::None -or $code -notin (@(33..40)+@(45,46)+@(48..57)+@(65..90)+@(96..111)+@(112..123))){$form.FindName('KeyCaptureHint').Text='Choose a letter, number, function or navigation key without modifiers. Escape cancels.';return}
 $script:menuKeyCandidate=$code;$script:capturingMenuKey=$false
 $form.FindName('PrimaryMenuKey').Text=([Windows.Forms.Keys]$code).ToString();$form.FindName('ChangeMenuKey').Content='Change'
 $form.FindName('KeyCaptureHint').Text='Not saved yet. Click Save shortcuts to apply this key after restarting MSFS.'
}
$form.FindName('ChangeMenuKey').Add_Click({BeginMenuKeyCapture})
$form.Add_PreviewKeyDown({CaptureMenuKey $_})
$form.Add_Deactivated({if($script:capturingMenuKey){$script:capturingMenuKey=$false;$form.FindName('ChangeMenuKey').Content='Change';$form.FindName('KeyCaptureHint').Text='Key capture cancelled when the manager lost focus.'}})
$form.FindName('ChangeHotSwapKey').Add_Click({$script:capturingMenuKey=$false;$form.FindName('ChangeMenuKey').Content='Change';$script:capturingHotSwap=$true;$form.FindName('ChangeHotSwapKey').Content='Press a key...';$form.FindName('KeyCaptureHint').Text='Press a hotswap key. Escape cancels; Backspace clears. Then Save shortcuts.'})
$form.FindName('ClearHotSwapKey').Add_Click({$script:capturingHotSwap=$false;$script:hotSwapCandidate=0;$form.FindName('HotSwapKey').Text='Not set';$form.FindName('ChangeHotSwapKey').Content='Change';$form.FindName('KeyCaptureHint').Text='Click Save shortcuts to keep this change.'})
$form.Add_PreviewKeyDown({
 if(-not $script:capturingHotSwap){return};$_.Handled=$true;$key=$_.Key;if($key -eq [Windows.Input.Key]::System){$key=$_.SystemKey}
 if($key -eq [Windows.Input.Key]::Escape){$script:capturingHotSwap=$false;$form.FindName('ChangeHotSwapKey').Content='Change';return}
 $code=[Windows.Input.KeyInterop]::VirtualKeyFromKey($key)
 if($code -eq 8){$code=0}elseif([Windows.Input.Keyboard]::Modifiers -ne [Windows.Input.ModifierKeys]::None -or $code -notin (@(33..40)+@(45,46)+@(48..57)+@(65..90)+@(96..111)+@(112..123))){return}
 $script:hotSwapCandidate=$code;$script:capturingHotSwap=$false;$form.FindName('ChangeHotSwapKey').Content='Change';$form.FindName('HotSwapKey').Text=if($code){([Windows.Forms.Keys]$code).ToString()}else{'Not set'};$form.FindName('KeyCaptureHint').Text='Click Save shortcuts to keep this change.'
})
$form.Add_Deactivated({$script:capturingHotSwap=$false;$form.FindName('ChangeHotSwapKey').Content='Change'})
$form.FindName('LoadMenuKeys').Add_Click({RunAction {RefreshMenuKeys;$status.Text='Showing shortcuts for the selected game folder.'}})
$form.FindName('SaveMenuKeys').Add_Click({RunAction {
 if($script:capturingMenuKey -or -not $script:menuKeyCandidate){throw 'Press a primary menu key first.'}
 $keys=GetMenuSettings $path.Text
 if($script:capturingHotSwap){throw 'Finish choosing the hotswap key first.'}
 SetMenuSettings $path.Text $script:menuKeyCandidate ([int]$keys.BackupShortcutKey) $script:hotSwapCandidate
 RefreshMenuKeys;$status.Text='Shortcuts saved. Restart MSFS to use them. Your recovery shortcut is unchanged.'
}})
$form.FindName('DefaultMenuKeys').Add_Click({RunAction {SetMenuSettings $path.Text 45 79 0;RefreshMenuKeys;$status.Text='Default shortcuts saved: Insert and Ctrl+Shift+O. Restart MSFS.'}})
$path.Add_TextChanged({RefreshMenuKeys})
RefreshMenuKeys
ShowPage 'Home'
# Raise the shared splash/installer window once, without keeping it above other apps.
$form.Add_Loaded({$form.Topmost=$true;[void]$form.Activate()})
$form.Add_ContentRendered({$form.Topmost=$false;[void]$form.Activate();$script:introStart=Get-Date;$form.FindName('IntroStatus').Text=if(Test-Path -LiteralPath $script:cachePath){'Loading your saved setup...'}else{'Checking graphics hardware and finding Microsoft Flight Simulator installations...'};$status.Text=$form.FindName('IntroStatus').Text;$script:startupTimer.Start()})
$form.Add_Closed({$script:startupTimer.Stop();if($script:startupResult){$script:startup.BeginStop($null,$null)|Out-Null}})
[void]$form.ShowDialog()
