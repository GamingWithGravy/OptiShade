param(
    [Parameter(Mandatory=$true)][string]$UpstreamSourceRoot,
    [Parameter(Mandatory=$true)][string]$TestDirectory,
    [string]$UpstreamSourceArchive
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=Split-Path $PSScriptRoot -Parent
$component=Join-Path $repo 'installer/OptionalMFG'
if(Test-Path -LiteralPath $TestDirectory) { throw 'Use a fresh fixture directory.' }
$fixture=[IO.Path]::GetFullPath($TestDirectory)
$native=Join-Path $fixture 'source/native'
New-Item -ItemType Directory -Path $native -Force | Out-Null
$pins=@{
    'single_hotkey.h'='0689775DC296CE19E6654B135C56E2791D60AD93F5BD6C0214FE8152961B64D0'
    'overlay_platform.cpp'='5F4264C2C837DE6A0826B24F956AAB456365D465F4099807EA7C269BD0AEEADA'
}
foreach($name in $pins.Keys) {
    $original=Join-Path $UpstreamSourceRoot ('source/native/'+$name)
    if((Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash -cne $pins[$name]) { throw "Unexpected upstream source: $name" }
    Copy-Item -LiteralPath $original -Destination (Join-Path $native $name)
}
$patch=Join-Path $component 'controls-only.patch'
& git -C $fixture -c core.autocrlf=false apply --check -- $patch
if($LASTEXITCODE -ne 0) { throw 'Controls-only patch check failed.' }
& git -C $fixture -c core.autocrlf=false apply -- $patch
if($LASTEXITCODE -ne 0) { throw 'Controls-only patch application failed.' }
$platform=[IO.File]::ReadAllText((Join-Path $native 'overlay_platform.cpp')).Replace("`r`n","`n")
function Get-FunctionSource([string]$Signature) {
    $start=$platform.IndexOf($Signature+"`n{",[StringComparison]::Ordinal)
    if($start -lt 0) { throw "Missing function: $Signature" }
    $opening=$platform.IndexOf('{',$start)
    $depth=1; $end=$opening+1
    # These pinned function bodies have no unmatched braces in strings/comments.
    while($depth -gt 0 -and $end -lt $platform.Length) {
        if($platform[$end] -eq '{') { $depth++ }
        if($platform[$end] -eq '}') { $depth-- }
        $end++
    }
    if($depth -ne 0) { throw 'Unbalanced upstream function.' }
    return $platform.Substring($start,$end-$start)
}
$extracted='namespace single_overlay {'+"`n"+
    'struct PlatformState { bool Initialize(HWND); bool WantsFrame() const noexcept; };'+"`n"
foreach($signature in @('bool CaptureInput() noexcept','bool ProcessKey(HWND window, int key, bool down)',
    'bool AttachWindow(HWND window)','bool PlatformState::Initialize(HWND hwnd)','bool PlatformState::WantsFrame() const noexcept')) {
    $extracted+=(Get-FunctionSource $signature)+"`n"
}
$extracted+="}`n"
[IO.File]::WriteAllText((Join-Path $fixture 'patched-input-functions.h'),$extracted,[Text.UTF8Encoding]::new($false))
$test=@'
#include <cassert>
#include <cstdio>
#include "source/native/single_hotkey.h"
#if !MFG_UNLOCK_OVERLAY_MENU_DRAW
#include "patched-input-functions.h"
#endif
int main() {
    using namespace single_overlay;
    MenuHotkey key;
#if MFG_UNLOCK_OVERLAY_MENU_DRAW
    // Positive control: the same patched file retains upstream behavior in UI builds.
    assert(key.Key()==VK_BACK);
    assert(key.Process(VK_BACK,true)==KeyAction::Toggle);
    assert(key.Process(VK_BACK,true)==KeyAction::None);
    assert(key.Process(VK_BACK,false)==KeyAction::None);
    key.BeginBinding();
    assert(key.Process('K',true)==KeyAction::Bound);
    assert(key.Key()=='K');
    puts("PASS: upstream-menu positive control");
#else
    static_assert(kDefaultMenuKey==0,"No replacement key is allowed");
    assert(key.Key()==0 && !key.Binding());
    // Includes Backspace, Escape, game/menu keys, modifiers and invalid values.
    // Load models every persisted ToggleKey value: none can reactivate binding.
    for(int vk=-1;vk<=256;++vk) {
        assert(!MenuHotkey::Bindable(vk));
        assert(!key.Load(vk));
        key.BeginBinding();
        assert(!key.Binding() && key.Key()==0);
        for(int repeat=0;repeat<3;++repeat) {
            assert(key.Process(vk,true)==KeyAction::None);
            assert(!ProcessKey(nullptr,vk,true));
        }
        assert(key.Process(vk,false)==KeyAction::None);
        assert(!ProcessKey(nullptr,vk,false));
        assert(key.TakePendingSave()==0);
        key.ResetPressed(); key.CancelBinding();
    }
    assert(!CaptureInput());
    assert(!AttachWindow(nullptr));
    PlatformState platform;
    assert(!platform.Initialize(nullptr));
    assert(!platform.WantsFrame());
    puts("PASS: patched MenuHotkey rejects all bindings; actual input/lifecycle functions never consume keys, attach input or open UI");
#endif
}
'@
[IO.File]::WriteAllText((Join-Path $fixture 'controls-only.cpp'),$test,[Text.UTF8Encoding]::new($false))
$cmd=@"
@echo off
call "$repo\build-env.cmd" >nul
if errorlevel 1 exit /b 1
cd /d "$fixture"
cl /nologo /std:c++17 /EHsc /W4 /DMFG_UNLOCK_OVERLAY_MENU_DRAW=0 controls-only.cpp /Fe:no-menu.exe /Fo:no-menu.obj
if errorlevel 1 exit /b 1
no-menu.exe
if errorlevel 1 exit /b 1
cl /nologo /std:c++17 /EHsc /W4 /DMFG_UNLOCK_OVERLAY_MENU_DRAW=1 controls-only.cpp /Fe:upstream-menu.exe /Fo:upstream-menu.obj
if errorlevel 1 exit /b 1
upstream-menu.exe
"@
$buildScript=Join-Path $fixture 'build-test.cmd'
[IO.File]::WriteAllText($buildScript,$cmd,[Text.UTF8Encoding]::new($false))
& $env:ComSpec /d /c $buildScript
if($LASTEXITCODE -ne 0) { throw 'Native controls-only regression failed.' }

function Expect-Blocked([scriptblock]$Operation,[string]$Reason) {
    $blocked=$false
    try { & $Operation | Out-Null } catch { $blocked=$true }
    if(!$blocked) { throw "Unsafe success: $Reason" }
    Write-Output "PASS: $Reason"
}
$fakeComponent=Join-Path $fixture 'component'
New-Item -ItemType Directory -Path $fakeComponent | Out-Null
[IO.File]::WriteAllText((Join-Path $fakeComponent 'RTXMFG.dll'),'synthetic verification fixture')
Expect-Blocked { & (Join-Path $component 'verify-controls-only.ps1') -ComponentDirectory $fakeComponent } 'missing approval receipt blocks packaging'
$receipt=[ordered]@{
    Schema=1; UpstreamCommit='53e3311157140df7b72a6cf0c76fb4e93c44fc04'
    SourceArchiveSha256='8F7C530CEE0D733C8A7E26FD2F808DBFA5ED68DA7C47952D7F9F5BBCADB047B6'
    PatchSha256=(Get-FileHash -LiteralPath $patch -Algorithm SHA256).Hash
    DllSha256=(Get-FileHash -LiteralPath (Join-Path $fakeComponent 'RTXMFG.dll') -Algorithm SHA256).Hash
    MenuDraw=$false; RuntimeGpuSelection=$true; EmbeddedKernelValidation=$true
    InputIsolationVerified=$false; BackendRegressionVerified=$false
}
$receipt | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fakeComponent 'controls-only-approved.json') -Encoding UTF8
Expect-Blocked { & (Join-Path $component 'verify-controls-only.ps1') -ComponentDirectory $fakeComponent } 'compile-only candidate cannot be packaged'
$receipt.InputIsolationVerified=$true; $receipt.BackendRegressionVerified=$true; $receipt.MenuDraw=$true
$receipt | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fakeComponent 'controls-only-approved.json') -Encoding UTF8
Expect-Blocked { & (Join-Path $component 'verify-controls-only.ps1') -ComponentDirectory $fakeComponent } 'menu-enabled candidate cannot be packaged'
$receipt.MenuDraw=$false
$receipt | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fakeComponent 'controls-only-approved.json') -Encoding UTF8
& (Join-Path $component 'verify-controls-only.ps1') -ComponentDirectory $fakeComponent | Out-Null
Write-Output 'PASS: synthetic fully reviewed matching receipt follows expected acceptance path (not a DLL certification)'
[IO.File]::AppendAllText((Join-Path $fakeComponent 'RTXMFG.dll'),'changed')
Expect-Blocked { & (Join-Path $component 'verify-controls-only.ps1') -ComponentDirectory $fakeComponent } 'changed candidate DLL is rejected'
Copy-Item -LiteralPath (Join-Path $component 'RTXMFG.dll') -Destination (Join-Path $fakeComponent 'RTXMFG.dll') -Force
$receipt.DllSha256=(Get-FileHash -LiteralPath (Join-Path $fakeComponent 'RTXMFG.dll') -Algorithm SHA256).Hash
$receipt | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fakeComponent 'controls-only-approved.json') -Encoding UTF8
Expect-Blocked { & (Join-Path $component 'verify-controls-only.ps1') -ComponentDirectory $fakeComponent } 'unchanged upstream Backspace DLL is rejected even with an alleged approval receipt'
if($UpstreamSourceArchive) {
    $blocked=$false
    $candidate=Join-Path $fixture 'must-not-be-created'
    try {
        & (Join-Path $component 'build-controls-only.ps1') -SourceArchive $UpstreamSourceArchive `
            -NativeCacheRoot (Join-Path $fixture 'missing-native-cache') -StreamlineRoot $fixture `
            -ImGuiRoot $fixture -VulkanIncludeDirectory $fixture -CMakeExecutable $fixture `
            -VisualStudioInstance $fixture -CandidateDirectory $candidate | Out-Null
    } catch { $blocked=$_.Exception.Message -like '*missing original upstream input*' }
    if(!$blocked -or (Test-Path -LiteralPath $candidate)) { throw 'Missing original kernel inputs did not stop the builder before output creation.' }
    Write-Output 'PASS: original-input preflight blocks the actual builder before any output or package is created'
}
Write-Output 'PASS: native source and packaging-receipt fixtures. Full rebuilt-DLL input isolation remains untested until original build inputs are available.'
