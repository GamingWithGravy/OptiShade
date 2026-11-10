$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Beta/installer/dialogs.ps1"
foreach($choice in @('Dismiss','Yes')){
 $probe=@{Choice=$choice;Seen=$false}
 $timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(100)
 $timer.Add_Tick({
  foreach($source in @([Windows.PresentationSource]::CurrentSources)){
   $w=$source.RootVisual
   if($w -is [Windows.Window] -and $w.Title -eq 'Fixture confirmation'){
    $probe.Seen=$true;$timer.Stop()
    if($probe.Choice -eq 'Dismiss'){$w.FindName('Dismiss').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
    else{($w.FindName('Actions').Children|Where-Object Tag -eq 'Yes').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
   }
  }
 }.GetNewClosure())
 $timer.Start()
 try{$result=ShowOptiShadeDialog $null 'UI fixture only. No installer action is invoked.' 'Fixture confirmation' 'YesNo' 'Question' 'No'}finally{$timer.Stop()}
 $expected=if($choice -eq 'Dismiss'){'No'}else{'Yes'}
 if(-not $probe.Seen -or $result.ToString() -ne $expected){throw "Wrong dialog result for $choice"}
}
'PASS: themed confirmation opens; closing defaults to No; explicit Yes returns Yes. No installation invoked.'
