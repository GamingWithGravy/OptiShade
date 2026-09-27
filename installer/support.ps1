function ShowSupportDevelopment($Owner,[string]$Store){
 $marker=Join-Path $Store 'support-hidden.txt'
 if(Test-Path -LiteralPath $marker){return}
 [xml]$markup=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="Support OptiShade" Width="720" Height="620" WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True" WindowStartupLocation="CenterOwner" Background="Transparent" Foreground="#F3EFFB" FontFamily="Segoe UI">
 <Border Background="#100E17" BorderBrush="#40314F" BorderThickness="1" CornerRadius="20"><Grid>
 <Grid.RowDefinitions><RowDefinition Height="64"/><RowDefinition/><RowDefinition Height="84"/></Grid.RowDefinitions>
 <Border Name="DragHeader" Background="#17121F" CornerRadius="20,20,0,0" Cursor="SizeAll"><Grid Margin="28,0,16,0"><TextBlock Text="OPTISHADE  /  SUPPORT DEVELOPMENT" Foreground="#A499B6" FontSize="11" VerticalAlignment="Center"/><Button Name="HeaderClose" Content="&#x2715;" Background="Transparent" HorizontalAlignment="Right" Padding="14,10" Cursor="Hand" ToolTip="Close"/></Grid></Border>
 <Grid Grid.Row="1" Margin="30,24,30,0"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition/></Grid.RowDefinitions><TextBlock Name="Title" FontSize="26" FontWeight="SemiBold"/><TextBlock Grid.Row="1" Text="Optional support. OptiShade remains free." Foreground="#A499B6" Margin="0,8,0,22"/><Border Grid.Row="2" CornerRadius="12" Background="#1D1727" Padding="18"><TextBox Name="Notes" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Background="Transparent" BorderThickness="0" Foreground="#DDD3EA" FontSize="13" Padding="0,0,12,0"/></Border></Grid>
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
  catch{[void][Windows.MessageBox]::Show($dialog,'Could not open your browser. Visit https://buymeacoffee.com/GamingWithGravy','Support OptiShade')}
 })
 $dialog.FindName('Dismiss').Add_Click({
  try{New-Item -ItemType Directory -Path $Store -Force -ErrorAction Stop|Out-Null;Set-Content -LiteralPath $marker -Value 'hidden' -ErrorAction Stop;$dialog.Close()}
  catch{[void][Windows.MessageBox]::Show($dialog,'Could not save your preference. Please try again.','Support OptiShade')}
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
 <TextBlock Text="Diagnostics saved to your Desktop" FontSize="24" FontWeight="SemiBold"/>
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
  catch{[void][Windows.MessageBox]::Show($dialog,'Could not open File Explorer. Your ZIP is saved at: '+$FilePath,'Diagnostics saved')}
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
 <TextBox Name="Issue" Grid.Row="2" AcceptsReturn="True" TextWrapping="Wrap" MaxLength="12000" VerticalScrollBarVisibility="Auto" Background="#1D1727" Foreground="#F3EFFB" CaretBrush="#F3EFFB" BorderBrush="#694982" Padding="12" FontSize="14"/>
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

function ShowUninstallOptions($Owner){
 [xml]$markup=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="Uninstall OptiShade" Width="640" SizeToContent="Height" WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True" WindowStartupLocation="CenterOwner" Background="Transparent" Foreground="#F3EFFB" FontFamily="Segoe UI">
 <Border Background="#100E17" BorderBrush="#40314F" BorderThickness="1" CornerRadius="20" Padding="28"><StackPanel>
 <TextBlock Text="Uninstall OptiShade" FontSize="26" FontWeight="SemiBold"/>
 <TextBlock Text="Choose what to remove from your recorded installations." Foreground="#AA9CB9" Margin="0,12,0,20" TextWrapping="Wrap"/>
 <Border Background="#1D1727" CornerRadius="12" Padding="18"><StackPanel>
 <CheckBox Name="Everything" Content="Remove everything" Margin="0,0,0,20"/>
 <CheckBox Name="AppFiles" Content="Remove app files" IsChecked="True" Margin="0,0,0,14"/>
 <CheckBox Name="IniFiles" Content="Remove INI files" Margin="0,0,0,14"/>
 <CheckBox Name="Snapshots" Content="Remove snapshots"/>
 </StackPanel></Border>
 <TextBlock Text="INI removal covers saved presets in OptiShadeData/Presets. Snapshot removal covers recorded, unchanged OptiShade captures, across your recorded games. Other photos, game settings, controls and saves are kept. Your downloaded installer EXE is kept." TextWrapping="Wrap" Foreground="#AA9CB9" Margin="0,16,0,12"/>
 <TextBlock Name="Warning" Visibility="Collapsed" Text="This will remove your INI files and snapshots. Are you sure?" TextWrapping="Wrap" Foreground="#FF8799" FontWeight="SemiBold" Margin="0,8,0,10"/>
 <CheckBox Name="Confirm" Visibility="Collapsed" Content="Yes, remove my INI files and snapshots" Margin="0,0,0,12"/>
 <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0"><Button Name="Cancel" Content="Close" Background="#282238" IsCancel="True" Margin="0,0,12,0"/><Button Name="Remove" Content="Remove selected" Background="#8650C8"/></StackPanel>
 </StackPanel></Border>
</Window>
'@
 $dialog=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup));$dialog.Owner=$Owner
 [xml]$theme=Get-Content "$PSScriptRoot/dialog-theme.xaml" -Raw;$dialog.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($theme)))
 $refresh={
  $all=[bool]$dialog.FindName('Everything').IsChecked
  $danger=$all -or ($dialog.FindName('IniFiles').IsChecked -and $dialog.FindName('Snapshots').IsChecked)
  $dialog.FindName('Warning').Visibility=if($danger){'Visible'}else{'Collapsed'}
  $dialog.FindName('Confirm').Visibility=if($danger){'Visible'}else{'Collapsed'}
  $any=$all -or $dialog.FindName('AppFiles').IsChecked -or $dialog.FindName('IniFiles').IsChecked -or $dialog.FindName('Snapshots').IsChecked
  $dialog.FindName('Remove').IsEnabled=$any -and (-not $danger -or $dialog.FindName('Confirm').IsChecked)
 }
 $dialog.FindName('Everything').Add_Click({
  $all=[bool]$dialog.FindName('Everything').IsChecked
  foreach($name in @('AppFiles','IniFiles','Snapshots')){$dialog.FindName($name).IsChecked=$all;$dialog.FindName($name).IsEnabled=-not $all}
  $dialog.FindName('Confirm').IsChecked=$false;&$refresh
 })
 foreach($name in @('AppFiles','IniFiles','Snapshots','Confirm')){$dialog.FindName($name).Add_Click($refresh)}
 $dialog.FindName('Cancel').Add_Click({$dialog.Close()})
 $dialog.FindName('Remove').Add_Click({$dialog.Tag=@{AppFiles=[bool]$dialog.FindName('AppFiles').IsChecked;IniFiles=[bool]$dialog.FindName('IniFiles').IsChecked;Snapshots=[bool]$dialog.FindName('Snapshots').IsChecked};$dialog.DialogResult=$true})
 &$refresh
 if($dialog.ShowDialog()){return $dialog.Tag}
 return $null
}
