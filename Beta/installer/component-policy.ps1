# Component boundaries describe optional payloads; unclassified files are required core dependencies.
# File lifecycle is derived from purpose, never a stale receipt's Mutable bit.
# Unrecognised files (especially executable/model content) remain hash protected.
function GetOptiShadeFilePolicy([string]$Path){
 $p=([string]$Path).Replace('\','/')
 if($p -in @('OptiShadeData/NVIDIA-versions.json','OptiShadeData/Neural-dependency-status.txt','OptiShadeData/Effects-install.json')){return 'GeneratedMetadata'}
 if($p -eq 'RTX40MFG-Universal.json'){return 'UserSettings'}
 if($p -match '\.(ini|cfg)$'){return 'UserSettings'}
 if($p -match '\.log$'){return 'RuntimeLog'}
 # The OptiMFG controller rewrites its status heartbeat, session logs and
 # diagnostic exports beside its runtime. Backend binaries stay hash protected.
 if($p -match '^OptiShadeData/OptiMFG/Runtime/(?:exports/.+|[^/]+\.(?:status\.json|jsonl|csv))$'){return 'RuntimeLog'}
 return 'Immutable'
}
function TestOptiShadeMutableGeneratedMetadata([string]$Path){return (GetOptiShadeFilePolicy $Path) -eq 'GeneratedMetadata'}
function TestOptiShadeUserSettings([string]$Path){return (GetOptiShadeFilePolicy $Path) -eq 'UserSettings'}
function TestOptiShadeMutableFile([string]$Path){return (GetOptiShadeFilePolicy $Path) -ne 'Immutable'}
function TestOptiShadeKnownRetainedOriginal($Entry,[string]$CurrentHash){
 if(-not $Entry -or -not [bool]$Entry.Retained -or [string]::IsNullOrWhiteSpace([string]$Entry.PreviousHash) -or [string]::IsNullOrWhiteSpace($CurrentHash)){return $false}
 return [string]::Equals([string]$Entry.PreviousHash,$CurrentHash,[StringComparison]::OrdinalIgnoreCase)
}
function TestOptiShadeLegacyPayloadPath([string]$Path){
 $p=([string]$Path).Replace('\','/').TrimStart('/')
 return $p -eq 'OptiShadeLegacyNR.addon32' -or $p -match '^host64/' -or $p -match '^(OptiShadeData/)?Shaders/LegacyNR/'
}
function GetOptiShadeAddonId([string]$Path){
 $p=$Path.Replace('\','/')
 if($p -eq 'OptiShadeLegacyNR.addon32' -or $p -match '^host64/' -or $p -match '^OptiShadeData/Shaders/LegacyNR/'){return 'Neural'}
 if($p -match '^OptiShadeData/Engine/(amd_fidelityfx_[^/]+\.dll|libx(?:ess|ell)[^/]*\.dll)$'){return 'Providers'}
 if($p -eq 'glass-cockpit-dlss-fix.addon64'){return 'Cockpit'}
 if($p -match '^OptiShadeData/OptiMFG/'){return 'OptiMfg'}
 if($p -eq 'OptiMFGTest-backend.json'){return 'OptiMfg'} # legacy receipt cleanup only
 if($p -match '^OptiShadeData/MFG/' -or $p -match '^OptiShadeData/Licenses/DLSSG-SM86/' -or $p -match '^OptiShadeData/Engine/dlssg_sm86/' -or $p -match '^dlssg_sm86/' -or $p -eq 'dlssg_sm86.ini'){return 'Mfg'}
 if($p -eq 'nvngx_dlssnr.dll' -or $p -match '^OptiScaler/nvfp4/' -or $p -match '^OptiShadeData/Engine/(nvngx_dlss[^/]*\.dll|streamline/)' -or $p -in @('OptiShadeData/NVIDIA-versions.json','OptiShadeData/Neural-runtime.json')){return 'Neural'}
 if($p -match '^OptiShadeData/(Shaders|Textures|Presets)/'){
  # NR guides are embedded in the owned ReShade runtime. Old loose effect files
  # remain ordinary user/effect assets when encountered in an existing receipt.
  if($p -in @('OptiShadeData/Presets/My look.ini','OptiShadeData/Presets/X-Plane neural guides.ini')){return 'Core'}
  return 'Effects'
 }
 return 'Core'
}
# Explicit component removal is durable user intent. The Auto planner consumes
# these same receipt preferences; it does not maintain a second component owner.
function GetOptiShadeAutoComponentExclusions($Manifest){
 if(-not $Manifest -or -not $Manifest.PSObject.Properties['AutoComponentExclusions']){return @()}
 $ids=@($Manifest.AutoComponentExclusions)
 if($ids.Count -gt 3 -or @($ids|Select-Object -Unique).Count -ne $ids.Count -or @($ids|Where-Object {$_ -isnot [string] -or $_ -cnotin @('Effects','Neural','Providers')}).Count){throw 'The saved Auto component exclusions are invalid. Review this installation before changing components.'}
 return @($ids|Sort-Object)
}
function SetOptiShadeAutoComponentExclusion($Manifest,[string]$Id,[bool]$Excluded){
 # MFG already has its durable native/portable/provider route selection;
 # Cockpit is never automatically installed. Neither needs a parallel flag.
 if($Id -cnotin @('Effects','Neural','Providers')){return}
 $before=@(GetOptiShadeAutoComponentExclusions $Manifest)
 $ids=@($before|Where-Object {$_ -cne $Id})
 if($Excluded){$ids+=,$Id}
 if($Excluded -or $Manifest.PSObject.Properties['AutoComponentExclusions']){$Manifest|Add-Member AutoComponentExclusions @($ids|Sort-Object) -Force}
 if(($before -join ',') -cne (@($ids|Sort-Object) -join ',') -and $Manifest.AutoCompatibility){
  $Manifest.AutoCompatibility|Add-Member Fingerprint '' -Force
  $Manifest.AutoCompatibility|Add-Member State 'preferences_changed' -Force
  $Manifest|Add-Member Downloads 'Pending' -Force
 }
}
function GetOptiShadeAddonSelection($Manifest){
 if(-not $Manifest){return @()}
 if($Manifest.PSObject.Properties['Architecture'] -and $Manifest.Architecture -eq 'x86'){
  if($Manifest.PSObject.Properties['Components']){return @($Manifest.Components|Where-Object {$_ -in @('Effects','Neural','Mfg','OptiMfg')}|Select-Object -Unique)}
  if($Manifest.IncludeEffects){return @('Effects')};return @()
 }
 if($Manifest.PSObject.Properties['Components']){return @($Manifest.Components|Where-Object {$_ -in @('Effects','Neural','Mfg','OptiMfg','Cockpit','Providers')}|Select-Object -Unique)}
 $ids=@($Manifest.Files|Where-Object Hash|ForEach-Object {GetOptiShadeAddonId $_.Path}|Where-Object {$_ -ne 'Core'})
 if($Manifest.IncludeEffects){$ids+='Effects'};if($Manifest.OptionalDlss){$ids+='Neural'}
 if($Manifest.SourceMfg -or $Manifest.OptionalMfg -or $Manifest.Sm86Mfg){$ids+='Mfg'}
 return @($ids|Select-Object -Unique)
}

# Only the current menu-free backend belongs in new component installs.
# RTX 50 uses native control and needs no staged older-RTX provider binaries.
function TestOptiShadeCurrentMfgPayload([string]$Path,$Manifest,[int]$Family=0){
 $p=$Path.Replace('\','/')
 if($p -in @('version.dll','RTXMFG-Universal.json','RTX40MFG-UI.ini')){return $false}
 if($p -match '^OptiShadeData/OptiMFG/Runtime/backends/'){
  if(-not $Family -and $Manifest -and $Manifest.PSObject.Properties['OptiMfgAdapter']){$Family=[int]$Manifest.OptiMfgAdapter.Family}
  if($Family -eq 50){return $false}
  return $p -cmatch '^OptiShadeData/OptiMFG/Runtime/backends/headless/(files\.json|version\.dll|version\.ini|RTX40MFGCore\.dll|RTX40MFG\.asi)$'
 }
 return $true
}
