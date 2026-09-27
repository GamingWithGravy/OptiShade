function GetOptiShadeUpdate([string]$Current='0.21.1',[switch]$ReportErrors){
 [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
 try{
  $betaStore=if($env:OPTISHADE_STORE){$env:OPTISHADE_STORE}else{Join-Path $env:LOCALAPPDATA 'OptiShade'}
  $includeBeta=Test-Path -LiteralPath (Join-Path $betaStore 'beta-updates.txt')
  $endpoint=if($includeBeta){'https://api.github.com/repos/GamingWithGravy/OptiShade/releases?per_page=100'}else{'https://api.github.com/repos/GamingWithGravy/OptiShade/releases/latest'}
  $releases=@(Invoke-RestMethod $endpoint -Headers @{'User-Agent'='OptiShade-update-check'} -TimeoutSec 12)
  $candidates=@(foreach($item in $releases){
   if($item.draft -or ($item.prerelease -and -not $includeBeta) -or $item.tag_name -notmatch '^v?(\d+\.\d+(?:\.\d+){0,2})(?:-(?:alpha|beta|rc)[.-]?\d*)?$'){continue}
   if([version]$Matches[1] -le [version]$Current){continue}
   [pscustomobject]@{Release=$item;Numeric=[version]$Matches[1]}
  })
  $choice=$candidates|Sort-Object Numeric,@{Expression={$_.Release.prerelease};Descending=$false} -Descending|Select-Object -First 1
  if(-not $choice){return $null}
  $release=$choice.Release;$version=([string]$release.tag_name) -replace '^v',''
  $asset=@($release.assets|Where-Object {$_.name -eq "OptiShade_Version_$version.exe" -and $_.digest -match '^sha256:[a-fA-F0-9]{64}$'})
  if($asset.Count -ne 1){return $null}
  $url=[uri]$asset[0].browser_download_url
  if($url.Scheme -ne 'https' -or $url.Host -ne 'github.com' -or $url.AbsolutePath -cnotmatch '^/GamingWithGravy/(OptiShade|OptiShade_V0[.]19[.]17)/releases/download/'){return $null}
  [pscustomobject]@{Version=$version;Url=$url.AbsoluteUri;SHA256=$asset[0].digest.Substring(7);Notes=[string]$release.body;Prerelease=[bool]$release.prerelease}
 }catch{if($ReportErrors){throw 'Could not check GitHub. Check your connection and try again.'};return $null}
}

function GetOptiShadePreviousReleases([string]$Current='0.21.1'){
 [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
 $releases=Invoke-RestMethod 'https://api.github.com/repos/GamingWithGravy/OptiShade/releases?per_page=100' -Headers @{'User-Agent'='OptiShade-revert'} -TimeoutSec 12
 foreach($release in $releases){
  if($release.draft -or $release.prerelease -or $release.tag_name -notmatch '^v?(\d+\.\d+(?:\.\d+){0,2})$'){continue}
  $version=$Matches[1];if([version]$version -ge [version]$Current -or [version]$version -lt [version]'0.20.12'){continue}
  $assets=@($release.assets|Where-Object {$_.name -eq "OptiShade_Version_$version.exe" -and $_.digest -match '^sha256:[a-fA-F0-9]{64}$'})
  if($assets.Count -ne 1){continue}
  $url=[uri]$assets[0].browser_download_url
  if($url.Scheme -ne 'https' -or $url.Host -ne 'github.com' -or $url.AbsolutePath -cnotmatch '^/GamingWithGravy/OptiShade/releases/download/'){continue}
  [pscustomobject]@{Version=$version;Url=$url.AbsoluteUri;SHA256=$assets[0].digest.Substring(7);Notes=[string]$release.body;Rollback=$true}
 }
}
function ShowOptiShadeRevert($Owner,[string]$Current='0.21.1'){
 [xml]$markup=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="Revert update" Width="650" Height="520" WindowStartupLocation="CenterOwner" WindowStyle="None" AllowsTransparency="True" Background="Transparent" Foreground="#F3EFFB" FontFamily="Segoe UI" ResizeMode="NoResize">
 <Border CornerRadius="20" Background="#171020" BorderBrush="#40314F" BorderThickness="1" Padding="28"><Grid>
 <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
 <TextBlock Text="Revert update" FontSize="26" FontWeight="SemiBold"/>
 <ComboBox Name="Versions" Grid.Row="1" Margin="0,18,0,18" DisplayMemberPath="Version"/>
 <TextBlock Name="Instructions" Grid.Row="2" TextWrapping="Wrap" Foreground="#CEC0DF"/>
 <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right"><Button Name="Close" Content="Close" Margin="0,0,12,0"/><Button Name="Continue" Content="Install selected build" Background="#8650C8" IsEnabled="False"/></StackPanel>
 </Grid></Border>
</Window>
'@
 $dialog=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup));$dialog.Owner=$Owner
 [xml]$theme=Get-Content "$PSScriptRoot/dialog-theme.xaml" -Raw
 $dialog.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($theme)))
 $dialog.Resources.Add([Windows.Controls.ComboBox],$Owner.FindResource([Windows.Controls.ComboBox]))
 $dialog.Resources.Add([Windows.Controls.ComboBoxItem],$Owner.FindResource([Windows.Controls.ComboBoxItem]))
 $dialog.FindName('Instructions').Text="Choose an older build, then press Install selected build.`n`nOptiShade will download the official installer, verify its SHA-256, check your installations and run the installation automatically. Presets and configuration are kept. The selected manager will be saved to your Desktop.`n`nClose all simulators first. This changes all supported, recorded game installations. Modified graphics loaders will stop the operation.`n`nOnly builds supporting the automatic installation workflow are listed (0.20.12 onward). Versions before 0.21 cannot be installed while X-Plane remains installed in OptiShade. Older features and fixes will be lost."
 $dialog.FindName('Close').Add_Click({$dialog.Close()})
 $dialog.FindName('Continue').Add_Click({
  $selected=$dialog.FindName('Versions').SelectedItem
  if($selected){$dialog.Tag=$selected;$dialog.DialogResult=$true}
 })
 $dialog.Add_ContentRendered({
  try{
   $items=@(GetOptiShadePreviousReleases $Current|Sort-Object {[version]$_.Version} -Descending)
   $dialog.FindName('Versions').ItemsSource=$items
   if($items.Count){$dialog.FindName('Versions').SelectedIndex=0;$dialog.FindName('Continue').IsEnabled=$true}
   else{$dialog.FindName('Instructions').Text='No older published installer versions were found. No files have been changed.'}
  }catch{$dialog.FindName('Instructions').Text='Could not load previous releases. Check your connection and try again. No files have been changed.'}
 })
 if($dialog.ShowDialog()){return $dialog.Tag}
}
