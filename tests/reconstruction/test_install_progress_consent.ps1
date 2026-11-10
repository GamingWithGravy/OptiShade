$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Beta/installer/operation-progress-store.ps1"
$fixture=Join-Path $root ('test-run/progress-consent-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$progressFile=Join-Path $fixture 'progress.json'
$configFile=Join-Path $fixture 'config.json'
@{Title='Progress fixture';ProgressPath=$progressFile;ParentPid=$PID}|ConvertTo-Json|Set-Content $configFile
WriteOptiShadeOperationProgressState $progressFile @{Title='Progress fixture';Status='Running';Total=0;Completed=0}
$check=@{Stage=0;Failure=$null;Started=[datetime]::UtcNow}
$control=[Windows.Threading.DispatcherTimer]::new();$control.Interval=[TimeSpan]::FromMilliseconds(700)
$tick={
 try{
  if(([datetime]::UtcNow-$check.Started).TotalSeconds -gt 10){throw 'Progress transition timed out'}
  $w=@([Windows.Application]::Current.Windows|Where-Object Title -eq 'OptiShade operation')[0]
  switch($check.Stage){
   0 {if(-not $w.IsVisible){throw 'Progress was not shown'};WriteOptiShadeOperationProgressState $progressFile @{Status='AwaitingConsent';Total=0;Completed=0};$check.Stage=1}
   1 {if($w.IsVisible){throw 'Progress remained visible behind consent'};WriteOptiShadeOperationProgressState $progressFile @{Status='Running';Detail='Installing component';Total=10;Completed=7};$check.Stage=2}
   2 {if(-not $w.IsVisible){throw 'Progress failed to resume'};WriteOptiShadeOperationProgressState $progressFile @{Status='Failed';Detail='Component install failed';Total=10;Completed=7};$check.Stage=3}
   3 {
    if(-not $w.IsVisible){throw 'Failure window closed before the tester could read it'}
    if($w.FindName('OperationFooter').Text -notmatch '^FAILED\.' -or $w.FindName('Dismiss').Visibility -ne 'Visible'){throw 'Failure status or dismiss action was not shown'}
    if([int]$w.FindName('OperationProgress').Value -ne 7){throw 'Failure progress was incorrectly reported as complete'}
    $check.ClosedWindow=$w
    $w.FindName('Dismiss').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    $check.Stage=4
   }
  }
 }catch{$check.Failure=$_.Exception.Message;WriteOptiShadeOperationProgressState $progressFile @{Status='Completed';Total=1;Completed=1};$control.Stop()}
}.GetNewClosure()
$control.Add_Tick($tick)
$app=[Windows.Application]::new();$app.ShutdownMode='OnExplicitShutdown'
$control.Start()
& "$root/Beta/installer/operation-progress.ps1" -Config $configFile
if($check.Failure){throw $check.Failure}
if($check.Stage -ne 4 -or $check.ClosedWindow.IsVisible){throw 'Dismiss did not close the failed operation window'}
'PASS: actual progress window hides during consent, resumes, clearly holds a failed partial result, and closes after a successful completion'

