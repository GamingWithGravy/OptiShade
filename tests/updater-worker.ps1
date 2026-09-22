$ErrorActionPreference='Stop'
$fixture=Join-Path $env:TEMP ('OptiShade-worker-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force|Out-Null
@'
using System; using System.IO; using System.Reflection;
class TestApp { static void Main(string[] args) {var p=Assembly.GetExecutingAssembly().Location;if(args.Length>1){if(args[0]=="--check-update" && File.Exists(Path.Combine(Path.GetDirectoryName(p),"fail-validation"))){File.WriteAllText(args[1],"ERROR: damaged fixture payload");Environment.ExitCode=1;return;}File.WriteAllText(args[1],"OK");}File.WriteAllText(p+(args.Length>0?(args[0]=="--check-update"?".checked":".applied"):".opened"),"ok");} }
'@|Set-Content "$fixture/test.cs"
Push-Location $fixture
try{& "$env:SystemRoot/Microsoft.NET/Framework64/v4.0.30319/csc.exe" /nologo /target:winexe /out:new.exe test.cs}finally{Pop-Location}
if($LASTEXITCODE){throw 'Fixture compile failed'}
Copy-Item "$fixture/new.exe" "$fixture/current.exe"
$script:downloadFixture="$fixture/new.exe"
$config=@{Installer="$fixture/current.exe";Url='https://github.com/GamingWithGravy/OptiShade_V0.19.17/releases/download/v9.0.0/test.exe';Version='9.0.0';SHA256=(Get-FileHash "$fixture/new.exe").Hash;Notes='Fixture update; no game installation touched.'}
$config|ConvertTo-Json|Set-Content "$fixture/config.json"
# Isolate the test from live processes and the network. All file replacement,
# verification and child-process execution still run through the real worker.
function Get-Process {}
function New-Object([string]$TypeName){
 if($TypeName -ne 'Net.WebClient'){throw 'Unexpected object in worker fixture'}
 $web=[pscustomobject]@{Headers=@{}}
 $web|Add-Member ScriptMethod DownloadFileTaskAsync {param($uri,$dest) Copy-Item -LiteralPath $script:downloadFixture -Destination $dest;return [Threading.Tasks.Task]::FromResult(0)}
 $web|Add-Member ScriptMethod Dispose {}
 $web|Add-Member ScriptMethod CancelAsync {}
 return $web
}
Add-Type -AssemblyName PresentationFramework
$script:launchChecked=$false
$timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(100)
$timer.Add_Tick({if($window -and $window.FindName('Launch').Visibility -eq 'Visible'){
 if(Test-Path "$fixture/current.exe.opened"){throw 'Installer restarted before Launch was clicked'}
 if($window.FindName('Progress').Value -ne 100){throw 'Completion progress not shown'}
 if($window.FindName('DoneClose').Visibility -ne 'Visible'){throw 'Completion Close button missing'}
 $script:launchChecked=$true;$timer.Stop();$window.FindName('Launch').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
}});$timer.Start()
. "$PSScriptRoot/../installer/update-worker.ps1" -Config "$fixture/config.json"
if(-not $script:launchChecked){throw 'Completion screen was not checked'}
Start-Sleep -Milliseconds 500
foreach($name in @('download.exe.checked','current.exe.applied','current.exe.opened')){if(-not(Test-Path "$fixture/$name")){throw "Missing updater result: $name"}}
'PASS: update window verifies, replaces installer, runs game update helper, then reopens setup'
'Fixture: '+$fixture
if(Test-Path "$fixture/current.exe.previous"){throw 'Successful update left recovery copy behind'}
$before=(Get-FileHash "$fixture/current.exe").Hash
Set-Content "$fixture/fail-validation" 'fail'
$script:failureChecked=$false
$failureTimer=[Windows.Threading.DispatcherTimer]::new();$failureTimer.Interval=[TimeSpan]::FromMilliseconds(100)
$failureTimer.Add_Tick({if($window -and $window.FindName('Status').Text -like 'Update stopped.*'){$script:failureChecked=$true;$failureTimer.Stop();$window.Close()}})
$failureTimer.Start()
. "$PSScriptRoot/../installer/update-worker.ps1" -Config "$fixture/config.json"
if(-not $script:failureChecked -or (Get-FileHash "$fixture/current.exe").Hash -ne $before -or (Test-Path "$fixture/current.exe.previous")){throw 'Failed staged validation modified the installer'}
'PASS: failed staged payload check leaves original installer untouched'