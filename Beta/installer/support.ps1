function ShowSupportDevelopment($Owner,[string]$Store){
 $marker=Join-Path $Store 'support-hidden.txt'
 if(Test-Path -LiteralPath $marker){return}
 [xml]$markup=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="Support OptiShade" Width="720" Height="620" WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True" WindowStartupLocation="CenterOwner" Background="Transparent" Foreground="#F3EFFB" FontFamily="Segoe UI">
 <Border Background="#100E17" BorderBrush="#40314F" BorderThickness="1" CornerRadius="20"><Grid>
 <Grid.RowDefinitions><RowDefinition Height="64"/><RowDefinition/><RowDefinition Height="84"/></Grid.RowDefinitions>
 <Border Name="DragHeader" Background="#17121F" CornerRadius="20,20,0,0" Cursor="SizeAll"><Grid Margin="28,0,16,0"><TextBlock Text="OPTISHADE  /  SUPPORT DEVELOPMENT" Foreground="#A499B6" FontSize="11" VerticalAlignment="Center"/><Button Name="HeaderClose" Content="&#x2715;" Background="Transparent" HorizontalAlignment="Right" Padding="14,10" Cursor="Hand" ToolTip="Close"/></Grid></Border>
 <Grid Grid.Row="1" Margin="30,24,30,0"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition/></Grid.RowDefinitions><TextBlock Name="Title" FontSize="26" FontWeight="SemiBold"/><TextBlock Grid.Row="1" Text="Optional support. OptiShade remains free." Foreground="#A499B6" Margin="0,8,0,22"/><Border Grid.Row="2" CornerRadius="12" Background="#1D1727" Padding="18"><TextBox Name="Notes" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Hidden" HorizontalScrollBarVisibility="Hidden" Background="Transparent" BorderThickness="0" Foreground="#DDD3EA" FontSize="13" Padding="0,0,12,0"/></Border></Grid>
 <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="30,0"><Button Name="Dismiss" Content="Don't show again" Margin="0,0,12,0"/><Button Name="Close" Content="Close" Margin="0,0,12,0"/><Button Name="Continue" Content="Continue" Background="#8650C8"/></StackPanel>
 </Grid></Border>
</Window>
'@
 $dialog=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup));$dialog.Owner=$Owner
 [xml]$theme=Get-Content "$PSScriptRoot/dialog-theme.xaml" -Raw; $dialog.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($theme)))
 $dialog.FindName('Title').Text='Thank you for supporting OptiShade'
 $dialog.FindName('Notes').Text=@"
Thank you to everyone who has downloaded OptiShade, shared feedback or sent in a bug report. Your support helps me make the app better, and I appreciate every one of you.

If you'd like to support development, select Continue to visit Buy Me a Coffee. You're just as welcome to select Close, or Don't show again to hide this support button.

Donations are entirely optional. Whether you donate or not, my commitment to improving OptiShade stays the same. OptiShade will always be 100% free.

Thank you for being part of the community - and for taking a moment to read this.

Gravy
"@
 $dialog.FindName('Continue').Add_Click({
  try{Start-Process 'https://buymeacoffee.com/GamingWithGravy' -ErrorAction Stop;$dialog.Close()}
  catch{[void](ShowOptiShadeDialog ($dialog) ('Could not open your browser. Visit https://buymeacoffee.com/GamingWithGravy') ('Support OptiShade'))}
 })
 $dialog.FindName('Dismiss').Add_Click({
  try{New-Item -ItemType Directory -Path $Store -Force -ErrorAction Stop|Out-Null;Set-Content -LiteralPath $marker -Value 'hidden' -ErrorAction Stop;$dialog.Close()}
  catch{[void](ShowOptiShadeDialog ($dialog) ('Could not save your preference. Please try again.') ('Support OptiShade'))}
 })
 $dialog.FindName('Close').Add_Click({$dialog.Close()})
 $dialog.FindName('HeaderClose').Add_Click({$dialog.Close()})
 $dialog.FindName('DragHeader').Add_MouseLeftButtonDown({if($_.ChangedButton -eq 'Left'){$dialog.DragMove()}})
 [void]$dialog.ShowDialog()
}

function ShowDiagnosticSavedDialog($Owner,[string]$FilePath){
 [xml]$markup=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="Diagnostics saved" Width="680" SizeToContent="Height" WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True" WindowStartupLocation="CenterOwner" Background="Transparent" Foreground="#F3EFFB" FontFamily="Segoe UI">
 <Border Background="#100E17" BorderBrush="#40314F" BorderThickness="1" CornerRadius="20" Padding="28"><StackPanel>
 <TextBlock Text="Diagnostics saved in the OptiShade app-data folder" FontSize="24" FontWeight="SemiBold"/>
 <TextBox Name="SavedPath" IsReadOnly="True" TextWrapping="Wrap" Background="#1D1727" Foreground="#F3EFFB" BorderThickness="0" Padding="12" Margin="0,20,0,16"/>
 <TextBlock Text="Review the ZIP, then share it in the diagnostic zips channel in BlackBox Discord. Nothing has been uploaded automatically." TextWrapping="Wrap" Foreground="#AA9CB9"/>
 <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,22,0,0"><Button Name="OpenLocation" Content="Open file location" Background="#8650C8" Margin="0,0,12,0"/><Button Name="Close" Content="Close" IsCancel="True"/></StackPanel>
 </StackPanel></Border>
</Window>
'@
 $dialog=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup));$dialog.Owner=$Owner
 [xml]$theme=Get-Content "$PSScriptRoot/dialog-theme.xaml" -Raw
 $dialog.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($theme)))
 $dialog.FindName('SavedPath').Text=$FilePath
 $dialog.FindName('OpenLocation').Add_Click({
  try{Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList ('/select,"'+$FilePath+'"') -ErrorAction Stop}
  catch{[void](ShowOptiShadeDialog ($dialog) ('Could not open File Explorer. Your ZIP is saved at: '+$FilePath) ('Diagnostics saved'))}
 })
 $dialog.FindName('Close').Add_Click({$dialog.Close()})
 [void]$dialog.ShowDialog()
}

function ShowDiagnosticIssueDialog($Owner){
 [xml]$markup=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="Export diagnostics" Width="680" Height="510" WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True" WindowStartupLocation="CenterOwner" Background="Transparent" Foreground="#F3EFFB" FontFamily="Segoe UI">
 <Border Background="#100E17" BorderBrush="#40314F" BorderThickness="1" CornerRadius="20" Padding="28"><Grid>
 <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
 <TextBlock Text="Export diagnostics" FontSize="26" FontWeight="SemiBold"/>
 <TextBlock Grid.Row="1" Text="Describe the issue" Foreground="#D4B7F9" Margin="0,20,0,10"/>
 <TextBox Name="Issue" Grid.Row="2" AcceptsReturn="True" TextWrapping="Wrap" MaxLength="12000" VerticalScrollBarVisibility="Hidden" Background="#1D1727" Foreground="#F3EFFB" CaretBrush="#F3EFFB" BorderBrush="#694982" Padding="12" FontSize="14"/>
 <TextBlock Grid.Row="3" Text="Include what happened and how to reproduce it. Your description is saved in the ZIP. Review it before posting in diagnostic zips in BlackBox Discord. Nothing is uploaded automatically." TextWrapping="Wrap" Foreground="#AA9CB9" Margin="0,12,0,18"/>
 <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right"><Button Name="Close" Content="Close" IsCancel="True" Margin="0,0,12,0"/><Button Name="Export" Content="Export" Background="#8650C8" IsEnabled="False"/></StackPanel>
 </Grid></Border>
</Window>
'@
 $dialog=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup));$dialog.Owner=$Owner
 [xml]$theme=Get-Content "$PSScriptRoot/dialog-theme.xaml" -Raw
 $dialog.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($theme)))
 $dialog.FindName('Issue').Add_TextChanged({$dialog.FindName('Export').IsEnabled=-not [string]::IsNullOrWhiteSpace($dialog.FindName('Issue').Text)})
 $dialog.FindName('Export').Add_Click({$dialog.DialogResult=$true})
 $dialog.FindName('Close').Add_Click({$dialog.DialogResult=$false})
 $dialog.Add_ContentRendered({[void]$dialog.FindName('Issue').Focus()})
 if($dialog.ShowDialog() -eq $true){return $dialog.FindName('Issue').Text}
 return $null
}

# Settings > Remove OptiShade from all games: the app stays installed.
function ShowRemoveFromGamesOptions($Owner){
 [xml]$markup=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="Remove OptiShade from all games" Width="640" SizeToContent="Height" WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True" WindowStartupLocation="CenterOwner" Background="Transparent" Foreground="#F3EFFB" FontFamily="Segoe UI">
 <Border Background="#100E17" BorderBrush="#40314F" BorderThickness="1" CornerRadius="20" Padding="28"><StackPanel>
 <TextBlock Text="Remove OptiShade from all games" FontSize="26" FontWeight="SemiBold" TextWrapping="Wrap"/>
 <TextBlock Text="Restores the original files in every game OptiShade was installed into. The OptiShade app stays on this PC, so you can add it back to any game later." Foreground="#AA9CB9" Margin="0,12,0,20" TextWrapping="Wrap"/>
 <Border Background="#1D1727" CornerRadius="12" Padding="18"><StackPanel>
 <CheckBox Name="KeepPresets" Content="Keep my saved looks (INI presets)" IsChecked="True" Margin="0,0,0,14"/>
 <CheckBox Name="KeepSnapshots" Content="Keep my snapshots" IsChecked="True"/>
 </StackPanel></Border>
 <TextBlock Text="Only games with an OptiShade installation record are restored. Game saves, controls and game settings are not changed." Foreground="#8F819E" FontSize="12" Margin="0,14,0,0" TextWrapping="Wrap"/>
 <TextBlock Name="Warning" Visibility="Collapsed" Text="Your saved looks and snapshots will be deleted. Are you sure?" TextWrapping="Wrap" Foreground="#FF8799" FontWeight="SemiBold" Margin="0,12,0,8"/>
 <CheckBox Name="Confirm" Visibility="Collapsed" Content="Yes, delete my saved looks and snapshots"/>
 <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0"><Button Name="Cancel" Content="Cancel" Background="#282238" IsCancel="True" Margin="0,0,12,0"/><Button Name="Remove" Content="Remove from all games" Background="#8650C8"/></StackPanel>
 </StackPanel></Border>
</Window>
'@
 $dialog=NewOptiShadeUninstallDialog $Owner $markup
 $refresh={
  $danger=-not $dialog.FindName('KeepPresets').IsChecked -and -not $dialog.FindName('KeepSnapshots').IsChecked
  foreach($name in 'Warning','Confirm'){$dialog.FindName($name).Visibility=if($danger){'Visible'}else{'Collapsed'}}
  if(-not $danger){$dialog.FindName('Confirm').IsChecked=$false}
  $dialog.FindName('Remove').IsEnabled=-not $danger -or [bool]$dialog.FindName('Confirm').IsChecked
 }
 foreach($name in 'KeepPresets','KeepSnapshots','Confirm'){$dialog.FindName($name).Add_Checked($refresh);$dialog.FindName($name).Add_Unchecked($refresh)}
 $dialog.FindName('Cancel').Add_Click({$dialog.Close()})
 $dialog.FindName('Remove').Add_Click({$dialog.Tag=@{KeepPresets=[bool]$dialog.FindName('KeepPresets').IsChecked;Snapshots=-not [bool]$dialog.FindName('KeepSnapshots').IsChecked};$dialog.DialogResult=$true})
 &$refresh
 if($dialog.ShowDialog()){return $dialog.Tag}
 return $null
}

# Settings > Uninstall OptiShade from this system, and Uninstall.exe. Restores every
# game, removes the app and its data, and optionally sends the user's reason.
function ShowOptiShadeUninstallPage($Owner){
 [xml]$markup=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="Uninstall OptiShade" Width="760" SizeToContent="Height" WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True" WindowStartupLocation="CenterOwner" Background="Transparent" Foreground="#F3EFFB" FontFamily="Segoe UI" ShowInTaskbar="True">
 <Border Background="#100E17" BorderBrush="#40314F" BorderThickness="1" CornerRadius="20" Padding="30,26"><StackPanel>
 <TextBlock Text="Uninstall OptiShade" FontSize="28" FontWeight="SemiBold"/>
 <TextBlock Text="Restores the original files in every game OptiShade was installed into, then removes the OptiShade app and its data from this PC." Foreground="#AA9CB9" Margin="0,10,0,18" TextWrapping="Wrap"/>
 <TextBlock Text="WHAT TO REMOVE" FontSize="12" FontWeight="SemiBold" Foreground="#9E86C4" Margin="2,0,0,8"/>
 <Border Background="#1D1727" CornerRadius="12" Padding="18"><StackPanel>
 <CheckBox Name="Everything" Content="Remove everything, including my saved looks and snapshots" Margin="0,0,0,16"/>
 <CheckBox Name="KeepPresets" Content="Keep my saved looks (INI presets) in each game's OptiShadeData folder" IsChecked="True" Margin="0,0,0,12"/>
 <CheckBox Name="KeepSnapshots" Content="Keep my snapshots" IsChecked="True"/>
 </StackPanel></Border>
 <TextBlock Name="Warning" Visibility="Collapsed" Text="Your saved looks and snapshots will be deleted too. Are you sure?" TextWrapping="Wrap" Foreground="#FF8799" FontWeight="SemiBold" Margin="0,12,0,8"/>
 <CheckBox Name="Confirm" Visibility="Collapsed" Content="Yes, delete my saved looks and snapshots"/>
 <TextBlock Text="WHY ARE YOU UNINSTALLING? (OPTIONAL)" FontSize="12" FontWeight="SemiBold" Foreground="#9E86C4" Margin="2,22,0,8"/>
 <Border Background="#1D1727" CornerRadius="12" Padding="18"><StackPanel>
 <WrapPanel Name="Reasons" Margin="0,0,0,10"/>
 <Grid>
  <TextBox Name="ReasonText" MinHeight="78" MaxHeight="140" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" MaxLength="1000" Background="#282238" Foreground="#F3EFFB" BorderBrush="#5E3E86" CaretBrush="#F3EFFB" Padding="10,8" FontSize="13"/>
  <TextBlock Name="ReasonHint" Text="Tell us more, if you like: what went wrong, which game, what you expected..." Foreground="#8F819E" FontSize="13" Margin="13,9,0,0" IsHitTestVisible="False" TextWrapping="Wrap"/>
 </Grid>
 <TextBlock Text="If you pick a reason or write something, it is sent privately to the OptiShade developer with your OptiShade version. Nothing else is sent, and nothing is sent if you leave this empty." Foreground="#8F819E" FontSize="12" Margin="0,10,0,0" TextWrapping="Wrap"/>
 </StackPanel></Border>
 <TextBlock Text="Only games with an OptiShade installation record are restored. Game saves, controls and game settings are not changed." Foreground="#8F819E" FontSize="12" Margin="2,14,0,0" TextWrapping="Wrap"/>
 <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0"><Button Name="Cancel" Content="Cancel" Background="#282238" IsCancel="True" Margin="0,0,12,0"/><Button Name="Remove" Content="Uninstall OptiShade" Background="#A83F5C"/></StackPanel>
 </StackPanel></Border>
</Window>
'@
 $dialog=NewOptiShadeUninstallDialog $Owner $markup
 $reasons=$dialog.FindName('Reasons');$reasons.Tag=''
 foreach($text in 'Lower FPS or stutter','Crashes or freezes',"Didn't work with my game",'Too complicated to use','Only trying it out','Something else'){
  $chip=[Windows.Controls.Primitives.ToggleButton]::new();$chip.Content=$text;$chip.Margin='0,0,8,8';$chip.Padding='12,6';$chip.Cursor='Hand'
  $chip.Background=[Windows.Media.BrushConverter]::new().ConvertFrom('#282238');$chip.Foreground=[Windows.Media.Brushes]::White;$chip.BorderBrush=[Windows.Media.BrushConverter]::new().ConvertFrom('#5E3E86')
  $chip.Template=[Windows.Markup.XamlReader]::Parse('<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="ToggleButton"><Border Name="Chip" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="14" Padding="{TemplateBinding Padding}"><ContentPresenter/></Border><ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True"><Setter TargetName="Chip" Property="Background" Value="#5A2BA8"/><Setter TargetName="Chip" Property="BorderBrush" Value="#D4B7F9"/></Trigger><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Chip" Property="BorderBrush" Value="#B48CE8"/></Trigger></ControlTemplate.Triggers></ControlTemplate>')
  # One reason at a time; pressing the chosen one again clears it.
  $chip.Add_Click({param($sender,$eventArgs) foreach($other in $reasons.Children){if($other -ne $sender){$other.IsChecked=$false}};$reasons.Tag=if($sender.IsChecked){[string]$sender.Content}else{''}}.GetNewClosure())
  [void]$reasons.Children.Add($chip)
 }
 $text=$dialog.FindName('ReasonText');$hint=$dialog.FindName('ReasonHint')
 $text.Add_TextChanged({$hint.Visibility=if($text.Text){'Collapsed'}else{'Visible'}}.GetNewClosure())
 $refresh={
  $all=[bool]$dialog.FindName('Everything').IsChecked
  foreach($name in 'KeepPresets','KeepSnapshots'){$dialog.FindName($name).IsEnabled=-not $all;if($all){$dialog.FindName($name).IsChecked=$false}}
  $danger=$all -or (-not $dialog.FindName('KeepPresets').IsChecked -and -not $dialog.FindName('KeepSnapshots').IsChecked)
  foreach($name in 'Warning','Confirm'){$dialog.FindName($name).Visibility=if($danger){'Visible'}else{'Collapsed'}}
  if(-not $danger){$dialog.FindName('Confirm').IsChecked=$false}
  $dialog.FindName('Remove').IsEnabled=-not $danger -or [bool]$dialog.FindName('Confirm').IsChecked
 }
 $dialog.FindName('Everything').Add_Unchecked({foreach($name in 'KeepPresets','KeepSnapshots'){$dialog.FindName($name).IsChecked=$true}})
 foreach($name in 'Everything','KeepPresets','KeepSnapshots','Confirm'){$dialog.FindName($name).Add_Checked($refresh);$dialog.FindName($name).Add_Unchecked($refresh)}
 $dialog.FindName('Cancel').Add_Click({$dialog.Close()})
 $dialog.FindName('Remove').Add_Click({
  $dialog.Tag=@{AppFiles=$true;IniFiles=-not [bool]$dialog.FindName('KeepPresets').IsChecked;Snapshots=-not [bool]$dialog.FindName('KeepSnapshots').IsChecked;ReasonChoice=[string]$dialog.FindName('Reasons').Tag;ReasonText=([string]$text.Text).Trim()}
  $dialog.DialogResult=$true
 })
 &$refresh
 if($dialog.ShowDialog()){return $dialog.Tag}
 return $null
}

# Shared look for both uninstall dialogs: the manager's switch style when the
# owner has it, and the dialog theme.
function NewOptiShadeUninstallDialog($Owner,[xml]$Markup){
 $dialog=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($Markup))
 if($Owner -and $Owner.IsLoaded){$dialog.Owner=$Owner}else{$dialog.WindowStartupLocation='CenterScreen'}
 try{$switch=$Owner.FindResource('OptiShadeSwitch');if($switch){$dialog.Resources.Add([Windows.Controls.CheckBox],$switch)}}catch{}
 [xml]$theme=Get-Content "$PSScriptRoot/dialog-theme.xaml" -Raw;$dialog.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($theme)))
 $dialog.Add_MouseLeftButtonDown({param($sender,$eventArgs) if($eventArgs.ChangedButton -eq 'Left' -and $eventArgs.OriginalSource -isnot [Windows.Controls.TextBox]){try{$dialog.DragMove()}catch{}}}.GetNewClosure())
 return $dialog
}

# Sends the optional uninstall reason through the Troubleshooter's private
# report upload. Returns the process, or $null when there is nothing to send.
function StartOptiShadeUninstallFeedback($Choice,[string]$Version,[string]$Scope){
 if(-not $Choice -or (-not $Choice.ReasonChoice -and -not $Choice.ReasonText)){return $null}
 $tool=Join-Path $PSScriptRoot 'OptiShade-Troubleshooter.exe'
 if(-not(Test-Path -LiteralPath $tool -PathType Leaf)){WriteInstallerLog 'Uninstall feedback not sent: the Troubleshooter is missing.';return $null}
 $request=Join-Path ([IO.Path]::GetTempPath()) ('optishade-uninstall-feedback-'+[guid]::NewGuid().ToString('N')+'.json')
 $body=[ordered]@{Schema=1;Version=$Version;Scope=$Scope;Reason=[string]$Choice.ReasonChoice;Text=[string]$Choice.ReasonText;KeptPresets=-not $Choice.IniFiles;KeptSnapshots=-not $Choice.Snapshots}
 [IO.File]::WriteAllText($request,($body|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
 try{return [pscustomobject]@{Process=(Start-Process -FilePath $tool -ArgumentList @('--uninstall-feedback',('"'+$request+'"')) -WindowStyle Hidden -PassThru -ErrorAction Stop);Request=$request}}
 catch{WriteInstallerLog ('Uninstall feedback could not start: '+$_.Exception.Message);Remove-Item -LiteralPath $request -Force -ErrorAction SilentlyContinue;return $null}
}
# Waits for the send so nothing is left running from OptiShade's folders once the
# app is removed; a send that is still going after the limit is stopped.
function WaitOptiShadeUninstallFeedback($Feedback,[int]$Seconds=30){
 if(-not $Feedback -or -not $Feedback.Process){return}
 try{
  if(-not $Feedback.Process.WaitForExit($Seconds*1000)){try{$Feedback.Process.Kill()}catch{};WriteInstallerLog 'Uninstall feedback was not sent in time and was stopped.'}
  elseif($Feedback.Process.ExitCode -ne 0){WriteInstallerLog 'Uninstall feedback could not be sent.'}else{WriteInstallerLog 'Uninstall feedback sent.'}
 }catch{}
 Remove-Item -LiteralPath $Feedback.Request -Force -ErrorAction SilentlyContinue
}
