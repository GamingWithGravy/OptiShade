$ErrorActionPreference='Stop'
$repository=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repository 'Beta/build-identity.ps1')
$checks=0
function Assert([bool]$Condition,[string]$Message){$script:checks++;if(-not $Condition){throw $Message}}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('optishade-build-inputs-'+[guid]::NewGuid().ToString('N'))
$copy=$fixture+'-copy'
try{
 $beta=Join-Path $fixture 'Beta'
 $relative=@('installer/GlassCockpit/glass-cockpit-dlss-fix.addon64','installer/GlassCockpit/PROVENANCE.json','optiscaler/external/freetype/freetype.lib','optiscaler/external/FidelityFX-SDK-v2/Kits/FidelityFX/signedbin/amd_fidelityfx_loader_dx12.dll','optiscaler/external/FidelityFX-SDK-v2/Kits/FidelityFX/signedbin/amd_fidelityfx_upscaler_dx12.dll','optiscaler/external/FidelityFX-SDK-v2/Kits/FidelityFX/signedbin/amd_fidelityfx_framegeneration_dx12.dll','optiscaler/external/FidelityFX-SDK/PrebuiltSignedDLL/amd_fidelityfx_vk.dll','optiscaler/external/directx_agility_sdk/lib/D3D12Core.dll')
 $required=@('tests/reconstruction/run_tests.py','tests/reconstruction/run_temporal_interval_trace_tests.py','tests/reconstruction/run_installer_fixture.ps1','tests/reconstruction/test_components.ps1','tests/reconstruction/test_component_packages.ps1','tests/reconstruction/test_update_manager.ps1','tests/reconstruction/test_manager_compatibility_callbacks.ps1','tests/reconstruction/test_release_notes.ps1','Research/Compositor/test_prototype.py','Common/build-private-channel.ps1')
 foreach($path in @($relative|ForEach-Object {'Beta/'+$_})+$required){
  $target=Join-Path $fixture $path;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
  [IO.File]::WriteAllText($target,'BUILD INPUT FIXTURE ONLY: '+$path)
 }
 [void][IO.Directory]::CreateDirectory((Join-Path $beta 'optiscaler/OptiScaler/library'))
 [IO.File]::WriteAllText((Join-Path $beta 'package-inputs.json'),' {"Groups":{}} ')
 $inventory=@(@($relative|ForEach-Object {'Beta/'+$_})+'Beta/package-inputs.json'+$required|ForEach-Object {[pscustomobject]@{Path=$_}})
 $inventoryPath=Join-Path $fixture 'R10-SOURCE-MANIFEST.json'
 $inventory|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $inventoryPath -Encoding utf8
 $source=GetOptiShadeSourceIdentity $beta;$build=GetOptiShadeBuildInputIdentity $beta
 Assert (@(GetOptiShadeRepositoryBuildPaths $beta).Count -eq $required.Count) 'Mandatory archive fixtures were not included'
 Copy-Item -LiteralPath $fixture -Destination $copy -Recurse
 Assert ((GetOptiShadeBuildInputIdentity (Join-Path $copy 'Beta')) -eq $build) 'Build-input identity depends on checkout location'
 # Archive inventories may retain incidental Python bytecode. Executing a
 # required fixture must not turn a cache file into candidate source evidence.
 $cached='Beta/reconstruction/__pycache__/fixture.cpython-312.pyc'
 @($inventory)+@([pscustomobject]@{Path=$cached})|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $inventoryPath -Encoding utf8
 Assert ((GetOptiShadeSourceIdentity $beta) -eq $source -and (GetOptiShadeBuildInputIdentity $beta) -eq $build) 'An interpreter cache was included as a build source'
 $inventory|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $inventoryPath -Encoding utf8
 $changed=Join-Path $fixture $required[2]
 [IO.File]::AppendAllText($changed,' changed fixture')
 Assert ((GetOptiShadeSourceIdentity $beta) -eq $source) 'Sibling fixture incorrectly changed Beta-only source identity'
 Assert ((GetOptiShadeBuildInputIdentity $beta) -ne $build) 'Mandatory fixture edit did not invalidate candidate identity'
 Remove-Item -LiteralPath $changed
 $failure='';try{$null=GetOptiShadeBuildInputIdentity $beta}catch{$failure=$_.Exception.Message}
 Assert ($failure.Contains('Required repository build input is missing')) 'Missing staged fixture did not fail explicitly'
 [IO.File]::WriteAllText($changed,'restored fixture')
 @($inventory|Where-Object Path -ne $required[2])|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $inventoryPath -Encoding utf8
 $failure='';try{$null=GetOptiShadeRepositoryBuildPaths $beta}catch{$failure=$_.Exception.Message}
 Assert ($failure.Contains('absent from the inventory')) 'Omitted mandatory fixture was silently ignored'
 @($inventory)+@([pscustomobject]@{Path='tests/reconstruction/../../escape'})|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $inventoryPath -Encoding utf8
 $failure='';try{$null=GetOptiShadeRepositoryBuildPaths $beta}catch{$failure=$_.Exception.Message}
 Assert ($failure.Contains('escapes its root')) 'Escaping build inventory path was accepted'
 Write-Output "PASS: $checks archive build-input, missing dependency and identity invalidation checks (fixture bytes, no product build)."
}finally{
 foreach($path in @($fixture,$copy)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}}
}
