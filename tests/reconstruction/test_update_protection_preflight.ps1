$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$managerPath=Join-Path $root 'Beta/installer/manager.ps1'
$guardPath=Join-Path $root 'Beta/installer/anti-cheat.ps1'
$manager=[IO.File]::ReadAllText($managerPath)
$guard=[IO.File]::ReadAllText($guardPath)
$errors=$null
[Management.Automation.Language.Parser]::ParseFile($managerPath,[ref]$null,[ref]$errors)|Out-Null
if($errors){throw ('manager.ps1 syntax errors: '+($errors|ForEach-Object Message -join '; '))}
[Management.Automation.Language.Parser]::ParseFile($guardPath,[ref]$null,[ref]$errors)|Out-Null
if($errors){throw ('anti-cheat.ps1 syntax errors: '+($errors|ForEach-Object Message -join '; '))}
if($manager -match 'ConfirmUpdateBatchProtection|Review update risks'){throw 'Update flow still contains the removed anti-cheat dialog.'}
if($manager -notmatch '\$script:AntiCheatUpdateMode=\$true'){throw 'Update mode is not scoped around the update run.'}
if($guard -notmatch '(?s)EnsureOptiShadeAntiCheatAgreement \$null.*?if\(\$script:AntiCheatUpdateMode\)\{return\}\s+\$scope='){throw 'Update bypass does not occur after startup consent and before game-specific prompt.'}
if($guard -notmatch '\$result=InvokeAntiCheatScan -Game \$Game -Executable \$Executable' -or $guard -notmatch 'ConfirmFusionInstall'){throw 'Game-install detector/prompt path was removed.'}
if($manager.Substring(0,[Math]::Min($manager.Length,1000)) -notmatch 'ConfirmOptiShadeAntiCheatAgreement'){throw 'Startup agreement is missing.'}
if($manager -notmatch 'try\{RunAction \{' -or $manager -notmatch '\} ''Updating game installations''\}finally\{\$script:AntiCheatUpdateMode=\$priorAntiCheatUpdateMode\}'){throw 'Update-only anti-cheat prompt suppression is not restored after the batch.'}
'PASS: updates no longer show anti-cheat dialogs; startup agreement and per-game install detection remain; update-only suppression is scoped.'

