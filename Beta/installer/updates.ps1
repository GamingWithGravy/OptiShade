. "$PSScriptRoot/update-lifecycle.ps1"

function GetOptiShadeModularUpdatePackageId([string]$Component){
 # Resolve one update row at a time. Optional channel failures must not turn
 # into a request for every installed component or block unrelated updates.
 switch -CaseSensitive ($Component){
  'Core' {return 'OptiShade.Core'}
  'Effects' {return 'OptiShade.Effects'}
  'OptiMfg' {return 'OptiShade.OptiMFG'}
  'Providers' {return 'OptiShade.Providers'}
  default {return ''}
 }
}

function GetOptiShadeReleaseAsset($Release,[string]$Version){

 $channel=if($Release.prerelease){'beta'}else{'stable'}

 $readable=GetOptiShadeManagerName $Version $channel

 # GitHub normalises spaces in uploaded asset filenames to periods.

 foreach($name in (GetOptiShadeReleaseAssetNames $Version $channel)){

  $assets=@($Release.assets|Where-Object {$_.name -ceq $name -and $_.digest -match '^sha256:[a-fA-F0-9]{64}$'})

  if($assets.Count -ne 1){continue}

  $url=[uri]$assets[0].browser_download_url

  if($url.Scheme -eq 'https' -and $url.Host -eq 'github.com' -and [uri]::UnescapeDataString($url.AbsolutePath) -ceq "/GamingWithGravy/OptiShade/releases/download/$($Release.tag_name)/$name"){return $assets[0]}

 }

}

function GetOptiShadeUpdateChannel {

 'stable'

}

function SetOptiShadeUpdateChannel([bool]$Beta){

 $root=if($env:OPTISHADE_STORE){$env:OPTISHADE_STORE}else{Join-Path $env:LOCALAPPDATA 'OptiShade'}

 $marker=Join-Path $root 'beta-updates.txt'

 [void][IO.Directory]::CreateDirectory($root)

 if($Beta){throw 'Prerelease updates are unavailable in this stable launcher; they may return with a separate future beta branch.'}

 # Stable is the default channel in this build. Do not rewrite a stable marker
 # during every manager startup: multiple open manager instances can collide
 # on that write, and no stable marker is read by the update path.
 # A second open launcher may hold it for a moment; the next start removes it.
 try{if(Test-Path -LiteralPath $marker){Remove-Item -LiteralPath $marker -Force -ErrorAction Stop}}catch{}

}

function InitializeOptiShadeUpdateChannel([ValidateSet('stable','beta')][string]$InstalledChannel){

 $root=if($env:OPTISHADE_STORE){$env:OPTISHADE_STORE}else{Join-Path $env:LOCALAPPDATA 'OptiShade'}

 # This stable release always uses Stable. Clear an older Beta opt-in so update

 # checks and the update worker agree about the selected channel.

 SetOptiShadeUpdateChannel $false

}

function GetOptiShadeUpdateLabel($Update){

 if($Update.Rollback){return 'Return to stable - '+$Update.Version}

 if($Update.Prerelease -or $Update.Channel -eq 'beta'){return 'Beta update available - '+(GetOptiShadeDisplayVersion $Update.Version)}

 return 'Update available - '+$Update.Version

}

function GetBetaVersionKey([string]$Value){

 if($Value -notmatch '^v?(\d+\.\d+(?:\.\d+){0,2})(?:-(alpha|beta|rc)(?:[.-]?(\d+))?)?$'){return $null}

 $stage=if($Matches[2]){@{alpha=0;beta=1;rc=2}[$Matches[2]]}else{3}

 $revision=if($Matches[3]){[int]$Matches[3]}else{0}

 [pscustomobject]@{Numeric=[version]$Matches[1];Stage=$stage;Revision=$revision}

}

# The persisted setting selects release assets, never source-code branch archives.

function GetOptiShadeUpdate([string]$Current='1.0.77',[switch]$ReportErrors,[ValidateSet('stable','beta')][string]$InstalledChannel='stable'){

 [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12

 try{

  $channel=GetOptiShadeUpdateChannel

  $currentKey=GetBetaVersionKey $Current

  if(-not $currentKey){throw 'Invalid current version'}

  if(-not $PSBoundParameters.ContainsKey('InstalledChannel')){$InstalledChannel=if($currentKey.Stage -lt 3){'beta'}else{'stable'}}

  # Beta update checks never offer stable. The separate Return to stable dialog

  # fetches stable releases only after the user explicitly opens it.

  if($InstalledChannel -eq 'beta' -and $channel -eq 'stable'){return $null}

  $releases=@(Invoke-RestMethod 'https://api.github.com/repos/GamingWithGravy/OptiShade/releases?per_page=100' -Headers @{'User-Agent'='OptiShade-beta-update-check'} -TimeoutSec 12 | ForEach-Object { $_ })

  $candidates=@(foreach($release in $releases){

   if($release.draft -or ([bool]$release.prerelease -ne ($channel -eq 'beta'))){continue}

   $version=([string]$release.tag_name) -replace '^v','';$key=GetBetaVersionKey $version

   if(-not $key -or ($channel -eq 'beta' -and $key.Stage -eq 3) -or ($channel -eq 'stable' -and $key.Stage -ne 3)){continue}

   if(-not (($channel -ne $InstalledChannel -and (($currentKey.Stage -eq 3) -eq ($InstalledChannel -eq 'stable'))) -or ($channel -eq 'stable' -and $currentKey.Stage -ne 3)) -and ($key.Numeric -lt $currentKey.Numeric -or ($key.Numeric -eq $currentKey.Numeric -and ($key.Stage -lt $currentKey.Stage -or ($key.Stage -eq $currentKey.Stage -and $key.Revision -le $currentKey.Revision))))){continue}

   $assets=@(GetOptiShadeReleaseAsset $release $version)

   if($assets.Count -ne 1){continue}

   $url=[uri]$assets[0].browser_download_url

   [pscustomobject]@{Version=$version;Url=$url.AbsoluteUri;SHA256=$assets[0].digest.Substring(7);Notes=[string]$release.body;Prerelease=[bool]$release.prerelease;Channel=$channel;ReleaseUrl="https://github.com/GamingWithGravy/OptiShade/releases/tag/$($release.tag_name)";Rollback=($channel -eq 'stable' -and ($InstalledChannel -eq 'beta' -or $currentKey.Stage -ne 3));Numeric=$key.Numeric;Stage=$key.Stage;Revision=$key.Revision}

  })

  $candidates|Sort-Object Numeric,Stage,Revision -Descending|Select-Object -First 1

 }catch{if($ReportErrors){throw 'Could not check the selected update channel on GitHub. Check your connection and try again.'};return $null}

}

# The payload-free manager checks the signed launcher branch through a short
# CLI mode in its own executable. Full R builds retain the historical Releases
# updater and are not routed through this AppData-only path.
function GetOptiShadeModularUpdate([string]$Current,[string]$ManagerPath){
 if(-not $Current -or -not $ManagerPath -or -not(Test-Path -LiteralPath $ManagerPath -PathType Leaf)){throw 'The installed OptiShade manager executable could not be located.'}
 $currentKey=GetBetaVersionKey $Current;if(-not $currentKey){throw 'The installed OptiShade manager version is invalid.'}
 $root=if($env:OPTISHADE_STORE){$env:OPTISHADE_STORE}else{Join-Path $env:LOCALAPPDATA 'OptiShade'}
 $updateRoot=Join-Path $root 'Updates';[void][IO.Directory]::CreateDirectory($updateRoot)
 $resultPath=Join-Path $updateRoot ('launcher-check-'+[guid]::NewGuid().ToString('N')+'.json')
 try{
  $process=Start-Process -FilePath $ManagerPath -ArgumentList @('--launcher-check-update',$Current,('"'+$resultPath+'"')) -WindowStyle Hidden -PassThru -Wait -ErrorAction Stop
  if(-not(Test-Path -LiteralPath $resultPath -PathType Leaf)){throw 'The signed launcher update check did not return a result.'}
  $result=Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
  if($process.ExitCode -ne 0 -or -not $result.OK){throw ([string]$result.Message)}
  if(-not $result.ChannelPublished){return [pscustomobject]@{ChannelUnavailable=$true;Message=[string]$result.Message;Channel='stable';Modular=$true;Rollback=$false;Prerelease=$false}}
  $remoteKey=GetBetaVersionKey ([string]$result.Version);if(-not $remoteKey){throw 'The signed launcher channel returned an invalid version.'}
  if($remoteKey.Numeric -le $currentKey.Numeric){return $null}
  [pscustomobject]@{Version=[string]$result.Version;Bytes=[long]$result.Bytes;SHA256=[string]$result.SHA256;PackagePath=[string]$result.Path;Channel='stable';Modular=$true;Rollback=$false;Prerelease=$false;Notes='';ReleaseUrl=''}
 }finally{Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue}
}

function GetOptiShadePreviousReleases([string]$Current='1.0.77'){

 [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12

 $releases=Invoke-RestMethod 'https://api.github.com/repos/GamingWithGravy/OptiShade/releases?per_page=100' -Headers @{'User-Agent'='OptiShade-revert'} -TimeoutSec 12

 foreach($release in $releases){

  if($release.draft -or $release.prerelease -or $release.tag_name -notmatch '^v?(\d+\.\d+(?:\.\d+){0,2})$'){continue}

  $version=$Matches[1];if([version]$version -lt [version]'0.20.12'){continue}

  $assets=@(GetOptiShadeReleaseAsset $release $version)

  if($assets.Count -ne 1){continue}

  $url=[uri]$assets[0].browser_download_url

  if($url.Scheme -ne 'https' -or $url.Host -ne 'github.com' -or $url.AbsolutePath -cnotmatch '^/GamingWithGravy/OptiShade/releases/download/'){continue}

  [pscustomobject]@{Version=$version;Url=$url.AbsoluteUri;SHA256=$assets[0].digest.Substring(7);Notes=[string]$release.body;Rollback=$true;Channel='stable';Prerelease=$false;ReleaseUrl="https://github.com/GamingWithGravy/OptiShade/releases/tag/$($release.tag_name)"}

 }

}

function ShowOptiShadeRevert($Owner,[string]$Current='1.0.77'){

 [xml]$markup=@'

<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="Return to stable" Width="650" Height="520" WindowStartupLocation="CenterOwner" WindowStyle="None" AllowsTransparency="True" Background="Transparent" Foreground="#F3EFFB" FontFamily="Segoe UI" ResizeMode="NoResize">

 <Border CornerRadius="20" Background="#171020" BorderBrush="#40314F" BorderThickness="1" Padding="28"><Grid>

 <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

 <TextBlock Text="Return to stable" FontSize="26" FontWeight="SemiBold"/>

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

 $dialog.FindName('Instructions').Text="Choose a stable build, then press Install selected build. This leaves the beta channel.`n`nOptiShade will download the official installer, verify its SHA-256, check your installations and run the installation automatically. Presets and configuration are kept. The selected manager will be saved to your Desktop.`n`nClose all simulators first. This changes all supported, recorded game installations. Modified graphics loaders will stop the operation.`n`nOnly builds supporting the automatic installation workflow are listed (0.20.12 onward). Versions before 0.21 cannot be installed while X-Plane remains installed in OptiShade. Older features and fixes will be lost."

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

