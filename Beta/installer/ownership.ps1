. "$PSScriptRoot/anti-cheat.ps1"
. "$PSScriptRoot/component-policy.ps1"
. "$PSScriptRoot/compatibility.ps1"

. "$PSScriptRoot/json-state.ps1"
. "$PSScriptRoot/executable.ps1"

$ErrorActionPreference='Stop'

function GetBundledOptiShadeVersion { 'P1.0.77' }

# Keep upgraded ReShade installs able to find effects/textures from both the
# current OptiShadeData layout and the standard ReShade layout. ReShade.ini is
# user settings, so merge only these paths and retain every other setting.
# OptiShade's own folder goes first: when a player's reshade-shaders folder has the
# same effect files, OptiShade's presets then use the shaders OptiShade ships and
# tests (OSD-Q58X: every effect loaded twice, the player's copies first).
function EnsureOptiShadeReShadeSearchPaths([string]$Game){
 $ini=OwnedPath $Game 'ReShade.ini';if(-not(Test-Path -LiteralPath $ini -PathType Leaf)){return}
 $text=[IO.File]::ReadAllText($ini);$originalText=$text;$newline=if($text.Contains("`r`n")){"`r`n"}else{"`n"}
 $rows=@(
  @{Key='EffectSearchPaths';Paths=@('.\OptiShadeData\Shaders\**','.\reshade-shaders\Shaders\**')},
  @{Key='TextureSearchPaths';Paths=@('.\OptiShadeData\Textures\**','.\reshade-shaders\Textures\**')}
 )
 foreach($row in $rows){
  $lines=[Collections.Generic.List[string]]::new();foreach($line in ($text -split '\r?\n')){$lines.Add($line)}
  $general=-1;$end=$lines.Count
  for($i=0;$i -lt $lines.Count;$i++){if($lines[$i] -match '^\s*\[GENERAL\]\s*$'){$general=$i;for($j=$i+1;$j -lt $lines.Count;$j++){if($lines[$j] -match '^\s*\[[^\]]+\]\s*$'){$end=$j;break}};break}}
  if($general -lt 0){if($text -and -not $text.EndsWith("`n")){$lines.Add('')};$lines.Add('[GENERAL]');$general=$lines.Count-1;$end=$lines.Count}
  $match=-1;for($i=$general+1;$i -lt $end;$i++){if($lines[$i] -match ('^\s*'+[regex]::Escape($row.Key)+'\s*=')){$match=$i;break}}
  if($match -ge 0){$value=$lines[$match].Substring($lines[$match].IndexOf('=')+1);$paths=@($value -split ','|ForEach-Object {$_.Trim().Trim('"').Replace('/',[string][char]92).TrimEnd([char]92)});foreach($path in $row.Paths){$normal=$path.Replace('/',[string][char]92).TrimEnd([char]92);if($normal -notin $paths){$paths+=,$normal}};$own=$row.Paths[0].Replace('/',[string][char]92).TrimEnd([char]92);$paths=@($own)+@($paths|Where-Object {$_ -and $_ -ne $own});$lines[$match]=$row.Key+'='+($paths -join ',')}
  else{$lines.Insert($end,$row.Key+'='+($row.Paths -join ','))}
  $text=$lines -join $newline
 }
 if($text -ceq $originalText){return}
 $suffix=[guid]::NewGuid().ToString('N');$temp=$ini+'.optishade-search-'+$suffix+'.tmp';$backup=$ini+'.optishade-search-'+$suffix+'.bak'
 try{[IO.File]::WriteAllText($temp,$text,[Text.UTF8Encoding]::new($false));[IO.File]::Replace($temp,$ini,$backup,$true);Remove-Item -LiteralPath $backup -Force}
 catch{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force};throw}
}

# Windows refused the write itself (not a file in use): usually a game under
# Program Files, which only an elevated process may change (DCS World report).
$script:OptiShadeProtectedFolderHelp='Games installed under Program Files are protected by Windows. Close the OptiShade manager, right-click it and choose Run as administrator, then try again.'
function TestOptiShadeAccessDenied($ErrorRecord){
 for($e=$ErrorRecord.Exception;$e;$e=$e.InnerException){if($e -is [UnauthorizedAccessException]){return $true}}
 # Transactions rethrow as text; keep recognising .NET's own wording.
 return [string]$ErrorRecord.Exception.Message -match "Access to the path '.+' is denied"
}
# Crash dumps are on by default (owner direction, 1 Nov 2026: players with
# crashes to desktop never turned them on in the Troubleshooter). After an
# install the manager asks Windows once to save a dump when the game's own EXE
# crashes. Same LocalDumps values and OptiShadeManaged marker as the
# Troubleshooter (CrashDumps.cs), so it can still turn them off; a key made
# outside OptiShade is left alone. Dumps stay on this PC (at most 5, usually
# 50-400 MB each) and are only sent with a report the player chooses to send.
function GetOptiShadeCrashDumpExecutable([string]$Executable){
 $folder=Split-Path $Executable -Parent;$leaf=Split-Path $Executable -Leaf
 # The Xbox launch helper is not the process that crashes.
 if($leaf -ieq 'gamelaunchhelper.exe'){foreach($game in @('FlightSimulator2024.exe','FlightSimulator.exe')){if(Test-Path -LiteralPath (Join-Path $folder $game) -PathType Leaf){return $game}}}
 return $leaf
}
# CustomDumpFlags 6501 = CrashDumps.CustomFlags (0x1|0x4|0x20|0x40|0x100|0x800|0x1000).
# A plain .reg file imported by Windows' own reg.exe: the approval prompt names
# Microsoft's Registry tool and the file can be read. An elevated, hidden,
# -EncodedCommand PowerShell did the same job but is a classic malware pattern
# that antivirus behaviour detection flags (audit, 1 Nov 2026).
function GetOptiShadeCrashDumpRegistryText([string]$Hive,[string]$Executable){
 $folder=(([Text.Encoding]::Unicode.GetBytes('%LOCALAPPDATA%\CrashDumps')+[byte[]](0,0))|ForEach-Object {'{0:x2}' -f $_}) -join ','
 return ("Windows Registry Editor Version 5.00`r`n`r`n["+$Hive+'\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\'+$Executable+"]`r`n"+
  '"DumpFolder"=hex(2):'+$folder+"`r`n"+'"DumpType"=dword:00000000'+"`r`n"+
  '"CustomDumpFlags"=dword:00001965'+"`r`n"+'"DumpCount"=dword:00000005'+"`r`n"+'"OptiShadeManaged"=dword:00000001'+"`r`n")
}
function EnableOptiShadeCrashDumps([string]$Executable){
 $exe=GetOptiShadeCrashDumpExecutable $Executable
 if($exe -notmatch '^[^\\/"'';&|`$\[\]]{1,96}\.exe$'){return 'not changed: no valid game executable'}
 $key='HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\'+$exe
 if(Test-Path -LiteralPath $key){return ('already on for '+$exe)}
 $file=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-crash-dumps-'+[guid]::NewGuid().ToString('N')+'.reg')
 [IO.File]::WriteAllText($file,(GetOptiShadeCrashDumpRegistryText 'HKEY_LOCAL_MACHINE' $exe),[Text.Encoding]::Unicode)
 try{
  # /reg:64 writes the 64-bit view even from a 32-bit host.
  $reg=Join-Path $env:WINDIR 'System32\reg.exe'
  $elevated=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  $arguments=@('import',('"'+$file+'"'),'/reg:64')
  try{$p=if($elevated){Start-Process -FilePath $reg -ArgumentList $arguments -WindowStyle Hidden -PassThru -ErrorAction Stop}else{Start-Process -FilePath $reg -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru -ErrorAction Stop}}
  catch{return ('not changed: the administrator prompt was declined or failed ('+$_.Exception.Message+')')}
  if(-not $p.WaitForExit(60000)){return 'not changed: Windows did not finish in time'}
 }finally{Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue}
 if(Test-Path -LiteralPath $key){return ('on for '+$exe)}
 return ('not changed for '+$exe)
}
# Full uninstall takes back only the keys OptiShade set, with one Windows prompt. A
# key made outside OptiShade has no marker and stays. Saved dumps in
# %LOCALAPPDATA%\CrashDumps are Windows' own folder and are not touched.
function GetOptiShadeCrashDumpRemovalText([string[]]$Executables){
 $text="Windows Registry Editor Version 5.00`r`n"
 foreach($exe in @($Executables)){$text+="`r`n[-HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\"+$exe+"]`r`n"}
 return $text
}
function RemoveOptiShadeCrashDumps([string[]]$Executables){
 $keys=@()
 foreach($executable in @($Executables|Where-Object {$_})){
  $exe=GetOptiShadeCrashDumpExecutable $executable
  if($exe -notmatch '^[^\\/"'';&|`$\[\]]{1,96}\.exe$' -or $exe -in $keys){continue}
  $key='HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\'+$exe
  $value=Get-ItemProperty -LiteralPath $key -Name OptiShadeManaged -ErrorAction SilentlyContinue
  if($value -and $value.OptiShadeManaged -eq 1){$keys+=$exe}
 }
 if(-not $keys.Count){return 'nothing to remove'}
 $file=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-crash-dumps-off-'+[guid]::NewGuid().ToString('N')+'.reg')
 [IO.File]::WriteAllText($file,(GetOptiShadeCrashDumpRemovalText $keys),[Text.Encoding]::Unicode)
 try{
  $reg=Join-Path $env:WINDIR 'System32\reg.exe'
  $elevated=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  $arguments=@('import',('"'+$file+'"'),'/reg:64')
  try{$p=if($elevated){Start-Process -FilePath $reg -ArgumentList $arguments -WindowStyle Hidden -PassThru -ErrorAction Stop}else{Start-Process -FilePath $reg -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru -ErrorAction Stop}}
  catch{return ('kept: the administrator prompt was declined or failed ('+$_.Exception.Message+')')}
  if(-not $p.WaitForExit(60000)){return 'kept: Windows did not finish in time'}
 }finally{Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue}
 return ('removed for '+($keys -join ', '))
}
# Crash dumps on by default after install; a declined prompt never fails it.
function EnsureOptiShadeCrashDumps([string]$Executable){
 # Say what the Windows prompt is for before it appears (the manager's status line).
 $line=Get-Variable -Name status -ValueOnly -ErrorAction SilentlyContinue
 if($line -and $line.PSObject.Properties['Text']){$previous=$line.Text;$line.Text='Windows will ask once to let OptiShade save a crash dump if this game crashes (Registry Editor). Dumps stay on this PC unless you send a report. Saying No is fine.'
  # Paint it now: the prompt below blocks this thread.
  try{$line.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render)}catch{}}
 try{WriteInstallerLog ('Crash dumps: '+(EnableOptiShadeCrashDumps $Executable))}catch{WriteInstallerLog ('Crash dumps: not changed ('+$_.Exception.Message+')')}
 if($line -and $line.PSObject.Properties['Text']){$line.Text=$previous}
}
function GetOptiShadeFriendlyError($ErrorRecord){
 $message=$ErrorRecord.Exception.Message
 if((TestOptiShadeAccessDenied $ErrorRecord) -and $message -notlike "*$script:OptiShadeProtectedFolderHelp*"){return ($message.TrimEnd()+' '+$script:OptiShadeProtectedFolderHelp)}
 return $message
}

function TestOptiShadePrivateBuildUpdate($Manifest,[string]$BundledIdentityPath=(Join-Path $PSScriptRoot 'PayloadFusion/OptiShadeData/BuildIdentity.json')){
 if(-not $Manifest.Game -or -not(Test-Path -LiteralPath $BundledIdentityPath -PathType Leaf)){return $false}
 $relative='OptiShadeData/BuildIdentity.json'
 $owned=@($Manifest.Files|Where-Object {$_.Path.Replace('\','/') -ieq $relative})
 if($owned.Count -ne 1){return $false}
 $installedPath=OwnedPath $Manifest.Game $relative
 if((HashFile $installedPath) -ine [string]$owned[0].Hash){throw 'The installed build identity does not match its receipt. Repair this installation before updating.'}
 $installed=ReadOptiShadeJson $installedPath 'Installed build identity' -MaxBytes 65536
 $bundled=ReadOptiShadeJson $BundledIdentityPath 'Bundled build identity' -MaxBytes 65536
 if($installed.Channel -cne $bundled.Channel -or $installed.Version -cne $bundled.Version){return $false}
 if(-not $installed.PrivateTesting -or -not $bundled.PrivateTesting){return $false}
 $old=0;$next=0
 if(-not [int]::TryParse([string]$installed.PrivateTestNumber,[ref]$old) -or -not [int]::TryParse([string]$bundled.PrivateTestNumber,[ref]$next)){return $false}
 return $old -gt 0 -and $next -gt $old
}
function TestBundledUpdateVersion($Manifest){

 try{

  $parse={param($text)

   if($text -notmatch '^P?(\d+\.\d+(?:\.\d+){0,2})(?:-(alpha|beta|rc)(?:[.-]?(\d+))?)?(?:-MSFS24)?$'){return $null}

   $rank=if($Matches[2]){@{alpha=0;beta=1;rc=2}[$Matches[2]]}else{3}

   $revision=if($Matches[3]){[int]$Matches[3]}else{0}

   [pscustomobject]@{Core=[version]$Matches[1];Rank=$rank;Revision=$revision}

  }

  $installed=&$parse ([string]$Manifest.Version);$bundled=&$parse (GetBundledOptiShadeVersion)

  if(-not $installed -or -not $bundled){return $false}

  if($bundled.Core -ne $installed.Core){return $bundled.Core -gt $installed.Core}

  if($bundled.Rank -ne $installed.Rank){return $bundled.Rank -gt $installed.Rank}

  if($bundled.Revision -ne $installed.Revision){return $bundled.Revision -gt $installed.Revision}
  return TestOptiShadePrivateBuildUpdate $Manifest

 }catch{return $false}

}

function GetOptiShadeChannelChangeLabel([string]$InstalledVersion,[string]$BundledVersion,[string]$BundledIdentityPath=(Join-Path $PSScriptRoot 'PayloadFusion/OptiShadeData/BuildIdentity.json')){
    $fromPreview=([string]$InstalledVersion) -match '-(?:alpha|beta|rc)'
    $toPreview=([string]$BundledVersion) -match '-(?:alpha|beta|rc)'
    if($fromPreview -eq $toPreview){return ''}
    if(-not $toPreview){return 'Switch to stable'}
    if(Test-Path -LiteralPath $BundledIdentityPath -PathType Leaf){
        try{$identity=Get-Content -LiteralPath $BundledIdentityPath -Raw -Encoding UTF8|ConvertFrom-Json;if($identity.PrivateTesting -eq $true){return 'Install private test build'}}catch{}
    }
    return 'Switch to beta'
}

function AssertRepairVersion($Manifest){

    $bundled=GetBundledOptiShadeVersion

    if(-not $Manifest.Version -or $Manifest.Version -cne $bundled){

        $next=if(TestBundledUpdateVersion $Manifest){'Choose Update OptiShade in Setup to review and apply this newer build while keeping presets, settings and original backups.'}else{'Use the manager matching the installed version, or the separate update/return-to-stable workflow to change builds.'}

        throw "Repair requires the installer matching the installed version ($($Manifest.Version)). This installer contains $bundled. Repair will not update or downgrade OptiShade. $next"

    }

}

function GetOptiShadeRepairAction($Manifest){

    if($Manifest.Status -notin @('Installed','Installing')){throw 'No repairable installation record. Restore the recorded installation first, then install again.'}

    $bundled=GetBundledOptiShadeVersion

    if($Manifest.Version -ceq $bundled){return 'Repair OptiShade'}

    $pattern='^P?\d+\.\d+(?:\.\d+){0,2}(?:-(?:alpha|beta|rc)(?:[.-]?\d+)?)?(?:-MSFS24)?$'

    if(([string]$Manifest.Version) -notmatch $pattern -or $bundled -notmatch $pattern){AssertRepairVersion $Manifest}

    $channelAction=GetOptiShadeChannelChangeLabel ([string]$Manifest.Version) $bundled
    if($channelAction){return $channelAction}

    if(TestBundledUpdateVersion $Manifest){return 'Update OptiShade'}

    # Same-channel downgrades and unrecognised versions remain explicit errors.

    AssertRepairVersion $Manifest

}

function FullPath([string]$Path){

    if([string]::IsNullOrWhiteSpace($Path)){throw 'Path is empty.'}

    $value=[string]$Path

    # Windows PowerShell 5.1 can reject an already-absolute path before the

    # extended-length IO wrapper below gets a chance to add \\?\.

    # Long paths must already be canonical: reject dot traversal instead of

    # asking legacy System.IO to normalise it.

    if($value.Length -ge 248){

        if($value.StartsWith('\\?\UNC\',[StringComparison]::OrdinalIgnoreCase)){$value='\\'+$value.Substring(8)}

        elseif($value.StartsWith('\\?\',[StringComparison]::OrdinalIgnoreCase)){$value=$value.Substring(4)}

        $value=$value.Replace('/','\')

        if($value -notmatch '^(?:[A-Za-z]:\\|\\\\)'){throw 'Long paths must be fully qualified.'}

        if(@($value -split '\\'|Where-Object {$_ -eq '.' -or $_ -eq '..'}).Count){throw 'Long paths containing dot traversal are not supported.'}

        return $value.TrimEnd('\','/')

    }

    [IO.Path]::GetFullPath($value).TrimEnd('\','/')

}

function OptiShadeIoPath([string]$Path){

    # Extended-length IO paths are local transport, not ownership identities.

    if($Path.StartsWith('\\?\') -or $Path.Length -lt 248){return $Path}

    if($Path.StartsWith('\\')){return '\\?\UNC\'+$Path.Substring(2)}

    if($Path -match '^[A-Za-z]:\\'){return '\\?\'+$Path}

    return $Path

}

function HashFile([string]$Path){$io=OptiShadeIoPath $Path;if(Test-Path -LiteralPath $io -PathType Leaf){(Get-FileHash -LiteralPath $io -Algorithm SHA256).Hash}else{''}}

function TestOptiShadePresetIniPath([string]$Path){return $Path -match '^OptiShadeData[\\/]+Presets[\\/]+.*\.ini$'}

function GetDefenderFileEvidence([string]$Path){

    # Read only a bounded recent event window, and return evidence for this exact

    # file. Detection/action events are not proof that quarantine succeeded.

    try{

        $wanted=FullPath $Path

        $events=@(Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Windows Defender/Operational';Id=1116,1117;StartTime=(Get-Date).AddDays(-2)} -MaxEvents 128 -ErrorAction Stop)

        foreach($event in $events){

            [xml]$xml=$event.ToXml();$fields=@{}

            foreach($data in $xml.Event.EventData.Data){$fields[[string]$data.Name]=[string]$data.'#text'}

            $matched=$false

            foreach($resource in ([string]$fields['Path'] -split ';')){

                $candidate=$resource.Trim() -replace '^(?i:file:|containerfile:)',''

                if($candidate -notmatch '^(?:[A-Za-z]:[\\/]|\\\\)'){continue}

                if([string]::Equals((FullPath $candidate),$wanted,[StringComparison]::OrdinalIgnoreCase)){$matched=$true;break}

            }

            if(-not $matched){continue}

            $threat=([string]$fields['Threat Name'] -replace '[\r\n\x00-\x1f]',' ').Trim()

            # A detection label should not contain a filesystem path. Avoid

            # echoing unrelated private paths from an unusual/malformed record.

            if($threat -match '[A-Za-z]:[\\/]|\\\\'){$threat='unnamed detection'}

            if(-not $threat){$threat='unnamed detection'}

            if($threat.Length -gt 160){$threat=$threat.Substring(0,160)}

            return " Windows Defender recorded $threat for this exact file within the last 48 hours. Open Windows Security > Protection history to check the action taken."

        }

    }catch{ }

    return ' Check antivirus protection history for this file; no matching recent Defender event was available to confirm the cause.'

}

function OwnedPath([string]$Root,[string]$Relative){

    $base=FullPath $Root;$path=FullPath (Join-Path $base $Relative)

    if(-not $path.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Path is outside the installation folder.'}

    $check=$path

    while($check){if(Test-Path -LiteralPath (OptiShadeIoPath $check)){if((Get-Item -LiteralPath (OptiShadeIoPath $check) -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Linked folders are not supported: $check"}};$parent=Split-Path $check -Parent;if($parent -eq $check){break};$check=$parent}

    $path

}

# The launcher EXE can be kept inside the game folder. It holds no game files, and it
# is what runs the repair, so counting it blocked the repair for good: "still running
# in the background" however long the player waited (owner report, R350). A renamed
# EXE is recognised as this manager's own parent chain.
function TestOptiShadeLauncherImageName([string]$Name){return $Name -match '^OptiShade[ ._]Version[ ._][0-9][0-9.]*([ ._]R[0-9]+)?\.exe$'}
function GetOptiShadeLauncherProcessIds {
 $ids=@($PID);$current=$PID
 for($depth=0;$depth -lt 8;$depth++){
  $row=Get-CimInstance Win32_Process -Filter ("ProcessId="+$current) -ErrorAction SilentlyContinue
  if(-not $row -or -not $row.ParentProcessId -or $row.ParentProcessId -in $ids){break}
  $ids+=[int]$row.ParentProcessId;$current=[int]$row.ParentProcessId
 }
 return $ids
}
function AssertClosed([string]$Game){

    # Subfolders too: the OptiMFG tray controller runs from OptiShadeData\OptiMFG\Runtime
    # and holds its runtime DLLs, which made a Core update fail partway through.
    # Check by process name before reading executable paths: Windows may deny
    # Process.Path for an elevated controller when the manager is not elevated.
    if(@(Get-Process -Name @('OptiMFG_Live','OptiMFG_LiveCtl','OptiMFG_Controller') -ErrorAction SilentlyContinue).Count){throw 'Exit OptiMFG from the system tray first, then retry. No files have been changed.'}
    $root=FullPath $Game;$launcherIds=$null
    foreach($p in Get-Process){try{if($p.Path){$folder=FullPath (Split-Path $p.Path -Parent)
        if($folder -eq $root -or $folder.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){
            if(TestOptiShadeLauncherImageName (Split-Path $p.Path -Leaf)){continue}
            if($null -eq $launcherIds){$launcherIds=@(GetOptiShadeLauncherProcessIds)}
            if($p.Id -in $launcherIds){continue}
            if($p.ProcessName -in 'OptiMFG_Live','PresentMon'){throw 'Exit OptiMFG from the system tray first, then retry. No files have been changed.'}
            # OSD-3A5R: six retries in 14 minutes against an MSFS that had closed its
            # window but was still shutting down in the background.
            if($p.MainWindowHandle -eq [IntPtr]::Zero){throw "$($p.ProcessName) is still running in the background with no window: it may still be closing. Wait a moment, or end it in Task Manager, then retry. No files have been changed."}
            throw "Close $($p.ProcessName) first."}}}catch [System.ComponentModel.Win32Exception]{}}

    if(Get-Process FlightSimulator2024,FlightSimulator -ErrorAction SilentlyContinue){throw 'Close MSFS before changing installed files.'}

}

function GetOptiShadeMutationStore([string]$ManifestPath){
 $receipt=FullPath $ManifestPath;$normal=$receipt.Replace('\','/')
 if($normal -match '^(.*)/Games/[a-fA-F0-9]{16}/manifest\.json$'){return FullPath $Matches[1]}
 # Canonical managed stores have one owner across every game and cleanup.
 # A malformed or archived managed path must not create an unrelated lock.
 if($normal -match '/Games/' -or $normal -match '/(?:MfgRollback|AddonBackups|TransactionBackups)/' -or [IO.Path]::GetFileName($receipt) -cne 'manifest.json'){throw 'The mutation needs a canonical game receipt or an explicit standalone manifest.json owner.'}
 # Standalone receipts own their containing directory. This is the existing
 # direct-receipt import/repair format, not a guessed managed-store fallback.
 return FullPath (Split-Path $receipt)
}
function InitializeOptiShadeMutationContext {
 if(-not ('OptiShadeMutationContext' -as [type])){
  try{Add-Type -TypeDefinition 'public static class OptiShadeMutationContext { [System.ThreadStatic] public static System.Collections.Generic.List<string> CallbackStores; }' -ErrorAction Stop}
  catch{if(-not ('OptiShadeMutationContext' -as [type])){throw}}
 }
}
function InvokeOptiShadeMutationProgress([string]$ManifestPath,[scriptblock]$Progress,[string]$Text,[int]$Completed=0,[int]$Total=0){
 # Progress can pump the UI dispatcher while a provider transaction owns its
 # rollback snapshot. A new same-store mutation inside that callback cannot be
 # safely nested; ordinary production calls outside the callback stay reentrant.
 InitializeOptiShadeMutationContext
 $owner=(GetOptiShadeMutationStore $ManifestPath).Replace('\','/').ToLowerInvariant()
 $active=[OptiShadeMutationContext]::CallbackStores
 if($null -eq $active){$active=[Collections.Generic.List[string]]::new();[OptiShadeMutationContext]::CallbackStores=$active}
 $active.Add($owner)
 try{& $Progress $Text $Completed $Total}finally{$active.RemoveAt($active.Count-1);if(-not $active.Count){[OptiShadeMutationContext]::CallbackStores=$null}}
}
function EnterOptiShadeMutation {
 [CmdletBinding(DefaultParameterSetName='Receipt')]
 param([Parameter(Mandatory=$true,ParameterSetName='Receipt')][string]$ManifestPath,[Parameter(Mandatory=$true,ParameterSetName='Store')][string]$StateRoot)
 $owner=if($PSCmdlet.ParameterSetName -ceq 'Store'){FullPath $StateRoot}else{GetOptiShadeMutationStore $ManifestPath}
 $identity=$owner.Replace('\','/').ToLowerInvariant()
 InitializeOptiShadeMutationContext
 if([OptiShadeMutationContext]::CallbackStores -and [OptiShadeMutationContext]::CallbackStores.Contains($identity)){throw 'OptiShade is reporting progress for an active preparation transaction. Finish that operation before changing this installation store.'}
 $sha=[Security.Cryptography.SHA256]::Create()
 try{$key=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity))).Replace('-','')}finally{$sha.Dispose()}
 $prefix=if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){'Global\OptiShade.StoreMutation.'}else{'OptiShade.StoreMutation.'}
 $mutex=[Threading.Mutex]::new($false,($prefix+$key));$acquired=$false
 try{
  try{$acquired=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$acquired=$true}
  if(-not $acquired){throw 'Another OptiShade operation is changing this installation store. Wait for that operation to finish, then retry.'}
  # The OS releases a terminated owner. Existing route recovery still runs
  # before mutation; abandonment never bypasses receipt or hash validation.
  return $mutex
 }catch{$mutex.Dispose();throw}
}
function ExitOptiShadeMutation($Mutation){
 if($null -eq $Mutation){return}
 try{$Mutation.ReleaseMutex()}finally{$Mutation.Dispose()}
}

function ManifestPath([string]$StateRoot,[string]$Game){

    $bytes=[Text.Encoding]::UTF8.GetBytes((FullPath $Game).ToLowerInvariant());$sha=[Security.Cryptography.SHA256]::Create();$id=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').Substring(0,16);$sha.Dispose()

    OwnedPath $StateRoot ('Games/'+$id+'/manifest.json')

}

# Regenerated ReShade cache files never belong in a receipt. Repairs recorded every
# one (OSD-9BB5: 10,944 entries, 5.3 MB), and past the size limit the receipt could
# not be read again, which locked the game out of repair. Uninstall already clears
# all of OptiShadeData, so these entries are not needed to remove the files.
function TestOptiShadeRegeneratedData([string]$Relative){return $Relative -match '^OptiShadeData[\\/]Cache[\\/]' -and $Relative -notmatch '[\\/]\.keep$'}
function ReadOptiShadeState([string]$Path){

 $bytes=0
 $lastReadError='Unknown read failure'
 $driveUnavailable=$false

 for($attempt=0;$attempt -lt 5;$attempt++){

  try{

   $bytes=0
   $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop;$bytes=$item.Length

   if($item.PSIsContainer -or $bytes -gt 16MB -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Invalid receipt size or linked file'}

   $text=[IO.File]::ReadAllText($item.FullName,[Text.Encoding]::UTF8)

   $value=$text|ConvertFrom-Json -ErrorAction Stop

   if($null -eq $value -or $value -is [array] -or $value -isnot [pscustomobject] -or -not $value.Game -or -not $value.Status -or -not [IO.Path]::IsPathRooted([string]$value.Game)){throw 'Invalid ownership receipt schema'}

   # Older repairs stored cache files; the next save writes the smaller receipt.
   if($value.Files -and @($value.Files).Count -gt 2000){$value.Files=@(@($value.Files)|Where-Object {$_.Hash -or -not(TestOptiShadeRegeneratedData ([string]$_.Path))})}

   return $value

  }catch{
   $lastReadError=$_.Exception.GetType().Name
   if($_.Exception -is [System.Management.Automation.DriveNotFoundException]){$driveUnavailable=$true;break}
   if($_.CategoryInfo -and $_.CategoryInfo.Category){$lastReadError+=' ('+[string]$_.CategoryInfo.Category+')'}
   if($_.Exception.Message -eq 'Invalid ownership receipt schema'){$lastReadError+=': Invalid ownership receipt schema'}
   if($attempt -lt 4){Start-Sleep -Milliseconds ([int](50*[math]::Pow(2,$attempt)))}
  }

 }

 if($driveUnavailable){
  $driveRoot=try{[IO.Path]::GetPathRoot([string]$Path)}catch{''}
  $receiptHint=[string]$Path
  if($env:USERPROFILE){$receiptHint=$receiptHint.Replace($env:USERPROFILE,'<USERPROFILE>')}
  $receiptHint=[regex]::Replace($receiptHint,'[\r\n\t]',' ')
  if($receiptHint.Length -gt 180){$receiptHint=$receiptHint.Substring(0,180)+'...'}
  $location=if($driveRoot){"OptiShade's saved installation data on drive '$driveRoot' (receipt '$receiptHint')"}else{"OptiShade's saved installation data at relative receipt path '$receiptHint'"}
  throw "$location could not be accessed. Reconnect any disconnected drive and try again. No receipt or original backup was changed."
 }

 $digest=try{(Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash}catch{'unavailable'}

 throw "Installation receipt could not be read or validated ($([IO.Path]::GetFileName($Path)), $bytes bytes, SHA256 $digest; last error: $lastReadError). No receipt or original backup was reset. Repair this recorded installation before retrying."

}

function WriteState($Manifest,[string]$Path){

 $tmp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'

 try{

  $json=$Manifest|ConvertTo-Json -Depth 12

  [IO.File]::WriteAllText($tmp,$json,[Text.UTF8Encoding]::new($true))
  $durable=[IO.File]::Open($tmp,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
  try{$durable.Flush($true)}finally{$durable.Dispose()}

  if(Test-Path -LiteralPath $Path){[IO.File]::Replace($tmp,$Path,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($tmp,$Path)}

 }finally{if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force}}

}

function CopyOptiShadeRouteFile([string]$Source,[string]$Destination,[string]$ExpectedHash){
 # A route journal owns exact files, never a directory tree. Replacement is
 # atomic so restart recovery only sees the complete before or after bytes.
 if((HashFile $Source) -cne $ExpectedHash){throw 'Route recovery source failed verification.'}
 [void][IO.Directory]::CreateDirectory((Split-Path $Destination))
 $temporary=$Destination+'.route-'+[guid]::NewGuid().ToString('N')+'.tmp'
 try{
  [IO.File]::Copy($Source,$temporary,$false)
  if((HashFile $temporary) -cne $ExpectedHash){throw 'Route staging copy failed verification.'}
  $stream=[IO.File]::Open($temporary,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
  try{$stream.Flush($true)}finally{$stream.Dispose()}
  if(Test-Path -LiteralPath $Destination){[IO.File]::Replace($temporary,$Destination,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temporary,$Destination)}
 }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
}

function GetOptiShadeRouteRecovery([string]$ManifestPath){
 $folder=Split-Path ([IO.Path]::GetFullPath($ManifestPath));$active=OwnedPath $folder 'MfgRouteTransaction.json'
 if(-not(Test-Path -LiteralPath $active)){return $null}
 $pointer=ReadOptiShadeJson $active 'Active route transaction' -MaxBytes 4096 -Shape Object
 if($pointer.Schema -ne 1 -or [string]$pointer.Journal -cnotmatch '^MfgRollback/[a-f0-9]{32}/route-transaction\.json$' -or [string]$pointer.Hash -cnotmatch '^[A-F0-9]{64}$'){throw 'The pending route transaction identity is invalid. Its recovery files were retained.'}
 $journalPath=OwnedPath $folder ([string]$pointer.Journal)
 if((HashFile $journalPath) -cne [string]$pointer.Hash){throw 'The pending route transaction journal failed verification.'}
 $journal=ReadOptiShadeJson $journalPath 'Route transaction journal' -MaxBytes 1048576 -Shape Object
 if($journal.Schema -ne 1 -or -not [IO.Path]::IsPathRooted([string]$journal.Game) -or @($journal.Files).Count -lt 2 -or @($journal.Files).Count -gt 512){throw 'The pending route transaction schema is invalid.'}
 $rollback=Split-Path $journalPath;$seen=@{};$receiptCount=0
 foreach($entry in @($journal.Files)){
  if($entry.Scope -eq 'Receipt' -and $entry.Path -ceq 'manifest.json'){$target=[IO.Path]::GetFullPath($ManifestPath);$receiptCount++}
  elseif($entry.Scope -eq 'Game'){$target=OwnedPath ([string]$journal.Game) ([string]$entry.Path)}
  else{throw 'The route journal contains an invalid target scope.'}
  if($seen.ContainsKey($target)){throw 'The route journal repeats a target.'};$seen[$target]=$true
  foreach($side in @('Before','After')){
   $hash=[string]$entry.($side+'Hash');$copy=[string]$entry.$side
   if(-not $hash){if($copy){throw 'The route journal contains an unbound recovery copy.'};continue}
   if($hash -cnotmatch '^[A-F0-9]{64}$' -or $copy -cnotmatch '^(?:before-\d+|after-\d+|manifest\.json|manifest\.after\.json|OptiScaler\.ini)$' -or (HashFile (OwnedPath $rollback $copy)) -cne $hash){throw 'A route recovery copy is missing or changed. No recovery targets were overwritten.'}
  }
  $entry|Add-Member Target $target -Force
 }
 if($receiptCount -ne 1){throw 'The route journal does not identify one canonical receipt.'}
 $receipt=@($journal.Files|Where-Object Scope -eq 'Receipt')[0]
 $before=ReadOptiShadeState (OwnedPath $rollback ([string]$receipt.Before))
 if((FullPath ([string]$before.Game)) -ine (FullPath ([string]$journal.Game))){throw 'The route recovery game does not match its original receipt.'}
 return [pscustomobject]@{Active=$active;Directory=$rollback;Journal=$journal}
}

function RecoverOptiShadeRouteTransaction([string]$ManifestPath){
 $storeMutation=EnterOptiShadeMutation -ManifestPath $ManifestPath
 try{
 $recovery=GetOptiShadeRouteRecovery $ManifestPath;if(-not $recovery){return $false}
 AssertClosed ([string]$recovery.Journal.Game)
 $complete=$true
 # Validate the complete set before restoring anything. An unrelated edit is
 # a conflict, not permission to overwrite a user's current file.
 foreach($entry in @($recovery.Journal.Files)){
  $current=[string](HashFile $entry.Target)
  if($current -cne [string]$entry.AfterHash){$complete=$false}
  if($current -cne [string]$entry.BeforeHash -and $current -cne [string]$entry.AfterHash){throw ('A file changed outside the interrupted route transaction: '+$entry.Path+'. Recovery is retained; resolve this conflict before changing providers.')}
 }
 if(-not $complete){
  # Receipt is last both on commit and rollback. The previous provider, its
  # original-backup chain and the user's settings remain a single unit.
  foreach($entry in @($recovery.Journal.Files)){
   $current=[string](HashFile $entry.Target)
   if($current -ceq [string]$entry.BeforeHash){continue}
   if($current -cne [string]$entry.AfterHash){throw 'A route recovery target changed during rollback. Recovery was retained.'}
   if($entry.BeforeHash){CopyOptiShadeRouteFile (OwnedPath $recovery.Directory ([string]$entry.Before)) $entry.Target ([string]$entry.BeforeHash)}
   elseif(Test-Path -LiteralPath $entry.Target){Remove-Item -LiteralPath $entry.Target -Force}
  }
 }
 foreach($entry in @($recovery.Journal.Files)){$expected=if($complete){[string]$entry.AfterHash}else{[string]$entry.BeforeHash};if((HashFile $entry.Target) -cne $expected){throw 'Route recovery could not verify its final state. Recovery was retained.'}}
 Remove-Item -LiteralPath $recovery.Active -Force
 return $true
 }finally{ExitOptiShadeMutation $storeMutation}
}

function InvokeOptiShadeRouteTransaction([string]$ManifestPath,[string]$BeforeReceiptHash,$AfterManifest,[object[]]$Changes,[string]$RollbackRelative,[string]$Purpose='Portable FSR 2x route switch'){
 $storeMutation=EnterOptiShadeMutation -ManifestPath $ManifestPath
 try{
 $folder=Split-Path ([IO.Path]::GetFullPath($ManifestPath));$active=OwnedPath $folder 'MfgRouteTransaction.json'
 if(Test-Path -LiteralPath $active){throw 'Recover the pending route transaction before preparing another route.'}
 if($RollbackRelative -cnotmatch '^MfgRollback/[a-f0-9]{32}$'){throw 'Invalid route recovery directory.'}
 if((HashFile $ManifestPath) -cne $BeforeReceiptHash){throw 'Installation ownership changed before route preparation.'}
 $rollback=OwnedPath $folder $RollbackRelative;[void][IO.Directory]::CreateDirectory($rollback)
 $entries=@();$seen=@{}
 foreach($change in @($Changes)){
  $target=OwnedPath ([string]$AfterManifest.Game) ([string]$change.Path)
  if($seen.ContainsKey($target)){throw 'Route preparation repeats a target.'};$seen[$target]=$true
  $before=[string](HashFile $target)
  if($before -cne [string]$change.BeforeHash){throw ('A route target changed before preparation: '+$change.Path)}
  $beforeCopy='';$afterCopy='';$afterHash=''
  if($before){$beforeCopy=if($change.Path -ceq 'OptiScaler.ini'){'OptiScaler.ini'}else{'before-'+$entries.Count};CopyOptiShadeRouteFile $target (OwnedPath $rollback $beforeCopy) $before}
  if($change.PSObject.Properties['Bytes']){
   $afterCopy='after-'+$entries.Count;[IO.File]::WriteAllBytes((OwnedPath $rollback $afterCopy),[byte[]]$change.Bytes);$afterHash=HashFile (OwnedPath $rollback $afterCopy)
   $durable=[IO.File]::Open((OwnedPath $rollback $afterCopy),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);try{$durable.Flush($true)}finally{$durable.Dispose()}
  }elseif($change.Source){
   $afterCopy='after-'+$entries.Count;$afterHash=[string]$change.AfterHash;CopyOptiShadeRouteFile ([string]$change.Source) (OwnedPath $rollback $afterCopy) $afterHash
  }
  $entries+=[pscustomobject]@{Scope='Game';Path=[string]$change.Path;BeforeHash=$before;AfterHash=$afterHash;Before=$beforeCopy;After=$afterCopy}
 }
 CopyOptiShadeRouteFile $ManifestPath (OwnedPath $rollback 'manifest.json') $BeforeReceiptHash
 WriteState $AfterManifest (OwnedPath $rollback 'manifest.after.json')
 $entries+=[pscustomobject]@{Scope='Receipt';Path='manifest.json';BeforeHash=$BeforeReceiptHash;AfterHash=(HashFile (OwnedPath $rollback 'manifest.after.json'));Before='manifest.json';After='manifest.after.json'}
 $journalPath=OwnedPath $rollback 'route-transaction.json'
 WriteState ([pscustomobject]@{Schema=1;Game=[string]$AfterManifest.Game;Purpose=$Purpose;Files=$entries}) $journalPath
 WriteState ([pscustomobject]@{Schema=1;Journal=($RollbackRelative+'/route-transaction.json');Hash=(HashFile $journalPath)}) $active
 try{
  $prepared=GetOptiShadeRouteRecovery $ManifestPath
  foreach($entry in @($prepared.Journal.Files)){
   if((HashFile $entry.Target) -cne [string]$entry.BeforeHash){throw ('Route target changed during commit: '+$entry.Path)}
   if($entry.Scope -eq 'Receipt'){WriteState $AfterManifest $ManifestPath}
   elseif($entry.AfterHash){CopyOptiShadeRouteFile (OwnedPath $rollback ([string]$entry.After)) $entry.Target ([string]$entry.AfterHash)}
   elseif(Test-Path -LiteralPath $entry.Target){Remove-Item -LiteralPath $entry.Target -Force}
   if((HashFile $entry.Target) -cne [string]$entry.AfterHash){throw ('Route commit verification failed: '+$entry.Path)}
  }
  [void](RecoverOptiShadeRouteTransaction $ManifestPath)
 }catch{
  $failure=$_
  try{[void](RecoverOptiShadeRouteTransaction $ManifestPath)}catch{throw ($failure.Exception.Message+' Recovery also stopped: '+$_.Exception.Message)}
  throw $failure
 }
 }finally{ExitOptiShadeMutation $storeMutation}
}

function IsGraphicsMod([string]$Relative,[string]$File){

 if($Relative -match '^(?i:OptiShadeData)[\\/]' -or $Relative -match '^(?i:ReShade(?:32|64)?\.dll|ReShade\.ini|ReShade\.log|OptiScaler(?:\.dll|\.ini|\.log)|nvngx_dlssnr\.dll|nvngx\.dll_dlssnr\.dll)$' -or $Relative -match '(?i)(dlss5|renodx).*\.addon64$'){return $true}

 if(Test-Path -LiteralPath $File -PathType Leaf){try{$v=[Diagnostics.FileVersionInfo]::GetVersionInfo($File);return "$($v.ProductName) $($v.FileDescription)" -match '(?i)optishade|optiscaler|reshade'}catch{}}

 return $false

}

function TestOptiShadeRecoverableOwnedFile([string]$Path){
 $p=([string]$Path).Replace('\','/')
 # This helper is called only for exact files named in the verified install
 # receipt. Repair can replace any immutable receipt-owned file; Restore saves
 # its current bytes before putting back the recorded original or removing it.
 return -not (TestOptiShadeMutableFile $p)
}

function GetOptiShadeMfgLoaderAliases {

    # Keep this list aligned with the pinned RTXMFG upstream install guide.

    @('version.dll','dinput8.dll','winmm.dll','d3d9.dll','d3d10.dll','d3d11.dll','d3d12.dll','dxgi.dll','dsound.dll','wininet.dll','winhttp.dll','xinput1_1.dll','xinput1_2.dll','xinput1_3.dll','xinput1_4.dll','xinput9_1_0.dll','xinputuap.dll')

}

function GetOptiShadeMfgLoaderName($Manifest){

    $aliases=@(GetOptiShadeMfgLoaderAliases)

    $recorded=[string]$Manifest.OptionalMfgLoader

    # Recognise the verified upstream DLL after a tester moved it to another

    # supported alias. OptionalMfg in the receipt is required before adopting it.

    if($Manifest.OptionalMfg){

        $physical=@($aliases|Where-Object {(HashFile (OwnedPath $Manifest.Game $_)) -eq 'E9CA3587854EEB723E0579F7DDF6CFB1E6CF4BED79B0D75BC716003ED98FE040'})

        if($physical.Count -eq 1){return [string]$physical[0]}

        if($physical.Count -gt 1){throw 'Multiple supported loader names contain the pinned MFG DLL. Review the installation before repair.'}

        if($recorded -and $recorded -in $aliases){return $recorded}

        foreach($entry in @($Manifest.Files|Where-Object {$_.Path -in $aliases -and $_.Hash -eq 'E9CA3587854EEB723E0579F7DDF6CFB1E6CF4BED79B0D75BC716003ED98FE040'})){return [string]$entry.Path}

        return 'version.dll'

    }

    return ''

}

function CleanModBackupReferences($Manifest,[string]$Folder){

 # Preserve verified backup references, including third-party graphics mods.

 # Older optional-MFG installs may have duplicated the chosen proxy record.

 # Merge only the exact pinned-provider + verified-original shape.

 if($Manifest.OptionalMfg){foreach($alias in (GetOptiShadeMfgLoaderAliases)){

  $records=@($Manifest.Files|Where-Object Path -eq $alias)

  if($records.Count -eq 2){

   $mfg=@($records|Where-Object {$_.Hash -eq 'E9CA3587854EEB723E0579F7DDF6CFB1E6CF4BED79B0D75BC716003ED98FE040' -and -not $_.SourcePath -and -not $_.Backup -and -not $_.PreviousHash})

   $original=@($records|Where-Object {-not $_.Hash -and -not $_.SourcePath -and $_.Backup -and $_.PreviousHash})

   if($mfg.Count -eq 1 -and $original.Count -eq 1){

    $mfg[0].Backup=$original[0].Backup;$mfg[0].PreviousHash=$original[0].PreviousHash

    $Manifest.Files=@($Manifest.Files|Where-Object Path -ne $alias)+@($mfg[0])

   }

  }

 }}

}

function RemoveUnreferencedBackups($Manifest,[string]$Folder){

 $root=OwnedPath $Folder 'Backups';$keep=@($Manifest.Files|Where-Object Backup|ForEach-Object {OwnedPath $Folder $_.Backup})

 if(Test-Path -LiteralPath $root){foreach($f in Get-ChildItem -LiteralPath $root -File -Recurse){$safe=OwnedPath $Folder $f.FullName.Substring($Folder.Length+1);if($safe -notin $keep){Remove-Item -LiteralPath $safe -Force}}}

}

function RemoveLegacyOptiShadeOrphanBackupReferences($Manifest){

 # An older reinstall treated an untracked OptiShadeData tree as user data and

 # saved the prior runtime under Backups/*-orphan-*. That made Restore put an

 # older OptiShade build back into the game. Keep only the established user-data

 # areas; the rest of OptiShadeData is owned runtime/app content.

 $removed=0

 foreach($entry in @($Manifest.Files)){

  $path=([string]$entry.Path).Replace('\','/')

  $backup=([string]$entry.Backup).Replace('\','/')

  if($path -match '^OptiShadeData/' -and $path -notmatch '^OptiShadeData/(Presets|Shaders|Textures)/' -and $backup -match '^Backups/[A-Fa-f0-9-]+-orphan-\d+$' -and -not $entry.Retained){

   if(-not $entry.Hash -and $entry.PreviousHash -and (HashFile (OwnedPath $Manifest.Game $entry.Path)) -eq $entry.PreviousHash){$entry.Hash=$entry.PreviousHash}
   $entry.Backup='';$entry.PreviousHash='';$removed++

  }

 }

 return $removed

}

function RemoveManagedTransactionFolder([string]$Folder,[string]$Relative){

 try{

  $target=OwnedPath $Folder $Relative

  if(-not(Test-Path -LiteralPath $target -PathType Container)){return $false}

  $items=@(Get-ChildItem -LiteralPath $target -Force -Recurse -ErrorAction Stop)

  if($items|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}){return $false}

  Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop

  return $true

 }catch{Write-Warning ('Kept transaction recovery data at '+$Relative+': '+$_.Exception.Message);return $false}

}

function RemoveCompletedInstallTransactionBackups($Manifest,[string]$Folder){

 if($Manifest.Status -ne 'Installed'){return}

 # Rollback holds only the previous state of a completed installer transaction.

 # A successful install has its own verified receipt and no longer needs these.

 $rollbackRoot=OwnedPath $Folder 'Rollback'

 if(Test-Path -LiteralPath $rollbackRoot -PathType Container){

  foreach($dir in Get-ChildItem -LiteralPath $rollbackRoot -Directory -Force -ErrorAction SilentlyContinue|Where-Object Name -match '^[A-Fa-f0-9]{32}$'){

   [void](RemoveManagedTransactionFolder $Folder ('Rollback/'+$dir.Name))

  }

 }

 # AddonBackups contains transaction data and can also hold a verified original

 # file still referenced by the current receipt. Remove stale unreferenced

 # transactions only; never delete a backup required to restore user content.

 $current=HashFile (Join-Path $Folder 'manifest.json')

 $addonRoot=OwnedPath $Folder 'AddonBackups'

 if($current -and (Test-Path -LiteralPath $addonRoot -PathType Container)){

  foreach($dir in Get-ChildItem -LiteralPath $addonRoot -Directory -Force -ErrorAction SilentlyContinue|Where-Object Name -match '^[A-Fa-f0-9]{32}$'){

   $saved=Join-Path $dir.FullName 'manifest.json'

   $prefix='AddonBackups/'+$dir.Name+'/'

   $referenced=@($Manifest.Files|Where-Object {([string]$_.Backup).Replace('\','/').StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)}).Count -gt 0

   if(-not $referenced -and (HashFile $saved) -and (HashFile $saved) -cne $current){[void](RemoveManagedTransactionFolder $Folder ('AddonBackups/'+$dir.Name))}

  }

 }

}

function GetOptiShadeLoaderMigrationPlan($Manifest,[string]$Game,[string]$StateFolder,[string]$TargetProxy){

    # A Repair can change the entry-point DLL. Retire only loader files still

    # matching this receipt, restoring their verified pre-install backup.

    $supported=@('winmm.dll','dxgi.dll','d3d12.dll','version.dll','dbghelp.dll','d3d9.dll','opengl32.dll')

    $loaders=@($Manifest.Files|Where-Object {$_.SourcePath -in @('winmm.dll','ReShade32.dll')})

    $plan=@()

    foreach($group in ($loaders|Group-Object Path)){

        if(@($Manifest.Files|Where-Object {$_.Path -eq $group.Name -and $_.SourcePath -notin @('winmm.dll','ReShade32.dll')}).Count){throw "The recorded loader path $($group.Name) is shared with another component. Repair was stopped; no files were changed."}

        if($group.Name -notin $supported){throw "Unsupported recorded OptiShade loader path $($group.Name). Repair was stopped; no files were changed."}

        if($group.Name -eq $TargetProxy){continue}

        $path=OwnedPath $Game $group.Name;$current=HashFile $path
        $record=@($group.Group|Where-Object {$current -and $_.Hash -eq $current}|Select-Object -First 1)
        if(-not $record.Count){$record=@($group.Group|Where-Object {$_.Backup -and (HashFile (OwnedPath $StateFolder $_.Backup)) -ceq [string]$_.PreviousHash}|Select-Object -First 1)}
        if(-not $record.Count){$record=@($group.Group|Select-Object -First 1)}
        $record=$record[0]

        $installed=[string]$record.Hash;$previous=[string]$record.PreviousHash

        $restoreNeeded=$true

        if($current -and $previous -and $current -eq $previous){$restoreNeeded=$false}

        # The recorded receipt is the ownership authority. A changed current
        # loader is captured by Repair's recovery snapshot and can then be
        # replaced or retired safely.

        if($restoreNeeded -and $previous -and $record.Backup){[void](OwnedPath $StateFolder $record.Backup)}

        $plan+=@{Path=$group.Name;PreviousHash=$previous;Backup=[string]$record.Backup;RestoreNeeded=$restoreNeeded;RetireLoader=$true}

    }

    return ,$plan

}

function FindFusionConflicts([string]$Game){

 foreach($name in @('ReShade.ini','OptiScaler.ini','nvngx_dlssnr.dll','nvngx.dll_dlssnr.dll')){if(Test-Path -LiteralPath (Join-Path $Game $name) -PathType Leaf){[pscustomobject]@{Path=$name;Recognised=$true;Description='Graphics mod file';Hash=(HashFile (Join-Path $Game $name))}}}

 foreach($addon in Get-ChildItem -LiteralPath $Game -Filter '*.addon64' -File -ErrorAction SilentlyContinue|Where-Object Name -match '(?i)dlss5|renodx'){

  [pscustomobject]@{Path=$addon.Name;Recognised=$true;Description='External neural-rendering/ReShade add-on';Hash=(HashFile $addon.FullName)}

 }

 foreach($name in (@('dxgi.dll','d3d12.dll','d3d11.dll','d3d9.dll','opengl32.dll','OptiScaler.dll','ReShade64.dll','winmm.dll','version.dll','dbghelp.dll','wininet.dll','winhttp.dll','dinput8.dll','SpecialK64.dll','ReShade.asi','OptiScaler.asi')+(GetOptiShadeMfgLoaderAliases)|Select-Object -Unique)){

  $file=Join-Path $Game $name

  if(Test-Path -LiteralPath $file -PathType Leaf){

   $info=[Diagnostics.FileVersionInfo]::GetVersionInfo($file);$description="$($info.ProductName) $($info.FileDescription) $($info.OriginalFilename)"
   # A configured translation layer is a dependency, not a competing overlay.
   if($name -eq 'd3d9.dll' -and $info.ProductName -eq 'dgVoodoo' -and (TestOptiShadeLegacyD3D9Wrapper $Game)){continue}

    $recognised=($description -match '(?i)reshade|optiscaler|optishade|special.?k|enbseries') -or ((HashFile $file) -eq 'E9CA3587854EEB723E0579F7DDF6CFB1E6CF4BED79B0D75BC716003ED98FE040')

   [pscustomobject]@{Path=$name;Recognised=$recognised;Description=$description.Trim();Hash=(HashFile $file)}

  }

 }

}

function SelectOptiShadeRoutePayload($Catalog,[string]$RouteName){

 @($Catalog|Where-Object {

  $relative=$_.Path.Replace('\','/')

  if(TestOptiShadeLegacyPayloadPath $relative){return $false}

  if($relative -ieq 'glass-cockpit-dlss-fix.addon64'){return $RouteName -eq 'OptiShadeMSFS2024.dll'}

  return $relative -notlike 'OptiShadeData/Engine/Routes/*' -or [IO.Path]::GetFileName($_.Path) -eq $RouteName

 })

}

function CopyOptiShadeInstallationPreferences($Source,$Target){
 if(-not $Source){return}
 # These are user preferences and preparation receipts, never live intent or
 # a replacement for the new loader/executable identity established by install.
 foreach($key in @('AutoCompatibility','AutoComponentExclusions','ProviderAdapter','NeuralAdapter','NeuralAdapterSelection','NeuralGpuName','NeuralGpuSelection','NeuralRuntimeVariant','NeuralRuntimeHash','NeuralPreparation','DlssRuntimeProfile','ProviderPolicy','Downloads','OptionalDlss','FxPresetRelative','AllFxInstalled','InstallMethod','RendererApi')){
  $property=$Source.PSObject.Properties[$key]
  if(-not $property){continue}
  if($Target -is [Collections.IDictionary]){$Target[$key]=$property.Value}else{$Target|Add-Member -NotePropertyName $key -NotePropertyValue $property.Value -Force}
 }
}

# The manager sets OptiShadeCancelCheck while a cancellable operation runs.
# It throws once, only at the safe points that call this.
function AssertOptiShadeNotCancelled{if($script:OptiShadeCancelCheck){& $script:OptiShadeCancelCheck}}

function InstallFusion([string]$Game,[string]$Payload,[string]$StateRoot,[string]$Installer,[string]$Proxy='winmm.dll',[object[]]$ReplaceMods=@(),[bool]$ReplaceExisting=$false,[bool]$PreserveConfiguration=$false,[bool]$IncludeEffects=$false,[string]$Executable='',[object]$ExpectedExecutableMetadata=$null,[scriptblock]$Progress={param($text,$completed=0,$total=0)}){
 $storeMutation=EnterOptiShadeMutation -StateRoot $StateRoot
 try{

     &$Progress 'Checking game files and installation ownership...' 0 6

    if($Proxy -notin @('winmm.dll','dxgi.dll','d3d12.dll','version.dll','dbghelp.dll','wininet.dll','winhttp.dll','d3d9.dll','opengl32.dll')){throw 'Unsupported installation method.'}

    $Game=FullPath $Game;$Payload=FullPath $Payload
    &$Progress 'Checking that the game is closed...' 0 6
    AssertClosed $Game;AssertOptiShadeNotCancelled

    if(-not(Test-Path -LiteralPath $Game -PathType Container)){throw 'Choose the game folder first.'}

    $mp=ManifestPath $StateRoot $Game

    if(Test-Path -LiteralPath $mp){[void](RecoverOptiShadeRouteTransaction $mp)}

    $old=$null;$oldJson=$null

    if(Test-Path -LiteralPath $mp){$oldJson=Get-Content -LiteralPath $mp -Raw;$old=ReadOptiShadeState $mp;if($old.Status -ne 'Restored' -and -not $ReplaceExisting){throw 'OptiShade is already recorded here. Choose Repair or approve reinstalling it.'};if($old.Status -eq 'Restored'){$old=$null}}

    if(-not $Executable -and $old -and $old.LaunchExe){$Executable=[string]$old.LaunchExe}

    # The agreement guard returns a Boolean when the session has already
    # accepted the safety prompt. Suppress that implementation detail here:
    # InstallFusion's public output is the canonical receipt path, and callers
    # capture it for the next read/write operation.
    [void](AssertAntiCheatMutation $Game $Executable 'Install / repair core')

    $targetIdentity=$null;$architecture='x64'

    if($Executable){
        &$Progress ('Checking the game executable: '+[IO.Path]::GetFileName($Executable)+'...') 0 6
        AssertOptiShadeNotCancelled
        try{$targetIdentity=GetOptiShadeExecutableIdentity $Executable}catch{
            if(-not(TestOptiShadeExecutableAccessDenied $_) -or -not $old -or [string]$old.Status -cne 'Installed'){throw}
            $targetIdentity=GetOptiShadeRecordedXboxExecutableIdentity $old $Executable
            if(-not $targetIdentity){throw}
        }
        if($ExpectedExecutableMetadata){
            $currentMetadata=GetOptiShadeExecutableMetadata $Executable
            if((ConvertTo-Json $currentMetadata -Compress) -cne (ConvertTo-Json $ExpectedExecutableMetadata -Compress)){throw 'The game executable changed after update preflight. No game files were changed.'}
            if([string]$targetIdentity.SHA256){$currentHash=HashFile $Executable;if($currentHash -cne [string]$targetIdentity.SHA256){throw 'The game executable changed after update preflight. No game files were changed.'}}
        }
        $architecture=[string]$targetIdentity.Architecture
    }

    if($architecture -eq 'x86' -and $Proxy -notin @('d3d9.dll','dxgi.dll','opengl32.dll')){throw 'This x86 installation needs a DirectX 9, DirectX 10/11/12, or OpenGL hook. Choose the matching x86 image-effects method.'}

    if($architecture -ne 'x86' -and $Proxy -in @('d3d9.dll','opengl32.dll')){throw 'The selected ReShade32 hook is only for a 32-bit game executable.'}

    if($old -and $old.PSObject.Properties['IncludeEffects']){$IncludeEffects=[bool]$old.IncludeEffects}

    elseif($old -and $old.Downloads -eq 'Complete' -and -not(Test-Path -LiteralPath (Join-Path $Game 'OptiShadeData/Shaders'))){$IncludeEffects=$false}

    $unrestoredOriginalFiles=@()
    if($old){

        CleanModBackupReferences $old (Split-Path $mp)

        $staleOptiShadeBackups=RemoveLegacyOptiShadeOrphanBackupReferences $old

        if($staleOptiShadeBackups){Write-Warning "Discarding $staleOptiShadeBackups legacy OptiShade runtime backup record(s); they are not original game files."}

        foreach($f in $old.Files){
            if(-not $f.PreviousHash -or (TestOptiShadePresetIniPath $f.Path)){continue}
            $original=if($f.Backup){HashFile (OwnedPath (Split-Path $mp) $f.Backup)}else{''}
            if($original -cne [string]$f.PreviousHash){$unrestoredOriginalFiles+=([string]$f.Path)}
        }

    }

    # An immutable file can change after installation when the user or an
    # upstream component updates it. It is still owned at this exact path by
    # the receipt, so snapshot it for recovery before Repair replaces it.
    $repairChangedFiles=@()
    if($old){foreach($record in $old.Files){
        if(TestOptiShadeMutableFile $record.Path){continue}
        $current=HashFile (OwnedPath $Game ([string]$record.Path))
        if($current -and $current -cne [string]$record.Hash -and $current -cne [string]$record.PreviousHash){$repairChangedFiles+=@{Path=[string]$record.Path;Hash=$current}}
    }}

    $selectedName=if($Executable){[IO.Path]::GetFileName($Executable)}else{''}
    $infer= -not $selectedName -or $selectedName -eq 'gamelaunchhelper.exe'
    $routeName=if($selectedName -eq 'FlightSimulator2024.exe' -or ($infer -and (Test-Path -LiteralPath (Join-Path $Game 'FlightSimulator2024.exe')))){'OptiShadeMSFS2024.dll'}elseif($selectedName -eq 'FlightSimulator.exe' -or ($infer -and (Test-Path -LiteralPath (Join-Path $Game 'FlightSimulator.exe')))){'OptiShadeMSFS2020.dll'}elseif($selectedName -eq 'X-Plane.exe' -or ($infer -and (Test-Path -LiteralPath (Join-Path $Game 'X-Plane.exe')))){'OptiShadeXPlane12.dll'}else{'OptiShadeGeneric.dll'}
    $nativeProviderHash='E6B6E6B70A6ED3AF839C9647A32FC22660AE6B2D655062C5C072246C91FC10C7'
    $isMsfsRoute=$routeName -in @('OptiShadeMSFS2020.dll','OptiShadeMSFS2024.dll') -and $Proxy -cne 'version.dll'
    $conflicts=@(FindFusionConflicts $Game)

    # A same-named foreign proxy belongs to another mod. Never silently replace
    # it just because the user selected that hook name. Unknown proxy DLLs at
    # other names are not conflicts with this install route and must stay put.
    $installConflicts=@()
    foreach($conflict in $conflicts){
        # A recorded path is allowed through this preflight so the stricter
        # per-file repair check below can reconcile an interrupted write or
        # reject changed bytes against the verified incoming payload.
        $recorded=@($old.Files|Where-Object {$_.Path -ieq $conflict.Path})
        if($conflict.Path -ieq 'version.dll' -and $isMsfsRoute){
            # version.dll is the native MFG provider on this route. Leave a
            # foreign loader alone; an identical pinned provider is safe to
            # adopt into core ownership during repair.
            if($conflict.Hash -ceq $nativeProviderHash -or -not $recorded.Count){continue}
            $recordedMfgProvider=@($recorded|Where-Object {[string]$_.Hash -ceq $nativeProviderHash})
            if($recordedMfgProvider.Count -ne 1){continue}
        }
        $knownMfgProvider=($conflict.Hash -eq 'E9CA3587854EEB723E0579F7DDF6CFB1E6CF4BED79B0D75BC716003ED98FE040')
        if(-not $conflict.Recognised -and -not $recorded.Count -and -not $knownMfgProvider){
            if($conflict.Path -ieq $Proxy){
                throw ("A third-party {0} is already present and is not owned by OptiShade. It was left untouched. Choose a different compatible install method (for a DirectX game, try dxgi.dll), or remove the other mod with its own installer before retrying." -f $Proxy)
            }
            continue
        }
        $installConflicts+=,$conflict
    }
    $conflicts=$installConflicts

    foreach($conflict in $conflicts){

        $approved=@($ReplaceMods|Where-Object {$_.Path -eq $conflict.Path -and $_.Hash -eq $conflict.Hash})

        if(-not $approved.Count){throw "Approval is needed to back up and replace $($conflict.Path). The file was left untouched."}

    }

    $data=OwnedPath $Game 'OptiShadeData'

    if(Test-Path -LiteralPath $data){

        $presetRoot=OwnedPath $Game 'OptiShadeData/Presets'

        foreach($entry in Get-ChildItem -LiteralPath $data -Force -Recurse){

            if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked OptiShade data was left untouched.'}

            if(-not $ReplaceExisting -and -not $entry.PSIsContainer -and -not($entry.FullName.StartsWith($presetRoot+'\',[StringComparison]::OrdinalIgnoreCase) -and $entry.Extension -eq '.ini')){throw 'Existing OptiShade files detected. Approve a backed-up reinstall to continue.'}

        }

    }

    $catalog=ReadOptiShadeJson (Join-Path $Payload 'files.json') 'Payload catalogue JSON' -Shape Array

    if($Executable -and -not [string]::Equals((FullPath (Split-Path $Executable)), $Game, [StringComparison]::OrdinalIgnoreCase)){throw 'Select the folder containing the rendering executable.'}

    $selectedComponents=@(GetOptiShadeAddonSelection $old)

    if($architecture -eq 'x86'){

        $selectedComponents=@($selectedComponents|Where-Object {$_ -in @('Effects','Neural')}|Select-Object -Unique)

        $catalog=@($catalog|Where-Object {

            $relative=$_.Path.Replace('\','/')

            $relative -eq 'ReShade32.dll' -or $relative -eq 'ReShade.ini' -or $relative -eq 'OptiShadeData/Presets/My look.ini' -or

            $relative -match '^OptiShadeData/Licenses/' -or (GetOptiShadeAddonId $_.Path) -eq 'Effects' -or

            ((GetOptiShadeAddonId $_.Path) -eq 'Neural' -and 'Neural' -in $selectedComponents)

        })

    }else{

        $catalog=@(SelectOptiShadeRoutePayload $catalog $routeName)

    }

    if(-not $old -and $IncludeEffects){$selectedComponents+='Effects'}

    $catalog=@($catalog|Where-Object {(GetOptiShadeAddonId $_.Path) -eq 'Core' -or ((GetOptiShadeAddonId $_.Path) -in $selectedComponents -and -not($old -and $old.Sm86Mfg -and (GetOptiShadeAddonId $_.Path) -eq 'Mfg'))})

    # Core repair must not resurrect retired root providers or stage an older-RTX
    # backend on a native RTX 50 receipt. The selected core proxy is mapped later
    # from winmm.dll; this does not remove support for that legitimate alias.
    $catalog=@($catalog|Where-Object {TestOptiShadeCurrentMfgPayload $_.Path $old})

    # The official addon has its own update feed. A core repair must never
    # replace it with the older bundled version, or rewrite its ownership.
    if($old -and 'Cockpit' -in $selectedComponents){$catalog=@($catalog|Where-Object {(GetOptiShadeAddonId $_.Path) -ne 'Cockpit'})}

    if($architecture -ne 'x86'){$catalog=@($catalog|Where-Object {$_.Path -ne 'ReShade32.dll'})}

    if($architecture -ne 'x86' -and $routeName -and @($catalog|Where-Object {$_.Path.Replace('\','/') -eq ('OptiShadeData/Engine/Routes/'+$routeName)}).Count -ne 1){throw 'The installer does not contain the matching simulator adapter. No game files have been changed.'}

    if($architecture -eq 'x86' -and @($catalog|Where-Object {$_.Path -eq 'ReShade32.dll'}).Count -ne 1){throw 'The installer is missing the verified 32-bit ReShade runtime. No game files have been changed.'}



    # r5 source setup could record the same MFG file using two slash spellings.

    # Coalesce only identical ownership chains, using the incoming catalogue's

    # spelling. Conflicting originals remain a recovery error.

    if($old -and $old.SourceMfg){

        foreach($relative in @('OptiShadeData/MFG/OptiShadeMFG.dll','OptiShadeData/MFG/source-backend.json')){

            $records=@($old.Files|Where-Object {$_.Path.Replace('\','/') -eq $relative})

            if(-not $records.Count){continue}

            $chains=@($records|ForEach-Object {([string]$_.Backup)+'|'+([string]$_.PreviousHash)+'|'+([string]$_.Hash)}|Select-Object -Unique)

            if($chains.Count -ne 1){throw 'Conflicting source MFG ownership records require recovery; original backups were kept.'}

            $incoming=@($catalog|Where-Object {$_.Path.Replace('\','/') -eq $relative})

            $record=$records[0];$record.Path=$(if($incoming.Count -eq 1){$incoming[0].Path}else{$relative})

            $old.Files=@($old.Files|Where-Object {$_.Path.Replace('\','/') -ne $relative})+@($record)

        }

    }

    $folder=Split-Path $mp

    $loaderMigrations=if($old){GetOptiShadeLoaderMigrationPlan $old $Game $folder $Proxy}else{@()}

    New-Item -ItemType Directory -Path (Join-Path $folder 'Backups') -Force|Out-Null

    &$Progress 'Comparing installed files with this version...' 1 6
    AssertOptiShadeNotCancelled
    $files=@();$index=0;$transaction=[guid]::NewGuid().ToString('N')

    # Keep the original ownership chain across upgrades. Orphaned data is backed up

    # as pre-existing user data so Restore can recover it instead of deleting it.

    if($old){

        foreach($entry in $old.Files){

            $addon=GetOptiShadeAddonId $entry.Path

            $retained=(([bool]$entry.Component -or $addon -ne 'Core') -and $addon -in $selectedComponents) -or

                ($entry.Path -in @('OptiShadeData/MFG/source-backend.json','RTXMFG-Universal.json') -and $old.SourceMfg) -or

                $entry.Path -match '^OptiShadeData[\\/](Presets|Shaders|Textures)[\\/]' -or

                (TestOptiShadeUserSettings $entry.Path) -or

                $entry.Path -match 'Effects-install\.json$' -or $entry.Path -eq 'nvngx_dlssnr.dll' -or

                ($old.OptionalMfg -and $entry.Path -in (GetOptiShadeMfgLoaderAliases)) -or

                ($entry.Component -eq 'OptiMfg' -and 'OptiMfg' -in $selectedComponents) -or

                ($old.Sm86Mfg -and $entry.Path -ieq $old.Sm86MfgLoader)

            $files+=@{Path=$entry.Path;SourcePath='';Hash=$entry.Hash;PreviousHash=$entry.PreviousHash;Backup=$entry.Backup;Mutable=$entry.Mutable;RetireLoader=$entry.RetireLoader;Retained=[bool]$retained;Component=$entry.Component}

        }

    }

    if($ReplaceExisting -and (Test-Path -LiteralPath $data)){

        $dataItems=@(Get-ChildItem -LiteralPath $data -File -Recurse -Force)
        if($dataItems|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}){throw 'A linked item was found in OptiShade data. Repair stopped before changing files.'}
        $knownPaths=@($files|ForEach-Object {([string]$_.Path).Replace('\','/')})
        foreach($entry in $dataItems){

            $relative=$entry.FullName.Substring($Game.Length+1)
            if(TestOptiShadeRegeneratedData $relative){continue}
            $previous=HashFile $entry.FullName
            $normalized=$relative.Replace('\','/')
            if($normalized -in $knownPaths){continue}

            $keep=$relative -match '^OptiShadeData[\\/](Presets|Shaders|Textures)[\\/]'

            # Preserve looks and user shader/texture assets. Other files beneath

            # OptiShadeData are manager-owned runtime/state and must not be

            # reinstalled by Restore as an older OptiShade build.

            $backup=''

            if($keep){

                $backup='Backups/'+$transaction+'-orphan-'+$index

                Copy-Item -LiteralPath $entry.FullName -Destination (OwnedPath $folder $backup)

                if((HashFile (OwnedPath $folder $backup)) -ne $previous){throw 'Pre-existing user-data backup verification failed.'}

            }

            if(-not $keep){$repairChangedFiles+=@{Path=$relative;Hash=$previous}}
            $files+=@{Path=$relative;SourcePath='';Hash=$(if($keep){$previous}else{''});PreviousHash=$(if($keep){$previous}else{''});Backup=$backup;Mutable=$true;Retained=$keep};$knownPaths+=,$normalized;$index++

        }

    }

    foreach($migration in $loaderMigrations){

        $files=@($files|Where-Object Path -ne $migration.Path)

        if($migration.RestoreNeeded){$files+=@{Path=$migration.Path;SourcePath='';Hash='';PreviousHash=$migration.PreviousHash;Backup=$migration.Backup;Mutable=$false;Retained=$false;RetireLoader=$true}}

    }

    # Refresh the installed optional provider in the same rollback transaction as

    # the main loader. Only a recorded MFG destination may be mapped this way.

    if($old -and $old.OptionalMfg){

        $provider=@($catalog|Where-Object Path -match '^OptiShadeData[\\/]MFG[\\/]RTXMFG\.dll$')

        $mfgLoader=GetOptiShadeMfgLoaderName $old

        $ownedProvider=@($old.Files|Where-Object {$_.Path -in (GetOptiShadeMfgLoaderAliases) -and $_.Hash -eq 'E9CA3587854EEB723E0579F7DDF6CFB1E6CF4BED79B0D75BC716003ED98FE040'})

        if($provider.Count -ne 1 -or $ownedProvider.Count -ne 1 -or $ownedProvider[0].SourcePath -eq 'winmm.dll' -or $ownedProvider[0].Mutable){throw 'Recorded MFG provider cannot be refreshed safely. Review this installation in Setup.'}

        $current=HashFile (OwnedPath $Game $mfgLoader)

        # A changed receipt-owned provider is archived by Repair's recovery
        # pass and the verified bundled provider replaces it below.

        $ownedProvider[0].Path=$mfgLoader

        $catalog+=@{Path=$provider[0].Path;Hash=$provider[0].Hash;UpdateDestination=$mfgLoader}

    }

    # Retire unchanged bundled shader/texture assets no longer shipped. Imported

    # assets (no payload source), edited files and user presets remain untouched.

    if($old){foreach($previous in $old.Files){

        if($previous.SourcePath -and $previous.Path -match '^OptiShadeData[\\/](Shaders|Textures)[\\/]' -and $previous.SourcePath -notin $catalog.Path -and (HashFile (OwnedPath $Game $previous.Path)) -eq $previous.Hash){

            foreach($tracked in @($files|Where-Object Path -eq $previous.Path)){$tracked.Retained=$false;$tracked.Hash=''}

        }

    }}

    foreach($entry in $catalog){

        $bundledLook=$entry.Path -match '^OptiShadeData[\\/](Shaders[\\/]Custom[\\/]Gravy_FusionCinema\.fx|Presets[\\/](My look\.ini|Gravy - Fusion Cinema Custom v1\.ini))$'

        $neuralGuides=$entry.Path -match '^OptiShadeData[\\/](Shaders[\\/]OptiShadeTaa[\\/]|Textures[\\/]vort_BlueNoise\.png$|Presets[\\/]X-Plane neural guides\.ini$)'

        if(-not $IncludeEffects -and $entry.Path -match '^OptiShadeData[\\/](Shaders|Textures|Presets)[\\/]' -and -not $bundledLook -and -not $neuralGuides){continue}

        $source=OptiShadeIoPath (OwnedPath $Payload $entry.Path);$relative=if($entry.Path -in @('winmm.dll','ReShade32.dll')){$Proxy}elseif($entry.UpdateDestination){$entry.UpdateDestination}else{$entry.Path};$dest=OwnedPath $Game $relative

        $sourceHash=try{HashFile $source}catch{''}

        if($sourceHash -ne $entry.Hash){throw ("Installer verification failed for $($entry.Path). The extracted file is missing or differs from the packaged copy. No game files have been changed."+(GetDefenderFileEvidence $source)+' Close the manager and download a fresh official installer. Do not replace the DLL from another website.')}

        # Keep download receipts on repair/reinstall; bundled defaults must not erase them.

        if($relative -match '^OptiShadeData[\\/]Effects-install\.json$' -and (Test-Path -LiteralPath $dest)){continue}

        # A returning user's saved default look is their preset, not disposable payload.

        if($relative -match '^OptiShadeData[\\/]Presets[\\/].*\.ini$' -and (Test-Path -LiteralPath $dest)){continue}

        # If a user-retained preset was deleted, do not silently recreate a

        # bundled default over the missing user copy during Repair.

        if((TestOptiShadePresetIniPath $relative) -and -not(Test-Path -LiteralPath $dest)){

            $retainedPreset=@($files|Where-Object {$_.Path -eq $relative -and $_.Retained})

            if($retainedPreset.Count){continue}

        }

        if((TestOptiShadeUserSettings $relative) -and (Test-Path -LiteralPath $dest)){

            if(@($files|Where-Object {$_.Path.Replace('\','/') -ieq $relative.Replace('\','/')} ).Count -eq 0){

                $previous=HashFile $dest;$backup='Backups/'+$transaction+'-config-'+$index

                Copy-Item -LiteralPath $dest -Destination (OwnedPath $folder $backup)

                if((HashFile (OwnedPath $folder $backup)) -ne $previous){throw 'Configuration backup verification failed.'}

                $files+=@{Path=$relative;SourcePath=$entry.Path;Hash=$previous;PreviousHash=$previous;Backup=$backup;Mutable=$true;Retained=$true};$index++

            }

            continue

        }

        $existing=@($files|Where-Object {$_.Path.Replace('\','/') -ieq $relative.Replace('\','/')})

        if($existing.Count){

            $currentHash=HashFile $dest;$matching=@($existing|Where-Object {$_.Hash -eq $currentHash})

            # A previous install may have written the verified current payload
            # without committing its receipt. Keep its original recovery chain.
            # Only exact bytes from the source verified above qualify.
            if($currentHash -and -not $matching.Count -and $currentHash -eq $sourceHash){$matching=$existing}

            if($currentHash -and -not $matching.Count -and (TestOptiShadeRecoverableOwnedFile $relative)){
                # The receipt owns this exact path. Preserve current bytes in
                # Repair's recovery archive and carry the original chain forward
                # even when its backup needs recovery; that must not block repair.
                $matching=$existing
            }
            if($currentHash -and -not $matching.Count -and -not (TestOptiShadeMutableFile $relative)){throw "Existing owned file changed during repair: $relative"}

            $originalCandidates=@($matching|Where-Object {$_.PreviousHash -and $_.PreviousHash -notin @($matching.Hash)})
            $verifiedOriginals=@($originalCandidates|Where-Object {$_.Backup -and (HashFile (OwnedPath $folder $_.Backup)) -ceq [string]$_.PreviousHash})
            $original=if($verifiedOriginals.Count){@($verifiedOriginals|Select-Object -First 1)}else{@($originalCandidates|Select-Object -First 1)}

            $previous=if($original.Count){$original[0].PreviousHash}else{''};$backup=if($original.Count){$original[0].Backup}else{''}

            $files=@($files|Where-Object {$_.Path.Replace('\','/') -ine $relative.Replace('\','/')})

        }

        else{$previous=HashFile $dest;$backup='';if($previous){$backup='Backups/'+$transaction+'-'+$index;Copy-Item -LiteralPath $dest -Destination (OwnedPath $folder $backup);if((HashFile (OwnedPath $folder $backup)) -ne $previous){throw 'Backup verification failed.'}}}

        $files+=@{Path=$relative;SourcePath=$entry.Path;Hash=$entry.Hash;PreviousHash=$previous;Backup=$backup;Mutable=(TestOptiShadeMutableFile $relative);Retained=$false};$index++

    }

    foreach($conflict in $conflicts){

        if($files.Path -contains $conflict.Path){

            $tracked=@($files|Where-Object Path -eq $conflict.Path)[0]

            if($tracked.Retained -and (TestOptiShadeUserSettings $conflict.Path)){continue}

            if($tracked.Retained -and ($conflict.Path -eq 'nvngx_dlssnr.dll' -or (($old.OptionalMfg -or $old.Sm86Mfg) -and $conflict.Path -in (GetOptiShadeMfgLoaderAliases)))){continue};if($tracked.Retained){$tracked.Retained=$false;$tracked.Hash=''}

            continue

        }

        $backup='Backups/'+$transaction+'-mod-'+$index;$previous=$conflict.Hash;$source=OwnedPath $Game $conflict.Path

        Copy-Item -LiteralPath $source -Destination (OwnedPath $folder $backup)

        if((HashFile (OwnedPath $folder $backup)) -ne $previous){throw 'Existing mod backup verification failed.'}

        $files+=@{Path=$conflict.Path;SourcePath='';Hash='';PreviousHash=$previous;Backup=$backup;Mutable=$false};$index++

    }

    $rollback=@();$rollbackFolder=OwnedPath $folder ('Rollback/'+$transaction);New-Item -ItemType Directory -Path $rollbackFolder -Force|Out-Null

     $rollbackItems=@($files|Where-Object {-not $_.Retained});$rollbackIndex=0

     foreach($entry in $rollbackItems){

         $rollbackIndex++;&$Progress ("Saving recovery copy {0}/{1}: {2}" -f $rollbackIndex,$rollbackItems.Count,[IO.Path]::GetFileName($entry.Path)) ($rollbackIndex-1) $rollbackItems.Count

        $dest=OwnedPath $Game $entry.Path;$hash=HashFile $dest;$copy=Join-Path $rollbackFolder ([string]$rollback.Count)

        if($hash){Copy-Item -LiteralPath $dest -Destination $copy;if((HashFile $copy) -ne $hash){throw 'Rollback snapshot verification failed.'}}

        $rollback+=@{Path=$entry.Path;Hash=$hash;Copy=$copy}

    }

    # Keep modified receipt-owned files and orphaned app-runtime files outside
    # the game before a successful Repair replaces or removes them.
    $repairRecovery=SaveOptiShadeRecoveryFiles $Game $repairChangedFiles 'RepairFiles'

     &$Progress 'Writing the transaction record...' 4 6

    $manifest=@{Version=(GetBundledOptiShadeVersion);Game=$Game;Installer=(FullPath $Installer);Status='Installing';Files=$files;OwnedDirectories=@('OptiShadeData');IncludeEffects=$IncludeEffects;Components=$selectedComponents;Architecture=$architecture;Runtime=$(if($architecture -eq 'x86'){if('Neural' -in $selectedComponents){'ReShade32 + Legacy NR x64 worker'}else{'ReShade32 effects-only'}}else{'OptiScaler + ReShade64'});PreserveThirdParty=$true;Created=(Get-Date -Format o)}

    $manifest.RouteDLL=$routeName
    if($repairRecovery){$manifest.RecoveredChangedFiles=$repairRecovery}
    if($unrestoredOriginalFiles.Count){$manifest.UnrestoredOriginalFiles=@($unrestoredOriginalFiles|Select-Object -Unique)}

    if($Executable){$manifest.LaunchExe=$Executable}
    if($old -and $old.NativeLaunchExe){$manifest.NativeLaunchExe=$old.NativeLaunchExe}
    if($old -and $old.DisplayName){$manifest.DisplayName=$old.DisplayName}

    if($old -and $old.OptionalMfg){$manifest.OptionalMfg=$true;$manifest.OptionalMfgVersion=$old.OptionalMfgVersion;$manifest.OptionalMfgLoader=GetOptiShadeMfgLoaderName $old;$manifest.OptionalMfgLoaderEvidence=$old.OptionalMfgLoaderEvidence}

    if($old -and $old.SourceMfg){$manifest.SourceMfg=$true;$manifest.SourceMfgRollback=$old.SourceMfgRollback}

    if($old -and $old.Sm86Mfg){$manifest.Sm86Mfg=$true;$manifest.Sm86MfgVersion=$old.Sm86MfgVersion;$manifest.Sm86MfgSHA256=$old.Sm86MfgSHA256;$manifest.Sm86MfgLoader=$old.Sm86MfgLoader;$manifest.Sm86MfgFiles=$old.Sm86MfgFiles;$manifest.Sm86MfgIniBefore=$old.Sm86MfgIniBefore}

    if($old -and $old.PSObject.Properties['FrameGenerationRoute']){$manifest.FrameGenerationRoute=$old.FrameGenerationRoute;$manifest.FrameGenerationRouteRollback=$old.FrameGenerationRouteRollback}

    if($old -and $old.NeuralGpuName){$manifest.NeuralGpuName=$old.NeuralGpuName;$manifest.NeuralGpuSelection=$old.NeuralGpuSelection}

    if($old -and $old.PSObject.Properties['LegacyNrPresetRelative']){$manifest.LegacyNrPresetRelative=$old.LegacyNrPresetRelative;$manifest.LegacyNrPresetStatus=$old.LegacyNrPresetStatus;$manifest.LegacyNrPresetMessage=$old.LegacyNrPresetMessage}

    CopyOptiShadeInstallationPreferences $old $manifest

    WriteState $manifest $mp

    try{

        # The entry-point proxy is copied last so an incomplete install cannot start.

         $installItems=@($files|Sort-Object @{Expression={$_.SourcePath -in @('winmm.dll','ReShade32.dll')}});$installIndex=0;$installTotal=@($installItems|Where-Object {-not $_.Retained}).Count

         foreach($entry in $installItems){

             if(-not $entry.Retained){$installIndex++;&$Progress ("Installing file {0}/{1}: {2}" -f $installIndex,$installTotal,[IO.Path]::GetFileName($entry.Path)) $installIndex $installTotal}
             # Inside the rollback block: a cancel here restores every file changed so far.
             AssertOptiShadeNotCancelled

            if($entry.Retained){continue}

            $dest=OwnedPath $Game $entry.Path;New-Item -ItemType Directory -Path (Split-Path $dest) -Force|Out-Null

            $snapshot=@($rollback|Where-Object Path -eq $entry.Path)[0]

            if((HashFile $dest) -ne $snapshot.Hash){throw 'An existing file changed during installation.'}

            if($entry.RetireLoader){

                if($entry.PreviousHash){

                    $backup=if($entry.Backup){OwnedPath $folder $entry.Backup}else{''}
                    if($backup -and (HashFile $backup) -ceq [string]$entry.PreviousHash){
                        Copy-Item -LiteralPath $backup -Destination $dest -Force
                        if((HashFile $dest) -ne $entry.PreviousHash){throw "The original loader could not be restored for $($entry.Path)."}
                    }else{
                        if(Test-Path -LiteralPath $dest){Remove-Item -LiteralPath $dest -Force}
                        $unrestoredOriginalFiles+=([string]$entry.Path)
                    }

                }elseif(Test-Path -LiteralPath $dest){Remove-Item -LiteralPath $dest -Force}

                continue

            }

            if(-not $entry.SourcePath){if(Test-Path -LiteralPath $dest){Remove-Item -LiteralPath $dest -Force};continue}

            try{

                Copy-Item -LiteralPath (OptiShadeIoPath (OwnedPath $Payload $entry.SourcePath)) -Destination $dest -Force

                if((HashFile $dest) -ne $entry.Hash){throw 'Copied file is missing or differs from the packaged copy.'}

            }catch{

                throw ("Installed file verification failed for $($entry.Path). The file could not be copied or verified."+(GetDefenderFileEvidence $dest))

            }

        }

        EnsureOptiShadeReShadeSearchPaths $Game
        foreach($reshadeRecord in @($manifest.Files|Where-Object {$_.Path.Replace('\','/') -ieq 'ReShade.ini'})){$reshadeRecord.Hash=HashFile (OwnedPath $Game 'ReShade.ini')}

         if((Test-Path -LiteralPath (Join-Path $Game 'X-Plane.exe')) -and -not $PreserveConfiguration){

            $config=OwnedPath $Game 'ReShade.ini'

            if(Test-Path -LiteralPath $config){

                $text=[IO.File]::ReadAllText($config) -replace '(?m)^PresetPath=.*$','PresetPath=.\OptiShadeData\Presets\My look.ini'

                [IO.File]::WriteAllText($config,$text,[Text.UTF8Encoding]::new($false))

                ($manifest.Files|Where-Object Path -eq 'ReShade.ini').Hash=HashFile $config

            }

        }

        $dependencyPointer=OwnedPath $Game 'OptiShadeData/dependency-state.ini'

        if(Test-Path -LiteralPath $dependencyPointer){

            [IO.File]::WriteAllText($dependencyPointer,"[Storage]`nRoot=$StateRoot`n",[Text.UTF8Encoding]::new($false))

            foreach($entry in $manifest.Files|Where-Object {$_.Path.Replace('\','/') -eq 'OptiShadeData/dependency-state.ini'}){$entry.Hash=HashFile $dependencyPointer}

        }

         &$Progress 'Verifying the completed installation...' 5 6

         $manifest.Files=@($manifest.Files|Where-Object {-not $_.RetireLoader})

        $manifest.Status='Installed'
        if($unrestoredOriginalFiles.Count){$manifest|Add-Member -NotePropertyName UnrestoredOriginalFiles -NotePropertyValue @($unrestoredOriginalFiles|Select-Object -Unique) -Force}
        WriteState $manifest $mp

    }catch{

        $failure=$_

        foreach($entry in $rollback){$dest=OwnedPath $Game $entry.Path;if($entry.Hash){Copy-Item -LiteralPath $entry.Copy -Destination $dest -Force}else{if(Test-Path -LiteralPath $dest){Remove-Item -LiteralPath $dest -Force}}}

        if($oldJson){$oldJson|Set-Content -LiteralPath $mp -Encoding UTF8}else{Remove-Item -LiteralPath $mp -Force}

        throw $failure

    }

     &$Progress 'Finishing cleanup and validating saved files...' 6 6

     foreach($entry in $rollback){if(Test-Path -LiteralPath $entry.Copy){Remove-Item -LiteralPath $entry.Copy -Force}}

    Remove-Item -LiteralPath $rollbackFolder

    RemoveUnreferencedBackups $manifest $folder

    RemoveCompletedInstallTransactionBackups $manifest $folder

    # An optional installation failure must not misreport a successful core install.

    if($old -and ($old.SourceMfg -or $old.OptionalMfg -or $old.Sm86Mfg -or $old.FrameGenerationRoute -eq 'portable-fsr2x') -and (Test-Path -LiteralPath "$PSScriptRoot/mfg.ps1")){

        try{

            . "$PSScriptRoot/mfg.ps1"

            $gpuNames=GetOptiShadeGpuFacts

            $null=EnsureAutomaticMfg $mp $Payload $gpuNames

        }catch{Write-Warning ('Automatic MFG setup unavailable: '+$_.Exception.Message)}

    }

    $mp

 }finally{ExitOptiShadeMutation $storeMutation}
}

function RemoveRecordedOptiShadeLoaders($Manifest,[string]$ManifestPath){

    # Identify our loader by the recorded payload hash, never just a proxy filename.

    $coreLoaderHashes=@($Manifest.Files|Where-Object {$_.SourcePath -eq 'winmm.dll' -and $_.Hash}|ForEach-Object Hash)
    $optionalMfgHashes=@()

    # Older optional MFG installs used version.dll. A user may have moved that

    # exact recorded provider to dinput8.dll to resolve a loader conflict.

    # Only its immutable ownership hash authorises removing a renamed copy.

    if($Manifest.OptionalMfg){

        $optionalMfgHashes+=@($Manifest.Files|Where-Object {$_.Path -in (GetOptiShadeMfgLoaderAliases) -and -not $_.Mutable -and $_.SourcePath -ne 'winmm.dll' -and $_.Hash -eq 'E9CA3587854EEB723E0579F7DDF6CFB1E6CF4BED79B0D75BC716003ED98FE040'}|ForEach-Object Hash)

    }

    if(-not $coreLoaderHashes.Count -and -not $optionalMfgHashes.Count -and -not $Manifest.Sm86Mfg){return}

    # A prior install or manual route switch can leave a duplicate loader
    # under another supported alias. Remove only byte-identical OptiShade
    # core loaders recorded by this receipt; never remove a DLL by name alone.
    $loaderNames=@('dbghelp.dll','OptiScaler.dll','dxgi.dll','d3d12.dll','version.dll',
                   'd3d9.dll','opengl32.dll','winmm.dll','wininet.dll','winhttp.dll')

    # Optional provider proxies may be moved between known aliases by the user,

    # so retain their historical hash-based alias cleanup. The SM86 provider is

    # hosted below OptiShadeData and must only be removed at its recorded path.

    if($Manifest.OptionalMfg){$loaderNames+=@(GetOptiShadeMfgLoaderAliases)}

    if($Manifest.Sm86Mfg -and $Manifest.Sm86MfgLoader){$loaderNames+=,[string]$Manifest.Sm86MfgLoader}

    foreach($name in $loaderNames|Select-Object -Unique){

        $file=OwnedPath $Manifest.Game ([string]$name)

        $hash=HashFile $file

        $ownedHashes=@($coreLoaderHashes)

        # Optional proxy MFG may be moved among its verified loader aliases.

        if($Manifest.OptionalMfg -and $name -in (GetOptiShadeMfgLoaderAliases)){$ownedHashes+=@($optionalMfgHashes)}

        # The hosted SM86 provider has a private engine path. Never treat its
        # hash as authority to delete a same-byte file at an unrelated alias.

        if($Manifest.Sm86Mfg -and $name -ieq [string]$Manifest.Sm86MfgLoader){
            $ownedHashes+=@($Manifest.Files|Where-Object {$_.Path -ieq $Manifest.Sm86MfgLoader -and $_.Component -eq 'Mfg' -and -not $_.Mutable}|ForEach-Object Hash)
        }

        if($hash -and $hash -in $ownedHashes){

            AssertClosed $Manifest.Game

            Remove-Item -LiteralPath $file -Force

            if(Test-Path -LiteralPath $file){throw ('OptiShade loader is still present: '+$file)}

        }

    }

}

function GetShaderRecoveryRoot { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'OptiShade-Recovery' }

function SaveOptiShadeRecoveryFiles([string]$Game,[object[]]$Entries,[string]$Label){
 $items=@($Entries|Where-Object {$_.Path -and $_.Hash}|Group-Object {([string]$_.Path).Replace('\','/')}|ForEach-Object {$_.Group[0]})
 if(-not $items.Count){return ''}
 $root=Join-Path (GetShaderRecoveryRoot) ($Label+'-'+[guid]::NewGuid().ToString('N'))
 [void][IO.Directory]::CreateDirectory($root)
 foreach($entry in $items){
  $source=OwnedPath $Game ([string]$entry.Path)
  $current=HashFile $source
  if($current -cne [string]$entry.Hash){throw ('Recovery stopped because an owned file changed during the operation: '+[string]$entry.Path)}
  $copy=Join-Path $root ([string]$entry.Path)
  [void][IO.Directory]::CreateDirectory((Split-Path $copy))
  [IO.File]::Copy((OptiShadeIoPath $source),(OptiShadeIoPath $copy),$false)
  if((HashFile $copy) -cne [string]$entry.Hash){throw ('OptiShade recovery copy failed verification: '+[string]$entry.Path)}
 }
 return $root
}

function TestLegacyMutableReShadeLog($Manifest,$Entry,[string]$File){

    # Migrate only the old root-log receipt shapes. This is not a generic

    # extension-based exception: unknown receipts and all DLL hashes still fail.

    if($Entry.Path -cne 'ReShade.log' -or $Entry.Mutable -or $Manifest.Status -notin @('Installed','Installing')){return $false}

    if($Manifest.Version -notmatch '^P0\.(?:20(?:\.\d{1,2})?(?:-MSFS24)?|21(?:\.[1-3])?(?:-beta\.[1-4])?(?:-MSFS24)?)$'){return $false}

    if(@($Manifest.Files|Where-Object Path -eq 'ReShade.log').Count -ne 1){return $false}

    if(-not @($Manifest.Files|Where-Object {$_.SourcePath -eq 'winmm.dll' -and $_.Hash -match '^[A-Fa-f0-9]{64}$'}).Count){return $false}

    $packaged=$Entry.SourcePath -ceq 'ReShade.log' -and $Entry.Hash -match '^[A-Fa-f0-9]{64}$'

    $displaced=-not $Entry.SourcePath -and -not $Entry.Hash -and $Entry.Backup -and $Entry.PreviousHash -match '^[A-Fa-f0-9]{64}$'

    if(-not($packaged -or $displaced)){return $false}

    # Confirm this is recognisable ReShade output, never arbitrary changed data.

    # Read a bounded header even when a long session has produced a large log.

    $stream=[IO.File]::OpenRead($File)

    try{$bytes=New-Object byte[] 65536;$length=$stream.Read($bytes,0,$bytes.Length);$header=[Text.Encoding]::UTF8.GetString($bytes,0,$length)}finally{$stream.Dispose()}

    return $header -match '(?m)^\d{2}:\d{2}:\d{2}:\d{3}\s+\[\s*\d+\s*\]\s+\|\s*INFO\s*\|\s*Initializing ReShade version\s'

}

# Files created beside the EXE while OptiShade was installed are not in the receipt,
# so Restore and Uninstall used to leave them behind (owner report, 4 Nov 2026).
# Exact names beside the EXE only. A file that belongs to something still present
# stays: an add-on the player had before OptiShade comes back on Restore, with its
# logs and settings, and a player's own ReShade keeps its numbered configs.
function GetOptiShadeRuntimeLeftovers([string]$Game,[bool]$KeepSettings=$true){
 $found=@()
 $has={param($name) Test-Path -LiteralPath (Join-Path $Game $name) -PathType Leaf}
 $mfgGone=-not(& $has 'RTX40MFG.asi');$glassGone=-not(& $has 'glass-cockpit-dlss-fix.addon64');$atmosphereGone=-not(& $has 'AtmosphereMod.addon64')
 foreach($file in @(Get-ChildItem -LiteralPath $Game -File -Force -ErrorAction SilentlyContinue)){
  if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
  $name=$file.Name;$remove=$false
  if($name -match '^OptiScaler\.ini\.save-.*\.bak$' -or $name -ieq 'winmm.dll.optimfg-baseline-disabled'){$remove=$true}
  elseif($mfgGone -and $name -match '^RTX(40)?MFG(-Universal\.status\.json|-UI(-layout)?\.ini|-Universal\.json\.removed-.*\.bak|-.*\.(log|csv))$'){$remove=$true}
  elseif($glassGone -and $name -match '^glass-cockpit-dlss-fix(\.old)?\.log$'){$remove=$true}
  elseif($glassGone -and -not $KeepSettings -and $name -ieq 'glass-cockpit-dlss-fix.ini'){$remove=$true}
  elseif($atmosphereGone -and $name -ieq 'ReShade.ini.atmospheremod.bak'){$remove=$true}
  elseif($name -match '^ReShade[2-9]\.ini$' -and $file.Length -le 1MB){
   try{$remove=[IO.File]::ReadAllText($file.FullName).Contains('OptiShadeData')}catch{$remove=$false}
  }
  if($remove){$found+=$name}
 }
 return $found
}
# AtmosphereMod is outside the receipt. Only a copy OptiShade installed for this
# game is removed; one from the mod's own installer belongs to the player.
function RemoveOptiShadeOwnedAtmosphereMod([string]$Game){
 if(-not(Get-Command UninstallAtmosphereMod -CommandType Function -ErrorAction SilentlyContinue)){
  $module=Join-Path $PSScriptRoot 'atmosphere-mod.ps1'
  if(-not(Test-Path -LiteralPath $module -PathType Leaf)){return $false}
  . $module
 }
 $record=Join-Path (GetAtmosphereModDataFolder) 'install.json'
 if(-not(Test-Path -LiteralPath $record -PathType Leaf)){return $false}
 $saved=Get-Content -LiteralPath $record -Raw|ConvertFrom-Json
 if([string]$saved.installedBy -cne 'OptiShade' -or -not(TestAtmosphereModSameFolder ([string]$saved.sim) $Game)){return $false}
 $null=UninstallAtmosphereMod $Game $null
 return $true
}
# Never fails a Restore or Uninstall: the game has already been put back.
function RemoveOptiShadeRuntimeLeftovers([string]$Game,[bool]$KeepSettings=$true){
 $note={param($text) if(Get-Command WriteInstallerLog -ErrorAction SilentlyContinue){WriteInstallerLog $text}}
 try{if(RemoveOptiShadeOwnedAtmosphereMod $Game){& $note ('Restore removed AtmosphereMod from '+$Game+'; its tunables.ini is kept in OptiShade backups')}}catch{& $note ('Restore could not remove AtmosphereMod: '+$_.Exception.Message)}
 $removed=@()
 foreach($name in @(GetOptiShadeRuntimeLeftovers $Game $KeepSettings)){
  try{Remove-Item -LiteralPath (OwnedPath $Game $name) -Force -ErrorAction Stop;$removed+=$name}catch{& $note ('Restore could not remove '+$name+': '+$_.Exception.Message)}
 }
 # Folders only OptiShade makes here; never removed while anything is inside them.
 foreach($folder in @('host64','OptiScaler')){
  $path=Join-Path $Game $folder
  if(-not(Test-Path -LiteralPath $path -PathType Container)){continue}
  try{
   $item=Get-Item -LiteralPath $path -Force
   if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
   if(@(Get-ChildItem -LiteralPath $path -File -Recurse -Force -ErrorAction Stop).Count){continue}
   if(@(Get-ChildItem -LiteralPath $path -Directory -Recurse -Force -ErrorAction Stop|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){continue}
   Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop;$removed+=($folder+'\')
  }catch{& $note ('Restore could not remove the empty '+$folder+' folder: '+$_.Exception.Message)}
 }
 if($removed.Count){& $note ('Restore removed leftovers from '+$Game+': '+($removed -join ', '))}
 return $removed
}
function RestoreFusion([string]$ManifestPath,[bool]$KeepPresets=$true,[scriptblock]$Progress={param($detail,$completed=0,$total=0)}){
 $storeMutation=EnterOptiShadeMutation -ManifestPath $ManifestPath
 try{

    [void](RecoverOptiShadeRouteTransaction $ManifestPath)

    $report={param([string]$detail,[int]$value) if($Progress){$Progress.Invoke($detail,$value,100)}}.GetNewClosure()

    & $report 'Checking recorded game files...' 0

    $m=ReadOptiShadeState $ManifestPath

    CleanModBackupReferences $m (Split-Path $ManifestPath)

    $staleOptiShadeBackups=RemoveLegacyOptiShadeOrphanBackupReferences $m

    if($staleOptiShadeBackups){Write-Warning "Discarding $staleOptiShadeBackups legacy OptiShade runtime backup record(s); uninstall will remove those files instead of restoring an older build."}

    if($m.Status -eq 'Restored'){

        & $report 'This game is already restored. Checking any remaining OptiShade files...' 10

        AssertClosed $m.Game

        RemoveRecordedOptiShadeLoaders $m $ManifestPath

        # A diagnostic viewer may keep a harmless OptiShade log open after
        # the game loaders have already been restored. Retry only the exact
        # log paths recorded by the earlier restore; never sweep game files.
        $remainingDeferredLogs=@()
        foreach($relativeLog in @($m.DeferredCleanupPaths)){
            if(-not $relativeLog -or [IO.Path]::GetExtension([string]$relativeLog) -ine '.log'){continue}
            $deferredLog=OwnedPath $m.Game ([string]$relativeLog)
            if(Test-Path -LiteralPath $deferredLog -PathType Leaf){
                try{Remove-Item -LiteralPath $deferredLog -Force -ErrorAction Stop}catch{$remainingDeferredLogs+=([string]$relativeLog)}
            }
        }
        $m.DeferredCleanupPaths=@($remainingDeferredLogs|Select-Object -Unique)
        $deferredData=OwnedPath $m.Game 'OptiShadeData'
        if((Test-Path -LiteralPath $deferredData -PathType Container) -and -not (Get-ChildItem -LiteralPath $deferredData -Force)){Remove-Item -LiteralPath $deferredData}
        WriteState $m $ManifestPath
        if($remainingDeferredLogs.Count){Write-Warning ('OptiShade loaders are removed. Close the log viewer and retry cleanup for: '+($remainingDeferredLogs -join ', '))}

        if(-not $KeepPresets){

            AssertClosed $m.Game;$presets=OwnedPath $m.Game 'OptiShadeData/Presets'

            if(Test-Path -LiteralPath $presets){

                if(Get-ChildItem -LiteralPath $presets -Force -Recurse|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}){throw 'Linked preset files were left untouched.'}

                Get-ChildItem -LiteralPath $presets -Filter '*.ini' -File -Recurse | Remove-Item -Force

                Get-ChildItem -LiteralPath $presets -Directory -Recurse | Sort-Object {$_.FullName.Length} -Descending | ForEach-Object {if(-not(Get-ChildItem -LiteralPath $_.FullName -Force)){Remove-Item -LiteralPath $_.FullName}}

                if(-not(Get-ChildItem -LiteralPath $presets -Force)){Remove-Item -LiteralPath $presets}

                $data=OwnedPath $m.Game 'OptiShadeData';if(-not(Get-ChildItem -LiteralPath $data -Force)){Remove-Item -LiteralPath $data}

            }

        }

        & $report 'Restore complete.' 100

        return

    }

    AssertClosed $m.Game;$folder=Split-Path $ManifestPath

    $checkFiles=@($m.Files|ForEach-Object {OwnedPath $m.Game $_.Path})

    foreach($relative in $m.OwnedDirectories){$dir=OwnedPath $m.Game $relative;if(Test-Path -LiteralPath $dir){$checkFiles+=@(Get-ChildItem -LiteralPath $dir -File -Recurse -Force|ForEach-Object FullName)}}

    $uniqueCheckFiles=@($checkFiles|Select-Object -Unique);$checkIndex=0;$deferredCleanupPaths=@()
    $optishadeDataRoot=OwnedPath $m.Game 'OptiShadeData'
    $optishadeDataPrefix=$optishadeDataRoot.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar

    foreach($file in $uniqueCheckFiles){$checkIndex++;& $report ('Checking game file '+$checkIndex+' of '+$uniqueCheckFiles.Count+'...') (5+[int](12*$checkIndex/[Math]::Max(1,$uniqueCheckFiles.Count)));if(Test-Path -LiteralPath $file -PathType Leaf){

        try{$handle=[IO.File]::Open($file,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$handle.Dispose()}

        catch{
            $isOptiShadeLog=$file.StartsWith($optishadeDataPrefix,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetExtension($file) -ieq '.log'
            if($isOptiShadeLog){$deferredCleanupPaths+=($file.Substring($m.Game.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar).Length).TrimStart([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar).Replace('\','/'));continue}
            if(TestOptiShadeAccessDenied $_){throw ('Restore has not changed any files. Windows does not let OptiShade change files in this folder: '+$file+'. '+$script:OptiShadeProtectedFolderHelp)}
            throw ('Restore has not changed any files. Close the game and any log viewers, then retry. File is in use: '+$file)
        }

    }}

    $changedShaders=@();$changedLogs=@();$changedOwnedFiles=@();$unavailablePresetBackups=@();$unavailableOriginalFiles=@()

    $verifyIndex=0

    foreach($f in $m.Files){

        $verifyIndex++;& $report ('Verifying installation record '+$verifyIndex+' of '+$m.Files.Count+'...') (18+[int](18*$verifyIndex/[Math]::Max(1,$m.Files.Count)))

        $dest=OwnedPath $m.Game $f.Path;$actual=HashFile $dest

        # Older manifests incorrectly classified the installer-maintained FX receipt as immutable.

        $mutable=TestOptiShadeMutableFile $f.Path

        if($actual -and -not $mutable -and $actual -ne $f.Hash -and $actual -ne $f.PreviousHash){

            if(TestLegacyMutableReShadeLog $m $f $dest){

                $changedLogs+=@{Path=$f.Path;Hash=$actual}

            }elseif($f.Path -match '^OptiShadeData[\\/]Shaders[\\/].+\.(fx|fxh|h|hlsl)$'){

                $changedShaders+=@{Path=$f.Path;Hash=$actual}

            }elseif(TestOptiShadeRecoverableOwnedFile $f.Path){

                # A changed immutable path in the validated receipt is still
                # removable. Preserve its current bytes before restoring the
                # original backup or removing an app-created file.
                $changedOwnedFiles+=@{Path=$f.Path;Hash=$actual}

            }else{throw "A file changed after installation: $($f.Path). Restore stopped before changing anything."}

        }

        if($f.PreviousHash){
            $backupHash=if($f.Backup){HashFile (OwnedPath $folder $f.Backup)}else{''}
            if($backupHash -cne [string]$f.PreviousHash -and $actual -cne [string]$f.PreviousHash){
                if(TestOptiShadePresetIniPath $f.Path){$unavailablePresetBackups+=([string]$f.Path)}
                else{$unavailableOriginalFiles+=([string]$f.Path)}
            }
        }

    }

    foreach($relative in $m.OwnedDirectories){

        $dir=OwnedPath $m.Game $relative

        if(Test-Path -LiteralPath $dir){if(Get-ChildItem -LiteralPath $dir -Force -Recurse|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}){throw 'A linked item was found in OptiShade data. Cleanup stopped.'}}

    }

    & $report 'Preserving recoverable logs and edited shaders...' 40

    # A legacy log exception is allowed only after a full verified preservation

    # copy succeeds. Keep it outside the app store so Uninstall cannot delete it.

    if($changedLogs.Count){

        $recovery=OwnedPath (GetShaderRecoveryRoot) ('Logs-'+[guid]::NewGuid().ToString('N'))

        foreach($log in $changedLogs){

            $copy=OwnedPath $recovery $log.Path

            New-Item -ItemType Directory -Path (Split-Path $copy) -Force|Out-Null

            [IO.File]::Copy((OwnedPath $m.Game $log.Path),$copy,$false)

            if((HashFile $copy) -ne $log.Hash){throw 'Log recovery copy failed verification. Game files have not been removed.'}

        }

        $m|Add-Member -NotePropertyName RecoveredLogs -NotePropertyValue $recovery -Force

        WriteState $m $ManifestPath

        Write-Warning ('Changed legacy ReShade log was preserved in: '+$recovery)

    }

    # Preserve edited, manifest-owned shader sources outside the game before cleanup.

    # Do not extend this exception to loaders or other executable content.

    if($changedShaders.Count){

        $recovery=OwnedPath (GetShaderRecoveryRoot) ('Shaders-'+[guid]::NewGuid().ToString('N'))

        foreach($shader in $changedShaders){

            $copy=OwnedPath $recovery $shader.Path

            New-Item -ItemType Directory -Path (Split-Path $copy) -Force|Out-Null

            [IO.File]::Copy((OwnedPath $m.Game $shader.Path),$copy,$false)

            if((HashFile $copy) -ne $shader.Hash){throw 'Changed shader recovery copy failed verification. Game files have not been removed.'}

        }

        $m|Add-Member -NotePropertyName RecoveredShaders -NotePropertyValue $recovery -Force

        WriteState $m $ManifestPath

        Write-Warning ('Changed shader sources were preserved in: '+$recovery)

    }

    # Any immutable receipt-owned file can be changed by a component update.
    # Keep those current bytes outside the game before restoring or removing.
    if($changedOwnedFiles.Count){
        $recovery=SaveOptiShadeRecoveryFiles $m.Game $changedOwnedFiles 'RestoreFiles'
        $m|Add-Member -NotePropertyName RecoveredChangedFiles -NotePropertyValue $recovery -Force
        WriteState $m $ManifestPath
        Write-Warning ('Changed OptiShade-owned files were preserved in: '+$recovery)
    }

    # Preserve bounded evidence outside game files before cleanup. Diagnostics must never block recovery.

    try{

        if(-not(Get-Command SavePreRestoreEvidence -ErrorAction SilentlyContinue)){. "$PSScriptRoot/diagnostics.ps1"}

        & $report 'Saving restore diagnostics...' 46

        SavePreRestoreEvidence $m.Game $folder

    }catch{Write-Warning 'Could not preserve pre-restore diagnostics. Restore will continue.'}

    $presets=OwnedPath $m.Game 'OptiShadeData/Presets'

    $restoreIndex=0;$restoreTotal=[Math]::Max(1,$m.Files.Count)

    foreach($f in $m.Files){

        $restoreIndex++;& $report ('Restoring game file '+$restoreIndex+' of '+$m.Files.Count+'...') (50+[int](31*$restoreIndex/$restoreTotal))

        $dest=OwnedPath $m.Game $f.Path

        if($f.Path -in $deferredCleanupPaths){continue}

        if($KeepPresets -and (TestOptiShadePresetIniPath $f.Path)){continue}

        $backup=if($f.Backup){OwnedPath $folder $f.Backup}else{''}
        $backupValid=$backup -and (HashFile $backup) -ceq [string]$f.PreviousHash
        if($backupValid){Copy-Item -LiteralPath $backup -Destination $dest -Force}
        elseif($f.PreviousHash -and (HashFile $dest) -ceq [string]$f.PreviousHash){continue}
        elseif($f.PreviousHash){
            if(Test-Path -LiteralPath $dest){Remove-Item -LiteralPath $dest -Force}
            if(-not(TestOptiShadePresetIniPath $f.Path)){$unavailableOriginalFiles+=([string]$f.Path)}
        }elseif(Test-Path -LiteralPath $dest){Remove-Item -LiteralPath $dest -Force}

    }

    $restoredPaths=@($m.Files|Where-Object Backup|ForEach-Object {OwnedPath $m.Game $_.Path})
    $restoredPaths+=@($m.Files|Where-Object {$_.PreviousHash -and (HashFile (OwnedPath $m.Game $_.Path)) -ceq [string]$_.PreviousHash}|ForEach-Object {OwnedPath $m.Game $_.Path})
    $restoredPaths=@($restoredPaths|Select-Object -Unique)

    $directoryIndex=0;$directoryTotal=[Math]::Max(1,$m.OwnedDirectories.Count)

    foreach($relative in $m.OwnedDirectories){$dir=OwnedPath $m.Game $relative;if(Test-Path -LiteralPath $dir){

        $directoryIndex++;& $report ('Cleaning OptiShade data '+$directoryIndex+' of '+$m.OwnedDirectories.Count+'...') (82+[int](9*$directoryIndex/$directoryTotal))

        Get-ChildItem -LiteralPath $dir -Force -Recurse -File | Where-Object {$_.FullName -notin $restoredPaths -and $_.FullName -notin @($deferredCleanupPaths|ForEach-Object {OwnedPath $m.Game $_}) -and -not($KeepPresets -and $_.FullName.StartsWith($presets+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -and $_.Extension -eq '.ini')} | Remove-Item -Force

        Get-ChildItem -LiteralPath $dir -Force -Recurse -Directory | Sort-Object {$_.FullName.Length} -Descending | ForEach-Object {if(-not(Get-ChildItem -LiteralPath $_.FullName -Force)){Remove-Item -LiteralPath $_.FullName}}

        if(-not(Get-ChildItem -LiteralPath $dir -Force)){Remove-Item -LiteralPath $dir}

    }}

    & $report 'Removing recorded OptiShade loaders...' 92

    RemoveRecordedOptiShadeLoaders $m $ManifestPath

    $verifyIndex=0

    foreach($f in $m.Files){

        $verifyIndex++;& $report ('Verifying restored files '+$verifyIndex+' of '+$m.Files.Count+'...') (94+[int](5*$verifyIndex/[Math]::Max(1,$m.Files.Count)))

        $dest=OwnedPath $m.Game $f.Path

        if($KeepPresets -and $dest.StartsWith($presets+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetExtension($dest) -eq '.ini'){continue}

        if($f.PreviousHash -and (HashFile $dest) -ceq [string]$f.PreviousHash){continue}
        if($f.Path -in $unavailableOriginalFiles){if(Test-Path -LiteralPath $dest){throw ('Unrestorable OptiShade file was not removed: '+$f.Path)};continue}

        $ours=@($m.Files|Where-Object {$_.SourcePath -eq 'winmm.dll'}|ForEach-Object Hash)

        if($f.Backup -and $f.PreviousHash -notin $ours){

            if((HashFile (OwnedPath $folder $f.Backup)) -ne $f.PreviousHash -and (TestOptiShadePresetIniPath $f.Path)){

                if(Test-Path -LiteralPath $dest){throw ('Unrecoverable preset was not removed: '+$f.Path)}

                continue

            }

            if((HashFile $dest) -ne $f.PreviousHash){throw ('Restored file verification failed: '+$f.Path)}

        }

        elseif(Test-Path -LiteralPath $dest){
            if($f.Path -in $deferredCleanupPaths -and [IO.Path]::GetExtension($dest) -ieq '.log'){continue}
            throw ('Removal verification failed: '+$f.Path)
        }

    }

    $m.Status='Restored'

    $m|Add-Member -NotePropertyName DeferredCleanupPaths -NotePropertyValue @($deferredCleanupPaths|Select-Object -Unique) -Force

    if($unavailablePresetBackups.Count){$m|Add-Member -NotePropertyName RestoreWarnings -NotePropertyValue @($unavailablePresetBackups|Select-Object -Unique) -Force}
    if($unavailableOriginalFiles.Count){$m|Add-Member -NotePropertyName UnrestoredOriginalFiles -NotePropertyValue @($unavailableOriginalFiles|Select-Object -Unique) -Force}

    WriteState $m $ManifestPath;RemoveUnreferencedBackups $m $folder
    $null=RemoveOptiShadeRuntimeLeftovers $m.Game $KeepPresets
    if($deferredCleanupPaths.Count){Write-Warning ('OptiShade loaders are restored. Locked diagnostic log(s) remain temporarily and will be retried on the next cleanup: '+($deferredCleanupPaths -join ', '))}
    & $report 'Restore complete.' 100

 }finally{ExitOptiShadeMutation $storeMutation}
}

function FindNrRuntime([string]$Installer){

    # Only inspect known locations; never crawl drives for DLLs.

    $candidates=@((Join-Path (Split-Path $Installer) 'nvngx_dlssnr.dll'),(Join-Path ([Environment]::GetFolderPath('Desktop')) 'DLSS5Installer/DLSS5Resources/Payload/Common/nvngx_dlssnr.dll'))

    $cards=@(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue|ForEach-Object Name)

    foreach($candidate in $candidates){$hash=HashFile $candidate

        if($hash -eq 'E16BCF15E16E13F527491CDF7845B2FE6521A738D8F7C9C721866A8496E1FC8E' -and ($cards -match 'RTX\s*50')){return $candidate}

        if($hash -eq '2BC19BC09A7B89DD44F73E2AC0108FCC586E2154BDD0830F242F4F040E28789F' -and ($cards -match 'RTX\s*50')){return $candidate}

        if($hash -eq 'E67DEE209320CDAFE0E93E45675D7AA34323A53ACC57A72B2E40A181581C989A' -and ($cards -match 'RTX\s*[2345]0')){return $candidate}

    }

    return $null

}

function ImportNrRuntime([string]$ManifestPath,[string]$Source,[string]$Variant="auto",$Gpu=$null){
 $storeMutation=EnterOptiShadeMutation -ManifestPath $ManifestPath
 try{
 [void](RecoverOptiShadeRouteTransaction $ManifestPath)
 $m=ReadOptiShadeState $ManifestPath
 if($m.Status -ne 'Installed'){throw 'Install OptiShade into a game first.'}
 AssertClosed $m.Game;AssertAntiCheatMutation $m.Game $m.LaunchExe 'Import Neural runtime'
 # Neural import has already selected a measured NVIDIA adapter and verified
 # the pinned model hash. It does not need to read the protected game image;
 # use only the installed x64 record when Xbox/Store denies that read, keeping
 # the PE hash and renderer/API evidence explicitly unknown.
 $beforeReceiptHash=HashFile $ManifestPath;$identity=GetOptiShadeRenderingExecutable $m -AllowRecordedUnknown
 $hash=HashFile $Source
 if(-not $Gpu){$Gpu=GetOptiShadeGpuFacts}
 $candidate=ResolveOptiShadeNeuralAdapter $m $Gpu
 if($candidate.State -ne 'candidate'){throw ('A measured rendering-adapter candidate is required before importing an architecture-specific model: '+$candidate.Reason)}
 $model=GetOptiShadeNeuralModelByHash $hash
 if(-not $model){throw 'The DLL hash is not in the local NR runtime catalogue. The game was not changed.'}
 if($Variant -cne $model.Variant){throw 'Select the matching NR runtime variant before importing this pinned DLL. The game was not changed.'}
 if([int]$candidate.Adapter.Family -notin $model.Families){throw 'This pinned NR model does not support the measured adapter architecture. The game was not changed.'}
 if($model.Signed -and (Get-AuthenticodeSignature -LiteralPath $Source).Status -ne 'Valid'){throw 'NVIDIA runtime signature verification failed.'}
 $adapter=$candidate.Adapter
 # Bounded local preparation evidence, owned by this same model transaction.
 # The runtime hashes its actual selected model and executable independently;
 # this candidate LUID never substitutes for the live rendering device.
 $preparation=[ordered]@{schema=1;modelSha256=$hash;variant=$Variant;executable=[IO.Path]::GetFileName($identity.Path);executableSha256=$identity.SHA256;architecture=$identity.Architecture;adapter=[ordered]@{luid=[string]$adapter.Luid;vendorId=[uint32]$adapter.VendorId;deviceId=[uint32]$adapter.DeviceId;computeMajor=[int]$adapter.ComputeMajor;computeMinor=[int]$adapter.ComputeMinor;family=[int]$adapter.Family};evidence='inventory_candidate'}
 $receiptBytes=[Text.UTF8Encoding]::new($false).GetBytes(($preparation|ConvertTo-Json -Depth 8))
 $sha=[Security.Cryptography.SHA256]::Create();try{$receiptHash=[BitConverter]::ToString($sha.ComputeHash($receiptBytes)).Replace('-','')}finally{$sha.Dispose()}
 $rollbackRelative='MfgRollback/'+[guid]::NewGuid().ToString('N');$changes=@()
 foreach($item in @([pscustomobject]@{Path='nvngx_dlssnr.dll';Hash=$hash;Source=$Source;Bytes=$null},[pscustomobject]@{Path='OptiShadeData/Neural-runtime.json';Hash=$receiptHash;Source='';Bytes=$receiptBytes})){
  $dest=OwnedPath $m.Game $item.Path;$old=[string](HashFile $dest)
  if((Test-Path -LiteralPath $dest) -and -not(Test-Path -LiteralPath $dest -PathType Leaf)){throw ('Neural preparation target is not a regular file: '+$item.Path)}
  $existing=@($m.Files|Where-Object {([string]$_.Path).Replace('\','/') -ieq $item.Path})
  if($existing.Count -gt 1){throw ('Neural ownership is ambiguous: '+$item.Path+'. Existing files were retained.')}
  if($old -and $existing.Count -eq 1 -and $old -cne [string]$existing[0].Hash){throw ('The installed neural file changed outside OptiShade: '+$item.Path+'. Existing files were retained.')}
  if($old -and -not $existing.Count -and $item.Path -ne 'nvngx_dlssnr.dll'){throw 'An unowned Neural-runtime.json is present. Existing files were retained.'}
  # Already owned model bytes need no second large rollback copy. The bounded
  # receipt is always in the journal, including a same-model identity refresh.
  $changeRequired=$old -cne [string]$item.Hash -or -not $existing.Count -or $item.Path -ne 'nvngx_dlssnr.dll'
  if($existing.Count){$entry=$existing[0];$entry.Hash=$item.Hash}
  else{
   $entry=[pscustomobject]@{Path=$item.Path;Hash=$item.Hash;PreviousHash=$old;Backup=$(if($old){$rollbackRelative+'/before-'+$changes.Count}else{''});Mutable=$false}
   $m.Files=@($m.Files)+@($entry)
  }
  $entry|Add-Member Component 'Neural' -Force;$entry|Add-Member Retained $true -Force
  if($changeRequired){
   if($item.Bytes){$changes+=[pscustomobject]@{Path=$item.Path;BeforeHash=$old;Bytes=[byte[]]$item.Bytes}}
   else{$changes+=[pscustomobject]@{Path=$item.Path;BeforeHash=$old;Source=$Source;AfterHash=$hash}}
  }
 }
 $m|Add-Member NeuralAdapter (GetOptiShadeAdapterReceipt $adapter) -Force
 $m|Add-Member NeuralRuntimeVariant $Variant -Force;$m|Add-Member NeuralRuntimeHash $hash -Force
 $m|Add-Member NeuralPreparation ([pscustomobject]@{Schema=1;Path='OptiShadeData/Neural-runtime.json';Hash=$receiptHash;ExecutableHash=$identity.SHA256;Evidence='installation_only'}) -Force
 # One durable operation includes model, narrow identity and canonical receipt.
 # Process termination is recovered by the same owner before the next mutation.
 InvokeOptiShadeRouteTransaction $ManifestPath $beforeReceiptHash $m $changes $rollbackRelative 'Neural model preparation'
 }finally{ExitOptiShadeMutation $storeMutation}
}

function RemoveMissingOptiShadeInstallRecord([string]$StateRoot,[string]$Game,[switch]$MutationHeld){
    # Explicit removal of an already-uninstalled game must discard only its
    # app-owned receipt/backups. RestoreFusion must not recreate original game
    # files below a path that the game manager has already removed.
    $storeMutation=$null;if(-not $MutationHeld){$storeMutation=EnterOptiShadeMutation -StateRoot $StateRoot}
    try{
        $root=FullPath $StateRoot;$gamePath=ResolveOptiShadeLibraryPath $Game
        if(-not(Test-Path -LiteralPath $root -PathType Container)){throw 'The OptiShade data folder is unavailable. No installation record was removed.'}
        $volume=[IO.Path]::GetPathRoot($gamePath)
        if(-not $volume){throw 'The game path has no usable drive root. Its OptiShade record was kept.'}
        try{$volumeItem=Get-Item -LiteralPath $volume -Force -ErrorAction Stop;if(-not $volumeItem.PSIsContainer){throw 'The game drive root is not a folder.'}}
        catch{throw ('The drive for '+$gamePath+' is unavailable. Reconnect it before removing this game entry.')}
        $gamePathExists=$false
        try{$null=Get-Item -LiteralPath $gamePath -Force -ErrorAction Stop;$gamePathExists=$true}
        catch [System.Management.Automation.ItemNotFoundException]{}
        catch{throw ('The game path could not be checked safely. No OptiShade records were removed: '+$_.Exception.Message)}
        if($gamePathExists){throw 'The game folder exists. Use Restore so original files can be returned safely.'}
        $parent=Split-Path $gamePath -Parent;$leaf=Split-Path $gamePath -Leaf
        $probe=$parent;$parentInfo=$null
        while($probe){
            try{$parentInfo=Get-Item -LiteralPath $probe -Force -ErrorAction Stop;break}
            catch [System.Management.Automation.ItemNotFoundException]{$next=Split-Path $probe -Parent;if(-not $next -or $next -ceq $probe){break};$probe=$next}
            catch{throw ('The parent folder for '+$gamePath+' cannot be accessed. Reconnect the game drive or restore access before removing this entry.')}
        }
        if(-not $parentInfo -or -not $parentInfo.PSIsContainer){throw ('The parent folder for '+$gamePath+' cannot be verified. No OptiShade records were removed.')}
        $check=$probe
        while($check){
            $checkInfo=Get-Item -LiteralPath $check -Force -ErrorAction Stop
            if($checkInfo.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The missing game path is below a linked directory. Reconnect the original game location before removing its OptiShade record.'}
            $next=Split-Path $check -Parent;if(-not $next -or $next -ceq $check){break};$check=$next
        }
        if($probe -ieq $parent){$parentItems=@(Get-ChildItem -LiteralPath $parent -Force -ErrorAction Stop);if(@($parentItems|Where-Object {$_.Name -ieq $leaf}).Count){throw 'The game path is present or inaccessible. No OptiShade files were changed.'}}
        if(-not(Get-Command GetFusionInstallationReceipts -CommandType Function -ErrorAction SilentlyContinue)){. "$PSScriptRoot/library.ps1"}
        $expected=FullPath (ManifestPath $root $gamePath)
        $records=@(GetFusionInstallationReceipts $root $gamePath -Strict)
        if($records.Count -ne 1 -or (FullPath $records[0].FullName) -ine $expected){throw 'A single canonical OptiShade installation record could not be verified. Nothing was removed.'}
        $manifest=ReadOptiShadeState $expected
        if((ResolveOptiShadeLibraryPath ([string]$manifest.Game)) -ine $gamePath){throw 'The OptiShade record points to a different game path. Nothing was removed.'}
        if($manifest.Status -cne 'Installed'){throw 'This installation is incomplete or already restoring. Reconnect the game folder and use Repair or Restore first.'}
        if(GetOptiShadeRouteRecovery $expected){throw 'An unfinished OptiShade file transaction needs recovery. Reconnect the game folder before removing this entry.'}
        AssertClosed $gamePath
        $recordFolder=FullPath (Split-Path $expected -Parent);$gamesRoot=FullPath (Join-Path $root 'Games')
        if(-not $recordFolder.StartsWith($gamesRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $recordFolder -Leaf) -notmatch '^[a-fA-F0-9]{16}$'){
            throw 'The OptiShade record is outside the canonical per-game data folder. Nothing was removed.'
        }
        if((Get-Item -LiteralPath $recordFolder -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The OptiShade game record is linked. Nothing was removed.'}
        if(Get-ChildItem -LiteralPath $recordFolder -Force -Recurse -ErrorAction Stop|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}){throw 'A linked file exists in the OptiShade game record. Nothing was removed.'}
        $gamePathExists=$false
        try{$null=Get-Item -LiteralPath $gamePath -Force -ErrorAction Stop;$gamePathExists=$true}
        catch [System.Management.Automation.ItemNotFoundException]{}
        catch{throw ('The game path could not be rechecked safely: '+$_.Exception.Message)}
        if($gamePathExists){throw 'The game folder reappeared during removal. No OptiShade records were changed.'}
        $trashRoot=Join-Path $root 'RemovedGameRecords';[void][IO.Directory]::CreateDirectory($trashRoot)
        if((Get-Item -LiteralPath $trashRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The OptiShade removal staging folder is linked. Nothing was removed.'}
        $staged=Join-Path $trashRoot ([guid]::NewGuid().ToString('N'))
        Move-Item -LiteralPath $recordFolder -Destination $staged -ErrorAction Stop
        try{
            Remove-Item -LiteralPath $staged -Recurse -Force -ErrorAction Stop
            if(Test-Path -LiteralPath $staged){throw 'The saved OptiShade installation record could not be fully removed.'}
        }catch{
            if((Test-Path -LiteralPath $staged) -and -not(Test-Path -LiteralPath $recordFolder)){Move-Item -LiteralPath $staged -Destination $recordFolder -ErrorAction Stop}
            throw
        }
        if((Test-Path -LiteralPath $gamesRoot -PathType Container) -and -not(Get-ChildItem -LiteralPath $gamesRoot -Force)){Remove-Item -LiteralPath $gamesRoot -Force}
        if((Test-Path -LiteralPath $trashRoot -PathType Container) -and -not(Get-ChildItem -LiteralPath $trashRoot -Force)){Remove-Item -LiteralPath $trashRoot -Force}
        return $true
    }finally{if(-not $MutationHeld){ExitOptiShadeMutation $storeMutation}}
}

function GetOptiShadeCleanupReceipts([string]$StateRoot){

    # Standalone ownership callers do not necessarily load the library module.
    # Reuse its canonical inventory; saved rollback receipts are recovery data,
    # never independent game installations or alternate ownership authority.
    if(-not(Get-Command GetFusionInstallationReceipts -CommandType Function -ErrorAction SilentlyContinue)){. "$PSScriptRoot/library.ps1"}

    $root=FullPath $StateRoot
    [void](OwnedPath $root 'Games/cleanup-check')
    $records=@(GetFusionInstallationReceipts $root -Strict|Sort-Object FullName)

    # Validate the entire inventory before either cleanup caller mutates files.
    # Do not filter by library visibility, receipt status or current drive
    # availability: doing so could delete the only backups for an offline game.
    foreach($record in $records){
        [void](OwnedPath $root $record.FullName.Substring($root.Length+1))
        $manifest=ReadOptiShadeState $record.FullName
        if((FullPath $record.FullName) -ine (FullPath (ManifestPath $root $manifest.Game))){throw 'The installation receipt changed its canonical game identity. Cleanup stopped before changing files.'}
        if(-not(Test-Path -LiteralPath (OptiShadeIoPath $manifest.Game) -PathType Container)){throw ('Recorded game folder is unavailable: '+$manifest.Game+'. Cleanup stopped before changing files. Ownership records and original backups are retained; reconnect the game drive or restore access to that folder, then retry.')}
        [void](OwnedPath $manifest.Game 'cleanup-check')
        AssertClosed $manifest.Game
        $record.Manifest=$manifest
    }
    return $records
}

function GetOptiShadeLiveManagerSessionDirectories([string]$StateRoot,[string[]]$RunningImagePaths){
    $root=FullPath $StateRoot;$sessionsRoot=FullPath (Join-Path $root 'Sessions');$prefix=$sessionsRoot+'\'
    $directories=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($image in @($RunningImagePaths)){
        if(-not $image){continue}
        try{$path=FullPath $image}catch{continue}
        if(-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){continue}
        $directory=Split-Path $path -Parent
        if((FullPath (Split-Path $directory -Parent)) -ceq $sessionsRoot){[void]$directories.Add((FullPath $directory))}
    }
    return @($directories)
}
function GetOptiShadeRunningImagePaths{
    $paths=[Collections.Generic.List[string]]::new()
    foreach($process in [Diagnostics.Process]::GetProcesses()){
        try{$path=[string]$process.MainModule.FileName;if($path){$paths.Add($path)}}catch{}
        finally{$process.Dispose()}
    }
    return @($paths.ToArray())
}
function UninstallFusion([string]$StateRoot,[string]$Installer,[string]$ActiveSession='',[bool]$KeepPresets=$true,[scriptblock]$Progress={param($detail,$completed=0,$total=0)},[string[]]$RunningImagePaths=$null){
 $storeMutation=EnterOptiShadeMutation -StateRoot $StateRoot
 try{

    $report={param([string]$detail,[int]$value) if($Progress){$Progress.Invoke($detail,$value,100)}}.GetNewClosure()

    & $report 'Finding OptiShade-managed game installations...' 0

    $root=FullPath $StateRoot;$keep=FullPath $Installer

    if(-not(Test-Path -LiteralPath $root)){return}

    $portableRoot=Join-Path (Split-Path $keep -Parent) 'Data'

    $portable=($env:OPTISHADE_PORTABLE -eq '1' -and $root -eq (FullPath $portableRoot) -and (Test-Path -LiteralPath (Join-Path (Split-Path $keep -Parent) 'portable.txt') -PathType Leaf))

    if((Split-Path $root -Leaf) -ne 'OptiShade' -and -not $portable){throw 'Cleanup requires the dedicated OptiShade storage folder.'}

    [void](OwnedPath $root 'cleanup-check')

    $records=@(GetOptiShadeCleanupReceipts $root)
    $recoveredChangedFiles=@();$unrestoredOriginalFiles=@()

    if(-not $records.Count){
        # A user may uninstall a fresh manager before installing it into any
        # game. Permit that only when the dedicated game index is empty; any
        # orphaned receipt/backup/session data remains a hard stop because it
        # may be the only recovery copy for files previously installed.
        $gamesRoot=Join-Path $root 'Games'
        if(Test-Path -LiteralPath $gamesRoot -PathType Container){
            if(Get-ChildItem -LiteralPath $gamesRoot -Force -Recurse | Select-Object -First 1){throw 'No recorded game installations were found, but OptiShade game data remains. Nothing was removed; repair or restore the recorded game installation before uninstalling.'}
        }
    }

    if($null -eq $RunningImagePaths){$RunningImagePaths=GetOptiShadeRunningImagePaths}
    $liveSessions=@(GetOptiShadeLiveManagerSessionDirectories $root $RunningImagePaths)

    $recordIndex=0;$recordCount=$records.Count

    foreach($m in $records){

        $recordIndex++;$manifest=ReadOptiShadeState $m.FullName

        $nestedProgress={param($detail,$completed=0,$total=0)

            $fraction=if($total -gt 0){[Math]::Min(1.0,[Math]::Max(0.0,$completed/[double]$total))}else{0.0}

            $value=5+[int](80*(($recordIndex-1+$fraction)/[Math]::Max(1,$recordCount)))

            $Progress.Invoke(('Restoring '+$manifest.Game+' ('+$recordIndex+' of '+$recordCount+'): '+$detail),$value,100)

        }.GetNewClosure()

        RestoreFusion $m.FullName -KeepPresets $KeepPresets -Progress $nestedProgress
        $restored=ReadOptiShadeState $m.FullName
        if($restored.RecoveredChangedFiles){$recoveredChangedFiles+=([string]$restored.RecoveredChangedFiles)}
        if($restored.UnrestoredOriginalFiles){$unrestoredOriginalFiles+=@($restored.UnrestoredOriginalFiles)}

    }

    & $report 'Checking manager data before removal...' 87

    # Downloaded component packages can contain very deep third-party source
    # trees (for example FidelityFX SDK framework folders). Remove that
    # disposable cache before walking the manager store: Windows PowerShell's
    # recursive provider can report a missing path while traversing such trees
    # even though the game restore and its backups are already complete.
    # The cache is not used as an uninstall source; game files are restored
    # exclusively from the recorded, hash-checked backups above.
    $componentPackageCache=Join-Path $root 'ComponentPackages'
    if(Test-Path -LiteralPath $componentPackageCache -PathType Container){
        $cacheItem=Get-Item -LiteralPath $componentPackageCache -Force -ErrorAction Stop
        if($cacheItem.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The component package cache is linked outside OptiShade storage. Cleanup stopped.'}
        $cacheRemoved=$false
        for($attempt=1;$attempt -le 3 -and -not $cacheRemoved;$attempt++){
            try{
                RemoveOptiShadeLongPathTree $componentPackageCache
                $cacheRemoved=$true
            }catch{
                # A file may disappear during cleanup (for example, while
                # antivirus scans an extracted package). Treat an already
                # removed cache as success and retry transient enumeration
                # races before reporting a real cleanup failure. PowerShell's
                # Remove-Item provider cannot reliably delete paths beyond
                # MAX_PATH; the helper uses extended-length .NET paths.
                if(-not(Test-Path -LiteralPath $componentPackageCache)){$cacheRemoved=$true}
                elseif($attempt -eq 3){throw ('Could not remove the cached component packages. Game files were restored; close any other OptiShade manager windows, then retry uninstall. '+$_.Exception.GetBaseException().Message)}
                else{Start-Sleep -Milliseconds 150}
            }
        }
    }

    if(Get-ChildItem -LiteralPath $root -Force -Recurse | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}){throw 'A linked item was found in OptiShade storage. Cleanup stopped.'}

    # Delete only the dedicated application store; never search the PC by filename.

    $session=''

    if($ActiveSession){$candidate=FullPath $ActiveSession;if($candidate.StartsWith($root+'\Sessions\',[StringComparison]::OrdinalIgnoreCase)){$session=$candidate+'\'}}
    if($session){$currentSession=$session.TrimEnd('\','/');$liveSessions=@($liveSessions|Where-Object {$_.TrimEnd('\','/') -ine $currentSession})}

    if($session -or $keep.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase) -or $liveSessions.Count){

        & $report 'Removing OptiShade manager files...' 92

        Get-ChildItem -LiteralPath $root -Force -Recurse -File|Where-Object {
            $file=FullPath $_.FullName
            $isLive=$false;foreach($directory in $liveSessions){if($file.StartsWith($directory+'\',[StringComparison]::OrdinalIgnoreCase)){$isLive=$true;break}}
            $file -ne $keep -and (-not $session -or -not $file.StartsWith($session,[StringComparison]::OrdinalIgnoreCase)) -and -not $isLive
        }|Remove-Item -Force

        Get-ChildItem -LiteralPath $root -Force -Recurse -Directory|Sort-Object FullName -Descending|ForEach-Object {if(-not(Get-ChildItem -LiteralPath $_.FullName -Force)){Remove-Item -LiteralPath $_.FullName}}

    }else{& $report 'Removing the OptiShade data folder...' 92;Remove-Item -LiteralPath $root -Recurse -Force}

    if($session -and $liveSessions.Count){& $report 'OptiShade was removed from games. This manager and other open OptiShade windows will finish cleaning their session files when they close.' 100}
    elseif($session){& $report 'OptiShade was removed from games. This manager will finish cleaning its session files when it closes.' 100}
    elseif($liveSessions.Count){& $report 'OptiShade was removed from games. Other open OptiShade windows will finish cleaning their session files when they close.' 100}
    else{& $report 'Uninstall complete.' 100}

    return [pscustomobject]@{RecoveredChangedFiles=@($recoveredChangedFiles|Select-Object -Unique);UnrestoredOriginalFiles=@($unrestoredOriginalFiles|Select-Object -Unique)}

 }finally{ExitOptiShadeMutation $storeMutation}
}

function RemoveOptiShadeLongPathTree([string]$Path){
    if(-not ('OptiShadeLongPathTree' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.IO;

public static class OptiShadeLongPathTree {
    public static void Delete(string path) {
        string full = Path.GetFullPath(path);
        string extended = full.StartsWith(@"\\?\", StringComparison.Ordinal) ? full : @"\\?\" + full;
        DeleteEntry(extended);
    }

    private static void DeleteEntry(string path) {
        FileAttributes attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.ReparsePoint) != 0)
            throw new IOException("A linked item was found in the cached component packages. Cleanup stopped.");
        attributes &= ~(FileAttributes.ReadOnly | FileAttributes.Hidden | FileAttributes.System);
        File.SetAttributes(path, attributes);
        if ((attributes & FileAttributes.Directory) == 0) {
            File.Delete(path);
            return;
        }
        foreach (string child in Directory.EnumerateFileSystemEntries(path)) DeleteEntry(child);
        Directory.Delete(path, false);
    }
}
'@ -ErrorAction Stop | Out-Null
    }
    [OptiShadeLongPathTree]::Delete($Path)
}



function GetSnapshotRemovalPlan([string]$ReceiptRoot='',[string[]]$GameRoots) {

 $root=if($ReceiptRoot){FullPath $ReceiptRoot}else{Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'OptiShade-SnapShot'}

 if((Split-Path $root -Leaf) -ne 'OptiShade-SnapShot'){throw 'Invalid snapshot record folder.'}

 if(-not(Test-Path -LiteralPath $root)){return}

 [void](OwnedPath $root 'check')

 foreach($receipt in Get-ChildItem -LiteralPath $root -Filter 'OptiShade-*.txt' -File){

  $safe=OwnedPath $root $receipt.Name

  $lines=[IO.File]::ReadAllLines($safe,[Text.Encoding]::UTF8)

  if($lines.Count -notin @(3,4) -or $lines[2] -notmatch '^[a-fA-F0-9]{64}$'){throw "Invalid SnapShot record: $safe. No snapshot cleanup was performed."}

  $file=FullPath $lines[0];$folder=Split-Path $file -Parent;$name=Split-Path $file -Leaf

  $captureGame=if($lines.Count -eq 4){FullPath $lines[3]}else{FullPath (Split-Path $folder -Parent)}

  if($PSBoundParameters.ContainsKey('GameRoots') -and $captureGame -notin $GameRoots){continue}

  $legacyLocation=(Split-Path $folder -Leaf) -ieq 'OptiShade Snapshots'

  $libraryLocation=((Split-Path (Split-Path $folder -Parent) -Leaf) -ieq 'OptiShade Snapshots' -and (Split-Path $folder -Leaf) -ieq (Split-Path $captureGame -Leaf))

  if((-not $legacyLocation -and -not $libraryLocation) -or $name -notmatch '^OptiShade-\d{8}-\d{6}-\{[a-fA-F0-9-]{36}\}\.(png|jpg)$' -or [IO.Path]::GetFileNameWithoutExtension($name) -cne $receipt.BaseName){throw 'Invalid SnapShot ownership record. Cleanup stopped.'}

  [void](OwnedPath $folder $name)

  if(Test-Path -LiteralPath $file){

   if((Get-Item -LiteralPath $file).Length -ne [long]$lines[1] -or (HashFile $file) -ne $lines[2]){throw "This snapshot has changed since capture and will not be deleted automatically: $file"}

  }

  [pscustomobject]@{File=$file;Receipt=$safe;Folder=$folder}

 }

}

function RemoveSelectedOptiShadeData([string]$StateRoot,[string]$Installer,[string]$ActiveSession,[bool]$AppFiles,[bool]$IniFiles,[bool]$Snapshots,[scriptblock]$Progress={param($detail,$completed=0,$total=0)}){
 $storeMutation=EnterOptiShadeMutation -StateRoot $StateRoot
 try{

 $Progress.Invoke('Checking selected uninstall options...',0,100)

 if(-not($AppFiles -or $IniFiles -or $Snapshots)){throw 'Choose at least one item to remove.'}

 $records=@(GetOptiShadeCleanupReceipts $StateRoot)

 $presets=@()

 $gameRoots=@()

 foreach($record in $records){

  [void](OwnedPath $StateRoot $record.FullName.Substring((FullPath $StateRoot).Length+1))

  $manifest=ReadOptiShadeState $record.FullName

  $gameRoots+=FullPath $manifest.Game

  AssertClosed $manifest.Game

  if($IniFiles -and -not $AppFiles){

   $folder=OwnedPath $manifest.Game 'OptiShadeData/Presets'

   if(Test-Path -LiteralPath $folder){

    if(Get-ChildItem -LiteralPath $folder -Recurse -Force|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}){throw 'A linked preset was found. Cleanup stopped.'}

    $presets+=@(Get-ChildItem -LiteralPath $folder -Filter '*.ini' -File -Recurse|ForEach-Object {OwnedPath $folder $_.FullName.Substring($folder.Length+1)})

   }

  }

 }

 $captures=if($Snapshots){@(GetSnapshotRemovalPlan -GameRoots $gameRoots)}else{@()}

 $Progress.Invoke('Game installations and selected files are verified...',10,100)

 if($AppFiles){

  $uninstallProgress={param($detail,$completed=0,$total=0)

   $fraction=if($total -gt 0){[Math]::Min(1.0,[Math]::Max(0.0,$completed/[double]$total))}else{0.0}

   $Progress.Invoke($detail,(10+[int](76*$fraction)),100)

  }.GetNewClosure()

  $uninstallResult=UninstallFusion $StateRoot $Installer $ActiveSession -KeepPresets (-not $IniFiles) -Progress $uninstallProgress

 }

 $removedIni=0;$iniTotal=[Math]::Max(1,$presets.Count)

 foreach($file in $presets){$removedIni++;$Progress.Invoke(('Removing saved preset '+$removedIni+' of '+$presets.Count+'...'),(87+[int](5*$removedIni/$iniTotal)),100);Remove-Item -LiteralPath $file -Force}

 $removedCapture=0;$captureTotal=[Math]::Max(1,$captures.Count)

 foreach($capture in $captures){

  $removedCapture++;$Progress.Invoke(('Removing SnapShot '+$removedCapture+' of '+$captures.Count+'...'),(93+[int](6*$removedCapture/$captureTotal)),100)

  if(Test-Path -LiteralPath $capture.File){Remove-Item -LiteralPath $capture.File -Force}

  Remove-Item -LiteralPath $capture.Receipt -Force

  if((Test-Path -LiteralPath $capture.Folder) -and -not(Get-ChildItem -LiteralPath $capture.Folder -Force)){Remove-Item -LiteralPath $capture.Folder}

 }

 $Progress.Invoke('Uninstall complete.',100,100)
 if($uninstallResult){return $uninstallResult}
 return [pscustomobject]@{RecoveredChangedFiles=@();UnrestoredOriginalFiles=@()}

 }finally{ExitOptiShadeMutation $storeMutation}
}

# Settings > Remove OptiShade from all games. Restores every recorded game the same
# verified way Restore does for one game, and leaves the OptiShade app, its data and
# its settings installed so any game can be set up again later.
function RemoveOptiShadeFromAllGames([string]$StateRoot,[bool]$KeepPresets=$true,[bool]$Snapshots=$false,[scriptblock]$Progress={param($detail,$completed=0,$total=0)}){
 $storeMutation=EnterOptiShadeMutation -StateRoot $StateRoot
 try{
  $Progress.Invoke('Finding games with OptiShade installed...',0,100)
  # Games already restored keep their record; only games that still have OptiShade change.
  $records=@(GetOptiShadeCleanupReceipts $StateRoot|Where-Object {(ReadOptiShadeState $_.FullName).Status -ne 'Restored'})
  $gameRoots=@()
  foreach($record in $records){
   [void](OwnedPath $StateRoot $record.FullName.Substring((FullPath $StateRoot).Length+1))
   $manifest=ReadOptiShadeState $record.FullName
   $gameRoots+=FullPath $manifest.Game
   AssertClosed $manifest.Game
  }
  $captures=if($Snapshots){@(GetSnapshotRemovalPlan -GameRoots $gameRoots)}else{@()}
  $recovered=@();$unrestored=@();$index=0;$count=[Math]::Max(1,$records.Count)
  foreach($record in $records){
   $index++;$game=(ReadOptiShadeState $record.FullName).Game
   $nested={param($detail,$completed=0,$total=0)
    $fraction=if($total -gt 0){[Math]::Min(1.0,[Math]::Max(0.0,$completed/[double]$total))}else{0.0}
    $Progress.Invoke(('Restoring '+$game+' ('+$index+' of '+$records.Count+'): '+$detail),(5+[int](85*(($index-1+$fraction)/$count))),100)
   }.GetNewClosure()
   RestoreFusion $record.FullName -KeepPresets $KeepPresets -Progress $nested
   $restored=ReadOptiShadeState $record.FullName
   if($restored.RecoveredChangedFiles){$recovered+=([string]$restored.RecoveredChangedFiles)}
   if($restored.UnrestoredOriginalFiles){$unrestored+=@($restored.UnrestoredOriginalFiles)}
  }
  $removed=0;$total=[Math]::Max(1,$captures.Count)
  foreach($capture in $captures){
   $removed++;$Progress.Invoke(('Removing SnapShot '+$removed+' of '+$captures.Count+'...'),(91+[int](8*$removed/$total)),100)
   if(Test-Path -LiteralPath $capture.File){Remove-Item -LiteralPath $capture.File -Force}
   Remove-Item -LiteralPath $capture.Receipt -Force
   if((Test-Path -LiteralPath $capture.Folder) -and -not(Get-ChildItem -LiteralPath $capture.Folder -Force)){Remove-Item -LiteralPath $capture.Folder}
  }
  $Progress.Invoke('OptiShade was removed from every game.',100,100)
  return [pscustomobject]@{Games=$records.Count;RecoveredChangedFiles=@($recovered);UnrestoredOriginalFiles=@($unrestored)}
 }finally{ExitOptiShadeMutation $storeMutation}
}
function GetFusionUpdateConflicts($Manifest){

 foreach($conflict in @(FindFusionConflicts $Manifest.Game)){

  [void](OwnedPath $Manifest.Game $conflict.Path)

  # Runtime-generated logs are not executable loaders or distributed payloads.

  # Keep them in place; do not require an installation-time hash for a log.

  if($conflict.Path -in @('ReShade.log','OptiScaler.log')){continue}

  $record=@($Manifest.Files|Where-Object {$_.Path -eq $conflict.Path})

  $owned=@($record|Where-Object {$_.Hash -eq $conflict.Hash -or (TestOptiShadeMutableFile $_.Path)})

  if(-not $owned.Count){

   $reason=if($record.Count){'has changed since it was installed'}else{'is not recorded as an OptiShade-installed file'}

   throw "Update paused: $($conflict.Path) $reason.`nGame folder: $($Manifest.Game)`nOpen Setup and review the conflicting file before reinstalling. No game files were changed; your presets are still there. Do not delete the file if it belongs to another graphics mod."

  }

  $conflict

 }

}

