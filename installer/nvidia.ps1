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
function InstallNvidia([string]$Game,[scriptblock]$Progress={param($text) Write-Output $text}){
    AssertClosed $Game
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    &$Progress 'Checking NVIDIA releases...'
    $latest='Unavailable';$latestSl='Unavailable'
    try{$latest=(Invoke-RestMethod 'https://api.github.com/repos/NVIDIA/DLSS/releases/latest' -Headers @{'User-Agent'='OptiShade'} -TimeoutSec 15).tag_name}catch{}
    try{$latestSl=(Invoke-RestMethod 'https://api.github.com/repos/NVIDIA-RTX/Streamline/releases/latest' -Headers @{'User-Agent'='OptiShade'} -TimeoutSec 15).tag_name}catch{}
    $staging=OwnedPath $Game 'OptiShadeData/Downloads/NVIDIA';New-Item -ItemType Directory $staging -Force|Out-Null
    $files=Get-Content "$PSScriptRoot/nvidia-files.json" -Raw|ConvertFrom-Json
    $streamline=Get-Content "$PSScriptRoot/streamline-files.json" -Raw|ConvertFrom-Json
    $engine=OwnedPath $Game 'OptiShadeData/Engine'
    $dlssPending=@($files|Where-Object {(HashFile (OwnedPath $engine $_.Name)) -ne $_.SHA256})
    $slPending=@($streamline.files|Where-Object {(HashFile (OwnedPath $engine ('streamline/'+$_.name))) -ne $_.sha256})
    foreach($file in $dlssPending){
        &$Progress "Downloading NVIDIA DLSS 310.9.1: $($file.Name)"
        $dest=OwnedPath $staging $file.Name
        GetVerifiedDownload "https://raw.githubusercontent.com/NVIDIA/DLSS/v310.9.1/lib/Windows_x86_64/rel/$($file.Name)" $dest $file.SHA256
        AssertNvidiaFile $dest
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
    $report=[ordered]@{InstalledDLSS='310.9.1';LatestDLSS=$latest;InstalledStreamline=$streamline.version;LatestStreamline=$latestSl;Checked=(Get-Date -Format o);NeuralRendering='Requires matching original RTX 50 or compatible RTX 20/30/40 310.8 runtime';Files=@($files|ForEach-Object{[ordered]@{Name=$_.Name;Version=$_.Version;SHA256=$_.SHA256}})}
    $report|ConvertTo-Json -Depth 5|Set-Content (OwnedPath $Game 'OptiShadeData/NVIDIA-versions.json') -Encoding UTF8
    if($latest -ne 'v310.9.1' -or $latestSl -ne ('v'+$streamline.version)){&$Progress 'Installed the tested NVIDIA files. A newer release or an unavailable version check is recorded in NVIDIA-versions.json.'}
}
