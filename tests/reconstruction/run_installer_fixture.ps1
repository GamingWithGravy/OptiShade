param([Parameter(Mandatory=$true)][string]$TestScript,[string]$ArgumentsBase64='W10=')
$ErrorActionPreference='Stop'
$resolved=[IO.Path]::GetFullPath($TestScript)
if(-not [string]::Equals([IO.Path]::GetDirectoryName($resolved),[IO.Path]::GetFullPath($PSScriptRoot),[StringComparison]::OrdinalIgnoreCase)){throw 'Only reconstruction fixtures may use this harness.'}
$arguments=ConvertFrom-Json ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ArgumentsBase64)))
$parameters=@{}
for($i=0;$i -lt $arguments.Count;$i++){
 $key=[string]$arguments[$i];if(-not $key.StartsWith('-')){throw 'Fixture arguments must be named.'}
 if($i+1 -lt $arguments.Count -and -not ([string]$arguments[$i+1]).StartsWith('-')){$parameters[$key.TrimStart('-')]=$arguments[++$i]}else{$parameters[$key.TrimStart('-')]=$true}
}
$fixtureStore=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-ConsentFixture-'+[guid]::NewGuid().ToString('N'))
$previous=$env:OPTISHADE_STORE;$env:OPTISHADE_STORE=$fixtureStore
# Explicit test-only UI decision for unrelated installer fixtures. Production
# never reads a test environment flag or accepts a force/confirm bypass.
# Simulate accepting the launch-wide agreement with “don't show again” for the
# isolated fixture store. Returning true alone is not acceptance evidence: the
# real prompt also persists the acceptance before mutations can proceed.
$script:AntiCheatDecision={param($result) SaveOptiShadeAntiCheatAcceptance;return $true}
$script:AntiCheatOperation=@{Name='isolated installer fixture';Accepted=@{}}
try{. $resolved @parameters}finally{
 $env:OPTISHADE_STORE=$previous;$script:AntiCheatDecision=$null;$script:AntiCheatOperation=$null
 if([IO.Path]::GetFullPath($fixtureStore).StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $fixtureStore -Leaf) -like 'OptiShade-ConsentFixture-*' -and (Test-Path -LiteralPath $fixtureStore)){Remove-Item -LiteralPath $fixtureStore -Recurse -Force}
}
