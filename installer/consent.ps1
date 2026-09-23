function ConfirmFusionInstall($Owner,[string]$Message){
 [xml]$markup=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Before you install OptiShade" Width="560" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#171020" Foreground="#F3EFFB" FontFamily="Segoe UI">
 <StackPanel Margin="28">
  <TextBlock Text="Check before installing" FontSize="24" FontWeight="SemiBold" Margin="0,0,0,16"/>
  <TextBlock x:Name="Details" TextWrapping="Wrap" Foreground="#D1C2DF" Margin="0,0,0,22"/>
  <CheckBox x:Name="AcceptRisk" IsChecked="False" Foreground="#F3EFFB" Margin="0,0,0,24" VerticalContentAlignment="Center">
   <TextBlock TextWrapping="Wrap" Width="450" Text="I understand that using OptiShade in multiplayer or with anti-cheat may lead to a ban. I have checked this game's rules and choose to install."/>
  </CheckBox>
  <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
   <Button x:Name="CancelInstall" Content="Cancel" IsCancel="True" Padding="20,9" Margin="0,0,12,0"/>
   <Button x:Name="AcceptInstall" Content="Install OptiShade" IsEnabled="False" Padding="20,9" Background="#8650C8" Foreground="White"/>
  </StackPanel>
 </StackPanel>
</Window>
'@
 $dialog=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $markup))
 $dialog.Owner=$Owner;$dialog.FindName('Details').Text=$Message
 $check=$dialog.FindName('AcceptRisk');$accept=$dialog.FindName('AcceptInstall')
 $check.Add_Checked({$accept.IsEnabled=$true}.GetNewClosure())
 $check.Add_Unchecked({$accept.IsEnabled=$false}.GetNewClosure())
 $accept.Add_Click({if($check.IsChecked -eq $true){$dialog.DialogResult=$true}}.GetNewClosure())
 $dialog.FindName('CancelInstall').Add_Click({$dialog.DialogResult=$false}.GetNewClosure())
 return $dialog.ShowDialog() -eq $true
}

function ConfirmOptionalDlss($Owner,[bool]$Supported){
 [xml]$markup=@"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="Optishade setup" Width="550" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#17121F" Foreground="#F3EFFB" FontFamily="Segoe UI" ShowInTaskbar="False">
 <StackPanel Margin="28"><TextBlock Text="Would you like to install DLSS 5?" FontSize="23" FontWeight="SemiBold" TextWrapping="Wrap"/>
 <TextBlock Margin="0,16,0,12" Text="Yes downloads GPU-matched files. DLSS/Streamline come from NVIDIA; the neural model comes from pinned community GitHub releases (RHI for RTX 50; OptiScaler-Susemi for RTX 20/30/40). RTX 20/30/40 uses an experimental modified model without a valid NVIDIA signature. Downloads are hash-verified. Installing files does not switch the effect on." TextWrapping="Wrap" Foreground="#C2B0D7"/>
 <TextBlock Text="No installs Optishade with image effects and presets, without adding DLSS 5 files. Your game's built-in DLSS stays untouched." TextWrapping="Wrap" Foreground="#C2B0D7"/>
 <TextBlock Name="Availability" Margin="0,14,0,0" Foreground="#FFBE83" TextWrapping="Wrap"/>
 <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,24,0,0"><Button Name="Yes" Content="Yes" MinWidth="100" Margin="0,0,12,0"/><Button Name="No" Content="No" MinWidth="100" IsDefault="True"/></StackPanel>
 </StackPanel>
</Window>
"@
 $dialog=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $markup));$dialog.Owner=$Owner
 foreach($name in @('Yes','No')){$dialog.FindName($name).Style=$Owner.FindResource([Windows.Controls.Button])}
 $dialog.FindName('Yes').IsEnabled=$Supported
 if(-not $Supported){$dialog.FindName('Availability').Text='The current hardware or game check does not support this option. You can still choose No and install image effects.'}
 $dialog.FindName('Yes').Add_Click({$dialog.Tag='Yes';$dialog.Close()})
 $dialog.FindName('No').Add_Click({$dialog.Tag='No';$dialog.Close()})
 [void]$dialog.ShowDialog()
 if($dialog.Tag -eq 'Yes'){return $true};if($dialog.Tag -eq 'No'){return $false};return $null
}
function UseOptionalDlss($Manifest,$Plan){return ($Manifest.OptionalDlss -eq $true -and $Plan.DownloadNvidia -eq $true)}

function ConfirmAmdExperimental($Owner){
 [xml]$markup=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="AMD experimental support" Width="550" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#17121F" Foreground="#F3EFFB" FontFamily="Segoe UI" ShowInTaskbar="False">
 <StackPanel Margin="28">
  <TextBlock Text="AMD GPU detected" FontSize="23" FontWeight="SemiBold"/>
  <TextBlock Margin="0,16,0,12" Text="AMD support is currently in a very early experimental stage. Please report any issues to Gravy." TextWrapping="Wrap" Foreground="#FFBE83"/>
  <TextBlock Text="This patch enables image effects and available FSR/XeSS paths. NVIDIA DLSS Neural Rendering is not available on AMD in this build. Compatibility, performance and image quality still need testing on AMD hardware." TextWrapping="Wrap" Foreground="#C2B0D7"/>
  <TextBlock Text="If you encounter an issue, save a diagnostic report from Troubleshooting and review it before sharing with Gravy." TextWrapping="Wrap" Foreground="#C2B0D7" Margin="0,12,0,0"/>
  <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,24,0,0"><Button Name="Cancel" Content="Cancel" MinWidth="100" Margin="0,0,12,0" IsCancel="True"/><Button Name="Continue" Content="Continue" MinWidth="100"/></StackPanel>
 </StackPanel>
</Window>
'@
 $dialog=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup));$dialog.Owner=$Owner
 foreach($name in @('Cancel','Continue')){$dialog.FindName($name).Style=$Owner.FindResource([Windows.Controls.Button])}
 $dialog.FindName('Cancel').Add_Click({$dialog.DialogResult=$false}.GetNewClosure())
 $dialog.FindName('Continue').Add_Click({$dialog.DialogResult=$true}.GetNewClosure())
 return $dialog.ShowDialog() -eq $true
}
