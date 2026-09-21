# Downloads the same public shader catalogue used by earlier OptiShade previews.
# Archives are transport files only, never release packages or executable content.
function DownloadShaderArchive([uri]$Uri,[string]$Destination){
    $urls=@($Uri.AbsoluteUri)
    if($Uri.AbsoluteUri -match '^https://github.com/([^/]+)/([^/]+)/archive/(.+)\.zip$'){$urls+='https://codeload.github.com/'+$Matches[1]+'/'+$Matches[2]+'/zip/'+$Matches[3]}
    for($attempt=0;$attempt -lt 3;$attempt++){
        $web=New-Object Net.WebClient
        try{
            $web.Headers['User-Agent']='OptiShade-FusionEngine'
            $task=$web.DownloadFileTaskAsync([uri]$urls[([Math]::Min($attempt,$urls.Count-1))],$Destination)
            $timer=[Diagnostics.Stopwatch]::StartNew()
            while(-not $task.IsCompleted){if($timer.Elapsed.TotalSeconds -gt 90){$web.CancelAsync();throw 'Shader download timed out.'};Start-Sleep -Milliseconds 100;if('System.Windows.Forms.Application' -as [type]){[Windows.Forms.Application]::DoEvents()}}
            $task.GetAwaiter().GetResult();return
        }catch{if($attempt -eq 2){throw}}finally{$web.Dispose()}
    }
}
function InstallAllEffects([string]$Game,[string]$Catalogue,[scriptblock]$Progress={param($text) Write-Output $text}){
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $packages=@();$current=$null
    foreach($line in Get-Content -LiteralPath $Catalogue){
        if($line -match '^\[(.+)\]$'){$current=@{Id=$Matches[1]};$packages+=,$current}
        elseif($current -and $line -match '^([^=]+)=(.*)$'){$current[$Matches[1]]=$Matches[2]}
    }
    $data=OwnedPath $Game 'OptiShadeData';$results=@();$index=0
    $previous=@();$report=OwnedPath $Game 'OptiShadeData/Effects-install.json'
    if(Test-Path -LiteralPath $report){try{$previous=Get-Content -LiteralPath $report -Raw|ConvertFrom-Json}catch{}}
    foreach($pkg in $packages){
        $index++;$name=$pkg.PackageName;&$Progress "Installing effects $index/$($packages.Count): $name" ($index-1) $packages.Count
        $done=@($previous|Where-Object {$_.Source -eq $pkg.DownloadUrl -and $_.Status -eq 'Installed'})
        $installedRoot=OwnedPath $Game ('OptiShadeData/Shaders/Packages/'+$pkg.Id)
        $complete=$false
        if($done.Count -and (Test-Path -LiteralPath $installedRoot)){
            if($done[0].PSObject.Properties['Files'] -and @($done[0].Files).Count){
                $complete=$true
                foreach($relative in $done[0].Files){$existing=OwnedPath $data $relative;if(-not(Test-Path -LiteralPath $existing -PathType Leaf) -or (Get-Item -LiteralPath $existing).Length -eq 0){$complete=$false;break}}
            }else{
                # Upgrade old count-only receipts without downloading working packages.
                $complete=([int]$done[0].Effects -gt 0 -and @(Get-ChildItem -LiteralPath $installedRoot -Recurse -Filter '*.fx' -File|Where-Object Length -gt 0).Count -ge [int]$done[0].Effects)
                if($complete){$inventory=@(foreach($folder in @($installedRoot,(OwnedPath $Game ('OptiShadeData/Textures/Packages/'+$pkg.Id)))){if(Test-Path -LiteralPath $folder){Get-ChildItem -LiteralPath $folder -Recurse -File|ForEach-Object {$_.FullName.Substring($data.Length+1)}}});$done[0]|Add-Member -NotePropertyName Files -NotePropertyValue $inventory -Force}
            }
        }
        if($complete){&$Progress "Already installed - skipping download: $name" $index $packages.Count;$results+=$done[0];continue}
        $cache=OwnedPath $Game ('OptiShadeData/Downloads/'+$pkg.Id+'.zip')
        New-Item -ItemType Directory -Path (Split-Path $cache) -Force|Out-Null
        $client=New-Object Net.WebClient;$archive=$null;$count=0;$inventory=New-Object 'System.Collections.Generic.List[string]'
        try{
            $uri=[uri]$pkg.DownloadUrl;if($uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com'){throw 'Unexpected shader download address.'}
            DownloadShaderArchive $uri $cache
            $archive=[IO.Compression.ZipFile]::OpenRead($cache)
            $shaderRoot='OptiShadeData/Shaders/Packages/'+$pkg.Id+'/'
            $textureRoot='OptiShadeData/Textures/Packages/'+$pkg.Id+'/'
            $allow=@($pkg.EffectFiles -split ','|Where-Object {$_});$deny=@($pkg.DenyEffectFiles -split ','|Where-Object {$_})
            foreach($entry in $archive.Entries){
                if(-not $entry.Name){continue}
                $relative=($entry.FullName -replace '\\','/') -replace '^[^/]+/','';$ext=[IO.Path]::GetExtension($entry.Name).ToLowerInvariant()
                if($ext -eq '.fx' -and ($entry.Name -in $deny)){continue}
                if($ext -in @('.fx','.fxh','.h','.hlsl')){
                    $relative=$relative -replace '^(?i:reshade-shaders/)?(?i:Shaders)/','';$dest=OwnedPath (OwnedPath $Game $shaderRoot) $relative;if($ext -eq '.fx'){$count++}
                }elseif($ext -in @('.png','.dds','.jpg','.jpeg','.bmp','.cube','.tga','.lut')){
                    $relative=$relative -replace '^(?i:reshade-shaders/)?(?i:Textures)/','';$dest=OwnedPath (OwnedPath $Game $textureRoot) $relative
                }elseif($entry.Name -match '^(?i:LICENSE|COPYING|NOTICE|README)'){$dest=OwnedPath (OwnedPath $Game ('OptiShadeData/Licenses/Shaders/'+$pkg.Id)) $relative}else{continue}
                New-Item -ItemType Directory -Path (Split-Path $dest) -Force|Out-Null
                # Repair missing files without replacing existing custom edits.
                if(-not(Test-Path -LiteralPath $dest) -or (Get-Item -LiteralPath $dest).Length -eq 0){[IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$dest,$true)}
                $inventory.Add($dest.Substring($data.Length+1))
            }
            if($count -eq 0){throw 'No compatible effects were found in this pack.'}
            $results+=[pscustomobject]@{Name=$name;Source=$pkg.DownloadUrl;Effects=$count;Status='Installed';SHA256=(HashFile $cache);Files=@($inventory.ToArray())}
        }catch{$results+=[pscustomobject]@{Name=$name;Source=$pkg.DownloadUrl;Effects=$count;Status='Failed';Error=$_.Exception.Message}}
        finally{if($archive){$archive.Dispose()};$client.Dispose();if(Test-Path -LiteralPath $cache){Remove-Item -LiteralPath $cache -Force}}
        # Keep completed receipts even if the installer closes during the next pack.
        $checkpoint=@($results)+@($previous|Where-Object {$_.Source -notin $results.Source})
        $checkpoint|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $report -Encoding UTF8
        &$Progress "Checked effects $index/$($packages.Count): $name" $index $packages.Count
    }
    # Some public packs include ../ReShade.fxh relative to their pack folder.
    # Keep the standard headers at that shared parent as well as in their pack.
    foreach($header in @('ReShade.fxh','ReShadeUI.fxh')){
        $source=OwnedPath $Game ('OptiShadeData/Shaders/Packages/00/'+$header)
        if(Test-Path -LiteralPath $source){Copy-Item -LiteralPath $source -Destination (OwnedPath $Game ('OptiShadeData/Shaders/Packages/'+$header)) -Force}
    }
    $results|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (OwnedPath $Game 'OptiShadeData/Effects-install.json') -Encoding UTF8
    $failed=@($results|Where-Object Status -eq 'Failed');$total=($results|Measure-Object Effects -Sum).Sum
    if($failed.Count){throw "$total effects installed; $($failed.Count) packs are unfinished. Use Retry unfinished downloads. Details are in OptiShadeData/Effects-install.json."}
    return "$total effects installed from $($results.Count) packs. Press Insert in game to choose your look."
}
