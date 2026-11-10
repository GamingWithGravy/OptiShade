param([string]$Root=(Join-Path $PSScriptRoot '../..'))
$ErrorActionPreference='Stop'
$installer=Join-Path $Root 'Beta/installer'
. "$installer/ownership.ps1"
function Check($Value,[string]$Message){if(-not $Value){throw $Message};Write-Output ('PASS: '+$Message)}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-HelperReceipt-'+[guid]::NewGuid().ToString('N'))
$game=Join-Path $fixture 'X-Plane 12';$tools=Join-Path $game 'OptiShadeData/Tools';$state=Join-Path $fixture 'portable-store'
$oldStore=$env:OPTISHADE_STORE;$oldLocal=$env:LOCALAPPDATA;$oldConsent=$env:OPTISHADE_ANTICHEAT_SESSION_ACCEPTED
try{
 [void][IO.Directory]::CreateDirectory($tools);[void][IO.Directory]::CreateDirectory((Join-Path $game 'OptiShadeData/Shaders'))
 $env:LOCALAPPDATA=Join-Path $fixture 'profile';$env:OPTISHADE_STORE=$null
 # Model a helper spawned from a launcher session after the global warning
 # was accepted. The fresh-install path below still verifies per-installation
 # consent when there is no valid installed receipt.
 $env:OPTISHADE_ANTICHEAT_SESSION_ACCEPTED='1'
 [IO.File]::WriteAllText((Join-Path $game 'X-Plane.exe'),'not executable: isolated fixture')
 [IO.File]::WriteAllText((Join-Path $game 'OptiScaler.ini'),'[Menu]')
 [IO.File]::WriteAllText((Join-Path $game 'OptiShadeData/dependency-state.ini'),"[Storage]`nRoot=$state")
 $receipt=ManifestPath $state $game
 [void][IO.Directory]::CreateDirectory((Split-Path $receipt))
 $manifest=[pscustomobject]@{Game=$game;Status='Installed';Files=@([pscustomobject]@{Path='dxgi.dll';Hash=('a'*64)})}
 WriteState $manifest $receipt
 # Mirror the actual package closure, not the manager's preloaded session.
 $package=[IO.File]::ReadAllText((Join-Path $Root 'Beta/package.ps1'))
 $match=[regex]::Match($package,'foreach\(\$dependency in @\((?<files>[^\r\n]+)\)\)\{Copy-Item -LiteralPath "\$root/installer/\$dependency"')
 Check $match.Success 'packaged helper dependency closure is explicit'
 $files=@([regex]::Matches($match.Groups['files'].Value,"'([^']+)'")|ForEach-Object {$_.Groups[1].Value})
 foreach($name in @('import-effects.ps1','store-paths.ps1','EffectPackages.ini')+$files){Copy-Item -LiteralPath (Join-Path $installer $name) -Destination (Join-Path $tools $name)}
 Add-Type -AssemblyName System.IO.Compression.FileSystem
 $archive=Join-Path $fixture 'look.zip';$zip=[IO.Compression.ZipFile]::Open($archive,'Create')
 try{$entry=$zip.CreateEntry('Shaders/ReceiptFixture.fx');$writer=[IO.StreamWriter]::new($entry.Open());try{$writer.Write('technique ReceiptFixture { }')}finally{$writer.Dispose()}}finally{$zip.Dispose()}
 $result=Join-Path $game 'OptiShadeData/fixture-result.txt'
 & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $tools 'import-effects.ps1') -Archive $archive -Game $game -Result 'fixture-result.txt'
 Check ($LASTEXITCODE -eq 0 -and [IO.File]::ReadAllText($result).StartsWith('OK:')) 'fresh extracted importer resolves portable ownership after launcher-wide consent without another maintenance prompt'
 Check (@(Get-ChildItem -LiteralPath (Join-Path $game 'OptiShadeData/Shaders') -Filter ReceiptFixture.fx -Recurse).Count -eq 1) 'fresh helper performed the actual isolated FX import'
 $before=(Get-FileHash -LiteralPath $receipt).Hash
 $preset=Join-Path $game 'OptiShadeData/test-look.ini';[IO.File]::WriteAllText($preset,'Techniques=ReceiptFixture@ReceiptFixture.fx')
 & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $tools 'import-effects.ps1') -Preset $preset -Game $game -Result 'fixture-result.txt'
 Check ($LASTEXITCODE -eq 0 -and [IO.File]::ReadAllText($result).StartsWith('OK:')) 'fresh preset dependency helper passes installed-game gate with shaders already present (offline)'
 Check ((Get-FileHash -LiteralPath $receipt).Hash -eq $before) 'maintenance recognition does not rewrite the ownership receipt'
 $env:OPTISHADE_STORE=Join-Path $fixture 'wrong-env-store'
 Check ((GetOptiShadeExistingInstallation $game).Path -eq $receipt) 'portable canonical receipt survives an unrelated inherited store environment'
 foreach($status in @('Restored','Installing')){
  $manifest.Status=$status;WriteState $manifest $receipt
  Check (-not(TestAntiCheatExistingInstallation $game)) "receipt state $status cannot bypass first-install consent"
 }
 $manifest.Status='Installed';$manifest.Game=Join-Path $fixture 'Other game';WriteState $manifest $receipt
 Check (-not(TestAntiCheatExistingInstallation $game)) 'pointer to another game cannot establish ownership'
 $manifest.Game=$game;$manifest.Files[0].Hash='invalid';WriteState $manifest $receipt
 Check (-not(TestAntiCheatExistingInstallation $game)) 'receipt without a valid owned-file digest cannot establish maintenance'
 Remove-Item -LiteralPath $receipt
 # A fresh helper without either saved consent or the accepted launcher
 # session must be denied before it can mutate the game.
 $env:OPTISHADE_ANTICHEAT_SESSION_ACCEPTED=$null
 & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $tools 'import-effects.ps1') -Preset $preset -Game $game -Result 'fixture-result.txt'
 Check ($LASTEXITCODE -ne 0 -and [IO.File]::ReadAllText($result) -match 'UserConsentRequired') 'unrecorded fresh helper still requires initial-install consent before mutation'
}finally{
 $env:OPTISHADE_STORE=$oldStore;$env:LOCALAPPDATA=$oldLocal;$env:OPTISHADE_ANTICHEAT_SESSION_ACCEPTED=$oldConsent
 # The generated absolute fixture root is the only cleanup target.
 if($fixture.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue}
}
