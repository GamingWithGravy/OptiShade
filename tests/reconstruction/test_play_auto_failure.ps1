$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$lifetimePath=Join-Path $repo 'Beta/installer/manager-lifetime.ps1'
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($lifetimePath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ('Manager lifetime source parse failed: '+$errors[0].Message)}
$functionAst=$ast.Find({param($node)$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'InvokeOptiShadePlayPreparation'},$true)
if(-not $functionAst){throw 'Production non-blocking Play-preparation helper was not found.'}
Invoke-Expression $functionAst.Extent.Text
$checks=0
function Assert([bool]$condition,[string]$message){if(-not $condition){throw $message};$script:checks++}

$script:log='';$script:prepared=$false
$success=InvokeOptiShadePlayPreparation {$script:prepared=$true} {param($message)$script:log=$message}
Assert ($success.Succeeded -and $script:prepared -and -not $success.Error) 'Successful Auto preparation was not preserved.'
Assert (-not $script:log) 'Successful Auto preparation unexpectedly logged a failure.'

$failure=InvokeOptiShadePlayPreparation {throw 'measured adapter is unavailable'} {param($message)$script:log=$message}
Assert (-not $failure.Succeeded -and $failure.Error -eq 'measured adapter is unavailable') 'Auto preparation failure was not surfaced to the caller.'
Assert ($script:log -match 'measured adapter is unavailable') 'Auto preparation failure was not retained in the manager log.'

$managerPath=Join-Path $repo 'Beta/installer/manager.ps1';$source=[IO.File]::ReadAllText($managerPath)
$managerTokens=$null;$managerErrors=$null
$managerAst=[System.Management.Automation.Language.Parser]::ParseFile($managerPath,[ref]$managerTokens,[ref]$managerErrors)
if($managerErrors.Count){throw ('Manager source parse failed: '+$managerErrors[0].Message)}
$play=$managerAst.Find({param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Extent.Text.StartsWith('$form.FindName(''Play'').Add_Click(')},$true)
Assert ([bool]$play) 'Production Play callback was not found.'
$playText=$play.Extent.Text
Assert ($playText -notmatch 'InvokeOptiShadeAutoPreparation|InvokeOptiShadePlayPreparation') 'Play must not install components or override in-game feature intent.'
Assert ($playText -match 'StartOptiShadeXPlane' -and $playText -match 'StartOptiShadeDirectGame' -and $playText -match 'gamelaunchhelper.exe') 'Simplified Play must retain Vulkan, direct and Xbox launch paths.'
Assert ($playText -match 'StartManagerAutoSession \$m -ObserveOnly') 'Launch may observe the runtime but must not request feature changes.'
Assert ($playText -match 'GetFusionNativeLaunchExecutable') 'Packaged game launch must retain the verified native bootstrap path.'
Write-Output "PASS: Play retains native launch paths without component installation or feature activation; legacy helper behavior remains covered ($checks assertions)."
