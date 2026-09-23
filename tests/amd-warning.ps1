$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework
. "$PSScriptRoot/../installer/consent.ps1"
foreach($names in @('NVIDIA GeForce RTX 5090, AMD Radeon(TM) Graphics','AMD Radeon(TM) Graphics, NVIDIA GeForce RTX 5070 Ti','NVIDIA GeForce RTX 3080')){
 if(ShouldWarnAmdExperimental ([pscustomobject]@{Known=$true;Nvidia=$true;Names=$names})){throw 'NVIDIA system received an AMD-only warning'}
}
foreach($names in @('AMD Radeon RX 9070','AMD Radeon RX 7900 XTX','Intel UHD Graphics, AMD Radeon RX 6800')){
 if(-not(ShouldWarnAmdExperimental ([pscustomobject]@{Known=$true;Nvidia=$false;Names=$names}))){throw 'AMD system lost its warning'}
}
if(ShouldWarnAmdExperimental ([pscustomobject]@{Known=$false;Nvidia=$false;Names='Unknown'})){throw 'Unknown GPU incorrectly classified as AMD'}
if(ShouldWarnAmdExperimental ([pscustomobject]@{Known=$true;Nvidia=$false;Names='NVIDIA GeForce RTX 5090, AMD Radeon(TM) Graphics'})){throw 'Mixed inventory warning depends on cached flag'}
foreach($names in @('AMD Radeon(TM) Graphics','AMD Radeon 780M','AMD Radeon RX Vega 11 Graphics','AMD Radeon Vega 8 Graphics','AMD Radeon 890M','AMD Radeon Unknown')){
 if(ShouldWarnAmdExperimental ([pscustomobject]@{Known=$true;Nvidia=$false;Names=$names})){throw 'Integrated or unclassified Radeon received dedicated-GPU warning'}
}
'PASS: dedicated AMD-only warns; integrated, unclassified and NVIDIA mixed systems skip warning'
[xml]$markup=Get-Content "$PSScriptRoot/../installer/manager.xaml" -Raw -Encoding UTF8
$owner=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($markup));$owner.Opacity=0;$owner.ShowInTaskbar=$false;$owner.Show()
$timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(40)
$script:choice='Continue';$script:seen=0
$timer.Add_Tick({
 foreach($window in @($owner.OwnedWindows)){
  if($window.Title -ne 'AMD experimental support'){continue}
  $window.Opacity=0;$script:seen++
  if($script:seen -eq 1){
   $content=$window.Content;$content.UpdateLayout()
   $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new(([int]$content.ActualWidth+56),([int]$content.ActualHeight+56),96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($content)
   $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
   $dest=Join-Path $PSScriptRoot '../test-run/amd-warning.png';$stream=[IO.File]::Create($dest);try{$encoder.Save($stream)}finally{$stream.Dispose()}
  }
  $window.FindName($script:choice).RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));$timer.Stop()
 }
})
try{
 $timer.Start();if(-not(ConfirmAmdExperimental $owner)){throw 'Continue did not accept AMD warning'}
 $script:choice='Cancel';$timer.Start();if(ConfirmAmdExperimental $owner){throw 'Cancel accepted AMD warning'}
 if($script:seen -ne 2){throw 'AMD warning not shown for both cases'}
 'PASS: AMD warning Continue and Cancel outcomes; rendered dialog captured'
}finally{$timer.Stop();$owner.Close()}
