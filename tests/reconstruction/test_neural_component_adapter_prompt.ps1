$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$manager=Join-Path $root 'Beta/installer/manager.ps1';$parse=$null;$tokens=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($manager,[ref]$tokens,[ref]$parse)
if($parse.Count){throw $parse[0]}
$node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'InstallSelectedNeuralComponent'},$true)
if(-not $node){throw 'InstallSelectedNeuralComponent was not found.'}
Invoke-Expression $node.Extent.Text

$script:Payload='fixture payload';$script:progress={param($text)}
$script:manifest=[pscustomobject]@{Status='Installed';Game='C:\fixture\game'}
$script:attempts=0;$script:pickerCalls=0;$script:gpuCalls=0;$script:mode='resolve';$script:observedProfile=''
function GetFusionGpu{$script:gpuCalls++;return [pscustomobject]@{Fixture=$script:gpuCalls}}
function InstallOptiShadeAddon([string]$ManifestPath,$Payload,[string]$Id,$Gpu,$Progress,[switch]$ExplicitSelection,[string]$DlssRuntimeProfile){
 $script:attempts++;$script:observedProfile=$DlssRuntimeProfile
 if($script:mode -eq 'resolve' -and $script:attempts -eq 1){throw 'Neural preparation needs a measured adapter candidate: Multiple physical NVIDIA adapters remain possible; a matching live rendering LUID is required.'}
 if($script:mode -eq 'other'){throw 'fixture download failure'}
}
function ShowNeuralAdapterPicker([string]$ManifestPath){$script:pickerCalls++;return [bool]$script:pickerAccept}
function ReadOptiShadeState([string]$ManifestPath){return $script:manifest}
function GetOptiShadeManagerStatusKey([string]$Path){return [IO.Path]::GetFullPath($Path).TrimEnd('\')}
function AssertClosed([string]$Game){$script:assertedGame=$Game}
function ResolveOptiShadeNeuralAdapter($Manifest,$Gpu){return [pscustomobject]@{State='candidate';Reason='fixture candidate'}}

$key=GetOptiShadeManagerStatusKey $script:manifest.Game
$script:pickerAccept=$true
InstallSelectedNeuralComponent 'C:\fixture\manifest.json' $key 'nvidia-310.9.16'
if($script:attempts -ne 2 -or $script:pickerCalls -ne 1 -or $script:gpuCalls -ne 2){throw 'Ambiguous direct component install did not prompt for an adapter, refresh inventory, and retry exactly once.'}
if($script:observedProfile -cne 'nvidia-310.9.16' -or $script:assertedGame -cne $script:manifest.Game){throw 'Adapter retry lost the selected runtime profile or game-close guard.'}

$script:attempts=0;$script:pickerCalls=0;$script:gpuCalls=0;$script:pickerAccept=$false
$cancelled=$false
try{InstallSelectedNeuralComponent 'C:\fixture\manifest.json' $key 'nvidia-310.9.16'}catch{$cancelled=$_.Exception.Message -like '*No component files were changed*'}
if(-not $cancelled -or $script:attempts -ne 1 -or $script:pickerCalls -ne 1){throw 'Cancelling adapter selection did not stop before a retry with a clear message.'}

$script:attempts=0;$script:pickerCalls=0;$script:gpuCalls=0;$script:pickerAccept=$true;$script:mode='other'
$otherFailure=$false
try{InstallSelectedNeuralComponent 'C:\fixture\manifest.json' $key 'nvidia-310.9.16'}catch{$otherFailure=$_.Exception.Message -eq 'fixture download failure'}
if(-not $otherFailure -or $script:attempts -ne 1 -or $script:pickerCalls -ne 0){throw 'Unrelated neural install failures must not open the GPU picker or retry.'}
$script:mode='resolve'
Write-Output 'PASS: Direct Neural component install prompts and retries once after GPU ambiguity; cancel and unrelated failures do not retry.'
