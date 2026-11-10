function NewAntiCheatDialog($Owner,$Result){
 [xml]$markup=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'anti-cheat-dialog.xaml') -Raw
 $dialog=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $markup))
 [xml]$themeXml=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'dialog-theme.xaml') -Raw
 $theme=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $themeXml))
 $dialog.Resources.MergedDictionaries.Add($theme)
 $dialog.FindName('CancelInstall').Background=[Windows.Media.BrushConverter]::new().ConvertFromString('#30283F')

 if($Owner){$dialog.Owner=$Owner};$dialog.MaxHeight=[Math]::Max(350,[Windows.SystemParameters]::WorkArea.Height-40)
 $dialog.FindName('GameName').Text='Game: '+$Result.Target.Name
 $providers=@(foreach($id in @($Result.Matches|Select-Object -ExpandProperty Id -Unique)){$group=@($Result.Matches|Where-Object Id -eq $id);$group[0].Name+$(if(-not @($group|Where-Object Strength -eq 'Detected').Count){' (unconfirmed)'})})
 $dialog.FindName('Providers').Text='Anti-cheat: '+$(if($providers.Count){$providers -join ', '}else{'No matching provider identified (check incomplete)'})
 $officialOnly=$Result.Matches.Count -gt 0 -and -not @($Result.Matches|Where-Object Basis -ne 'Official').Count
 $dialog.FindName('Heading').Text=switch($Result.State){'Detected'{'⚠ ANTI-CHEAT DETECTED'} 'Possible'{'POSSIBLE ANTI-CHEAT DETECTED'} default{'ANTI-CHEAT CHECK INCOMPLETE'}}
 $dialog.FindName('Opening').Text=if($officialOnly){'Official game information identifies this anti-cheat system.'}elseif($Result.State -eq 'Detected'){'Anti-cheat has been detected in this game.'}elseif($Result.State -eq 'Possible'){'Possible anti-cheat components were found in this game.'}else{'No matching anti-cheat provider was identified, but the check is incomplete. This is not a confirmed detection or a guarantee that the game has no anti-cheat.'}
 $dialog.FindName('Evidence').Text=if($officialOnly){'Evidence: Official information for this game lists '+($providers -join ', ')+'.'}elseif($Result.Matches.Count){'Evidence: Matching components found in the selected game folder; see details for verification.'}else{'Evidence: '+($Result.Limitations|Select-Object -First 1)}
 $details=@('Checked root: '+$Result.Target.Root,'Rendering executable: '+$Result.Target.Executable)
 foreach($match in $Result.Matches){$details+=($match.Name+' — '+$match.Path+' — '+$match.Rule+' — '+$match.Corroboration+' — '+$match.Mode+' — '+$match.Source)}
 $details+=@($Result.Limitations);$dialog.FindName('Details').Text=$details -join "`n"
 SetOptiShadeConsentDialogChrome $dialog
 $contextCheck=$script:AntiCheatContextValid
 $check=$dialog.FindName('AcceptRisk');$remember=$dialog.FindName('DontShowForGame');$accept=$dialog.FindName('AcceptInstall');$cancel=$dialog.FindName('CancelInstall')
 $check.Add_Checked({$accept.IsEnabled=$true}.GetNewClosure());$check.Add_Unchecked({$accept.IsEnabled=$false}.GetNewClosure())
 $accept.Add_Click({if($check.IsChecked -eq $true -and (-not $contextCheck -or (& $contextCheck))){$dialog.Tag=[bool]($remember.IsChecked -eq $true);$dialog.DialogResult=$true}}.GetNewClosure())
 $cancel.Add_Click({$dialog.DialogResult=$false}.GetNewClosure());$dialog.Add_ContentRendered({[void]$cancel.Focus()}.GetNewClosure())
 return $dialog
}
function ConfirmFusionInstall($Owner,$Result){
 $dialog=NewAntiCheatDialog $Owner $Result
 $contextCheck=$script:AntiCheatContextValid
 $timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(200)
 $timer.Add_Tick({if($contextCheck -and -not(& $contextCheck)){$dialog.DialogResult=$false}}.GetNewClosure())
 try{
  $timer.Start();$show={$dialog.Topmost=$true;$dialog.ShowDialog()}.GetNewClosure()
  $accepted=if(Get-Command InvokeWithOperationProgressHidden -ErrorAction SilentlyContinue){(InvokeWithOperationProgressHidden $show) -eq $true}else{(& $show) -eq $true}
  if($accepted -and $dialog.Tag -eq $true){try{SaveAntiCheatGameSuppression $Result}catch{Write-Warning ('The game-specific warning preference could not be saved: '+$_.Exception.GetBaseException().Message)}}
  return $accepted
 }finally{$timer.Stop()}
}

function SetOptiShadeConsentDialogChrome($Dialog){
 $title=$Dialog.FindName('TitleBar');$close=$Dialog.FindName('CloseWindow');$minimize=$Dialog.FindName('MinimizeWindow')
 if($title){$title.Add_MouseLeftButtonDown({if($_.ClickCount -eq 2){return};try{$Dialog.DragMove()}catch{}}.GetNewClosure())}
 if($close){$close.Add_MouseLeftButtonUp({$Dialog.DialogResult=$false}.GetNewClosure())}
 if($minimize){$minimize.Add_MouseLeftButtonUp({$Dialog.WindowState=[Windows.WindowState]::Minimized}.GetNewClosure())}
}

function GetOptiShadeAntiCheatAcceptancePath {
 $state=if($env:OPTISHADE_STORE){$env:OPTISHADE_STORE}else{Join-Path $env:LOCALAPPDATA 'OptiShade'}
 Join-Path $state 'anti-cheat-install-acceptance.json'
}
function TestOptiShadeAntiCheatAccepted {
 if($script:AntiCheatSessionAccepted -eq $true -or $env:OPTISHADE_ANTICHEAT_SESSION_ACCEPTED -eq '1'){return $true}
 $path=GetOptiShadeAntiCheatAcceptancePath
 try{
  if((Test-Path -LiteralPath $path -PathType Leaf) -and (Get-Item -LiteralPath $path).Length -le 16KB){
   $record=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
   if($record.Schema -eq 1 -and $record.Accepted -eq $true -and $record.WarningVersion -eq 1){return $true}
  }
 }catch{}
 # The OptiShade installer's User Agreement includes this anti-cheat and ban
 # risk and must be accepted before installing, so it is not asked again here.
 # Per-game anti-cheat warnings before installing into a game are unchanged.
 try{
  $state=Split-Path -Parent $path
  $agreement=Join-Path $state 'user-agreement-acceptance.json'
  if(-not(Test-Path -LiteralPath $agreement -PathType Leaf) -or (Get-Item -LiteralPath $agreement).Length -gt 16KB){return $false}
  $record=Get-Content -LiteralPath $agreement -Raw -Encoding UTF8|ConvertFrom-Json
  return ($record.Schema -eq 1 -and $record.Accepted -eq $true -and [int]$record.AgreementVersion -ge 1)
 }catch{return $false}
}

function GetAntiCheatGameSuppressionPath($Result){
 if(-not $Result -or -not $Result.Target -or -not $Result.Target.Root){throw 'The selected game identity is unavailable.'}
 $state=if($env:OPTISHADE_STORE){$env:OPTISHADE_STORE}else{Join-Path $env:LOCALAPPDATA 'OptiShade'}
 $root=[IO.Path]::GetFullPath([string]$Result.Target.Root).TrimEnd('\').ToLowerInvariant()
 $key=GetAntiCheatHash (($root,[string]$Result.Target.Store,[string]$Result.Target.ProductId) -join "`n")
 Join-Path (Join-Path $state 'AntiCheatConsent') ('suppressed-'+$key+'.json')
}
function TestAntiCheatGameSuppressed($Result){
 try{
  $path=GetAntiCheatGameSuppressionPath $Result
  if(-not(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -gt 8KB){return $false}
  $saved=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
  return ($saved.Schema -eq 1 -and $saved.Suppressed -eq $true)
 }catch{return $false}
}
function SaveAntiCheatGameSuppression($Result){
 $path=GetAntiCheatGameSuppressionPath $Result
 $root=[IO.Path]::GetFullPath([string]$Result.Target.Root).TrimEnd('\')
 [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
 $record=[ordered]@{Schema=1;Suppressed=$true;TargetRoot=$root;Store=[string]$Result.Target.Store;ProductId=[string]$Result.Target.ProductId;SavedUtc=[datetime]::UtcNow.ToString('o')}
 $temp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 try{[IO.File]::WriteAllText($temp,($record|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $temp -Destination $path -Force -ErrorAction Stop}finally{if(Test-Path -LiteralPath $temp -PathType Leaf){Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}}
}
function SaveOptiShadeAntiCheatAcceptance {
 $path=GetOptiShadeAntiCheatAcceptancePath
 [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
 $record=@{Schema=1;Accepted=$true;WarningVersion=1;AcceptedUtc=[datetime]::UtcNow.ToString('o')}
 [IO.File]::WriteAllText($path,($record|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($true))
}
function NewOptiShadeAntiCheatAgreementDialog($Owner){
 [xml]$markup=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'anti-cheat-agreement.xaml') -Raw
 $dialog=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $markup))
 [xml]$themeXml=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'dialog-theme.xaml') -Raw
 $theme=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $themeXml))
 $dialog.Resources.MergedDictionaries.Add($theme)
 $dialog.FindName('Decline').Background=[Windows.Media.BrushConverter]::new().ConvertFromString('#30283F')
 SetOptiShadeConsentDialogChrome $dialog
 if($Owner){$dialog.Owner=$Owner}
 $dialog.MaxHeight=[Math]::Max(350,[Windows.SystemParameters]::WorkArea.Height-40)
 $accept=$dialog.FindName('Accept');$risk=$dialog.FindName('AcceptRisk');$dontShow=$dialog.FindName('DontShowAgain')
 $risk.Add_Checked({$accept.IsEnabled=$true}.GetNewClosure());$risk.Add_Unchecked({$accept.IsEnabled=$false}.GetNewClosure())
 $accept.Add_Click({if($risk.IsChecked -eq $true){$dialog.Tag=[bool]$dontShow.IsChecked;$dialog.DialogResult=$true}}.GetNewClosure())
 $dialog.FindName('Decline').Add_Click({$dialog.DialogResult=$false}.GetNewClosure())
 $dialog.Add_ContentRendered({[void]$dialog.FindName('Decline').Focus()}.GetNewClosure())
 return $dialog
}
function ConfirmOptiShadeAntiCheatAgreement($Owner){
 $dialog=NewOptiShadeAntiCheatAgreementDialog $Owner
 try{
  if($dialog.ShowDialog() -eq $true){
   $script:AntiCheatSessionAccepted=$true;$env:OPTISHADE_ANTICHEAT_SESSION_ACCEPTED='1'
   if($dialog.Tag -eq $true){SaveOptiShadeAntiCheatAcceptance}
   return $true
  }
  $script:AntiCheatSessionAccepted=$false;$env:OPTISHADE_ANTICHEAT_SESSION_ACCEPTED=$null
  return $false
 }finally{$dialog.Close()}
}
function EnsureOptiShadeAntiCheatAgreement($Owner){
 if(TestOptiShadeAntiCheatAccepted){return $true}
 if(-not $script:AntiCheatDecision){throw 'UserConsentRequired: Read and accept the OptiShade installation safety warning in the manager. Nothing changed.'}
 $accepted=(& $script:AntiCheatDecision)
 if(-not $accepted -or -not(TestOptiShadeAntiCheatAccepted)){throw 'Nothing changed; accept the installation safety warning before installing.'}
 return $true
}

function UseOptionalDlss($Manifest,$Plan){return ($Manifest.OptionalDlss -eq $true -and $Plan.DownloadNvidia -eq $true)}

function ShouldWarnAmdExperimental($Gpu){
 # Inventory is not the game's active adapter. An AMD iGPU alongside NVIDIA is
 # not evidence that the user is installing for AMD; retain runtime device checks.
 if(-not $Gpu -or -not $Gpu.Known){return $false}
 if($Gpu.Nvidia -or $Gpu.Names -match '(?i)NVIDIA'){return $false}
 # Conservative model allowlist: generic Radeon Graphics, Vega 8/11 and
 # Radeon 680M/780M/890M are not evidence of a dedicated card.
 $dedicated='(?i)\bRadeon\s+(?:RX\s+(?:\d{3,4}\b|Vega\s+(?:56|64)\b)|VII\b|R[579]\s+(?:\d{3}\b|Fury\b)|Pro\s+(?:W\d{4}\b|WX\s*\d{4}\b))'
 return [bool]($Gpu.Names -match $dedicated)
}
function ConfirmAmdExperimental($Owner){
 return (ShowOptiShadeDialog $Owner 'AMD support is experimental. Image effects and available FSR/XeSS routes can be used, but NVIDIA neural rendering is not available on AMD. Compatibility, performance and image quality still need testing. Continue with this installation?' 'AMD compatibility' 'OKCancel' 'Information' 'Cancel') -eq 'OK'
}
function GetNvidiaDriverWarning($Gpu){
 if(-not $Gpu -or (-not $Gpu.Nvidia -and $Gpu.Names -notmatch '(?i)NVIDIA')){return ''}
 $drivers=@($Gpu.Drivers|Where-Object {$_.Name -match '(?i)NVIDIA'})
 if(-not $drivers.Count){return 'The NVIDIA driver version could not be detected. Compatibility is unknown. Please update to NVIDIA driver 616.92 or newer to help avoid possible issues.'}
 $messages=@(foreach($driver in $drivers){
  $version=[string]$driver.Version
  if($version -notmatch '^\d{3,4}\.\d{2}$'){'NVIDIA driver version unknown for '+$driver.Name+'. Please update to NVIDIA driver 616.92 or newer to help avoid possible issues.'}
  elseif([version]$version -lt [version]'616.92'){"Driver $version detected for $($driver.Name). Compatibility with this driver is unknown. Please update to 616.92 or newer to help avoid possible issues."}
 })
 return ($messages -join "`n`n")
}
function ConfirmNvidiaDriver($Owner,$Gpu){
 $message=GetNvidiaDriverWarning $Gpu
 if(-not $message){return $true}
 return (ShowOptiShadeDialog $Owner ($message+"`n`nThis is the recommended baseline, not a compatibility guarantee. Cancel to update your driver, or choose OK to continue.") 'Check your graphics driver' 'OKCancel' 'Information' 'Cancel') -eq 'OK'
}
