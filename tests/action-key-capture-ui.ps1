$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,System.Windows.Forms
. "$PSScriptRoot/../installer/ownership.ps1"
. "$PSScriptRoot/../installer/menu-settings.ps1"
$fixture=Join-Path $env:TEMP ('OptiShade-action-keys-ui-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$ini=Join-Path $fixture 'OptiScaler.ini'
$initial=@'
; Existing preferences must survive shortcut edits.
[Menu]
ShortcutKey=45
BackupShortcutKey=79
PresetHotSwapKey=120
SnapshotKey=0
FpsShortcutKey=33
FpsCycleShortcutKey=34
FGShortcutKey=35
UnrelatedMenuValue=keep exactly
[DlssNr]
ToggleKey=119
UnrelatedNrValue=preserve
[Other]
UnrelatedValue=still present
'@
[IO.File]::WriteAllText($ini,$initial,[Text.UTF8Encoding]::new($false))
function AssertClosed([string]$Game) {
    if([IO.Path]::GetFullPath($Game) -ne [IO.Path]::GetFullPath($fixture)) { throw 'Fixture attempted to change another installation.' }
}
function RunAction([scriptblock]$Action) { & $Action }
[xml]$xaml=Get-Content "$PSScriptRoot/../installer/manager.xaml" -Raw -Encoding UTF8
$form=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xaml))
$path=$form.FindName('GamePath');$status=$form.FindName('Status')
$path.Text=$fixture
$source=[IO.File]::ReadAllText("$PSScriptRoot/../installer/manager.ps1")
$start=$source.IndexOf('function CancelSnapshotCapture ',[StringComparison]::Ordinal)
$end=$source.IndexOf('$path.Add_TextChanged({RefreshMenuKeys})',$start,[StringComparison]::Ordinal)
if($start -lt 0 -or $end -lt 0) { throw 'Could not find the actual manager keybind functions and event subscriptions.' }
# Executes the actual manager's keybind functions and event registrations only.
# Startup, simulator detection, network and install callbacks are not loaded.
Invoke-Expression $source.Substring($start,$end-$start)
RefreshMenuKeys
$parameters=[Windows.Interop.HwndSourceParameters]::new('OptiShade hidden key event fixture')
$parameters.Width=1;$parameters.Height=1;$parameters.PositionX=-32000;$parameters.PositionY=-32000
$parameters.WindowStyle=0
$eventSource=[Windows.Interop.HwndSource]::new($parameters)
function Click([string]$Name) {
    $form.FindName($Name).RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
}
function KeyEvent([int]$Code,[bool]$Up=$false) {
    $key=[Windows.Input.KeyInterop]::KeyFromVirtualKey($Code)
    $event=[Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice,$eventSource,0,$key)
    $event.RoutedEvent=if($Up){[Windows.Input.Keyboard]::PreviewKeyUpEvent}else{[Windows.Input.Keyboard]::PreviewKeyDownEvent}
    $form.RaiseEvent($event)
    return $event
}
function AssertUnrelated {
    $text=[IO.File]::ReadAllText($ini)
    foreach($line in @('; Existing preferences must survive shortcut edits.','ShortcutKey=45','BackupShortcutKey=79',
        'FpsShortcutKey=33','FpsCycleShortcutKey=34','FGShortcutKey=35','UnrelatedMenuValue=keep exactly',
        'ToggleKey=119','UnrelatedNrValue=preserve','UnrelatedValue=still present')) {
        if(!$text.Contains($line)) { throw "Shortcut save lost unrelated setting: $line" }
    }
}
function AssertNotSaved([string]$Before) {
    if((HashFile $ini) -cne $Before) { throw 'Capture or validation changed the INI before Save shortcuts.' }
}
try {
    $bytes=[IO.File]::ReadAllBytes("$PSScriptRoot/../installer/manager.ps1")
    if($bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191) { throw 'Manager must retain its UTF-8 BOM for Windows PowerShell.' }
    if($form.FindName('KeyCaptureHint').Text -notmatch 'Num Lock') { throw 'Number-pad guidance is missing.' }
    $before=HashFile $ini
    Click 'ChangeSnapshotKey'
    $event=KeyEvent 44 $true
    if(!$event.Handled -or $script:capturingSnapshot -or $script:snapshotCandidate -ne 44 -or
        $form.FindName('SnapshotKey').Text -ne 'Print Screen') { throw 'Print Screen key-up-only did not complete SnapShot capture.' }
    AssertNotSaved $before
    Click 'SaveMenuKeys'
    if((GetMenuSettings $fixture).SnapshotKey -ne 44) { throw 'Print Screen did not save/load.' }
    AssertUnrelated

    Click 'ClearSnapshotKey'
    $before=HashFile $ini
    Click 'ChangeSnapshotKey'
    $down=KeyEvent 44
    if(!$down.Handled -or $script:capturingSnapshot -or $script:snapshotCandidate -ne 44) { throw 'Print Screen key-down did not capture.' }
    $form.FindName('KeyCaptureHint').Text='after the completed capture'
    $repeat=KeyEvent 44
    $up=KeyEvent 44 $true
    if($repeat.Handled -or $up.Handled -or $form.FindName('KeyCaptureHint').Text -ne 'after the completed capture') { throw 'Print Screen repeat/up captured twice.' }
    AssertNotSaved $before

    Click 'ClearSnapshotKey'
    Click 'ChangeHotSwapKey'
    $event=KeyEvent 44 $true
    if(!$event.Handled -or $script:capturingHotSwap -or $script:hotSwapCandidate -ne 44) { throw 'Hotswap does not share Print Screen key-up capture.' }
    AssertNotSaved $before
    Click 'SaveMenuKeys'
    if((GetMenuSettings $fixture).PresetHotSwapKey -ne 44 -or (GetMenuSettings $fixture).SnapshotKey -ne 0) { throw 'Hotswap Print Screen save/load failed.' }
    AssertUnrelated

    # Windows reports NumPad0..9 as VK96..105 with Num Lock on.
    foreach($action in @('Snapshot','HotSwap')) {
        foreach($digit in 0..9) {
            $other=if($action -eq 'Snapshot'){'HotSwap'}else{'Snapshot'}
            Click ('Clear'+$other+'Key')
            $before=HashFile $ini
            Click ('Change'+$action+'Key')
            $event=KeyEvent (96+$digit)
            $candidate=if($action -eq 'Snapshot'){$script:snapshotCandidate}else{$script:hotSwapCandidate}
            if(!$event.Handled -or $candidate -ne (96+$digit) -or $form.FindName($action+'Key').Text -ne ('NumPad'+$digit)) { throw "$action NumPad$digit did not capture with the correct label." }
            AssertNotSaved $before
            Click 'SaveMenuKeys'
            Click 'LoadMenuKeys'
            $settings=GetMenuSettings $fixture
            $stored=if($action -eq 'Snapshot'){$settings.SnapshotKey}else{$settings.PresetHotSwapKey}
            if($stored -ne (96+$digit) -or $form.FindName($action+'Key').Text -ne ('NumPad'+$digit)) { throw "$action NumPad$digit did not round-trip through the real Save/Load callbacks." }
            AssertUnrelated
        }
    }

    # With Num Lock off, NumPad1 arrives as End, and NumPad5 as Clear.
    $before=HashFile $ini
    Click 'ChangeSnapshotKey'
    $event=KeyEvent 35
    if(!$event.Handled -or !$script:capturingSnapshot -or $script:snapshotCandidate -ne 0 -or
       $form.FindName('KeyCaptureHint').Text -notmatch 'FGShortcutKey' -or $form.FindName('KeyCaptureHint').Text -notmatch 'Num Lock') { throw 'End did not explain its default frame-generation conflict.' }
    $event=KeyEvent 12
    if(!$event.Handled -or !$script:capturingSnapshot -or $script:snapshotCandidate -ne 0 -or
       $form.FindName('KeyCaptureHint').Text -notmatch 'Unsupported key') { throw 'Num Lock-off Clear was silently accepted or ignored without guidance.' }
    $event=KeyEvent 119
    if(!$script:capturingSnapshot -or $form.FindName('KeyCaptureHint').Text -notmatch 'DlssNrToggleKey') { throw 'Configured NR conflict was not detected.' }
    $event=KeyEvent 45
    if(!$script:capturingSnapshot -or $form.FindName('KeyCaptureHint').Text -notmatch 'the menu') { throw 'Primary menu conflict was not detected.' }
    $event=KeyEvent 105
    if(!$script:capturingSnapshot -or $form.FindName('KeyCaptureHint').Text -notmatch 'other SnapShot or hotswap') { throw 'Other action conflict was not detected.' }
    $event=KeyEvent 27
    if($script:capturingSnapshot -or $script:snapshotCandidate -ne 0 -or $form.FindName('KeyCaptureHint').Text -notmatch 'Cancelled') { throw 'Escape did not cancel without changing the pending binding.' }
    AssertNotSaved $before

    Click 'ChangeHotSwapKey'
    $event=KeyEvent 96 $true
    if($event.Handled -or !$script:capturingHotSwap -or $script:hotSwapCandidate -ne 105) { throw 'An ordinary key-up incorrectly completed capture.' }
    $event=KeyEvent 8
    if(!$event.Handled -or $script:capturingHotSwap -or $script:hotSwapCandidate -ne 0 -or $form.FindName('HotSwapKey').Text -ne 'Not set') { throw 'Backspace did not clear the pending binding.' }
    AssertNotSaved $before
    Click 'SaveMenuKeys'
    if((GetMenuSettings $fixture).PresetHotSwapKey -ne 0) { throw 'Cleared hotswap binding did not save.' }
    AssertUnrelated
    Write-Output 'PASS: actual WPF capture/event and Save/Load callbacks handle Print Screen up-only/down-up without doubles, both actions round-trip NumPad0-9, conflicts/unsupported keys give guidance, and capture never saves early.'
    Write-Output 'PASS: unrelated INI keys and backup shortcut retained; only isolated fixture settings were changed.'
} finally {
    $eventSource.Dispose()
    $form.Close()
}
