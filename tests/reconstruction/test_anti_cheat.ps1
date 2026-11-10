param([string]$Root=(Join-Path $PSScriptRoot '../..'))
$ErrorActionPreference='Stop'
$installer=Join-Path $Root 'Beta/installer'
. "$installer/anti-cheat.ps1"
. "$installer/consent.ps1"
function Check($Value,[string]$Message){if(-not $Value){throw $Message};Write-Output ('PASS: '+$Message)}
$managerSource=Get-Content -LiteralPath (Join-Path $installer 'manager.ps1') -Raw -Encoding UTF8
$antiCheatGate=$managerSource.IndexOf('TestOptiShadeAntiCheatAccepted',[StringComparison]::Ordinal)
$antiCheatDialog=$managerSource.IndexOf('ConfirmOptiShadeAntiCheatAgreement',[StringComparison]::Ordinal)
$managerInitialization=$managerSource.IndexOf('InitializeOptiShadeManagerLifetime',[StringComparison]::Ordinal)
$patchNotesLoad=$managerSource.IndexOf('. "$PSScriptRoot/release-notes.ps1"',[StringComparison]::Ordinal)
Check ($antiCheatGate -ge 0 -and $antiCheatDialog -gt $antiCheatGate -and $managerInitialization -gt $antiCheatDialog -and $patchNotesLoad -gt $managerInitialization) 'anti-cheat agreement gates manager discovery and patch-note loading'
Check ($managerSource -match '(?s)if\(-not\(ConfirmOptiShadeAntiCheatAgreement \$null\)\)\{return\}') 'declining the startup anti-cheat agreement exits before manager initialization'
Check ($managerSource -notmatch 'OPTISHADE_PRIVATE_TESTER_AUTH|Test-OptiShadePrivateTesterAccess|StartOptiShadePrivateTesterHeartbeat') 'launcher startup has no private tester sign-in or server heartbeat'
Check ($managerSource.Contains("`$progress.Stage='Checking library protection...'") -and $managerSource.Contains('ProtectionResults=@($protection.ToArray())') -and $managerSource.Contains('ApplyStartupGameResults $copies @($result.ProtectionResults)')) 'library and anti-cheat results are collected and applied before the startup splash closes'
Check ($managerSource.Contains('$protectionBudgetMs=12000') -and $managerSource.Contains('quick check reached its time limit') -and $managerSource.Contains('1500 -Folder ([string]$game.Folder)')) 'startup protection work has an aggregate time cap and reports incomplete checks accurately'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-AntiCheat-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$oldStore=$env:OPTISHADE_STORE;$env:OPTISHADE_STORE=Join-Path $temp 'state'
$game=Join-Path $temp 'game';[void][IO.Directory]::CreateDirectory($game)
$target=[pscustomobject]@{Root=$game;Executable=(Join-Path $game 'game.exe');Name='Test <Game> & literal';Verified=$false;Store='';ProductId='';Limitations=@();ExcludedDirectories=@()}
$rules=Join-Path $installer 'anti-cheat-rules.json'
try{
 $drive=GetAntiCheatTarget ([IO.Path]::GetPathRoot($temp))
 Check $drive.ScopeBlocked 'whole-drive scope is rejected before enumeration'
 $blocked=InvokeAntiCheatScanCore $drive $rules
 Check ($blocked.State -eq 'Check incomplete' -and $blocked.Entries -eq 0) 'blocked broad scope cannot claim no known indicators'
 $r=InvokeAntiCheatScanCore $target $rules
 Check ($r.State -eq 'No known indicators') 'empty completed scope is qualified no-indicators'
 $consentResult=[pscustomobject]@{Target=$target;State='Check incomplete';RulesVersion=$r.RulesVersion;Matches=@();Limitations=@('Entry/time limit interrupted the scan.')}
 SaveAntiCheatDecision $consentResult 'Install / repair core' 'Accepted'
 Check (TestAntiCheatDecisionAccepted $consentResult) 'accepted incomplete-scan warning is reusable for the exact same game and scan evidence'
 $changedConsent=$consentResult.PSObject.Copy();$changedConsent.Limitations=@('Scan was cancelled.');Check (-not(TestAntiCheatDecisionAccepted $changedConsent)) 'changed scan evidence requires a fresh risk acknowledgement'
 $legacyWarning="No matching anti-cheat provider was identified, but the check is incomplete. This is not a confirmed detection or a guarantee that the game has no anti-cheat.`n`nInstalling or using OptiShade may result in an account suspension or permanent ban.`n`nOptiShade cannot guarantee compatibility or protection against account penalties. By continuing, you acknowledge these risks and accept responsibility for your decision to use OptiShade, to the extent permitted by applicable law.`n`nI understand the risk and choose to proceed."
 $legacyRecord=[ordered]@{Utc=[datetime]::UtcNow.ToString('o');Target=$target;Providers=@();RulesVersion=$r.RulesVersion;WarningVersion=1;WarningHash=(GetAntiCheatHash $legacyWarning);Operation='Install / repair core';Build='1.0.77';Outcome='Accepted'}
 [IO.File]::WriteAllText((Join-Path (Join-Path $env:OPTISHADE_STORE 'AntiCheatConsent') 'legacy-accepted.json'),($legacyRecord|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($true))
 Check (TestAntiCheatDecisionAccepted $consentResult) 'legacy accepted warning is reused when target, rule version, warning and provider evidence still match'
 $managerProtectionSource=Get-Content -LiteralPath (Join-Path $installer 'manager.ps1') -Raw -Encoding UTF8
 Check ($managerProtectionSource.Contains("'Quick check: none found'") -and $managerProtectionSource.Contains("'Check incomplete'") -and $managerProtectionSource -notmatch "Status -eq 'Not detected'\).*ProtectionStatus='Anti-cheat not detected'") 'library status does not present a scoped quick check as a definitive clean scan'
 $cardProtection=GetAntiCheatLibraryCardResult $target $rules 1500
 Check ($cardProtection.State -eq 'No known indicators' -and $cardProtection.Label -eq 'Quick check: none found' -and $cardProtection.Detail -match 'not a full game-folder scan' -and $cardProtection.Detail -notmatch 'Engine[\\/]|Depth limit reached') 'library clearly distinguishes a limited quick check from a full anti-cheat scan'
 $deepPath=Join-Path $game 'Engine/Binaries/ThirdParty/CEF3/Win64/128.4.13/Resources/Nested/Deep'
 [void][IO.Directory]::CreateDirectory($deepPath)
 $cardProtection=GetAntiCheatLibraryCardResult $target $rules 1500
 Check ($cardProtection.State -eq 'No known indicators' -and $cardProtection.Label -eq 'Quick check: none found' -and $cardProtection.Detail -match 'install check') 'deep vendor folders do not turn standard-location startup checks into incomplete status'
 $unresolved=GetAntiCheatTarget $game
 $cardProtection=GetAntiCheatLibraryCardResult $unresolved $rules 1500
 Check ($cardProtection.State -eq 'No known indicators' -and $cardProtection.Label -eq 'Quick check: none found') 'unresolved rendering executable does not invalidate a completed local provider check'
 $cardProtection=GetAntiCheatLibraryCardResult $target $rules 0
 Check ($cardProtection.State -eq 'Check incomplete' -and $cardProtection.Label -eq 'Check incomplete' -and $cardProtection.Detail -match 'status is unknown') 'budget exhaustion is explicitly unknown, never falsely clean'
 Remove-Item -LiteralPath (Join-Path $game 'Engine') -Recurse -Force
 foreach($name in @('steam_api.dll','Denuvo.dll','rallyrace-base.txt','readme-anticheat.txt')){[IO.File]::WriteAllText((Join-Path $game $name),'BattlEye Vanguard')}
 $r=InvokeAntiCheatScanCore $target $rules
 Check ($r.State -eq 'No known indicators') 'Steam API, DRM and report text do not identify anti-cheat'
 [void][IO.Directory]::CreateDirectory((Join-Path $game 'EasyAntiCheat'))
 [IO.File]::WriteAllText((Join-Path $game 'EasyAntiCheat/EasyAntiCheat_EOS_Setup.exe'),'fixture, not executable')
 $r=InvokeAntiCheatScanCore $target $rules
 Check ($r.State -eq 'Possible' -and @($r.Matches|Where-Object Strength -eq 'Detected').Count -eq 0) 'directory and non-PE lookalike remain possible'
 # Only metadata verification is mocked; production rule matching and classification run.
 function GetAntiCheatFileEvidence($Path,$Rule){if($Path -like '*EasyAntiCheat_EOS_Setup.exe'){'Verified provider signature and product metadata'}else{'Provider signature/product evidence unverified'}}
 [void][IO.Directory]::CreateDirectory((Join-Path $game 'BattlEye'))
 [IO.File]::WriteAllText((Join-Path $game 'BattlEye/BEService_x64.exe'),'fixture')
 $cardProtection=GetAntiCheatLibraryCardResult $target $rules 1500
 Check ($cardProtection.State -eq 'Detected' -and $cardProtection.Label -match 'Detected:') 'startup quick check reports recognized provider evidence instead of a generic incomplete state'
 $r=InvokeAntiCheatScanCore $target $rules -MaxEntries 1
 Check ($r.State -eq 'Detected' -and -not $r.Completed) 'confirmed result survives entry-limit coverage failure'
 Check (@($r.Matches|Select-Object -ExpandProperty Id -Unique).Count -eq 2) 'EAC and BattlEye are not collapsed into one provider'
 $r=InvokeAntiCheatScanCore $target (Join-Path $temp 'missing.json')
 Check ($r.State -eq 'Check incomplete') 'missing rules cannot produce no-indicators'
 $r=InvokeAntiCheatScanCore $target $rules -Cancellation @{Cancelled=$true}
 Check (-not $r.Completed) 'cancellation is incomplete'
 $catalogueTarget=[pscustomobject]@{Root=$game;Executable=(Join-Path $game 'cs2.exe');Name='Counter-Strike 2';Verified=$true;Store='Steam';ProductId='730';Limitations=@();ExcludedDirectories=@('EasyAntiCheat','BattlEye')}
 $r=InvokeAntiCheatScanCore $catalogueTarget $rules
 Check (@($r.Matches|Where-Object {$_.Id -eq 'vac' -and $_.Basis -eq 'Official'}).Count -eq 1) 'exact Steam product plus rendering executable supplies official VAC association'
 $catalogueTarget.Executable=Join-Path $game 'gta_sa.exe'
 $r=InvokeAntiCheatScanCore $catalogueTarget $rules
 Check (@($r.Matches|Where-Object Basis -eq 'Official').Count -eq 0) 'another executable cannot inherit a catalogue association'
 $catalogueTarget.ProductId='271590'
 $r=InvokeAntiCheatScanCore $catalogueTarget $rules
 Check (@($r.Matches|Where-Object Basis -eq 'Official').Count -eq 0) 'San Andreas does not inherit GTA Online policy'
 # Exact store root discovery, including a nested rendering executable.
 $apps=Join-Path $temp 'steamapps';$steamGame=Join-Path $apps 'common/Fixture';$nested=Join-Path $steamGame 'Binaries/Win64';[void][IO.Directory]::CreateDirectory($nested)
 [IO.File]::WriteAllText((Join-Path $apps 'appmanifest_730.acf'),'"AppState" { "appid" "730" "name" "Counter-Strike 2" "installdir" "Fixture" }')
 $t=GetAntiCheatTarget $nested (Join-Path $nested 'cs2.exe')
 Check ($t.Root -eq $steamGame -and $t.ProductId -eq '730') 'nested executable resolves only its matching Steam installation root'
 $before=GetAntiCheatDecisionKey $r 'install'
 $r.Utc='new timestamp';Check ((GetAntiCheatDecisionKey $r 'components') -eq $before) 'operation and timestamp do not invalidate acknowledgement for the same evidence'
 $r.Target.Executable=Join-Path $game 'different.exe';Check ((GetAntiCheatDecisionKey $r 'install') -ne $before) 'target change invalidates acknowledgement'
 # Actual mutation entrypoint must reach the common gate before any game/state writes.
 . "$installer/ownership.ps1"
 $script:AntiCheatDecision=$null;$script:AntiCheatOperation=$null
 $failed=$false
 # This fixture validates anti-cheat consent, not the live-game guard. Mock
 # only the process-name lookup so a simulator running on the test workstation
 # does not make this unrelated assertion nondeterministic.
 function Get-Process {[CmdletBinding()]param([string[]]$Name);if($Name -contains 'FlightSimulator2024' -or $Name -contains 'FlightSimulator'){return @()};Microsoft.PowerShell.Management\Get-Process @PSBoundParameters}
 try{InstallFusion $game (Join-Path $temp 'absent-payload') $env:OPTISHADE_STORE 'not-an-installer.exe' -Executable $target.Executable}catch{$failed=$_.Exception.Message -like '*UserConsentRequired*'}finally{Remove-Item Function:\Get-Process -ErrorAction SilentlyContinue}
 Check $failed 'direct install fails with UserConsentRequired before payload/ownership mutation'
 Check (-not(Test-Path (Join-Path $env:OPTISHADE_STORE 'Games'))) 'declined/unattended gate writes no ownership records'
 # The global agreement replaces scan-based mutation decisions. Declines block
 # writes and a session acceptance covers each game and nested component action.
 $script:AntiCheatSessionAccepted=$false;$env:OPTISHADE_ANTICHEAT_SESSION_ACCEPTED=$null
 $script:AntiCheatDecision={ $false }
 $failed=$false;try{AssertAntiCheatMutation $game $target.Executable}catch{$failed=$_.Exception.Message -like '*Nothing changed*'}
 Check $failed 'Declining the global warning refuses mutation'
 $script:AntiCheatSessionAccepted=$true;$env:OPTISHADE_ANTICHEAT_SESSION_ACCEPTED='1'
 $savedScan=${function:InvokeAntiCheatScan};$script:scanCalls=0
 function InvokeAntiCheatScan {param($Target,$Game,$Executable) $script:scanCalls++;return [pscustomobject]@{Cancelled=$false;State='No known indicators'}}
 try{
  $script:AntiCheatOperation=@{Name='test install';Accepted=@{}}
  AssertAntiCheatMutation $game $target.Executable
  AssertAntiCheatMutation $game $target.Executable
  $script:AntiCheatOperation=@{Name='repair';Accepted=@{}}
  AssertAntiCheatMutation $game $target.Executable
 }finally{Set-Item Function:InvokeAntiCheatScan $savedScan}
 Check ($script:scanCalls -eq 2) 'each operation rechecks while nested mutations reuse its result'
 $script:AntiCheatSessionAccepted=$false;$env:OPTISHADE_ANTICHEAT_SESSION_ACCEPTED=$null
 SaveOptiShadeAntiCheatAcceptance
 Check (TestOptiShadeAntiCheatAccepted) 'persisted acceptance is recognized by the shared gate'
 Remove-Item -LiteralPath (GetOptiShadeAntiCheatAcceptancePath) -Force
 $script:AntiCheatContextValid={$false}
 $failed=$false;try{AssertAntiCheatMutation $game $target.Executable}catch{$failed=($_.Exception.Message -like '*context changed*' -or $_.Exception.Message -like '*check cancelled*')}
 Check $failed 'changed selection rejects old context'
 # Existing installations use the receipt before any scan, including changed files.
 $script:AntiCheatContextValid=$null;$script:AntiCheatOperation=$null
 $mp=ManifestPath $env:OPTISHADE_STORE $game
 [void][IO.Directory]::CreateDirectory((Split-Path $mp))
 $receipt=@{Game=$game;Status='Installed';Files=@(@{Path='dxgi.dll';Hash=('a'*64)})}
 $receipt|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $mp
 Check (TestAntiCheatExistingInstallation $game) 'valid receipt establishes maintenance even when repair must restore missing files'
 $script:AntiCheatSessionAccepted=$true;$env:OPTISHADE_ANTICHEAT_SESSION_ACCEPTED='1'
 $savedScan=${function:InvokeAntiCheatScan};$script:scanCalls=0
 function InvokeAntiCheatScan {param($Target,$Game,$Executable) $script:scanCalls++;return [pscustomobject]@{Cancelled=$false;State='No known indicators'}}
 try{
  foreach($operation in @('Repair','Update core','Update NR','Update cockpit')){AssertAntiCheatMutation $game $target.Executable $operation}
  Check ($script:scanCalls -eq 4) 'each standalone maintenance operation rechecks selected installation'
 }finally{Set-Item Function:InvokeAntiCheatScan $savedScan}
 foreach($badStatus in @('Restored','Installing')){
  $receipt.Status=$badStatus;$receipt|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $mp
  Check (-not(TestAntiCheatExistingInstallation $game)) ('receipt '+$badStatus+' cannot suppress initial installation warning')
 }
 $receipt.Status='Installed';$receipt.Game=Join-Path $temp 'other-game';$receipt|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $mp
 Check (-not(TestAntiCheatExistingInstallation $game)) 'another installation receipt cannot suppress warning'
 Remove-Item -LiteralPath $mp
 # Exact scoped catalogue lookup, stale evidence and unknown-game semantics.
 $target.Verified=$true;$target.Store='Steam';$target.ProductId='1172470';$target.Executable=Join-Path $game 'r5apex.exe'
 $r=InvokeAntiCheatScanCore $target $rules
 Check (@($r.Matches|Where-Object { $_.Basis -eq 'Official' -and $_.Id -eq 'ea'}).Count -eq 1) 'Apex catalogue selects current Javelin provider'
 $target.ProductId='2014780';$target.Executable=Join-Path $game 'X-Plane.exe'
 $r=InvokeAntiCheatScanCore $target $rules
 Check (@($r.Matches|Where-Object Basis -eq 'Official').Count -eq 0 -and $r.State -ne 'No known indicators') 'unknown catalogue game still receives local anti-cheat detection'
 # The optional persistent preference must fail safely if its state folder is
 # not writable; session acceptance remains independently testable.
 $script:AntiCheatContextValid=$null;$script:AntiCheatOperation=$null
 $env:OPTISHADE_STORE=Join-Path $temp 'unwritable-state-file'
 [IO.File]::WriteAllText($env:OPTISHADE_STORE,'fixture')
 $failed=$false;try{SaveOptiShadeAntiCheatAcceptance}catch{$failed=$true}
 Check $failed 'cannot save persistent acceptance when its state path is a file'
 # Missing/malformed resources and budgets preserve uncertainty.
 $badRules=Join-Path $temp 'invalid-rules.json';[IO.File]::WriteAllText($badRules,'{"Schema":9}')
 $r=InvokeAntiCheatScanCore $target $badRules
 Check ($r.State -eq 'Check incomplete') 'malformed rules never imply no indicators'
 $r=InvokeAntiCheatScanCore $target $rules -MaxMilliseconds 0
 Check (-not $r.Completed) 'elapsed-time budget produces incomplete coverage'
}finally{
 $script:AntiCheatDecision=$null;$script:AntiCheatContextValid=$null;$script:AntiCheatOperation=$null;$env:OPTISHADE_STORE=$oldStore
 # Explicitly checked fixture root; never remove selected game data.
 if([IO.Path]::GetFullPath($temp).StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $temp -Leaf) -like 'OptiShade-AntiCheat-*'){Remove-Item -LiteralPath $temp -Recurse -Force}
}


