$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Beta/installer/ownership.ps1"
. "$root/Beta/installer/library.ps1"
$errors=$null;$tokens=$null
$ast=[Management.Automation.Language.Parser]::ParseFile("$root/Beta/installer/manager.ps1",[ref]$tokens,[ref]$errors)
if($errors.Count){throw $errors[0].Message}
$fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'ConfirmManagerCoreInstallation'},$true)
Invoke-Expression $fn.Extent.Text
$checks=0
function Check($ok,$message){if(-not $ok){throw $message};$script:checks++}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('optishade-simple-install-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try{
 $game=Join-Path $temp 'game/Binaries/Win64';[void][IO.Directory]::CreateDirectory($game)
 $loader=Join-Path $game 'dxgi.dll';[IO.File]::WriteAllText($loader,'fixture loader; never executed')
 $record=[pscustomobject]@{Status='Installed';Game=$game;Version=(GetBundledOptiShadeVersion);Files=@([pscustomobject]@{Path='dxgi.dll';SourcePath='winmm.dll';Hash=(HashFile $loader)});Components=@()}
 $mp=Join-Path $temp 'manifest.json';WriteState $record $mp
 $path=[pscustomobject]@{Text=$game}
 $entry=[pscustomobject]@{Folder=(Join-Path $temp 'game');InstallFolder=(Join-Path $temp 'game')}
 $selector=[pscustomobject]@{ItemsSource=@($entry)}
 $form=[pscustomobject]@{Selector=$selector};$form|Add-Member ScriptMethod FindName {param($name) return $this.Selector}
 $script:libraryGames=@();$script:scans=0
 function RequestManagerStatusScan{param([switch]$Force);if($Force){$script:scans++}}
 ConfirmManagerCoreInstallation $mp
 Check ($entry.InstallFolder -eq $game -and $script:scans -eq 1) 'verified nested installation must rebind the library and request a fresh status snapshot'
 [IO.File]::WriteAllText($loader,'damaged fixture')
 $blocked=$false;try{ConfirmManagerCoreInstallation $mp}catch{$blocked=$true}
 Check ($blocked -and $script:scans -eq 1) 'damaged loader must not pass installation confirmation'
 $path.Text=Join-Path $temp 'wrong-game';$blocked=$false;try{ConfirmManagerCoreInstallation $mp}catch{$blocked=$true}
 Check $blocked 'a receipt for another target must not pass installation confirmation'
 $path.Text=$game
 $build=Join-Path $game 'OptiShadeData/BuildIdentity.json';[void][IO.Directory]::CreateDirectory((Split-Path $build))
 $identity=@{Version='1.0.77';Channel='stable';PrivateTesting=$true;PrivateTestNumber=145}
 WriteState $identity $build
 $record.Files=@([pscustomobject]@{Path='OptiShadeData/BuildIdentity.json';Hash=(HashFile $build)})
 $bundle=Join-Path $temp 'bundled-build.json';$identity.PrivateTestNumber=146;WriteState $identity $bundle
 Check (TestOptiShadePrivateBuildUpdate $record $bundle) 'a newer private candidate is an update even when its public version is unchanged'
 $identity.PrivateTestNumber=145;WriteState $identity $bundle
 Check (-not(TestOptiShadePrivateBuildUpdate $record $bundle)) 'the same private candidate is not an endless update'
 $identity.PrivateTestNumber=144;WriteState $identity $bundle
 Check (-not(TestOptiShadePrivateBuildUpdate $record $bundle)) 'an older private candidate cannot be offered as an update'
 $identity.PrivateTestNumber=146;$identity.Channel='beta';WriteState $identity $bundle
 Check (-not(TestOptiShadePrivateBuildUpdate $record $bundle)) 'same-version candidate checks cannot silently switch channels'
 $identity.Channel='stable';WriteState $identity $bundle
 [IO.File]::AppendAllText($build,' ');$blocked=$false;try{$null=TestOptiShadePrivateBuildUpdate $record $bundle}catch{$blocked=$true}
 Check $blocked 'unowned or modified build identity cannot authorize an update'
 $install=$ast.Find({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text.StartsWith('$form.FindName(''Install'').Add_Click(')},$true)
 Check ($install -and $install.Extent.Text -notmatch 'InvokeOptiShadeAutoPreparation|StartManagerAutoSession') 'core install must not install or activate optional components'
 Check ($install.Extent.Text.IndexOf('ConfirmManagerCoreInstallation') -lt $install.Extent.Text.IndexOf("ShowPage 'Components'")) 'component navigation follows core verification'
 [xml]$xaml=Get-Content "$root/Beta/installer/manager.xaml" -Raw
 Check (-not $xaml.SelectSingleNode('//*[@*[local-name()="Name"]="AutoSession" or @*[local-name()="Name"]="AutoOff" or @*[local-name()="Name"]="AutoSetup"]')) 'ordinary setup must not expose competing Auto installation/session controls'
 Write-Output "PASS: $checks simple-install confirmation, library binding, private-update and UI-flow checks. No game was modified or executed."
}finally{
 $safe=[IO.Path]::GetFullPath($temp);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if($safe.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $safe -Leaf).StartsWith('optishade-simple-install-')){Remove-Item -LiteralPath $safe -Recurse -Force}
}
