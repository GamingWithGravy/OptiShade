param([string]$Output='test-results/r15-auxiliary')
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
New-Item -ItemType Directory -Path $Output -Force|Out-Null
function Render($w,$name,$width,$height){
 $w.Content.Measure([Windows.Size]::new($width,$height));$w.Content.Arrange([Windows.Rect]::new(0,0,$width,$height));$w.Content.UpdateLayout()
 $b=[Windows.Media.Imaging.RenderTargetBitmap]::new($width,$height,96,96,[Windows.Media.PixelFormats]::Pbgra32);$b.Render($w.Content)
 $e=[Windows.Media.Imaging.PngBitmapEncoder]::new();$e.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($b));$f=[IO.File]::Create((Join-Path (Resolve-Path $Output) ($name+'.png')));try{$e.Save($f)}finally{$f.Dispose()}
}
[xml]$x=Get-Content Beta/installer/manager.xaml -Raw -Encoding UTF8
$w=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($x));Render $w 'splash' 1344 985;$w.Close()
[xml]$x=Get-Content Beta/installer/Troubleshooter/src/UI.xaml -Raw -Encoding UTF8
$w=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($x))
$source=Get-Content Beta/installer/Troubleshooter/src/Shell.cs -Raw -Encoding UTF8
foreach($m in [regex]::Matches($source,'Find<[^>]+>\("([^"]+)"\)')){if(-not $w.FindName($m.Groups[1].Value)){throw "Missing troubleshooter binding $m"}}
$w.FindName('ReportPage').Visibility='Collapsed';Render $w 'simulators' 1200 900
$w.FindName('SimulatorPage').Visibility='Collapsed';$w.FindName('ReportPage').Visibility='Visible';Render $w 'report' 1200 900
if($w.FindName('ReportPage').ScrollableHeight -gt 0){throw 'Report unnecessarily scrolls at default size'}
Render $w 'report-small' 920 680
if($w.FindName('ReportPage').ScrollableHeight -le 0){throw 'Small-window overflow is inaccessible'}
$w.Close()
$s=Get-Content Beta/installer/release-notes.ps1 -Raw -Encoding UTF8
$markup=[regex]::Match($s,"(?s)\[xml\]\`$markup=@'\s*(.*?)\s*'@").Groups[1].Value
if(-not $markup){throw 'Notes markup missing'}
$w=[Windows.Markup.XamlReader]::Parse($markup)
[xml]$x=Get-Content Beta/installer/dialog-theme.xaml -Raw -Encoding UTF8
$w.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($x)))
$w.FindName('Title').Text="What's new in OptiShade"
$w.FindName('Notes').Text=Get-Content Beta/installer/Help/Release-notes.txt -Raw -Encoding UTF8
Render $w 'notes' 900 760;$w.Close()
'PASS: auxiliary XAML and troubleshooter bindings; default report fits; small-window overflow remains accessible. Native layout renders only.'
