$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$s=Get-Content Beta/installer/manager.ps1 -Raw -Encoding UTF8
$markup=[regex]::Match($s,'(?s)<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="OptiShade guides".*?</Window>').Value
if(-not $markup){throw 'Guide markup not found'}
$w=[Windows.Markup.XamlReader]::Parse($markup)
[xml]$theme=Get-Content Beta/installer/dialog-theme.xaml -Raw
$w.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($theme)))
[xml]$manager=Get-Content Beta/installer/manager.xaml -Raw -Encoding UTF8
$m=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($manager))
$w.FindName('Guide').Style=$m.FindResource([Windows.Controls.ComboBox]);$w.FindName('Guide').ItemsSource=@('Tutorial','How it works','Features');$w.FindName('Guide').SelectedIndex=0
$w.FindName('Reading').Text=Get-Content Beta/installer/Help/Tutorial.txt -Raw -Encoding UTF8
foreach($name in @('GuideHeader','GuideClose','Guide','Reading')){if(-not $w.FindName($name)){throw "Missing guide control: $name"}}
$w.Content.Measure([Windows.Size]::new(800,700));$w.Content.Arrange([Windows.Rect]::new(0,0,800,700));$w.Content.UpdateLayout()
$b=[Windows.Media.Imaging.RenderTargetBitmap]::new(800,700,96,96,[Windows.Media.PixelFormats]::Pbgra32);$b.Render($w.Content)
$e=[Windows.Media.Imaging.PngBitmapEncoder]::new();$e.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($b));$outputDirectory=Join-Path (Get-Location) 'test-results/r19-desktop';[void][IO.Directory]::CreateDirectory($outputDirectory);$f=[IO.File]::Create((Join-Path $outputDirectory 'Guides.png'));try{$e.Save($f)}finally{$f.Dispose()}
$w.Close();$m.Close()
'PASS: production guide XAML, themed controls, text and named bindings render.'
