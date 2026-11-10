$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Beta/installer/ownership.ps1"
. "$root/Beta/installer/components.ps1"
function TestLocalComponentReceipt($Manifest,$Id){return $false}
function GetLocalComponentPackageState($Manifest,$Package){return [pscustomobject]@{Available=$false}}
$manager=Join-Path $root 'Beta/installer/manager.ps1';$parse=$null;$tokens=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($manager,[ref]$tokens,[ref]$parse)
if($parse.Count){throw $parse[0]}
$node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'GetComponentUpdateIds'},$true)
if(-not $node){throw 'GetComponentUpdateIds was not found'}
Invoke-Expression $node.Extent.Text
$temp=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-update-architecture-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try{
 $script:bundleCatalog=@(@{Path='host64/OptiShadeLegacyNR.addon32';Hash=('A'*64)},@{Path='host64/worker.dll';Hash=('B'*64)})
 $script:localComponentPackage=$null
 $manifest=[pscustomobject]@{Status='Installed';Game=$temp;Architecture='x64';Components=@('Neural');Files=@()}
 $x64=@(GetComponentUpdateIds $manifest)
 if($x64.Count){throw ('x64 incorrectly reports skipped host64 files as an update: '+($x64 -join ','))}
 $manifest.Architecture='x86'
 $x86=@(GetComponentUpdateIds $manifest)
 if('Neural' -notin $x86){throw 'x86 did not request missing applicable Legacy NR files'}
 Write-Output 'PASS: x64 ignores omitted host64 Neural files; x86 still detects missing applicable files.'
}finally{Remove-Item -LiteralPath $temp -Force -Recurse -ErrorAction SilentlyContinue}
