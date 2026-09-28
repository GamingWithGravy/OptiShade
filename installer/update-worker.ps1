param([Parameter(Mandatory=$true)][string]$Config)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework
. "$PSScriptRoot/update-lifecycle.ps1"
. "$PSScriptRoot/beta-download.ps1"
$settings=Get-Content -LiteralPath $Config -Raw -Encoding UTF8|ConvertFrom-Json
$script:target=[IO.Path]::GetFullPath($settings.Installer)
$desktop=if($settings.Desktop){[string]$settings.Desktop}else{[Environment]::GetFolderPath('DesktopDirectory')}
if([string]::IsNullOrWhiteSpace($desktop) -or -not [IO.Path]::IsPathRooted($desktop) -or -not (Test-Path -LiteralPath $desktop -PathType Container)){throw 'Your Desktop folder is unavailable. Reconnect it and retry the update.'}
$desktop=[IO.Path]::GetFullPath($desktop)
$safeVersion=([string]$settings.Version) -replace '[^a-zA-Z0-9._-]','_'
$channel=if($safeVersion -match '-(?:alpha|beta|rc)'){'beta'}else{'stable'}
$destination=Join-Path $desktop (GetOptiShadeManagerName $safeVersion $channel)
$previous=$script:target
$uri=[uri]$settings.Url
if($settings.SHA256 -notmatch '^[a-fA-F0-9]{64}$' -or [IO.Path]::GetExtension($script:target) -ne '.exe'){throw 'Invalid update information.'}
if($channel -eq 'beta'){
 if($settings.Source -cne 'beta-branch'){throw 'Beta downloads must come from the opted-in beta branch.'}
}else{
 if($settings.Source -eq 'beta-branch' -or $uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com' -or $uri.AbsolutePath -cnotmatch '^/GamingWithGravy/(OptiShade|OptiShade_V0[.]19[.]17)/releases/download/'){throw 'Stable downloads must come from official releases.'}
}
[xml]$markup=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="OptiShade update" Width="700" Height="500" ResizeMode="NoResize" WindowStyle="None" AllowsTransparency="True" WindowStartupLocation="CenterScreen" Background="Transparent" Foreground="#F3EFFB" FontFamily="Segoe UI"><Border Background="#171020" BorderBrush="#40314F" BorderThickness="1" CornerRadius="20"><Grid><Border Name="DragHeader" Height="48" VerticalAlignment="Top" Background="Transparent" Cursor="SizeAll"/><Button Name="Close" Content="&#x2715;" HorizontalAlignment="Right" VerticalAlignment="Top" Background="Transparent" Margin="0,8,12,0" Padding="12,8" ToolTip="Close"/><StackPanel Margin="36" VerticalAlignment="Center"><TextBlock Text="Optishade" FontSize="48" FontWeight="SemiBold" HorizontalAlignment="Center"/><TextBlock Text="Your simulator. Your way." FontSize="22" Foreground="#BD9CEC" HorizontalAlignment="Center" Margin="0,8,0,24"/><TextBlock Name="Version" HorizontalAlignment="Center" Margin="0,0,0,16"/><TextBox Name="Notes" Visibility="Collapsed"/><TextBox Name="Status" Text="Updating..." IsReadOnly="True" TextWrapping="Wrap" TextAlignment="Center" Foreground="#C9B6DF" Background="Transparent" BorderThickness="0" MaxHeight="140" VerticalScrollBarVisibility="Auto"/><ProgressBar Name="Progress" Width="360" Height="7" Margin="0,24,0,0" Foreground="#9755E9" Background="#332246" Maximum="100" BorderThickness="0"/><StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,22,0,0"><Button Name="Launch" Content="Open manager" Visibility="Collapsed" Padding="26,10" Background="#8650C8" Foreground="White"/><Button Name="OpenLocation" Content="Open file location" Visibility="Collapsed" Padding="16,10" Margin="12,0,0,0" Background="#282238"/><Button Name="DoneClose" Content="Close" Visibility="Collapsed" Padding="26,10" Margin="12,0,0,0" Background="#282238"/></StackPanel><TextBlock Text="created by gravy" HorizontalAlignment="Center" Foreground="#8E829E" Margin="0,26,0,0"/></StackPanel></Grid></Border></Window>
'@
$window=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup))
[xml]$theme=Get-Content "$PSScriptRoot/dialog-theme.xaml" -Raw; $window.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($theme)))
$window.FindName('Close').Add_Click({$window.Close()})
$window.FindName('OpenLocation').Add_Click({try{Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList ('/select,"'+$script:target+'"')}catch{$window.FindName('Status').Text='Saved to: '+$script:target+' (Explorer could not open.)'}})
$window.FindName('DoneClose').Add_Click({$window.Close()})
$window.FindName('DragHeader').Add_MouseLeftButtonDown({$window.DragMove()})
$window.FindName('Version').Text=if($settings.Rollback){'Reverting to Version '+$settings.Version}else{'Updating to Version '+$settings.Version}
$window.FindName('Notes').Text=$settings.Notes
$script:started=$false;$script:updating=$true
$script:rollbackLogs=@()
function SuspendRollbackLogs {
 # Older updaters mistake generated, untracked logs for foreign graphics loaders.
 # Temporarily park only these two logs; never DLLs, INIs or tracked files.
 $records=Join-Path $env:LOCALAPPDATA 'OptiShade/Games'
 foreach($record in Get-ChildItem -LiteralPath $records -Filter manifest.json -Recurse -File -ErrorAction SilentlyContinue){
  $m=Get-Content -LiteralPath $record.FullName -Raw|ConvertFrom-Json
  if($m.Status -ne 'Installed'){continue}
  if([version]$settings.Version -lt [version]'0.21' -and (Test-Path -LiteralPath (Join-Path $m.Game 'X-Plane.exe'))){throw 'Restore X-Plane original files before installing a version below 0.21.'}
  $game=[IO.Path]::GetFullPath($m.Game);$check=$game
  while($check){
   if((Get-Item -LiteralPath $check -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Rollback stopped: select the physical game installation folder in Setup first.'}
   $parent=Split-Path $check -Parent;if($parent -eq $check){break};$check=$parent
  }
  foreach($name in @('ReShade.log','OptiScaler.log')){
   if(@($m.Files|Where-Object Path -eq $name).Count){continue}
   $file=Join-Path $game $name
   if(-not(Test-Path -LiteralPath $file -PathType Leaf)){continue}
   if((Get-Item -LiteralPath $file -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Rollback stopped: a graphics log is linked.'}
   $backup=$file+'.rollback-'+[guid]::NewGuid().ToString('N')
   [IO.File]::Move($file,$backup)
   $script:rollbackLogs+=@{Path=$file;Backup=$backup}
  }
 }
}
function RunUpdateStage([string]$Executable,[string]$Mode){
 $receipt=Join-Path (Split-Path $Config) ([guid]::NewGuid().ToString('N')+'.result')
 $job=Start-Process -FilePath $Executable -ArgumentList @($Mode,('"'+$receipt+'"')) -WindowStyle Hidden -PassThru
 # Retain the process handle so ExitCode remains available after the child exits.
 $handle=$job.Handle
 try{
  while(-not $job.HasExited){$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background);Start-Sleep -Milliseconds 150}
  $job.WaitForExit()
  $result=if(Test-Path -LiteralPath $receipt){Get-Content -LiteralPath $receipt -Raw}else{''}
  if($job.ExitCode -ne 0 -or $result -ne 'OK'){
   if($result){throw $result}
   throw "Update stage $Mode did not confirm completion (exit $($job.ExitCode)). The update was stopped."
  }
 }finally{$job.Dispose();if(Test-Path -LiteralPath $receipt){Remove-Item -LiteralPath $receipt -Force}}
}
$window.FindName('Launch').Add_Click({try{Start-Process -FilePath $script:target -WindowStyle Hidden;$window.Close()}catch{$window.FindName('Status').Text=$_.Exception.Message}})
$window.Add_Closing({param($sender,$e) if($script:updating){$e.Cancel=$true}})
# Raise the update splash once; release topmost before processing the update.
$window.Add_Loaded({$window.Topmost=$true;[void]$window.Activate()})
$window.Add_ContentRendered({
 $window.Topmost=$false;[void]$window.Activate()
 if($script:started){return};$script:started=$true
 $download=Join-Path (Split-Path $Config) 'download.exe';$web=New-Object Net.WebClient
 try{
  $space=@{}
  foreach($requirement in @(@{Path=(Split-Path $Config);Bytes=1GB},@{Path=$desktop;Bytes=512MB})){
   $drive=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($requirement.Path));$space[$drive]+=$requirement.Bytes
  }
  foreach($drive in $space.Keys){if(([IO.DriveInfo]::new($drive)).AvailableFreeSpace -lt $space[$drive]){throw "Not enough disk space on $drive. Free at least $([math]::Ceiling($space[$drive]/1MB)) MB for downloading and staging the update, then retry. No installed files were changed."}}
  [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
  $window.FindName('Status').Text='Downloading OptiShade Manager...';$window.FindName('Progress').IsIndeterminate=$true
  if($channel -eq 'beta'){
   $downloadStore=if($settings.Store){[string]$settings.Store}else{Join-Path $env:LOCALAPPDATA 'OptiShade'}
   SaveOptiShadeBetaDownload $settings $download $downloadStore {
    param($part,$count)
    $window.FindName('Status').Text="Downloading beta from the beta branch ($part of $count)..."
    $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)
   }
  }else{
  $web.Headers['User-Agent']='OptiShade-updater';$task=$web.DownloadFileTaskAsync($uri,$download);$clock=[Diagnostics.Stopwatch]::StartNew()
  while(-not $task.IsCompleted){if($clock.Elapsed.TotalMinutes -gt 15){$web.CancelAsync();throw 'Download timed out. Your existing manager is unchanged.'};$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background);Start-Sleep -Milliseconds 100}
  $task.GetAwaiter().GetResult()
  }
  if(Get-Process FlightSimulator2024,FlightSimulator,X-Plane -ErrorAction SilentlyContinue){throw 'Close all simulators, then retry. No installed files were changed.'}
  if((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $settings.SHA256){throw 'Update verification failed. Your existing manager is unchanged.'}
  if($settings.Rollback){SuspendRollbackLogs}
  $window.FindName('Status').Text='Checking staged files and installation requirements...'
  $window.FindName('Progress').IsIndeterminate=$false;$window.FindName('Progress').Value=35
  RunUpdateStage $download '--check-update'
  $window.FindName('Status').Text='Saving the verified manager to your Desktop...'
  $window.FindName('Progress').Value=55
  $staged=$destination+'.updating'
  Copy-Item -LiteralPath $download -Destination $staged
  if((Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash -ne $settings.SHA256){throw 'Staged update verification failed.'}
  if(Test-Path -LiteralPath $destination){
   if((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $settings.SHA256){throw 'A different EXE already uses the destination name on your Desktop. Move that file and retry; it has not been overwritten.'}
   Remove-Item -LiteralPath $staged -Force
  }else{[IO.File]::Move($staged,$destination)}
  $script:target=$destination
  $window.FindName('Status').Text='Updating installed game files and keeping your presets...'
  $window.FindName('Progress').Value=70
  RunUpdateStage $script:target '--apply-update'
  $window.FindName('Progress').IsIndeterminate=$false;$window.FindName('Progress').Value=100
  $action=if($settings.Rollback){'Rollback'}else{'Update'}
  $store=if($settings.Store){[string]$settings.Store}else{Join-Path $env:LOCALAPPDATA 'OptiShade'}
  $cleanup=CompleteOptiShadeManagerUpdate $previous $settings.PreviousHash $script:target $settings.SHA256 $store $channel
  $window.FindName('Status').Text="$action complete. The selected OptiShade EXE is on your Desktop:`n$script:target`nUse this EXE from now on.`n$cleanup"
  $window.FindName('OpenLocation').Visibility='Visible'
  Remove-Item -LiteralPath $download -Force
  $script:updating=$false;$window.FindName('Launch').Visibility='Visible';$window.FindName('DoneClose').Visibility='Visible'
 }catch{
  $window.FindName('Progress').IsIndeterminate=$false
  $detail=$_.Exception.Message
  $friendly=$detail
  if($detail -match '(?s)System\.Management\.Automation\.RuntimeException: (.*?)(?: --->|\r?\n\s+at |$)'){$friendly=$Matches[1].Trim()}
  $window.FindName('Status').Text='Update stopped. '+$friendly
  if(Test-Path -LiteralPath $destination){$window.FindName('Status').Text+="`nThe verified EXE is saved at: $destination. Game updates may be incomplete.";$window.FindName('OpenLocation').Visibility='Visible'}
  if($staged -and (Test-Path -LiteralPath $staged)){Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue}
  $script:updating=$false;$window.FindName('Launch').Content='Open manager';$window.FindName('Launch').Visibility='Visible';$window.FindName('DoneClose').Visibility='Visible'
  $_|Out-String|Set-Content -LiteralPath (Join-Path (Split-Path $Config) 'Update-error.txt') -Encoding UTF8
 }
 finally{
  foreach($log in $script:rollbackLogs){
   try{if(Test-Path -LiteralPath $log.Backup){[IO.File]::Move($log.Backup,$log.Path)}}
   catch{$window.FindName('Status').Text+="`nPrevious log preserved at: $($log.Backup)"}
  }
  $web.Dispose()
 }
})
[void]$window.ShowDialog()
