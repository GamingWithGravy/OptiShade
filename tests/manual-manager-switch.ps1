$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/ownership.ps1"
. "$PSScriptRoot/../installer/update-lifecycle.ps1"
function AssertClosed($Game){} # All installations below are synthetic folders.
function Check($ok,$message){if(-not $ok){throw ('FAIL: '+$message)};'PASS: '+$message}
$fixture=Join-Path $env:TEMP ('OptiShade-manual-switch-'+[guid]::NewGuid().ToString('N'))
$game=Join-Path $fixture 'Game';$payload=Join-Path $fixture 'Payload';$store=Join-Path $fixture 'Store'
[void][IO.Directory]::CreateDirectory($game);[void][IO.Directory]::CreateDirectory($payload)
$savedPortable=$env:OPTISHADE_PORTABLE;$env:OPTISHADE_PORTABLE=''
function GetBundledOptiShadeVersion {$script:fixtureVersion}
function InstallFixture($exe,$version,$prior=$null){
 $script:fixtureVersion=$version
 Set-Content -LiteralPath (Join-Path $payload 'winmm.dll') -Value $version
 @(@{Path='winmm.dll';Hash=(HashFile (Join-Path $payload 'winmm.dll'))})|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $payload 'files.json')
 $manifest=InstallFusion $game $payload $store $exe 'winmm.dll' @(FindFusionConflicts $game) -ReplaceExisting ([bool]$prior) -PreserveConfiguration $true
 CompleteOptiShadeManualInstall $manifest $exe $version $store $prior
 return $manifest
}
try{
 $old=Join-Path $fixture 'renamed stable manager.exe';$beta=Join-Path $fixture 'downloaded beta.exe';$new=Join-Path $fixture 'new stable.exe'
 Set-Content $old 'stable manager';Set-Content $beta 'beta manager';Set-Content $new 'latest stable manager'
 $foreign=Join-Path $fixture 'third-party.exe';Copy-Item -LiteralPath $old -Destination $foreign;$foreignHash=HashFile $foreign
 Check (TestOptiShadeChannelChange 'P0.21.4' 'P0.21.4-beta.1') 'same-base manual stable to beta is an explicit channel change'
 Check (TestOptiShadeChannelChange 'P0.21.4-beta.1' 'P0.21.4') 'same-base manual beta to stable is an explicit channel change'
 Check (-not(TestOptiShadeChannelChange 'P0.21.4' 'P0.21.3')) 'ordinary downgrade is not mistaken for a channel change'
 $manifest=@(InstallFixture $old 'P0.21.4')[-1]
 $receipt=Join-Path $store 'manager-installed.json';$saved=Get-Content $receipt -Raw|ConvertFrom-Json
 Check ($saved.Installer -eq $old -and $saved.SHA256 -eq (HashFile $old)) 'successful manual install records exact renamed EXE and hash'
 $prior=Get-Content $manifest -Raw|ConvertFrom-Json
 $manifest=@(InstallFixture $beta 'P0.21.4-beta.1' $prior)[-1]
 Check (-not(Test-Path $old) -and (Test-Path $beta) -and (Test-Path "$store/beta-updates.txt")) 'manual beta install deletes only recorded stable EXE after success'
 $prior=Get-Content $manifest -Raw|ConvertFrom-Json
 $manifest=@(InstallFixture $new 'P0.21.4' $prior)[-1]
 Check (-not(Test-Path $beta) -and (Test-Path $new) -and -not(Test-Path "$store/beta-updates.txt") -and (Test-Path "$store/stable-updates.txt")) 'manual stable install deletes recorded beta and resets opt-in'
 # Changing the old EXE after its receipt was recorded must preserve it.
 Set-Content $new 'changed by somebody else';Set-Content $beta 'fresh beta download'
 $prior=Get-Content $manifest -Raw|ConvertFrom-Json
 $result=@(InstallFixture $beta 'P0.21.4-beta.1' $prior);$manifest=$result[-1]
 Check ((Get-Content $new) -eq 'changed by somebody else' -and ($result -join ' ') -like '*changed or is linked*') 'modified previous manager is retained with explanation'
 $receiptHash=HashFile $receipt;$betaHash=HashFile $beta
 # A failed install cannot qualify for successful-manager cleanup.
 Set-Content (Join-Path $payload 'winmm.dll') 'corrupt payload'
 $failed=$false
 try{InstallFusion $game $payload $store $new 'winmm.dll' @(FindFusionConflicts $game) -ReplaceExisting $true -PreserveConfiguration $true|Out-Null}catch{$failed=$true}
 Check ($failed -and (HashFile $receipt) -eq $receiptHash -and (HashFile $beta) -eq $betaHash) 'failed manual install preserves previous manager and manager receipt'
 $failed=$false
 try{CompleteOptiShadeManualInstall $manifest $new 'P0.21.4' $store $prior|Out-Null}catch{$failed=$true}
 Check ($failed -and (HashFile $beta) -eq $betaHash) 'failed or wrong-version game receipt cannot authorize cleanup'
 # Legacy manifests have a path but no trusted installer hash. Never adopt its
 # current contents as the historical expected hash merely to remove the file.
 Remove-Item -LiteralPath $receipt
 Set-Content $new 'legacy manager retained'
 $prior=[pscustomobject]@{Installer=$new;Version='P0.21.3';Status='Installed'}
 $result=@(InstallFixture $beta 'P0.21.4-beta.1' $prior)
 Check ((Test-Path $new) -and ($result -join ' ') -like '*no recorded verification hash*') 'unverifiable legacy manager remains with a clear notice'
 Check ((HashFile $foreign) -eq $foreignHash) 'no directory-name or same-hash scan removes unrelated executables'
 'Fixture: '+$fixture
}finally{$env:OPTISHADE_PORTABLE=$savedPortable}
