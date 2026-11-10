$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml

class CompatibilityFixtureButton {
 [string]$Content
 [scriptblock]$Handler
 [void] Add_Click([scriptblock]$callback){$this.Handler=$callback}
 [void] Click(){if(-not $this.Handler){throw 'Fixture button has no click handler.'};$callback=$this.Handler;& $callback $this $null}
}
class CompatibilityFixtureWindow {
 [bool]$Closed=$false
 [void] Close(){$this.Closed=$true}
}
class CompatibilityFixtureCombo {
 [object[]]$Items=@()
 [object]$SelectedItem
 [scriptblock]$SelectionHandler
 CompatibilityFixtureCombo([object[]]$items){$this.Items=$items;if($items.Count){$this.SelectedItem=$items[0]}}
 [void] Add_SelectionChanged([scriptblock]$callback){$this.SelectionHandler=$callback}
}

$checks=0
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$managerPath=Join-Path $repo 'Beta/installer/manager.ps1'
$source=[IO.File]::ReadAllText($managerPath)
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ('Manager source parse failed: '+$errors[0].Message)}
$functionAst=$ast.Find({param($node)$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ShowCompatibilityPopup'},$true)
if(-not $functionAst){throw 'Production ShowCompatibilityPopup function was not found.'}

function NewManagerPopup($Title,$Description){
 $script:lastCompatibilityPopup=[pscustomobject]@{
  Body=[pscustomobject]@{Children=[Collections.ArrayList]::new()}
  Footer=[pscustomobject]@{Children=[Collections.ArrayList]::new()}
  Window=[CompatibilityFixtureWindow]::new()
 }
 return $script:lastCompatibilityPopup
}
function ShowManagerPopup($Popup){}
function AddPopupText($Popup,[string]$Text,[int]$Font=14,[string]$Color='#C0AEDF'){
 $label=[Windows.Controls.TextBlock]::new();$label.Text=$Text;[void]$Popup.Body.Children.Add($label);return $label
}
function AddPopupButton($Popup,[string]$Text,[bool]$Primary=$false){
 $button=[CompatibilityFixtureButton]::new();$button.Content=$Text;[void]$Popup.Footer.Children.Add($button);return $button
}
function NewPopupComboBox($Popup,$Items,[string]$DisplayProperty){return [CompatibilityFixtureCombo]::new([object[]]$Items)}
function GetFusionGameTargetFolder($Game){return [string]$Game.Folder}
function SetSelectedFusionGame($Game){$script:selectedCompatibilityGame=$Game;return $true}
function ManifestPath($Store,[string]$Folder){return $script:compatibilityManifest}
function ReadOptiShadeState($Path){return [pscustomobject]@{LaunchExe=$script:compatibilityExe}}
function FindFusionExecutable($Folder,$Launcher,$Name){return @()}
function ChooseGameExe{return $null}
function CheckGameCompatibility([string]$Exe){$script:compatibilityScanCount++;return [pscustomobject]@{ExecutableEvidence='verified fixture';ScanComplete=$true}}
function FormatFusionCompatibility($Plan){return 'fixture compatibility report'}
function WriteInstallerLog([string]$Message){$script:compatibilityLog=$Message}
function OpenDiagnosticTool{$script:diagnosticOpenCount++}
Invoke-Expression $functionAst.Extent.Text

$fixture=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-compatibility-popup-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
try{
 $script:compatibilityManifest=Join-Path $fixture 'install.json';[IO.File]::WriteAllText($script:compatibilityManifest,'{}')
 $script:compatibilityExe=Join-Path $fixture 'Game.exe';[IO.File]::WriteAllText($script:compatibilityExe,'fixture')
 $game=[pscustomobject]@{DisplayName='Fixture Game';StoreDisplay='Fixture Store';Folder=$fixture;Launcher='Fixture';Name='FixtureGame'}
 $script:libraryGames=@($game);$path=[pscustomobject]@{Text=$fixture};$store=Join-Path $fixture 'store'
 $status=[pscustomobject]@{Text='';Foreground=$null};$script:compatibilityScanCount=0;$script:diagnosticOpenCount=0;$script:compatibilityLog=''
 ShowCompatibilityPopup
 $popup=$script:lastCompatibilityPopup
 $report=@($popup.Body.Children|Where-Object {$_ -is [Windows.Controls.TextBox]})|Select-Object -First 1
 Assert ($null -ne $report) 'Compatibility report textbox was not created.'
 Assert ($report.Text -match 'Choose Check selected game') 'Initial preview did not resolve the selected game folder.'
 $checkButton=@($popup.Footer.Children|Where-Object {$_.Content -eq 'Check selected game'})|Select-Object -First 1
 Assert ($null -ne $checkButton) 'Check selected game button was not created.'
 $checkButton.Click()
 Assert ($script:compatibilityScanCount -eq 1) 'Compatibility scan callback did not invoke the production scanner.'
 Assert ($report.Text -match 'fixture compatibility report' -and $report.Text -match 'Fixture Game') 'Compatibility result was not rendered into the report.'
 Assert ($status.Text -eq 'Compatibility evidence collected. Open the troubleshooting tool for a diagnostic report.') 'Compatibility callback did not update manager status.'
 $toolButton=@($popup.Footer.Children|Where-Object {$_.Content -eq 'Open troubleshooting tool'})|Select-Object -First 1
 $toolButton.Click()
 Assert ($script:diagnosticOpenCount -eq 1) 'Troubleshooter callback did not resolve its manager function.'
 Write-Output "Compatibility popup callbacks: $checks production callback assertions passed. No game launched or installation modified."
}finally{if(Test-Path -LiteralPath $fixture){[IO.Directory]::Delete($fixture,$true)}}
