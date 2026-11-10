# Approved owner-supplied 13 October concept artwork. Only the three decorative
# aircraft image regions are displayed; all UI, text and controls remain native.
function GetOptiShadeConceptArtwork([string]$Simulator) {
 $rect=if($Simulator -match '2024'){@(363,345,82,84)}elseif($Simulator -match '2020'){@(704,345,82,84)}elseif($Simulator -match 'X.?Plane'){@(1044,345,82,84)}else{$null}
 if(-not $rect){return $null}
 try {
  $source=[Windows.Media.Imaging.BitmapImage]::new()
  $source.BeginInit();$source.CacheOption='OnLoad';$source.UriSource=[uri](Join-Path $PSScriptRoot 'ConceptArtwork.png');$source.EndInit();$source.Freeze()
  $crop=[Windows.Media.Imaging.CroppedBitmap]::new($source,[Windows.Int32Rect]::new($rect[0],$rect[1],$rect[2],$rect[3]));$crop.Freeze();return $crop
 }catch{return $null}
}
