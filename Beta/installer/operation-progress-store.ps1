function WriteOptiShadeOperationProgressState([string]$Path,$State){
 if([string]::IsNullOrWhiteSpace($Path)){throw 'Operation progress path is empty.'}
 $folder=Split-Path -Parent $Path
 [void][IO.Directory]::CreateDirectory($folder)
 $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 try{
  $json=ConvertTo-Json -InputObject $State -Depth 6 -Compress
  if([Text.Encoding]::UTF8.GetByteCount($json) -gt 1MB){throw 'Operation progress state exceeded its safety limit.'}
  [IO.File]::WriteAllText($temporary,$json,[Text.UTF8Encoding]::new($false))
  for($attempt=0;$attempt -lt 12;$attempt++){
   try{
    if([IO.File]::Exists($Path)){[IO.File]::Replace($temporary,$Path,[System.Management.Automation.Language.NullString]::Value)}
    else{[IO.File]::Move($temporary,$Path)}
    return
   }catch [IO.IOException]{
    if($attempt -ge 11){throw}
    Start-Sleep -Milliseconds ([Math]::Min(100,10*($attempt+1)))
   }catch [UnauthorizedAccessException]{
    if($attempt -ge 11){throw}
    Start-Sleep -Milliseconds ([Math]::Min(100,10*($attempt+1)))
   }
  }
  throw 'Operation progress state could not be published.'
 }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}
function ReadOptiShadeOperationProgressState([string]$Path){
 $share=[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
 $stream=$null
 # Atomic replacement can briefly deny a new open even with delete sharing.
 # Retry that transient contention; never return an empty or partial snapshot.
 for($attempt=0;$attempt -lt 6;$attempt++){
  try{$stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,$share);break}
  catch [IO.IOException]{if($attempt -ge 5 -or ($_.Exception.HResult -band 0xffff) -notin @(2,32,33)){throw};Start-Sleep -Milliseconds 10}
 }

 try{
  $reader=[IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false),$true)
  try{return $reader.ReadToEnd()}finally{$reader.Dispose()}
 }finally{$stream.Dispose()}
}
