using System;
using System.IO;
using System.IO.Compression;
using System.Text;
using System.Linq;
using System.Collections.Generic;
using System.Drawing;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using System.Reflection;
using Microsoft.Win32;
[assembly: AssemblyTitle("OptiShade Troubleshooter")]
[assembly: AssemblyDescription("Private testing evidence collector")]
[assembly: AssemblyVersion("0.2.34.0")]
[assembly: AssemblyFileVersion("0.2.34.0")]
namespace OptiShade.TesterKit {
static class Program {
    [STAThread] static int Main(string[] args) {
        try {
            // Exercise an unfinished notification in a child process. It must not
            // keep the process alive after its owning operation returns.
            if(args.Length==1 && args[0]=="--notice-exit-self-test") { CaptureNotice.Begin("Shutdown regression check"); return 0; }
            if(args.Length==4 && args[0]=="--auto-watch") return AutoCapture.Watch(args);
            if(args.Length==5 && args[0]=="--hang-worker") return HangCapture.Worker(args);
            if(args.Length==2 && args[0]=="--mfg-trace-self-test") { Tests.RunMfgTrace(args[1]); return 0; }
            if(args.Length==2 && args[0]=="--mfg-native-log-self-test") { Tests.RunMfgNativeLog(args[1]); return 0; }
            if(args.Length>0 && args[0]=="--self-test") { Tests.Run(args[1]); return 0; }
            // Re-run the rules on an extracted report: folder, results file.
            if(args.Length==3 && args[0]=="--verdicts") {
                string root=Path.GetFullPath(args[1]);
                var captured=Directory.GetFiles(root,"*",SearchOption.AllDirectories).Where(f=>(f.EndsWith(".txt",StringComparison.OrdinalIgnoreCase)||f.EndsWith(".jsonl",StringComparison.OrdinalIgnoreCase)||f.EndsWith(".log",StringComparison.OrdinalIgnoreCase)||f.EndsWith(".json",StringComparison.OrdinalIgnoreCase))&&!f.StartsWith(Path.Combine(root,"raw"),StringComparison.OrdinalIgnoreCase))
                    .Select(f=>new KeyValuePair<string,string>(f.Substring(root.Length+1).Replace('\\','/'),File.ReadAllText(f))).ToList();
                string report=File.Exists(Path.Combine(root,"REPORT.txt"))?File.ReadAllText(Path.Combine(root,"REPORT.txt")):"";
                var stamp=System.Text.RegularExpressions.Regex.Match(report,@"Captured UTC: (\S+)");
                var hours=System.Text.RegularExpressions.Regex.Match(report,@"Lookback hours for events/dumps: (\d+)");
                DateTime capturedUtc;
                Verdicts.Since=stamp.Success&&DateTime.TryParse(stamp.Groups[1].Value,out capturedUtc)?(DateTime?)capturedUtc.ToUniversalTime().AddHours(-(hours.Success?Int32.Parse(hours.Groups[1].Value):24)):null;
                var findings=Verdicts.Analyze(captured);
                File.WriteAllText(args[2],Verdicts.Format(findings)+"\r\nPLAYER VIEW\r\n"+SelfHelp.Format(SelfHelp.Build(findings)));
                return 0;
            }
            // Check my setup without the window: game folder, game EXE, results file.
            if(args.Length==4 && args[0]=="--check-setup") {
                var findings=new Collector(new Request{Game=args[1],Executable=args[2],Output=Path.GetTempPath(),CaptureLive=false,IncludeGameLogs=true,IncludeLauncherLogs=true},s=>{},CancellationToken.None).Check();
                File.WriteAllText(args[3],SelfHelp.Format(SelfHelp.Build(findings))+"\r\nDEVELOPER VIEW\r\n"+Verdicts.Format(findings));
                return 0;
            }
            // Runs the crash-dump registry scripts against a per-user test key
            // (no elevation, no real WER setting touched) and reads them back.
            if(args.Length==2 && args[0]=="--crashdump-self-test") {
                // The same .reg import as Enable, into a per-user test key (no elevation).
                const string exe="OptiShadeSelfTest.exe";
                string sub=@"SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\"+exe;
                var lines=new StringBuilder();int code=0;
                Func<RegistryKey> open=()=>RegistryKey.OpenBaseKey(RegistryHive.CurrentUser,RegistryView.Registry64).OpenSubKey(sub);
                string failure=CrashDumps.ImportAndCheck(exe,"HKEY_CURRENT_USER",false,()=>{using(var k=open())return k!=null;});
                using(var k=open()) {
                    bool ok=failure==null&&k!=null&&(string)k.GetValue("DumpFolder","",RegistryValueOptions.DoNotExpandEnvironmentNames)==@"%LOCALAPPDATA%\CrashDumps"
                        &&k.GetValueKind("DumpFolder")==RegistryValueKind.ExpandString
                        &&(int)k.GetValue("DumpType",-1)==0&&(int)k.GetValue("CustomDumpFlags",-1)==CrashDumps.CustomFlags&&(int)k.GetValue("DumpCount",-1)==CrashDumps.Keep&&(int)k.GetValue("OptiShadeManaged",-1)==1;
                    lines.AppendLine((ok?"PASS":"FAIL")+": reg.exe import writes DumpFolder (unexpanded), DumpType 0, CustomDumpFlags, DumpCount, OptiShadeManaged"+(failure==null?"":" ("+failure+")"));if(!ok)code=1;
                }
                using(var parent=RegistryKey.OpenBaseKey(RegistryHive.CurrentUser,RegistryView.Registry64).OpenSubKey(@"SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps",true)) {
                    if(parent!=null){parent.DeleteSubKeyTree(exe,false);bool empty=parent.SubKeyCount==0&&parent.ValueCount==0;parent.Close();
                        if(empty)RegistryKey.OpenBaseKey(RegistryHive.CurrentUser,RegistryView.Registry64).DeleteSubKey(@"SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps",false);}
                }
                bool text=!CrashDumps.RegistryText("HKEY_LOCAL_MACHINE","Game.exe").Contains("EncodedCommand")&&CrashDumps.RegistryText("HKEY_LOCAL_MACHINE","Game.exe").Contains(@"[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\Game.exe]");
                lines.AppendLine((text?"PASS":"FAIL")+": the machine-wide setting targets HKLM LocalDumps for the game EXE");if(!text)code=1;
                lines.AppendLine((CrashDumps.Disable("OptiShadeSelfTest.exe")==null?"PASS":"FAIL")+": turning off a setting that is not there changes nothing");
                lines.AppendLine("Read(FlightSimulator2024.exe): "+CrashDumps.Read("FlightSimulator2024.exe").Detail);
                File.WriteAllText(args[1],lines.ToString());return code;
            }
            // Sends a file through the real upload path. For synthetic files only.
            // Summarise one dump the way reports do (support and tests).
            if(args.Length==3 && args[0]=="--dump-summary") { File.WriteAllText(args[2],OptiShade.Diagnostics.DumpSummary.Analyze(args[1])); return 0; }
            // The optional uninstall reason, sent by the manager's uninstall page.
            if(args.Length==2 && args[0]=="--uninstall-feedback") return UninstallFeedback.Run(args[1],null);
            if(args.Length==3 && args[0]=="--uninstall-feedback-preview") return UninstallFeedback.Run(args[1],args[2]);
            if((args.Length==4||args.Length==5) && args[0]=="--upload-self-test") {
                var log=new StringBuilder();
                var upload=new ReportUpload(args[2],(text,sent,total)=>{lock(log)log.AppendLine(DateTime.UtcNow.ToString("HH:mm:ss.fff")+" "+sent+"/"+total+" "+text);}){RetryDelay=attempt=>TimeSpan.FromSeconds(2)};
                int code=0;string result;
                try{result="REPORT "+upload.Send(args[1],CancellationToken.None,args.Length==5?args[4]:null,"SyntheticTest").GetAwaiter().GetResult();}
                catch(Exception e){code=1;result="FAILED "+e.GetType().Name+": "+e.Message;}
                lock(log)File.WriteAllText(args[3],result+"\r\n"+log);
                return code;
            }
            if(args.Length>0 && args[0]=="--collect") {
                var r=new Request{Game=args[1],Output=args[2]};
                if(args.Length>3) r.Limit=Int64.Parse(args[3]);
                Result result=new Collector(r,s=>Console.WriteLine(s),CancellationToken.None).Run();
                Console.WriteLine(result.Zip);
                return 0;
            }
            var app=new System.Windows.Application();
            var ui=new Shell();
            if(args.Length>0 && args[0]=="--launcher-only")ui.OpenLauncherOnly();
            // OptiMFG's "Send diagnostics report": that game, with OptiMFG logs selected.
            if(args.Length>=2 && args[0]=="--game")ui.OpenGame(args[1],Array.IndexOf(args,"--mfg")>1);
            if(args.Length>0 && args[0]=="--ui-navigation") {ui.TestNavigation(args[1]);return 0;}
            if(args.Length>0 && args[0]=="--ui-collect") {
                int code=0;
                ui.Window.Loaded+=async(s,e)=>{
                    try{await ui.TestCollection(args[1],args[2]);}
                    catch(Exception error){code=1;File.WriteAllText(Path.Combine(args[2],"ui-error.txt"),error.ToString());}
                    app.Shutdown();
                };
                app.Run(ui.Window);return code;
            }
            if(args.Length==4 && args[0]=="--ui-send") {
                int code=0;
                ui.Window.Loaded+=async(s,e)=>{
                    try{await ui.TestSend(args[1],args[2],args[3]);}
                    catch(Exception error){code=1;File.WriteAllText(Path.Combine(args[2],"ui-error.txt"),error.ToString());}
                    app.Shutdown();
                };
                app.Run(ui.Window);return code;
            }
            if(args.Length>0 && args[0]=="--preview") {
                ui.Window.Show();
                var frame=new System.Windows.Threading.DispatcherFrame();
                var timer=new System.Windows.Threading.DispatcherTimer{Interval=TimeSpan.FromSeconds(1)};
                timer.Tick+=(s,e)=>{timer.Stop();frame.Continue=false;};timer.Start();
                System.Windows.Threading.Dispatcher.PushFrame(frame);
                if(args.Length>2 && args[2]=="memory")ui.Navigate(true);
                if(args.Length>2 && args[2]=="confirm"){ui.Navigate(true);ui.PreviewConfirm(Path.ChangeExtension(args[1],".confirm.png"));}
                if(args.Length>3 && args[2]=="game")ui.OpenGame(args[3],true);
                if(args.Length>2 && args[2]=="check"){ui.Navigate(true);ui.PreviewCheck(Path.ChangeExtension(args[1],".check.png"));}
                ui.Window.Dispatcher.Invoke(System.Windows.Threading.DispatcherPriority.ApplicationIdle,new Action(()=>{}));
                ui.Window.UpdateLayout();
                var bitmap=new System.Windows.Media.Imaging.RenderTargetBitmap((int)ui.Window.ActualWidth,(int)ui.Window.ActualHeight,96,96,System.Windows.Media.PixelFormats.Pbgra32);
                bitmap.Render(ui.Window);
                var encoder=new System.Windows.Media.Imaging.PngBitmapEncoder();encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bitmap));
                using(var f=File.Create(args[1]))encoder.Save(f);
                ui.Window.Close(); return 0;
            }
            app.Run(ui.Window); return 0;
        } catch(Exception e) {
            string error=Path.Combine(Path.GetTempPath(),"OptiShade-Tester-Kit-error.txt");
            File.WriteAllText(error,e.ToString());
            if(args.Length==0) MessageBox.Show(e.Message+"\r\nDetails: "+error,"OptiShade Troubleshooter");
            return 1;
        }
    }
}
static class Tests {
    static void Check(bool condition,string label,List<string> results) {if(!condition)throw new Exception("FAIL: "+label);results.Add("PASS: "+label);}
    public static void RunMfgNativeLog(string root) {
        Directory.CreateDirectory(root);var results=MfgNativeLogChecks();
        File.WriteAllText(Path.Combine(root,"mfg-native-log-self-test-results.txt"),String.Join("\r\n",results));
    }
    public static void RunMfgTrace(string root) {
        Directory.CreateDirectory(root);var results=new List<string>();
        string fixture=Path.Combine(root,"mfg-interval-"+Guid.NewGuid().ToString("N"));string game=Path.Combine(fixture,"game");string temp=Path.Combine(fixture,"temp");
        Directory.CreateDirectory(Path.Combine(game,"OptiShadeData","MFG"));Directory.CreateDirectory(temp);
        try {
            using(Process current=Process.GetCurrentProcess()) {
                uint pid=(uint)current.Id;DateTime processBirth=current.StartTime.ToUniversalTime();long birth=processBirth.ToFileTimeUtc();long heartbeat=Math.Max((DateTime.UtcNow.Ticks-new DateTime(1970,1,1,0,0,0,DateTimeKind.Utc).Ticks)/TimeSpan.TicksPerSecond,(long)(processBirth.AddSeconds(3).Ticks-new DateTime(1970,1,1,0,0,0,DateTimeKind.Utc).Ticks)/TimeSpan.TicksPerSecond);
                string trace=Path.Combine(temp,"MfgUnlock-intervals-"+pid+".csv");File.WriteAllText(trace,"# fixture\r\ninterval-sequence-sentinel\r\n");
                string previous=Path.Combine(temp,"MfgUnlock-intervals-"+pid+".previous.csv");File.WriteAllText(previous,"# fixture\r\nprevious-interval-sentinel\r\n");
                Check(Collector.IsSessionBoundMfgIntervalTrace(trace,pid,birth,heartbeat,DateTime.UtcNow,24),"Current MFG interval trace passes PID/birth/time bounds",results);
                Check(Collector.IsSessionBoundMfgIntervalTrace(previous,pid,birth,heartbeat,DateTime.UtcNow,24),"Previous bounded MFG interval trace passes PID/birth/time bounds",results);
                Check(!Collector.IsSessionBoundMfgIntervalTrace(trace,pid+1,birth,heartbeat,DateTime.UtcNow,24),"MFG interval trace with a different PID is rejected",results);
                string receipt="{\"product\":\"OptiShadeMFG\",\"abi\":131072,\"pid\":"+pid+",\"processBirth\":"+birth+",\"heartbeat\":"+heartbeat+"}";
                File.WriteAllText(Path.Combine(game,"OptiShadeData","MFG","session.json"),receipt);
                var request=new Request{Game=game,Hours=24};var collector=new Collector(request,s=>{},CancellationToken.None);
                var flags=BindingFlags.NonPublic|BindingFlags.Instance;
                typeof(Collector).GetField("exe",flags).SetValue(collector,"FixtureGame.exe");
                typeof(Collector).GetField("mfgTempDirectory",flags).SetValue(collector,temp);
                typeof(Collector).GetMethod("MfgLogs",flags).Invoke(collector,null);
                var captured=(List<Item>)typeof(Collector).GetField("items",flags).GetValue(collector);
                Check(captured.Any(i=>i.Name=="providers/MfgUnlock-intervals-selected-session.csv"&&i.Text.Contains("interval-sequence-sentinel")),"Troubleshooter packages the selected session MFG interval trace",results);
                Check(captured.Any(i=>i.Name=="providers/MfgUnlock-intervals-previous-selected-session.csv"&&i.Text.Contains("previous-interval-sentinel")),"Troubleshooter packages the previous bounded MFG interval trace",results);
            }
        } finally {if(Directory.Exists(fixture))Directory.Delete(fixture,true);}
        File.WriteAllText(Path.Combine(root,"mfg-trace-self-test-results.txt"),String.Join("\r\n",results));
    }
    static void PutU32(byte[] bytes,int offset,uint value) {Buffer.BlockCopy(BitConverter.GetBytes(value),0,bytes,offset,4);}
    static void WriteIdentityDump(string path,uint flags,uint pid,uint processCreateTime,uint miscSize=24) {
        byte[] bytes=new byte[checked(60+(int)miscSize)];
        PutU32(bytes,0,0x504d444d);PutU32(bytes,4,0x0000a793);PutU32(bytes,8,2);PutU32(bytes,12,32);
        PutU32(bytes,32,4);PutU32(bytes,36,4);PutU32(bytes,40,56); // Empty module list, sufficient for metadata analysis.
        PutU32(bytes,44,15);PutU32(bytes,48,miscSize);PutU32(bytes,52,60);
        PutU32(bytes,56,0);PutU32(bytes,60,miscSize);if(miscSize>=8)PutU32(bytes,64,flags);if(miscSize>=12)PutU32(bytes,68,pid);if(miscSize>=16)PutU32(bytes,72,processCreateTime);
        File.WriteAllBytes(path,bytes);
    }
    public static void Run(string root) {
        Directory.CreateDirectory(root);var results=new List<string>();
        foreach(string line in MfgNativeLogChecks()) results.Add(line);
        string hangPreferenceRoot=Path.Combine(root,"auto-hang-upload-preference-test"),hangPreference=Path.Combine(hangPreferenceRoot,"AutoHangUpload.txt");
        try {
            Check(AutoCapture.ReadAutomaticUploadPreference(hangPreference),"Automatic hang upload defaults on when no preference exists",results);
            AutoCapture.WriteAutomaticUploadPreference(hangPreference,true);
            Check(AutoCapture.ReadAutomaticUploadPreference(hangPreference),"Automatic hang upload on preference persists for the watcher",results);
            AutoCapture.WriteAutomaticUploadPreference(hangPreference,false);
            Check(!AutoCapture.ReadAutomaticUploadPreference(hangPreference),"Explicit automatic hang upload opt-out persists for the watcher",results);
            AutoCapture.WriteAutomaticUploadPreference(hangPreference,true);
            File.WriteAllText(hangPreference,"unknown-value");
            Check(!AutoCapture.ReadAutomaticUploadPreference(hangPreference),"Unknown automatic-upload preference fails closed",results);
            AutoCapture.WriteAutomaticUploadPreference(hangPreference,false);
            Check(File.Exists(hangPreference)&&!AutoCapture.ReadAutomaticUploadPreference(hangPreference),"Turning off automatic upload writes an explicit opt-out",results);
        } finally { if(Directory.Exists(hangPreferenceRoot))Directory.Delete(hangPreferenceRoot,true); }
        string glassTrace="";
        for(int i=0;i<6;i++)glassTrace+="20:36:15 cost frames=0\r\n";
        glassTrace+="20:36:15 note not an NVIDIA GPU: DLSS unavailable\r\n20:36:15 DLSS answered by another mod: winmm.dll 0.7.7.0 hook=1\r\n20:36:23 WARNING DLSS evaluate hook was changed by another mod\r\n20:36:23 stats overlay=1 jitter_positive=1 dlss_calls=0 dlss_upscales=0 fsr_calls=0 screen_draws=0 recorded=0 overlay_frames=0 skipped=0\r\n";
        var glassFinding=Verdicts.GlassCockpitNotDrawing(new[]{glassTrace},new[]{"CheckWorkingMode OptiScaler working as winmm.dll\r\nhkD3D12CreateDevice Adapter Desc: AMD Radeon(TM) Graphics\r\nhkD3D12CreateDevice Adapter Desc: NVIDIA GeForce RTX 4080 SUPER"});
        Check(glassFinding.Count==1&&glassFinding[0].Contains("winmm.dll answered DLSS")&&glassFinding[0].Contains("WinMM route")&&glassFinding[0].Contains("AMD D3D12 device"),"Glass Cockpit assessment correlates OptiShade WinMM hook conflict and early hybrid-GPU selection",results);
        var glassNoOptiWinmm=Verdicts.GlassCockpitNotDrawing(new[]{glassTrace},new[]{"no OptiScaler WinMM route evidence"});
        Check(glassNoOptiWinmm.Count==1&&!glassNoOptiWinmm[0].Contains("OptiScaler was running through its WinMM route"),"Glass Cockpit assessment does not attribute another mod's hook to OptiShade without route evidence",results);
        // Check my setup: plain advice for each finding, fixable first, nothing sent.
        var defender=Verdicts.DefenderBlocks(new[]{"header\r\n2026-10-30T10:00:00.0000000Z | 1116 | Threat: Trojan:Win32/Wacatac.B!ml | Path: C:\\Games\\MSFS\\OptiShadeData\\OptiMFG\\Runtime\\OptiMFG_Live.exe | Action: Quarantine\r\n"});
        Check(defender.Count==2&&defender[0].StartsWith("WINDOWS SECURITY DETECTION")&&defender[0].Contains("OptiMFG_Live.exe"),"Troubleshooter reports Windows Defender detections of OptiShade files",results);
        Check(Verdicts.DefenderBlocks(new[]{"Windows Defender log unreadable (UnauthorizedAccessException)."}).Count==0,"An unreadable Defender log is not reported as a detection",results);
        var download=Verdicts.DefenderBlocks(new[]{"2026-10-31T22:29:55.0Z | 1117 | Threat: T | Path: <USER>\\Downloads\\OptiShade.exe; web<USER>\\Downloads\\OptiShade.exe|https://cdn.example/a.exe?hm=secret|pid:1; process:_pid:2 | Action: Quarantine"});
        Check(download[0].Contains("OptiShade.exe")&&!download[0].Contains("process:")&&!download.Any(l=>l.Contains("hm=secret")),"Defender findings show file paths, not download URLs or process entries",results);
        Check(!Verdicts.RelevantDefenderPath(@"D:\OtherGame\winmm.dll",@"D:\MSFS") && !Verdicts.RelevantDefenderPath(@"D:\MSFS-other\version.dll",@"D:\MSFS"),"Generic proxy in another game is not attributed to OptiShade",results);
        Check(Verdicts.RelevantDefenderPath(@"D:\MSFS\winmm.dll",@"D:\MSFS") && Verdicts.RelevantDefenderPath(@"<GAME>\version.dll"),"Selected game detection remains visible",results);
        Check(Verdicts.DefenderBlocks(new[]{@"2026-10-22T19:12:11Z | 1117 | Path: D:\OtherGame\winmm.dll | Action: Remove"},new DateTime(2026,11,4,0,0,0,DateTimeKind.Utc)).Count==0,"Old unrelated antivirus event does not become the current primary issue",results);
        Check(Verdicts.DefenderBlocks(new[]{@"2026-10-22T19:12:11Z | 1117 | Path: <GAME>\winmm.dll | Action: Remove"},new DateTime(2026,11,4,0,0,0,DateTimeKind.Utc)).Count==0,"Old related antivirus event respects the capture lookback",results);
        var earlierDisplay=Verdicts.DriverTimeouts(new[]{"2026-11-05T15:42:52Z | nvlddmkm | 153"},new DateTime(2026,11,5,20,0,0,DateTimeKind.Utc));
        Check(earlierDisplay.Count==1&&earlierDisplay[0].StartsWith("HISTORICAL DISPLAY EVENT"),"Earlier driver event cannot diagnose the later saved game session",results);
        var sessionBirth=new DateTime(2026,11,6,21,54,20,DateTimeKind.Utc).ToFileTimeUtc();
        var oldCrashTime=new DateTime(2026,11,6,20,15,52,DateTimeKind.Utc).ToFileTimeUtc();
        var sessionIdentity=new KeyValuePair<string,string>("logs/LastSession.json","{\"ProcessBirthFileTime\":\""+sessionBirth+"\",\"CapturedUtc\":\"2026-11-06T22:17:46Z\"}");
        var priorWer=new KeyValuePair<string,string>("crashes/WER-system-1.txt","EventType=APPCRASH\r\nEventTime="+oldCrashTime+"\r\nSig[3].Value=CoherentUIGT.dll\r\nSig[4].Value=2.9.5.0\r\nSig[6].Value=c0000005\r\nSig[7].Value=0009ba1a\r\n");
        var separateSession=Verdicts.Analyze(new[]{sessionIdentity,priorWer,new KeyValuePair<string,string>("events/System.txt","2026-11-06T18:27:56Z | Microsoft-Windows-Kernel-Power | 41\r\n")});
        Check(separateSession.Any(f=>f.Text.StartsWith("HISTORICAL CRASH"))&&!separateSession.Any(f=>f.Text.StartsWith("CRASH in CoherentUIGT"))&&separateSession.Any(f=>f.Text.StartsWith("HISTORICAL SYSTEM RESTART"))&&Verdicts.Primary(separateSession).StartsWith("PRIMARY ISSUE: none detected"),"Prior crash and restart do not become the primary diagnosis for a later game session",results);
        var currentWer=new KeyValuePair<string,string>("crashes/WER-system-1.txt","EventType=APPCRASH\r\nEventTime="+sessionBirth+"\r\nSig[3].Value=CoherentUIGT.dll\r\nSig[4].Value=2.9.5.0\r\nSig[6].Value=c0000005\r\nSig[7].Value=0009ba1a\r\n");
        Check(Verdicts.Crash(new[]{sessionIdentity,currentWer}).Any(l=>l.StartsWith("CRASH in CoherentUIGT")),"Crash within the selected game session remains a crash finding",results);
        Check(Verdicts.DriverTimeouts(new[]{"2026-11-05T20:10:00Z | nvlddmkm | 153"})[0].StartsWith("GPU DRIVER EVENT"),"Generic NVIDIA event is not asserted to be a timeout",results);
        Check(Verdicts.DriverTimeouts(new[]{"2026-11-05T20:10:00Z | Display | 4101"})[0].StartsWith("GPU DRIVER TIMEOUT"),"Windows display recovery remains visible",results);
        var bound=Verdicts.SessionControllers(new List<KeyValuePair<string,string>>{
            new KeyValuePair<string,string>("logs/LastSession.json","{\"PID\":\"42\",\"ProcessBirthFileTime\":\"134383833020881037\"}"),
            new KeyValuePair<string,string>("mfg/controller-old.jsonl","{\"pid\":42,\"tick_ms\":20,\"backend_snapshot\":{\"processBirth\":134383833020881036,\"marker\":\"OLD\"}}"),
            new KeyValuePair<string,string>("mfg/controller-current.jsonl","{\"pid\":42,\"tick_ms\":10,\"backend_snapshot\":{\"processBirth\":134383833020881037,\"marker\":\"CURRENT\"}}")});
        Check(bound.Count==1&&bound[0].Contains("CURRENT")&&!bound[0].Contains("OLD"),"Controller evidence requires exact PID and 64-bit process birth",results);
        string followSample="{\"event\":\"backend_status\",\"backend_requested\":-1,\"backend_snapshot\":{\"followGame\":true,\"appliedMultiplier\":3,\"gameFrameGenerationOn\":false,\"actualFramesPresented\":1}}";
        var follow=Verdicts.Mfg(new[]{followSample},new string[0]);
        Check(follow.Any(l=>l.StartsWith("MFG FOLLOW GAME"))&&!follow.Any(l=>l.Contains("OptiMFG applied")),"Follow game does not claim OptiMFG forced the saved multiplier",results);
        // Memory samples: growth over a session, low system memory, video memory over budget.
        var samples=new StringBuilder();
        for(int i=0;i<=120;i++)samples.Append("[I] Memory sample: pid=7 tick="+(1000000+i*60000)+" privateMB="+(25000+i*60)+" workingSetMB=1 commitMB="+(i==120?62000:40000)+" commitLimitMB=64000 availableRamMB="+(i==120?600:9000)+" vramMB="+(i==120?17000:12000)+" vramBudgetMB=15500\n");
        var memory=Verdicts.MemoryTrend(new[]{samples.ToString()});
        var loading=new StringBuilder();
        for(int i=0;i<=36;i++)loading.Append("[I] Memory sample: pid=9 tick="+(1000000+i*60000)+" privateMB="+(i<20?1600+i*1900:40100)+" workingSetMB=1 commitMB=30000 commitLimitMB=64000 availableRamMB=9000 vramMB=9000 vramBudgetMB=15500\n");
        Check(Verdicts.MemoryTrend(new[]{loading.ToString()}).Count==0,"Memory growth ignores the simulator's first 15 minutes of loading",results);
        Check(memory.Count==3&&memory[0].StartsWith("MEMORY GROWTH")&&memory[0].Contains("over 105 min")&&memory[1].StartsWith("LOW SYSTEM MEMORY")&&memory[2].StartsWith("VIDEO MEMORY OVER BUDGET"),"Memory samples show growth, low system memory and video memory over budget",results);
        Check(Verdicts.MemoryTrend(new[]{"[I] Memory sample: pid=7 tick=1 privateMB=25000 workingSetMB=1 commitMB=30000 commitLimitMB=64000 availableRamMB=9000 vramMB=9000 vramBudgetMB=15500\n[I] Memory sample: pid=7 tick=3600001 privateMB=25500 workingSetMB=1 commitMB=30000 commitLimitMB=64000 availableRamMB=9000 vramMB=9000 vramBudgetMB=15500"}).Count==0,"Stable memory raises no memory finding",results);
        var localised=Verdicts.DefenderBlocks(new[]{"2026-10-30T00:53:53.6Z | 1117 | Threat:  | Path: <USER>\\Sessions\\FusionSetup.exe%\uFFFD %Lokaler Computer%FastPath | Action: "});
        Check(localised[0].Contains("FusionSetup.exe. A detection")&&!localised.Any(l=>l.Contains("Lokaler")),"Defender paths end at the file name on localised Windows",results);
        var r334=Verdicts.Analyze(new[]{new KeyValuePair<string,string>("logs/OptiShadeData_BuildIdentity.json.txt","{\"PrivateBuildLabel\":\"Rebuild R334\"}"),
            new KeyValuePair<string,string>("settings/OptiScaler.ini.txt","[Plugins]\r\nLoadReshade = auto\r\n"),new KeyValuePair<string,string>("system/installed-hashes.txt","ReShade64.dll | 5928960 bytes | X")});
        Check(!r334.Any(f=>f.Text.StartsWith("IMAGE EFFECTS NOT LOADED")),"R330+ is not told an auto LoadReShade stops effects",results);
        Check(Verdicts.EffectsNotLoaded("[Plugins]\r\nLoadReshade = auto\r\n[Log]\r\nLogFileName = auto\r\n","ReShade64.dll | 5928960 bytes | X")[0].StartsWith("IMAGE EFFECTS NOT LOADED"),"Troubleshooter flags an OptiScaler.ini that no longer loads ReShade",results);
        Check(Verdicts.EffectsNotLoaded("[Plugins]\r\nLoadReShade=true\r\n","ReShade64.dll | 5928960 bytes | X").Count==0&&Verdicts.EffectsNotLoaded("LoadReShade=auto","dxgi.dll: absent").Count==0,"ReShade loading is not flagged when it is on or not installed",results);
        var gated=Verdicts.NeuralOnGeneratedFrames(new string[0],new[]{"TAA NR paused: the game's frame generation is generating (2x)\nTAA pre-FG gate: tags: frame generation not confirmed as generating; signature=0 optiMfgController=true"});
        Check(gated.Count==1&&gated[0].Contains("last check that stopped it: tags: frame generation not confirmed as generating"),"TAA NR pause names the pre-FG gate that stopped it",results);
        var ungated=Verdicts.NeuralOnGeneratedFrames(new string[0],new[]{"TAA NR paused: the game's frame generation is generating (2x)\nTAA NR: Frame generation is on: TAA NR runs before frame generation once the game's frame inputs are confirmed, and is paused until then."});
        Check(ungated[0].Contains("was on but never started"),"TAA NR pause does not claim the feature was off when it was waiting",results);
        var stub=Verdicts.WrongGameExecutable("Executable: H:\\FS25\\FarmingSimulator2025.exe\r\nStubTarget: H:\\FS25\\x64\\FarmingSimulator2025Game.exe\r\n");
        Check(stub.Count==1&&stub[0].StartsWith("WRONG GAME EXE")&&stub[0].Contains("x64\\FarmingSimulator2025Game.exe"),"Troubleshooter names the game EXE behind a launcher stub",results);
        Check(Verdicts.WrongGameExecutable("Executable: H:\\FS25\\x64\\FarmingSimulator2025Game.exe\r\n").Count==0,"The real game EXE is not flagged as a launcher",results);
        Check(Verdicts.WrongGameExecutable("Executable: <USER>\\FS25\\FarmingSimulator2025.exe\r\nStubTarget: <USER>\\FS25\\x64\\FarmingSimulator2025Game.exe\r\n")[0].Contains("beside FarmingSimulator2025.exe,"),"Launcher check reads redacted paths",results);
        var ini=new KeyValuePair<string,string>("settings/OptiScaler.ini.txt","[Log]\r\nLogFileName = OptiShadeData/Performance.log\r\n");
        var emptied=Verdicts.MissingRuntimeLog(new List<KeyValuePair<string,string>>{new KeyValuePair<string,string>("logs/Performance-current.txt","Original bytes: 0; captured offset: 0; bytes: 0"),
            new KeyValuePair<string,string>("logs/Performance.log.first.log.txt","Original bytes: 2183;\r\n[14:42:40] [W] OptiScaler v0.7.7-final loaded"),ini});
        Check(emptied.Count==1&&emptied[0].StartsWith("RUNTIME LOG EMPTIED"),"An empty log after a logged startup is reported as emptied by another process",results);
        Check(Verdicts.MissingRuntimeLog(new List<KeyValuePair<string,string>>{new KeyValuePair<string,string>("logs/Performance-current.txt","Original bytes: 0;"),ini})[0].StartsWith("RUNTIME LOG MISSING"),"An empty log with no logged startup stays a missing log",results);
        var dump=Verdicts.Crash(new[]{new KeyValuePair<string,string>("crashes/1-sl-sha-da40c631.dmp.txt","Dump-to-session association: MATCHED: dump PID\r\nException thread: 1; code=0xC0000005; flags=0x0\r\nException address: 0x1DF36BCA4D8 (unmapped)\r\nAccess violation: execute at 0x1DF36BCA4D8\r\n  [RSP+0x20] 0x7FFFEAC7CD00 ucrtbase.dll+0x2CD00\r\n")});
        Check(dump.Count==1&&dump[0].StartsWith("CRASH DUMP")&&dump[0].Contains("stale function pointer"),"A session-matched dump with no crash report is still reported",results);
        Check(Verdicts.Crash(new[]{new KeyValuePair<string,string>("crashes/1-x.dmp.txt","Dump-to-session association: DIFFERENT PROCESS INSTANCE\r\nException thread: 1; code=0xC0000005; flags=0x0\r\nException address: 0x1 (unmapped)\r\n")}).Count==0,"A dump from another process is not reported as this session's crash",results);
        var mfgCrash=Verdicts.OptiMfgCrash(new[]{"2026-11-02T23:01:00.0000000Z | Application Error | 1000\r\nFaulting application name: OptiMFG_Live.exe, version: 1.0.0.0\r\nFaulting module name: d3d11.dll, version: 10.0.26100.1\r\nException code: 0xc0000005\r\n\r\n2026-11-02T23:02:00.0000000Z | Application Error | 1000\r\nFaulting application name: FlightSimulator2024.exe, version: 1.9.21.0\r\nFaulting module name: x.dll\r\n"});
        Check(mfgCrash.Count==1&&mfgCrash[0].Contains("1 OptiMFG_Live.exe crash(es)")&&mfgCrash[0].Contains("in d3d11.dll")&&mfgCrash[0].Contains("0xc0000005"),"An OptiMFG app crash is reported with its faulting module",results);
        var restart=Verdicts.UnexpectedRestart(new[]{"2026-11-01T13:20:00.0000000Z | Microsoft-Windows-Kernel-Power | 41\r\nThe system has rebooted without cleanly shutting down first.\r\n\r\n2026-11-01T13:20:05.0000000Z | BugCheck | 1001\r\nThe computer has rebooted from a bugcheck. The bugcheck was: 0x00000116 (0x1, 0x2).\r\n"});
        Check(restart.Count==1&&restart[0].StartsWith("PC RESTARTED UNEXPECTEDLY")&&restart[0].Contains("0x00000116"),"An unexpected PC restart and its stop code are reported",results);
        var foreign=Verdicts.ForeignReShade(new[]{"15:51:39:270 [28388] | WARN  | Another ReShade instance was already loaded from '<GAME>\\dxgi.dll'! Aborting initialization ..."});
        Check(foreign.Count==1&&foreign[0].Contains("move dxgi.dll out of the game folder"),"A separate ReShade that loaded first is named",results);
        var handler=Verdicts.HungInCrashHandler(new[]{"Thread 28388: RIP=0x7FFEC7AE2254 ntdll.dll+0x162254 RSP=0x1\r\n  candidate [RSP+0x0] 0x7FFEC6F0E439 kernel32.dll+0xE439\r\n  candidate [RSP+0x60] 0x7FFE95BB54DB dbgcore.dll+0x154DB\r\n  candidate [RSP+0x6C0] 0x7FFEB48BB9E0 dbghelp.dll+0x2B9E0\r\n  candidate [RSP+0xFB0] 0x7FFE3B817A80 sl.interposer.dll+0x77A80\r\n"});
        Check(handler.Count==1&&handler[0].Contains("sl.interposer.dll (NVIDIA Streamline's crash handler)"),"A game frozen inside its crash handler is reported as a crash",results);
        Check(Verdicts.HungInCrashHandler(new[]{"Thread 1: RIP=0x1 ntdll.dll+0x1 RSP=0x1\r\n  candidate [RSP+0x0] 0x2 FlightSimulator2024.exe+0x2\r\n"}).Count==0,"An ordinary waiting thread is not a crash handler",results);
        var vrLog=new StringBuilder("23:07:29:822 [1] | INFO  | OptiShade output context: api=49152 vr=1 width=9534 height=2688 format=28 colorSpace=0 samples=1 layers=1\n");
        for(int i=0;i<12;i++)vrLog.Append("23:07:31:000 [1] | INFO  | Successfully compiled 'x.fx' in 0.003 s.\n");
        var vrFx=Verdicts.VrHeadsetEffects(new[]{vrLog.ToString()});
        Check(vrFx.Count==1&&vrFx[0].Contains("9534x2688 (25.6 megapixels")&&vrFx[0].Contains("195 MiB"),"Image effects on the VR headset image are reported with their size",results);
        Check(Verdicts.VrHeadsetEffects(new[]{"OptiShade output context: api=49152 vr=0 width=2560 height=1440\nSuccessfully compiled\n"}).Count==0,"Desktop-only image effects are not reported as VR",results);
        var pauses=new StringBuilder();
        foreach(string at in new[]{"23:09:30","23:09:43","23:10:00","23:10:08"})
            foreach(string ms in new[]{".469",".477"})pauses.Append("["+at+ms+"] [W] DLSS-NR stopped: Paused: video memory is almost full and Pause NR when video memory is low is on.\n");
        var paused=Verdicts.NeuralMemoryPause(new[]{pauses.ToString()});
        Check(paused.Count==1&&paused[0].StartsWith("NR PAUSED FOR GPU MEMORY 4 time(s)"),"A stop logged once per output is one stop, not an on/off loop",results);
        var advice=SelfHelp.Build(Verdicts.Analyze(new[]{
            new KeyValuePair<string,string>("events/Defender.txt","2026-10-30T10:00:00.0000000Z | 1117 | Threat: X | Path: <GAME>\\dxgi.dll | Action: Remove"),
            new KeyValuePair<string,string>("checks/game-executable.txt","Executable: H:\\FS25\\FarmingSimulator2025.exe\r\nStubTarget: H:\\FS25\\x64\\FarmingSimulator2025Game.exe")}));
        Check(advice.Count==2&&advice.All(a=>a.UserCanFix)&&advice.Any(a=>a.TryThis.Contains("Protection history"))&&advice.Any(a=>a.Title.Contains("launcher")),"Check my setup turns findings into player steps",results);
        var unknown=SelfHelp.For(new Finding{Severity=2,Area="x",Text="SOMETHING NEW: detail"});
        Check(!unknown.UserCanFix&&unknown.TryThis.Contains("Send a report"),"Findings without player advice point to sending a report",results);
        var ordered=SelfHelp.Build(new[]{new Finding{Severity=1,Area="a",Text="CRASH in x.dll"},new Finding{Severity=4,Area="b",Text="MFG WORKING: ok"},new Finding{Severity=2,Area="c",Text="MFG: OptiMFG applied 3x but frame generation is off"}});
        Check(ordered.Count==3&&ordered[0].UserCanFix&&!ordered[1].UserCanFix&&ordered[2].Good,"Check my setup lists fixable problems first, report-only next, working last",results);
        Check(SelfHelp.Format(new List<Advice>()).Contains("No known problem"),"An empty check says nothing known was found",results);
        var nrOff=Collector.NeuralSessionAssessment(new Dictionary<string,object>{{"Requested","Off"},{"API","Vulkan"},{"NRRoute","0"},{"NRStage","Waiting"}});
        Check(nrOff.Contains("NR requested=Off")&&nrOff.Contains("no explicit activation action record")&&nrOff.Contains("cannot establish that NR was never attempted"),"Troubleshooter treats missing action history as unknown rather than proof NR was never attempted",results);
        var nrOffAfterAttempt=Collector.NeuralSessionAssessment(new Dictionary<string,object>{{"Requested","Off"},{"NRActivationAttemptCount","2"},{"NRActivationHistory","2026-10-25T09:50:00.000Z On source=in-game-panel; 2026-10-25T09:51:00.000Z Off source=hotkey"},{"NRActivationLastAction","Off"},{"NRActivationLastSource","hotkey"},{"NRActivationOutcome","Deactivation requested"},{"NRStage","Waiting"}});
        Check(nrOffAfterAttempt.Contains("recorded 2 explicit NR control action")&&nrOffAfterAttempt.Contains("On/Off history")&&nrOffAfterAttempt.Contains("not evidence that it was never attempted"),"Troubleshooter preserves an On attempt even when the final NR state is Off",results);
        var xp12Block=Collector.NeuralSessionAssessment(new Dictionary<string,object>{{"Requested","On"},{"NRActivationAttemptCount","1"},{"NRActivationLastAction","On"},{"NRActivationLastSource","in-game-panel"},{"XP12BridgeAdmissionStage","Blocked before NR frame submission"},{"XP12BridgeFirstBlockReason","Core guide history warming up"},{"XP12BridgeLatestBlockReason","Vulkan device cannot import this D3D12 image format"},{"XP12BridgeLatestBlockUtc","2026-10-26T12:55:35.000Z"},{"XP12BridgeBlockCount","2"},{"XP12BridgeBlockAPI","Vulkan"},{"XP12BridgeBlockDevice","101"},{"XP12BridgeBlockOwner","202"},{"XP12BridgeBlockGeneration","303"},{"XP12BridgeBlockQueue","404"},{"NRStage","Waiting"}});
        Check(xp12Block.Contains("XP12 first block=Core guide history warming up")&&xp12Block.Contains("latest XP12 block=Vulkan device cannot import this D3D12 image format")&&xp12Block.Contains("API=Vulkan, device=101, owner=202, generation=303, queue=404"),"Troubleshooter preserves the initial XP12 event and reports the current Vulkan NR blocker",results);
        var nrWaiting=Collector.NeuralSessionAssessment(new Dictionary<string,object>{{"Requested","On"},{"NRStage","Waiting"},{"LastFailure","Not observed"}});
        Check(nrWaiting.Contains("NR was requested")&&nrWaiting.Contains("does not establish why processing stopped"),"Troubleshooter distinguishes a pending NR request from a confirmed failure",results);
        var nrActive=Collector.NeuralSessionAssessment(new Dictionary<string,object>{{"Requested","On"},{"NRStage","Active"}});
        Check(nrActive.Contains("runtime stage was recorded")&&nrActive.Contains("does not prove that the processed image was visible"),"Troubleshooter does not equate an NR runtime stage with visible output",results);
        Check(Collector.NeuralSessionAssessment(null).Contains("cannot determine whether NR was requested"),"Missing session data remains explicitly unknown",results);
        var nrInjected=Collector.NeuralSessionAssessment(new Dictionary<string,object>{{"Requested","Off\r\nforged observation"},{"LastFailure",new string('x',300)}});
        Check(!nrInjected.Contains("\nforged observation")&&nrInjected.Length<1800,"Saved NR fields are bounded and cannot inject report lines",results);
        string nrFixture=Path.Combine(root,"neural-session-summary");Directory.CreateDirectory(Path.Combine(nrFixture,"OptiShadeData"));
        File.WriteAllText(Path.Combine(nrFixture,"OptiShadeData","LastSession.json"),"{\"Requested\":\"Off\",\"API\":\"Vulkan\",\"NRRoute\":\"0\",\"NRStage\":\"Waiting\"}");
        var nrRequest=new Request{Game=nrFixture};var nrCollector=new Collector(nrRequest,s=>{},CancellationToken.None);
        typeof(Collector).GetMethod("NeuralSessionAssessment",BindingFlags.NonPublic|BindingFlags.Instance).Invoke(nrCollector,null);
        var nrFindings=(StringBuilder)typeof(Collector).GetField("findings",BindingFlags.NonPublic|BindingFlags.Instance).GetValue(nrCollector);
        Check(nrFindings.ToString().Contains("NR was not requested in this saved session's final state"),"Troubleshooter report reads LastSession and surfaces the current NR-off explanation",results);
        Check(Collector.GameFileToken("GTA5_Enhanced.exe")=="GTA5-Enhanced","Diagnostic filename token identifies the selected game",results);
        Check(Collector.GameFileToken("???.exe")=="Unknown-Game","Invalid diagnostic filename token has a safe fallback",results);
        var slowLoad=new StallPolicy();
        Check(slowLoad.Observe(45,false,1)==null&&slowLoad.Observe(299,false,1)==null,"Slow or briefly unresponsive startup is ignored during the five-minute grace",results);
        Check(slowLoad.Observe(300,false,1)==null&&slowLoad.Observe(419,false,1)==null,"Startup grace does not trigger an immediate hang report",results);
        Check(slowLoad.Observe(421,false,1)!=null,"Sustained nonresponse is detected after startup grace and threshold",results);
        var msfsPolicy=StallPolicy.ForExecutable(@"C:\Games\FlightSimulator2024.exe");
        Check(msfsPolicy.ActiveStartupGraceSeconds==600&&msfsPolicy.ActiveUnresponsiveThresholdSeconds==90&&msfsPolicy.ActiveTraceStallThresholdSeconds==180,"MSFS 2024 gets a ten-minute load grace, then 90 s nonresponse or 180 s pending GPU work",results);
        Check(msfsPolicy.Observe(599,false,4)==null&&msfsPolicy.Observe(600,false,4)==null&&msfsPolicy.Observe(689,false,4)==null,"Slow MSFS 2024 loading does not create an early hang report",results);
        Check(msfsPolicy.Observe(691,false,4)!=null,"A sustained MSFS 2024 nonresponse is still captured after its longer threshold",results);
        var msfsTrace=StallPolicy.ForExecutable("FlightSimulator2024.exe");
        Check(msfsTrace.Observe(600,true,20,false)==null&&msfsTrace.Observe(1199,true,20,false)==null&&msfsTrace.Observe(1201,true,20,false)==null,"A frozen sequence without a pending GPU checkpoint does not trigger a false MSFS hang",results);
        var pendingMsfsTrace=StallPolicy.ForExecutable("FlightSimulator2024.exe");
        Check(pendingMsfsTrace.Observe(600,true,20,true)==null&&pendingMsfsTrace.Observe(779,true,20,true)==null,"MSFS 2024 pending GPU checkpoints receive the longer threshold",results);
        Check(pendingMsfsTrace.Observe(781,true,20,true)!=null,"A sustained current-session pending GPU checkpoint is captured",results);
        Check(StallPolicy.ForExecutable("Cyberpunk2077.exe").ActiveStartupGraceSeconds==StallPolicy.StartupGraceSeconds,"Other games retain the general startup grace",results);
        var stoppedTrace=new StallPolicy();
        Check(stoppedTrace.Observe(300,true,10,true)==null&&stoppedTrace.Observe(479,true,10,true)==null,"Pending GPU checkpoint receives a separate post-startup grace",results);
        Check(stoppedTrace.Observe(481,true,10,true)!=null,"A sustained pending GPU checkpoint can identify a possible stall",results);
        var movingTrace=new StallPolicy();movingTrace.Observe(300,true,10,true);
        Check(movingTrace.Observe(600,true,11,false)==null,"A progress snapshot clears the pending-GPU timer",results);
        DateTime processStart=DateTime.UtcNow.AddMinutes(-2);DateTime currentWrite=DateTime.UtcNow;
        Check(AutoCapture.IsFreshPerformanceLog(currentWrite,processStart,DateTime.UtcNow),"Current-session Performance.log freshness is accepted",results);
        Check(!AutoCapture.IsFreshPerformanceLog(processStart.AddMinutes(-1),processStart,DateTime.UtcNow),"A Performance.log from before process start is ignored",results);
        var freshTrace=AutoCapture.ParsePerformanceTrace("Performance.log","FGTRACE seq=100 SNAPSHOT progress\r\n",currentWrite,processStart,DateTime.UtcNow);
        Check(freshTrace.Sequence==100&&!freshTrace.PendingGpuCheckpoint,"A fresh progress snapshot is distinguished from a pending GPU checkpoint",results);
        var pendingTrace=AutoCapture.ParsePerformanceTrace("Performance.log","FGTRACE seq=101 SNAPSHOT pending GPU checkpoint older than 1500ms (not a diagnosis)\r\n",currentWrite,processStart,DateTime.UtcNow);
        Check(pendingTrace.Sequence==101&&pendingTrace.PendingGpuCheckpoint,"A fresh pending-GPU snapshot is available to stall policy",results);
        var staleTrace=AutoCapture.ParsePerformanceTrace("Performance.log","FGTRACE seq=101 SNAPSHOT pending GPU checkpoint older than 1500ms (not a diagnosis)\r\n",processStart.AddMinutes(-1),processStart,DateTime.UtcNow);
        Check(staleTrace.Sequence==-1&&!staleTrace.PendingGpuCheckpoint,"A stale configured log cannot drive automatic hang detection",results);
        Check(Collector.IsDeviceFailureEvidence("FGTRACE seq=7 completed=18446744073709551615"),"Decimal device-removal fence sentinel recognised",results);
        Check(Collector.IsDeviceFailureEvidence("completed=0xffffffffffffffff"),"Hex device-removal fence sentinel recognised",results);
        Check(!Collector.IsDeviceFailureEvidence("completed=18446744073709551614"),"Ordinary fence value is not device removal",results);
        Check(!Collector.IsDeviceFailureEvidence("value=18446744073709551615"),"Requested fence token is not a completion failure",results);
        Check(Collector.ClassifyLogProvenance("",0,"FlightSimulator2024.exe",2236,processStart,currentWrite).StartsWith("EMPTY:"),"Empty Performance.log is missing evidence, not a current runtime failure",results);
        Check(Collector.ClassifyLogProvenance("Initializing ReShade into 'C:\\Games\\GameLaunchHelper.exe' [17040]",2533,"FlightSimulator2024.exe",2236,processStart,currentWrite).StartsWith("OTHER PROCESS:"),"Launcher ReShade log cannot be attributed to the simulator",results);
        Check(Collector.ClassifyLogProvenance("pid=2236",500,"FlightSimulator2024.exe",2236,processStart,processStart.AddMinutes(-10)).StartsWith("PRE-SESSION:"),"Matching/reused PID cannot override pre-session log timestamp",results);
        Check(Collector.ClassifyLogProvenance("pid=2236",500,"FlightSimulator2024.exe",2236,processStart,currentWrite).StartsWith("PID ONLY:"),"PID without process birth is not claimed as a verified current session",results);
        Check(Collector.ClassifyLogProvenance("pid=2236\npid=44140",500,"FlightSimulator2024.exe",2236,processStart,currentWrite).StartsWith("MIXED/UNMATCHED:"),"Mixed session log requires per-session inspection",results);
        Check(Collector.ClassifyLogProvenance("[2236] ReShade initialized",500,"FlightSimulator2024.exe",2236,processStart,currentWrite).StartsWith("UNMATCHED:"),"ReShade thread ID is not mistaken for a process ID",results);
string game=Path.Combine(root,"fixture-game");Directory.CreateDirectory(game);
        string actual=Path.Combine(root,"XboxGames","MSFS2024","Content");Directory.CreateDirectory(actual);
        File.WriteAllText(Path.Combine(actual,"FlightSimulator2024.exe"),"");
        string store=Path.Combine(root,"WindowsApps","Microsoft.Limitless_fixture");Directory.CreateDirectory(Path.GetDirectoryName(store));
        if(!Directory.Exists(store)) {
            var junction=Process.Start(new ProcessStartInfo("cmd.exe","/d /c mklink /J \""+store+"\" \""+actual+"\""){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true});
            junction.StandardOutput.ReadToEnd();junction.WaitForExit();Check(junction.ExitCode==0,"Store junction fixture created",results);junction.Dispose();
        }
        var locations=Collector.ResolveGameFolders(new[]{store,actual,actual.ToUpperInvariant()});
        Check(locations.Length==1 && String.Equals(locations[0],Path.GetFullPath(actual),StringComparison.OrdinalIgnoreCase),"Store alias resolves to actual Content folder and deduplicates",results);
        string unresolved=Path.Combine(root,"WindowsApps","Microsoft.Limitless_unresolved");Directory.CreateDirectory(unresolved);File.WriteAllText(Path.Combine(unresolved,"FlightSimulator2024.exe"),"");
        Check(String.Equals(Collector.ResolveGameFolder(unresolved),Path.GetFullPath(unresolved),StringComparison.OrdinalIgnoreCase),"Readable WindowsApps package with simulator executable is offered for read-only diagnostics",results);
        Check(String.Equals(Collector.ResolveGameFolder(Path.GetDirectoryName(actual)),actual,StringComparison.OrdinalIgnoreCase),"Xbox parent resolves to Content",results);
        string other=Path.Combine(root,"second-install");Directory.CreateDirectory(other);File.WriteAllText(Path.Combine(other,"FlightSimulator2024.exe"),"");
        Check(Collector.ResolveGameFolders(new[]{actual,other}).Length==2,"Distinct installations remain separate",results);
        Check(Collector.SameGameExecutable(Path.Combine(store,"FlightSimulator2024.exe"),Path.Combine(actual,"FlightSimulator2024.exe")),"Live capture accepts resolved alias of selected installation",results);
        Check(!Collector.SameGameExecutable(Path.Combine(other,"FlightSimulator2024.exe"),Path.Combine(actual,"FlightSimulator2024.exe")),"Live capture rejects different installation",results);
        string generic=Path.Combine(root,"generic-game");Directory.CreateDirectory(generic);string genericExe=Path.Combine(generic,"SampleGame-Win64-Shipping.exe");File.WriteAllText(genericExe,"");
        Check(Collector.Identity(generic)==Path.GetFileName(genericExe),"Generic game executable is recognized for diagnostics",results);
        Check(String.Equals(Collector.ResolveGameFolder(generic),Path.GetFullPath(generic),StringComparison.OrdinalIgnoreCase),"Generic game directory is accepted",results);
        string ambiguous=Path.Combine(root,"generic-multi-exe");Directory.CreateDirectory(ambiguous);File.WriteAllText(Path.Combine(ambiguous,"Game.exe"),"");File.WriteAllText(Path.Combine(ambiguous,"Launcher.exe"),"");
        Check(Collector.Identity(ambiguous)=="Game.exe" && Collector.ResolveGameFolder(ambiguous,Path.Combine(ambiguous,"Game.exe"))==Path.GetFullPath(ambiguous),"Generic game selection accepts explicit executable in a multi-EXE directory",results);
        string priorDiagnostics=Environment.GetEnvironmentVariable("OPTISHADE_DIAGNOSTICS_DIR");Environment.SetEnvironmentVariable("OPTISHADE_DIAGNOSTICS_DIR",Path.Combine(root,"private-reports"));
        Check(DiagnosticsLocation.Root==Path.GetFullPath(Path.Combine(root,"private-reports")),"Diagnostic output follows the manager app-data setting",results);Environment.SetEnvironmentVariable("OPTISHADE_DIAGNOSTICS_DIR",priorDiagnostics);
        string privatePath=Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)+@"\Private\test.txt";
        string redacted=Collector.Redact(privatePath+"\n"+privatePath.Replace(@"\",@"\\")+"\nname@example.test\napi_key=private-token\nAuthorization: Bearer abc.def",game);
        Check(!redacted.Contains(privatePath)&&!redacted.Contains("example.test")&&!redacted.Contains("private-token")&&!redacted.Contains("abc.def"),"Common secrets/user paths redacted",results);
        string utf=Path.Combine(root,"utf16.log");File.WriteAllText(utf,"first line\n"+new string('x',10000)+"\nLAST_MARKER",Encoding.Unicode);
        Check(Collector.ReadWindow(utf,1024,false).Contains("LAST_MARKER"),"UTF16 tail decoded correctly",results);
        byte[] bytes=new byte[250000];new Random(125).NextBytes(bytes);
        var list=new List<Item>{new Item("REPORT.txt","essential",-1),new Item("logs/random.txt",Convert.ToBase64String(bytes),3)};
        string zip=Path.Combine(root,"budget-"+Guid.NewGuid().ToString("N")+".zip");
        Collector.Pack(list,zip,50000,CancellationToken.None);
        using(var z=ZipFile.OpenRead(zip)) {
            Check(new FileInfo(zip).Length<=50000 && z.GetEntry("REPORT.txt")!=null,"ZIP respects cap and retains essential report",results);
            using(var reader=new StreamReader(z.GetEntry("size-budget.txt").Open())) Check(reader.ReadToEnd().Contains("Reduced"),"Truncation explicitly recorded",results);
        }
        string fixture=Path.Combine(root,"fixture.dmp");File.WriteAllBytes(fixture,bytes.Take(513).ToArray());
        var full=new StringWriter();Collector.WriteMemory(fixture,513,full,CancellationToken.None);
        string[] lines=full.ToString().Split('\n');var roundtrip=new List<byte>();
        foreach(string line in lines) if(System.Text.RegularExpressions.Regex.IsMatch(line,@"^[0-9A-F]{16} \| ")) {
            string segment=line.Split('|')[1];
            foreach(string b in segment.Split(new[]{' '},StringSplitOptions.RemoveEmptyEntries)) roundtrip.Add(Convert.ToByte(b,16));
        }
        Check(roundtrip.SequenceEqual(bytes.Take(513)),"Full dump byte export lossless including partial final row",results);
        string malformed=OptiShade.Diagnostics.DumpSummary.Analyze(fixture);
        Check(malformed.Length>0 && !malformed.Contains("Exception code:"),"Malformed dump handled without invented exception",results);
        string identityDump=Path.Combine(root,"identity.dmp");DateTime dumpProcessStart=new DateTime(2026,10,22,12,34,56,DateTimeKind.Utc);uint dumpProcessStartSeconds=(uint)(dumpProcessStart-new DateTime(1970,1,1,0,0,0,DateTimeKind.Utc)).TotalSeconds;
        WriteIdentityDump(identityDump,3,5092,dumpProcessStartSeconds);
        string identitySummary=OptiShade.Diagnostics.DumpSummary.Analyze(identityDump);
        Check(identitySummary.Contains("Dump process ID: 5092"),"MINIDUMP_MISC_INFO process ID is extracted when its validity flag is set",results);
        Check(identitySummary.Contains("Dump process start UTC: "+dumpProcessStart.ToString("o"))&&identitySummary.Contains("processBirthFileTime="+dumpProcessStart.ToFileTimeUtc()),"MINIDUMP_MISC_INFO process start correlates exactly with LastSession FILETIME",results);
        var parsedDumpIdentity=OptiShade.Diagnostics.DumpSummary.ReadProcessIdentity(identityDump);
        Check(parsedDumpIdentity.HasProcessId&&parsedDumpIdentity.ProcessId==5092&&parsedDumpIdentity.HasProcessStartTime&&parsedDumpIdentity.ProcessBirthFileTime==dumpProcessStart.ToFileTimeUtc(),"Structured dump identity exposes the exact PID and process-birth FILETIME for association",results);
        Check(Collector.ClassifyCrashDumpProcessIdentity(parsedDumpIdentity,5092,dumpProcessStart.ToFileTimeUtc(),"selected installation LastSession").StartsWith("MATCHED:"),"Crash dump process identity matches at minidump timestamp resolution",results);
        Check(Collector.ClassifyCrashDumpProcessIdentity(parsedDumpIdentity,5092,dumpProcessStart.AddMilliseconds(999).ToFileTimeUtc(),"selected installation LastSession").StartsWith("MATCHED:"),"Sub-second FILETIME precision does not misclassify the same minidump process start second",results);
        Check(Collector.ClassifyCrashDumpProcessIdentity(parsedDumpIdentity,5092,dumpProcessStart.AddSeconds(1).ToFileTimeUtc(),"selected installation LastSession").StartsWith("DIFFERENT PROCESS INSTANCE:"),"PID reuse with a different birth time is not treated as the selected game session",results);
        Check(Collector.ClassifyCrashDumpProcessIdentity(parsedDumpIdentity,6000,dumpProcessStart.ToFileTimeUtc(),"live selected game process").StartsWith("DIFFERENT PROCESS INSTANCE:"),"A different dump PID is not attributed to the live selected game process",results);
        string noIdentityDump=Path.Combine(root,"no-identity.dmp");WriteIdentityDump(noIdentityDump,0,5092,dumpProcessStartSeconds);
        string noIdentitySummary=OptiShade.Diagnostics.DumpSummary.Analyze(noIdentityDump);
        Check(noIdentitySummary.Contains("Dump process ID: unavailable")&&noIdentitySummary.Contains("Dump process start time: unavailable")&&!noIdentitySummary.Contains("Dump process ID: 5092"),"Unset MINIDUMP_MISC_INFO flags never produce guessed process identity",results);
        var missingDumpIdentity=OptiShade.Diagnostics.DumpSummary.ReadProcessIdentity(noIdentityDump);
        Check(!missingDumpIdentity.HasProcessId&&!missingDumpIdentity.HasProcessStartTime&&Collector.ClassifyCrashDumpProcessIdentity(missingDumpIdentity,5092,dumpProcessStart.ToFileTimeUtc(),"selected installation LastSession").StartsWith("UNVERIFIED:"),"Missing dump identity remains explicitly unverified instead of inferred by executable name",results);
        string pidOnlyDump=Path.Combine(root,"pid-only.dmp");WriteIdentityDump(pidOnlyDump,1,5092,dumpProcessStartSeconds);
        var pidOnlyIdentity=OptiShade.Diagnostics.DumpSummary.ReadProcessIdentity(pidOnlyDump);
        Check(pidOnlyIdentity.HasProcessId&&!pidOnlyIdentity.HasProcessStartTime&&Collector.ClassifyCrashDumpProcessIdentity(pidOnlyIdentity,5092,dumpProcessStart.ToFileTimeUtc(),"selected installation LastSession").StartsWith("UNVERIFIED:"),"A matching PID without dump process-birth identity is still unverified",results);
        string birthOnlyDump=Path.Combine(root,"birth-only.dmp");WriteIdentityDump(birthOnlyDump,2,5092,dumpProcessStartSeconds);
        var birthOnlyIdentity=OptiShade.Diagnostics.DumpSummary.ReadProcessIdentity(birthOnlyDump);
        Check(!birthOnlyIdentity.HasProcessId&&birthOnlyIdentity.HasProcessStartTime&&Collector.ClassifyCrashDumpProcessIdentity(birthOnlyIdentity,5092,dumpProcessStart.ToFileTimeUtc(),"selected installation LastSession").StartsWith("UNVERIFIED:"),"A matching process-birth time without dump PID is still unverified",results);
        Check(Collector.ClassifyCrashDumpProcessIdentity(parsedDumpIdentity,0,0,"selected game").StartsWith("UNVERIFIED:"),"No selected session identity prevents crash attribution",results);
        string truncatedIdentityDump=Path.Combine(root,"truncated-identity.dmp");WriteIdentityDump(truncatedIdentityDump,3,5092,dumpProcessStartSeconds,8);
        string truncatedIdentitySummary=OptiShade.Diagnostics.DumpSummary.Analyze(truncatedIdentityDump);
        Check(truncatedIdentitySummary.Contains("Analysis status: incomplete/unavailable")&&!truncatedIdentitySummary.Contains("Dump process ID: 5092"),"Truncated MINIDUMP_MISC_INFO is reported as incomplete without partial identity claims",results);
        var cancelled=new CancellationTokenSource();cancelled.Cancel();bool stopped=false;
        try{Collector.Pack(new List<Item>{new Item("REPORT.txt","core",-1)},Path.Combine(root,"cancelled.zip"),50000,cancelled.Token);}catch(OperationCanceledException){stopped=true;}
        Check(stopped && Directory.GetFiles(root,"*.partial").Length==0,"Cancelled dump export leaves no partial file",results);
        string memoryZip=Path.Combine(root,"memory-"+Guid.NewGuid().ToString("N")+".zip");
        Collector.Pack(new List<Item>{new Item("REPORT.txt","core",-1),new Item("memory.txt","",4){DumpPath=fixture,DumpBytes=513}},memoryZip,50000,CancellationToken.None);
        using(var archive=ZipFile.OpenRead(memoryZip))using(var reader=new StreamReader(archive.GetEntry("memory.txt").Open())) {
            string packed=reader.ReadToEnd();Check(packed.Contains("FULL BYTE EXPORT")&&packed.Contains("Bytes actually exported: 513; omitted: 0"),"Memory text streams into ZIP",results);
        }
        string largeDump=Path.Combine(root,"large.dmp");File.WriteAllBytes(largeDump,bytes);
        string limited=Path.Combine(root,"limited-"+Guid.NewGuid().ToString("N")+".zip");
        Collector.Pack(new List<Item>{new Item("REPORT.txt","core",-1),new Item("memory.txt","",4){DumpPath=largeDump,DumpBytes=bytes.Length}},limited,20000,CancellationToken.None);
        using(var archive=ZipFile.OpenRead(limited))using(var reader=new StreamReader(archive.GetEntry("memory.txt").Open()))
            Check(new FileInfo(limited).Length<=20000&&reader.ReadToEnd().Contains("INCOMPLETE"),"Memory cap preserves ZIP limit and labels omissions",results);
        string bounded=Path.Combine(root,"bounded.partial");bool capped=false;
        using(var output=new CappedFileStream(bounded,100)) {output.Write(bytes,0,80);try{output.Write(bytes,0,30);}catch(ZipBudgetExceeded){capped=true;}}
        Check(capped&&new FileInfo(bounded).Length==80,"Temporary ZIP writes cannot exceed hard cap",results);File.Delete(bounded);
        var oldStatus=new Dictionary<string,object>{{"pid",46128},{"processBirth",134354946825341558L}};
        var selected=new Dictionary<string,object>{{"pid",5092},{"processBirth",134359700190596577L}};
        Check(!Collector.SameMfgSession(oldStatus,selected)&&Collector.SameMfgSession(selected,selected),"Historical MFG status cannot masquerade as selected session",results);
        oldStatus["pid"]=5092;Check(!Collector.SameMfgSession(oldStatus,selected),"Reused PID requires matching process birth",results);
        var lastSession=new Dictionary<string,object>{{"PID","5092"},{"ProcessBirthFileTime","134359700190596577"}};
        var providerStatus=new Dictionary<string,object>{{"pid",5092L},{"processBirth",134359700190596577L}};
        Check(Collector.SameMfgSession(providerStatus,lastSession),"Legacy MFG status matches LastSession using PID and process birth",results);
        lastSession["ProcessBirthFileTime"]="134359700190596578";
        Check(!Collector.SameMfgSession(providerStatus,lastSession),"LastSession PID match without matching process birth is rejected",results);
        string mfgFixture=Path.Combine(root,"mfg-interval-"+Guid.NewGuid().ToString("N"));string mfgGame=Path.Combine(mfgFixture,"game");string mfgTemp=Path.Combine(mfgFixture,"temp");
        Directory.CreateDirectory(Path.Combine(mfgGame,"OptiShadeData","MFG"));Directory.CreateDirectory(mfgTemp);
        string tracePath=null;
        try {
            using(Process current=Process.GetCurrentProcess()) {
                uint pid=(uint)current.Id;DateTime processBirth=current.StartTime.ToUniversalTime();long birth=processBirth.ToFileTimeUtc();DateTime epoch=new DateTime(1970,1,1,0,0,0,DateTimeKind.Utc);long heartbeat=Math.Max((DateTime.UtcNow.Ticks-epoch.Ticks)/TimeSpan.TicksPerSecond,(long)(processBirth.AddSeconds(3).Ticks-epoch.Ticks)/TimeSpan.TicksPerSecond);
                tracePath=Path.Combine(mfgTemp,"MfgUnlock-intervals-"+pid+".csv");File.WriteAllText(tracePath,"# fixture\r\ninterval-sequence-sentinel\r\n");
                string previousTracePath=Path.Combine(mfgTemp,"MfgUnlock-intervals-"+pid+".previous.csv");File.WriteAllText(previousTracePath,"# fixture\r\nprevious-interval-sentinel\r\n");
                Check(Collector.IsSessionBoundMfgIntervalTrace(tracePath,pid,birth,heartbeat,DateTime.UtcNow,24),"Current MFG interval trace passes PID/birth/time bounds",results);
                Check(Collector.IsSessionBoundMfgIntervalTrace(previousTracePath,pid,birth,heartbeat,DateTime.UtcNow,24),"Previous bounded MFG interval trace passes PID/birth/time bounds",results);
                Check(!Collector.IsSessionBoundMfgIntervalTrace(tracePath,pid+1,birth,heartbeat,DateTime.UtcNow,24),"MFG interval trace with a different PID is rejected",results);
                string receipt="{\"product\":\"OptiShadeMFG\",\"abi\":131072,\"pid\":"+pid+",\"processBirth\":"+birth+",\"heartbeat\":"+heartbeat+"}";
                File.WriteAllText(Path.Combine(mfgGame,"OptiShadeData","MFG","session.json"),receipt);
                var request=new Request{Game=mfgGame,Hours=24};var collector=new Collector(request,s=>{},CancellationToken.None);
                var flags=BindingFlags.NonPublic|BindingFlags.Instance;
                typeof(Collector).GetField("exe",flags).SetValue(collector,"FixtureGame.exe");
                typeof(Collector).GetField("mfgTempDirectory",flags).SetValue(collector,mfgTemp);
                typeof(Collector).GetMethod("MfgLogs",flags).Invoke(collector,null);
                var captured=(List<Item>)typeof(Collector).GetField("items",flags).GetValue(collector);
                Check(captured.Any(i=>i.Name=="providers/MfgUnlock-intervals-selected-session.csv"&&i.Text.Contains("interval-sequence-sentinel")),"Troubleshooter packages the selected session MFG interval trace",results);
                Check(captured.Any(i=>i.Name=="providers/MfgUnlock-intervals-previous-selected-session.csv"&&i.Text.Contains("previous-interval-sentinel")),"Troubleshooter packages the previous bounded MFG interval trace",results);
            }
        } finally { if(Directory.Exists(mfgFixture))Directory.Delete(mfgFixture,true); }
        File.WriteAllText(Path.Combine(root,"self-test-results.txt"),String.Join("\r\n",results));
    }
    static List<string> MfgNativeLogChecks() {
        var results=new List<string>();
        string nativeMfg=Collector.NativeMfgLogAssessment(new[]{new KeyValuePair<string,string>("Performance.1.log","[info] Multi-frame supported, max generated frames 5 (SL Plugin supports 5, NGX feature supports 5)\n[info] DLSS-G GetState max generated frames: 5")});
        Check(nativeMfg.Contains("Native game Streamline DLSS-G capability evidence"),"Troubleshooter identifies native Streamline capability evidence",results);
        Check(nativeMfg.Contains("A reported maximum shows provider capability only"),"Troubleshooter does not overstate capability as generated output",results);
        Check(nativeMfg.Contains("Performance.1.log"),"Troubleshooter names the capability log source",results);
        Check(Collector.NativeMfgLogAssessment(new[]{new KeyValuePair<string,string>("Performance.log","ordinary startup complete")}).Contains("does not establish that the game lacks a provider"),"Missing native provider lines are reported as unknown, not as provider absence",results);
        return results;
    }
}
}
