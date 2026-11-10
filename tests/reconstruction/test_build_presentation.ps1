$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$header=Get-Content (Join-Path $root 'Beta/shared/OptiShadeVersion.h') -Raw
$definition=Get-Content (Join-Path $root 'Beta/shared/build-version.json') -Raw|ConvertFrom-Json
$candidateVersion=[string]$definition.version
if($candidateVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$'){throw 'Shared candidate version is missing'}
$candidateNumber=[version]$candidateVersion
$displayVersion=$candidateVersion+$(if($definition.channel -eq 'beta'){'-beta.'+[string]$definition.betaRevision}else{''})
$headerVersion=[regex]::Match($header,'OPTISHADE_VERSION_TEXT "([^"]+)"').Groups[1].Value
if($headerVersion -cne $displayVersion){throw 'Native title differs from the structured candidate version'}
$channelLabel=(Get-Culture).TextInfo.ToTitleCase([string]$definition.channel)
. (Join-Path $root 'Beta/installer/release-notes.ps1')
$temp=Join-Path ([IO.Path]::GetTempPath()) ('optishade-label-'+[guid]::NewGuid().ToString('N'))
$data=Join-Path $temp 'OptiShadeData';[void][IO.Directory]::CreateDirectory($data)
$file=Join-Path $data 'BuildIdentity.json'
$oldStore=$env:OPTISHADE_STORE
try{
 @{Version='0.21.7-beta.1';Channel='beta';PrivateTesting=$true;PrivateBuildLabel='Rebuild R3';PrivateTestNumber=0}|ConvertTo-Json|Set-Content -LiteralPath $file -Encoding UTF8
 $p=GetOptiShadeManagerPresentation $temp $false
 if($p.Test -ne 'Rebuild R3' -or $p.Footer -notmatch 'Rebuild R3' -or $p.Scope -ne 'PRIVATE TESTING ONLY'){throw 'Private reconstruction label lost'}
 $p=GetOptiShadeManagerPresentation $temp $true
 if($p.Package -ne 'PORTABLE'){throw 'Portable scope lost'}
 @{Version='1.0.19';Channel='stable';PrivateTesting=$false;PrivateBuildLabel=''}|ConvertTo-Json|Set-Content -LiteralPath $file -Encoding UTF8
 $p=GetOptiShadeManagerPresentation $temp $false
 if($p.Test -or $p.Footer -match 'Rebuild' -or $p.Scope -ne 'PUBLIC RELEASE' -or $p.Version -ne '1.0.19' -or $p.Channel -ne 'STABLE'){throw 'Private label leaked into the stable public presentation'}
 $manager=Get-Content (Join-Path $root 'Beta/installer/manager.xaml') -Raw -Encoding UTF8
 if([regex]::Matches($manager,'PRIVATE TESTING ONLY').Count -ne 1 -or $manager -notmatch 'x:Name="IntroBuildType"'){throw 'Private testing wording must remain on the startup screen only'}
 if(-not $manager.Contains(('Title="OptiShade '+$displayVersion+' / '+$channelLabel+' candidate"')) -or -not $manager.Contains(('<TextBlock Text="'+$displayVersion+'" FontSize="14" x:Name="HeaderVersion"'))){throw 'Manager title and header must identify the shared candidate version'}
 $versionInfo=Get-Content (Join-Path $root 'Beta/installer/versioninfo.json') -Raw -Encoding UTF8|ConvertFrom-Json
 foreach($fixed in @($versionInfo.FixedFileInfo.FileVersion,$versionInfo.FixedFileInfo.ProductVersion)){if($fixed.Major -ne $candidateNumber.Major -or $fixed.Minor -ne $candidateNumber.Minor -or $fixed.Patch -ne $candidateNumber.Build){throw 'Fixed Windows version disagrees with shared candidate version'}}
 if($versionInfo.StringFileInfo.FileVersion -ne $displayVersion -or $versionInfo.StringFileInfo.ProductVersion -ne $displayVersion){throw 'Displayed Windows version disagrees with shared candidate version'}
 $managerScript=Get-Content (Join-Path $root 'Beta/installer/manager.ps1') -Raw -Encoding UTF8
 if($managerScript -notmatch "IntroBuildType'\)\.Text='PRIVATE TESTING ONLY'"){throw 'The startup screen private testing label is not explicitly retained'}
 if($manager -notmatch 'x:Name="BetaChannel"[^>]*IsEnabled="False"[^>]*Opacity="0\.42"' -or $manager -notmatch 'Locked until the future VR beta'){throw 'Beta channel must remain visibly locked until the VR beta'}
 if($manager -notmatch '<Run Text=" STABLE"' -or $manager -match '<Run Text=" BETA"'){throw 'Stable release branding is missing or the Beta badge is still shown'}
 $env:OPTISHADE_STORE=Join-Path $temp 'store';[void][IO.Directory]::CreateDirectory($env:OPTISHADE_STORE)
 . (Join-Path $root 'Beta/installer/updates.ps1')
 Set-Content -LiteralPath (Join-Path $env:OPTISHADE_STORE 'beta-updates.txt') -Value 'stale beta preference'
 InitializeOptiShadeUpdateChannel -InstalledChannel stable
 if((GetOptiShadeUpdateChannel) -ne 'stable' -or (Test-Path -LiteralPath (Join-Path $env:OPTISHADE_STORE 'beta-updates.txt'))){throw 'Stable startup did not clear the old Beta preference'}
 $rejected=$false;try{SetOptiShadeUpdateChannel $true}catch{$rejected=$_.Exception.Message.Contains('Beta updates are locked')}
 if(-not $rejected){throw 'The locked Beta channel accepted opt-in'}
 . (Join-Path $root 'Beta/installer/ownership.ps1');if((GetBundledOptiShadeVersion) -cne ('P'+$displayVersion)){throw 'Installer ownership version disagrees with shared candidate version'}
 'Private, portable and stable-public presentation cases passed; startup screen retains the private label.'
}finally{if($oldStore){$env:OPTISHADE_STORE=$oldStore}else{Remove-Item Env:OPTISHADE_STORE -ErrorAction SilentlyContinue};if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}
