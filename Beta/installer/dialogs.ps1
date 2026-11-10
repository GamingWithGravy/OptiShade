function ShowOptiShadeDialog($Owner,[string]$Message,[string]$Title='OptiShade',[string]$Buttons='OK',[string]$Icon='Information',[string]$Default='None'){
 [xml]$x=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="OptiShade" Width="680" SizeToContent="Height" MaxHeight="800" WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" Foreground="#F3EFFB" FontSize="14" ShowInTaskbar="False">
 <Border Background="{DynamicResource WindowGlass}" BorderBrush="#55406C" BorderThickness="1" CornerRadius="10"><Grid Margin="28">
 <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
 <DockPanel Name="Drag" Margin="0,0,0,22"><Button Name="Dismiss" Content="✕" Background="Transparent" Padding="8" DockPanel.Dock="Right"/><TextBlock FontSize="22" FontWeight="SemiBold" VerticalAlignment="Center"><Run Text="O" Foreground="#AB70FF"/><Run Text="ptiShade"/></TextBlock></DockPanel>
 <TextBlock Name="Heading" Grid.Row="1" FontSize="25" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,0,0,16"/>
 <ScrollViewer Grid.Row="2" MaxHeight="440" VerticalScrollBarVisibility="Hidden" HorizontalScrollBarVisibility="Hidden"><TextBlock Name="Details" TextWrapping="Wrap" Foreground="#C0AEDF" FontSize="14" LineHeight="22"/></ScrollViewer>
 <StackPanel Name="Actions" Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,24,0,0"/>
 </Grid></Border>
</Window>
'@
 $dialog=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($x));$dialog.Owner=$Owner;$dialog.Title=$Title
 [xml]$theme=Get-Content "$PSScriptRoot/dialog-theme.xaml" -Raw -Encoding UTF8
 $dialog.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($theme)))
 $dialog.MaxHeight=[Math]::Min(800,[Windows.SystemParameters]::WorkArea.Height-24)
 $dialog.FindName('Heading').Text=$Title;$dialog.FindName('Details').Text=$Message
 $choices=switch($Buttons){'YesNo'{@('No','Yes')};'YesNoCancel'{@('Cancel','No','Yes')};'OKCancel'{@('Cancel','OK')};default{@('OK')}}
 $dialog.Tag=if('Cancel' -in $choices){'Cancel'}elseif('No' -in $choices){'No'}else{'OK'}
 foreach($choice in $choices){
  $button=[Windows.Controls.Button]::new();$button.Content=$choice;$button.Tag=$choice;$button.MinWidth=100;$button.Margin='10,0,0,0'
  if($choice -in @('No','Cancel')){$button.Background=[Windows.Media.BrushConverter]::new().ConvertFromString('#211D30')}
  $button.IsDefault=($choice -eq $Default -or ($Default -eq 'None' -and $choice -eq $choices[0]))
  $button.Add_Click({param($sender,$event) $dialog.Tag=[string]$sender.Tag;$dialog.Close()}.GetNewClosure())
  [void]$dialog.FindName('Actions').Children.Add($button)
 }
 $dialog.FindName('Dismiss').Add_Click({$dialog.Close()}.GetNewClosure())
 $dialog.FindName('Drag').Add_MouseLeftButtonDown({if($_.OriginalSource -is [Windows.Controls.TextBlock]){$dialog.DragMove()}}.GetNewClosure())
 $dialog.Add_PreviewKeyDown({param($sender,$event) if($event.Key -eq 'Escape'){$dialog.Close();$event.Handled=$true}}.GetNewClosure())
 $show={ $dialog.Topmost=$true;[void]$dialog.Activate();$dialog.ShowDialog() }.GetNewClosure()
 if(Get-Command InvokeWithOperationProgressHidden -ErrorAction SilentlyContinue){[void](InvokeWithOperationProgressHidden $show)}else{[void](& $show)};return [Enum]::Parse([Windows.MessageBoxResult],[string]$dialog.Tag)
}

# Asked when the main window is closed. Returns @{Choice='Tray'|'Exit'|'Cancel';Remember=$bool}.
function ShowOptiShadeCloseChoice($Owner){
 [xml]$x=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="Close OptiShade" Width="560" SizeToContent="Height" WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" Foreground="#F3EFFB" FontSize="14" ShowInTaskbar="False">
 <Border Background="{DynamicResource WindowGlass}" BorderBrush="#55406C" BorderThickness="1" CornerRadius="10"><Grid Margin="28">
 <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
 <DockPanel Name="Drag" Margin="0,0,0,20"><Button Name="Dismiss" Content="&#x2715;" Background="Transparent" Padding="8" DockPanel.Dock="Right"/><TextBlock FontSize="22" FontWeight="SemiBold" VerticalAlignment="Center"><Run Text="O" Foreground="#AB70FF"/><Run Text="ptiShade"/></TextBlock></DockPanel>
 <TextBlock Grid.Row="1" Text="Keep OptiShade running?" FontSize="25" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,0,0,10"/>
 <TextBlock Grid.Row="2" TextWrapping="Wrap" Foreground="#C0AEDF" FontSize="14" LineHeight="22" Text="In the system tray OptiShade keeps checking for updates and shows a notification when one is ready. Open it again from the tray icon."/>
 <CheckBox Name="Remember" Grid.Row="3" Margin="0,18,0,0" Content="Remember my choice (you can change it in Settings)"/>
 <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,24,0,0"><Button Name="ExitApp" Content="Close OptiShade" MinWidth="140" Background="#211D30"/><Button Name="ToTray" Content="Keep in system tray" MinWidth="160" Margin="10,0,0,0" IsDefault="True"/></StackPanel>
 </Grid></Border>
</Window>
'@
 $dialog=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($x))
 if($Owner -and $Owner.IsVisible){$dialog.Owner=$Owner}else{$dialog.WindowStartupLocation='CenterScreen'}
 [xml]$theme=Get-Content "$PSScriptRoot/dialog-theme.xaml" -Raw -Encoding UTF8
 $dialog.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($theme)))
 $dialog.Tag='Cancel'
 $dialog.FindName('ToTray').Add_Click({$dialog.Tag='Tray';$dialog.Close()}.GetNewClosure())
 $dialog.FindName('ExitApp').Add_Click({$dialog.Tag='Exit';$dialog.Close()}.GetNewClosure())
 $dialog.FindName('Dismiss').Add_Click({$dialog.Close()}.GetNewClosure())
 $dialog.FindName('Drag').Add_MouseLeftButtonDown({if($_.OriginalSource -is [Windows.Controls.TextBlock]){$dialog.DragMove()}}.GetNewClosure())
 $dialog.Add_PreviewKeyDown({param($sender,$event) if($event.Key -eq 'Escape'){$dialog.Close();$event.Handled=$true}}.GetNewClosure())
 [void]$dialog.ShowDialog()
 return [pscustomobject]@{Choice=[string]$dialog.Tag;Remember=[bool]$dialog.FindName('Remember').IsChecked}
}
