param([Parameter(Mandatory=$true)][string]$Config)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework
$settings=Get-Content -LiteralPath $Config -Raw -Encoding UTF8|ConvertFrom-Json
$target=[IO.Path]::GetFullPath($settings.Installer)
$uri=[uri]$settings.Url
if($uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com' -or $uri.AbsolutePath -cnotmatch '^/GamingWithGravy/(OptiShade|OptiShade_V0[.]19[.]17)/releases/download/' -or $settings.SHA256 -notmatch '^[a-fA-F0-9]{64}$' -or [IO.Path]::GetExtension($target) -ne '.exe'){throw 'Invalid update information.'}
[xml]$markup=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="OptiShade update" Width="700" Height="500" ResizeMode="NoResize" WindowStyle="None" AllowsTransparency="True" WindowStartupLocation="CenterScreen" Background="Transparent" Foreground="#F3EFFB" FontFamily="Segoe UI"><Border Background="#171020" BorderBrush="#40314F" BorderThickness="1" CornerRadius="20"><Grid><Border Name="DragHeader" Height="48" VerticalAlignment="Top" Background="Transparent" Cursor="SizeAll"/><Button Name="Close" Content="&#x2715;" HorizontalAlignment="Right" VerticalAlignment="Top" Background="Transparent" Margin="0,8,12,0" Padding="12,8" ToolTip="Close"/><StackPanel Margin="36" VerticalAlignment="Center"><TextBlock Text="Optishade" FontSize="48" FontWeight="SemiBold" HorizontalAlignment="Center"/><TextBlock Text="Microsoft Flight Simulator 2024" FontSize="22" Foreground="#BD9CEC" HorizontalAlignment="Center" Margin="0,8,0,24"/><TextBlock Name="Version" HorizontalAlignment="Center" Margin="0,0,0,16"/><TextBox Name="Notes" Visibility="Collapsed"/><TextBox Name="Status" Text="Updating..." IsReadOnly="True" TextWrapping="Wrap" TextAlignment="Center" Foreground="#C9B6DF" Background="Transparent" BorderThickness="0" MaxHeight="140" VerticalScrollBarVisibility="Auto"/><ProgressBar Name="Progress" Width="360" Height="7" Margin="0,24,0,0" Foreground="#9755E9" Background="#332246" Maximum="100" BorderThickness="0"/><StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,22,0,0"><Button Name="Launch" Content="Open manager" Visibility="Collapsed" Padding="26,10" Background="#8650C8" Foreground="White"/><Button Name="DoneClose" Content="Close" Visibility="Collapsed" Padding="26,10" Margin="12,0,0,0" Background="#282238"/></StackPanel><TextBlock Text="created by gravy" HorizontalAlignment="Center" Foreground="#8E829E" Margin="0,26,0,0"/></StackPanel></Grid></Border></Window>
'@
$window=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup))
[xml]$theme=Get-Content "$PSScriptRoot/dialog-theme.xaml" -Raw; $window.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($theme)))
$window.FindName('Close').Add_Click({$window.Close()})
$window.FindName('DoneClose').Add_Click({$window.Close()})
$window.FindName('DragHeader').Add_MouseLeftButtonDown({$window.DragMove()})
$window.FindName('Version').Text='Updating to Version '+$settings.Version
$window.FindName('Notes').Text=$settings.Notes
$script:started=$false;$script:updating=$true
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
$window.FindName('Launch').Add_Click({try{Start-Process -FilePath $target -WindowStyle Hidden;$window.Close()}catch{$window.FindName('Status').Text=$_.Exception.Message}})
$window.Add_Closing({param($sender,$e) if($script:updating){$e.Cancel=$true}})
# Raise the update splash once; release topmost before processing the update.
$window.Add_Loaded({$window.Topmost=$true;[void]$window.Activate()})
$window.Add_ContentRendered({
 $window.Topmost=$false;[void]$window.Activate()
 if($script:started){return};$script:started=$true
 $download=Join-Path (Split-Path $Config) 'download.exe';$backup=$target+'.previous';$web=New-Object Net.WebClient
 try{
  $space=@{}
  foreach($requirement in @(@{Path=(Split-Path $Config);Bytes=1GB},@{Path=(Split-Path $target);Bytes=512MB})){
   $drive=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($requirement.Path));$space[$drive]+=$requirement.Bytes
  }
  foreach($drive in $space.Keys){if(([IO.DriveInfo]::new($drive)).AvailableFreeSpace -lt $space[$drive]){throw "Not enough disk space on $drive. Free at least $([math]::Ceiling($space[$drive]/1MB)) MB for downloading and staging the update, then retry. No installed files were changed."}}
  [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
  $window.FindName('Status').Text='Downloading OptiShade Manager...';$window.FindName('Progress').IsIndeterminate=$true
  $web.Headers['User-Agent']='OptiShade-updater';$task=$web.DownloadFileTaskAsync($uri,$download);$clock=[Diagnostics.Stopwatch]::StartNew()
  while(-not $task.IsCompleted){if($clock.Elapsed.TotalMinutes -gt 15){$web.CancelAsync();throw 'Download timed out. Your existing manager is unchanged.'};$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background);Start-Sleep -Milliseconds 100}
  $task.GetAwaiter().GetResult()
  if(Get-Process FlightSimulator2024,FlightSimulator -ErrorAction SilentlyContinue){throw 'Close Microsoft Flight Simulator, then retry the update. No installed files were changed.'}
  if((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $settings.SHA256){throw 'Update verification failed. Your existing manager is unchanged.'}
  $window.FindName('Status').Text='Checking staged files and installation requirements...'
  $window.FindName('Progress').IsIndeterminate=$false;$window.FindName('Progress').Value=35
  RunUpdateStage $download '--check-update'
  $window.FindName('Status').Text='Verified. Waiting for the previous manager to close...'
  $clock.Restart();$ready=$false
  while(-not $ready -and $clock.Elapsed.TotalSeconds -lt 45){try{$stream=[IO.File]::Open($target,'Open','ReadWrite','None');$stream.Dispose();$ready=$true}catch{Start-Sleep -Milliseconds 200;$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)}}
  if(-not $ready){throw 'The previous manager is still open or its folder is not writable. Close it and retry.'}
  $window.FindName('Progress').Value=55
  # Same-volume replacement is atomic and leaves the previous EXE as a recovery copy.
  $staged=$target+'.updating';Copy-Item -LiteralPath $download -Destination $staged -Force
  if((Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash -ne $settings.SHA256){throw 'Staged update verification failed.'}
  [IO.File]::Replace($staged,$target,$backup,$true)
  $window.FindName('Status').Text='Updating installed game files and keeping your presets...'
  $window.FindName('Progress').Value=70
  RunUpdateStage $target '--apply-update'
  $window.FindName('Progress').IsIndeterminate=$false;$window.FindName('Progress').Value=100
  $window.FindName('Status').Text='Update complete. Your manager and recorded game installations are up to date.'
  Remove-Item -LiteralPath $download -Force
  if(Test-Path -LiteralPath $backup){try{Remove-Item -LiteralPath $backup -Force}catch{$window.FindName('Status').Text+=' The old installer recovery copy could not be removed: '+$backup}}
  $script:updating=$false;$window.FindName('Launch').Visibility='Visible';$window.FindName('DoneClose').Visibility='Visible'
 }catch{
  $window.FindName('Progress').IsIndeterminate=$false
  $window.FindName('Status').Text='Update stopped. '+$_.Exception.Message
  $script:updating=$false;$window.FindName('Launch').Content='Open manager';$window.FindName('Launch').Visibility='Visible';$window.FindName('DoneClose').Visibility='Visible'
  $_|Out-String|Set-Content -LiteralPath (Join-Path (Split-Path $Config) 'Update-error.txt') -Encoding UTF8
 }
 finally{$web.Dispose()}
})
[void]$window.ShowDialog()
