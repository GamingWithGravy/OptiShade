param([string]$Config)
# Shown by the modular OptiShade launcher when the OptiShade installer has not set
# it up (no install-setup.json, a missing data folder, or this EXE is not the
# installed copy). The launcher runs this from a Windows temporary folder and
# removes it afterwards; nothing is written to OptiShade's AppData folders.
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
$settings=Get-Content -LiteralPath $Config -Raw -Encoding UTF8|ConvertFrom-Json
[xml]$markup=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="OptiShade" Width="540" SizeToContent="Height" ResizeMode="NoResize" WindowStyle="None" AllowsTransparency="True" Background="Transparent" WindowStartupLocation="CenterScreen" Foreground="#F3EFFB" FontFamily="Segoe UI" Topmost="True">
 <Window.Resources>
  <LinearGradientBrush x:Key="WindowGlass" StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#141323" Offset="0"/><GradientStop Color="#0D0D19" Offset="0.55"/><GradientStop Color="#171024" Offset="1"/></LinearGradientBrush>
  <LinearGradientBrush x:Key="CardGlass" StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#272039" Offset="0"/><GradientStop Color="#141120" Offset="1"/></LinearGradientBrush>
  <LinearGradientBrush x:Key="ActionPurple" StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#842BFF" Offset="0"/><GradientStop Color="#4C0BCA" Offset="1"/></LinearGradientBrush>
  <Style TargetType="Button"><Setter Property="Foreground" Value="#F3EFFB"/><Setter Property="Background" Value="{StaticResource ActionPurple}"/><Setter Property="Padding" Value="24,10"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border Name="Surface" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="7" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsEnabled" Value="False"><Setter TargetName="Surface" Property="Opacity" Value="0.4"/></Trigger><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Surface" Property="Opacity" Value="0.82"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Surface" Property="BorderBrush" Value="#D4B7F9"/><Setter TargetName="Surface" Property="BorderThickness" Value="1"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
  <Style TargetType="ScrollBar"><Setter Property="Width" Value="10"/><Setter Property="Background" Value="#21192C"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar"><Grid Background="{TemplateBinding Background}"><Track Name="PART_Track" IsDirectionReversed="True" Orientation="Vertical"><Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/></Track.DecreaseRepeatButton><Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="#694982" CornerRadius="4" Margin="2"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb><Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/></Track.IncreaseRepeatButton></Track></Grid></ControlTemplate></Setter.Value></Setter></Style>
  <Style x:Key="Secondary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}"><Setter Property="Background" Value="#2A2238"/><Setter Property="BorderBrush" Value="#5E3E86"/><Setter Property="BorderThickness" Value="1"/></Style>
  <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#E4D9F5"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Margin" Value="0,0,0,12"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox"><Grid Background="Transparent"><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><Border Name="Box" Width="20" Height="20" CornerRadius="5" BorderBrush="#8650C8" BorderThickness="1" Background="#282238" Margin="0,1,12,0" VerticalAlignment="Top"><Path Name="Mark" Visibility="Collapsed" Data="M 4,9 L 8,13 L 15,5" Stroke="#E5D2FF" StrokeThickness="2"/></Border><ContentPresenter Grid.Column="1" VerticalAlignment="Center"/></Grid><ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True"><Setter TargetName="Mark" Property="Visibility" Value="Visible"/><Setter TargetName="Box" Property="Background" Value="#5A2BA8"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="#D4B7F9"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
 </Window.Resources>
 <Border Background="{StaticResource WindowGlass}" BorderBrush="#5E3E86" BorderThickness="1" CornerRadius="12" Margin="8">
  <Border.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="0" Opacity="0.55" Color="#000000"/></Border.Effect>
  <Grid Margin="26,18,26,24">
   <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
   <Grid Name="TitleBar" Background="Transparent">
    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
     <Image Name="Logo" Width="30" Height="30" Margin="0,0,12,0"/>
     <TextBlock Text="OptiShade" FontSize="22" FontWeight="SemiBold" Foreground="#EDE3FA" VerticalAlignment="Center"/>
    </StackPanel>
    <Button Name="CloseWindow" Content="&#x2715;" Style="{StaticResource Secondary}" Padding="11,4" HorizontalAlignment="Right" VerticalAlignment="Center" ToolTip="Close"/>
   </Grid>
   <StackPanel Grid.Row="1" Margin="0,18,0,0">
    <TextBlock Text="Install OptiShade with the OptiShade installer" FontSize="16" FontWeight="SemiBold" TextWrapping="Wrap"/>
    <TextBlock Margin="0,8,0,0" Foreground="#C0AEDF" TextWrapping="Wrap" Text="This copy of OptiShade can't open on its own. Run OptiShade-Installer.exe: it asks you to accept the User Agreement, sets up OptiShade's folders for this Windows user and installs the launcher. Then open OptiShade from the shortcut it creates."/>
    <TextBlock Name="Reason" Margin="0,10,0,0" FontSize="12" Foreground="#8F7FAA" TextWrapping="Wrap"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
     <Button Name="CloseNotice" Content="Close" Style="{StaticResource Secondary}" Margin="0,0,10,0"/>
     <Button Name="Download" Content="Get the installer" IsDefault="True"/>
    </StackPanel>
   </StackPanel>
  </Grid>
 </Border>
</Window>
'@
$window=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup))
function Find([string]$Name){return $window.FindName($Name)}
try{if($settings.IconPath -and (Test-Path -LiteralPath $settings.IconPath)){$image=[Windows.Media.Imaging.BitmapImage]::new();$image.BeginInit();$image.CacheOption='OnLoad';$image.UriSource=[Uri]::new([string]$settings.IconPath);$image.EndInit();(Find 'Logo').Source=$image}}catch{}
try{if($settings.IconPath){$window.Icon=[Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new([string]$settings.IconPath))}}catch{}
(Find 'Reason').Text='Details: '+[string]$settings.Reason
(Find 'TitleBar').Add_MouseLeftButtonDown({try{$window.DragMove()}catch{}})
(Find 'CloseWindow').Add_Click({$window.Close()})
(Find 'CloseNotice').Add_Click({$window.Close()})
(Find 'Download').Add_Click({
 $url=[string]$settings.DownloadUrl
 if($url -match '^https://github\.com/GamingWithGravy/OptiShade/'){try{Start-Process $url}catch{}}
 $window.Close()
})
[void]$window.ShowDialog()
