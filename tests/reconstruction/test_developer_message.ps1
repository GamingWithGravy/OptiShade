$ErrorActionPreference='Stop'
$root=Resolve-Path (Join-Path $PSScriptRoot '..\..')
. (Join-Path $root 'Beta/installer/developer-message.ps1')
function Assert($condition,$message){if(-not $condition){throw $message}}
function Throws([scriptblock]$Block){try{& $Block;return $false}catch{return $true}}

# A normal message: title, body with line breaks, updated date.
$m=ConvertFromOptiShadeDeveloperMessage '{"schema":1,"title":"Welcome to OptiShade 1.0!","body":"Line one\nLine two","updated":"2026-11-09"}'
Assert ($m.Title -eq 'Welcome to OptiShade 1.0!') 'title not read'
Assert ($m.Body -eq "Line one`nLine two") 'line breaks not kept'
Assert ($m.Updated -eq '9 November 2026') ('updated date not formatted: '+$m.Updated)
# Control characters are dropped; nothing else is interpreted.
$m=ConvertFromOptiShadeDeveloperMessage ('{"schema":1,"title":"T","body":"a\u0007b <Bold>c</Bold>"}')
Assert ($m.Body -eq 'ab <Bold>c</Bold>') ('control characters or markup handled wrongly: '+$m.Body)
# Rejected: wrong schema, empty, oversized, not JSON.
Assert (Throws {ConvertFromOptiShadeDeveloperMessage '{"schema":2,"title":"T","body":"B"}'}) 'unknown schema accepted'
Assert (Throws {ConvertFromOptiShadeDeveloperMessage '{"schema":1,"title":"","body":""}'}) 'empty message accepted'
Assert (Throws {ConvertFromOptiShadeDeveloperMessage ('{"schema":1,"title":"T","body":"'+('x'*7000)+'"}')}) 'oversized body accepted'
Assert (Throws {ConvertFromOptiShadeDeveloperMessage 'not json'}) 'non-JSON accepted'
# Only GitHub's raw host over HTTPS.
Assert (Throws {StartOptiShadeDeveloperMessageDownload 'http://raw.githubusercontent.com/x/y/main/developer-message.json'}) 'plain HTTP accepted'
Assert (Throws {StartOptiShadeDeveloperMessageDownload 'https://example.com/developer-message.json'}) 'another host accepted'

# Cache: a bad download never replaces the last good copy.
$store=Join-Path ([IO.Path]::GetTempPath()) ('osdev-'+[guid]::NewGuid().ToString('N'))
try{
 Assert ($null -eq (ReadOptiShadeCachedDeveloperMessage $store)) 'cache present before any message'
 SaveOptiShadeDeveloperMessage $store '{"schema":1,"title":"Cached","body":"Saved copy"}'
 Assert ((ReadOptiShadeCachedDeveloperMessage $store).Title -eq 'Cached') 'cache not read back'
 Assert (Throws {SaveOptiShadeDeveloperMessage $store '{"schema":1,"title":"","body":""}'}) 'invalid message cached'
 Assert ((ReadOptiShadeCachedDeveloperMessage $store).Title -eq 'Cached') 'invalid message replaced the cache'
}finally{Remove-Item -LiteralPath $store -Recurse -Force -ErrorAction SilentlyContinue}

# The real download path completes against GitHub (the file may not be published yet).
$download=StartOptiShadeDeveloperMessageDownload
for($i=0;$i -lt 80 -and -not $download.Task.IsCompleted;$i++){Start-Sleep -Milliseconds 250}
if(-not $download.Task.IsCompleted){throw 'download did not finish in 20 s'}
$outcome=try{$json=CompleteOptiShadeDeveloperMessageDownload $download;'downloaded: '+(ConvertFromOptiShadeDeveloperMessage $json).Title}catch{'not published or unreachable: '+$_.Exception.Message}
'PASS: developer message parsing, limits, host check and cache. Live check: '+$outcome
