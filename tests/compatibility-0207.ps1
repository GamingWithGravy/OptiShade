$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/ownership.ps1"
. "$PSScriptRoot/../installer/library.ps1"
. "$PSScriptRoot/../installer/compatibility.ps1"
. "$PSScriptRoot/../installer/neural-download.ps1"
$root=Join-Path $env:TEMP ('OptiShade-0207-'+[guid]::NewGuid().ToString('N'))
$game=Join-Path $root '2020';$other=Join-Path $root '2024';$store=Join-Path $root 'Store'
New-Item -ItemType Directory -Path $game,$other -Force|Out-Null
Copy-Item "$PSScriptRoot/../installer/FusionSetup.exe" "$game/FlightSimulator.exe"
Copy-Item "$PSScriptRoot/../installer/FusionSetup.exe" "$other/FlightSimulator2024.exe"
function Check($test,$label){if(-not $test){throw $label};"PASS: $label"}
$gpu=[pscustomobject]@{Known=$true;Nvidia=$true;Names='NVIDIA GeForce RTX 3080'}
AssertMsfsNvidiaTarget "$game/FlightSimulator.exe" $gpu
$exe=@(FindFusionExecutable $game 'Steam')[0].Path
Check ($exe -eq "$game\FlightSimulator.exe") '2020 Steam resolves its own EXE'
Check ((GetMsfsTitle $game) -eq 'Microsoft Flight Simulator 2020') '2020 title has no test label'
Check ((GetMsfsTitle $other) -match '2024') '2024 identity retained'
Check ((ManifestPath $store $game) -ne (ManifestPath $store $other)) 'Separate simulator receipts'
$plan=GetFusionCompatibility $game $exe $gpu 'Steam'
Check ($plan.PossibleInput -and $plan.DownloadNvidia -and $plan.Proxy -eq 'dxgi.dll') '2020 temporal input candidate and Steam loader'
Check ($plan.Performance -match 'MSFS 2020: select DirectX 12') 'DX12 setup guidance retained'
Check ((@(FindFusionExecutable $game 'Xbox')[0].Path) -like '*FlightSimulator.exe') 'Accessible legacy Xbox 2020 main EXE accepted without helper'
Check ((GetFusionCompatibility $game $exe $gpu 'Xbox').Proxy -eq 'winmm.dll') 'Legacy Xbox loader uses platform evidence'
Copy-Item "$PSScriptRoot/../installer/FusionSetup.exe" "$game/gamelaunchhelper.exe"
Check ((@(FindFusionExecutable $game 'Xbox')[0].Path) -like '*gamelaunchhelper.exe') '2020 Xbox uses helper when present'
$plan=GetFusionCompatibility $game "$game/gamelaunchhelper.exe" $gpu 'Xbox'
Check ($plan.Proxy -eq 'winmm.dll') '2020 Xbox helper loader'
foreach($family in @('2060','3080','4070')){
 $g=[pscustomobject]@{Names='NVIDIA GeForce RTX '+$family}
 Check ((GetNeuralDownload $g).Family -match 'experimental') "RTX $family selects pinned experimental model"
}
$rejected=$false;try{GetNeuralDownload ([pscustomobject]@{Names='NVIDIA GeForce RTX 3080, NVIDIA GeForce RTX 5090'})}catch{$rejected=$true}
Check $rejected 'Ambiguous multiple RTX cards rejected'
@('[Menu]','ShortcutKey=120','[DlssNr]','Enabled=true','Passes=5','UnlockPasses=true','WorkingScale=0.75','[Other]','Enabled=true') | Set-Content "$game/OptiScaler.ini"
function AssertClosed($Game){}
SetOlderRtxTestSettings $game
$text=Get-Content "$game/OptiScaler.ini" -Raw
Check ($text -match 'Enabled=false' -and $text -match 'Passes=1' -and $text -match 'UnlockPasses=false') 'Test stays off at startup and uses one pass'
Check ($text -match 'ShortcutKey=120' -and $text -match 'WorkingScale=0.75' -and $text -match '(?s)\[Other\].*Enabled=true') 'Other settings and bindings preserved'
SetOlderRtxTestSettings $game
Check (@(Select-String -Path "$game/OptiScaler.ini" -Pattern '^Passes=').Count -eq 1) 'Repeated preparation is idempotent'
