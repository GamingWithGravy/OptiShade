using System;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Markup;
namespace OptiShade.TesterKit {
sealed class GameChoice {
    public string Label, Folder, Executable;
    public override string ToString(){return Label;}
}
public sealed class Shell {
    public readonly Window Window;
    CancellationTokenSource cancel;
    string folder, reportZip;
    string selectedTitle="OptiShade Troubleshooter";
    string selectedExe="";
    string selectedExecutablePath="";
    bool updatingSources;
    readonly System.Collections.Generic.List<string> knownGames=new System.Collections.Generic.List<string>();
    readonly System.Collections.Generic.Dictionary<string,string> knownExecutables=new System.Collections.Generic.Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
    Window progressWindow;
    System.Windows.Threading.DispatcherTimer progressClock;
    DateTime started;
    bool successful;
    void RaiseWindow() {
        Window.Topmost=true;
        Window.Activate();
        var timer=new System.Windows.Threading.DispatcherTimer{Interval=TimeSpan.FromMilliseconds(450)};
        timer.Tick+=(s,e)=>{timer.Stop();if(Window.IsVisible){Window.Topmost=false;Window.Activate();Window.Focus();}};
        timer.Start();
    }
    public void TestNavigation(string output) {
        Directory.CreateDirectory(output);
        string[] names={"FlightSimulator2024.exe","X-Plane.exe","SampleRacer.exe"};
        for(int i=0;i<3;i++){string dir=Path.Combine(output,"fixture-"+i);Directory.CreateDirectory(dir);File.WriteAllText(Path.Combine(dir,names[i]),"");knownGames.Add(dir);}
        RefreshGameChoices();
        Home();
        if(Find<ScrollViewer>("SimulatorPage").Visibility!=Visibility.Visible || Find<Button>("Collect").Visibility!=Visibility.Collapsed)throw new Exception("Landing page not initial state");
        for(int i=0;i<3;i++) {
            var choices=Find<System.Windows.Controls.ComboBox>("GameChoices");
            GameChoice choice=choices.Items.Cast<GameChoice>().FirstOrDefault(item=>item.Executable.EndsWith(names[i],StringComparison.OrdinalIgnoreCase));
            if(choice==null)throw new Exception("Detected game missing from dropdown: "+names[i]);
            choices.SelectedItem=choice;
            Find<Button>("ContinueGame").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            if(selectedExe!=names[i] || Find<ScrollViewer>("ReportPage").Visibility!=Visibility.Visible)throw new Exception("Simulator navigation failed");
            foreach(string dir in Find<ComboBox>("Games").Items)if(SafeIdentity(dir)!=names[i])throw new Exception("Wrong simulator leaked into selection");
            Find<Button>("Back").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        }
        File.WriteAllText(Path.Combine(output,"navigation-results.txt"),"PASS: generic game dropdown lists detected installations; all three selections reach the matching report page; installation filtering; back navigation.");
    }

    public async Task TestCollection(string game,string output) {

        selectedExe=Collector.Identity(game);
        SelectSimulator(selectedExe,"Test simulator");
        Find<TextBox>("GamePath").Text=game;Find<TextBox>("Output").Text=output;
        const string description="TAA + NR flickers with DLSS FG.\r\nPaused: stable; resumed: flickering again. Unicode: café.";
        Find<TextBox>("IssueDescription").Text=description;
        TestMode=true;
        await Collect();
        if(successful)using(var zip=System.IO.Compression.ZipFile.OpenRead(reportZip)) {
            var entry=zip.GetEntry("ISSUE-DESCRIPTION.txt");
            if(entry==null)throw new Exception("Issue description missing from ZIP");
            using(var reader=new StreamReader(entry.Open()))if(!reader.ReadToEnd().Contains(description))throw new Exception("Issue description changed in ZIP");
            using(var reader=new StreamReader(zip.GetEntry("REPORT.txt").Open()))if(!reader.ReadToEnd().Contains(description))throw new Exception("Report description missing");
            File.WriteAllText(Path.Combine(output,"description-test.txt"),"PASS production textbox -> collection request -> ISSUE-DESCRIPTION.txt and REPORT.txt; multiline Unicode preserved.");
        }
        if(!successful)throw new Exception("UI collection failed");
        Window.Dispatcher.Invoke(System.Windows.Threading.DispatcherPriority.ApplicationIdle,new Action(()=>{}));
        progressWindow.UpdateLayout();
        var bitmap=new System.Windows.Media.Imaging.RenderTargetBitmap((int)progressWindow.ActualWidth,(int)progressWindow.ActualHeight,96,96,PixelFormats.Pbgra32);
        bitmap.Render(progressWindow);
        var png=new System.Windows.Media.Imaging.PngBitmapEncoder();png.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bitmap));
        using(var f=File.Create(Path.Combine(output,"completion-popup.png")))png.Save(f);
        if(((TextBlock)progressWindow.FindName("Heading")).Text!="Report collected (test mode, not sent)")throw new Exception("Completion heading wrong");
        using(var zip=System.IO.Compression.ZipFile.OpenRead(reportZip))
            if(zip.GetEntry("raw/RAW-MANIFEST.txt")==null)throw new Exception("Raw evidence manifest missing");
        ((Button)progressWindow.FindName("Stop")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if(Window.IsVisible)throw new Exception("Completion Close did not exit main window");
        File.WriteAllText(Path.Combine(output,"ui-result.txt"),"PASS: production UI collection (full evidence, raw manifest); completion popup; Close shuts down main window.");
    }
    string previousStage="";
    void ProgressPopup() {
        if(progressWindow!=null){var previous=progressWindow;progressWindow=null;previous.Close();}
        string markup=@"<Window xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Width='620' Height='450' WindowStyle='None' AllowsTransparency='True' Background='Transparent' ResizeMode='NoResize' WindowStartupLocation='CenterOwner' FontFamily='Segoe UI' FontSize='13' Foreground='#F3EFFB' ShowInTaskbar='False'>
<Border Background='{DynamicResource WindowGlass}' BorderBrush='#423454' BorderThickness='1' CornerRadius='10' Padding='26'>
<Grid><Grid.RowDefinitions><RowDefinition Height='Auto'/><RowDefinition Height='Auto'/><RowDefinition Height='Auto'/><RowDefinition Height='*'/><RowDefinition Height='Auto'/></Grid.RowDefinitions>
<TextBlock Name='Heading' Text='Collecting your report' FontSize='24' FontWeight='SemiBold'/>
<TextBlock Name='Current' Grid.Row='1' Text='Starting collection...' TextWrapping='Wrap' Foreground='#D4B7F9' Margin='0,16,0,14'/>
<ProgressBar Name='Activity' Grid.Row='2' Height='5' IsIndeterminate='True' Foreground='#A44DFF' Background='#282238'/>
<TextBox Name='History' Grid.Row='3' IsReadOnly='True' TextWrapping='Wrap' VerticalScrollBarVisibility='Auto' Margin='0,18,0,16' FontSize='12'/>
<Grid Grid.Row='4'><TextBlock Name='Elapsed' Text='Elapsed 00:00' Foreground='#AA9CB9' VerticalAlignment='Center'/><StackPanel Orientation='Horizontal' HorizontalAlignment='Right'><Button Name='CopyId' Content='Copy report ID' Background='{DynamicResource ActionPurple}' Visibility='Collapsed' Margin='0,0,10,0'/><Button Name='Send' Content='Send again' Background='{DynamicResource ActionPurple}' Visibility='Collapsed' Margin='0,0,10,0'/><Button Name='Stop' Content='Cancel'/></StackPanel></Grid>
</Grid></Border></Window>";
        progressWindow=(Window)XamlReader.Parse(markup);
        progressWindow.Resources=Window.Resources;
        progressWindow.Owner=Window;
        progressWindow.MouseLeftButtonDown+=(s,e)=>{if(e.OriginalSource is TextBlock)progressWindow.DragMove();};
        ((Button)progressWindow.FindName("Stop")).Click+=(s,e)=>{if(cancel!=null){cancel.Cancel();Status("Cancelling after the current read...");}else Window.Close();};
        ((Button)progressWindow.FindName("Send")).Click+=async(s,e)=>await Send();
        ((Button)progressWindow.FindName("CopyId")).Click+=(s,e)=>CopyReportId();
        progressWindow.Closing+=(s,e)=>{if(cancel!=null && Object.ReferenceEquals(s,progressWindow)){e.Cancel=true;cancel.Cancel();Status("Cancelling after the current read...");}};
        progressWindow.Topmost=true;started=DateTime.UtcNow;previousStage="";
        progressClock=new System.Windows.Threading.DispatcherTimer{Interval=TimeSpan.FromSeconds(1)};
        progressClock.Tick+=(s,e)=>((TextBlock)progressWindow.FindName("Elapsed")).Text="Elapsed "+(DateTime.UtcNow-started).ToString(@"hh\:mm\:ss");
        progressClock.Start();progressWindow.Show();
    }
    T Find<T>(string name) where T:class {return Window.FindName(name) as T;}
    public Shell() {
        using(var stream=Assembly.GetExecutingAssembly().GetManifestResourceStream("TesterUI"))
            Window=(Window)XamlReader.Load(stream);
        Window.Height=Math.Max(Window.MinHeight,Math.Min(Window.Height,SystemParameters.WorkArea.Height-24));
        Window.Width=Math.Max(Window.MinWidth,Math.Min(Window.Width,SystemParameters.WorkArea.Width-24));
        Find<Button>("Close").Click+=(s,e)=>Window.Close();
        Find<Button>("Minimize").Click+=(s,e)=>Window.WindowState=WindowState.Minimized;
        Find<Border>("TitleBar").MouseLeftButtonDown+=(s,e)=>{if(e.ClickCount==2)Window.WindowState=Window.WindowState==WindowState.Maximized?WindowState.Normal:WindowState.Maximized;else Window.DragMove();};
        Find<Button>("BrowseGameHome").Click+=(s,e)=>{
            using(var d=new System.Windows.Forms.OpenFileDialog()){
                d.Filter="Game executable (*.exe)|*.exe";d.Title="Choose the game's main executable";d.CheckFileExists=true;
                if(d.ShowDialog()==System.Windows.Forms.DialogResult.OK){
                    string executable=Path.GetFullPath(d.FileName),resolved=Collector.ResolveGameFolder(Path.GetDirectoryName(executable),executable);
                    if(resolved==null){Status("Choose a game EXE inside an accessible game installation folder.");return;}
                    if(!knownGames.Contains(resolved))knownGames.Add(resolved);knownExecutables[resolved]=executable;RefreshGameChoices(resolved,executable);
                }
            }
        };
        Find<Button>("ContinueGame").Click+=(s,e)=>{
            var choice=Find<ComboBox>("GameChoices").SelectedItem as GameChoice;
            if(choice==null){Status("Select a detected game or browse to its main EXE first.");return;}
            selectedExecutablePath=choice.Executable;
            SelectSimulator(Path.GetFileName(choice.Executable),choice.Label,choice.Folder,choice.Executable);
        };
        Find<Button>("LauncherOnly").Click+=(s,e)=>OpenLauncherOnly();
        foreach(string name in new[]{"IncludeGameLogs","IncludeMfgLogs","IncludeLauncherLogs"}){
            Find<CheckBox>(name).Checked+=(s,e)=>UpdateSourceSelection();
            Find<CheckBox>(name).Unchecked+=(s,e)=>UpdateSourceSelection();
        }
        var autoHangUpload=Find<CheckBox>("AutoHangUpload");
        autoHangUpload.IsChecked=AutoCapture.AutomaticUploadEnabled;
        autoHangUpload.Checked+=AutoHangUploadChecked;
        autoHangUpload.Unchecked+=AutoHangUploadUnchecked;
        Find<ComboBox>("Games").SelectionChanged+=(s,e)=>{if(Find<ComboBox>("Games").SelectedItem!=null){Find<TextBox>("GamePath").Text=Find<ComboBox>("Games").SelectedItem.ToString();selectedExecutablePath=Collector.ExecutablePath(Find<TextBox>("GamePath").Text,selectedExe)??"";}};
        Find<TextBox>("Output").Text=DiagnosticsLocation.Root;
        Find<TextBlock>("VersionLabel").Text="TROUBLESHOOTER  /  "+Collector.Version;
        Find<Button>("Collect").Click+=async(s,e)=>await Collect();
        Find<Button>("CheckSetup").Click+=async(s,e)=>await CheckSetup();
        Find<Button>("Cancel").Click+=(s,e)=>{if(cancel!=null){cancel.Cancel();Status("Cancelling after the current read...");}};
        Find<Button>("SendReport").Click+=async(s,e)=>await ResumeUnsent();
        Find<Button>("CrashDumpToggle").Click+=async(s,e)=>await ToggleCrashDumps();
        PendingReports.Cleanup();
        Window.Loaded+=(s,e)=>{RefreshUnsent();if(Find<Button>("SendReport").Visibility==Visibility.Visible)Status("A report from earlier was not sent. Press Send unsent report to finish sending it.");};
        Window.Closing+=(s,e)=>{if(cancel!=null){e.Cancel=true;cancel.Cancel();Status("Cancelling... close once collection stops.");}};
        Window.Loaded+=(s,e)=>Window.Dispatcher.BeginInvoke(new Action(()=>RaiseWindow()),System.Windows.Threading.DispatcherPriority.ApplicationIdle);
        Window.Loaded+=async(s,e)=>{
            // Discovery can query running process modules; keep the UI responsive.
            try{
                string[] games=await Task.Run(()=>Collector.Discover());
                foreach(string game in games)if(!knownGames.Contains(game))knownGames.Add(game);
                RefreshGameChoices();
                Find<TextBlock>("GameChoicesHint").Text=Find<ComboBox>("GameChoices").Items.Count==0?
                    "No tracked game installations were found. Browse to a game's main EXE to add it." :
                    "Choose the game you tested. The last launched game is not selected automatically.";
            }catch{Find<TextBlock>("GameChoicesHint").Text="Game scan failed. Browse to the game's main EXE to continue.";Status("Choose a game installation to get started.");}
        };
        Find<Button>("Back").Click+=(s,e)=>Home();
        Home();
    }
    static string SafeIdentity(string path){try{return Collector.Identity(path);}catch{return null;}}
    // Opened from another OptiShade tool for one game folder (OptiMFG's "Send
    // diagnostics report"). Unknown folders fall back to the normal game list.
    public void OpenGame(string folder,bool includeMfg){
        string resolved=null;try{resolved=Collector.ResolveGameFolder(folder);}catch{}
        string exe=resolved==null?null:SafeIdentity(resolved);
        if(String.IsNullOrEmpty(exe)){Status("Choose the game you tested to collect its report.");return;}
        if(!knownGames.Contains(resolved))knownGames.Add(resolved);
        SelectSimulator(exe,DisplayGameName(exe),resolved,Collector.ExecutablePath(resolved,exe)??"");
        if(includeMfg)Find<CheckBox>("IncludeMfgLogs").IsChecked=true;
        Status("Describe what happened, then collect and send. Game, OptiShade and OptiMFG logs are included.");
    }
    static string DisplayGameName(string executable) {
        try {string product=FileVersionInfo.GetVersionInfo(executable).ProductName;if(!String.IsNullOrWhiteSpace(product))return product.Trim();}catch{}
        string name=Path.GetFileNameWithoutExtension(executable);
        if(String.Equals(name,"FlightSimulator2024",StringComparison.OrdinalIgnoreCase))return "Microsoft Flight Simulator 2024";
        if(String.Equals(name,"FlightSimulator",StringComparison.OrdinalIgnoreCase))return "Microsoft Flight Simulator 2020";
        if(String.Equals(name,"X-Plane",StringComparison.OrdinalIgnoreCase))return "X-Plane 12";
        return name;
    }
    void RefreshGameChoices(string preferredFolder="",string preferredExecutable="") {
        var list=Find<ComboBox>("GameChoices");list.Items.Clear();
        string preferred=Collector.ResolveGameFolder(preferredFolder,preferredExecutable);
        foreach(string candidate in knownGames.Distinct(StringComparer.OrdinalIgnoreCase)) {
            string folder=Collector.ResolveGameFolder(candidate,knownExecutables.ContainsKey(candidate)?knownExecutables[candidate]:null);
            if(folder==null)continue;
            string executable=null;
            string stored;
            if(knownExecutables.TryGetValue(candidate,out stored) && File.Exists(stored))executable=stored;
            else {string identity=SafeIdentity(folder);if(identity!=null)executable=Collector.ExecutablePath(folder,identity);}
            if(String.IsNullOrWhiteSpace(executable)||!File.Exists(executable))continue;
            var choice=new GameChoice{Folder=folder,Executable=Path.GetFullPath(executable),Label=DisplayGameName(executable)+" — "+Path.GetFileName(folder)};
            list.Items.Add(choice);
            if(String.Equals(folder,preferred,StringComparison.OrdinalIgnoreCase) &&
               (String.IsNullOrWhiteSpace(preferredExecutable)||String.Equals(choice.Executable,Path.GetFullPath(preferredExecutable),StringComparison.OrdinalIgnoreCase)))list.SelectedItem=choice;
        }
    }
    void RefreshGames(string preferred="",string preferredExecutable="") {
        if(selectedExe.Length==0)return;
        string current=Find<TextBox>("GamePath").Text;
        var list=Find<ComboBox>("Games");list.Items.Clear();Find<TextBox>("GamePath").Text="";
        foreach(string candidate in knownGames.Distinct(StringComparer.OrdinalIgnoreCase)) {
            string executable=null;
            string stored;
            if(knownExecutables.TryGetValue(candidate,out stored) && File.Exists(stored))executable=stored;
            else {string identity=SafeIdentity(candidate);if(identity!=null)executable=Collector.ExecutablePath(candidate,identity);}
            if(String.IsNullOrWhiteSpace(executable)||!String.Equals(Path.GetFileName(executable),selectedExe,StringComparison.OrdinalIgnoreCase))continue;
            string game=Collector.ResolveGameFolder(candidate,executable);if(game!=null&&!list.Items.Contains(game))list.Items.Add(game);
        }
        preferred=Collector.ResolveGameFolder(preferred,preferredExecutable);
        current=Collector.ResolveGameFolder(current,selectedExecutablePath);
        if(list.Items.Contains(preferred))list.SelectedItem=preferred;
        else if(list.Items.Contains(current))list.SelectedItem=current;
        else if(list.Items.Count==1)list.SelectedIndex=0;
    }
    void Home(){Find<ScrollViewer>("SimulatorPage").Visibility=Visibility.Visible;Find<ScrollViewer>("ReportPage").Visibility=Visibility.Collapsed;Find<Button>("Collect").Visibility=Visibility.Collapsed;Find<Button>("CheckSetup").Visibility=Visibility.Collapsed;}
    void UpdateSourceSelection(){
        if(updatingSources)return;
        bool needsGame=Find<CheckBox>("IncludeGameLogs").IsChecked==true||Find<CheckBox>("IncludeMfgLogs").IsChecked==true;
        Find<Border>("GameSelectionCard").Visibility=needsGame?Visibility.Visible:Visibility.Collapsed;
        RefreshCrashDumps();
        bool includeLauncher=Find<CheckBox>("IncludeLauncherLogs").IsChecked==true;
        Find<TextBlock>("SelectedTitle").Text=needsGame?selectedTitle:(includeLauncher?"Launcher and installer diagnostics":"Select diagnostic sources");
    }
    void SetAutomaticHangUpload(bool enabled) {
        try {
            AutoCapture.AutomaticUploadEnabled=enabled;
            Status(enabled?"Automatic hang reports will be sent privately after capture. You can turn this off here.":"Automatic hang uploads are off; suspected stalls are saved locally for you to send.");
        } catch(Exception e) {
            var box=Find<CheckBox>("AutoHangUpload");
            box.Checked-=AutoHangUploadChecked;box.Unchecked-=AutoHangUploadUnchecked;
            box.IsChecked=!enabled;
            box.Checked+=AutoHangUploadChecked;box.Unchecked+=AutoHangUploadUnchecked;
            Status("Could not save the automatic hang upload setting: "+e.Message);
        }
    }
    void AutoHangUploadChecked(object sender,RoutedEventArgs e){SetAutomaticHangUpload(true);}
    void AutoHangUploadUnchecked(object sender,RoutedEventArgs e){SetAutomaticHangUpload(false);}
    void SelectSimulator(string exe,string title,string folder="",string executable=""){
        selectedExe=exe;selectedExecutablePath=executable;selectedTitle=title;
        updatingSources=true;Find<CheckBox>("IncludeGameLogs").IsChecked=true;Find<CheckBox>("IncludeMfgLogs").IsChecked=false;Find<CheckBox>("IncludeLauncherLogs").IsChecked=false;updatingSources=false;
        Find<ScrollViewer>("SimulatorPage").Visibility=Visibility.Collapsed;Find<ScrollViewer>("ReportPage").Visibility=Visibility.Visible;
        Find<Button>("Collect").Visibility=Visibility.Visible;Find<Button>("CheckSetup").Visibility=Visibility.Visible;
        RefreshGames(folder,executable);if(!String.IsNullOrWhiteSpace(folder))Find<TextBox>("GamePath").Text=folder;UpdateSourceSelection();
        Status("Confirm the selected game installation. Check my setup looks for known problems and sends nothing; to send a report, describe what happened, then collect and send.");
    }
    public void OpenLauncherOnly(){
        selectedExe="";selectedExecutablePath="";selectedTitle="Launcher and installer diagnostics";
        updatingSources=true;Find<CheckBox>("IncludeGameLogs").IsChecked=false;Find<CheckBox>("IncludeMfgLogs").IsChecked=false;Find<CheckBox>("IncludeLauncherLogs").IsChecked=true;updatingSources=false;
        Find<ScrollViewer>("SimulatorPage").Visibility=Visibility.Collapsed;Find<ScrollViewer>("ReportPage").Visibility=Visibility.Visible;
        Find<Button>("Collect").Visibility=Visibility.Visible;Find<Button>("CheckSetup").Visibility=Visibility.Visible;UpdateSourceSelection();
        Status("Launcher-only collection selected. Add game or OptiMFG logs if they’re relevant to this issue.");
    }
    public void Navigate(bool memory){SelectSimulator("FlightSimulator2024.exe","Microsoft Flight Simulator 2024");}
    void Status(string text) {Window.Dispatcher.BeginInvoke(new Action(()=>{
        Find<TextBlock>("Status").Text=text;
        if(progressWindow!=null && progressWindow.IsVisible) {
            ((TextBlock)progressWindow.FindName("Current")).Text=text;
            if(previousStage!=text) {
                var history=(TextBox)progressWindow.FindName("History");
                string[] lines=(history.Text+DateTime.Now.ToString("HH:mm:ss")+"  "+text+"\n").Split('\n');
                history.Text=String.Join("\n",System.Linq.Enumerable.Skip(lines,Math.Max(0,lines.Length-30)));
                history.ScrollToEnd();previousStage=text;
            }
        }
    }));}
    void Busy(bool active) {
        Find<StackPanel>("ReportInputs").IsEnabled=!active;Find<Button>("Back").IsEnabled=!active;
        Find<Button>("Collect").IsEnabled=!active;Find<Button>("CheckSetup").IsEnabled=!active;Find<Button>("SendReport").IsEnabled=!active;
        Find<Button>("Cancel").Visibility=active?Visibility.Visible:Visibility.Collapsed;
        Find<ProgressBar>("Progress").IsIndeterminate=active;
        Find<ProgressBar>("Progress").Visibility=active?Visibility.Visible:Visibility.Collapsed;
        Find<TextBlock>("State").Text=active?"WORKING":"READY";
    }
    // Test hook: collect without the confirmation dialog or sending, keeping
    // the pending ZIP so the self-test can inspect it.
    public bool TestMode;
    // Test hook: the real collect-and-send path with the confirmation accepted.
    public bool AutoConfirm;
    public async Task TestSend(string game,string output,string description) {
        selectedExe=Collector.Identity(game);
        SelectSimulator(selectedExe,"Test simulator");
        Find<TextBox>("GamePath").Text=game;
        Find<TextBox>("IssueDescription").Text=description;
        AutoConfirm=true;
        await Collect();
        Window.Dispatcher.Invoke(System.Windows.Threading.DispatcherPriority.ApplicationIdle,new Action(()=>{}));
        string heading=progressWindow==null?"(no popup)":((TextBlock)progressWindow.FindName("Heading")).Text;
        bool pendingEmpty=!Directory.Exists(PendingReports.Root)||Directory.GetDirectories(PendingReports.Root).Length==0;
        File.WriteAllText(Path.Combine(output,"ui-send-result.txt"),(successful&&reportId!=null&&heading=="Report sent"&&pendingEmpty?"PASS":"FAIL")+
            "\r\nreport="+reportId+"\r\nheading="+heading+"\r\npendingEmpty="+pendingEmpty+"\r\nstatus="+Find<TextBlock>("Status").Text);
    }
    string reportId, reportNotes="", reportGame="";
    void CopyReportId(){if(reportId==null)return;try{Clipboard.SetText(reportId);Status("Report ID copied: "+reportId+". Paste it in Discord.");}catch{Status("Could not copy. Your report ID is "+reportId);}}

    // One step for the tester: confirm, collect into a hidden pending folder,
    // send, delete. Only the report ID is left. A report that could not be
    // sent stays hidden in the pending folder so Send can resume it; it is
    // removed once sent or after the relay's 48-hour upload pass expires.
    async Task Collect() {
        const int hours=24;
        bool includeGame=Find<CheckBox>("IncludeGameLogs").IsChecked==true,includeMfg=Find<CheckBox>("IncludeMfgLogs").IsChecked==true,includeLauncher=Find<CheckBox>("IncludeLauncherLogs").IsChecked==true;
        if(!includeGame&&!includeMfg&&!includeLauncher){Status("Select at least one diagnostic source.");return;}
        string game=SelectedGame(includeGame||includeMfg);if(game==null)return;
        if(!TestMode&&!AutoConfirm&&!ConfirmSend(includeGame))return;
        string output=TestMode?Find<TextBox>("Output").Text.Trim():PendingReports.NewFolder();
        var req=new Request{Game=game,Executable=selectedExecutablePath,Output=output,Notes=Find<TextBox>("IssueDescription").Text.Trim(),Profile="Private upload",Limit=Collector.MaxSentReportBytes,Hours=hours,Settings=true,Crash=true,IncludeGameLogs=includeGame,IncludeMfgLogs=includeMfg,IncludeLauncherLogs=includeLauncher,FullEvidence=true};
        cancel=new CancellationTokenSource();successful=false;Busy(true);ProgressPopup();Find<TextBlock>("Result").Text="";
        bool collected=false;
        try {
            Result saved=await Task.Run(()=>new Collector(req,Status,cancel.Token).Run());
            reportZip=saved.Zip;collected=true;
            reportNotes=req.Notes??"";reportGame=includeGame||includeMfg?Path.GetFileNameWithoutExtension(selectedExe):"Launcher only";
            if(includeGame&&!Path.GetFileName(saved.Zip).Contains(Collector.GameFileToken(selectedExe)))throw new InvalidDataException("The diagnostic filename does not identify the selected game.");
            Status("Report collected ("+(saved.Bytes/1000000.0).ToString("0.0")+" MB).");
        }catch(OperationCanceledException){Status("Cancelled. Nothing was sent.");}
        catch(Exception e){Status("Could not collect: "+e.Message+" Nothing was sent.");}
        finally{cancel.Dispose();cancel=null;}
        if(!collected){if(!TestMode)PendingReports.Discard(output);Finish("Report not collected",false);Busy(false);return;}
        if(TestMode){successful=true;Finish("Report collected (test mode, not sent)",false);Busy(false);return;}
        await Send();
    }
    // The game folder to read, or null after telling the user what to choose.
    string SelectedGame(bool needGame) {
        string game=Find<TextBox>("GamePath").Text.Trim();
        if(!needGame)return game;
        try{string resolved=Collector.ResolveGameFolder(game,selectedExecutablePath);if(resolved==null){Status("Choose the game installation you tested, or browse directly to its main EXE.");return null;}game=resolved;if(String.IsNullOrEmpty(selectedExecutablePath))selectedExecutablePath=Collector.ExecutablePath(game,selectedExe)??"";if(String.IsNullOrEmpty(selectedExecutablePath)||!File.Exists(selectedExecutablePath)){Status("Choose the game's main EXE using Browse.");return null;}}catch{Status("Choose a valid game installation folder.");return null;}
        return game;
    }
    // Check my setup: run the report's rules on this PC and show what to try.
    // Nothing is written to the report folders and nothing is sent.
    async Task CheckSetup() {
        bool includeGame=Find<CheckBox>("IncludeGameLogs").IsChecked==true,includeMfg=Find<CheckBox>("IncludeMfgLogs").IsChecked==true;
        string game=SelectedGame(includeGame||includeMfg);if(game==null)return;
        // Launcher logs are always read here: manager and antivirus failures are in them.
        var req=new Request{Game=game,Executable=selectedExecutablePath,Output=Path.GetTempPath(),Hours=24,Settings=true,Crash=true,CaptureLive=false,
            IncludeGameLogs=includeGame,IncludeMfgLogs=includeMfg,IncludeLauncherLogs=true};
        cancel=new CancellationTokenSource();Busy(true);Find<TextBlock>("Result").Text="";
        System.Collections.Generic.List<Advice> advice=null;
        try{
            var findings=await Task.Run(()=>new Collector(req,Status,cancel.Token).Check());
            advice=SelfHelp.Build(findings);
            Status(advice.Count(a=>!a.Good)==0?"Check finished: no known problem found.":"Check finished: "+advice.Count(a=>!a.Good)+" thing(s) to look at. Nothing was sent.");
        }catch(OperationCanceledException){Status("Check cancelled.");}
        catch(Exception e){Status("Could not check: "+e.Message);}
        finally{cancel.Dispose();cancel=null;Busy(false);}
        if(advice!=null&&BuildCheckResults(advice).ShowDialog()==true)await Collect();
    }
    Window BuildCheckResults(System.Collections.Generic.List<Advice> advice) {
        string markup=@"<Window xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Width='680' MaxHeight='760' SizeToContent='Height' WindowStyle='None' AllowsTransparency='True' Background='Transparent' ResizeMode='NoResize' WindowStartupLocation='CenterOwner' FontFamily='Segoe UI' FontSize='13' Foreground='#F3EFFB' ShowInTaskbar='False'>
<Border Background='{DynamicResource WindowGlass}' BorderBrush='#423454' BorderThickness='1' CornerRadius='10' Padding='28,26'>
<DockPanel>
<StackPanel DockPanel.Dock='Top'>
<TextBlock Text='Check my setup' FontSize='24' FontWeight='SemiBold'/>
<TextBlock Name='Summary' TextWrapping='Wrap' Foreground='#D4B7F9' Margin='0,10,0,14'/>
</StackPanel>
<StackPanel DockPanel.Dock='Bottom' Orientation='Horizontal' HorizontalAlignment='Right' Margin='0,18,0,0'>
<Button Name='Copy' Content='Copy results' Padding='16,9' Margin='0,0,10,0'/>
<Button Name='Close' Content='Close' Padding='16,9' Margin='0,0,10,0' IsCancel='True'/>
<Button Name='Report' Content='Still broken? Send a report' Background='{DynamicResource ActionPurple}' Padding='16,9'/>
</StackPanel>
<ScrollViewer VerticalScrollBarVisibility='Auto' MaxHeight='520'><StackPanel Name='Items'/></ScrollViewer>
</DockPanel></Border></Window>";
        var dialog=(Window)XamlReader.Parse(markup);
        dialog.Resources=Window.Resources;dialog.Owner=Window;
        dialog.MouseLeftButtonDown+=(s,e)=>{if(e.OriginalSource is TextBlock||e.OriginalSource is Border)dialog.DragMove();};
        int problems=advice.Count(a=>!a.Good),fixable=advice.Count(a=>a.UserCanFix);
        ((TextBlock)dialog.FindName("Summary")).Text=problems==0?
            "No known problem was found in this PC's OptiShade logs, settings and Windows events. If something still looks wrong, send a report and describe it.":
            "Found "+problems+" thing(s)"+(fixable>0?", "+fixable+" you can try to fix yourself":"")+". Try the steps from the top, then test the game again. Nothing was sent.";
        var items=(StackPanel)dialog.FindName("Items");
        var converter=new BrushConverter();
        foreach(var a in advice) {
            var card=new Border{Background=(Brush)Window.Resources["ControlSurface"],BorderBrush=(Brush)converter.ConvertFromString(a.Good?"#3F6B4F":a.UserCanFix?"#8C6DAA":"#6B4F3F"),BorderThickness=new Thickness(1),CornerRadius=new CornerRadius(9),Padding=new Thickness(16,12,16,12),Margin=new Thickness(0,0,0,10)};
            var body=new StackPanel();
            body.Children.Add(new TextBlock{Text=(a.Good?"OK":a.UserCanFix?"YOU CAN FIX THIS":"NEEDS A REPORT"),FontSize=10,FontWeight=FontWeights.SemiBold,Foreground=(Brush)converter.ConvertFromString(a.Good?"#8FD3A6":a.UserCanFix?"#BDA0F4":"#E8B48F")});
            body.Children.Add(new TextBlock{Text=a.Title,FontSize=15,FontWeight=FontWeights.SemiBold,TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,4,0,0)});
            body.Children.Add(new TextBlock{Text=a.Why,TextWrapping=TextWrapping.Wrap,Foreground=(Brush)Window.Resources["TextMuted"],Margin=new Thickness(0,6,0,0)});
            body.Children.Add(new TextBlock{Text="Try this: "+a.TryThis,TextWrapping=TextWrapping.Wrap,Foreground=(Brush)converter.ConvertFromString("#EAE1F6"),Margin=new Thickness(0,6,0,0)});
            var details=new TextBlock{Text=a.Source.Text+(a.Source.Details.Count>0?"\n"+String.Join("\n",a.Source.Details):""),TextWrapping=TextWrapping.Wrap,FontSize=11,Foreground=(Brush)Window.Resources["TextMuted"]};
            body.Children.Add(new Expander{Header="Details",Content=details,Foreground=(Brush)converter.ConvertFromString("#B68BE8"),Margin=new Thickness(0,8,0,0)});
            card.Child=body;items.Children.Add(card);
        }
        ((Button)dialog.FindName("Copy")).Click+=(s,e)=>{try{Clipboard.SetText(SelfHelp.Format(advice));Status("Check results copied.");}catch{Status("Could not copy the results.");}};
        ((Button)dialog.FindName("Close")).Click+=(s,e)=>dialog.DialogResult=false;
        ((Button)dialog.FindName("Report")).Click+=(s,e)=>dialog.DialogResult=true;
        return dialog;
    }
    // Sends reportZip; shared by Collect and by resuming an unsent report.
    async Task Send() {
        if(reportZip==null||!File.Exists(reportZip)||cancel!=null)return;
        if(progressWindow==null||!progressWindow.IsVisible)ProgressPopup();
        else{progressClock.Start();}
        Busy(true);
        var heading=(TextBlock)progressWindow.FindName("Heading");var bar=(ProgressBar)progressWindow.FindName("Activity");
        heading.Text="Sending your report";bar.Visibility=Visibility.Visible;bar.IsIndeterminate=false;bar.Minimum=0;bar.Maximum=1;bar.Value=0;
        foreach(string b in new[]{"Send","CopyId"})((Button)progressWindow.FindName(b)).Visibility=Visibility.Collapsed;
        ((Button)progressWindow.FindName("Stop")).Content="Cancel";
        cancel=new CancellationTokenSource();bool sent=false;string failure=null;
        DateTime last=DateTime.MinValue;
        var upload=new ReportUpload(ReportUpload.DefaultEndpoint,(text,done,total)=>{
            if(DateTime.UtcNow-last<TimeSpan.FromMilliseconds(200)&&done<total)return;last=DateTime.UtcNow;
            string amount=" "+(done/1000000.0).ToString("0.0")+" of "+(total/1000000.0).ToString("0.0")+" MB";
            Window.Dispatcher.BeginInvoke(new Action(()=>{if(progressWindow!=null){bar.Value=total>0?(double)done/total:0;((TextBlock)progressWindow.FindName("Current")).Text=text+amount;}}));
            if(text!=previousStage)Status(text);
        });
        string zip=reportZip,notes=reportNotes,game=reportGame;
        try{reportId=await Task.Run(()=>upload.Send(zip,cancel.Token,notes,game));sent=true;}
        catch(OperationCanceledException){failure="Sending was paused. Press Send again to carry on where it stopped.";}
        catch(UploadFailed e){failure="Not sent: "+e.Message+(e.Retryable?" Press Send again to carry on where it stopped.":"");}
        catch(Exception e){failure="Not sent: "+e.Message;}
        finally{cancel.Dispose();cancel=null;}
        if(sent) {
            // No copy stays on this PC once the relay has confirmed every part.
            PendingReports.Discard(Path.GetDirectoryName(zip));reportZip=null;successful=true;
            Find<TextBlock>("Result").Text="Report ID: "+reportId;
            Status("Report sent. Your report ID is "+reportId+". Post this ID in Discord.");
            try{Clipboard.SetText(reportId);}catch{}
            Finish("Report sent",false);
            ((Button)progressWindow.FindName("CopyId")).Visibility=Visibility.Visible;
            Window.Dispatcher.BeginInvoke(new Action(()=>((TextBlock)progressWindow.FindName("Current")).Text="Report ID: "+reportId+"\nIt has been copied for you. Post this ID in Discord so the developer can find your report."));
        } else {
            Status(failure);
            Finish("Report not sent",true);
        }
        Busy(false);RefreshUnsent();
    }
    void Finish(string heading,bool canRetry) {
        if(progressWindow==null)return;
        progressClock.Stop();
        ((TextBlock)progressWindow.FindName("Heading")).Text=heading;
        ((ProgressBar)progressWindow.FindName("Activity")).Visibility=Visibility.Collapsed;
        ((Button)progressWindow.FindName("Stop")).Content="Close";
        var again=(Button)progressWindow.FindName("Send");
        again.Content="Send again";again.Visibility=canRetry?Visibility.Visible:Visibility.Collapsed;
    }
    // An earlier report that did not finish sending (closed, offline, refused).
    void RefreshUnsent() {
        var unsent=PendingReports.Unsent();
        var button=Find<Button>("SendReport");
        button.Visibility=unsent!=null&&cancel==null?Visibility.Visible:Visibility.Collapsed;
        if(unsent!=null&&reportZip==null){reportZip=unsent.Zip;reportNotes=unsent.Notes;reportGame=unsent.Game;}
    }
    async Task ResumeUnsent() {
        RefreshUnsent();
        if(reportZip==null){Status("There is no unsent report.");return;}
        successful=false;ProgressPopup();await Send();
    }

    // Windows Error Reporting crash dumps for the selected game.
    void RefreshCrashDumps() {
        bool game=Find<CheckBox>("IncludeGameLogs").IsChecked==true&&!String.IsNullOrWhiteSpace(selectedExe);
        Find<Border>("CrashDumpCard").Visibility=game?Visibility.Visible:Visibility.Collapsed;
        if(!game)return;
        var state=CrashDumps.Read(selectedExe);
        Find<TextBlock>("CrashDumpStatus").Text=state.Detail;
        var toggle=Find<Button>("CrashDumpToggle");
        toggle.Content=state.Enabled?"Turn off":"Turn on";
        // A setting made outside OptiShade is reported but left alone.
        toggle.IsEnabled=!state.Enabled||state.ManagedByOptiShade;
    }
    async Task ToggleCrashDumps() {
        string exe=selectedExe;bool on=CrashDumps.Read(exe).Enabled;
        var toggle=Find<Button>("CrashDumpToggle");toggle.IsEnabled=false;
        Status(on?"Turning off crash dumps for "+exe+"...":"Turning on crash dumps for "+exe+". Approve the Windows prompt...");
        string failure=await Task.Run(()=>on?CrashDumps.Disable(exe):CrashDumps.Enable(exe));
        RefreshCrashDumps();
        Status(failure??(on?"Crash dumps turned off for "+exe+".":"Crash dumps turned on for "+exe+". If the game crashes, collect and send a report afterwards."));
    }

    // Confirmation styled like the rest of the Troubleshooter.
    bool ConfirmSend(bool includeGame){return BuildConfirm(includeGame).ShowDialog()==true;}
    public void PreviewCheck(string png) {
        var advice=SelfHelp.Build(new[]{
            new Finding{Severity=1,Area="a",Text="WINDOWS SECURITY BLOCKED OptiShade: Windows Defender detected 1 OptiShade-related item(s): <USER>\\Games\\MSFS\\OptiShadeData\\OptiMFG\\Runtime\\OptiMFG_Live.exe."},
            new Finding{Severity=2,Area="b",Text="MFG: OptiMFG applied 3x but frame generation is off in the game."},
            new Finding{Severity=1,Area="c",Text="CRASH in nvwgf2umx.dll"},
            new Finding{Severity=4,Area="d",Text="MFG WORKING: generated frames reported."}});
        PreviewDialog(BuildCheckResults(advice),png);
    }
    void PreviewDialog(Window dialog,string png) {
        dialog.Show();
        dialog.Dispatcher.Invoke(System.Windows.Threading.DispatcherPriority.ApplicationIdle,new Action(()=>{}));dialog.UpdateLayout();
        var bitmap=new System.Windows.Media.Imaging.RenderTargetBitmap((int)dialog.ActualWidth,(int)dialog.ActualHeight,96,96,PixelFormats.Pbgra32);bitmap.Render(dialog);
        var encoder=new System.Windows.Media.Imaging.PngBitmapEncoder();encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bitmap));
        using(var f=File.Create(png))encoder.Save(f);
        dialog.Close();
    }
    public void PreviewConfirm(string png) {
        var dialog=BuildConfirm(true);dialog.Show();
        dialog.Dispatcher.Invoke(System.Windows.Threading.DispatcherPriority.ApplicationIdle,new Action(()=>{}));dialog.UpdateLayout();
        var bitmap=new System.Windows.Media.Imaging.RenderTargetBitmap((int)dialog.ActualWidth,(int)dialog.ActualHeight,96,96,PixelFormats.Pbgra32);bitmap.Render(dialog);
        var encoder=new System.Windows.Media.Imaging.PngBitmapEncoder();encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bitmap));
        using(var f=File.Create(png))encoder.Save(f);
        dialog.Close();
    }
    Window BuildConfirm(bool includeGame) {
        string markup=@"<Window xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Width='600' SizeToContent='Height' WindowStyle='None' AllowsTransparency='True' Background='Transparent' ResizeMode='NoResize' WindowStartupLocation='CenterOwner' FontFamily='Segoe UI' FontSize='13' Foreground='#F3EFFB' ShowInTaskbar='False'>
<Border Background='{DynamicResource WindowGlass}' BorderBrush='#423454' BorderThickness='1' CornerRadius='10' Padding='28,26'>
<StackPanel>
<TextBlock Text='Send this report to OptiShade?' FontSize='24' FontWeight='SemiBold'/>
<TextBlock TextWrapping='Wrap' Foreground='#D4B7F9' Margin='0,14,0,0' Text='OptiShade will collect a diagnostic report and send it straight to the developer&#39;s private storage. You get a report ID to post in Discord. Nobody else can use the ID to open your report.'/>
<Border Background='{DynamicResource ControlSurface}' BorderBrush='#40314F' BorderThickness='1' CornerRadius='9' Padding='16,12' Margin='0,16,0,0'><StackPanel>
<TextBlock Text='What is sent' FontWeight='SemiBold' Foreground='#BDA0F4' FontSize='11'/>
<TextBlock Name='Included' TextWrapping='Wrap' Margin='0,8,0,0' LineHeight='20'/>
</StackPanel></Border>
<TextBlock TextWrapping='Wrap' Foreground='{DynamicResource TextMuted}' FontSize='12' Margin='0,14,0,0' Text='Original log files and dumps are sent exactly as they are, so they can include your Windows user name and folder paths. Dumps are copies of the game&#39;s memory. Your connection is recorded only as an anonymous sender code to stop abuse; your IP address is not stored.'/>
<TextBlock TextWrapping='Wrap' Foreground='{DynamicResource TextMuted}' FontSize='12' Margin='0,8,0,0' Text='No copy is kept on this PC once it is sent. Large reports can take a few minutes on slower connections.'/>
<StackPanel Orientation='Horizontal' HorizontalAlignment='Right' Margin='0,22,0,0'>
<Button Name='No' Content='Cancel' Padding='16,9' Margin='0,0,10,0' IsCancel='True'/>
<Button Name='Yes' Content='Collect and send' Background='{DynamicResource ActionPurple}' Padding='16,9' IsDefault='True'/>
</StackPanel>
</StackPanel></Border></Window>";
        var dialog=(Window)XamlReader.Parse(markup);
        dialog.Resources=Window.Resources;dialog.Owner=Window;
        dialog.MouseLeftButtonDown+=(s,e)=>{if(e.OriginalSource is TextBlock||e.OriginalSource is Border)dialog.DragMove();};
        ((TextBlock)dialog.FindName("Included")).Text=
            "•  Your description from this screen\n"+
            "•  OptiShade, game, OptiMFG and launcher logs you selected, including the original files\n"+
            "•  Settings, hardware, driver and Windows event logs"+
            (includeGame?"\n•  Recent crash and freeze dumps for this game":"");
        ((Button)dialog.FindName("Yes")).Click+=(s,e)=>dialog.DialogResult=true;
        ((Button)dialog.FindName("No")).Click+=(s,e)=>dialog.DialogResult=false;
        return dialog;
    }
}
}
