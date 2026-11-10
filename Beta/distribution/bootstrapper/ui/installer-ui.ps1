param([string]$Config)
# OptiShade installer window. The bootstrapper downloads, verifies and installs;
# this window shows the User Agreement, asks for the install choices and shows
# what the bootstrapper reports. Choices go to ChoicePath; progress comes from StatePath.
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
$settings=Get-Content -LiteralPath $Config -Raw -Encoding UTF8|ConvertFrom-Json
[xml]$markup=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="OptiShade installer" Width="620" SizeToContent="Height" ResizeMode="NoResize" WindowStyle="None" AllowsTransparency="True" Background="Transparent" ShowInTaskbar="True" WindowStartupLocation="CenterScreen" Foreground="#F3EFFB" FontFamily="Segoe UI" FontSize="14">
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
     <TextBlock Text="  installer" FontSize="22" Foreground="#9E86C4" VerticalAlignment="Center"/>
    </StackPanel>
    <Button Name="CloseWindow" Content="&#x2715;" Style="{StaticResource Secondary}" Padding="11,4" HorizontalAlignment="Right" VerticalAlignment="Center" ToolTip="Close"/>
   </Grid>
   <Grid Grid.Row="1" Margin="0,18,0,0">
    <StackPanel Name="OptionsPage">
     <Border Name="ExistingPanel" Visibility="Collapsed" Margin="0,0,0,14" Background="{StaticResource CardGlass}" BorderBrush="#9755E9" BorderThickness="1" CornerRadius="9" Padding="14,12">
      <StackPanel>
       <TextBlock Text="Another version of OptiShade has been detected on this system" FontSize="15" FontWeight="SemiBold" TextWrapping="Wrap"/>
       <TextBlock Name="ExistingSummary" Margin="0,4,0,0" FontSize="12" Foreground="#A99ABF" TextWrapping="Wrap"/>
       <CheckBox Name="RunCleanup" IsChecked="True" Margin="0,10,0,0">
        <TextBlock TextWrapping="Wrap"><Run Text="Run a clean up" FontWeight="SemiBold"/><LineBreak/><Run Text="Removes the old OptiShade launcher and its temporary files. Your current ini files, snapshots and settings are kept, and games set up with OptiShade stay as they are." Foreground="#A99ABF" FontSize="12"/></TextBlock>
       </CheckBox>
      </StackPanel>
     </Border>
     <TextBlock Text="Install the OptiShade app for this Windows user" FontSize="16" FontWeight="SemiBold" TextWrapping="Wrap"/>
     <TextBlock Margin="0,6,0,0" Foreground="#C0AEDF" TextWrapping="Wrap" Text="This installs the OptiShade launcher only. Games are not changed until you choose one in OptiShade. Components (Core, OptiMFG, image effects) are downloaded from GitHub, verified, and update separately."/>
     <TextBlock Margin="0,10,0,0" Foreground="#FFBE83" TextWrapping="Wrap" FontWeight="SemiBold" Text="Using mods in games with anti-cheat can get your account banned. Read the agreement below."/>
     <Border Margin="0,10,0,0" Background="{StaticResource CardGlass}" BorderBrush="#3A2D52" BorderThickness="1" CornerRadius="9" Padding="4">
      <ScrollViewer Name="AgreementScroll" Height="200" VerticalScrollBarVisibility="Auto" Padding="12,10">
       <TextBlock Name="AgreementText" TextWrapping="Wrap" FontSize="12.5" Foreground="#D9CDEB"/>
      </ScrollViewer>
     </Border>
     <TextBlock Name="ScrollHint" Margin="2,8,0,0" FontSize="12" Foreground="#FFBE83" Text="Scroll to the end of the agreement to accept it."/>
     <CheckBox Name="AcceptAgreement" IsChecked="False" IsEnabled="False" Margin="0,8,0,0">
      <TextBlock TextWrapping="Wrap" FontWeight="SemiBold" Text="I have read and accept the OptiShade User Agreement, including that I am responsible for any ban or suspension if I install OptiShade into a game that does not allow it."/>
     </CheckBox>
     <TextBlock Text="Options" Margin="2,14,0,10" FontSize="13" FontWeight="SemiBold" Foreground="#9E86C4"/>
     <CheckBox Name="DesktopShortcut" IsChecked="True" Content="Create a desktop shortcut"/>
     <CheckBox Name="StartMenuShortcut" IsChecked="True" Content="Add OptiShade to the Start menu"/>
     <CheckBox Name="StartWithWindows" IsChecked="False">
      <TextBlock TextWrapping="Wrap"><Run Text="Start OptiShade with Windows"/><LineBreak/><Run Text="Runs in the system tray and shows a Windows notification when an update is available. Change this later in OptiShade's settings." Foreground="#A99ABF" FontSize="12"/></TextBlock>
     </CheckBox>
     <TextBlock Name="InstallLocation" Margin="2,4,0,0" FontSize="12" Foreground="#8F7FAA" TextWrapping="Wrap"/>
     <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
      <Button Name="CancelInstall" Content="Cancel" Style="{StaticResource Secondary}" Margin="0,0,10,0"/>
      <Button Name="Install" Content="Install" IsDefault="True" IsEnabled="False" ToolTip="Accept the User Agreement to install"/>
     </StackPanel>
    </StackPanel>
    <StackPanel Name="ProgressPage" Visibility="Collapsed">
     <TextBlock Name="ProgressTitle" Text="Installing OptiShade" FontSize="18" FontWeight="SemiBold"/>
     <TextBlock Name="ProgressDetail" Margin="0,12,0,0" Foreground="#C0AEDF" TextWrapping="Wrap" MinHeight="40" Text="Starting..."/>
     <ProgressBar Name="ProgressBar" Margin="0,14,0,0" Height="9" Minimum="0" Maximum="100" IsIndeterminate="True" Foreground="#9755E9" Background="#332246" BorderThickness="0"/>
     <TextBlock Name="ProgressFooter" Margin="0,12,0,0" FontSize="12" Foreground="#A99ABF" TextWrapping="Wrap" Text="Every download is checked against OptiShade's signed release record before it is used."/>
     <StackPanel Name="ResultButtons" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0" Visibility="Collapsed">
      <Button Name="CloseResult" Content="Close" Style="{StaticResource Secondary}" Margin="0,0,10,0"/>
      <Button Name="OpenApp" Content="Open OptiShade" IsDefault="True"/>
     </StackPanel>
    </StackPanel>
   </Grid>
  </Grid>
 </Border>
</Window>
'@
$window=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup))
function Find([string]$Name){return $window.FindName($Name)}
try{if($settings.IconPath -and (Test-Path -LiteralPath $settings.IconPath)){$image=[Windows.Media.Imaging.BitmapImage]::new();$image.BeginInit();$image.CacheOption='OnLoad';$image.UriSource=[Uri]::new([string]$settings.IconPath);$image.EndInit();(Find 'Logo').Source=$image;$window.Icon=$image}}catch{}
try{if($settings.IconPath){$window.Icon=[Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new([string]$settings.IconPath))}}catch{}
(Find 'InstallLocation').Text='Installs to '+[string]$settings.InstallDir
if($settings.ExistingFound){(Find 'ExistingPanel').Visibility='Visible';(Find 'ExistingSummary').Text='Found: '+[string]$settings.ExistingSummary+'.'}
(Find 'AgreementText').Text=[IO.File]::ReadAllText([string]$settings.AgreementPath,[Text.Encoding]::UTF8)
# Checked/Unchecked fire for mouse, keyboard and accessibility tools alike.
$syncInstall={(Find 'Install').IsEnabled=[bool](Find 'AcceptAgreement').IsChecked}
# The agreement can only be accepted once it has been scrolled to the end.
$script:agreementRead=$false
$checkRead={
 $scroll=Find 'AgreementScroll'
 if(-not $script:agreementRead -and $scroll.ScrollableHeight -ge 0 -and $scroll.VerticalOffset -ge ($scroll.ScrollableHeight-2) -and $scroll.ActualHeight -gt 0){
  $script:agreementRead=$true;(Find 'AcceptAgreement').IsEnabled=$true;(Find 'ScrollHint').Visibility='Collapsed'
 }
}
(Find 'AgreementScroll').Add_ScrollChanged($checkRead)
(Find 'AcceptAgreement').Add_Checked($syncInstall);(Find 'AcceptAgreement').Add_Unchecked($syncInstall)
$script:phase='Options'

function WriteChoice([bool]$Install,[bool]$Open){
 $choice=[ordered]@{Install=$Install;AcceptedAgreement=[bool](Find 'AcceptAgreement').IsChecked;Desktop=[bool](Find 'DesktopShortcut').IsChecked;StartMenu=[bool](Find 'StartMenuShortcut').IsChecked;Startup=[bool](Find 'StartWithWindows').IsChecked;Open=$Open;CleanUp=[bool]((Find 'ExistingPanel').Visibility -eq 'Visible' -and (Find 'RunCleanup').IsChecked)}
 $temp=[string]$settings.ChoicePath+'.partial'
 [IO.File]::WriteAllText($temp,($choice|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
 if([IO.File]::Exists([string]$settings.ChoicePath)){[IO.File]::Delete([string]$settings.ChoicePath)}
 [IO.File]::Move($temp,[string]$settings.ChoicePath)
}
(Find 'Install').Add_Click({
 if(-not (Find 'AcceptAgreement').IsChecked){return}
 WriteChoice $true $false
 $script:phase='Running';(Find 'OptionsPage').Visibility='Collapsed';(Find 'ProgressPage').Visibility='Visible';(Find 'CloseWindow').Visibility='Collapsed'
})
$cancel={if($script:phase -eq 'Options'){WriteChoice $false $false;$script:phase='Closed';$window.Close()}elseif($script:phase -eq 'Finished'){$window.Close()}}
(Find 'CancelInstall').Add_Click($cancel);(Find 'CloseWindow').Add_Click($cancel)
(Find 'CloseResult').Add_Click({$window.Close()})
(Find 'OpenApp').Add_Click({WriteChoice $true $true;$window.Close()})
(Find 'TitleBar').Add_MouseLeftButtonDown({param($sender,$event) if($event.ChangedButton -eq 'Left'){try{$window.DragMove()}catch{}}})
$window.Add_KeyDown({param($sender,$event) if($event.Key -eq 'Escape'){& $cancel}})
$window.Add_Closing({param($sender,$event) if($script:phase -eq 'Running'){$event.Cancel=$true}})

$timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(200)
$timer.Add_Tick({
 # The bootstrapper owns the work; if it is gone, this window has nothing to show.
 try{[void][Diagnostics.Process]::GetProcessById([int]$settings.ParentPid)}catch{$script:phase='Closed';$window.Close();return}
 if($script:phase -ne 'Running'){return}
 try{
  if(-not [IO.File]::Exists([string]$settings.StatePath)){return}
  $state=[IO.File]::ReadAllText([string]$settings.StatePath)|ConvertFrom-Json
  if($state.Detail){(Find 'ProgressDetail').Text=[string]$state.Detail}
  $bar=Find 'ProgressBar'
  if([double]$state.Total -gt 0){$bar.IsIndeterminate=$false;$bar.Value=[Math]::Min(100,[double]$state.Current*100/[double]$state.Total)}else{$bar.IsIndeterminate=$true}
  if($state.Status -in @('Done','Failed')){
   $script:phase='Finished';$bar.IsIndeterminate=$false;(Find 'ResultButtons').Visibility='Visible';(Find 'CloseWindow').Visibility='Visible'
   $warnings=@($state.Warnings|Where-Object {$_})
   if($state.Status -eq 'Done'){
    $bar.Value=100
    (Find 'ProgressTitle').Text=if($warnings.Count){'OptiShade is installed, with notes'}else{'OptiShade is installed'}
    (Find 'ProgressFooter').Text=if($warnings.Count){$warnings -join "`n"}else{'Open OptiShade to choose a game and install its components.'}
    if($warnings.Count){(Find 'ProgressFooter').Foreground='#FFBE83'}
    [void](Find 'OpenApp').Focus()
   }else{
    $bar.Foreground='#FFBE83';$bar.Value=100
    (Find 'ProgressTitle').Text='OptiShade was not installed'
    (Find 'ProgressFooter').Text='Nothing was started. Check your connection and run the installer again.'
    (Find 'OpenApp').Visibility='Collapsed'
   }
  }
 }catch{}
})
$window.Add_ContentRendered({[void]$window.Activate();& $checkRead;[void](Find 'AgreementScroll').Focus()})
$timer.Start()
try{[void]$window.ShowDialog()}finally{$timer.Stop()}
