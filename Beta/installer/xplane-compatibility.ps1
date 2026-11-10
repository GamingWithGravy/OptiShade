# Per-game opt-in diagnostics. Missing or invalid settings keep the native route.
function GetOptiShadeXPlaneRoute([string]$Game){
 $file=OwnedPath $Game 'OptiShadeData/XPlane-compatibility.ini'
 if(-not(Test-Path -LiteralPath $file -PathType Leaf)){return 'native-vulkan'}
 if((Get-Item -LiteralPath $file).Length -gt 64KB){throw 'X-Plane compatibility settings exceed the size limit.'}
 $section=''
 foreach($line in [IO.File]::ReadAllLines($file)){
  if($line -match '^\s*\[([^\]]+)\]'){$section=$Matches[1].Trim();continue}
  if($section -ieq 'XPlane' -and $line -match '^\s*GraphicsRoute\s*=\s*([^;#\s]+)'){
   $route=$Matches[1].ToLowerInvariant()
   if($route -in @('native-vulkan','legacy-dxgi','menu-only')){return $route}
   return 'native-vulkan'
  }
 }
 return 'native-vulkan'
}
function SetOptiShadeXPlaneRoute([string]$Game,[ValidateSet('native-vulkan','legacy-dxgi','menu-only')][string]$Route){
 $exe=OwnedPath $Game 'X-Plane.exe'
 if(-not(Test-Path -LiteralPath $exe -PathType Leaf)){throw 'Choose the X-Plane installation folder before saving its graphics route.'}
 $file=OwnedPath $Game 'OptiShadeData/XPlane-compatibility.ini'
 $text='';$encoding=[Text.UTF8Encoding]::new($false)
 if(Test-Path -LiteralPath $file){
  if((Get-Item -LiteralPath $file).Length -gt 64KB){throw 'X-Plane compatibility settings exceed the size limit.'}
  $bytes=[IO.File]::ReadAllBytes($file)
  if($bytes.Length -ge 2 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254){$encoding=[Text.Encoding]::Unicode}
  elseif($bytes.Length -ge 2 -and $bytes[0] -eq 254 -and $bytes[1] -eq 255){$encoding=[Text.Encoding]::BigEndianUnicode}
  elseif($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191){$encoding=[Text.UTF8Encoding]::new($true)}
  $text=[IO.File]::ReadAllText($file)
 }
 $newline=if($text.Contains("`r`n")){"`r`n"}else{"`n"}
 $lines=[Collections.Generic.List[string]]::new();$section='';$inserted=$false;$foundSection=$false
 foreach($line in ($text -split '\r?\n')){
  if($line -match '^\s*\[([^\]]+)\]'){
   if($section -ieq 'XPlane' -and -not $inserted){$lines.Add('GraphicsRoute='+$Route);$inserted=$true}
   $section=$Matches[1].Trim();if($section -ieq 'XPlane'){$foundSection=$true}
  }
  if($section -ieq 'XPlane' -and $line -match '^\s*GraphicsRoute\s*='){
   if(-not $inserted){$lines.Add('GraphicsRoute='+$Route);$inserted=$true};continue
  }
  $lines.Add($line)
 }
 if(-not $inserted){if(-not $foundSection){$lines.Add('[XPlane]')};$lines.Add('GraphicsRoute='+$Route)}
 [void][IO.Directory]::CreateDirectory((Split-Path $file))
 $temporary=$file+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 try{
  [IO.File]::WriteAllText($temporary,($lines -join $newline),$encoding)
  if(Test-Path -LiteralPath $file){[IO.File]::Replace($temporary,$file,[Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temporary,$file)}
 }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
}
