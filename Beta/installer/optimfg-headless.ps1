# OptiMFG component backend. Source-built 0.8.5 fixes on the 0.8.2 menu-free route.
. "$PSScriptRoot/provider-policy.ps1"
function GetOptiMfgHeadlessHashes {
 return [ordered]@{
  'version.dll'='28A1C573E66B8419D7FFD329A1CFEC44F33CE1345FD61FBD941D6EF00F0ED2F3'
  'version.ini'='ADF5513DBBC4A2D55B580B73A98DEDC366EEABE072E7A2E3C4BC84D65D62826F'
  'RTX40MFGCore.dll'='28451CE64EAF4EBB5F8406F6B43E14F779FCF9258D47D051EF63896A5419AB85'
  'RTX40MFG.asi'='5F2876D6F45D47A44EE5714BB3F9C5669320928ED09972E9E4502ED49C2493D3'
 }
}
function GetOptiMfgBackendPaths {return @('version.dll','version.ini','RTX40MFGCore.dll','RTX40MFG.asi','OptiMFGTest-backend.json','RTX40MFG-Universal.json')}
function ResolveOptiMfgComponentAdapter($Gpu,$Manifest){
 if($Manifest -and $Manifest.PSObject.Properties['OptiMfgAdapter'] -and $Manifest.OptiMfgAdapter){
  $saved=$Manifest.OptiMfgAdapter
  $candidate=ResolveOptiShadeAdapterCandidate $Gpu '' ([string]$saved.Luid)
  if($candidate.State -eq 'candidate'){
   $same=$true
   foreach($field in @('VendorId','DeviceId','SubSystemId','Family')){if([string]$candidate.Adapter.$field -cne [string]$saved.$field){$same=$false}}
   if($same){return $candidate}
  }
  return [pscustomobject]@{State='selection_required';Adapter=$null;Reason='The saved OptiMFG adapter is no longer an exact match. Choose it again.'}
 }
 return ResolveOptiShadeMfgAdapter $Gpu $Manifest
}
function SetOptiMfgAdapterSelection($Manifest,$Gpu,[string]$Luid){
 if(-not $Luid){throw 'Select an identified physical adapter.'}
 $candidate=ResolveOptiShadeAdapterCandidate $Gpu '' $Luid
 if($candidate.State -ne 'candidate'){throw ('The selected OptiMFG GPU is unavailable: '+$candidate.Reason)}
 $Manifest|Add-Member OptiMfgAdapter (GetOptiShadeAdapterReceipt $candidate.Adapter) -Force
}
function GetOptiMfgComponentFamily($Gpu,$Manifest){
 $candidate=ResolveOptiMfgComponentAdapter $Gpu $Manifest
 if($candidate.State -ne 'candidate' -or [int]$candidate.Adapter.Family -notin @(20,30,40,50)){throw ('OPTIMFG_GPU_SELECTION_REQUIRED: Select the game RTX adapter for OptiMFG preparation. '+$candidate.Reason)}
 return [int]$candidate.Adapter.Family
}
function TestOptiMfgComponentNeedsRepair($Manifest){
 if(Test-Path -LiteralPath (OwnedPath $Manifest.Game 'OptiShadeData/OptiMFG/start-with-game.disabled')){return $true}
 if(-not $Manifest.PSObject.Properties['OptiMfgBackendRevision'] -or [int]$Manifest.OptiMfgBackendRevision -ne 2){return $true}
 if(-not $Manifest.PSObject.Properties['OptiMfgAdapter'] -or -not $Manifest.OptiMfgAdapter){return $true}
 $family=[int]$Manifest.OptiMfgAdapter.Family
 if($family -eq 50){return (Test-Path -LiteralPath (OwnedPath $Manifest.Game 'OptiMFGTest-backend.json'))}
 if($family -notin @(20,30,40)){return $true}
 return -not (Test-OptiMfgBackendMarker $Manifest.Game)
}
function InstallOptiMfgHeadless([string]$ManifestPath,[string]$Payload,[int]$Family,[string]$ApprovedForeignVersionDllHash=''){
 $m=ReadOptiShadeState $ManifestPath;AssertClosed $m.Game
 $hashes=GetOptiMfgHeadlessHashes
 $oldProviderHash='E6B6E6B70A6ED3AF839C9647A32FC22660AE6B2D655062C5C072246C91FC10C7'
 if($Family -eq 50){
  $proxy=OwnedPath $m.Game 'version.dll';$proxyHash=HashFile $proxy
  if(-not $proxyHash -and -not(Test-Path -LiteralPath (OwnedPath $m.Game 'OptiMFGTest-backend.json'))){return}
  $owned=@($m.Files|Where-Object {$_.Path.Replace('\','/') -ieq 'version.dll'})
  # RTX 50 uses the native game provider. A foreign version.dll is unrelated
  # to that route and must not block OptiMFG selection or be removed.
  if($proxyHash -and -not(Test-OptiMfgBackendMarker $m.Game) -and
     ($owned.Count -ne 1 -or $owned[0].Hash -cne $proxyHash -or $proxyHash -notin @($oldProviderHash,$hashes['version.dll']))){return}
  if($owned.Count -ne 1 -or $owned[0].Hash -cne $proxyHash -or $proxyHash -notin @($oldProviderHash,$hashes['version.dll'])){throw 'RTX 50 migration found an unowned or changed version.dll. Its files were preserved; remove that provider through its owning installer.'}
  if($proxyHash -eq $hashes['version.dll'] -and -not(Test-OptiMfgBackendMarker $m.Game)){throw 'RTX 50 migration cannot verify the ASI backend; files were preserved.'}
  $names=@('version.dll','OptiMFGTest-backend.json')
  if($proxyHash -eq $hashes['version.dll']){$names+=@('version.ini','RTX40MFGCore.dll','RTX40MFG.asi')}
  $plan=@();$receiptFolder=Split-Path $ManifestPath
  foreach($name in $names){
   $dest=OwnedPath $m.Game $name;$current=HashFile $dest
   if(-not $current){continue}
   $entries=@($m.Files|Where-Object {$_.Path.Replace('\','/') -ieq $name})
   if($entries.Count -ne 1 -or $entries[0].Hash -cne $current){throw ('RTX 50 migration found a changed or unowned backend file: '+$name)}
   $entry=$entries[0];$backup=''
   if($entry.Backup){
    $backup=OwnedPath $receiptFolder $entry.Backup
    if(-not $entry.PreviousHash -or (HashFile $backup) -cne $entry.PreviousHash){throw ('RTX 50 migration cannot verify the original backup: '+$name)}
    if($name -ne 'version.dll' -or $entry.PreviousHash -in @($oldProviderHash,$hashes['version.dll'])){throw 'RTX 50 migration would restore another backend. Recovery files retained for review.'}
   }
   $plan+=,[pscustomobject]@{Name=$name;Dest=$dest;Before=$current;Backup=$backup;Original=$entry.PreviousHash}
  }
  foreach($item in $plan){
   if((HashFile $item.Dest) -cne $item.Before){throw 'Backend changed during RTX 50 migration.'}
   if($item.Backup){Copy-Item -LiteralPath $item.Backup -Destination $item.Dest -Force;if((HashFile $item.Dest) -cne $item.Original){throw 'RTX 50 original loader restore failed verification.'}}
   else{Remove-Item -LiteralPath $item.Dest -Force}
  }
  $m.Files=@($m.Files|Where-Object {$_.Path.Replace('\','/') -notin $plan.Name})
  WriteState $m $ManifestPath
  return
 }
 if($Family -notin @(20,30,40)){throw 'Unsupported rendering adapter for the menu-free backend.'}
 $base='OptiShadeData/OptiMFG/Runtime/backends/headless/'
 # Validate every source and destination before writing anything.
 foreach($name in $hashes.Keys){
  if((HashFile (OwnedPath $Payload ($base+$name))) -cne $hashes[$name]){throw ('OptiMFG backend payload verification failed: '+$name)}
 }
 $plan=@()
 foreach($name in (GetOptiMfgBackendPaths)){
  $target=OwnedPath $m.Game $name;$before=HashFile $target
  $records=@($m.Files|Where-Object {$_.Path.Replace('\','/') -ieq $name})
  if($records.Count -gt 1){throw ('Ambiguous OptiMFG ownership: '+$name)}
  if($before){
   if($name -eq 'RTX40MFG-Universal.json'){
    $config=ReadOptiShadeJson $target 'OptiMFG settings' -Shape Object -MaxBytes 4096
    if($config.version -ne 13){throw 'Unsupported existing OptiMFG settings version.'}
    continue
   }
   # Reuse exact pinned files from the external tester app without claiming
   # ownership. Removal leaves them in place; unknown bytes still stop install.
   if($hashes.Contains($name) -and $records.Count -eq 0 -and $before -ceq $hashes[$name]){continue}
   if($name -eq 'version.dll' -and $records.Count -eq 0 -and $before -cne $oldProviderHash -and $before -cne $hashes[$name]){
    if($ApprovedForeignVersionDllHash -cne $before){throw ('OPTIMFG_FOREIGN_VERSION_DLL_CONSENT_REQUIRED:'+$before)}
    # InvokeAddonTransaction has already made and verified a rollback copy of
    # this exact path. The consent token is the observed digest, so a changed
    # file between the prompt and this transaction is never replaced.
   }elseif($records.Count -ne 1 -or [string]$records[0].Hash -cne $before){throw ('Changed or foreign backend file; nothing installed: '+$name)}
   if($name -eq 'version.dll' -and $before -cne $oldProviderHash -and $before -cne $hashes[$name] -and $records.Count -gt 0){throw 'An OptiShade-owned version.dll conflicts with the OptiMFG backend. Its ownership and bytes were preserved; repair the owning component first.'}
  }
  $source=if($hashes.Contains($name)){OwnedPath $Payload ($base+$name)}else{''}
  $plan+=,[pscustomobject]@{Name=$name;Target=$target;Before=$before;Source=$source;Record=$(if($records.Count){$records[0]}else{$null})}
 }
 foreach($item in $plan){
  if((HashFile $item.Target) -cne $item.Before){throw ('Backend changed during installation: '+$item.Name)}
  if($item.Source){Copy-Item -LiteralPath $item.Source -Destination $item.Target -Force}
  elseif($item.Name -eq 'RTX40MFG-Universal.json'){
   [IO.File]::WriteAllText($item.Target,'{"version":13,"followGame":true,"mode":"follow","multiplier":2,"dynamicTargetFrameRate":0,"dynamicExperimental56":false,"generatedOnlyDebug":false,"intervalLogging":true}',[Text.UTF8Encoding]::new($false))
  }else{
   $files=@(foreach($name in $hashes.Keys){[pscustomobject]@{name=$name;sha256=$hashes[$name]}})
   $marker=@{provider='RTX30MFG source fork';providerVersion='1.2.2-optimfg.1';proxy='version.dll';externalUiOnly=$true;files=$files}
   [IO.File]::WriteAllText($item.Target,($marker|ConvertTo-Json -Depth 5 -Compress),[Text.UTF8Encoding]::new($false))
  }
  $hash=HashFile $item.Target
  if($item.Source -and $hash -cne $hashes[$item.Name]){throw ('Backend copy verification failed: '+$item.Name)}
  if($item.Record){$item.Record.Hash=$hash;$item.Record|Add-Member Component 'OptiMfg' -Force;$item.Record.Retained=$false}
  else{$m.Files+=,[pscustomobject]@{Path=$item.Name;SourcePath='';Hash=$hash;PreviousHash='';Backup='';Mutable=(TestOptiShadeMutableFile $item.Name);Retained=$false;Component='OptiMfg'}}
 }
 WriteState $m $ManifestPath
}
