param([Parameter(Mandatory=$true)][string]$Executable,[Parameter(Mandatory=$true)][string]$Version)
$ErrorActionPreference='Stop'
if((& git -C $PSScriptRoot branch --show-current) -ne 'beta'){throw 'Beta downloads may only be prepared on the beta branch.'}
if($Version -notmatch '^\d+\.\d+\.\d+-beta\.\d+$'){throw 'A beta version is required.'}
$exe=(Resolve-Path -LiteralPath $Executable).Path
$size=(Get-Item -LiteralPath $exe).Length
if($size -le 0 -or $size -gt 512MB){throw 'Invalid beta installer size.'}
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'downloads/beta'))
[void][IO.Directory]::CreateDirectory($root)
$parts=@();$input=[IO.File]::OpenRead($exe)
try{
 $buffer=New-Object byte[] (40MB);$index=0
 while($input.Position -lt $input.Length){
  $count=0
  while($count -lt $buffer.Length){$n=$input.Read($buffer,$count,$buffer.Length-$count);if(-not $n){break};$count+=$n}
  $index++;$name='OptiShade-beta.part'+$index.ToString('00');$path=Join-Path $root $name
  $output=[IO.File]::Create($path);try{$output.Write($buffer,0,$count)}finally{$output.Dispose()}
  $parts+=@{name=$name;bytes=$count;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
 }
}finally{$input.Dispose()}
# Only obsolete generated part files in this exact output directory are removed.
foreach($file in Get-ChildItem -LiteralPath $root -File){
 if($file.Name -cmatch '^OptiShade-beta\.part\d{2}$' -and $file.Name -notin $parts.name){Remove-Item -LiteralPath $file.FullName -Force}
}
$manifest=[ordered]@{schema=1;channel='beta';version=$Version;bytes=$size;sha256=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant();parts=$parts;notes=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'installer/Help/Release-notes.txt'))}
[IO.File]::WriteAllText((Join-Path $root 'manifest.json'),($manifest|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
"Prepared $($parts.Count) verified beta download parts. No GitHub release was created."
