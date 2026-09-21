$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework
. "$PSScriptRoot/../installer/consent.ps1"
[xml]$markup=Get-Content "$PSScriptRoot/../installer/manager.xaml" -Raw -Encoding UTF8
$owner=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $markup));$owner.Opacity=0;$owner.ShowInTaskbar=$false;$owner.Show()
try {
 foreach($script:answer in @('Yes','No','Close')){
  $timer=New-Object Windows.Threading.DispatcherTimer;$timer.Interval=[TimeSpan]::FromMilliseconds(80)
  $timer.Add_Tick({foreach($w in $owner.OwnedWindows){$w.Opacity=0;if($script:answer -eq 'Close'){$w.Close()}else{$w.FindName($script:answer).RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))};$timer.Stop();break}})
  $timer.Start();$choice=ConfirmOptionalDlss $owner $true;$timer.Stop()
  if($script:answer -eq 'Yes' -and $choice -ne $true){throw 'Yes failed'}
  if($script:answer -eq 'No' -and $choice -ne $false){throw 'No failed'}
  if($script:answer -eq 'Close' -and $null -ne $choice){throw 'Cancel failed'}
  "PASS: optional DLSS dialog $script:answer"
 }
 foreach($case in @(@($true,$true,$true),@($false,$true,$false),@($true,$false,$false),@($null,$true,$false))){
  $result=UseOptionalDlss ([pscustomobject]@{OptionalDlss=$case[0]}) ([pscustomobject]@{DownloadNvidia=$case[1]})
  if($result -ne $case[2]){throw 'Download choice was not respected'}
 }
 'PASS: downloads respect saved choice and compatibility, including older manifests'
} finally {$owner.Close()}
