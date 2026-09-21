param([Parameter(Mandatory=$true)][string]$Config)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework
$settings=Get-Content -LiteralPath $Config -Raw -Encoding UTF8|ConvertFrom-Json
$target=[IO.Path]::GetFullPath($settings.Installer)
$uri=[uri]$settings.Url
if($uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com' -or -not $uri.AbsolutePath.StartsWith('/GamingWithGravy/OptiShade_V0.19.17/releases/download/') -or $settings.SHA256 -notmatch '^[a-fA-F0-9]{64}$' -or [IO.Path]::GetExtension($target) -ne '.exe'){throw 'Invalid update information.'}
[xml]$markup=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="OptiShade update" Width="560" Height="420" ResizeMode="NoResize" WindowStartupLocation="CenterScreen" Background="#17121F" Foreground="#F3EFFB" FontFamily="Segoe UI"><StackPanel Margin="28"><TextBlock Text="Optishade" FontSize="28" FontWeight="SemiBold" HorizontalAlignment="Center"/><TextBlock Name="Version" FontSize="18" Margin="0,16,0,12"/><TextBox Name="Notes" Height="140" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Background="#241B30" Foreground="#D8C7ED" BorderThickness="0" Padding="10"/><ProgressBar Name="Progress" Height="8" Margin="0,20,0,16" Foreground="#9755E9"/><TextBlock Name="Status" TextWrapping="Wrap"/></StackPanel></Window>
'@
$window=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup))
$window.FindName('Version').Text='Updating to Version '+$settings.Version
$window.FindName('Notes').Text=$settings.Notes
$script:started=$false;$script:updating=$true
$window.Add_Closing({param($sender,$e) if($script:updating){$e.Cancel=$true}})
# Raise the update splash once; release topmost before processing the update.
$window.Add_Loaded({$window.Topmost=$true;[void]$window.Activate()})
$window.Add_ContentRendered({
 $window.Topmost=$false;[void]$window.Activate()
 if($script:started){return};$script:started=$true
 $download=Join-Path (Split-Path $Config) 'download.exe';$backup=$target+'.previous';$web=New-Object Net.WebClient
 try{
  [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
  $window.FindName('Status').Text='Downloading the new installer...';$window.FindName('Progress').IsIndeterminate=$true
  $web.Headers['User-Agent']='OptiShade-updater';$task=$web.DownloadFileTaskAsync($uri,$download);$clock=[Diagnostics.Stopwatch]::StartNew()
  while(-not $task.IsCompleted){if($clock.Elapsed.TotalMinutes -gt 15){$web.CancelAsync();throw 'Download timed out. Your existing installer is unchanged.'};$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background);Start-Sleep -Milliseconds 100}
  $task.GetAwaiter().GetResult()
  if(Get-Process FlightSimulator2024 -ErrorAction SilentlyContinue){throw 'Close Microsoft Flight Simulator 2024, then retry the update. No installed files were changed.'}
  if((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $settings.SHA256){throw 'Update verification failed. Your existing installer is unchanged.'}
  $window.FindName('Status').Text='Verified. Waiting for the previous installer to close...'
  $clock.Restart();$ready=$false
  while(-not $ready -and $clock.Elapsed.TotalSeconds -lt 45){try{$stream=[IO.File]::Open($target,'Open','ReadWrite','None');$stream.Dispose();$ready=$true}catch{Start-Sleep -Milliseconds 200;$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)}}
  if(-not $ready){throw 'The previous installer is still open or its folder is not writable. Close it and retry.'}
  # Same-volume replacement is atomic and leaves the previous EXE as a recovery copy.
  $staged=$target+'.updating';Copy-Item -LiteralPath $download -Destination $staged -Force
  if((Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash -ne $settings.SHA256){throw 'Staged update verification failed.'}
  [IO.File]::Replace($staged,$target,$backup,$true)
  $window.FindName('Status').Text='Updating installed game files and keeping your presets...'
  $job=Start-Process -FilePath $target -ArgumentList '--apply-update' -WindowStyle Hidden -PassThru
  while(-not $job.HasExited){$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background);Start-Sleep -Milliseconds 150;$job.Refresh()}
  if($job.ExitCode -ne 0){throw 'The installer was updated, but game-file updating stopped. Existing files were preserved or rolled back for the failed installation. See %LOCALAPPDATA%\OptiShade\Update-error.txt. Close this window and open setup to resolve it.'}
  $window.FindName('Progress').IsIndeterminate=$false;$window.FindName('Progress').Value=100
  $window.FindName('Status').Text='Update complete. Your installer and recorded game installations are up to date.'
  Start-Process -FilePath $target
  Remove-Item -LiteralPath $download -Force
  $script:updating=$false;$window.Close()
 }catch{$window.FindName('Progress').IsIndeterminate=$false;$window.FindName('Status').Text=$_.Exception.Message;$script:updating=$false}
 finally{$web.Dispose()}
})
[void]$window.ShowDialog()
