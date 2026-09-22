function ShowReleaseNotes($Owner,[string]$Store){
 $version='0.20.1';$marker=Join-Path $Store 'release-notes-dismissed.txt'
 if((Test-Path -LiteralPath $marker) -and (Get-Content -LiteralPath $marker -Raw).Trim() -eq $version){return}
 [xml]$markup=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="What's new in OptiShade" Width="660" Height="540" WindowStartupLocation="CenterOwner" Background="#171020" Foreground="#F3EFFB" FontFamily="Segoe UI"><Grid Margin="28"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition/><RowDefinition Height="Auto"/></Grid.RowDefinitions><TextBlock Name="Title" FontSize="26" Margin="0,0,0,18"/><TextBox Name="Notes" Grid.Row="1" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Background="#241B30" Foreground="#EAE1F6" Padding="16"/><StackPanel Grid.Row="2" Margin="0,18,0,0"><CheckBox Name="Dismiss" Content="Do not show again for this version" Foreground="#EAE1F6"/><Button Name="Close" Content="Close" HorizontalAlignment="Right" Padding="24,8" Margin="0,12,0,0"/></StackPanel></Grid></Window>
'@
 $dialog=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup));$dialog.Owner=$Owner
 $dialog.FindName('Title').Text="What's new in OptiShade $version"
 $dialog.FindName('Notes').Text=Get-Content -LiteralPath "$PSScriptRoot/Help/Release-notes.txt" -Raw -Encoding UTF8
 $dialog.FindName('Close').Add_Click({$dialog.Close()})
 $dialog.Add_Closing({if($dialog.FindName('Dismiss').IsChecked){New-Item -ItemType Directory -Path $Store -Force|Out-Null;Set-Content -LiteralPath $marker -Value $version}})
 [void]$dialog.ShowDialog()
}
