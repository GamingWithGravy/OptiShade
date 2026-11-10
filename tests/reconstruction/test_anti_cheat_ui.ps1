param([string]$Installer=(Join-Path $PSScriptRoot '../../Beta/installer'),[string]$Output=(Join-Path $PSScriptRoot '../../test-run/r103-anti-cheat-ui'))
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
. "$Installer/anti-cheat.ps1"
. "$Installer/consent.ps1"
function Check($Value,$Message){if(-not $Value){throw $Message};Write-Output ('PASS: '+$Message)}
[void][IO.Directory]::CreateDirectory($Output)
$result=[pscustomobject]@{State='Possible';Target=[pscustomobject]@{Name='Fixture <Game & literal text> — long edition name for keyboard and scaling checks';Root='C:\Fixture';Executable='C:\Fixture\game.exe'};Matches=@([pscustomobject]@{Id='eac';Name='Easy Anti-Cheat';Strength='Possible';Basis='Local';Path='EasyAntiCheat';Rule='eac-local';Corroboration='Directory name only';Mode='Presence does not establish activity.';Source='https://www.epicgames.com/help/'},[pscustomobject]@{Id='battleye';Name='BattlEye';Strength='Possible';Basis='Local';Path='BattlEye';Rule='battleye-local';Corroboration='Directory name only';Mode='Presence does not establish activity.';Source='https://www.battleye.com/support/faq/'});Limitations=@()}
$dialog=NewAntiCheatDialog $null $result
$accept=$dialog.FindName('AcceptInstall');$checkBox=$dialog.FindName('AcceptRisk')
Check (-not $accept.IsEnabled -and -not $checkBox.IsChecked -and -not $accept.IsDefault) 'Continue initially disabled and not Enter default'
Check ($dialog.FindName('GameName').Text.Contains('<Game & literal text>')) 'unusual title is literal text'
$checkBox.IsChecked=$true;Check $accept.IsEnabled 'checked enables Continue'
$checkBox.IsChecked=$false;Check (-not $accept.IsEnabled) 'unchecking disables Continue'
$dialog.Measure([Windows.Size]::new(900,700));$dialog.Arrange([Windows.Rect]::new(0,0,900,700));$dialog.UpdateLayout()
Check ($dialog.ActualWidth -le 900 -and $dialog.ActualHeight -le 700) 'anti-cheat dialog measures without opening a window'
$agreement=NewOptiShadeAntiCheatAgreementDialog $null
$agreementText=Get-Content -LiteralPath (Join-Path $Installer 'anti-cheat-agreement.xaml') -Raw
$accept=$agreement.FindName('Accept');$risk=$agreement.FindName('AcceptRisk');$dontShow=$agreement.FindName('DontShowAgain')
Check (-not $accept.IsEnabled -and -not $risk.IsChecked -and -not $dontShow.IsChecked) 'global agreement requires explicit consent and persistence is optional'
Check ($agreementText -match 'anti-cheat' -and $agreementText -match 'publisher guidance') 'agreement explains anti-cheat risk and checking game rules'
Check ($agreementText -match 'Gravy' -and $agreementText -match 'suspension or ban') 'agreement names the requested account enforcement risk'
$risk.IsChecked=$true;Check $accept.IsEnabled 'acceptance checkbox enables Accept'
$risk.IsChecked=$false;Check (-not $accept.IsEnabled) 'unchecking acceptance disables Accept'
$risk.IsChecked=$true;$dontShow.IsChecked=$true
$agreement.Measure([Windows.Size]::new(900,700));$agreement.Arrange([Windows.Rect]::new(0,0,900,700));$agreement.UpdateLayout()
Check ($agreement.ActualWidth -le 900 -and $agreement.ActualHeight -le 700) 'global agreement measures without flashing a window'
Write-Output 'Anti-cheat dialog controls validated without showing windows.'