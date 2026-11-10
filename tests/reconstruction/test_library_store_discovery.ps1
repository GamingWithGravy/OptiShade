$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$temp=Join-Path ([IO.Path]::GetTempPath()) ('OptiShadeStoreDiscovery-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$oldLocal=$env:LOCALAPPDATA;$oldProgramData=$env:ProgramData
$registryParent='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\OptiShadeDiscoveryFixture-'+[guid]::NewGuid().ToString('N')
$registryFixture=Join-Path $registryParent 'Game';$registryNonGame=Join-Path $registryParent 'Utility'
try{
 $env:LOCALAPPDATA=Join-Path $temp 'local';$env:ProgramData=Join-Path $temp 'programdata'
 [void][IO.Directory]::CreateDirectory($env:LOCALAPPDATA);[void][IO.Directory]::CreateDirectory($env:ProgramData)
 $drive=Join-Path $temp 'drive';[void][IO.Directory]::CreateDirectory($drive)
 $relative=@(
  'GOG Games/GOG Fixture',
  'Amazon Games/Library/Amazon Root Fixture',
  'EA Games/EA Fixture',
  'Origin Games/Origin Fixture',
  'GOG Galaxy/Games/GOG Galaxy Fixture',
  'Ubisoft Game Launcher/games/Ubisoft Fixture',
  'Ubisoft Connect/games/Ubisoft Connect Fixture',
  'Program Files (x86)/Battle.net/Games/Blizzard Fixture',
  'Program Files/Battle.net/Games/Blizzard Fixture 2'
 )
 function WriteFixtureExe([string]$Path){
  $bytes=New-Object byte[] 1024;$memory=[IO.MemoryStream]::new($bytes,$true);$w=[IO.BinaryWriter]::new($memory)
  $w.Write([uint16]0x5a4d);$memory.Position=0x3c;$w.Write([uint32]0x80)
  $memory.Position=0x80;$w.Write([uint32]0x4550);$w.Write([uint16]0x8664);$w.Write([uint16]1)
  $memory.Position=0x94;$w.Write([uint16]240);$w.Write([uint16]2);$w.Write([uint16]0x20b)
  $memory.Position=0x98+60;$w.Write([uint32]512);$memory.Position=0x98+108;$w.Write([uint32]16)
  $memory.Position=0x98+120;$w.Write([uint32]0x1000);$w.Write([uint32]40)
  $memory.Position=0x98+240+8;$w.Write([uint32]512);$w.Write([uint32]0x1000);$w.Write([uint32]512);$w.Write([uint32]512)
  $memory.Position=512+12;$w.Write([uint32]0x1040);$memory.Position=576;$w.Write([Text.Encoding]::ASCII.GetBytes("d3d12.dll`0"));$w.Dispose()
  [IO.File]::WriteAllBytes($Path,$bytes)
 }
 foreach($path in $relative){$folder=Join-Path $drive $path;[void][IO.Directory]::CreateDirectory($folder);WriteFixtureExe (Join-Path $folder ($folder.Substring($folder.LastIndexOf([IO.Path]::DirectorySeparatorChar)+1)+'.exe'))}
 $customFolder=Join-Path $temp 'custom-library/Registry Fixture Game';[void][IO.Directory]::CreateDirectory($customFolder);WriteFixtureExe (Join-Path $customFolder 'Registry Fixture Game.exe')
 $amazonFolder=Join-Path $temp 'amazon-custom/Amazon Registry Fixture';[void][IO.Directory]::CreateDirectory($amazonFolder);WriteFixtureExe (Join-Path $amazonFolder 'Amazon Registry Fixture.exe')
 [void](New-Item -Path $registryFixture -Force)
 New-ItemProperty -LiteralPath $registryFixture -Name DisplayName -Value 'Registry Fixture Game' -PropertyType String -Force|Out-Null
 New-ItemProperty -LiteralPath $registryFixture -Name Publisher -Value 'Ubisoft Entertainment' -PropertyType String -Force|Out-Null
 New-ItemProperty -LiteralPath $registryFixture -Name InstallLocation -Value $customFolder -PropertyType String -Force|Out-Null
 [void](New-Item -Path $registryNonGame -Force)
 New-ItemProperty -LiteralPath $registryNonGame -Name DisplayName -Value 'Registry Fixture Utility' -PropertyType String -Force|Out-Null
 New-ItemProperty -LiteralPath $registryNonGame -Name Publisher -Value 'Example Utility Vendor' -PropertyType String -Force|Out-Null
 New-ItemProperty -LiteralPath $registryNonGame -Name InstallLocation -Value $customFolder -PropertyType String -Force|Out-Null
 $registryAmazon=Join-Path $registryParent 'AmazonGame';[void](New-Item -Path $registryAmazon -Force)
 New-ItemProperty -LiteralPath $registryAmazon -Name DisplayName -Value 'Amazon Registry Fixture' -PropertyType String -Force|Out-Null
 New-ItemProperty -LiteralPath $registryAmazon -Name Publisher -Value 'Amazon Game Studios' -PropertyType String -Force|Out-Null
 New-ItemProperty -LiteralPath $registryAmazon -Name InstallLocation -Value $amazonFolder -PropertyType String -Force|Out-Null
 $registryAmazonApp=Join-Path $registryParent 'AmazonApp';[void](New-Item -Path $registryAmazonApp -Force)
 New-ItemProperty -LiteralPath $registryAmazonApp -Name DisplayName -Value 'Amazon Games' -PropertyType String -Force|Out-Null
 New-ItemProperty -LiteralPath $registryAmazonApp -Name Publisher -Value 'Amazon Games' -PropertyType String -Force|Out-Null
 New-ItemProperty -LiteralPath $registryAmazonApp -Name InstallLocation -Value $amazonFolder -PropertyType String -Force|Out-Null
 foreach($launcher in @(
  [pscustomobject]@{Key='SteamClient';Name='Steam';Publisher='Valve Corporation'},
  [pscustomobject]@{Key='RiotClient';Name='Riot Client';Publisher='Riot Games'},
  [pscustomobject]@{Key='TwoKLauncher';Name='2K Launcher';Publisher='2K Games'},
  [pscustomobject]@{Key='ParadoxLauncher';Name='Paradox Launcher v2';Publisher='Paradox Interactive'},
  [pscustomobject]@{Key='BethesdaLauncher';Name='Bethesda.net Launcher';Publisher='Bethesda Softworks'}
 )){
  $launcherKey=Join-Path $registryParent $launcher.Key;[void](New-Item -Path $launcherKey -Force)
  New-ItemProperty -LiteralPath $launcherKey -Name DisplayName -Value $launcher.Name -PropertyType String -Force|Out-Null
  New-ItemProperty -LiteralPath $launcherKey -Name Publisher -Value $launcher.Publisher -PropertyType String -Force|Out-Null
  New-ItemProperty -LiteralPath $launcherKey -Name InstallLocation -Value $customFolder -PropertyType String -Force|Out-Null
 }
 . (Join-Path $root 'Beta/installer/library.ps1')
 $registryRecords=@(GetFusionRegisteredGameLocations @($registryParent))
 if($registryRecords.Count -ne 2 -or -not @($registryRecords|Where-Object Name -eq 'Registry Fixture Game').Count -or -not @($registryRecords|Where-Object Name -eq 'Amazon Registry Fixture').Count){throw 'The registered-location reader did not admit supported Amazon game records while filtering the Amazon launcher.'}
 function GetFusionRegisteredGameLocations([string[]]$RegistryRoots){return $script:registryRecords}
 function GetFusionInstallState([string]$Store,[string]$Game){return 'Not installed'}
 function GetFusionInstallationReceipts([string]$Store){return @()}
 function Get-PSDrive{param([string]$PSProvider);return @([pscustomobject]@{Root=$drive})}
 $found=@(FindFusionGames (Join-Path $temp 'state'))
 $fixtureFound=@($found|Where-Object {$_.Folder.StartsWith($drive,[StringComparison]::OrdinalIgnoreCase) -or $_.Folder.StartsWith($customFolder,[StringComparison]::OrdinalIgnoreCase) -or $_.Folder.StartsWith($amazonFolder,[StringComparison]::OrdinalIgnoreCase)})
 $expected=@('GOG Fixture','Amazon Root Fixture','EA Fixture','Origin Fixture','GOG Galaxy Fixture','Ubisoft Fixture','Ubisoft Connect Fixture','Blizzard Fixture','Blizzard Fixture 2','Registry Fixture Game','Amazon Registry Fixture')
 foreach($name in $expected){if(-not @($fixtureFound|Where-Object Name -eq $name).Count){throw "Expected common store game was not discovered: $name"}}
 if($fixtureFound.Count -ne $expected.Count){throw "Expected $($expected.Count) fixture games, got $($fixtureFound.Count)."}
 foreach($name in @('2K Launcher','Amazon Games','Battle.net','Bethesda.net Launcher','EA app','EA Desktop','EA Desktop App','Epic Games Launcher','GOG Galaxy','Paradox Launcher','Paradox Launcher v2','REDlauncher','Riot Client','Riot Vanguard','Rockstar Games Launcher','Steam','Ubisoft Anti-Cheat','Ubisoft Connect','Ubisoft Game Launcher','Uplay')){
  if(TestFusionLibraryCandidateName $name){throw "Launcher/support utility was accepted as a game: $name"}
 }
 foreach($name in @('Battlefield 6','Epic Quest','Rockstar North: The Game','Ubisoft World')){
  if(-not(TestFusionLibraryCandidateName $name)){throw "Real game-like title was rejected by an exact utility exclusion: $name"}
 }
 Write-Output "PASS: production scanner accepted all $($fixtureFound.Count) synthetic store/custom-location installs, including Amazon's bounded library root and registered custom location; launcher utility was filtered."
}finally{
 $env:LOCALAPPDATA=$oldLocal;$env:ProgramData=$oldProgramData
 Remove-Item -LiteralPath $registryParent -Recurse -Force -ErrorAction SilentlyContinue
 Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
