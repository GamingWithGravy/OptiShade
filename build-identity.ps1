function GetOptiShadeSourceIdentity([string]$Root){
 $lines=[Collections.Generic.List[string]]::new()
 # Include tracked source and newly authored source, but never ignored build
 # products/private evidence. Matching local pinned link libraries are inputs.
 $paths=@(git -c core.quotepath=false -C $Root ls-files --cached --others --exclude-standard)
 if($LASTEXITCODE){throw 'Cannot enumerate candidate source'}
 $paths+=@(Get-ChildItem -LiteralPath "$Root/optiscaler/OptiScaler/library" -File -Recurse|ForEach-Object {$_.FullName.Substring($Root.Length+1).Replace('\','/')})
 # ReShade increments res/version.h during compilation; its final hash is stamped as build output.
 # Ordinal ordering is identical in Windows PowerShell 5.1 and PowerShell 7.
 $unique=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
 foreach($relative in $paths){[void]$unique.Add($relative)}
 $ordered=[string[]]@($unique)
 [Array]::Sort($ordered,[StringComparer]::Ordinal)
 foreach($relative in $ordered){
  $file=Join-Path $Root $relative
  if(Test-Path -LiteralPath $file -PathType Leaf){$lines.Add($relative+' '+(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash)}
 }
 $hash=[Security.Cryptography.SHA256]::Create()
 try{return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))))).Replace('-','')}
 finally{$hash.Dispose()}
}
function AssertOptiShadeCandidateBuild([string]$Root){
 $stampPath=Join-Path $Root 'test-run/native-build.json'
 if(-not(Test-Path -LiteralPath $stampPath)){throw 'Run build-candidate.ps1 first. Packaging requires matching fresh native build evidence.'}
 $stamp=Get-Content -LiteralPath $stampPath -Raw|ConvertFrom-Json
 if($stamp.SourceSHA256 -ne (GetOptiShadeSourceIdentity $Root)){throw 'Source changed since the candidate build. Rebuild before packaging.'}
 foreach($entry in $stamp.Binaries.PSObject.Properties){if((Get-FileHash -LiteralPath (Join-Path $Root $entry.Name) -Algorithm SHA256).Hash -ne $entry.Value){throw ('Native build output changed: '+$entry.Name)}}
 return $stamp
}
function TestOptiShadeFinalPackage([string]$Executable,[string]$Root,[string]$Channel,[string]$Version){
 $resource=[Diagnostics.FileVersionInfo]::GetVersionInfo($Executable)
 if($resource.ProductVersion -notin @($Version,($Version+'.0'))){throw 'Final EXE resource version does not match the candidate'}
 $parent=Join-Path $Root 'test-run/package-verification'
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
