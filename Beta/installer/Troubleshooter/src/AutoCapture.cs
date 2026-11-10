using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Threading;
namespace OptiShade.TesterKit {
public sealed class StallPolicy {
    public const double StartupGraceSeconds=300;
    public const double Msfs2024StartupGraceSeconds=600;
    public const double UnresponsiveThresholdSeconds=120;
    // Testers kill a frozen MSFS within a minute or two; at 300/600 s no freeze
    // report had a stack (OSD-NTNR, OSD-799A). The 10-minute load grace still applies.
    public const double Msfs2024UnresponsiveThresholdSeconds=90;
    public const double TraceStallThresholdSeconds=180;
    public const double Msfs2024TraceStallThresholdSeconds=180;
    public readonly double ActiveStartupGraceSeconds;
    public readonly double ActiveUnresponsiveThresholdSeconds;
    public readonly double ActiveTraceStallThresholdSeconds;
    public double UnresponsiveSince=-1, LastProgress=-1, PendingSince=-1;
    public long Sequence=-1;
    public bool Fired;
    public bool GraceEnded;
    public StallPolicy(double startupGraceSeconds=StartupGraceSeconds,double unresponsiveThresholdSeconds=UnresponsiveThresholdSeconds,double traceStallThresholdSeconds=TraceStallThresholdSeconds) {
        ActiveStartupGraceSeconds=Math.Max(0,startupGraceSeconds);
        ActiveUnresponsiveThresholdSeconds=Math.Max(1,unresponsiveThresholdSeconds);
        ActiveTraceStallThresholdSeconds=Math.Max(1,traceStallThresholdSeconds);
    }
    public static StallPolicy ForExecutable(string executable) {
        bool msfs=String.Equals(Path.GetFileName(executable),"FlightSimulator2024.exe",StringComparison.OrdinalIgnoreCase);
        return msfs?new StallPolicy(Msfs2024StartupGraceSeconds,Msfs2024UnresponsiveThresholdSeconds,Msfs2024TraceStallThresholdSeconds):new StallPolicy();
    }
    public string Observe(double seconds,bool responsive,long sequence,bool pendingGpuCheckpoint=false) {
        bool advanced=sequence>=0 && sequence!=Sequence;
        if(advanced)Sequence=sequence;
        if(Fired)return null;
        if(seconds<ActiveStartupGraceSeconds){if(sequence>=0)LastProgress=seconds;PendingSince=-1;return null;}
        if(!GraceEnded){
            GraceEnded=true;
            UnresponsiveSince=responsive?-1:seconds;
            LastProgress=sequence>=0?seconds:-1;
            PendingSince=pendingGpuCheckpoint?seconds:-1;
            return null;
        }
        if(responsive)UnresponsiveSince=-1;else if(UnresponsiveSince<0)UnresponsiveSince=seconds;
        if(advanced)LastProgress=seconds;
        if(pendingGpuCheckpoint){if(PendingSince<0)PendingSince=seconds;}else PendingSince=-1;
        string grace=(ActiveStartupGraceSeconds/60).ToString("0")+"-minute startup grace";
        string why=UnresponsiveSince>=0 && seconds-UnresponsiveSince>=ActiveUnresponsiveThresholdSeconds?"Window unresponsive for at least "+ActiveUnresponsiveThresholdSeconds.ToString("0")+" seconds after the "+grace:
            PendingSince>=0 && seconds-PendingSince>=ActiveTraceStallThresholdSeconds?"A current-session GPU checkpoint remained pending for at least "+ActiveTraceStallThresholdSeconds.ToString("0")+" seconds after the "+grace:null;
        if(why!=null)Fired=true;
        return why;
    }
}
public static class AutoCapture {
    // Automatic sending defaults on as requested. An explicit versioned opt-out
    // is persisted; malformed or linked preference files still fail closed.
    static string UploadPreferencePath {
        get {
            string root=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"OptiShade","Settings");
            return Path.Combine(root,"AutoHangUpload.txt");
        }
    }
    public static bool AutomaticUploadEnabled {
        get { return ReadAutomaticUploadPreference(UploadPreferencePath); }
        set { WriteAutomaticUploadPreference(UploadPreferencePath,value); }
    }
    public static bool ReadAutomaticUploadPreference(string path) {
        try {
            string root=Path.GetDirectoryName(Path.GetFullPath(path));
            if(Directory.Exists(root)&&(File.GetAttributes(root)&FileAttributes.ReparsePoint)!=0)return false;
            if(!File.Exists(path))return true;
            if((File.GetAttributes(path)&FileAttributes.ReparsePoint)!=0)return false;
            string value=File.ReadAllText(path).Trim();
            return String.Equals(value,"enabled-v1",StringComparison.Ordinal)||String.Equals(value,"enabled-v2",StringComparison.Ordinal);
        } catch { return false; }
    }
    public static void WriteAutomaticUploadPreference(string path,bool enabled) {
        path=Path.GetFullPath(path);string root=Path.GetDirectoryName(path);
        Directory.CreateDirectory(root);
        if((File.GetAttributes(root)&FileAttributes.ReparsePoint)!=0)throw new IOException("The OptiShade settings folder is a link; automatic hang upload preference was not changed.");
        string temp=path+"."+Guid.NewGuid().ToString("N")+".tmp";
        File.WriteAllText(temp,enabled?"enabled-v2\r\n":"disabled-v2\r\n",new UTF8Encoding(false));
        if(File.Exists(path)) {
            if((File.GetAttributes(path)&FileAttributes.ReparsePoint)!=0){File.Delete(temp);throw new IOException("The automatic hang upload preference is a link; it was not changed.");}
            File.Replace(temp,path,null);
        } else File.Move(temp,path);
    }
    public sealed class TraceObservation {
        public string Path="";
        public string State="unavailable";
        public long Sequence=-1;
        public bool PendingGpuCheckpoint;
    }
    public static bool IsFreshPerformanceLog(DateTime lastWriteUtc,DateTime processStartUtc,DateTime nowUtc) {
        return lastWriteUtc>=processStartUtc.AddSeconds(-30) && lastWriteUtc<=nowUtc.AddMinutes(2) && nowUtc-lastWriteUtc<=TimeSpan.FromSeconds(30);
    }
    public static TraceObservation ParsePerformanceTrace(string path,string text,DateTime lastWriteUtc,DateTime processStartUtc,DateTime nowUtc) {
        var result=new TraceObservation{Path=path};
        if(!IsFreshPerformanceLog(lastWriteUtc,processStartUtc,nowUtc)){result.State="stale or not recently written for this process";return result;}
        result.State="current-session log";
        foreach(Match m in Regex.Matches(text??"",@"FGTRACE seq=(\d+)")){
            long sequence;if(Int64.TryParse(m.Groups[1].Value,out sequence))result.Sequence=Math.Max(result.Sequence,sequence);
        }
        MatchCollection snapshots=Regex.Matches(text??"",@"FGTRACE [^\r\n]*SNAPSHOT [^\r\n]*",RegexOptions.IgnoreCase);
        if(snapshots.Count>0)result.PendingGpuCheckpoint=snapshots[snapshots.Count-1].Value.IndexOf("pending GPU checkpoint",StringComparison.OrdinalIgnoreCase)>=0;
        return result;
    }
    static string PerformanceLogPath(string game) {
        string fallback=Path.Combine(game,"OptiShadeData","Performance.log");
        string ini=Path.Combine(game,"OptiScaler.ini");
        try {
            bool logSection=false;
            foreach(string line in File.ReadAllLines(ini)){
                string trimmed=line.Trim();if(trimmed.StartsWith("[")&&trimmed.EndsWith("]")){logSection=String.Equals(trimmed,"[Log]",StringComparison.OrdinalIgnoreCase);continue;}
                if(!logSection)continue;
                int equals=trimmed.IndexOf('=');if(equals<0||!String.Equals(trimmed.Substring(0,equals).Trim(),"LogFileName",StringComparison.OrdinalIgnoreCase))continue;
                string value=trimmed.Substring(equals+1).Trim().Trim('"');if(String.IsNullOrWhiteSpace(value))return fallback;
                return Path.GetFullPath(Path.IsPathRooted(value)?value:Path.Combine(game,value));
            }
        }catch{}
        return fallback;
    }
    public static TraceObservation ReadCurrentPerformanceTrace(string game,DateTime processStartUtc,DateTime nowUtc) {
        string path=PerformanceLogPath(game);
        try {
            if((File.GetAttributes(path)&FileAttributes.ReparsePoint)!=0)return new TraceObservation{Path=path,State="linked log ignored"};
            var info=new FileInfo(path);if(!info.Exists)return new TraceObservation{Path=path,State="missing"};
            string text=Collector.ReadWindow(path,65536,false);
            return ParsePerformanceTrace(path,text,info.LastWriteTimeUtc,processStartUtc,nowUtc);
        }catch(Exception e){return new TraceObservation{Path=path,State="unavailable: "+e.GetType().Name};}
    }
    public static string Root(string game) {
        using(var sha=SHA256.Create()) {
            string key=BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(Path.GetFullPath(game).TrimEnd('\\').ToUpperInvariant()))).Replace("-","");
            return Path.Combine(DiagnosticsLocation.Root,"AutoHang",key);
        }
    }
    static bool Plain(string path){return (File.GetAttributes(path)&FileAttributes.ReparsePoint)==0;}
    public static void Prune(string root,string current) {
        // Only our narrowly named, direct children; never follow reparse points.
        // A forced shutdown can bypass cleanup. Workers are bounded to 45 seconds;
        // discard only our abandoned partial captures older than ten minutes.
        foreach(string orphan in Directory.GetFiles(root).Where(f=>Regex.IsMatch(Path.GetFileName(f),@"^session-\d+-\d+-(startup|stall)\.dmp\.capturing(?:\.error\.txt)?$") && Plain(f)))
            if(File.GetLastWriteTimeUtc(orphan)<DateTime.UtcNow.AddMinutes(-10))File.Delete(orphan);
        var files=Directory.GetFiles(root).Where(f=>Regex.IsMatch(Path.GetFileName(f),@"^session-\d+-\d+-(startup|stall)\.(dmp|txt|context\.txt|error\.txt)$") && Plain(f)).OrderByDescending(File.GetLastWriteTimeUtc).ToArray();
        long kept=0;
        foreach(string f in files) {
            long size=new FileInfo(f).Length;
            bool recent=File.GetLastWriteTimeUtc(f)>DateTime.UtcNow.AddDays(-3);
            if(recent && kept+size<=256L*1024*1024){kept+=size;continue;}
            File.Delete(f);
        }
        foreach(string f in Directory.GetFiles(root,"session-*.status.txt").Where(Plain).OrderByDescending(File.GetLastWriteTimeUtc).Skip(6))File.Delete(f);
    }
    public static int Watch(string[] args) {
        int pid=Int32.Parse(args[1]);long birth=Int64.Parse(args[2]);string expected=Path.GetFullPath(args[3]);
        string game=Collector.ResolveGameFolder(Path.GetDirectoryName(expected),expected);
        if(game==null)return 2;
        if(!Collector.SameGameExecutable(expected,Path.Combine(game,Path.GetFileName(expected))))return 2;
        bool created;
        using(var mutex=new Mutex(true,"Local\\OptiShadeAutoHang-"+pid+"-"+birth,out created)) {
            if(!created)return 0;
            string root=Root(game);Directory.CreateDirectory(root);if(!Plain(root))return 3;
            string prefix="session-"+pid+"-"+birth;
            string status=Path.Combine(root,prefix+".status.txt");
            Action<string> note=s=>File.AppendAllText(status,DateTime.UtcNow.ToString("o")+" "+s+Environment.NewLine);
            try {
                using(var process=Process.GetProcessById(pid)) {
                    if(!HangCapture.Matches(process,expected,birth))return 4;
                    Prune(root,prefix);
                    var timer=Stopwatch.StartNew();var policy=StallPolicy.ForExecutable(expected);double lastStatus=0;
                    DateTime processStartUtc=process.StartTime.ToUniversalTime();
                    note("Automatic capture started. PID/birth/executable verified. Startup grace is "+(policy.ActiveStartupGraceSeconds/60).ToString("0")+" minutes; a suspected stall requires "+policy.ActiveUnresponsiveThresholdSeconds.ToString("0")+" seconds of window nonresponse or "+policy.ActiveTraceStallThresholdSeconds.ToString("0")+" seconds of a fresh current-session pending GPU checkpoint after that grace. A frozen sequence, stale log, or progress snapshot cannot trigger a capture. At most one suspected-stall dump. Thread stacks only; not full heap.");
                    while(!process.HasExited) {
                        double now=timer.Elapsed.TotalSeconds;
                        process.Refresh();bool responding=process.Responding;
                        TraceObservation trace=ReadCurrentPerformanceTrace(game,processStartUtc,DateTime.UtcNow);
                        long sequence=trace.Sequence;
                        string reason=policy.Observe(now,responding,sequence,trace.PendingGpuCheckpoint);
                        string kind=reason!=null?"stall":null;
                        if(kind!=null) {
                            string file=Path.Combine(root,prefix+"-"+kind+".dmp");
                            note("Capture "+kind+": "+reason);
                            NoticeState notice=null;
                            if(kind=="stall")notice=CaptureNotice.Begin("Possible game stall detected: "+reason+".\r\nCollecting a diagnostic ZIP automatically. Please leave the game open while capture runs.");
                            var context=new StringBuilder("Capture UTC "+DateTime.UtcNow.ToString("o")+" PID "+pid+" birth "+birth+"\r\n"+reason+"\r\n");
                            context.AppendLine("Performance trace source: "+trace.Path+" ("+trace.State+"); sequence="+trace.Sequence+"; pending GPU checkpoint="+trace.PendingGpuCheckpoint);
                            foreach(string rel in new[]{"OptiShadeData/LastSession.json","OptiShadeData/ReShade.log","OptiShadeData/MFG/session.json"}) {
                                try{context.AppendLine("FILE "+rel+"\r\n"+Collector.ReadWindow(Path.Combine(game,rel),256*1024,false));}
                                catch(Exception e){context.AppendLine(rel+": unavailable "+e.GetType().Name);}
                            }
                            try{if(File.Exists(trace.Path))context.AppendLine("FILE configured Performance.log\r\n"+Collector.ReadWindow(trace.Path,256*1024,false));}catch(Exception e){context.AppendLine("Configured Performance.log: unavailable "+e.GetType().Name);}
                            File.WriteAllText(Path.ChangeExtension(file,"context.txt"),Collector.Redact(context.ToString(),game));
                            try {
                                if(new DriveInfo(Path.GetPathRoot(root)).AvailableFreeSpace<384L*1024*1024)throw new IOException("Insufficient disk space for bounded capture");
                                HangCapture.Capture(process,expected,file+".capturing",CancellationToken.None,s=>{if(notice!=null)notice.Update("Possible game stall detected.\r\n"+s);});
                                File.Move(file+".capturing",file);
                                File.WriteAllText(Path.ChangeExtension(file,"txt"),"PID "+pid+" birth "+birth+" UTC "+DateTime.UtcNow.ToString("o")+"\r\n"+reason+"\r\n"+OptiShade.Diagnostics.DumpSummary.Analyze(file));
                                note("Capture completed: "+new FileInfo(file).Length+" bytes");
                            }catch(Exception e){note("Capture failed: "+e.GetType().Name+": "+e.Message);if(File.Exists(file))File.Delete(file);
                                if(File.Exists(file+".capturing"))File.Delete(file+".capturing");
                                if(File.Exists(file+".capturing.error.txt")){File.Move(file+".capturing.error.txt",Path.ChangeExtension(file,"error.txt"));}}
                            Prune(root,prefix);
                            if(kind=="stall") {
                                bool upload=AutomaticUploadEnabled;
                                string pending=upload?PendingReports.NewFolder():null;
                                Result result=null;
                                try {
                                    note("Automatic diagnostic ZIP collection started.");
                                    var request=new Request{Game=game,Output=upload?pending:DiagnosticsLocation.Root,Limit=9000000,Profile="Automatic hang (9 MB cap)",CaptureLive=false,AutomaticReport=true,TargetPid=pid,Notes="Automatically detected POSSIBLE stall: "+reason+". PID "+pid+" birth "+birth+". This may be loading, paused or stalled; not a root-cause diagnosis."};
                                    result=new Collector(request,s=>notice.Update("Collecting a diagnostic ZIP for a possible game stall.\r\n\r\n"+s),CancellationToken.None).Run();
                                    note("Automatic ZIP saved: "+result.Zip+" bytes="+result.Bytes);
                                    if(upload) {
                                        notice.Update("Automatic hang report collected. Sending it privately to OptiShade…\r\n\r\nThe report contains bounded logs and thread-stack evidence, not a full process-memory dump.");
                                        string reportId=new ReportUpload(ReportUpload.DefaultEndpoint,(message,done,total)=>notice.Update("Sending the automatic hang report privately…\r\n\r\n"+message)).Send(result.Zip,CancellationToken.None,"Automatically captured possible game stall; automatic private upload is enabled in this installation's settings.",Path.GetFileNameWithoutExtension(expected)).GetAwaiter().GetResult();
                                        PendingReports.Discard(pending);
                                        note("Automatic hang report uploaded: "+reportId);
                                        notice.Finish("Automatic hang report sent privately to OptiShade.\r\nReport ID: "+reportId+"\r\nNo local ZIP copy was kept after the upload completed.");
                                    } else notice.Finish("Diagnostic ZIP saved with the OptiShade app data:\r\n"+result.Zip+"\r\nAutomatic upload is off. Send it privately to support when ready.");
                                }catch(Exception e){
                                    note((result==null?"Automatic ZIP FAILED: ":"Automatic upload FAILED; local report retained: ")+e.GetType().Name+": "+e.Message);
                                    notice.Finish(result==null?"Possible game stall detected, but the automatic ZIP could not be saved. Open OptiShade Troubleshooter and collect a report, then share it privately with support.":"The automatic hang report was saved but could not be uploaded. It remains on this PC at:\r\n"+result.Zip+"\r\nOpen Troubleshooter and choose Send unsent report when ready.");
                                }
                            }
                        }
                        if(now-lastStatus>=30){note("Observation: responding="+responding+" traceState="+trace.State+" latestTraceSequence="+sequence+" pendingGpuCheckpoint="+trace.PendingGpuCheckpoint);lastStatus=now;}
                        // Status remains bounded even during long flights.
                        if(new FileInfo(status).Length>65536)File.WriteAllText(status,Collector.ReadWindow(status,32768,false));
                        Thread.Sleep(2000);
                    }
                    note("Selected process exited. Saved evidence retained for diagnostics export.");
                }
            }catch(Exception e){note("Monitor stopped: "+e.GetType().Name+": "+e.Message);return 1;}
            return 0;
        }
    }
}
}
