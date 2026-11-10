# Test data only. This writes enough PE structure for the production metadata
# reader; these bytes are never executed or loaded as a provider/game.
function WriteOptiShadeFixtureExecutable([string]$Path,[ValidateSet('x86','x64')][string]$Architecture='x64'){
 $x86=$Architecture -eq 'x86';$bytes=New-Object byte[] 1024;$stream=[IO.MemoryStream]::new($bytes,$true);$writer=[IO.BinaryWriter]::new($stream)
 try{
  $writer.Write([uint16]0x5a4d);$stream.Position=0x3c;$writer.Write([uint32]0x80)
  $stream.Position=0x80;$writer.Write([uint32]0x4550);$writer.Write([uint16]$(if($x86){0x14c}else{0x8664}));$writer.Write([uint16]1)
  $optional=if($x86){224}else{240};$stream.Position=0x94;$writer.Write([uint16]$optional);$writer.Write([uint16]2);$writer.Write([uint16]$(if($x86){0x10b}else{0x20b}))
  $stream.Position=0x98+60;$writer.Write([uint32]512);$stream.Position=0x98+$optional+8;$writer.Write([uint32]512);$writer.Write([uint32]0x1000);$writer.Write([uint32]512);$writer.Write([uint32]512)
 }finally{$writer.Dispose()}
 [IO.File]::WriteAllBytes($Path,$bytes)
}
