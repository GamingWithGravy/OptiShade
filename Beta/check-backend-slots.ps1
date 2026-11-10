param([string]$Root=$PSScriptRoot)
$ErrorActionPreference='Stop'
# Inspect actual route-owned allocations, including nested C++ template types.
# A slot is process-local storage shared across renderer/forwarder components.
$entries=@()
foreach($dir in @('shared','optiscaler/OptiScaler','reshade/source','routes')){
 foreach($file in Get-ChildItem -LiteralPath (Join-Path $Root $dir) -Recurse -File | Where-Object Extension -in '.h','.hpp','.cpp','.inl'){
  $source=[IO.File]::ReadAllText($file.FullName)
  foreach($match in [regex]::Matches($source,'\broute::(?:Owned|Backend)<')){
   $start=$match.Index+$match.Length;$depth=1;$comma=-1;$end=-1
   for($i=$start;$i -lt $source.Length;$i++){
    if($source[$i] -eq '<'){$depth++}
    elseif($source[$i] -eq '>'){$depth--;if($depth -eq 0){$end=$i;break}}
    elseif($source[$i] -eq ',' -and $depth -eq 1){$comma=$i}
   }
   if($end -lt 0 -or $comma -lt 0){throw "Cannot inspect backend allocation in $($file.FullName)"}
   $slot=$source.Substring($comma+1,$end-$comma-1).Trim()
   if($slot -notmatch '^\d+$'){throw "Backend slot must have an auditable numeric identity: $($file.FullName): $slot"}
   if([int]$slot -ge 32){throw "Backend slot exceeds route capacity: $slot"}
   $type=$source.Substring($start,$comma-$start) -replace '\s+',''
   $entries+=[pscustomobject]@{Slot=[int]$slot;Type=$type;File=$file.FullName.Substring($Root.Length+1)}
  }
 }
}
foreach($group in $entries | Group-Object Slot){
 $types=@($group.Group.Type | Sort-Object -Unique)
 if($types.Count -ne 1){throw "Conflicting backend slot $($group.Name): $($types -join ' versus ')"}
}
$entries | Sort-Object Slot,Type,File -Unique
