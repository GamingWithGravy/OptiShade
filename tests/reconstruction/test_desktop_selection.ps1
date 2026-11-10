$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Beta/installer/library.ps1"
[xml]$xml=Get-Content "$root/Beta/installer/manager.xaml" -Raw -Encoding UTF8
$form=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xml))
. "$root/Beta/installer/manager-status.ps1"
$managerSource=Get-Content "$root/Beta/installer/manager.ps1" -Raw -Encoding UTF8
if(-not $managerSource.Contains('$card.ActionLabel=if($card.Installed){''Manage''}')){throw 'Installed library cards must offer Manage.'}
if($xml.OuterXml -notmatch 'Text="\{Binding ActionLabel\}"'){throw 'Library action button is not bound to its state label.'}
if($xml.OuterXml -match 'x:Name="EditionSteam"|x:Name="EditionXbox"'){throw 'Removed simulator-specific edition controls returned.'}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile("$root/Beta/installer/manager.ps1",[ref]$tokens,[ref]$errors)
if($errors.Count){throw $errors[0]}
foreach($name in @('SelectGame','SetSelectedFusionGame','GetDetectedStoreDisplay','GetCachedManagerGameStatus')){
 $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
 if(-not $function){throw "Missing production function $name"};Invoke-Expression $function.Extent.Text
}
function ShowPage($name){$script:shownPage=$name}
function GetFusionGameTargetFolder{throw 'Selecting a displayed game must not probe the filesystem'}
$script:busy=$false;$script:removedGames=@{};$path=$form.FindName('GamePath');$status=$form.FindName('Status')
$steam=[pscustomobject]@{Name='MSFS 2024';Folder='D:\fixture\steam';InstallFolder='D:\fixture\steam';Launcher='Steam';Thumbnail=$null;Label='Fixture Steam'}
$xbox=[pscustomobject]@{Name='MSFS 2024';Folder='E:\fixture\xbox';InstallFolder='E:\fixture\xbox\Content';Launcher='Xbox';Thumbnail=$null;Label='Fixture Xbox'}
$xp=[pscustomobject]@{Name='X-Plane 12';Folder='F:\fixture\xp';InstallFolder='F:\fixture\xp';Launcher='Laminar Research';Thumbnail=$null;Label='Fixture XP'}
$byPath=@{}
$byPath[(GetOptiShadeManagerStatusKey $steam.Folder)]=[pscustomobject]@{Folder=$steam.Folder;Game=$steam}
$byPath[(GetOptiShadeManagerStatusKey $xbox.Folder)]=[pscustomobject]@{Folder=$xbox.InstallFolder;Game=$xbox}
$script:managerStatusState=[pscustomobject]@{Snapshot=[pscustomobject]@{ByPath=$byPath}}
try{
 $form.FindName('MsfsCopies').ItemsSource=@($steam,$xbox,$xp)
 $form.FindName('MsfsCopies').SelectedItem=$steam
 SelectGame $xbox
 if($form.FindName('MsfsCopies').SelectedItem -ne $xbox -or $path.Text -ne $xbox.InstallFolder -or $script:shownPage -ne 'Setup'){throw 'Home selection left the wrong Setup simulator or verified nested path'}
 if($form.FindName('SelectedTitle').Text -ne $xbox.Name -or $form.FindName('DetectedStore').Text -ne 'Xbox / Microsoft Store'){throw 'Selected title/store did not follow the chosen game'}
 SelectGame $xp
 if($path.Text -ne $xp.Folder -or $form.FindName('SelectedTitle').Text -ne $xp.Name){throw 'Uncached selection did not retain its own game root while awaiting verification'}
 # An unrelated InstallFolder hint cannot redirect an unverified UI selection.
 $xp.InstallFolder='E:\fixture\unrelated';SelectGame $xp
 if($path.Text -ne $xp.Folder){throw 'Stale target hint redirected an unverified selection'}
 if($form.IsVisible){throw 'The selection fixture must remain offscreen'}
 'PASS: Home/Setup selection, verified nested target, selected title/store, and stale hint isolation. No game files read or installed.'
}finally{$form.Close()}
