param([string]$Config)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
. "$PSScriptRoot/operation-progress-store.ps1"
$settings=Get-Content -LiteralPath $Config -Raw -Encoding UTF8|ConvertFrom-Json
[xml]$markup=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="OptiShade operation" Width="560" MinHeight="270" SizeToContent="Height" MinWidth="480" MaxWidth="680" ResizeMode="NoResize" WindowStyle="None" ShowInTaskbar="True" ShowActivated="True" Topmost="False" WindowStartupLocation="CenterScreen" Background="#100F1D" Foreground="#F3EFFB" FontFamily="Segoe UI" FontSize="14">
 <Border Background="#171420" BorderBrush="#7546A8" BorderThickness="1" CornerRadius="10" Padding="22" Margin="1"><Grid>
  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <Grid Name="TitleBar"><TextBlock Name="OperationTitle" FontSize="20" FontWeight="SemiBold" Foreground="#EDE3FA" TextWrapping="Wrap" VerticalAlignment="Center"/></Grid>
  <TextBlock Name="OperationDetail" Grid.Row="1" Margin="0,16,0,0" FontSize="14" Foreground="#C0AEDF" TextWrapping="Wrap" MinHeight="44"/>
  <ProgressBar Name="OperationProgress" Grid.Row="2" Margin="0,18,0,0" Height="9" Minimum="0" Maximum="100" IsIndeterminate="True" Foreground="#9755E9" Background="#332246" BorderThickness="0"/>
  <TextBlock Name="OperationFooter" Grid.Row="3" Margin="0,13,0,0" Text="The progress display runs separately so it can keep updating while files are being processed." FontSize="12" Foreground="#A99ABF" TextWrapping="Wrap"/>
  <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
   <Button Name="CancelOperation" Content="Cancel" Padding="16,7" Margin="0,0,8,0" Visibility="Collapsed" Background="#30263E" Foreground="#F3EFFB" BorderBrush="#7546A8"/>
   <Button Name="Dismiss" Content="Dismiss" Padding="16,7" Visibility="Collapsed" Background="#30263E" Foreground="#F3EFFB" BorderBrush="#7546A8"/>
  </StackPanel>
 </Grid></Border>
</Window>
'@
$window=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup))
$window.FindName('OperationTitle').Text=[string]$settings.Title
$script:terminal=$false
$script:terminalAt=$null
$script:terminalStatus=''
$window.FindName('Dismiss').Add_Click({$window.Close()})
# Live footer: elapsed time and how long since the last step report, so a long
# step never looks like a frozen box.
$script:startedAt=[DateTime]::UtcNow
$script:lastDetail='';$script:lastChangeAt=[DateTime]::UtcNow
$script:cancelRequested=$false
$cancelPath=if($settings.PSObject.Properties['CancelPath']){[string]$settings.CancelPath}else{''}
if($cancelPath){$window.FindName('CancelOperation').Visibility='Visible'}
$window.FindName('CancelOperation').Add_Click({
 if($script:cancelRequested -or $script:terminal){return}
 try{[IO.File]::WriteAllText($cancelPath,[DateTime]::UtcNow.ToString('o'));$script:cancelRequested=$true}catch{return}
 $button=$window.FindName('CancelOperation');$button.Content='Cancelling...';$button.Opacity=0.7
})
function FormatElapsed([TimeSpan]$Span){if($Span.TotalHours -ge 1){return $Span.ToString('h\:mm\:ss')};return $Span.ToString('m\:ss')}
$timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(250)
$timer.Add_Tick({
 try{
  if(Test-Path -LiteralPath $settings.ProgressPath){
   $state=(ReadOptiShadeOperationProgressState $settings.ProgressPath)|ConvertFrom-Json
   if($state.Status -eq 'AwaitingConsent'){$window.Hide()}elseif(-not $window.IsVisible){$window.Show()}
   if($state.Title){$window.FindName('OperationTitle').Text=[string]$state.Title}
   if($state.Detail){$window.FindName('OperationDetail').Text=[string]$state.Detail}
   if([string]$state.Detail -cne $script:lastDetail){$script:lastDetail=[string]$state.Detail;$script:lastChangeAt=[DateTime]::UtcNow}
   $bar=$window.FindName('OperationProgress')
   if([int]$state.Total -gt 0){$bar.IsIndeterminate=$false;$bar.Maximum=[Math]::Max(1,[int]$state.Total);$bar.Value=[Math]::Min([int]$state.Completed,$bar.Maximum)}else{$bar.IsIndeterminate=$true}
   if($state.Status -eq 'Running'){
    $now=[DateTime]::UtcNow;$step=if([int]$state.Total -gt 0){'Step '+[Math]::Min([int]$state.Completed,[int]$state.Total)+' of '+[int]$state.Total+' · '}else{''}
    $quiet=($now-$script:lastChangeAt).TotalSeconds
    $footer=$step+'Elapsed '+(FormatElapsed ($now-$script:startedAt))+$(if($quiet -ge 5){' · this step has been running '+[int]$quiet+' s, still working'}else{''})
    if($script:cancelRequested){$footer+=' · Cancel requested: stopping at the next safe point. Files changed by the current step are finished or rolled back.'}
    $window.FindName('OperationFooter').Text=$footer
   }
  if($state.Status -in @('Completed','Failed','Attention','Cancelled')){
    if(-not $script:terminal){$script:terminal=$true;$script:terminalAt=[DateTime]::UtcNow;$script:terminalStatus=[string]$state.Status}
   }
  }
 }catch{}
 if(-not $script:terminal){
  try{[void][Diagnostics.Process]::GetProcessById([int]$settings.ParentPid)}catch{$script:terminal=$true;$script:terminalAt=[DateTime]::UtcNow;$script:terminalStatus='Failed';$window.FindName('OperationDetail').Text='The manager closed before it reported that this operation finished.'}
 }
 if($script:terminal){
  $window.FindName('OperationProgress').IsIndeterminate=$false
  $window.FindName('CancelOperation').Visibility='Collapsed'
  if($script:terminalStatus -eq 'Cancelled'){$window.FindName('OperationTitle').Text='CANCELLED — '+[string]$settings.Title;$window.FindName('OperationProgress').Foreground='#FFBE83';$window.FindName('OperationFooter').Text='Cancelled. Steps that had started were finished or rolled back; nothing else was changed.';$window.FindName('Dismiss').Visibility='Visible'}
  elseif($script:terminalStatus -eq 'Completed'){$window.FindName('OperationProgress').Value=100;$window.FindName('OperationFooter').Text='Completed successfully. This window will close shortly.'}elseif($script:terminalStatus -eq 'Attention'){$window.FindName('OperationTitle').Text='COMPLETED WITH ISSUES — '+[string]$settings.Title;$window.FindName('OperationProgress').Foreground='#FFBE83';$window.FindName('OperationFooter').Text='Some steps need attention. Review the details and manager results, then dismiss this window.';$window.FindName('Dismiss').Visibility='Visible'}else{$window.FindName('OperationTitle').Text='FAILED — '+[string]$settings.Title;$window.FindName('OperationProgress').Foreground='#FFBE83';$window.FindName('OperationFooter').Text='FAILED. Review the error above and the manager refreshed component statuses.';$window.FindName('Dismiss').Visibility='Visible'}
  if($script:terminalStatus -eq 'Completed' -and ([DateTime]::UtcNow-$script:terminalAt).TotalSeconds -ge 1.5){$window.Close()}
 }
})
$window.FindName('TitleBar').Add_MouseLeftButtonDown({param($sender,$event) if($event.ChangedButton -eq 'Left'){$window.DragMove()}})
$window.Add_Closing({param($sender,$event) if(-not $script:terminal){$event.Cancel=$true}})
$window.Add_ContentRendered({[void]$window.Activate()})
$timer.Start()
# A modal ShowDialog returns when hidden for consent. Keep the worker dispatcher
# alive until the progress window actually closes, so it can resume afterwards.
$frame=[Windows.Threading.DispatcherFrame]::new()
$window.Add_Closed({$frame.Continue=$false}.GetNewClosure())
try{$window.Show();[Windows.Threading.Dispatcher]::PushFrame($frame)}finally{$timer.Stop();$timer=$null}
