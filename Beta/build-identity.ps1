function InitializeOptiShadeWindowsPowerShellModules{
 if(-not $env:WINDIR){return}
 $modulePaths=@()
 if($env:USERPROFILE){$modulePaths+=Join-Path $env:USERPROFILE 'Documents/WindowsPowerShell/Modules'}
 if($env:ProgramFiles){$modulePaths+=Join-Path $env:ProgramFiles 'WindowsPowerShell/Modules'}
 $modulePaths+=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/Modules'
 $env:PSModulePath=$modulePaths -join [IO.Path]::PathSeparator
}
function GetOptiShadeSourcePaths([string]$Root){
 # Include tracked source and newly authored source, but never ignored build
 # products/private evidence. Matching local pinned link libraries are inputs.
 if((Test-Path -LiteralPath (Join-Path $Root '.git')) -or (Test-Path -LiteralPath (Join-Path (Split-Path $Root -Parent) '.git'))) {
  $local:optishadeChannelSourceFiles=@(git -c core.quotepath=false -C $Root ls-files --cached --others --exclude-standard -- . | Where-Object {$_ -ne 'reshade/res/version.h' -and $_ -notlike 'routes/bin/*' -and $_ -notlike 'legacy-nr/build/*' -and (Test-Path -LiteralPath (Join-Path $Root $_) -PathType Leaf)})
  if($LASTEXITCODE){throw 'Cannot enumerate candidate source'}
 } else {
  # Supplied source archive: its original inventory defines build inputs, not
  # disposable outputs, caches, private test evidence or package staging.
  $local:optishadeSourceManifestParent=Split-Path $Root -Parent
  $local:optishadeSourceManifestPath=Join-Path $local:optishadeSourceManifestParent 'R10-SOURCE-MANIFEST.json'
  $local:optishadeSourceManifestPrefix=(Split-Path $Root -Leaf)+'/'
  if(-not(Test-Path -LiteralPath $local:optishadeSourceManifestPath)){
   $bundle=Split-Path $local:optishadeSourceManifestParent -Parent
   $local:optishadeSourceManifestPath=Join-Path $bundle 'Notes/FILE-MANIFEST-SHA256.json'
   $local:optishadeSourceManifestPrefix='Source/'+(Split-Path $Root -Leaf)+'/'
  }
  if(-not(Test-Path -LiteralPath $local:optishadeSourceManifestPath)){throw 'Archive source inventory is missing; retain the source manifest supplied with the archive'}
  $local:optishadeSourceManifestPathEntries=ConvertFrom-Json -InputObject (Get-Content -LiteralPath $local:optishadeSourceManifestPath -Raw)
  $local:optishadeChannelSourceFiles=[Collections.Generic.List[string]]::new()
  foreach($local:optishadeSourceManifestEntry in $local:optishadeSourceManifestPathEntries){
   $local:optishadeSourceManifestEntryPath=[string]$local:optishadeSourceManifestEntry.Path
   if($local:optishadeSourceManifestEntryPath.StartsWith($local:optishadeSourceManifestPrefix,[StringComparison]::Ordinal)){
    $local:optishadeSourceManifestRelativePath=$local:optishadeSourceManifestEntryPath.Substring($local:optishadeSourceManifestPrefix.Length)
    if($local:optishadeSourceManifestRelativePath -ne 'reshade/res/version.h' -and $local:optishadeSourceManifestRelativePath -notlike 'routes/bin/*' -and $local:optishadeSourceManifestRelativePath -notlike 'legacy-nr/build/*'){[void]$local:optishadeChannelSourceFiles.Add($local:optishadeSourceManifestRelativePath)}
   }
  }
  if(-not $local:optishadeChannelSourceFiles.Count){throw 'Archive source inventory contains no files for this channel'}
 }
 # Generated troubleshooter binaries are stamped in NativeBinaries, not hashed as source.
 $local:optishadeChannelSourceFiles=@($local:optishadeChannelSourceFiles|Where-Object {$_ -ne 'installer/OptiShadeDriver.exe' -and $_ -ne 'installer/DriverSettings.obj' -and $_ -ne 'installer/OptiShade-Troubleshooter.exe' -and $_ -notlike 'installer/Troubleshooter/dist/*' -and $_ -notmatch '(^|/)(__pycache__|\.pytest_cache)/' -and $_ -notlike '*.pyc'})
 $local:optishadeChannelSourceFiles+=@('installer/GlassCockpit/glass-cockpit-dlss-fix.addon64','installer/GlassCockpit/PROVENANCE.json')
 $local:optishadeChannelSourceFiles+=@('optiscaler/external/freetype/freetype.lib')
 $local:optishadeChannelSourceFiles+=@('optiscaler/external/FidelityFX-SDK-v2/Kits/FidelityFX/signedbin/amd_fidelityfx_loader_dx12.dll','optiscaler/external/FidelityFX-SDK-v2/Kits/FidelityFX/signedbin/amd_fidelityfx_upscaler_dx12.dll','optiscaler/external/FidelityFX-SDK-v2/Kits/FidelityFX/signedbin/amd_fidelityfx_framegeneration_dx12.dll','optiscaler/external/FidelityFX-SDK/PrebuiltSignedDLL/amd_fidelityfx_vk.dll','optiscaler/external/directx_agility_sdk/lib/D3D12Core.dll')
 $packageInputs=Get-Content -LiteralPath (Join-Path $Root 'package-inputs.json') -Raw|ConvertFrom-Json
 foreach($group in $packageInputs.Groups.PSObject.Properties){$local:optishadeChannelSourceFiles+=@($group.Value|ForEach-Object Source)}
 $linkLibraries=Join-Path $Root 'optiscaler/OptiScaler/library'
 if(-not(Test-Path -LiteralPath $linkLibraries -PathType Container)){throw 'Required pinned native link-library directory is missing: optiscaler/OptiScaler/library'}
 $local:optishadeChannelSourceFiles+=@(Get-ChildItem -LiteralPath $linkLibraries -File -Recurse|ForEach-Object {$_.FullName.Substring($Root.Length+1).Replace('\','/')})
 # ReShade increments res/version.h during compilation; its final hash is stamped as build output.
 # Ordinal ordering is identical in Windows PowerShell 5.1 and PowerShell 7.
 $local:optishadeUniqueSourceSet=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
 foreach($local:optishadeSourceRelativePath in $local:optishadeChannelSourceFiles){[void]$local:optishadeUniqueSourceSet.Add($local:optishadeSourceRelativePath)}
 $local:optishadeOrderedSourceFiles=[string[]]@($local:optishadeUniqueSourceSet)
 [Array]::Sort($local:optishadeOrderedSourceFiles,[StringComparer]::Ordinal)
 return $local:optishadeOrderedSourceFiles
}
function GetOptiShadeSourceIdentity([string]$Root){
 $local:optishadeIdentityLines=[Collections.Generic.List[string]]::new()
 $local:optishadeIdentityPaths=GetOptiShadeSourcePaths $Root
 foreach($local:optishadeIdentityPath in $local:optishadeIdentityPaths){
  $file=Join-Path $Root $local:optishadeIdentityPath
  if([IO.Path]::IsPathRooted($local:optishadeIdentityPath) -or $local:optishadeIdentityPath -match '(^|[\\/])\.\.([\\/]|$)'){throw ('Source inventory path is outside the channel: '+$local:optishadeIdentityPath+' (root: '+$Root+')')}
  if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw ('Required build input is missing: '+$local:optishadeIdentityPath)}
  $local:optishadeIdentityLines.Add($local:optishadeIdentityPath+' '+(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash)
 }
 $hash=[Security.Cryptography.SHA256]::Create()
 try{return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes(($local:optishadeIdentityLines -join "`n"))))).Replace('-','')}
 finally{$hash.Dispose()}
}
function AssertOptiShadeCandidateBuild([string]$Root,[switch]$ManagerOnlyRepack){
 $stampPath=Join-Path $Root 'test-run/native-build.json'
 if(-not(Test-Path -LiteralPath $stampPath)){throw 'Run build-candidate.ps1 first. Packaging requires matching fresh native build evidence.'}
 $stamp=Get-Content -LiteralPath $stampPath -Raw|ConvertFrom-Json
 foreach($property in @('BuildMode','NativeBuildSourceSHA256','ReusedFromExecutableSHA256','ManagerOnlyChanges','ManagerRepackedUtc')){if(-not($stamp.PSObject.Properties.Name -contains $property)){$stamp|Add-Member -NotePropertyName $property -NotePropertyValue $null}}
 $currentSource=GetOptiShadeSourceIdentity $Root
 $currentInputs=GetOptiShadeBuildInputIdentity $Root
 $sourceChanged=$stamp.SourceSHA256 -ne $currentSource
 $inputsChanged=(-not $stamp.BuildInputsSHA256 -or $stamp.BuildInputsSHA256 -ne $currentInputs)
 $managerChanges=@()
 if($sourceChanged -or $inputsChanged){
  if(-not $ManagerOnlyRepack -or ($stamp.BuildMode -and $stamp.BuildMode -ne 'ManagerOnlyRepackVerifiedRuntime')){throw 'Source or required build inputs changed. Rebuild before packaging, or request a verified manager-only repack when only approved launcher resources changed.'}
  # Use the build/repack receipt timestamp as the source-change cutoff. The
  # receipt itself may be updated to record a rebuilt manager host; using its
  # filesystem timestamp would hide the manager-only source edits from the
  # handoff verifier on the next pass.
  $cutoffText=if($stamp.ManagerRepackedUtc){[string]$stamp.ManagerRepackedUtc}else{[string]$stamp.BuiltUtc}
  try{$builtUtc=[DateTime]::Parse($cutoffText).ToUniversalTime()}catch{throw 'Native build receipt has no valid source-change cutoff.'}
  $allowed=@('reconstruction/candidate_receipt.py','installer/atmosphere-mod.ps1','installer/manager-status.ps1','build-candidate.ps1','build-identity.ps1','package.ps1','package-staging.ps1','installer/main.go','installer/component_download.go','installer/component_download_test.go','installer/component_release.go','installer/component_release_test.go','installer/library.ps1','installer/ownership.ps1','installer/manager-lifetime.ps1','installer/manager.ps1','installer/manager.xaml','installer/driver-settings.ps1','installer/payload_test.go','installer/public_bundle.go','installer/FusionSetup.cs','installer/support.ps1','installer/uninstall_windows.go','distribution/bootstrapper/main_windows.go','reconstruction/R104_PRIVATE_TEST_CHECKLIST.md','reconstruction/R105_PRIVATE_TEST_CHECKLIST.md','reconstruction/R106_PRIVATE_TEST_CHECKLIST.md','reconstruction/R107_PRIVATE_TEST_CHECKLIST.md','reconstruction/R132_PRIVATE_TEST_CHECKLIST.md','reconstruction/R132_WP0_HOST_ONLY_SCENARIO_TEMPLATE.json','reconstruction/R139_PRIVATE_TEST_CHECKLIST.md','reconstruction/R139_WP0_HOST_ONLY_SCENARIO_TEMPLATE.json','reconstruction/R140_PRIVATE_TEST_CHECKLIST.md','reconstruction/R140_WP0_HOST_ONLY_SCENARIO_TEMPLATE.json','reconstruction/R141_PRIVATE_TEST_CHECKLIST.md','reconstruction/R141_WP0_HOST_ONLY_SCENARIO_TEMPLATE.json','reconstruction/R142_PRIVATE_TEST_CHECKLIST.md','reconstruction/R142_WP0_HOST_ONLY_SCENARIO_TEMPLATE.json','reconstruction/R143_PRIVATE_TEST_CHECKLIST.md','reconstruction/R143_WP0_HOST_ONLY_SCENARIO_TEMPLATE.json')
  $sourcePaths=@(GetOptiShadeSourcePaths $Root)
  $changed=@($sourcePaths|Where-Object { $file=Join-Path $Root $_; (Get-Item -LiteralPath $file).LastWriteTimeUtc -gt $builtUtc })
  $unexpected=@($changed|Where-Object { $_ -notin $allowed })
  if($unexpected.Count){throw ('Manager-only repack found changed source files outside the allowlist: '+($unexpected -join ', '))}
  $dependencies=@(GetOptiShadeRepositoryBuildPaths $Root)
  $repository=Split-Path ([IO.Path]::GetFullPath($Root)) -Parent
  $changedDependencies=@($dependencies|Where-Object { (Get-Item -LiteralPath (Join-Path $repository $_)).LastWriteTimeUtc -gt $builtUtc })
  $allowedChangedDependencies=@('tests/reconstruction/test_candidate_receipt.py','tests/reconstruction/test_update_manager.ps1','tests/reconstruction/test_atmosphere_mod.ps1','tests/reconstruction/run_tests.py','tests/reconstruction/test_anti_cheat.ps1','tests/reconstruction/test_sources.py','tests/reconstruction/test_library_store_discovery.ps1','tests/reconstruction/test_manager_responsiveness.ps1','tests/reconstruction/test_receipt_read.ps1','Beta/installer/component_download_test.go')
  $unexpectedDependencies=@($changedDependencies|Where-Object {$_ -notin $allowedChangedDependencies})
  if($unexpectedDependencies.Count){throw ('Manager-only repack found changed repository build dependencies: '+($unexpectedDependencies -join ', '))}
  $managerChanges=@(@($stamp.ManagerOnlyChanges)+$changed|Select-Object -Unique)
 }
 foreach($entry in $stamp.Binaries.PSObject.Properties){if((Get-FileHash -LiteralPath (Join-Path $Root $entry.Name) -Algorithm SHA256).Hash -ne $entry.Value){throw ('Native build output changed: '+$entry.Name)}}
 if($sourceChanged -or $inputsChanged){
  $stamp.BuildMode='ManagerOnlyRepackVerifiedRuntime'
  if(-not $stamp.NativeBuildSourceSHA256){$stamp.NativeBuildSourceSHA256=$stamp.SourceSHA256}
  $stamp.ReusedFromExecutableSHA256=''
  $stamp.ManagerOnlyChanges=$managerChanges
  $stamp.SourceSHA256=$currentSource
  $stamp.BuildInputsSHA256=$currentInputs
  $stamp.ManagerRepackedUtc=[DateTime]::UtcNow.ToString('o')
 }
 return $stamp
}
function TestOptiShadeFinalPackage([string]$Executable,[string]$Root,[string]$Channel,[string]$Version){
 $resource=[Diagnostics.FileVersionInfo]::GetVersionInfo($Executable)
 if($resource.ProductVersion -notin @($Version,($Version+'.0'))){throw 'Final EXE resource version does not match the candidate'}
 $parent=if($env:OPTISHADE_LOCAL_CANDIDATE_DIR){Join-Path ([IO.Path]::GetFullPath([string]$env:OPTISHADE_LOCAL_CANDIDATE_DIR)) 'package-verification'}else{Join-Path $Root 'test-run/package-verification'}
 [void][IO.Directory]::CreateDirectory($parent)
 $before=@(Get-ChildItem -LiteralPath $parent -Directory|ForEach-Object Name)
 $proc=Start-Process -FilePath $Executable -ArgumentList @('--verify-package',('"'+$parent+'"')) -WindowStyle Hidden -PassThru -Wait
 if($proc.ExitCode){throw 'Final EXE extraction verification failed. Candidate is not approved.'}
 $fresh=@(Get-ChildItem -LiteralPath $parent -Directory|Where-Object Name -notin $before)
 if($fresh.Count -ne 1){throw 'Expected one fresh verification session'}
 $report=Get-Content -LiteralPath (Join-Path $fresh[0].FullName 'Package-verification.json') -Raw|ConvertFrom-Json
 if(-not $report.Passed -or $report.Build.Channel -ne $Channel -or $report.Build.Version -ne $Version -or $report.WinmmSHA256 -ne (Get-FileHash -LiteralPath "$Root/optiscaler/x64/Release/OptiScaler.dll").Hash -or $report.ExecutableSHA256 -ne (Get-FileHash -LiteralPath $Executable).Hash){throw 'Final EXE identity does not match the candidate'}
 $report|ConvertTo-Json -Depth 6|Set-Content -LiteralPath ($Executable+'.verification.json') -Encoding UTF8
}




# The candidate's mandatory fixtures live beside Beta. They are build inputs,
# including in a Common/archive workspace; an absent test must fail, not vanish.
function GetOptiShadeRepositoryBuildPaths([string]$Root){
 $local:optishadeBuildRepositoryRoot=Split-Path ([IO.Path]::GetFullPath($Root)) -Parent
 $local:optishadeBuildManifestPrefix=''
 if(Test-Path -LiteralPath (Join-Path $local:optishadeBuildRepositoryRoot '.git')){
  $local:optishadeRepositoryBuildFiles=@(git -c core.quotepath=false -C $local:optishadeBuildRepositoryRoot ls-files --cached --others --exclude-standard -- tests/reconstruction Research/Compositor Common | Where-Object {Test-Path -LiteralPath (Join-Path $local:optishadeBuildRepositoryRoot $_) -PathType Leaf})
  if($LASTEXITCODE){throw 'Cannot enumerate required repository build inputs'}
 }else{
  $local:optishadeBuildManifestPath=Join-Path $local:optishadeBuildRepositoryRoot 'R10-SOURCE-MANIFEST.json'
  if(-not(Test-Path -LiteralPath $local:optishadeBuildManifestPath)){$local:optishadeBuildManifestPath=Join-Path (Split-Path $local:optishadeBuildRepositoryRoot -Parent) 'Notes/FILE-MANIFEST-SHA256.json';$local:optishadeBuildManifestPrefix='Source/'}
  if(-not(Test-Path -LiteralPath $local:optishadeBuildManifestPath)){throw 'Repository build inventory is missing; retain tests/reconstruction and its source manifest'}
  $local:optishadeBuildManifestPathEntries=ConvertFrom-Json -InputObject (Get-Content -LiteralPath $local:optishadeBuildManifestPath -Raw)
  $local:optishadeRepositoryBuildFiles=[Collections.Generic.List[string]]::new()
  foreach($local:optishadeBuildManifestEntry in $local:optishadeBuildManifestPathEntries){$local:optishadeBuildManifestEntryPath=[string]$local:optishadeBuildManifestEntry.Path;if($local:optishadeBuildManifestEntryPath.StartsWith($local:optishadeBuildManifestPrefix,[StringComparison]::Ordinal)){[void]$local:optishadeRepositoryBuildFiles.Add($local:optishadeBuildManifestEntryPath.Substring($local:optishadeBuildManifestPrefix.Length))}}
 }
 $local:optishadeFilteredRepositoryBuildFiles=[Collections.Generic.List[string]]::new()
 foreach($local:optishadeBuildCandidatePath in $local:optishadeRepositoryBuildFiles){if(($local:optishadeBuildCandidatePath -like 'tests/reconstruction/*' -or $local:optishadeBuildCandidatePath -like 'Research/Compositor/*' -or $local:optishadeBuildCandidatePath -like 'Common/*') -and $local:optishadeBuildCandidatePath -notmatch '(^|/)(__pycache__|\.pytest_cache|test-results|build)/' -and $local:optishadeBuildCandidatePath -notlike '*.pyc'){[void]$local:optishadeFilteredRepositoryBuildFiles.Add($local:optishadeBuildCandidatePath)}}
 $local:optishadeRepositoryBuildFiles=$local:optishadeFilteredRepositoryBuildFiles.ToArray()
 $local:optishadeRequiredBuildSet=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
 foreach($local:optishadeBuildRelativePath in $local:optishadeRepositoryBuildFiles){
  if([IO.Path]::IsPathRooted($local:optishadeBuildRelativePath) -or $local:optishadeBuildRelativePath -match '(^|[\\/])\.\.([\\/]|$)'){throw ('Repository build inventory escapes its root: '+$local:optishadeBuildRelativePath)}
  if(-not(Test-Path -LiteralPath (Join-Path $local:optishadeBuildRepositoryRoot $local:optishadeBuildRelativePath) -PathType Leaf)){throw ('Required repository build input is missing: '+$local:optishadeBuildRelativePath)}
  [void]$local:optishadeRequiredBuildSet.Add($local:optishadeBuildRelativePath)
 }
 foreach($required in @('tests/reconstruction/run_tests.py','tests/reconstruction/run_installer_fixture.ps1','tests/reconstruction/test_components.ps1','tests/reconstruction/test_component_packages.ps1','tests/reconstruction/test_update_manager.ps1','Research/Compositor/test_prototype.py','Common/build-private-channel.ps1')){
  if(-not $local:optishadeRequiredBuildSet.Contains($required)){throw ('Required repository build dependency is absent from the inventory: '+$required)}
 }
 $local:optishadeOrderedBuildFiles=[string[]]@($local:optishadeRequiredBuildSet);[Array]::Sort($local:optishadeOrderedBuildFiles,[StringComparer]::Ordinal);return $local:optishadeOrderedBuildFiles
}
function GetOptiShadeBuildInputIdentity([string]$Root){
 $local:optishadeBuildIdentityRepository=Split-Path ([IO.Path]::GetFullPath($Root)) -Parent
 $local:optishadeBuildIdentityLines=[Collections.Generic.List[string]]::new()
 $local:optishadeBuildIdentityLines.Add('Beta-source '+(GetOptiShadeSourceIdentity $Root))
 $local:optishadeBuildIdentityFiles=[string[]]@(GetOptiShadeRepositoryBuildPaths $Root)
 foreach($local:optishadeBuildIdentityPath in $local:optishadeBuildIdentityFiles){$local:optishadeBuildIdentityLines.Add($local:optishadeBuildIdentityPath+' '+(Get-FileHash -LiteralPath (Join-Path $local:optishadeBuildIdentityRepository $local:optishadeBuildIdentityPath) -Algorithm SHA256).Hash)}
 $hash=[Security.Cryptography.SHA256]::Create()
 try{$local:optishadeBuildIdentityDigest=$hash.ComputeHash([Text.Encoding]::UTF8.GetBytes(($local:optishadeBuildIdentityLines -join "`n")));return ([BitConverter]::ToString($local:optishadeBuildIdentityDigest)).Replace('-','')}
 finally{$hash.Dispose()}
 }function TestOptiShadeFinalPackage([string]$Executable,[string]$Root,[string]$Channel,[string]$Version){
 $resource=[Diagnostics.FileVersionInfo]::GetVersionInfo($Executable)
 if($resource.ProductVersion -notin @($Version,($Version+'.0'))){throw 'Final EXE resource version does not match the candidate'}
 $parent=if($env:OPTISHADE_LOCAL_CANDIDATE_DIR){Join-Path ([IO.Path]::GetFullPath([string]$env:OPTISHADE_LOCAL_CANDIDATE_DIR)) 'package-verification'}else{Join-Path $Root 'test-run/package-verification'}
 [void][IO.Directory]::CreateDirectory($parent)
 $before=@(Get-ChildItem -LiteralPath $parent -Directory|ForEach-Object Name)
 $proc=Start-Process -FilePath $Executable -ArgumentList @('--verify-package',('"'+$parent+'"')) -WindowStyle Hidden -PassThru -Wait
 if($proc.ExitCode){throw 'Final EXE extraction verification failed. Candidate is not approved.'}
 $fresh=@(Get-ChildItem -LiteralPath $parent -Directory|Where-Object Name -notin $before)
 if($fresh.Count -ne 1){throw 'Expected one fresh verification session'}
 $report=Get-Content -LiteralPath (Join-Path $fresh[0].FullName 'Package-verification.json') -Raw|ConvertFrom-Json
 if(-not $report.Passed -or $report.Build.Channel -ne $Channel -or $report.Build.Version -ne $Version -or $report.WinmmSHA256 -ne (Get-FileHash -LiteralPath "$Root/optiscaler/x64/Release/OptiScaler.dll").Hash -or $report.ExecutableSHA256 -ne (Get-FileHash -LiteralPath $Executable).Hash){throw 'Final EXE identity does not match the candidate'}
 $report|ConvertTo-Json -Depth 6|Set-Content -LiteralPath ($Executable+'.verification.json') -Encoding UTF8
}




# The candidate's mandatory fixtures live beside Beta. They are build inputs,
# including in a Common/archive workspace; an absent test must fail, not vanish.



