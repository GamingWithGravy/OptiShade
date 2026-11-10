# Driver writes are explicit, per-profile and reviewed. No automatic driver changes.
$script:nvReview=$null;$script:nvProcess=$null;$script:nvOperation=''
$script:nvDirectory=Join-Path $store 'DriverSettings';[void][IO.Directory]::CreateDirectory($script:nvDirectory)
foreach($choice in @('default','latest','K','L','M')){[void]$form.FindName('NvidiaSR').Items.Add([pscustomobject]@{Value=$choice;Label=$(if($choice -eq 'default'){'Game / driver controlled'}elseif($choice -eq 'latest'){'Latest supported preset'}else{'Preset '+$choice})})}
foreach($choice in @('default','latest','A','B')){[void]$form.FindName('NvidiaFG').Items.Add([pscustomobject]@{Value=$choice;Label=$(if($choice -eq 'default'){'Game / driver controlled'}elseif($choice -eq 'latest'){'Latest supported preset'}else{'Preset '+$choice})})}
$form.FindName('NvidiaSR').SelectedIndex=0;$form.FindName('NvidiaFG').SelectedIndex=0
function GetNvidiaBackupIndex([string]$Exe){
 $sha=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Exe.ToLowerInvariant())))).Replace('-','')}finally{$sha.Dispose()}
 Join-Path $script:nvDirectory ($hash+'.json')
}
function UpdateNvidiaActions{
 $ready=(-not $script:nvProcess) -and (-not $script:busy)
 $form.FindName('NvidiaGame').IsEnabled=$ready;$form.FindName('NvidiaBrowse').IsEnabled=$ready
 $form.FindName('NvidiaExe').IsEnabled=$ready;$form.FindName('NvidiaSR').IsEnabled=$ready;$form.FindName('NvidiaFG').IsEnabled=$ready
 $form.FindName('NvidiaRead').IsEnabled=$ready;$form.FindName('NvidiaUseGame').IsEnabled=$ready
 $form.FindName('NvidiaSave').IsEnabled=($ready -and $null -ne $script:nvReview)
 $form.FindName('NvidiaRestore').IsEnabled=$ready -and (Test-Path -LiteralPath (GetNvidiaBackupIndex $form.FindName('NvidiaExe').Text))
}
function StartNvidiaOperation([string]$Operation){
 if($script:busy -or $script:nvProcess){return}
 try{
  $exe=$form.FindName('NvidiaExe').Text.Trim();if(-not $exe -or $exe.Contains('"') -or $exe.Contains("`n") -or $exe.Contains("`r") -or -not $exe.EndsWith('.exe',[StringComparison]::OrdinalIgnoreCase)){throw 'Enter the game executable name or path ending in .exe.'}
  $record='-'
  if($Operation -eq 'save'){if(-not $script:nvReview -or $script:nvReviewExe -ne $exe){throw 'Read and review this profile before saving.'};$record=$script:nvReview.record}
  if($Operation -eq 'restore'){$saved=Get-Content -LiteralPath (GetNvidiaBackupIndex $exe) -Raw|ConvertFrom-Json;$record=$saved.record}
  $script:nvOutput=Join-Path $script:nvDirectory (([guid]::NewGuid().ToString('N'))+'.json')
  $sr=[string]$form.FindName('NvidiaSR').SelectedValue;$fg=[string]$form.FindName('NvidiaFG').SelectedValue
  $arguments=@($Operation,$exe,$record,$sr,$fg,$script:nvOutput)|ForEach-Object {'"'+$_+'"'}
  $options=@{FilePath=(Join-Path $PSScriptRoot 'OptiShadeDriver.exe');ArgumentList=($arguments -join ' ');PassThru=$true;WindowStyle='Hidden'}
  if($Operation -ne 'read'){$options.Verb='RunAs'}
  $script:nvOperation=$Operation;$script:nvReviewExe=$exe
  $script:nvProcess=Start-Process @options
  $form.FindName('NvidiaStatus').Text='Working with the selected NVIDIA profile...';UpdateNvidiaActions;$script:nvTimer.Start()
 }catch{$form.FindName('NvidiaStatus').Text=$_.Exception.Message;UpdateNvidiaActions}
}
$script:nvTimer=[Windows.Threading.DispatcherTimer]::new();$script:nvTimer.Interval=[TimeSpan]::FromMilliseconds(200)
$script:nvTimer.Add_Tick({
 if(-not $script:nvProcess -or -not $script:nvProcess.HasExited){return}
 $script:nvTimer.Stop();$script:nvProcess.Dispose();$script:nvProcess=$null
 try{
  $result=Get-Content -LiteralPath $script:nvOutput -Raw|ConvertFrom-Json
  if(-not $result.ok){throw $result.error}
  $describe={param($enabled,$preset) if($enabled -eq 0){'Game / driver controlled'}elseif($preset -eq 16777215){'Latest supported preset'}elseif($preset -ge 1 -and $preset -le 26){'Preset '+[char](64+$preset)}else{'Driver value '+$preset}}
  $form.FindName('NvidiaCurrent').Text=('Profile: '+$result.profile+"`nSuper Resolution: "+(& $describe $result.values[0].value $result.values[1].value)+"`nFrame Generation: "+(& $describe $result.values[2].value $result.values[3].value))
  if($script:nvOperation -eq 'read'){
   $script:nvReview=$result
   foreach($pair in @(@('NvidiaSR',0,1),@('NvidiaFG',2,3))){$v=[uint32]$result.values[$pair[2]].value;$choice=if($result.values[$pair[1]].value -eq 0){'default'}elseif($v -eq 16777215){'latest'}elseif($v -ge 1 -and $v -le 26){[string][char](64+$v)}else{''};$box=$form.FindName($pair[0]);$box.SelectedValue=$choice}
   $form.FindName('NvidiaStatus').Text='Profile read. Choose both presets before saving. default disables that model override; it does not disable DLSS.'
  }else{
   if($script:nvOperation -eq 'save'){$result|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (GetNvidiaBackupIndex $script:nvReviewExe) -Encoding UTF8}
   $script:nvReview=$null
   $form.FindName('NvidiaStatus').Text='Driver settings saved and verified by a fresh read. Start the game to test. Backup: '+$result.record
  }
 }catch{$script:nvReview=$null;$form.FindName('NvidiaStatus').Text=$_.Exception.Message}
 UpdateNvidiaActions
})
$form.FindName('NvidiaNav').Add_Click({ShowPage 'Nvidia';RefreshNvidiaGames})
$form.FindName('NvidiaRead').Add_Click({StartNvidiaOperation 'read'})
$form.FindName('NvidiaSave').Add_Click({if($form.FindName('NvidiaSR').SelectedIndex -lt 0 -or $form.FindName('NvidiaFG').SelectedIndex -lt 0){$form.FindName('NvidiaStatus').Text='Choose both presets first; the current driver value is not in the supported choices.';return};StartNvidiaOperation 'save'})
$form.FindName('NvidiaRestore').Add_Click({StartNvidiaOperation 'restore'})
$form.FindName('NvidiaExe').Add_TextChanged({$script:nvReview=$null;$form.FindName('NvidiaCurrent').Text='Read this game profile to review its settings.';UpdateNvidiaActions})
function RefreshNvidiaGames{
 if($script:nvProcess){return}
 $picker=$form.FindName('NvidiaGame');$previous=$picker.SelectedItem
 $script:nvRefreshing=$true
 try{
  $items=@($script:libraryGames | Where-Object {$_ -and $_.Folder} | Sort-Object Name,Folder)
  $picker.ItemsSource=$items
  $match=$null;if($previous){$match=$items | Where-Object {$_.Folder -eq $previous.Folder} | Select-Object -First 1}
  $picker.SelectedItem=$match
 }finally{$script:nvRefreshing=$false}
 if($previous -and -not $match){$form.FindName('NvidiaExe').Text=''}
 if(-not $items.Count){$form.FindName('NvidiaStatus').Text='No games in the library yet. Scan for games in Library, or browse an EXE here.'}
 UpdateNvidiaActions
}
function SelectNvidiaGame($Game){
 if($script:nvProcess -or $script:busy -or -not $Game){return}
 # Never retain the previous game target when resolving a different selection fails.
 $form.FindName('NvidiaExe').Text=''
 try{
  $cached=GetCachedManagerGameStatus $Game;$folder=if($cached){$cached.Folder}else{$Game.Folder}
  $receipt=ReadOptiShadeState (ManifestPath $store $folder);$selectedExe=''
  if($receipt -and $receipt.LaunchExe){
   $selectedExe=[string]$receipt.LaunchExe
   if([IO.Path]::GetFileName($selectedExe) -ieq 'gamelaunchhelper.exe'){
    switch($receipt.RouteDLL){
     'OptiShadeMSFS2024.dll' {$selectedExe='FlightSimulator2024.exe'}
     'OptiShadeMSFS2020.dll' {$selectedExe='FlightSimulator.exe'}
     default {throw 'This library entry has a launcher but no recorded rendering executable. Browse the game EXE below.'}
    }
   }
  }else{
   $matches=@(FindFusionExecutable $Game.Folder $Game.Launcher $Game.Name)
   if($matches.Count -ne 1){throw 'No unique game executable was found. Browse the game EXE below, or enter its executable name.'}
   $selectedExe=[string]$matches[0].Path
  }
  if(-not $selectedExe.EndsWith('.exe',[StringComparison]::OrdinalIgnoreCase)){throw 'The selected game has no usable executable. Browse the game EXE below.'}
  $form.FindName('NvidiaExe').Text=$selectedExe
  StartNvidiaOperation 'read'
 }catch{$form.FindName('NvidiaStatus').Text=$_.Exception.Message}
}
$form.FindName('NvidiaGame').Add_SelectionChanged({if(-not $script:nvRefreshing){SelectNvidiaGame $form.FindName('NvidiaGame').SelectedItem}})
$form.FindName('NvidiaUseGame').Add_Click({RefreshNvidiaGames})
$form.FindName('NvidiaBrowse').Add_Click({
 if($script:busy -or $script:nvProcess){return}
 $dialog=[Microsoft.Win32.OpenFileDialog]::new();$dialog.Title='Select the game rendering executable';$dialog.Filter='Game executable (*.exe)|*.exe';$dialog.CheckFileExists=$false
 if($dialog.ShowDialog($form)){
  $script:nvRefreshing=$true;try{$form.FindName('NvidiaGame').SelectedIndex=-1}finally{$script:nvRefreshing=$false}
  $form.FindName('NvidiaExe').Text=$dialog.FileName;StartNvidiaOperation 'read'
 }
})
$form.Add_Closed({$script:nvTimer.Stop();if($script:nvProcess){$script:nvProcess.Dispose();$script:nvProcess=$null}})
UpdateNvidiaActions
