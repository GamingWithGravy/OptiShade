$ErrorActionPreference='Stop'
$fixture=Join-Path $env:TEMP ('OptiShade-worker-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force|Out-Null
@'
using System; using System.IO; using System.Reflection;
class TestApp { static void Main(string[] args) {var p=Assembly.GetExecutingAssembly().Location;File.WriteAllText(p+(args.Length>0?".applied":".opened"),"ok");} }
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
. "$PSScriptRoot/../installer/update-worker.ps1" -Config "$fixture/config.json"
Start-Sleep -Milliseconds 500
foreach($name in @('current.exe.previous','current.exe.applied','current.exe.opened')){if(-not(Test-Path "$fixture/$name")){throw "Missing updater result: $name"}}
'PASS: update window verifies, replaces installer, runs game update helper, then reopens setup'
'Fixture: '+$fixture
