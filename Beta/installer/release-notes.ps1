function GetOptiShadeManagerBuild([string]$Payload=(Join-Path $PSScriptRoot 'PayloadFusion'),[string]$ManagerPath=''){
 # Launcher and Core are independently versioned. Prefer the manager EXE's
 # product version; retain Core identity as a fallback for older hosts.
 if($ManagerPath -and (Test-Path -LiteralPath $ManagerPath -PathType Leaf)){
  $info=[Diagnostics.FileVersionInfo]::GetVersionInfo($ManagerPath);$version=[string]$info.ProductVersion
  if($version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$'){$version=[string]$info.FileVersion}
  if($version -match '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$'){return $version}
  throw 'The manager executable does not contain a valid semantic product version.'
 }
 $identityPath=Join-Path $Payload 'OptiShadeData/BuildIdentity.json'
 if(Test-Path -LiteralPath $identityPath -PathType Leaf){
  $identity=Get-Content -LiteralPath $identityPath -Raw -Encoding UTF8|ConvertFrom-Json
  if([string]$identity.Version -match '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$'){return [string]$identity.Version}
 }
 throw 'Neither the manager executable nor the selected Core payload provides a valid version identity.'
}

function GetOptiShadeManagerPresentation([string]$Payload,[bool]$Portable,[string]$ManagerPath=''){
 $version=GetOptiShadeManagerBuild $Payload $ManagerPath
 $identityPath=Join-Path $Payload 'OptiShadeData/BuildIdentity.json';$identity=$null
 if(Test-Path -LiteralPath $identityPath -PathType Leaf){$identity=Get-Content -LiteralPath $identityPath -Raw -Encoding UTF8|ConvertFrom-Json}
 $channel=if($version -match '-beta'){'BETA'}else{'STABLE'}
 # Core can be on a different channel during independent component updates.
 $package=if($Portable){'PORTABLE'}else{'INSTALLER'}
 $private=($identity -and $identity.PSObject.Properties['PrivateTesting'] -and $identity.PrivateTesting -eq $true)
 $test=if($private -and $identity.PrivateTestNumber){'Test '+[string]$identity.PrivateTestNumber}else{''}
 if($private -and $identity.PrivateBuildLabel -match '^Rebuild R[0-9]+$'){$test=[string]$identity.PrivateBuildLabel}
 $scope=if($private){'PRIVATE TESTING ONLY'}else{'PUBLIC RELEASE'}
 $details=($channel+' / '+$package)
 $footer='v'+$version+$(if($private -and $identity.PrivateBuildLabel){' / '+$test}else{''})
 [pscustomobject]@{Version=$version;Channel=$channel;Package=$package;Scope=$scope;Test=$test;Footer=$footer;Title=('OptiShade '+$version+' / '+$details+' / '+$scope);Badge=($details+' / '+$scope);Intro=('Version '+$version)}
}
function TestOptiShadeReleaseNotesDismissed([string]$Store,[string]$NotesKey,[switch]$Reopen){
 if($Reopen){return $false}
 $marker=Join-Path $Store 'release-notes-dismissed.txt'
 return (Test-Path -LiteralPath $marker) -and (Get-Content -LiteralPath $marker -Raw).Trim() -eq $NotesKey
}

function ShowReleaseNotes($Owner,[string]$Store,[switch]$Reopen,[string]$Payload=(Join-Path $PSScriptRoot 'PayloadFusion'),[string]$ManagerPath=''){
 $version=GetOptiShadeManagerBuild $Payload $ManagerPath;$identity=$null;$identityPath=Join-Path $Payload 'OptiShadeData/BuildIdentity.json';if(Test-Path -LiteralPath $identityPath -PathType Leaf){$identity=Get-Content -LiteralPath $identityPath -Raw -Encoding UTF8|ConvertFrom-Json};$buildLabel=if($identity){[string]$identity.PrivateBuildLabel}else{''};$notesKey=$version+'-'+$buildLabel;$marker=Join-Path $Store 'release-notes-dismissed.txt'
 if(TestOptiShadeReleaseNotesDismissed $Store $notesKey -Reopen:$Reopen){return}
 [xml]$markup=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="What's new in OptiShade" Width="900" Height="760" MinWidth="680" MinHeight="540" WindowStyle="None" ResizeMode="CanResizeWithGrip" AllowsTransparency="True" WindowStartupLocation="CenterOwner" Background="Transparent" Foreground="#F3EFFB" FontFamily="Segoe UI">
 <Border Background="{DynamicResource WindowGlass}" BorderBrush="#40314F" BorderThickness="1" CornerRadius="10"><Grid>
 <Grid.RowDefinitions><RowDefinition Height="64"/><RowDefinition/><RowDefinition Height="84"/></Grid.RowDefinitions>
 <Border Name="DragHeader" Background="#11101E" CornerRadius="10,20,0,0" Cursor="SizeAll"><Grid Margin="28,0,16,0"><TextBlock Text="OptiShade  /  What’s new" Foreground="#CEB5FA" FontSize="20" VerticalAlignment="Center"/><Button Name="HeaderClose" Content="&#x2715;" Background="Transparent" HorizontalAlignment="Right" Padding="14,10" Cursor="Hand" ToolTip="Close"/></Grid></Border>
 <Grid Grid.Row="1" Margin="30,24,30,0"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition/></Grid.RowDefinitions><TextBlock Name="Title" FontSize="26" FontWeight="SemiBold"/><TextBlock Grid.Row="1" Text="See the latest changes, fixes and additions in this version." Foreground="#A499B6" Margin="0,8,0,22"/><Border Grid.Row="2" CornerRadius="12" Background="{DynamicResource CardGlass}" BorderBrush="#423454" BorderThickness="1" Padding="18"><TextBox Name="Notes" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Visible" HorizontalScrollBarVisibility="Hidden" Background="Transparent" BorderThickness="0" Foreground="#DDD3EA" FontSize="14" Padding="0,0,12,0"/></Border></Grid>
 <Grid Grid.Row="2" Margin="30,0"><CheckBox Name="Dismiss" Content="Do not show again for this version" VerticalAlignment="Center"/><Button Name="Close" Content="Got it" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid>
 </Grid></Border>
</Window>
'@
 $dialog=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup));$dialog.Owner=$Owner
 $dialog.Height=[Math]::Min($dialog.Height,[Windows.SystemParameters]::WorkArea.Height-24)
 [xml]$theme=Get-Content "$PSScriptRoot/dialog-theme.xaml" -Raw; $dialog.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($theme)))
 $dialog.FindName('Title').Text="What's new in OptiShade 1.0"
 $dialog.FindName('Notes').Text=Get-Content -LiteralPath "$PSScriptRoot/Help/Release-notes.txt" -Raw -Encoding UTF8
 $dialog.FindName('Close').Add_Click({$dialog.Close()})
 $dialog.FindName('HeaderClose').Add_Click({$dialog.Close()})
 $dialog.FindName('DragHeader').Add_MouseLeftButtonDown({if($_.ChangedButton -eq 'Left'){$dialog.DragMove()}})
 $dialog.Add_Closing({if($dialog.FindName('Dismiss').IsChecked){New-Item -ItemType Directory -Path $Store -Force|Out-Null;Set-Content -LiteralPath $marker -Value $notesKey}})
 [void]$dialog.ShowDialog()
}
