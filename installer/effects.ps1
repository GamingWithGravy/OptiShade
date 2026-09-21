# Downloads the same public shader catalogue used by earlier OptiShade previews.
# Archives are transport files only, never release packages or executable content.
function InstallAllEffects([string]$Game,[string]$Catalogue,[scriptblock]$Progress={param($text) Write-Output $text}){
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $packages=@();$current=$null
    foreach($line in Get-Content -LiteralPath $Catalogue){
        if($line -match '^\[(.+)\]$'){$current=@{Id=$Matches[1]};$packages+=,$current}
        elseif($current -and $line -match '^([^=]+)=(.*)$'){$current[$Matches[1]]=$Matches[2]}
    }
    $data=OwnedPath $Game 'OptiShadeData';$results=@();$index=0
    foreach($pkg in $packages){
        $index++;$name=$pkg.PackageName;&$Progress "Installing effects $index/$($packages.Count): $name" ($index-1) $packages.Count
        $cache=OwnedPath $Game ('OptiShadeData/Downloads/'+$pkg.Id+'.zip')
        New-Item -ItemType Directory -Path (Split-Path $cache) -Force|Out-Null
        $client=New-Object Net.WebClient;$archive=$null;$count=0
        try{
            $uri=[uri]$pkg.DownloadUrl;if($uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com'){throw 'Unexpected shader download address.'}
            $client.Headers['User-Agent']='OptiShade-FusionEngine'
            $download=$client.DownloadFileTaskAsync($uri,$cache)
            while(-not $download.IsCompleted){Start-Sleep -Milliseconds 100;if('System.Windows.Forms.Application' -as [type]){[Windows.Forms.Application]::DoEvents()}}
            $download.GetAwaiter().GetResult()
            $archive=[IO.Compression.ZipFile]::OpenRead($cache)
            $shaderRoot='OptiShadeData/Shaders/Packages/'+$pkg.Id+'/'
            $textureRoot='OptiShadeData/Textures/Packages/'+$pkg.Id+'/'
            $allow=@($pkg.EffectFiles -split ','|Where-Object {$_});$deny=@($pkg.DenyEffectFiles -split ','|Where-Object {$_})
            foreach($entry in $archive.Entries){
                if(-not $entry.Name){continue}
                $relative=$entry.FullName -replace '^[^/]+/','';$ext=[IO.Path]::GetExtension($entry.Name).ToLowerInvariant()
                if($ext -eq '.fx' -and ($entry.Name -in $deny)){continue}
                if($ext -in @('.fx','.fxh','.h','.hlsl')){
                    $relative=$relative -replace '^(?i:reshade-shaders/)?(?i:Shaders)/','';$dest=OwnedPath $Game ($shaderRoot+$relative);if($ext -eq '.fx'){$count++}
                }elseif($ext -in @('.png','.dds','.jpg','.jpeg','.bmp','.cube','.tga','.lut')){
                    $relative=$relative -replace '^(?i:reshade-shaders/)?(?i:Textures)/','';$dest=OwnedPath $Game ($textureRoot+$relative)
                }elseif($entry.Name -match '^(?i:LICENSE|COPYING|NOTICE|README)'){$dest=OwnedPath $Game ('OptiShadeData/Licenses/Shaders/'+$pkg.Id+'/'+$relative)}else{continue}
                New-Item -ItemType Directory -Path (Split-Path $dest) -Force|Out-Null
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$dest,$true)
            }
            if($count -eq 0){throw 'No compatible effects were found in this pack.'}
            $results+=[pscustomobject]@{Name=$name;Source=$pkg.DownloadUrl;Effects=$count;Status='Installed';SHA256=(HashFile $cache)}
        }catch{$results+=[pscustomobject]@{Name=$name;Source=$pkg.DownloadUrl;Effects=$count;Status='Failed';Error=$_.Exception.Message}}
        finally{if($archive){$archive.Dispose()};$client.Dispose();if(Test-Path -LiteralPath $cache){Remove-Item -LiteralPath $cache -Force}}
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
    if($failed.Count){throw "$total effects installed; $($failed.Count) packs could not download. Use Finish downloads to finish. Details are in OptiShadeData/Effects-install.json."}
    return "$total effects installed from $($results.Count) packs. Press Insert in game to choose your look."
}
