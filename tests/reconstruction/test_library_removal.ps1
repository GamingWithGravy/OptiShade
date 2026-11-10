$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Beta/installer/library.ps1"
$assertions=0
function Check($Value,[string]$Message){if(-not $Value){throw $Message};$script:assertions++}
$folder=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-library-remove-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($folder)
try{
 $msfs=[pscustomobject]@{Launcher='Xbox';Folder=(Join-Path $folder 'MSFS2020');Name='Microsoft Flight Simulator 2020'}
 $xp=[pscustomobject]@{Launcher='Steam';Folder=(Join-Path $folder 'X-Plane 12');Name='X-Plane 12'}
 $removed=@{};$key=GetFusionLibraryGameKey $msfs;$removed[$key]=$true
 $visible=@(FilterFusionLibraryGames @($msfs,$xp) $removed)
 Check ($visible.Count -eq 1 -and $visible[0].Name -eq 'X-Plane 12') 'Removed game entry remained visible or another game was hidden.'
 $samePath=[pscustomobject]@{Launcher='xbox';Folder=$msfs.Folder.ToUpperInvariant()}
 Check ((GetFusionLibraryGameKey $samePath) -eq $key) 'Library exclusion key was not stable across case differences.'
 $empty=@{};$notHidden=@(FilterFusionLibraryGames @($msfs) $empty)
 Check ($notHidden.Count -eq 1) 'An empty exclusion list hid a game.'
 $manager=Get-Content -LiteralPath "$root/Beta/installer/manager.ps1" -Raw
 $xaml=Get-Content -LiteralPath "$root/Beta/installer/manager.xaml" -Raw
 Check ($manager -match 'RemovedGames=@\(\$script:removedGames\.Keys\)' -and $manager -match 'foreach\(\$key in @\(\$saved\.RemovedGames\)\)') 'Library removals were not persisted and restored.'
 Check ($xaml -match 'Tag="remove"' -and $manager -match '\$source\.Tag -eq ''remove''') 'Library card Remove action is not wired to its handler.'
 $removeStart=$manager.IndexOf('function RemoveLibraryGameEntry(');$removeEnd=$manager.IndexOf('function RefreshHomeState',$removeStart);$removeBody=$manager.Substring($removeStart,$removeEnd-$removeStart)
 Check ($removeBody -match 'GetManagedInstallations' -and $removeBody -match 'RunAction \{InvokeRestoreInstall\}' -and $removeBody -match '\$script:restoreKeepPresets=\$true') 'Remove does not restore a managed game installation while preserving its presets.'
 Check ($removeBody.IndexOf('RunAction {InvokeRestoreInstall}') -lt $removeBody.IndexOf('$script:removedGames[$key]=$true')) 'The library entry can be hidden before the OptiShade restore completes.'
 Check ($removeBody -match 'if\(\$script:operationFailed\)\{return\}' -and $removeBody -match 'The game and saved presets were kept') 'Failed restore can still hide the library entry, or the completion message is inaccurate.'
 Check ($removeBody -match 'RemoveMissingOptiShadeInstallRecord' -and $removeBody -match 'If the drive is disconnected, choose No') 'Removing an already-uninstalled game does not offer explicit, safe cleanup of its OptiShade record.'
 Check ($manager -match 'removedGames\.Remove\(\$libraryKey\)') 'Explicitly selecting the game in Setup does not restore its library visibility.'
 # Execute the production handler with a WPF fixture and controlled restore
 # outcomes. The earlier source checks prove ordering text; this proves that
 # a failed restore leaves the entry visible and a successful restore hides it.
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Beta/installer/manager.ps1'),[ref]$tokens,[ref]$errors)
 if($errors.Count){throw ($errors|Out-String)}
 $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'RemoveLibraryGameEntry'},$true)
 if(-not $node){throw 'Could not locate the production library Remove handler.'}
 . ([scriptblock]::Create($node.Extent.Text))
 [xml]$xaml=Get-Content -LiteralPath (Join-Path $root 'Beta/installer/manager.xaml') -Raw -Encoding UTF8
 $form=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xaml))
 $path=$form.FindName('GamePath');$status=$form.FindName('Status')
 $path.Text=''
 $managedGame=[pscustomobject]@{Name='Managed fixture';Folder=(Join-Path $folder 'ManagedGame');InstallFolder=(Join-Path $folder 'ManagedGame');Launcher='Fixture'};[void][IO.Directory]::CreateDirectory($managedGame.Folder)
  $script:managedRecord=[pscustomobject]@{Title='Managed fixture';Game=$managedGame.Folder;Manifest='fixture';State='Installed';Version='fixture';Components=@();Display='Managed fixture'}
 $card=[pscustomobject]@{Name=$managedGame.Name;Folder=$managedGame.Folder;InstallFolder=$managedGame.InstallFolder;Launcher='Fixture';FavoriteKey=(GetFusionLibraryGameKey $managedGame)}
 $script:removedGames=@{};$script:favoriteGames=@{$card.FavoriteKey=$true};$script:libraryGames=@($card);$script:componentsGameSource=@($card);$script:simulateRestoreFailure=$true;$script:restoreTrace=[Collections.Generic.List[string]]::new();$script:operationFailed=$false;$script:restoreKeepPresets=$false
 $form.FindName('MsfsCopies').ItemsSource=@($managedGame)
 function global:GetManagedInstallations{return @($script:managedRecord)}
 function global:ShowOptiShadeDialog{param($Owner,$Message,$Confirm,$Buttons,$Icon,$Default);$script:lastPrompt=$Message;$script:restoreTrace.Add('confirm');return 'Yes'}
 function global:SetManagerGame($Item){$script:restoreTrace.Add('selected-game')}
 function global:RunAction($Action,$Text,[switch]$SkipTargetRecovery){$script:lastRunSkippedTarget=[bool]$SkipTargetRecovery;$script:restoreTrace.Add('restore-start');try{&$Action;$script:operationFailed=$false}catch{$script:operationFailed=$true};if(-not $script:operationFailed){$script:restoreTrace.Add('restore-complete')}}
 function global:InvokeRestoreInstall{$script:restoreTrace.Add('restore-executed');if($script:simulateRestoreFailure){throw 'fixture restore failure'}}
 function global:SaveLibraryPreferences{$script:restoreTrace.Add('hide-entry');if(-not $script:restoreTrace.Contains('restore-complete') -and -not $script:restoreTrace.Contains('discard-missing-record')){throw 'Library entry was hidden before restore or missing-game cleanup completed.'}}
 function global:UpdateLibraryGrid{}
 function global:RefreshHomeState{}
 function global:RefreshComponentsGameSelector{}
 function global:UpdateDetectedStore{}
 function global:ClearComponentsTargetSummary{}
 try{
  RemoveLibraryGameEntry $managedGame
  Check ($script:operationFailed -and -not $script:removedGames.ContainsKey($card.FavoriteKey)) 'A failed restore hid the managed game from the library.'
  Check ($script:libraryGames.Count -eq 1 -and $form.FindName('MsfsCopies').ItemsSource.Count -eq 1) 'A failed restore removed the managed game from a visible library collection.'
  Check ($script:restoreKeepPresets) 'The production handler did not request preset preservation.'
  $script:simulateRestoreFailure=$false;$script:operationFailed=$false;$script:restoreTrace.Clear()
  RemoveLibraryGameEntry $managedGame
  Check (-not $script:operationFailed -and $script:removedGames.ContainsKey($card.FavoriteKey)) 'A successful restore did not hide the game entry.'
  Check ($script:libraryGames.Count -eq 0 -and $form.FindName('MsfsCopies').ItemsSource.Count -eq 0) 'A successful restore left the game visible in the library.'
  Check ($script:restoreTrace.IndexOf('restore-complete') -ge 0 -and $script:restoreTrace.IndexOf('restore-complete') -lt $script:restoreTrace.IndexOf('hide-entry')) 'The entry was hidden before the restore completed.'
  Check ($status.Text -match 'OptiShade was removed from the game' -and $status.Text -match 'saved presets were kept') 'The success message does not match the restore and preset behavior.'
  Remove-Item -LiteralPath $managedGame.Folder -Recurse -Force;$script:removedGames=@{};$script:favoriteGames=@{$card.FavoriteKey=$true};$script:libraryGames=@($card);$script:componentsGameSource=@($card);$script:restoreTrace.Clear();$script:lastPrompt=''
  function global:RemoveMissingOptiShadeInstallRecord{param([string]$StateRoot,[string]$Game);if($Game -cne $script:managedRecord.Game){throw 'Wrong missing game record.'};$script:restoreTrace.Add('discard-missing-record')}
  RemoveLibraryGameEntry $managedGame
  Check ($script:restoreTrace.Contains('discard-missing-record') -and -not $script:restoreTrace.Contains('restore-executed') -and $script:lastRunSkippedTarget) 'A missing game path used Restore or the unrelated selected-game recovery path.'
  Check ($script:removedGames.ContainsKey($card.FavoriteKey) -and $script:libraryGames.Count -eq 0 -and $status.Text -match 'folder was not recreated') 'Missing-game cleanup failed to hide its entry or report the non-restoring result.'
  Check ($script:lastPrompt -match 'permanently delete' -and $script:lastPrompt -match 'drive is disconnected') 'Missing-game cleanup did not explain backup deletion and disconnected-drive behavior.'
  $orphanFolder=Join-Path $folder 'MicrosoftFlightSimulator';[void][IO.Directory]::CreateDirectory($orphanFolder)
  $orphanGame=[pscustomobject]@{Name='Microsoft Flight Simulator 2020';Folder=$orphanFolder;InstallFolder=$orphanFolder;Launcher='Steam'}
  $orphanCard=[pscustomobject]@{Name=$orphanGame.Name;Folder=$orphanFolder;InstallFolder=$orphanFolder;Launcher='Steam';FavoriteKey=(GetFusionLibraryGameKey $orphanGame)}
  $script:managedRecord=[pscustomobject]@{Title=$orphanGame.Name;Game=$orphanFolder;Manifest='fixture';State='Installed';Version='fixture';Components=@();Display=$orphanGame.Name}
  $script:removedGames=@{};$script:favoriteGames=@{$orphanCard.FavoriteKey=$true};$script:libraryGames=@($orphanCard);$script:componentsGameSource=@($orphanCard);$script:restoreTrace.Clear();$script:lastPrompt='';$script:operationFailed=$false
  $path.Text='';$form.FindName('MsfsCopies').ItemsSource=@($orphanGame)
  RemoveLibraryGameEntry $orphanGame
  Check ($script:restoreTrace.Contains('restore-executed') -and -not $script:restoreTrace.Contains('discard-missing-record')) 'An existing leftover folder with a missing simulator executable discarded restore data instead of restoring OptiShade.'
  Check ($script:removedGames.ContainsKey($orphanCard.FavoriteKey) -and $script:libraryGames.Count -eq 0 -and $status.Text -match 'No game executable was found' -and $status.Text -match 'saved presets were kept') 'Removing a stale simulator entry did not restore its OptiShade files, keep presets and hide the entry.'
  Check ($script:lastPrompt -match 'No simulator executable is accessible' -and $script:lastPrompt -match 'choose No') 'The stale-game confirmation did not distinguish a missing executable from an accessible game.'
 }finally{$form.Close()}
 Write-Output "Library removal: $assertions assertions passed; production handler exercised with failed/successful restore, missing folder and leftover folder without simulator executable."
}finally{Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue}

