# Optional upstream RTXMFG integration. Upstream code retains its MIT licence.
function SetMfgIniValue([string]$Text,[string]$Section,[string]$Key,[string]$Value){
 $lines=[Collections.Generic.List[string]]::new();$active=$false;$found=$false;$sectionFound=$false
 foreach($line in ($Text -split '\r?\n')){
  if($line -match '^\s*\[([^]]+)\]'){
   if($active -and -not $found){$lines.Add("$Key=$Value");$found=$true}
   $active=$Matches[1] -eq $Section;if($active){$sectionFound=$true}
  }
  if($active -and $line -match ('^\s*'+[regex]::Escape($Key)+'\s*=')){if(-not $found){$lines.Add("$Key=$Value");$found=$true}}else{$lines.Add($line)}
 }
 if(-not $sectionFound){$lines.Add("[$Section]")}
 if(-not $found){$lines.Add("$Key=$Value")}
 return $lines -join "`r`n"
}
function InstallOptionalMfg([string]$ManifestPath,[string]$Payload,[string[]]$GpuNames){
 if(-not ($GpuNames -match '\bRTX\s*40\d{2}\b')){throw 'This optional MFG setup is limited to RTX 40 GPUs. Other series are not validated.'}
 $original=Get-Content -LiteralPath $ManifestPath -Raw;$m=$original|ConvertFrom-Json
 if($m.Status -ne 'Installed'){throw 'Install OptiShade first.'}
 AssertClosed $m.Game
 if($m.PSObject.Properties['OptionalMfg'] -and $m.OptionalMfg){throw 'Optional MFG is already installed. Restore OptiShade to remove it.'}
 $source=OwnedPath $Payload 'OptiShadeData/MFG/RTXMFG.dll'
 $expected='E9CA3587854EEB723E0579F7DDF6CFB1E6CF4BED79B0D75BC716003ED98FE040'
 if((HashFile $source) -ne $expected){throw 'Optional MFG payload verification failed.'}
 # Never overwrite another loader, including an OptiShade installation using version.dll.
 $dest=OwnedPath $m.Game 'version.dll'
 if(Test-Path -LiteralPath $dest){throw 'version.dll is already occupied. Optional MFG was not installed; no existing loader was replaced.'}
 foreach($name in @('RTX40MFGCore.dll','RTX40MFG.asi','RTX40MFG-UI.addon64','RTXMFG.dll','dlss-enabler-headless.dll')){
  if((Test-Path -LiteralPath (OwnedPath $m.Game $name)) -or (Test-Path -LiteralPath (OwnedPath $m.Game ('OptiShadeData/Engine/'+$name)))){throw 'Another MFG component is present. Remove it using its own instructions before enabling optional MFG.'}
 }
 $ini=OwnedPath $m.Game 'OptiScaler.ini';$before=[IO.File]::ReadAllBytes($ini)
 $text=[IO.File]::ReadAllText($ini)
 $text=SetMfgIniValue $text 'FrameGen' 'External' 'true'
 $text=SetMfgIniValue $text 'DLSSG' 'AdaMfgUnlock' 'false'
 $text=SetMfgIniValue $text 'DLSSG' 'AmpereMfgUnlock' 'false'
 $temp=$dest+'.optishade-staging'
 if(Test-Path -LiteralPath $temp){throw 'An MFG staging file already exists. No files were changed.'}
 $installed=$false
 try{
  [IO.File]::Copy($source,$temp,$false)
  if((HashFile $temp) -ne $expected){throw 'MFG copy verification failed.'}
  [IO.File]::Move($temp,$dest);$installed=$true
  [IO.File]::WriteAllText($ini,$text,[Text.UTF8Encoding]::new($false))
  $m.Files=@($m.Files)+[pscustomobject]@{Path='version.dll';SourcePath='';Hash=$expected;PreviousHash='';Backup='';Mutable=$false;Retained=$true}
  $m|Add-Member OptionalMfg $true -Force
  $m|Add-Member OptionalMfgVersion 'v1.3.3-hotfix.2' -Force
  WriteState $m $ManifestPath
 }catch{
  [IO.File]::WriteAllBytes($ini,$before)
  if($installed -and (HashFile $dest) -eq $expected){Remove-Item -LiteralPath $dest -Force}
  [IO.File]::WriteAllText($ManifestPath,$original,[Text.UTF8Encoding]::new($true))
  throw
 }finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}}
}
