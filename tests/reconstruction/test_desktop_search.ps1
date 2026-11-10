$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source=Join-Path $root 'Beta/installer/manager.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
[xml]$xml=Get-Content (Join-Path $root 'Beta/installer/manager.xaml') -Raw -Encoding UTF8
$form=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xml))
# Load only the production search functions: never execute manager startup or installer actions.
foreach($name in @('UpdateManagerSearch','OpenManagerSearchResult')){
 $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 if(-not $node){throw "Missing search function: $name"}
 Invoke-Expression $node.Extent.Text
}
function ShowPage($name){$script:openedPage=$name}
function SelectGame($game){$script:selectedGame=$game}
$script:libraryGames=@([pscustomobject]@{Name='X-Plane 12';Launcher='Steam';InstallFolder='D:\Games\XP12'})
UpdateManagerSearch
if($form.FindName('ManagerSearchResults').Items.Count -ne 7){throw 'Search omitted cached game or page'}
$form.FindName('ManagerSearch').Text='Update Manager';UpdateManagerSearch;OpenManagerSearchResult
if($script:openedPage -ne 'Updates'){throw 'Update Manager search did not navigate to Updates'}
$form.FindName('ManagerSearch').Text='MFG';UpdateManagerSearch;OpenManagerSearchResult
if($script:openedPage -ne 'Components'){throw 'MFG search did not navigate to Components'}
$form.FindName('ManagerSearch').Text='x-plane';UpdateManagerSearch;OpenManagerSearchResult
if($script:selectedGame.InstallFolder -ne 'D:\Games\XP12'){throw 'Game search lost actual install target'}
$form.FindName('ManagerSearch').Text='not-a-control';UpdateManagerSearch
if($form.FindName('OpenSearchResult').IsEnabled){throw 'Empty result remained actionable'}
$script:openedPage='unchanged';OpenManagerSearchResult
if($script:openedPage -ne 'unchanged'){throw 'Empty selection navigated'}
$form.Close()
'Desktop search passed: cached entries, case-insensitive query, exact game target, empty state. No startup, scan or installation actions executed.'
