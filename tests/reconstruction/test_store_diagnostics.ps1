$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
[void][Reflection.Assembly]::LoadFrom((Join-Path $root 'Beta/installer/OptiShade-Troubleshooter.exe'))
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('optishade-store-discovery-'+[guid]::NewGuid().ToString('N'))
$previousStore=$env:OPTISHADE_STORE
try {
 $env:OPTISHADE_STORE=Join-Path $fixture 'store'
 $package=Join-Path $fixture 'WindowsApps/Microsoft.Limitless_fixture'
 $steam=Join-Path $fixture 'Steam/MSFS'
 $empty=Join-Path $fixture 'WindowsApps/EmptyPackage'
 foreach($dir in @($package,$steam,$empty)){[void][IO.Directory]::CreateDirectory($dir)}
 foreach($dir in @($package,$steam)){[IO.File]::WriteAllText((Join-Path $dir 'FlightSimulator2024.exe'),'fixture metadata only')}
 if([OptiShade.TesterKit.Collector]::ResolveGameFolder($package) -ine $package){throw 'Readable Store package was excluded'}
 if([OptiShade.TesterKit.Collector]::ResolveGameFolder($steam) -ine $steam){throw 'Steam folder regressed'}
 if($null -ne [OptiShade.TesterKit.Collector]::ResolveGameFolder($empty)){throw 'Empty package accepted without executable evidence'}
 if([OptiShade.TesterKit.Collector]::SameGameExecutable((Join-Path $package 'FlightSimulator2024.exe'),(Join-Path $steam 'FlightSimulator2024.exe'))){throw 'Different installations were conflated'}
 $receipt=Join-Path $env:OPTISHADE_STORE 'Games/fixture'
 [void][IO.Directory]::CreateDirectory($receipt)
 @{Game=$package;LaunchExe=(Join-Path $package 'gamelaunchhelper.exe');Status='Installed'}|ConvertTo-Json|Set-Content (Join-Path $receipt 'manifest.json')
 if([OptiShade.TesterKit.Collector]::Discover() -notcontains $package){throw 'Recorded Store game missing from discovery'}
 $nested=Join-Path $fixture 'XboxGames/MSFS/Content'
 [void][IO.Directory]::CreateDirectory($nested)
 [IO.File]::WriteAllText((Join-Path $nested 'FlightSimulator2024.exe'),'fixture metadata only')
 if([OptiShade.TesterKit.Collector]::ResolveGameFolder((Split-Path $nested)) -ine $nested){throw 'Xbox Content folder discovery regressed'}
 'PASS: Store package, receipt discovery, Xbox Content, Steam, empty package refusal and distinct installations.'
} finally {
 $env:OPTISHADE_STORE=$previousStore
 # Keep this tiny fixture for inspection; no game or installed receipt is changed.
 Write-Output ('Fixture retained: '+$fixture)
}
