. "$PSScriptRoot/anti-cheat.ps1"
. "$PSScriptRoot/json-state.ps1"
function GetVerifiedDownload([string]$Url,[string]$Path,[string]$Hash){
    $web=New-Object Net.WebClient
    try{$web.Headers['User-Agent']='OptiShade-FusionEngine';$task=$web.DownloadFileTaskAsync([uri]$Url,$Path)
        $downloadClock=[Diagnostics.Stopwatch]::StartNew()
        while(-not $task.IsCompleted){if($downloadClock.Elapsed.TotalMinutes -gt 10){$web.CancelAsync();throw 'Download timed out. Use Retry unfinished downloads.'};Start-Sleep -Milliseconds 100;if('System.Windows.Forms.Application' -as [type]){[Windows.Forms.Application]::DoEvents()}}
        $task.GetAwaiter().GetResult()
        if((HashFile $Path) -ne $Hash){throw 'Downloaded file did not match its verified release. Nothing was installed.'}
    }finally{$web.Dispose()}
}
function AssertNvidiaFile([string]$Path){$sig=Get-AuthenticodeSignature -LiteralPath $Path;if($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'NVIDIA'){throw 'The NVIDIA signature could not be verified.'}}
function TestNvidiaFileVersion($VersionInfo,[string]$Expected){
    if($Expected -notmatch '^\d+\.\d+\.\d+\.\d+$'){return $false}
    try{
        $expectedParts=[int[]]@($Expected.Split('.')|ForEach-Object{[int]::Parse($_,[Globalization.CultureInfo]::InvariantCulture)})
        $actualParts=[int[]]@($VersionInfo.FileMajorPart,$VersionInfo.FileMinorPart,$VersionInfo.FileBuildPart,$VersionInfo.FilePrivatePart)
        return (($actualParts -join '.') -ceq ($expectedParts -join '.'))
    }catch{return $false}
}
function InstallNvidia([string]$Game,[scriptblock]$Progress={param($text) Write-Output $text},[string]$DlssRuntimeProfile='nvidia-310.9.16'){
 AssertAntiCheatMutation $Game '' 'Install NVIDIA components'
    AssertClosed $Game
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    &$Progress 'Checking NVIDIA releases...'
    $latest='Unavailable';$latestSl='Unavailable'
    try{$latest=(Invoke-RestMethod 'https://api.github.com/repos/NVIDIA/DLSS/releases/latest' -Headers @{'User-Agent'='OptiShade'} -TimeoutSec 15).tag_name}catch{}
    try{$latestSl=(Invoke-RestMethod 'https://api.github.com/repos/NVIDIA-RTX/Streamline/releases/latest' -Headers @{'User-Agent'='OptiShade'} -TimeoutSec 15).tag_name}catch{}
    $staging=OwnedPath $Game 'OptiShadeData/Downloads/NVIDIA';New-Item -ItemType Directory $staging -Force|Out-Null
    $baseFiles=ReadOptiShadeJson "$PSScriptRoot/nvidia-files.json" 'NVIDIA catalogue JSON' -Shape Array
    $catalog=ReadOptiShadeJson "$PSScriptRoot/nvidia-runtime-profiles.json" 'DLSS runtime profile catalogue' -Shape Object
    if($catalog.schemaVersion -ne 1 -or @($catalog.scope).Count -ne 2 -or @($catalog.scope|Where-Object {$_ -cin @('nvngx_dlss.dll','nvngx_dlssd.dll')}).Count -ne 2){throw 'The DLSS runtime profile catalogue has an unsupported schema or file scope.'}
    if(-not $DlssRuntimeProfile){$DlssRuntimeProfile=[string]$catalog.default}
    if($DlssRuntimeProfile -cin @('nvidia-310.9.1','nvidia-310.7.0')){&$Progress "The saved DLSS SR/RR profile $DlssRuntimeProfile is retired. Updating this game to the current verified profile $($catalog.default).";$DlssRuntimeProfile=[string]$catalog.default}
    $selectedProfileEntry=@($catalog.profiles|Where-Object {$_.id -ceq $DlssRuntimeProfile})
    if($selectedProfileEntry.Count -ne 1){throw 'Choose a known DLSS runtime profile before installing NVIDIA components.'}
    $selectedProfileEntry=$selectedProfileEntry[0]
    $profileFiles=@($selectedProfileEntry.files)
    if($profileFiles.Count -ne 2 -or @($profileFiles|Where-Object {$_.Name -cin @('nvngx_dlss.dll','nvngx_dlssd.dll')}).Count -ne 2 -or @($profileFiles|Select-Object -ExpandProperty Name -Unique).Count -ne 2){throw 'The selected DLSS profile must contain exactly the SR and RR runtime files.'}
    foreach($file in $profileFiles){if([string]$file.SourceTag -notmatch '^v\d+\.\d+\.\d+$' -or [string]$file.Version -notmatch '^\d+\.\d+\.\d+\.\d+$' -or [string]$file.SHA256 -notmatch '^[A-Fa-f0-9]{64}$'){throw 'The selected DLSS profile has an invalid source, version or hash.'}}
    $profileNames=@($profileFiles|ForEach-Object {[string]$_.Name})
    if(@($baseFiles|Where-Object {$_.Name -in $profileNames}).Count -gt 0 -or @($baseFiles|Select-Object -ExpandProperty Name -Unique).Count -ne $baseFiles.Count){throw 'The base NVIDIA catalogue must contain unique files separate from the selected SR/RR profile.'}
    $files=@($baseFiles)+$profileFiles
    $streamline=ReadOptiShadeJson "$PSScriptRoot/streamline-files.json" 'Streamline catalogue JSON' -Shape Object
    $engine=OwnedPath $Game 'OptiShadeData/Engine'
    $dlssPending=@($files|Where-Object {(HashFile (OwnedPath $engine $_.Name)) -ne $_.SHA256})
    $slPending=@($streamline.files|Where-Object {(HashFile (OwnedPath $engine ('streamline/'+$_.name))) -ne $_.sha256})
    foreach($file in $dlssPending){
        if([string]$file.SourceTag -notmatch '^v\d+\.\d+\.\d+$' -or [string]$file.Version -notmatch '^\d+\.\d+\.\d+\.\d+$'){throw 'The pinned NVIDIA runtime catalogue has an invalid version or source tag.'}
        $displayVersion=[string]$file.Version -replace '\.0$',''
        &$Progress "Downloading signed NVIDIA DLSS ${displayVersion}: $($file.Name)"
        $dest=OwnedPath $staging $file.Name
        GetVerifiedDownload "https://raw.githubusercontent.com/NVIDIA/DLSS/$($file.SourceTag)/lib/Windows_x86_64/rel/$($file.Name)" $dest $file.SHA256
        AssertNvidiaFile $dest
        if(-not (TestNvidiaFileVersion (Get-Item -LiteralPath $dest).VersionInfo ([string]$file.Version))){throw 'The NVIDIA runtime file version did not match its pinned catalogue entry.'}
    }
    if($dlssPending.Count -eq 0){&$Progress 'Verified NVIDIA DLSS files already installed - skipping downloads.'}
    if($slPending.Count){
    &$Progress 'Downloading the matching NVIDIA frame-generation files...'
    $zip=OwnedPath $staging 'streamline.zip';GetVerifiedDownload $streamline.archiveUrl $zip $streamline.archiveSha256
    $archive=[IO.Compression.ZipFile]::OpenRead($zip)
    try{foreach($file in $streamline.files){
        $entry=$archive.GetEntry($file.entry);if(-not $entry){throw 'A required NVIDIA file was missing.'}
        $dest=OwnedPath $staging ('streamline/'+$file.name);New-Item -ItemType Directory (Split-Path $dest) -Force|Out-Null
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$dest,$true)
        if((HashFile $dest) -ne $file.sha256){throw 'NVIDIA frame-generation file verification failed.'}
        if($file.name.EndsWith('.dll')){AssertNvidiaFile $dest}
    }}finally{$archive.Dispose()}
    }else{&$Progress 'Verified Streamline files already installed - skipping download.'}
    $engine=OwnedPath $Game 'OptiShadeData/Engine';New-Item -ItemType Directory $engine,(Join-Path $engine 'streamline') -Force|Out-Null
    foreach($file in $dlssPending){Move-Item -LiteralPath (OwnedPath $staging $file.Name) -Destination (OwnedPath $engine $file.Name) -Force}
    if($slPending.Count){foreach($file in $streamline.files){Move-Item -LiteralPath (OwnedPath $staging ('streamline/'+$file.name)) -Destination (OwnedPath $engine ('streamline/'+$file.name)) -Force};Remove-Item -LiteralPath $zip -Force}
    $sr=@($files|Where-Object {$_.Name -ceq 'nvngx_dlss.dll'})[0]
    $rr=@($files|Where-Object {$_.Name -ceq 'nvngx_dlssd.dll'})[0]
    $fg=@($files|Where-Object {$_.Name -ceq 'nvngx_dlssg.dll'})[0]
    $report=[ordered]@{DlssRuntimeProfile=$selectedProfileEntry.id;DlssRuntimeProfileLabel=$selectedProfileEntry.label;InstalledDLSSSR=$sr.Version;InstalledDLSSRR=$rr.Version;InstalledDLSSG=$fg.Version;FrameGenerationProfile="Pinned Streamline $($streamline.version) / DLSS FG $($fg.Version -replace '\.0$','')";LatestDLSS=$latest;InstalledStreamline=$streamline.version;LatestStreamline=$latestSl;Checked=(Get-Date -Format o);NeuralRendering='Separate signed model/runtime selection; not changed by the DLSS SR/RR profile';Files=@($files|ForEach-Object{[ordered]@{Name=$_.Name;Version=$_.Version;SourceTag=$_.SourceTag;SHA256=$_.SHA256}})}
    $report|ConvertTo-Json -Depth 5|Set-Content (OwnedPath $Game 'OptiShadeData/NVIDIA-versions.json') -Encoding UTF8
    if($latest -ne $sr.SourceTag -or $latestSl -ne ('v'+$streamline.version)){&$Progress 'Installed the pinned NVIDIA files. A newer release or an unavailable version check is recorded in NVIDIA-versions.json.'}
}

