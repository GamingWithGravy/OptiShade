$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '../installer'
$fixture=Join-Path $env:TEMP ('OptiShade-switch-worker-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$savedLocal=$env:LOCALAPPDATA;$savedStore=$env:OPTISHADE_STORE;$savedPortable=$env:OPTISHADE_PORTABLE
function Check($condition,[string]$message){if(-not $condition){throw ('FAIL: '+$message)};Write-Output ('PASS: '+$message)}
@'
using System; using System.IO; using System.Reflection;
class Fixture {
 static void Main(string[] args) {
  string exe=Assembly.GetExecutingAssembly().Location, folder=Path.GetDirectoryName(exe);
  if(args.Length<2){File.WriteAllText(exe+".opened","ok");return;}
  string flag=args[0]=="--check-update"?"fail-validation":"fail-apply";
  if(File.Exists(Path.Combine(folder,"no-receipt")))return;
  if(File.Exists(Path.Combine(folder,flag))){File.WriteAllText(args[1],"ERROR: fixture stage failed");Environment.ExitCode=1;return;}
  File.WriteAllText(args[1],"OK");
  File.WriteAllText(exe+(args[0]=="--check-update"?".checked":".applied"),"ok");
 }
}
'@ | Set-Content -LiteralPath "$fixture/fixture.cs"
Push-Location $fixture
try{& "$env:WINDIR/Microsoft.NET/Framework64/v4.0.30319/csc.exe" /nologo /target:winexe /out:fixture.exe fixture.cs}finally{Pop-Location}
if($LASTEXITCODE){throw 'Fixture compilation failed'}
$fixtureHash=(Get-FileHash -LiteralPath "$fixture/fixture.exe").Hash
. "$source/updates.ps1"
# Exercise the exact manager action, with only its UAC launch captured. The
# worker below still runs real child processes and verifies their OK receipts.
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'manager.ps1'),[ref]$tokens,[ref]$errors)
$action=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'StartManagerUpdate'},$false)
if($errors.Count -or -not $action){throw 'Manager action parse failed'}
$helper=Join-Path $fixture 'Helper';[void][IO.Directory]::CreateDirectory($helper)
$action.Extent.Text | Set-Content -LiteralPath "$helper/manager-action.ps1"
foreach($name in @('update-worker.ps1','update-lifecycle.ps1','dialog-theme.xaml')){Copy-Item -LiteralPath (Join-Path $source $name) -Destination $helper}
Copy-Item -LiteralPath "$fixture/fixture.exe" -Destination "$helper/FusionSetup.exe"
. "$helper/manager-action.ps1"
function GetBundledOptiShadeVersion { $script:currentVersion }
function Get-Process {} # Fixture-only: never query or change a live simulator.
function Invoke-RestMethod { ,$script:releaseFixtures }
function Release([string]$version,[bool]$beta=$false){
 $channel=if($beta){'beta'}else{'stable'};$name="OptiShade_Version_$version.exe"
 [pscustomobject]@{draft=$false;prerelease=$beta;tag_name=('v'+$version);body='fixture';assets=@([pscustomobject]@{name=$name;digest=('sha256:'+$fixtureHash);browser_download_url=('https://github.com/GamingWithGravy/OptiShade/releases/download/v'+$version+'/'+[uri]::EscapeDataString($name))})}
}
Add-Type -AssemblyName PresentationFramework
try{
 foreach($case in @('stable-beta','beta-stable','beta-beta','failed-check','failed-apply','missing-receipt','changed-old','wrong-hash','automatic-stable-denied','worker-stable-denied','late-optout')){
  $caseRoot=Join-Path $fixture $case;[void][IO.Directory]::CreateDirectory($caseRoot)
  $env:LOCALAPPDATA=$caseRoot;$env:OPTISHADE_STORE=Join-Path $caseRoot 'Store';$env:OPTISHADE_PORTABLE=''
  $store=$env:OPTISHADE_STORE;$desktop=Join-Path $caseRoot 'Desktop';[void][IO.Directory]::CreateDirectory($desktop)
  $returnStable=$case -in @('beta-stable','failed-apply')
  $fromBeta=$returnStable -or $case -in @('beta-beta','automatic-stable-denied','worker-stable-denied','late-optout')
  $script:currentVersion=if($fromBeta){'P0.21.4-beta.1'}else{'P0.21.4'}
  $Installer=Join-Path $caseRoot $(if($fromBeta){'Optishade 0.21.4-beta.1 beta.exe'}else{'Optishade 0.21.4 stable.exe'})
  Set-Content -LiteralPath $Installer -Value 'original fixture manager'
  $oldHash=(Get-FileHash -LiteralPath $Installer).Hash
  $decoy=Join-Path $caseRoot 'Unrelated.exe';Copy-Item -LiteralPath $Installer -Destination $decoy
  SetOptiShadeUpdateChannel $true
  $script:releaseFixtures=@((Release '0.21.4'),(Release '0.21.5'),(Release '0.21.5-beta.1' $true))
  $update=if($returnStable -or $case -eq 'automatic-stable-denied'){@(GetOptiShadePreviousReleases|Sort-Object {[version]$_.Version} -Descending)[0]}else{GetOptiShadeUpdate -Current ($script:currentVersion.TrimStart('P')) -ReportErrors}
  if($returnStable){Check ($update.Version -eq '0.21.5') "$case chooses current latest stable"}
  $script:busy=$false;$status=[pscustomobject]@{Text=''};$form=[pscustomobject]@{Closed=$false}
  $form|Add-Member ScriptMethod Close {$this.Closed=$true}
  $script:workerConfig=$null
  function Start-Process {param($FilePath,$ArgumentList,$WindowStyle,$Verb)
   if($Verb -ne 'RunAs' -or $WindowStyle -ne 'Hidden' -or $ArgumentList[0] -ne '--update-worker'){throw 'Unexpected manager launch'}
   $script:workerConfig=$ArgumentList[1].Trim('"')
  }
  try{StartManagerUpdate $update -ReturnToStable:$returnStable}finally{Remove-Item Function:/Start-Process}
  if($case -eq 'automatic-stable-denied'){
   Check (-not $script:workerConfig -and -not $form.Closed -and $status.Text -like '*only download beta*' -and (Get-FileHash $Installer).Hash -eq $oldHash) 'beta automatic stable request denied before download'
   continue
  }
  Check ($script:workerConfig -and $form.Closed) "$case manager prepares request and closes"
  $settings=Get-Content -LiteralPath $script:workerConfig -Raw|ConvertFrom-Json
  # Redirect only the desktop; identity and intent come from the manager action.
  $settings.Desktop=$desktop
  Check ($settings.PreviousHash -eq $oldHash -and $settings.Installer -eq $Installer -and $settings.ExplicitReturnToStable -eq $returnStable) "$case carries previous hash and explicit intent"
  if($case -eq 'wrong-hash'){$settings.SHA256='0'*64}
  if($case -eq 'worker-stable-denied'){
   $stable=@(GetOptiShadePreviousReleases|Sort-Object {[version]$_.Version} -Descending)[0]
   foreach($property in @('Version','Url','SHA256','Rollback','Channel','Prerelease')){$settings.$property=$stable.$property}
  }
  if($case -eq 'late-optout'){SetOptiShadeUpdateChannel $false}
  $channelBeforeWorker=GetOptiShadeUpdateChannel
  $settings|ConvertTo-Json|Set-Content -LiteralPath $script:workerConfig
  $work=Split-Path $script:workerConfig
  if($case -eq 'failed-check'){Set-Content -LiteralPath "$work/fail-validation" -Value 'failure'}
  if($case -eq 'failed-apply'){Set-Content -LiteralPath "$desktop/fail-apply" -Value 'failure'}
  if($case -eq 'missing-receipt'){Set-Content -LiteralPath "$work/no-receipt" -Value 'failure'}
  if($case -eq 'changed-old'){Set-Content -LiteralPath $Installer -Value 'externally modified manager'}
  $retainedHash=(Get-FileHash -LiteralPath $Installer).Hash
  $script:downloadFixture=Join-Path $fixture 'fixture.exe';$script:downloads=0
  function New-Object([string]$TypeName){
   if($TypeName -ne 'Net.WebClient'){throw 'Unexpected worker object'}
   $web=[pscustomobject]@{Headers=@{}}
   $web|Add-Member ScriptMethod DownloadFileTaskAsync {param($uri,$dest)$script:downloads++;Copy-Item -LiteralPath $script:downloadFixture -Destination $dest;return [Threading.Tasks.Task]::FromResult(0)}
   $web|Add-Member ScriptMethod Dispose {}; $web|Add-Member ScriptMethod CancelAsync {};return $web
  }
  $window=$null;$script:finished=$false;$script:timedOut=$false;$script:finalStatus=''
  $timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(50);$clock=[Diagnostics.Stopwatch]::StartNew()
  $timer.Add_Tick({
   if($window){$window.Opacity=0;$window.ShowInTaskbar=$false}
   if($clock.Elapsed.TotalSeconds -gt 45){$script:timedOut=$true;$script:updating=$false}
   if($window -and -not $script:updating){$script:finalStatus=$window.FindName('Status').Text;$script:finished=$true;$timer.Stop();$window.Close()}
  });$timer.Start()
  try{. "$source/update-worker.ps1" -Config $script:workerConfig}finally{$timer.Stop();Remove-Item Function:/New-Object}
  $expectedDownloads=if($case -in @('worker-stable-denied','late-optout')){0}else{1}
  Check ($script:finished -and -not $script:timedOut -and $script:downloads -eq $expectedDownloads) "$case real worker finishes with $expectedDownloads download(s)"
  $failure=$case -in @('failed-check','failed-apply','missing-receipt','wrong-hash','worker-stable-denied','late-optout')
  if($failure){
   Check ($script:finalStatus -like 'Update stopped.*' -and (Get-FileHash -LiteralPath $Installer).Hash -eq $retainedHash -and (GetOptiShadeUpdateChannel) -eq $channelBeforeWorker) "$case retains previous EXE and channel on failure"
  }else{
   Check ($script:finalStatus -match '^(Update|Rollback) complete\.' -and (Get-FileHash -LiteralPath $script:target).Hash -eq $fixtureHash -and (Test-Path -LiteralPath ($script:target+'.applied'))) "$case receives install receipt and saves verified Desktop EXE"
   if($case -eq 'changed-old'){Check ((Get-FileHash -LiteralPath $Installer).Hash -eq $retainedHash -and $script:finalStatus -like '*changed or is linked*') 'changed EXE retained with visible reason'}
   else{Check (-not(Test-Path -LiteralPath $Installer)) "$case removes exact previous EXE after success"}
   Check ((GetOptiShadeUpdateChannel) -eq $settings.Channel) "$case persists completed channel"
  }
  Check ((Get-FileHash -LiteralPath $decoy).Hash -eq $oldHash -and -not(Test-Path -LiteralPath ($script:target+'.opened'))) "$case preserves unrelated matching EXE and does not auto-launch"
 }
 'Fixture: '+$fixture
}finally{$env:LOCALAPPDATA=$savedLocal;$env:OPTISHADE_STORE=$savedStore;$env:OPTISHADE_PORTABLE=$savedPortable}
