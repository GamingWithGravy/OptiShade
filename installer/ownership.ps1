$ErrorActionPreference='Stop'
function FullPath([string]$Path){[IO.Path]::GetFullPath($Path).TrimEnd('\','/')}
function HashFile([string]$Path){if(Test-Path -LiteralPath $Path -PathType Leaf){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}else{''}}
function OwnedPath([string]$Root,[string]$Relative){
    $base=FullPath $Root;$path=FullPath (Join-Path $base $Relative)
    if(-not $path.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Path is outside the installation folder.'}
    $check=$path
    while($check){if(Test-Path -LiteralPath $check){if((Get-Item -LiteralPath $check -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Linked folders are not supported: $check"}};$parent=Split-Path $check -Parent;if($parent -eq $check){break};$check=$parent}
    $path
}
function AssertClosed([string]$Game){
    foreach($p in Get-Process){try{if($p.Path -and ((FullPath (Split-Path $p.Path -Parent)) -eq (FullPath $Game))){throw "Close $($p.ProcessName) first."}}catch [System.ComponentModel.Win32Exception]{}}
    if(Get-Process FlightSimulator2024,FlightSimulator -ErrorAction SilentlyContinue){throw 'Close MSFS before changing installed files.'}
}
function ManifestPath([string]$StateRoot,[string]$Game){
    $bytes=[Text.Encoding]::UTF8.GetBytes((FullPath $Game).ToLowerInvariant());$sha=[Security.Cryptography.SHA256]::Create();$id=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').Substring(0,16);$sha.Dispose()
    OwnedPath $StateRoot ('Games/'+$id+'/manifest.json')
}
function WriteState($Manifest,[string]$Path){$tmp=$Path+'.tmp';$Manifest|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $tmp -Encoding UTF8;Move-Item -LiteralPath $tmp -Destination $Path -Force}
function IsGraphicsMod([string]$Relative,[string]$File){
 if($Relative -match '^(?i:OptiShadeData)[\\/]' -or $Relative -match '^(?i:ReShade(?:64\.dll|\.ini|\.log)|OptiScaler(?:\.dll|\.ini|\.log)|nvngx_dlssnr\.dll|nvngx\.dll_dlssnr\.dll)$' -or $Relative -match '(?i)(dlss5|renodx).*\.addon64$'){return $true}
 if(Test-Path -LiteralPath $File -PathType Leaf){try{$v=[Diagnostics.FileVersionInfo]::GetVersionInfo($File);return "$($v.ProductName) $($v.FileDescription)" -match '(?i)optishade|optiscaler|reshade'}catch{}}
 return $false
}
function CleanModBackupReferences($Manifest,[string]$Folder){
 # Preserve verified backup references, including third-party graphics mods.
}
function RemoveUnreferencedBackups($Manifest,[string]$Folder){
 $root=OwnedPath $Folder 'Backups';$keep=@($Manifest.Files|Where-Object Backup|ForEach-Object {OwnedPath $Folder $_.Backup})
 if(Test-Path -LiteralPath $root){foreach($f in Get-ChildItem -LiteralPath $root -File -Recurse){$safe=OwnedPath $Folder $f.FullName.Substring($Folder.Length+1);if($safe -notin $keep){Remove-Item -LiteralPath $safe -Force}}}
}
function FindFusionConflicts([string]$Game){
 foreach($name in @('ReShade.ini','OptiScaler.ini','ReShade.log','OptiScaler.log','nvngx_dlssnr.dll','nvngx.dll_dlssnr.dll')){if(Test-Path -LiteralPath (Join-Path $Game $name) -PathType Leaf){[pscustomobject]@{Path=$name;Recognised=$true;Description='Graphics mod file';Hash=(HashFile (Join-Path $Game $name))}}}
 foreach($addon in Get-ChildItem -LiteralPath $Game -Filter '*.addon64' -File -ErrorAction SilentlyContinue|Where-Object Name -match '(?i)dlss5|renodx'){
  [pscustomobject]@{Path=$addon.Name;Recognised=$true;Description='External neural-rendering/ReShade add-on';Hash=(HashFile $addon.FullName)}
 }
 foreach($name in @('dxgi.dll','d3d12.dll','d3d11.dll','d3d9.dll','opengl32.dll','OptiScaler.dll','ReShade64.dll','winmm.dll','version.dll','dbghelp.dll','wininet.dll','winhttp.dll','dinput8.dll','SpecialK64.dll','ReShade.asi','OptiScaler.asi')){
  $file=Join-Path $Game $name
  if(Test-Path -LiteralPath $file -PathType Leaf){
   $info=[Diagnostics.FileVersionInfo]::GetVersionInfo($file);$description="$($info.ProductName) $($info.FileDescription) $($info.OriginalFilename)"
   $recognised=$description -match '(?i)reshade|optiscaler|optishade|special.?k|enbseries'
   [pscustomobject]@{Path=$name;Recognised=$recognised;Description=$description.Trim();Hash=(HashFile $file)}
  }
 }
}
function InstallFusion([string]$Game,[string]$Payload,[string]$StateRoot,[string]$Installer,[string]$Proxy='winmm.dll',[object[]]$ReplaceMods=@(),[bool]$ReplaceExisting=$false,[bool]$PreserveConfiguration=$false,[bool]$IncludeEffects=$true){
    if($Proxy -notin @('winmm.dll','dxgi.dll','d3d12.dll','version.dll','dbghelp.dll','wininet.dll','winhttp.dll')){throw 'Unsupported installation method.'}
    $Game=FullPath $Game;$Payload=FullPath $Payload;AssertClosed $Game
    if(-not(Test-Path -LiteralPath $Game -PathType Container)){throw 'Choose the game folder first.'}
    $mp=ManifestPath $StateRoot $Game
    $old=$null;$oldJson=$null
    if(Test-Path -LiteralPath $mp){$oldJson=Get-Content -LiteralPath $mp -Raw;$old=$oldJson|ConvertFrom-Json;if($old.Status -ne 'Restored' -and -not $ReplaceExisting){throw 'OptiShade is already recorded here. Choose Repair or approve reinstalling it.'};if($old.Status -eq 'Restored'){$old=$null}}
    if($old -and $old.PSObject.Properties['IncludeEffects']){$IncludeEffects=[bool]$old.IncludeEffects}
    elseif($old -and $old.Downloads -eq 'Complete' -and -not(Test-Path -LiteralPath (Join-Path $Game 'OptiShadeData/Shaders'))){$IncludeEffects=$false}
    if($old){CleanModBackupReferences $old (Split-Path $mp);foreach($f in $old.Files){if($f.Backup -and (HashFile (OwnedPath (Split-Path $mp) $f.Backup)) -ne $f.PreviousHash){throw "Original backup is missing or damaged: $($f.Path). Keep the installation and recover its backup before replacing it."}}}
    $conflicts=@(FindFusionConflicts $Game)
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
    $catalog=Get-Content -LiteralPath (Join-Path $Payload 'files.json') -Raw|ConvertFrom-Json
    $folder=Split-Path $mp;New-Item -ItemType Directory -Path (Join-Path $folder 'Backups') -Force|Out-Null
    $files=@();$index=0;$transaction=[guid]::NewGuid().ToString('N')
    # Keep the original ownership chain across upgrades. Orphaned data is backed up
    # as pre-existing user data so Restore can recover it instead of deleting it.
    if($old){$files=@($old.Files|ForEach-Object {@{Path=$_.Path;SourcePath='';Hash=$_.Hash;PreviousHash=$_.PreviousHash;Backup=$_.Backup;Mutable=$_.Mutable;Retained=($_.Path -match '^OptiShadeData[\\/](Presets|Shaders|Textures)[\\/]' -or ($PreserveConfiguration -and $_.Path -match '\.ini$') -or $_.Path -match 'Effects-install\.json$' -or $_.Path -eq 'nvngx_dlssnr.dll')}})}
    elseif($ReplaceExisting -and (Test-Path -LiteralPath $data)){
        foreach($entry in Get-ChildItem -LiteralPath $data -File -Recurse -Force){
            $relative=$entry.FullName.Substring($Game.Length+1);$previous=HashFile $entry.FullName
            $keep=$relative -match '^OptiShadeData[\\/](Presets|Shaders|Textures)[\\/]'
            $files+=@{Path=$relative;SourcePath='';Hash=$(if($keep){$previous}else{''});PreviousHash='';Backup='';Mutable=$true;Retained=$keep}
        }
    }
    foreach($entry in $catalog){
        $bundledLook=$entry.Path -match '^OptiShadeData[\\/](Shaders[\\/]Custom[\\/]Gravy_FusionCinema\.fx|Presets[\\/](My look\.ini|Gravy - Fusion Cinema Custom v1\.ini))$'
        if(-not $IncludeEffects -and $entry.Path -match '^OptiShadeData[\\/](Shaders|Textures|Presets)[\\/]' -and -not $bundledLook){continue}
        $source=OwnedPath $Payload $entry.Path;$relative=if($entry.Path -eq 'winmm.dll'){$Proxy}else{$entry.Path};$dest=OwnedPath $Game $relative
        if((HashFile $source) -ne $entry.Hash){throw "Installer payload is damaged: $($entry.Path)"}
        # Keep download receipts on repair/reinstall; bundled defaults must not erase them.
        if($relative -match '^OptiShadeData[\\/]Effects-install\.json$' -and (Test-Path -LiteralPath $dest)){continue}
        # A returning user's saved default look is their preset, not disposable payload.
        if($relative -match '^OptiShadeData[\\/]Presets[\\/].*\.ini$' -and (Test-Path -LiteralPath $dest)){continue}
        if($PreserveConfiguration -and $relative -match '\.ini$' -and (Test-Path -LiteralPath $dest)){
            if($files.Path -notcontains $relative){
                $previous=HashFile $dest;$backup='Backups/'+$transaction+'-config-'+$index
                Copy-Item -LiteralPath $dest -Destination (OwnedPath $folder $backup)
                if((HashFile (OwnedPath $folder $backup)) -ne $previous){throw 'Configuration backup verification failed.'}
                $files+=@{Path=$relative;SourcePath=$entry.Path;Hash=$previous;PreviousHash=$previous;Backup=$backup;Mutable=$true;Retained=$true};$index++
            }
            continue
        }
        $existing=@($files|Where-Object Path -eq $relative)
        if($existing.Count){$previous=$existing[0].PreviousHash;$backup=$existing[0].Backup;$files=@($files|Where-Object Path -ne $relative)}
        else{$previous=HashFile $dest;$backup='';if($previous){$backup='Backups/'+$transaction+'-'+$index;Copy-Item -LiteralPath $dest -Destination (OwnedPath $folder $backup);if((HashFile (OwnedPath $folder $backup)) -ne $previous){throw 'Backup verification failed.'}}}
        $files+=@{Path=$relative;SourcePath=$entry.Path;Hash=$entry.Hash;PreviousHash=$previous;Backup=$backup;Mutable=(($entry.Path -match '\.(ini|log)$') -or ($entry.Path -match '^OptiShadeData[\\/]Effects-install\.json$'));Retained=$false};$index++
    }
    foreach($conflict in $conflicts){
        if($files.Path -contains $conflict.Path){
            $tracked=@($files|Where-Object Path -eq $conflict.Path)[0]
            if($PreserveConfiguration -and $tracked.Retained -and $conflict.Path -match '\.ini$'){continue}
            if($tracked.Retained -and $conflict.Path -eq 'nvngx_dlssnr.dll'){continue};if($tracked.Retained){$tracked.Retained=$false;$tracked.Hash=''}
            continue
        }
        $backup='Backups/'+$transaction+'-mod-'+$index;$previous=$conflict.Hash;$source=OwnedPath $Game $conflict.Path
        Copy-Item -LiteralPath $source -Destination (OwnedPath $folder $backup)
        if((HashFile (OwnedPath $folder $backup)) -ne $previous){throw 'Existing mod backup verification failed.'}
        $files+=@{Path=$conflict.Path;SourcePath='';Hash='';PreviousHash=$previous;Backup=$backup;Mutable=$false};$index++
    }
    $rollback=@();$rollbackFolder=OwnedPath $folder ('Rollback/'+$transaction);New-Item -ItemType Directory -Path $rollbackFolder -Force|Out-Null
    foreach($entry in $files|Where-Object {-not $_.Retained}){
        $dest=OwnedPath $Game $entry.Path;$hash=HashFile $dest;$copy=Join-Path $rollbackFolder ([string]$rollback.Count)
        if($hash){Copy-Item -LiteralPath $dest -Destination $copy;if((HashFile $copy) -ne $hash){throw 'Rollback snapshot verification failed.'}}
        $rollback+=@{Path=$entry.Path;Hash=$hash;Copy=$copy}
    }
    $manifest=@{Version='P0.20.11-MSFS24';Game=$Game;Installer=(FullPath $Installer);Status='Installing';Files=$files;OwnedDirectories=@('OptiShadeData');IncludeEffects=$IncludeEffects;PreserveThirdParty=$true;Created=(Get-Date -Format o)}
    WriteState $manifest $mp
    try{
        # The entry-point proxy is copied last so an incomplete install cannot start.
        foreach($entry in ($files|Sort-Object @{Expression={$_.SourcePath -eq 'winmm.dll'}})){
            if($entry.Retained){continue}
            $dest=OwnedPath $Game $entry.Path;New-Item -ItemType Directory -Path (Split-Path $dest) -Force|Out-Null
            $snapshot=@($rollback|Where-Object Path -eq $entry.Path)[0]
            if((HashFile $dest) -ne $snapshot.Hash){throw 'An existing file changed during installation.'}
            if(-not $entry.SourcePath){if(Test-Path -LiteralPath $dest){Remove-Item -LiteralPath $dest -Force};continue}
            Copy-Item -LiteralPath (OwnedPath $Payload $entry.SourcePath) -Destination $dest -Force
            if((HashFile $dest) -ne $entry.Hash){throw 'Installed file verification failed.'}
        }
        $manifest.Status='Installed';WriteState $manifest $mp
    }catch{
        $failure=$_
        foreach($entry in $rollback){$dest=OwnedPath $Game $entry.Path;if($entry.Hash){Copy-Item -LiteralPath $entry.Copy -Destination $dest -Force}else{if(Test-Path -LiteralPath $dest){Remove-Item -LiteralPath $dest -Force}}}
        if($oldJson){$oldJson|Set-Content -LiteralPath $mp -Encoding UTF8}else{Remove-Item -LiteralPath $mp -Force}
        throw $failure
    }
    foreach($entry in $rollback){if(Test-Path -LiteralPath $entry.Copy){Remove-Item -LiteralPath $entry.Copy -Force}}
    Remove-Item -LiteralPath $rollbackFolder
    RemoveUnreferencedBackups $manifest $folder
    $mp
}
function RemoveRecordedOptiShadeLoaders($Manifest,[string]$ManifestPath){
    # Identify our loader by the recorded payload hash, never just a proxy filename.
    $hashes=@($Manifest.Files|Where-Object {$_.SourcePath -eq 'winmm.dll' -and $_.Hash}|ForEach-Object Hash)
    if(-not $hashes.Count){return}
    foreach($name in @('winmm.dll','dxgi.dll','d3d12.dll','version.dll','dbghelp.dll','wininet.dll','winhttp.dll','dinput8.dll','OptiScaler.dll')){
        $file=OwnedPath $Manifest.Game $name
        $hash=HashFile $file
        if($hash -and $hash -in $hashes){
            AssertClosed $Manifest.Game
            Remove-Item -LiteralPath $file -Force
            if(Test-Path -LiteralPath $file){throw ('OptiShade loader is still present: '+$file)}
        }
    }
}
function RestoreFusion([string]$ManifestPath,[bool]$KeepPresets=$true){
    $m=Get-Content -LiteralPath $ManifestPath -Raw|ConvertFrom-Json
    CleanModBackupReferences $m (Split-Path $ManifestPath)
    if($m.Status -eq 'Restored'){
        AssertClosed $m.Game
        RemoveRecordedOptiShadeLoaders $m $ManifestPath
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
        return
    }
    AssertClosed $m.Game;$folder=Split-Path $ManifestPath
    $checkFiles=@($m.Files|ForEach-Object {OwnedPath $m.Game $_.Path})
    foreach($relative in $m.OwnedDirectories){$dir=OwnedPath $m.Game $relative;if(Test-Path -LiteralPath $dir){$checkFiles+=@(Get-ChildItem -LiteralPath $dir -File -Recurse -Force|ForEach-Object FullName)}}
    foreach($file in $checkFiles|Select-Object -Unique){if(Test-Path -LiteralPath $file -PathType Leaf){
        try{$handle=[IO.File]::Open($file,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$handle.Dispose()}
        catch{throw ('Restore has not changed any files. Close MSFS and any log viewers, then retry. File is locked or not writable: '+$file)}
    }}
    foreach($f in $m.Files){
        $dest=OwnedPath $m.Game $f.Path;$actual=HashFile $dest
        # Older manifests incorrectly classified the installer-maintained FX receipt as immutable.
        $mutable=$f.Mutable -or ($f.Path -match '^OptiShadeData[\\/]Effects-install\.json$')
        if($actual -and -not $mutable -and $actual -ne $f.Hash -and $actual -ne $f.PreviousHash){throw "A file changed after installation: $($f.Path). Restore stopped before changing anything."}
        if($f.Backup -and (HashFile (OwnedPath $folder $f.Backup)) -ne $f.PreviousHash){throw "Original backup failed verification: $($f.Path)"}
    }
    foreach($relative in $m.OwnedDirectories){
        $dir=OwnedPath $m.Game $relative
        if(Test-Path -LiteralPath $dir){if(Get-ChildItem -LiteralPath $dir -Force -Recurse|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}){throw 'A linked item was found in OptiShade data. Cleanup stopped.'}}
    }
    # Preserve bounded evidence outside game files before cleanup. Diagnostics must never block recovery.
    try{
        if(-not(Get-Command SavePreRestoreEvidence -ErrorAction SilentlyContinue)){. "$PSScriptRoot/diagnostics.ps1"}
        SavePreRestoreEvidence $m.Game $folder
    }catch{Write-Warning 'Could not preserve pre-restore diagnostics. Restore will continue.'}
    $presets=OwnedPath $m.Game 'OptiShadeData/Presets'
    foreach($f in $m.Files){$dest=OwnedPath $m.Game $f.Path;if($KeepPresets -and $dest.StartsWith($presets+'\',[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetExtension($dest) -eq '.ini'){continue};if($f.Backup){Copy-Item -LiteralPath (OwnedPath $folder $f.Backup) -Destination $dest -Force}elseif(Test-Path -LiteralPath $dest){Remove-Item -LiteralPath $dest -Force}}
    $restoredPaths=@($m.Files|Where-Object Backup|ForEach-Object {OwnedPath $m.Game $_.Path})
    foreach($relative in $m.OwnedDirectories){$dir=OwnedPath $m.Game $relative;if(Test-Path -LiteralPath $dir){
        Get-ChildItem -LiteralPath $dir -Force -Recurse -File | Where-Object {$_.FullName -notin $restoredPaths -and -not($KeepPresets -and $_.FullName.StartsWith($presets+'\',[StringComparison]::OrdinalIgnoreCase) -and $_.Extension -eq '.ini')} | Remove-Item -Force
        Get-ChildItem -LiteralPath $dir -Force -Recurse -Directory | Sort-Object {$_.FullName.Length} -Descending | ForEach-Object {if(-not(Get-ChildItem -LiteralPath $_.FullName -Force)){Remove-Item -LiteralPath $_.FullName}}
        if(-not(Get-ChildItem -LiteralPath $dir -Force)){Remove-Item -LiteralPath $dir}
    }}
    RemoveRecordedOptiShadeLoaders $m $ManifestPath
    foreach($f in $m.Files){
        $dest=OwnedPath $m.Game $f.Path
        if($KeepPresets -and $dest.StartsWith($presets+'\',[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetExtension($dest) -eq '.ini'){continue}
        $ours=@($m.Files|Where-Object {$_.SourcePath -eq 'winmm.dll'}|ForEach-Object Hash)
        if($f.Backup -and $f.PreviousHash -notin $ours){if((HashFile $dest) -ne $f.PreviousHash){throw ('Restored file verification failed: '+$f.Path)}}
        elseif(Test-Path -LiteralPath $dest){throw ('Removal verification failed: '+$f.Path)}
    }
    $m.Status='Restored';WriteState $m $ManifestPath;RemoveUnreferencedBackups $m $folder
}
function FindNrRuntime([string]$Installer){
    # Only inspect known locations; never crawl drives for DLLs.
    $candidates=@((Join-Path (Split-Path $Installer) 'nvngx_dlssnr.dll'),(Join-Path ([Environment]::GetFolderPath('Desktop')) 'DLSS5Installer/DLSS5Resources/Payload/Common/nvngx_dlssnr.dll'))
    $cards=@(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue|ForEach-Object Name)
    foreach($candidate in $candidates){$hash=HashFile $candidate
        if($hash -eq 'E16BCF15E16E13F527491CDF7845B2FE6521A738D8F7C9C721866A8496E1FC8E' -and ($cards -match 'RTX\s*50')){return $candidate}
        if($hash -eq 'E67DEE209320CDAFE0E93E45675D7AA34323A53ACC57A72B2E40A181581C989A' -and ($cards -match 'RTX\s*[2345]0')){return $candidate}
    }
    return $null
}
function ImportNrRuntime([string]$ManifestPath,[string]$Source){
    $m=Get-Content -LiteralPath $ManifestPath -Raw|ConvertFrom-Json;if($m.Status -ne 'Installed'){throw 'Install OptiShade into a game first.'};AssertClosed $m.Game
    $hash=HashFile $Source
    $cards=@(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue|ForEach-Object Name)
    if($cards.Count -and -not($cards -match 'RTX\s*[2345]0')){throw 'This neural-rendering runtime needs a supported NVIDIA RTX card. Use the included FSR/XeSS options on other compatible cards.'}
    if($hash -eq 'E16BCF15E16E13F527491CDF7845B2FE6521A738D8F7C9C721866A8496E1FC8E' -and $cards.Count -and -not($cards -match 'RTX\s*50')){throw 'This is the RTX 50 model. RTX 20/30/40 needs the compatibility runtime listed in the notes.'}
    if($hash -notin @('E16BCF15E16E13F527491CDF7845B2FE6521A738D8F7C9C721866A8496E1FC8E','E67DEE209320CDAFE0E93E45675D7AA34323A53ACC57A72B2E40A181581C989A')){throw 'Choose the original RTX 50 runtime or the exact 310.8 RTX 20/30/40 compatibility runtime listed in the included notes.'}
    if($hash -eq 'E16BCF15E16E13F527491CDF7845B2FE6521A738D8F7C9C721866A8496E1FC8E' -and (Get-AuthenticodeSignature -LiteralPath $Source).Status -ne 'Valid'){throw 'NVIDIA runtime signature verification failed.'}
    $relative='nvngx_dlssnr.dll';$dest=OwnedPath $m.Game $relative;$existing=@($m.Files|Where-Object Path -eq $relative)
    if((FullPath $Source) -eq (FullPath $dest) -and $existing.Count -and $existing[0].Hash -eq $hash){return}
    $originalManifest=Get-Content -LiteralPath $ManifestPath -Raw
    $old=HashFile $dest
    $snapshot=OwnedPath (Split-Path $ManifestPath) ('Backups/nr-import-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Split-Path $snapshot) -Force|Out-Null
    if($old){Copy-Item -LiteralPath $dest -Destination $snapshot;if((HashFile $snapshot) -ne $old){throw 'Runtime rollback snapshot failed verification.'}}
    try{
    if(-not $existing.Count){
        $m.Files+=@{Path=$relative;Hash=$hash;PreviousHash=$old;Backup=$(if($old){'Backups/'+[IO.Path]::GetFileName($snapshot)}else{''});Mutable=$false};WriteState $m $ManifestPath
    }
    if((FullPath $Source) -ne (FullPath $dest)){Copy-Item -LiteralPath $Source -Destination $dest -Force}
    if((HashFile $dest) -ne $hash){throw 'Imported runtime verification failed.'}
    foreach($entry in $m.Files){if($entry.Path -eq $relative){$entry.Hash=$hash}}
    WriteState $m $ManifestPath
    }catch{
        $failure=$_
        if((HashFile $dest) -ne $old){if($old){Copy-Item -LiteralPath $snapshot -Destination $dest -Force}else{Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue}}
        if((HashFile $dest) -ne $old){throw ('Runtime rollback failed; retain backup at '+$snapshot)}
        $originalManifest|Set-Content -LiteralPath $ManifestPath -Encoding UTF8
        throw $failure
    }
    if($existing.Count -and (Test-Path -LiteralPath $snapshot)){Remove-Item -LiteralPath $snapshot -Force}
}
function UninstallFusion([string]$StateRoot,[string]$Installer,[string]$ActiveSession='',[bool]$KeepPresets=$true){
    $root=FullPath $StateRoot;$keep=FullPath $Installer
    if(-not(Test-Path -LiteralPath $root)){return}
    if((Split-Path $root -Leaf) -ne 'OptiShade'){throw 'Cleanup requires the dedicated OptiShade storage folder.'}
    [void](OwnedPath $root 'cleanup-check')
    $records=@(Get-ChildItem -LiteralPath (Join-Path $root 'Games') -Filter manifest.json -File -Recurse -ErrorAction SilentlyContinue)
    if(-not $records.Count){throw 'No recorded game installations were found. Uninstall cannot confirm removal of untracked files. Select the actual game folder in Setup and inspect its installation before trying again.'}
    foreach($m in $records){RestoreFusion $m.FullName -KeepPresets $KeepPresets}
    if(Get-ChildItem -LiteralPath $root -Force -Recurse | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}){throw 'A linked item was found in OptiShade storage. Cleanup stopped.'}
    # Delete only the dedicated application store; never search the PC by filename.
    $session=''
    if($ActiveSession){$candidate=FullPath $ActiveSession;if($candidate.StartsWith($root+'\Sessions\',[StringComparison]::OrdinalIgnoreCase)){$session=$candidate+'\'}}
    if($session -or $keep.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){
        Get-ChildItem -LiteralPath $root -Force -Recurse -File|Where-Object {(FullPath $_.FullName) -ne $keep -and (-not $session -or -not $_.FullName.StartsWith($session,[StringComparison]::OrdinalIgnoreCase))}|Remove-Item -Force
        Get-ChildItem -LiteralPath $root -Force -Recurse -Directory|Sort-Object FullName -Descending|ForEach-Object {if(-not(Get-ChildItem -LiteralPath $_.FullName -Force)){Remove-Item -LiteralPath $_.FullName}}
    }else{Remove-Item -LiteralPath $root -Recurse -Force}
}


