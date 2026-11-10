param([string]$Manager,[string]$Payload,[string]$Installer,[switch]$Appearance,[string]$ScreenshotDirectory,[double]$WindowWidth=1344,[double]$WindowHeight=985,[switch]$CaptureSplash,[string]$CockpitManifest)

$ErrorActionPreference='Stop'

if($PSVersionTable.PSEdition -eq 'Core'){throw 'Run with Windows PowerShell 5.1, matching the packaged host.'}

$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

if(-not $Manager){$Manager=Join-Path $root 'Beta/installer/manager.ps1'}

if(-not $Payload){$Payload=Join-Path (Split-Path $Manager) 'PayloadFusion'}

if(-not $Installer){
 $candidates=@(Get-ChildItem -LiteralPath (Join-Path $root 'Beta/dist') -Filter 'OptiShade_Version_*.exe' -File -ErrorAction SilentlyContinue|ForEach-Object {
  $info=[Diagnostics.FileVersionInfo]::GetVersionInfo($_.FullName)
  $version=[string]$info.ProductVersion
  if($version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$'){$version=[string]$info.FileVersion}
  if($version -match '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$'){[pscustomobject]@{Path=$_.FullName;Version=[version]($version -replace '-.*$','')}}
 })
 if(-not $candidates.Count){throw 'No versioned OptiShade EXE is available for the startup fixture; pass -Installer explicitly.'}
 $Installer=($candidates|Sort-Object Version -Descending|Select-Object -First 1).Path
}

$tokens=$null;$errors=$null

$ast=[Management.Automation.Language.Parser]::ParseFile($Manager,[ref]$tokens,[ref]$errors)
$parameterNames=@($ast.ParamBlock.Parameters|ForEach-Object {$_.Name.VariablePath.UserPath})
if($errors.Count -or -not $ast.ParamBlock -or $parameterNames.Count -lt 2 -or $parameterNames[0] -ne 'Payload' -or $parameterNames[1] -ne 'Installer' -or 'StartInTray' -notin $parameterNames -or 'UninstallMode' -notin $parameterNames){throw 'Manager must bind Payload and Installer first, and retain its tray-start and verified-uninstall switches.'}

$env:OPTISHADE_STORE=Join-Path $root ('test-results/startup-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($env:OPTISHADE_STORE)
# This isolated GUI smoke test exercises the real startup path without
# presenting the first-run safety agreement to the desktop user.
$agreement=[ordered]@{Schema=1;Accepted=$true;WarningVersion=1;AcceptedUtc=[datetime]::UtcNow.ToString('o')}
[IO.File]::WriteAllText((Join-Path $env:OPTISHADE_STORE 'anti-cheat-install-acceptance.json'),($agreement|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($true))

# Optional read-only live-update integration: copy only the receipt into an
# isolated app store. The game/addon itself is neither installed nor updated.
if($CockpitManifest){
 $fixtureFolder=Join-Path $env:OPTISHADE_STORE ('Games/'+(Split-Path (Split-Path $CockpitManifest) -Leaf))
 [void][IO.Directory]::CreateDirectory($fixtureFolder)
 Copy-Item -LiteralPath $CockpitManifest -Destination (Join-Path $fixtureFolder 'manifest.json')
}

Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase

$probe=@{Seen=$false;Ticks=0;Appearance=$false;Failure=""}

$timer=New-Object Windows.Threading.DispatcherTimer

$timer.Interval=[TimeSpan]::FromSeconds(1)

$timer.Add_Tick({

 $probe.Ticks++

 foreach($source in @([Windows.PresentationSource]::CurrentSources)){

  $window=$source.RootVisual

  if($window -is [Windows.Window] -and $window.FindName('HomePage')){

   $probe.Seen=$true

   $window.Width=$WindowWidth;$window.Height=$WindowHeight

   if($Appearance -and -not $probe.Appearance){

    $probe.Appearance=$true

    try{

     $window.FindName('ThemeLight').IsChecked=$true

     if($window.Resources['TextPrimary'].Color.ToString() -ne '#FF251A35'){throw 'Light theme did not apply'}

     $window.FindName('ThemeDark').IsChecked=$true

     if($window.Resources['TextPrimary'].Color.ToString() -ne '#FFF3EFFB'){throw 'Dark theme did not apply'}

     $window.FindName('Accent1').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))

     if($window.Resources['ActionPurple'].GradientStops[0].Color.ToString() -ne '#FF2477FF'){throw 'Accent did not apply'}

     $window.FindName('Accent0').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))

     if(-not (Test-Path (Join-Path $env:OPTISHADE_STORE 'manager-interface.json'))){throw 'Appearance settings were not saved'}

    }catch{$probe.Failure=$_.Exception.Message}

   }

   if($probe.Ticks -ge 12){
    if($CockpitManifest){
     $notice=$window.FindName('HeaderComponentUpdateAvailable')
     if($notice.Visibility -ne 'Visible' -or [string]$notice.Content -ne 'Component updates available'){
      if($probe.Ticks -lt 45){return}
      $probe.Failure='The live cockpit release did not reach the visible manager header.'
     }else{Write-Output ('PASS: live notification visible: '+$notice.Content)}
    }


    foreach($dialog in @($window.OwnedWindows)){$dialog.Close()}

    if($ScreenshotDirectory){

     try{

      [void][IO.Directory]::CreateDirectory($ScreenshotDirectory)

      $window.FindName('Intro').Visibility='Collapsed'

      $capturePages=@('Home','Setup','Components','Updates','Keybinds','Troubleshooting','Settings');if($CaptureSplash){$capturePages+=@('Splash')}

      foreach($page in $capturePages){

       if($page -eq 'Splash'){$window.FindName('Intro').Visibility='Visible'}else{$window.FindName($page+'Nav').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))};$window.UpdateLayout()

       if($CockpitManifest -and $page -eq 'Components'){
        $picker=$window.FindName('ComponentsGame');$picker.SelectedItem=@($picker.ItemsSource|Where-Object {$_.Name -match '2024'})[0]
        $window.UpdateLayout()
        if($window.FindName('AddonCockpitStatus').Text -notmatch '^Installed v' -or $window.FindName('AddonCockpitUpdateState').Text -notmatch 'Installed v.*Available v'){
         throw 'The cockpit card did not display installed and available versions after clicking the real update banner.'
        }
       }

       if($CockpitManifest -and $page -eq 'Updates'){
        $window.FindName('HeaderComponentUpdateAvailable').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        $window.UpdateLayout()
        if($window.FindName('UpdatesPage').Visibility -ne 'Visible' -or $window.FindName('UpdatesGames').Children.Count -eq 0){throw 'Update Manager did not display live update rows.'}
        if($window.FindName('UpdatesNav').Foreground.ToString() -ne '#FFFFD16A'){throw 'Update Manager notification was not yellow.'}
       }
       $viewer=$window.FindName($(if($page -eq 'Splash'){'HomePage'}else{$page+'Page'}));[IO.File]::AppendAllText((Join-Path $ScreenshotDirectory "layout.txt"),("{0}: scroll={1:F1}, viewport={2:F1}, extent={3:F1}{4}" -f $page,$viewer.ScrollableHeight,$viewer.ViewportHeight,$viewer.ExtentHeight,[Environment]::NewLine))

       $surface=$window.Content;$bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$surface.ActualWidth,[int]$surface.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($surface)

       $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))

       $stream=[IO.File]::Create((Join-Path $ScreenshotDirectory ($page+'.png')));try{$encoder.Save($stream)}finally{$stream.Dispose()}

      }

     }catch{$probe.Failure=$_.Exception.Message}

    }

    $window.Close();$timer.Stop()

   }

  }

 }

}.GetNewClosure())

$timer.Start()

try{& $Manager -Payload $Payload -Installer $Installer}

catch{Write-Output $_.ScriptStackTrace;throw}

finally{$timer.Stop()}

if($probe.Failure){throw $probe.Failure}

if($Appearance -and -not $probe.Appearance){throw 'Appearance test did not run'}

if(-not $probe.Seen){throw 'Manager never displayed its real window.'}

Write-Output 'PASS: production manager parameter binding, startup and displayed window (isolated store; no installation actions).'


