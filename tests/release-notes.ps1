$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework
. "$PSScriptRoot/../installer/release-notes.ps1"
if(-not [Windows.Application]::Current){$app=[Windows.Application]::new();$app.ShutdownMode='OnExplicitShutdown'}
$store=Join-Path $env:TEMP ('OptiShade-notes-'+[guid]::NewGuid().ToString('N'))
$owner=[Windows.Window]::new();$owner.Opacity=0;$owner.ShowInTaskbar=$false;$owner.Show()
$script:seen=0
$timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(100)
$timer.Add_Tick({foreach($w in @($owner.OwnedWindows)){if($w.FindName('Dismiss')){
 $script:seen++;$w.Opacity=0
 if($w.FindName('Notes').Text -match 'https?://'){throw 'Download link found in release notes'}
 $w.FindName('Dismiss').IsChecked=$true;$w.FindName('Close').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));$timer.Stop()
}}})
$timer.Start();ShowReleaseNotes $owner $store
ShowReleaseNotes $owner $store
if($script:seen -ne 1){throw 'Notes suppression failed'}
$owner.Close()
'PASS: patch notes show once when dismissed; no download links'
