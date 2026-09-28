function GetOptiShadeManagerName([string]$Version,[string]$Channel){
 if($Version -notmatch '^\d+\.\d+(?:\.\d+){0,2}(?:-(?:alpha|beta|rc)[.-]?\d+)?$' -or $Channel -notin @('stable','beta')){throw 'Invalid manager version or channel.'}
 return "Optishade $Version $Channel.exe"
}
function AssertOptiShadeDownloadChannel([string]$Channel,[string]$Store){
 if($Channel -notin @('stable','beta')){throw 'Invalid download channel.'}
 if($Channel -eq 'beta' -and -not(Test-Path -LiteralPath (Join-Path $Store 'beta-updates.txt'))){throw 'Beta opt-in is off. No beta download was started.'}
}
function CompleteOptiShadeManagerUpdate([string]$Previous,[string]$PreviousHash,[string]$Destination,[string]$ExpectedHash,[string]$Store,[string]$Channel){
 if($Channel -notin @('stable','beta')){throw 'Invalid update channel.'}
 $dest=[IO.Path]::GetFullPath($Destination)
 if($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -ne $ExpectedHash){throw 'New manager verification failed; previous manager retained.'}
 $marker=Join-Path $Store 'beta-updates.txt'
 if($Channel -eq 'beta'){[void][IO.Directory]::CreateDirectory($Store);[IO.File]::WriteAllText($marker,'Opted into prerelease update offers')}
 elseif(Test-Path -LiteralPath $marker){Remove-Item -LiteralPath $marker -Force}
 if(-not $Previous){return ''}
 $old=[IO.Path]::GetFullPath($Previous)
 if($old -eq $dest -or -not(Test-Path -LiteralPath $old)){return ''}
 if([IO.Path]::GetExtension($old) -ne '.exe' -or $PreviousHash -notmatch '^[a-fA-F0-9]{64}$' -or (Get-Item -LiteralPath $old -Force).Attributes -band [IO.FileAttributes]::ReparsePoint -or (Get-FileHash -LiteralPath $old -Algorithm SHA256).Hash -ne $PreviousHash){return 'The previous EXE changed and was kept at: '+$old}
 for($attempt=0;$attempt -lt 10;$attempt++){
  try{Remove-Item -LiteralPath $old -Force -ErrorAction Stop;return ''}catch{Start-Sleep -Milliseconds 200}
 }
 return 'The previous EXE is still open and could not be removed: '+$old
}
