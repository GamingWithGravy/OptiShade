function ReadOptiShadeJson([string]$Path,[string]$Role='saved state',[int]$MaxBytes=4194304,[ValidateSet('Object','Array','Any')][string]$Shape='Object'){
 $bytes=0;$digest='unavailable'
 for($attempt=0;$attempt -lt 3;$attempt++){
  try{
   $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop;$bytes=$item.Length
   if($item.PSIsContainer -or $bytes -le 0 -or $bytes -gt $MaxBytes -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Not bounded regular JSON'}
   $stream=[IO.File]::Open($item.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
   try{
    if($stream.Length -gt $MaxBytes){throw 'JSON grew beyond its budget'}
    $buffer=New-Object byte[] ([int]$stream.Length);$count=0
    while($count -lt $buffer.Length){$n=$stream.Read($buffer,$count,$buffer.Length-$count);if(-not $n){throw 'JSON was truncated during read'};$count+=$n}
   }finally{$stream.Dispose()}
   $sha=[Security.Cryptography.SHA256]::Create();try{$digest=[BitConverter]::ToString($sha.ComputeHash($buffer)).Replace('-','')}finally{$sha.Dispose()}
   $text=[Text.Encoding]::UTF8.GetString($buffer).TrimStart([char]0xFEFF).Trim()
   if(($Shape -eq 'Object' -and -not $text.StartsWith('{')) -or ($Shape -eq 'Array' -and -not $text.StartsWith('['))){throw 'Unexpected JSON shape'}
   # Assign before wrapping: Windows PowerShell 5.1 emits the JSON array as
   # one pipeline object, whereas PowerShell 7 enumerates it.
   $value=$text|ConvertFrom-Json -ErrorAction Stop
   if($Shape -eq 'Array'){$value=@($value)}
   if($null -eq $value -or ($Shape -eq 'Object' -and $value -isnot [pscustomobject])){throw 'Unexpected JSON value'}
   return ,$value
  }catch{if($attempt -lt 2){Start-Sleep -Milliseconds 30}}
 }
 throw "$Role could not be read or validated ($([IO.Path]::GetFileName($Path)), $bytes bytes, SHA256 $digest). The original file was retained; no cache or installation was reset. Retry from the manager or repair this recorded operation."
}
