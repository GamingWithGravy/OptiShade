function ShowReleaseNotes($Owner,[string]$Store){
 $version='0.20.4';$marker=Join-Path $Store 'release-notes-dismissed.txt'
 if((Test-Path -LiteralPath $marker) -and (Get-Content -LiteralPath $marker -Raw).Trim() -eq $version){return}
 [xml]$markup=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="What's new in OptiShade" Width="720" Height="620" WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True" WindowStartupLocation="CenterOwner" Background="Transparent" Foreground="#F3EFFB" FontFamily="Segoe UI">
 <Border Background="#100E17" BorderBrush="#40314F" BorderThickness="1" CornerRadius="20"><Grid>
 <Grid.RowDefinitions><RowDefinition Height="64"/><RowDefinition/><RowDefinition Height="84"/></Grid.RowDefinitions>
 <Border Name="DragHeader" Background="#17121F" CornerRadius="20,20,0,0" Cursor="SizeAll"><Grid Margin="28,0,16,0"><TextBlock Text="OPTISHADE  /  RELEASE NOTES" Foreground="#A499B6" FontSize="11" VerticalAlignment="Center"/><Button Name="HeaderClose" Content="&#x2715;" Background="Transparent" HorizontalAlignment="Right" Padding="14,10" Cursor="Hand" ToolTip="Close"/></Grid></Border>
 <Grid Grid.Row="1" Margin="30,24,30,0"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition/></Grid.RowDefinitions><TextBlock Name="Title" FontSize="26" FontWeight="SemiBold"/><TextBlock Grid.Row="1" Text="The latest changes, ready when you are." Foreground="#A499B6" Margin="0,8,0,22"/><Border Grid.Row="2" CornerRadius="12" Background="#1D1727" Padding="18"><TextBox Name="Notes" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Background="Transparent" BorderThickness="0" Foreground="#DDD3EA" FontSize="13" Padding="0,0,12,0"/></Border></Grid>
 <Grid Grid.Row="2" Margin="30,0"><CheckBox Name="Dismiss" Content="Do not show again for this version" VerticalAlignment="Center"/><Button Name="Close" Content="Got it" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid>
 </Grid></Border>
</Window>
'@
 $dialog=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup));$dialog.Owner=$Owner
 [xml]$theme=Get-Content "$PSScriptRoot/dialog-theme.xaml" -Raw; $dialog.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($theme)))
 $dialog.FindName('Title').Text="What's new in OptiShade $version"
 $dialog.FindName('Notes').Text=Get-Content -LiteralPath "$PSScriptRoot/Help/Release-notes.txt" -Raw -Encoding UTF8
 $dialog.FindName('Close').Add_Click({$dialog.Close()})
 $dialog.FindName('HeaderClose').Add_Click({$dialog.Close()})
 $dialog.FindName('DragHeader').Add_MouseLeftButtonDown({if($_.ChangedButton -eq 'Left'){$dialog.DragMove()}})
 $dialog.Add_Closing({if($dialog.FindName('Dismiss').IsChecked){New-Item -ItemType Directory -Path $Store -Force|Out-Null;Set-Content -LiteralPath $marker -Value $version}})
 [void]$dialog.ShowDialog()
}
