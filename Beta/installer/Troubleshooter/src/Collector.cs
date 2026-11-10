using System;
using System.IO;
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;
using System.Linq;
using System.Collections.Generic;
using System.Diagnostics;
using System.Management;
using System.Security.Cryptography;
using System.Threading;
using System.Web.Script.Serialization;

namespace OptiShade.TesterKit {
sealed class ZipBudgetExceeded : IOException {}
sealed class CappedFileStream : FileStream {
    readonly long cap;
    public CappedFileStream(string path,long limit):base(path,FileMode.CreateNew,FileAccess.ReadWrite,FileShare.Read){cap=limit;}
    public override void Write(byte[] buffer,int offset,int count){if(count>cap-Position)throw new ZipBudgetExceeded();base.Write(buffer,offset,count);}
    public override void WriteByte(byte value){if(Position>=cap)throw new ZipBudgetExceeded();base.WriteByte(value);}
    public override void SetLength(long value){if(value>cap)throw new ZipBudgetExceeded();base.SetLength(value);}
}

public sealed class Request {
    public string Game, Output, Executable="", Notes = "", Profile = "No Nitro";
    public long Limit = 19000000;
    public int Hours = 24;
    public bool Settings = true, Crash = true, CaptureLive = true, AutomaticReport = false;
    public bool IncludeGameLogs = true, IncludeMfgLogs = false, IncludeLauncherLogs = false;
    // Private upload profile: whole logs and whole raw crash/hang dumps instead
    // of the tails and size reductions needed for Discord attachments.
    public bool FullEvidence = false;
    public int TargetPid;
}
public sealed class Result { public string Zip, Report; public long Bytes; }
public sealed class Item {
    public string Name, Text, DumpPath, BinaryPath; public long DumpBytes; public int Priority;
    // A log not written within the lookback window: still sent, but kept out of the
    // findings so a weeks-old file is not reported as the current session.
    public bool Historical;
    public Item(string n, string t, int p) { Name=n; Text=t; Priority=p; }
}
public sealed class Collector {
    public const string Version = "0.2.34";
    // Sent reports: below the relay's 2.2 GB (44 x 50 MB) report limit.
    public const long MaxSentReportBytes = 2000000000;
    readonly Request r;
    readonly Action<string> progress;
    readonly CancellationToken cancel;
    readonly List<Item> items = new List<Item>();
    readonly StringBuilder ledger = new StringBuilder();
    readonly List<string> historical = new List<string>();
    readonly StringBuilder findings = new StringBuilder();
    readonly StringBuilder logProvenance = new StringBuilder();
    int selectedLogPid;
    DateTime? selectedLogStartUtc;
    string exe, exePath;
    string mfgTempDirectory;
    bool checkOnly;
    public Collector(Request request, Action<string> status, CancellationToken token) { r=request; progress=status; cancel=token; mfgTempDirectory=Path.GetTempPath(); }
    public static string GameFileToken(string executable) {
        string value=Path.GetFileNameWithoutExtension(executable??"");
        value=Regex.Replace(value,@"[^A-Za-z0-9]+","-").Trim('-');
        if(value.Length==0)return "Unknown-Game";
        return value.Length>48?value.Substring(0,48).TrimEnd('-'):value;
    }
    void Stage(string s) { cancel.ThrowIfCancellationRequested(); progress(s); }
    public static string Identity(string dir) {
        foreach (string n in new[]{"FlightSimulator2024.exe","FlightSimulator.exe","X-Plane.exe"})
            if (File.Exists(Path.Combine(dir,n))) return n;
        string manifest=ManifestExecutable(dir);if(manifest!=null)return Path.GetFileName(manifest);
        try {
            var excluded=new Regex(@"(?i)^(?:setup|install|uninstall|unins\w*|launcher|updater|patcher|crashreporter|crashhandler|reporter|benchmark|steam|epicgameslauncher|eaapp|origin|uplay|battle\.net|easyanticheat|start_protected_game)(?:[-_].*)?\.exe$");
            var candidates=Directory.GetFiles(dir,"*.exe",SearchOption.TopDirectoryOnly).Where(p=>!excluded.IsMatch(Path.GetFileName(p))).OrderByDescending(p=>new FileInfo(p).Length).ThenBy(p=>p,StringComparer.OrdinalIgnoreCase).Take(2).ToArray();
            return candidates.Length==1?Path.GetFileName(candidates[0]):null;
        } catch {return null;}
    }
    static string StoreRoot {get {string configured=Environment.GetEnvironmentVariable("OPTISHADE_STORE");return String.IsNullOrWhiteSpace(configured)?Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"OptiShade"):Path.GetFullPath(configured);}}
    static string ManifestExecutable(string dir) {
        try {
            string target=Path.GetFullPath(dir).TrimEnd('\\','/');string root=Path.Combine(StoreRoot,"Games");if(!Directory.Exists(root))return null;
            foreach(string folder in Directory.GetDirectories(root).Take(100)) {
                string file=Path.Combine(folder,"manifest.json");if(!File.Exists(file)||new FileInfo(file).Length>4000000)continue;
                var map=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(File.ReadAllText(file));object game,launch;
                if(!map.TryGetValue("Game",out game)||!(game is string)||!map.TryGetValue("LaunchExe",out launch)||!(launch is string))continue;
                if(!String.Equals(Path.GetFullPath((string)game).TrimEnd('\\','/'),target,StringComparison.OrdinalIgnoreCase))continue;
                string executable=Path.GetFullPath((string)launch);string prefix=target+Path.DirectorySeparatorChar;
                if(executable.StartsWith(prefix,StringComparison.OrdinalIgnoreCase)&&File.Exists(executable))return executable;
            }
        }catch{}return null;
    }
    public static string ExecutablePath(string dir,string identity) {
        string manifest=ManifestExecutable(dir);if(manifest!=null&&String.Equals(Path.GetFileName(manifest),identity,StringComparison.OrdinalIgnoreCase))return manifest;
        if(String.IsNullOrWhiteSpace(identity))return null;
        string direct=Path.Combine(dir,identity);return File.Exists(direct)?direct:null;
    }
    [System.Runtime.InteropServices.DllImport("kernel32.dll",CharSet=System.Runtime.InteropServices.CharSet.Unicode,SetLastError=true)]
    static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFile(string name,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template);
    [System.Runtime.InteropServices.DllImport("kernel32.dll",CharSet=System.Runtime.InteropServices.CharSet.Unicode,SetLastError=true)]
    static extern uint GetFinalPathNameByHandle(Microsoft.Win32.SafeHandles.SafeFileHandle file,StringBuilder path,uint length,uint flags);
    // Read-only directory handle: resolve Store/Xbox aliases without changing permissions.
    public static string ResolveGameFolder(string directory,string executable=null) {
        if(String.IsNullOrWhiteSpace(directory))return null;
        try {
            string path=Path.GetFullPath(directory).TrimEnd('\\','/');
            using(var handle=CreateFile(path,0,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero)) {
                if(!handle.IsInvalid) {
                    var resolved=new StringBuilder(32768);
                    uint count=GetFinalPathNameByHandle(handle,resolved,(uint)resolved.Capacity,0);
                    if(count>0 && count<resolved.Capacity) {
                        path=resolved.ToString();
                        if(path.StartsWith(@"\\?\UNC\",StringComparison.OrdinalIgnoreCase))path=@"\\"+path.Substring(8);
                        else if(path.StartsWith(@"\\?\",StringComparison.OrdinalIgnoreCase))path=path.Substring(4);
                    }
                }
            }
            // Diagnostics is read-only: a verified executable in a Store package is
            // valid evidence even when the Xbox alias resolves into WindowsApps.
            // Do not infer access to an entire package from its directory name.
            if(Identity(path)!=null)return path;
            if(!String.IsNullOrWhiteSpace(executable)) {
                string expected=Path.GetFullPath(executable);string prefix=path+Path.DirectorySeparatorChar;
                if(expected.StartsWith(prefix,StringComparison.OrdinalIgnoreCase)&&File.Exists(expected))return path;
                string inFolder=Path.Combine(path,Path.GetFileName(executable));if(File.Exists(inFolder))return path;
            }
            string content=Path.Combine(path,"Content");
            if(Identity(content)!=null)return content;
            if(!String.IsNullOrWhiteSpace(executable)&&File.Exists(Path.Combine(content,Path.GetFileName(executable))))return content;
            return null;
        }catch{return null;}
    }
    public static string[] ResolveGameFolders(IEnumerable<string> candidates) {
        return candidates.Select(p=>ResolveGameFolder(p)).Where(p=>p!=null).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(p=>p,StringComparer.OrdinalIgnoreCase).ToArray();
    }
    public static bool SameGameExecutable(string first,string second) {
        if(!String.Equals(Path.GetFileName(first),Path.GetFileName(second),StringComparison.OrdinalIgnoreCase))return false;
        string a=ResolveGameFolder(Path.GetDirectoryName(first),first),b=ResolveGameFolder(Path.GetDirectoryName(second),second);
        return a!=null && b!=null && String.Equals(a,b,StringComparison.OrdinalIgnoreCase);
    }
    public static string[] Discover() {
        var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        string root=Path.Combine(StoreRoot,"Games");
        if(Directory.Exists(root)) foreach(string d in Directory.GetDirectories(root).Take(100)) {
            try {
                string f=Path.Combine(d,"manifest.json");
                if (!File.Exists(f) || new FileInfo(f).Length>4000000) continue;
                var map=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(File.ReadAllText(f));
                object value; if(map.TryGetValue("Game",out value) && value is string && Identity((string)value)!=null) paths.Add((string)value);
            } catch {}
        }
        foreach(string name in new[]{"FlightSimulator2024","FlightSimulator","X-Plane"})
            foreach(Process p in Process.GetProcessesByName(name)) using(p) {
                try { string d=Path.GetDirectoryName(p.MainModule.FileName); if(Identity(d)!=null) paths.Add(d); } catch {}
            }
        return ResolveGameFolders(paths);
    }
    public static string Redact(string s, string game) {
        foreach(var pair in new[]{
            new[]{game,"<GAME>"},
            new[]{Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),"<USER>"}
        }) if(!String.IsNullOrEmpty(pair[0])) {
            s=Regex.Replace(s,Regex.Escape(pair[0].Replace(@"\",@"\\")),m=>pair[1],RegexOptions.IgnoreCase);
            s=Regex.Replace(s,Regex.Escape(pair[0]),m=>pair[1],RegexOptions.IgnoreCase);
        }
        s=Regex.Replace(s,@"(?i)[A-Z]:\\+Users\\+[^\\/\s""<>]+","<USER>");
        s=Regex.Replace(s,@"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b","<EMAIL>");
        s=Regex.Replace(s,@"(?im)([""']?(?:password|passwd|access_token|refresh_token|authorization|api[_-]?key|secret)[""']?\s*[:=]\s*)[^\r\n]+","$1<REDACTED>");
        s=Regex.Replace(s,@"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+","Bearer <REDACTED>");
        return s;
    }
    void Add(string name, string text, int priority) { items.Add(new Item(name,Redact(text,r.Game),priority)); }
    public static string ReadWindow(string path,int limit,bool head) {
        using(var f=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)) {
            long length=f.Length;
            byte[] bom=new byte[3]; int n=f.Read(bom,0,3);
            Encoding enc=Encoding.UTF8;
            if(n>=2 && bom[0]==255 && bom[1]==254) enc=Encoding.Unicode;
            if(n>=2 && bom[0]==254 && bom[1]==255) enc=Encoding.BigEndianUnicode;
            long offset=head?0:Math.Max(0,length-limit);
            if(enc!=Encoding.UTF8) offset-=offset%2;
            f.Position=offset;
            byte[] data=new byte[(int)Math.Min((long)limit,length-offset)];
            int read=0, chunk; while(read<data.Length && (chunk=f.Read(data,read,data.Length-read))>0) read+=chunk;
            return "Source modified UTC: "+File.GetLastWriteTimeUtc(path).ToString("o")+
                "\r\nOriginal bytes: "+length+"; captured offset: "+offset+"; bytes: "+read+
                (offset>0?" (first line may be partial)":"")+"\r\n\r\n"+enc.GetString(data,0,read);
        }
    }
    void Log(string path,string name,int bytes,int priority,bool head) {
        cancel.ThrowIfCancellationRequested();
        try {
            if(!File.Exists(path)) { ledger.AppendLine(name+": not present"); return; }
            if((File.GetAttributes(path)&FileAttributes.ReparsePoint)!=0) { ledger.AppendLine(name+": linked file skipped");return; }
            if(r.FullEvidence && !head) bytes=Math.Max(bytes,name=="logs/Performance-current.txt"?FullMainLogBytes:FullLogBytes);
            string content=ReadWindow(path,bytes,head);
            Add(name,content,priority);
            if(!name.StartsWith("settings/",StringComparison.Ordinal)&&File.GetLastWriteTimeUtc(path)<DateTime.UtcNow.AddHours(-r.Hours)) {
                items[items.Count-1].Historical=true;
                historical.Add(name+" (modified "+File.GetLastWriteTimeUtc(path).ToString("yyyy-MM-dd")+")");
            }
            ledger.AppendLine(name+": captured "+(head?"head":"tail")+"; maximum bytes "+bytes);
            string provenance="Session identity not established.";
            if(name.StartsWith("logs/",StringComparison.Ordinal) &&
                (String.Equals(Path.GetExtension(path),".log",StringComparison.OrdinalIgnoreCase)||String.Equals(Path.GetFileName(path),"Log.txt",StringComparison.OrdinalIgnoreCase))) {
                var file=new FileInfo(path);
                string identityText=ReadWindow(path,32768,true)+"\n"+(content.Length>65536?content.Substring(content.Length-65536):content);
                provenance=ClassifyLogProvenance(identityText,file.Length,exe,selectedLogPid,selectedLogStartUtc,file.LastWriteTimeUtc);
                logProvenance.AppendLine(name+": "+provenance+" Source bytes="+file.Length+"; modified UTC="+file.LastWriteTimeUtc.ToString("o"));
            }
            if(name=="logs/Performance-current.txt") Analyze(content,provenance);
        } catch(Exception e) { ledger.AppendLine(name+": "+e.GetType().Name+" "+e.Message); }
    }
    // Whole-log windows for the private upload profile; larger files keep their newest bytes.
    const int FullMainLogBytes=192*1024*1024, FullLogBytes=48*1024*1024;
    internal static bool IsDeviceFailureEvidence(string line) {
        return Regex.IsMatch(line,@"(?i)DXGI_ERROR_DEVICE|device[ _-]?removed|0x887a000[567]|\bcompleted\s*=\s*(?:18446744073709551615|0x[fF]{16})(?![0-9a-fA-F])");
    }
    internal static string ClassifyLogProvenance(string text,long bytes,string expectedExe,int selectedPid,DateTime? processStartUtc,DateTime modifiedUtc) {
        if(bytes==0)return "EMPTY: no runtime evidence; do not infer a current failure from this file.";
        var executable=Regex.Match(text,@"(?i)\binto\s+'([^']+\.exe)'");
        if(executable.Success && !String.Equals(Path.GetFileName(executable.Groups[1].Value),Path.GetFileName(expectedExe),StringComparison.OrdinalIgnoreCase))
            return "OTHER PROCESS: log identifies "+Path.GetFileName(executable.Groups[1].Value)+"; selected game is "+expectedExe+".";
        var pids=Regex.Matches(text,@"(?i)\bpid\s*[=:]\s*(\d+)").Cast<Match>().Select(m=>m.Groups[1].Value).Distinct().Take(12).ToArray();
        if(processStartUtc.HasValue && modifiedUtc<processStartUtc.Value.AddSeconds(-2))
            return "PRE-SESSION: file predates the selected process start; historical evidence only.";
        if(pids.Length>1)return "MIXED/UNMATCHED: multiple reported PIDs ("+String.Join(",",pids)+"); inspect individual sessions.";
        if(pids.Length==1 && selectedPid>0 && pids[0]!=selectedPid.ToString())return "OTHER PROCESS: reported PID "+pids[0]+" differs from selected PID "+selectedPid+".";
        if(pids.Length==1 && selectedPid>0)return "PID ONLY: reported PID matches "+selectedPid+"; log process-birth identity is absent/unverified. Not a confirmed current-session failure.";
        return "UNMATCHED: no verified PID/process-birth pair; filename, installed build and modified time do not establish a current session.";
    }
    internal static string ClassifyCrashDumpProcessIdentity(OptiShade.Diagnostics.DumpProcessIdentityInfo dump,uint selectedPid,long selectedBirth,string selectedSource) {
        if(selectedPid==0||selectedBirth<=0)return "UNVERIFIED: selected process PID and birth identity are unavailable; executable name and dump time do not establish this session.";
        if(dump==null||!dump.HasProcessId||!dump.HasProcessStartTime)return "UNVERIFIED: dump lacks a complete embedded PID and process-start pair; selected reference is "+selectedSource+".";
        // MINIDUMP_MISC_INFO stores ProcessCreateTime in whole Unix seconds,
        // while Process.StartTime/LastSession retain FILETIME precision. Compare
        // the shared second after confirming PID, so ordinary sub-second
        // truncation does not mislabel the same process as PID reuse.
        if(dump.ProcessId==selectedPid&&dump.ProcessBirthFileTime/TimeSpan.TicksPerSecond==selectedBirth/TimeSpan.TicksPerSecond)return "MATCHED: dump PID and process-start second match the "+selectedSource+" identity (minidump time is second-resolution).";
        return "DIFFERENT PROCESS INSTANCE: dump PID/process birth do not match the "+selectedSource+" identity; do not attribute this dump to that session.";
    }
    void CaptureLogProcessContext() {
        foreach(Process p in Process.GetProcessesByName(Path.GetFileNameWithoutExtension(exe)))using(p)try {
            if(r.TargetPid>0 && p.Id!=r.TargetPid)continue;
            if(!SameGameExecutable(p.MainModule.FileName,exePath))continue;
            if(selectedLogPid!=0){selectedLogPid=0;selectedLogStartUtc=null;break;}
            DateTime started=p.StartTime.ToUniversalTime();
            selectedLogPid=p.Id;selectedLogStartUtc=started;
        }catch{}
        logProvenance.AppendLine("Captured UTC: "+DateTime.UtcNow.ToString("o")+"; selected executable: "+exePath);
        logProvenance.AppendLine(selectedLogPid>0?"Selected PID="+selectedLogPid+"; start UTC="+selectedLogStartUtc.Value.ToString("o")+"; processBirth="+selectedLogStartUtc.Value.ToFileTimeUtc():"No unique selected live process identity was verified.");
        logProvenance.AppendLine("Installed hashes/build identity describe collection-time files, not proof of the bytes loaded in a historical log. ReShade bracketed numbers are thread IDs, not process IDs.\r\n");
    }
    void Analyze(string text,string provenance) {
        string[] lines=text.Split('\n');
        var timeline=lines.Where(s=>!s.Contains("FGTRACE") && Regex.IsMatch(s,@"(?i)error|warn|device.?removed|NR.*(?:pass|running|pending|commit)|owner|memory|frame.?gen|hud.less|fence")).ToArray();
        Add("analysis/render-timeline.txt","Selected lines from the file named Performance.log. This filename does not establish the current process/session.\r\n"+provenance+"\r\n"+String.Join("\n",timeline.Skip(Math.Max(0,timeline.Length-3000))),0);
        var seq=new SortedDictionary<long,string>();
        foreach(string line in lines) if(line.Contains("FGTRACE")) {
            Match m=Regex.Match(line,@"\bseq=(\d+)"); long key;
            if(m.Success && Int64.TryParse(m.Groups[1].Value,out key)) seq[key]=line;
        }
        Add("analysis/last-trace-sequences.txt","Latest observation per FGTRACE sequence, ordered numerically. Original ordering remains in the log.\r\n"+provenance+"\r\n"+
            (seq.Count==0?"No sequence records captured. Older builds may not emit this instrumentation.":String.Join("\n",seq.Skip(Math.Max(0,seq.Count-2048)).Select(p=>p.Value))),0);
        findings.AppendLine("Performance.log provenance: "+provenance);
        findings.AppendLine("Captured Performance.log text lines (including collector header): "+lines.Length+"; matching timeline lines: "+timeline.Length+"; unique FGTRACE sequences: "+seq.Count);
        findings.AppendLine("Device-failure mentions in captured text (not unique or session-confirmed failures): "+lines.Count(IsDeviceFailureEvidence));
        if(lines.Any(IsDeviceFailureEvidence)) findings.AppendLine("Device-removal text found in the captured file. Match logs/session-provenance.txt and process birth before attributing it to this run. Fence values describe observation time, not necessarily the original event; this does not identify the failing GPU command or driver.");
    }
    void Logs() {
        Stage("Reading the selected diagnostic logs...");
        if(r.IncludeGameLogs) CaptureLogProcessContext();
        string data=Path.Combine(r.Game,"OptiShadeData");
        int tail=r.Limit>49000000?32*1024*1024:r.Limit>19000000?12*1024*1024:6*1024*1024;
        if(r.IncludeGameLogs) {
        Log(Path.Combine(data,"Performance.log"),"logs/Performance-start.txt",256*1024,0,true);
        Log(Path.Combine(data,"Performance.log"),"logs/Performance-current.txt",tail,1,false);
        foreach(string n in new[]{"Performance.1.log","Performance.2.log","Performance.log.first.log"})
            Log(Path.Combine(data,n),"logs/"+n+".txt",tail/2,3,false);
        foreach(string rel in new[]{"glass-cockpit-dlss-fix.log","glass-cockpit-dlss-fix.old.log","glass-cockpit-dlss-fix.ini","ReShade.log","ReShade64.log","OptiScaler.log","Log.txt","dlss5-feed.log","host64/dlss5-feed-host.log","OptiShadeData/ReShade.log","OptiShadeData/OptiScaler.log","OptiShadeData/LastSession.json","OptiShadeData/BuildIdentity.json","OptiShadeData/Compatibility.json","OptiShadeData/NVIDIA-versions.json","OptiShadeData/dependency-state.ini","OptiShadeData/Neural-dependency-status.txt","OptiShadeData/Import-last-error.txt"})
            Log(Path.Combine(r.Game,rel),"logs/"+rel.Replace('/','_')+".txt",2*1024*1024,1,false);
        foreach(string dir in new[]{r.Game,data,Path.Combine(data,"Logs"),Path.Combine(data,"Tools")}) {
            if(!Directory.Exists(dir)) continue;
            try {
                foreach(string f in Directory.GetFiles(dir).Where(f=>Regex.IsMatch(Path.GetFileName(f),@"(?i)^(OptiShadeSensor|HardwareMonitor|Sensors|sensor).*\.(log|json|txt)$") || (r.IncludeMfgLogs && Regex.IsMatch(Path.GetFileName(f),@"(?i)^(RTX(?:20|30|40)?MFG|MfgUnlock|sl\.).*\.(log|json|txt)$"))).OrderByDescending(File.GetLastWriteTimeUtc).Take(16))
                    Log(f,"providers/"+Path.GetFileName(dir)+"_"+Path.GetFileName(f)+".txt",2*1024*1024,2,false);
            } catch(Exception e) {ledger.AppendLine("Provider discovery: "+e.Message);}
        }
        if(r.IncludeGameLogs && r.Settings) foreach(string n in new[]{"OptiScaler.ini","ReShade.ini","OptiShadeData/HardwareMonitor.ini","OptiShadeData/UI-mode.ini","OptiShadeData/XPlane-compatibility.ini"})
            Log(Path.Combine(r.Game,n),"settings/"+n+".txt",256*1024,1,true);
        // The headset runtime has its own config, and each runs the preset it names
        // (OSD-Z4XF: the desktop preset ran on the headset image; neither was captured).
        if(r.IncludeGameLogs && r.Settings) {
            Log(Path.Combine(r.Game,"ReShadeVR.ini"),"settings/ReShadeVR.ini.txt",256*1024,1,true);
            var presets=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            string root=Path.GetFullPath(r.Game).TrimEnd('\\')+"\\";
            foreach(string ini in new[]{"ReShade.ini","ReShadeVR.ini"}) {
                try {
                    string path=Path.Combine(r.Game,ini);
                    if(!File.Exists(path))continue;
                    foreach(Match m in Regex.Matches(File.ReadAllText(path),@"(?m)^\s*(?:Startup)?PresetPath\s*=\s*(.+?)\s*$")) {
                        string rel=m.Groups[1].Value;
                        if(Path.IsPathRooted(rel)||!rel.EndsWith(".ini",StringComparison.OrdinalIgnoreCase))continue;
                        string full=Path.GetFullPath(Path.Combine(r.Game,rel));
                        if(!full.StartsWith(root,StringComparison.OrdinalIgnoreCase)||!presets.Add(full))continue;
                        Log(full,"settings/preset-"+Path.GetFileName(full)+".txt",256*1024,1,true);
                    }
                } catch(Exception e) {ledger.AppendLine("Preset discovery: "+e.Message);}
            }
            // AtmosphereMod (installed from the Components page by its own installer)
            // keeps its record and logs outside the game folder.
            string atmosphere=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"AtmosphereMod");
            if(Directory.Exists(atmosphere)) {
                Log(Path.Combine(atmosphere,"install.json"),"atmospheremod/install.json.txt",64*1024,1,true);
                Log(Path.Combine(atmosphere,"logs","install.log"),"atmospheremod/install.log.txt",1024*1024,1,false);
                Log(Path.Combine(atmosphere,"logs","weather.log"),"atmospheremod/weather.log.txt",2*1024*1024,2,false);
            }
        }
        }
        if(r.IncludeMfgLogs) {
            foreach(string rel in new[]{"OptiShadeData/MFG/session.json","OptiShadeData/MFG/source-build.json","OptiShadeData/MFG/source-backend.json"}) Log(Path.Combine(r.Game,rel),"mfg/"+rel.Replace('/','_'),256*1024,1,false);
            if(!r.IncludeGameLogs) foreach(string dir in new[]{r.Game,Path.Combine(r.Game,"OptiShadeData"),Path.Combine(r.Game,"OptiShadeData","Logs")}) {
                try {
                    if(!Directory.Exists(dir)||(File.GetAttributes(dir)&FileAttributes.ReparsePoint)!=0)continue;
                    foreach(string file in Directory.GetFiles(dir).Where(f=>Regex.IsMatch(Path.GetFileName(f),@"(?i)^(RTX(?:20|30|40)?MFG|MfgUnlock|sl\.).*\.(log|json|txt|csv)$")).OrderByDescending(File.GetLastWriteTimeUtc).Take(12))
                        Log(file,"mfg/game-"+Path.GetFileName(file),2*1024*1024,1,false);
                } catch(Exception e) {ledger.AppendLine("Game MFG log discovery: "+e.GetType().Name);}
            }
            MfgLogs();
            MfgStatusAssessment();
        }
        if(!r.IncludeGameLogs)return;
        NeuralSessionAssessment();
        var simRoots=new List<string>{r.Game};
        if(exe=="FlightSimulator2024.exe" || exe=="FlightSimulator.exe") {
            bool fs24=exe=="FlightSimulator2024.exe";
            simRoots.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),fs24?"Microsoft Flight Simulator 2024":"Microsoft Flight Simulator"));
            string family=fs24?"Microsoft.Limitless_8wekyb3d8bbwe":"Microsoft.FlightSimulator_8wekyb3d8bbwe";
            foreach(string area in new[]{"LocalState","LocalCache"}) simRoots.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Packages",family,area));
        }
        int simIndex=0;
        foreach(string dir in simRoots) {
            simIndex++;
            try {
                if(!Directory.Exists(dir))continue;
                foreach(string f in Directory.GetFiles(dir,"AsoboReport-Crash*.txt").Where(f=>File.GetLastWriteTimeUtc(f)>=DateTime.UtcNow.AddHours(-r.Hours)).OrderByDescending(File.GetLastWriteTimeUtc).Take(3))
                    Log(f,"crashes/simulator-"+simIndex+"-"+Path.GetFileName(f),512*1024,0,false);
                if(r.Settings) Log(Path.Combine(dir,"UserCfg.opt"),"settings/simulator-"+simIndex+"-UserCfg.txt",128*1024,1,false);
            }catch(Exception e){ledger.AppendLine("Simulator text reports: "+e.Message);}
        }
        Add("logs/session-provenance.txt",logProvenance.ToString(),0);
    }
    void LauncherLogs() {
        Stage("Collecting launcher and installer logs...");
        string configured=Environment.GetEnvironmentVariable("OPTISHADE_STORE");
        string root=String.IsNullOrWhiteSpace(configured)?Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"OptiShade"):Path.GetFullPath(configured);
        foreach(var item in new[]{new{File="Installer.log",Cap=1024*1024},new{File="Manager-error.txt",Cap=256*1024},new{File="Update-error.txt",Cap=256*1024}})
            Log(Path.Combine(root,item.File),"launcher/"+item.File,item.Cap,0,false);
        findings.AppendLine("Launcher and installer evidence was requested; available bounded log tails are under launcher/.");
    }
    public static bool SameMfgSession(Dictionary<string,object> status,Dictionary<string,object> session) {
        try {
            ulong statusPid,statusBirth,sessionPid,sessionBirth;
            return TryIdentityNumber(status,new[]{"pid","PID"},out statusPid) && statusPid>0 &&
                TryIdentityNumber(status,new[]{"processBirth","ProcessBirthFileTime","birth"},out statusBirth) && statusBirth>0 &&
                TryIdentityNumber(session,new[]{"pid","PID"},out sessionPid) && sessionPid==statusPid &&
                TryIdentityNumber(session,new[]{"processBirth","ProcessBirthFileTime","birth"},out sessionBirth) && sessionBirth==statusBirth;
        }
        catch {return false;}
    }
    static bool TryIdentityNumber(Dictionary<string,object> map,string[] names,out ulong value) {
        value=0;if(map==null)return false;
        foreach(string name in names) {
            object raw;
            if(!map.TryGetValue(name,out raw)) {
                var pair=map.FirstOrDefault(p=>String.Equals(p.Key,name,StringComparison.OrdinalIgnoreCase));
                if(pair.Key==null)continue;raw=pair.Value;
            }
            try {value=Convert.ToUInt64(raw);return true;}catch {return false;}
        }
        return false;
    }
    public static bool IsSessionBoundMfgIntervalTrace(string path,uint pid,long processBirthFileTime,long heartbeatUnixSeconds,DateTime nowUtc,int lookbackHours) {
        try {
            if(String.IsNullOrWhiteSpace(path)||pid==0||processBirthFileTime<=0||heartbeatUnixSeconds<=0||lookbackHours<1||lookbackHours>168)return false;
            string fileName=Path.GetFileName(path);
            string currentName="MfgUnlock-intervals-"+pid.ToString()+".csv";
            string previousName="MfgUnlock-intervals-"+pid.ToString()+".previous.csv";
            if(!String.Equals(fileName,currentName,StringComparison.OrdinalIgnoreCase)&&!String.Equals(fileName,previousName,StringComparison.OrdinalIgnoreCase))return false;
            var file=new FileInfo(path);if(!file.Exists||(file.Attributes&FileAttributes.ReparsePoint)!=0)return false;
            DateTime birth=DateTime.FromFileTimeUtc(processBirthFileTime);
            DateTime heartbeat=new DateTime(1970,1,1,0,0,0,DateTimeKind.Utc).AddSeconds(heartbeatUnixSeconds);
            nowUtc=nowUtc.ToUniversalTime();
            if(heartbeat<birth.AddSeconds(-2)||heartbeat>nowUtc.AddMinutes(2)||heartbeat<nowUtc.AddHours(-lookbackHours))return false;
            if(file.CreationTimeUtc<birth.AddSeconds(-2)||file.LastWriteTimeUtc<birth.AddSeconds(-2))return false;
            if(file.CreationTimeUtc>heartbeat.AddMinutes(2)||file.LastWriteTimeUtc>heartbeat.AddMinutes(2))return false;
            return true;
        }catch{return false;}
    }
    void MfgStatusAssessment() {
        var output=new StringBuilder("MFG provider assessment. Settings and accepted calls are not proof of generated frames.\r\n");
        try {
            var json=new JavaScriptSerializer();
            string receipt=Path.Combine(r.Game,"OptiShadeData","MFG","session.json");
            Dictionary<string,object> current=null;
            if(File.Exists(receipt)&&new FileInfo(receipt).Length<=16384)current=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(receipt));
            string lastPath=Path.Combine(r.Game,"OptiShadeData","LastSession.json");Dictionary<string,object> last=null;
            if(File.Exists(lastPath)&&new FileInfo(lastPath).Length<=262144)last=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(lastPath));
            output.AppendLine(current==null?"No OptiShade source-backend session receipt was captured; native game Streamline provider evidence is assessed separately below.":"OptiShade source-backend session receipt retained in logs/OptiShadeData_MFG_session.json.txt. This may describe a session that has ended.");
            output.AppendLine(last==null?"No usable LastSession process identity was captured.":"Provider status is also compared with LastSession PID and process birth; a match identifies the process only, not the selected backend or generated output.");
            var nativeLogs=new List<KeyValuePair<string,string>>();
            foreach(string name in new[]{"Performance.log","Performance.1.log","Performance.2.log","Performance.log.first.log"}) {
                string path=Path.Combine(r.Game,"OptiShadeData",name);
                try { if(File.Exists(path)&&new FileInfo(path).Length<=8*1024*1024) nativeLogs.Add(new KeyValuePair<string,string>(name,File.ReadAllText(path))); }
                catch { }
            }
            output.Append(NativeMfgLogAssessment(nativeLogs));
            foreach(string name in new[]{"RTXMFG-Universal.status.json","RTX40MFG-Universal.status.json","bridge_status.json"}) {
                string file=Path.Combine(r.Game,name);if(!File.Exists(file)||new FileInfo(file).Length>262144)continue;
                var status=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(file));
                string identity=current!=null&&SameMfgSession(status,current)?"MATCHES SOURCE-BACKEND SESSION PID AND BIRTH; freshness, active backend and output still require inspection.":last!=null&&SameMfgSession(status,last)?"MATCHES LASTSESSION PID AND BIRTH; this matches the process only and does not prove active backend or generated output.":"UNMATCHED PROCESS IDENTITY; do not attribute this status to the captured game session.";
                output.AppendLine(name+": "+identity+" Modified UTC: "+File.GetLastWriteTimeUtc(file).ToString("o"));
            }
        }catch(Exception e){output.AppendLine("Provider identity assessment unavailable: "+e.GetType().Name);}
        Add("analysis/MFG-provider-assessment.txt",output.ToString(),0);
    }
    public static string NativeMfgLogAssessment(IEnumerable<KeyValuePair<string,string>> logs) {
        var observations=new List<string>();
        if(logs!=null) foreach(var file in logs) {
            if(file.Value==null)continue;
            foreach(string line in file.Value.Split('\n')) {
                string trimmed=line.Trim();
                if(trimmed.Length==0||trimmed.Length>2048)continue;
                if(Regex.IsMatch(trimmed,@"(?i)multi.?frame.{0,80}supported|max(?:imum)? generated frames|DLSS.?G.{0,80}GetState|GetState.{0,80}DLSS.?G"))
                    observations.Add(file.Key+": "+Regex.Replace(trimmed,@"[\r\t]"," "));
            }
        }
        if(observations.Count==0)
            return "No native Streamline DLSS-G capability lines were found in the bounded Performance logs. This does not establish that the game lacks a provider.\r\n";
        return "Native game Streamline DLSS-G capability evidence was found in Performance logs (up to 12 lines shown):\r\n"+
            String.Join("\r\n",observations.Distinct().Take(12))+"\r\n"+
            "These log entries may be historical and are not bound here to LastSession process identity. A reported maximum shows provider capability only; it does not prove that MFG was selected, generated frames, or reached display.\r\n";
    }
    static string SessionField(Dictionary<string,object> session,string name) {
        if(session==null)return "Not observed";
        object value;
        if(!session.TryGetValue(name,out value)) {
            var pair=session.FirstOrDefault(p=>String.Equals(p.Key,name,StringComparison.OrdinalIgnoreCase));
            if(pair.Key==null)return "Not observed";value=pair.Value;
        }
        string text=Convert.ToString(value);
        if(String.IsNullOrWhiteSpace(text))return "Not observed";
        text=Regex.Replace(text,@"[\r\n\t]+"," ").Trim();
        return text.Length>2048?text.Substring(0,2048):text;
    }
    string NeuralRuntimeActivityEvidence() {
        var evidence=new List<string>();
        foreach(Item item in items.Where(i=>i.Name.IndexOf("OptiShadeData_ReShade.log",StringComparison.OrdinalIgnoreCase)>=0 ||
                                            i.Name.IndexOf("OptiScaler.log",StringComparison.OrdinalIgnoreCase)>=0)) {
            if(String.IsNullOrEmpty(item.Text))continue;
            foreach(string line in item.Text.Split('\n')) {
                string trimmed=line.Trim();
                if(trimmed.Length>2048)continue;
                if(Regex.IsMatch(trimmed,@"(?i)XP12 Vulkan NR:|Neural.?rendering.{0,80}(?:enabled|disabled|active|request)|NR.{0,80}disabled by user"))
                    evidence.Add(Regex.Replace(trimmed,@"[\r\t]"," "));
            }
        }
        return String.Join("\r\n",evidence.Distinct().Take(8));
    }
    public static string NeuralSessionAssessment(Dictionary<string,object> session) {
        if(session==null)return "Neural rendering: no usable saved game session was captured; this archive cannot determine whether NR was requested.\r\n";
        string requested=SessionField(session,"Requested");
        string activationCount=SessionField(session,"NRActivationAttemptCount");
        string activationHistory=SessionField(session,"NRActivationHistory");
        string lastAction=SessionField(session,"NRActivationLastAction");
        string lastSource=SessionField(session,"NRActivationLastSource");
        string activationOutcome=SessionField(session,"NRActivationOutcome");
        string runtimeActivity=SessionField(session,"NRRuntimeActivityEvidence");
        string xp12Admission=SessionField(session,"XP12BridgeAdmissionStage");
        string xp12FirstBlock=SessionField(session,"XP12BridgeFirstBlockReason");
        string xp12LatestBlock=SessionField(session,"XP12BridgeLatestBlockReason");
        ulong parsedActivationCount=0;
        bool hasRecordedActivationCount=UInt64.TryParse(activationCount,out parsedActivationCount);
        bool hasExplicitActivation=hasRecordedActivationCount&&parsedActivationCount>0;
        string stage=SessionField(session,"NRStage");
        var output=new StringBuilder("Latest saved game session (may be historical): NR requested=")
            .Append(requested).Append("; API=").Append(SessionField(session,"API"))
            .Append("; route=").Append(SessionField(session,"NRRoute"))
            .Append("; explicit activation controls=").Append(activationCount)
            .Append("; last control=").Append(lastAction).Append(" from ").Append(lastSource)
            .Append("; control outcome=").Append(activationOutcome)
            .Append("; control history=").Append(activationHistory)
            .Append("; XP12 admission=").Append(xp12Admission)
            .Append("; XP12 first block=").Append(xp12FirstBlock)
            .Append("; latest XP12 block=").Append(xp12LatestBlock)
            .Append(" at ").Append(SessionField(session,"XP12BridgeLatestBlockUtc"))
            .Append(" (distinct block transitions=").Append(SessionField(session,"XP12BridgeBlockCount")).Append(")")
            .Append(" (API=").Append(SessionField(session,"XP12BridgeBlockAPI"))
            .Append(", device=").Append(SessionField(session,"XP12BridgeBlockDevice"))
            .Append(", owner=").Append(SessionField(session,"XP12BridgeBlockOwner"))
            .Append(", generation=").Append(SessionField(session,"XP12BridgeBlockGeneration"))
            .Append(", queue=").Append(SessionField(session,"XP12BridgeBlockQueue")).Append(")")
            .Append("; stage=").Append(stage)
            .Append("; submission=").Append(SessionField(session,"SubmissionStage"))
            .Append("; GPU completion=").Append(SessionField(session,"GPUCompletion"))
            .Append("; XP12 bridge=").Append(SessionField(session,"XP12BridgeStage"))
            .Append("; failure=").Append(SessionField(session,"LastFailure")).Append(".\r\n");
        if(String.Equals(requested,"Off",StringComparison.OrdinalIgnoreCase)&&hasExplicitActivation)
            output.AppendLine("The final NR request is Off, but this session recorded "+parsedActivationCount+" explicit NR control action(s). Use the timestamped On/Off history and runtime stages to determine whether activation was attempted and why it stopped; the final Off state is not evidence that it was never attempted.");
        else if(String.Equals(requested,"Off",StringComparison.OrdinalIgnoreCase)&&!String.Equals(runtimeActivity,"Not observed",StringComparison.OrdinalIgnoreCase))
            output.AppendLine("NR runtime activity was found in the captured logs, but the saved LastSession state contains no explicit activation control record. The log and saved-session process identities may differ; this archive cannot establish that NR was never attempted. Review the activity lines and process timestamps before drawing a conclusion.");
        else if(String.Equals(requested,"Off",StringComparison.OrdinalIgnoreCase))
            output.AppendLine("NR was not requested in this saved session's final state, and this session contains no explicit activation action record. Older builds saved only the latest state, so an earlier On attempt may have been overwritten; this archive cannot establish that NR was never attempted. Enable NR in a new run and collect diagnostics after the attempt.");
        else if(String.Equals(requested,"On",StringComparison.OrdinalIgnoreCase) &&
                (String.Equals(stage,"Waiting",StringComparison.OrdinalIgnoreCase)||String.Equals(stage,"Starting",StringComparison.OrdinalIgnoreCase)||String.Equals(stage,"Not observed",StringComparison.OrdinalIgnoreCase)))
            output.AppendLine("NR was requested, but this saved session does not record a completed NR stage. Use the stage, failure and runtime logs to investigate; this alone does not establish why processing stopped.");
        else if(String.Equals(requested,"On",StringComparison.OrdinalIgnoreCase))
            output.AppendLine("NR was requested and a runtime stage was recorded. Saved state does not prove that the processed image was visible; review the session-bound runtime logs and user observation.");
        else
            output.AppendLine("NR request state is unknown in this saved session. This archive cannot establish whether neural rendering was exercised.");
        return output.ToString();
    }
    void NeuralSessionAssessment() {
        try {
            string path=Path.Combine(r.Game,"OptiShadeData","LastSession.json");
            Dictionary<string,object> session=null;
            if(File.Exists(path)&&new FileInfo(path).Length<=262144)
                session=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(File.ReadAllText(path));
            string runtimeActivity=NeuralRuntimeActivityEvidence();
            if(session!=null&&!String.IsNullOrEmpty(runtimeActivity))session["NRRuntimeActivityEvidence"]=runtimeActivity;
            findings.Append(NeuralSessionAssessment(session));
            if(!String.IsNullOrEmpty(runtimeActivity))findings.AppendLine("Captured NR runtime activity (session identity is not proven by these log lines):\r\n"+runtimeActivity);
        } catch(Exception e) { findings.AppendLine("Neural rendering session summary unavailable: "+e.GetType().Name+"."); }
    }
    void MfgLogs() {
        string temp=mfgTempDirectory;
        string local=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"OptiMFG","runtime");
        foreach(string dir in new[]{local,Path.Combine(r.Game,"OptiShadeData","OptiMFG","Runtime")}.Distinct(StringComparer.OrdinalIgnoreCase)) {
            try {
                if(!Directory.Exists(dir)) {ledger.AppendLine("OptiMFG runtime logs: directory not present: "+Path.GetFileName(dir));continue;}
                if((File.GetAttributes(dir)&FileAttributes.ReparsePoint)!=0){ledger.AppendLine("OptiMFG runtime log directory is linked and was skipped: "+Path.GetFileName(dir));continue;}
                int included=0;
                foreach(string file in Directory.GetFiles(dir).Where(f=>Regex.IsMatch(Path.GetFileName(f),@"(?i)^(controller|helper|fps|capture|OptiMFG).+\.(jsonl|log|txt)$") && File.GetLastWriteTimeUtc(f)>=DateTime.UtcNow.AddHours(-r.Hours)).OrderByDescending(File.GetLastWriteTimeUtc).Take(12)) {
                    Log(file,"mfg/OptiMFG-"+Path.GetFileName(file),2*1024*1024,1,false);included++;
                }
                ledger.AppendLine("OptiMFG bounded runtime logs captured: "+included+" from "+Path.GetFileName(dir)+".");
                string exports=Path.Combine(dir,"exports");
                if(Directory.Exists(exports)) ledger.AppendLine("OptiMFG diagnostic exports exist separately; controller/helper logs are included directly to avoid nested ZIPs.");
            } catch(Exception e) {ledger.AppendLine("OptiMFG runtime log discovery: "+e.GetType().Name);}
        }
        try {
            foreach(string f in Directory.GetFiles(temp,"RTXMFG-"+Path.GetFileNameWithoutExtension(exe)+"-*.log").Where(f=>File.GetLastWriteTimeUtc(f)>=DateTime.UtcNow.AddHours(-r.Hours)).OrderByDescending(File.GetLastWriteTimeUtc).Take(3))
                Log(f,"providers/historical-"+Path.GetFileName(f)+".txt",4*1024*1024,1,false);
            ledger.AppendLine("RTXMFG temporary logs match executable name/time only; may belong to another installation.");
        }catch(Exception e){ledger.AppendLine("RTXMFG log discovery: "+e.Message);}
        try {
            string receipt=Path.Combine(r.Game,"OptiShadeData","MFG","session.json");
            if(!File.Exists(receipt) || new FileInfo(receipt).Length>16384)return;
            var map=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(File.ReadAllText(receipt));
            if(Convert.ToString(map["product"])!="OptiShadeMFG" || Convert.ToInt64(map["abi"])!=131072)return;
            uint pid=Convert.ToUInt32(map["pid"]);
            DateTime birth=DateTime.FromFileTimeUtc(Convert.ToInt64(map["processBirth"]));
            DateTime heartbeat=new DateTime(1970,1,1,0,0,0,DateTimeKind.Utc).AddSeconds(Convert.ToInt64(map["heartbeat"]));
            if(pid==0 || heartbeat<birth || heartbeat>DateTime.UtcNow.AddMinutes(2) || heartbeat<DateTime.UtcNow.AddHours(-r.Hours))return;
            var fi=new FileInfo(Path.Combine(temp,"MfgUnlock-"+pid+".log"));
            if(fi.Exists && fi.CreationTimeUtc>=birth.AddSeconds(-2) && fi.CreationTimeUtc<=heartbeat.AddMinutes(2) && fi.LastWriteTimeUtc>=birth.AddSeconds(-2) && fi.LastWriteTimeUtc<=heartbeat.AddMinutes(2)) {
                Log(fi.FullName,"providers/MfgUnlock-selected-session.txt",4*1024*1024,1,false);
                ledger.AppendLine("MfgUnlock log matched selected installation receipt PID and time window; may be historical.");
            } else ledger.AppendLine("MfgUnlock session log was not present or failed the selected process time bounds.");
            string intervalPath=Path.Combine(temp,"MfgUnlock-intervals-"+pid+".csv");
            if(IsSessionBoundMfgIntervalTrace(intervalPath,pid,Convert.ToInt64(map["processBirth"]),Convert.ToInt64(map["heartbeat"]),DateTime.UtcNow,r.Hours)) {
                Log(intervalPath,"providers/MfgUnlock-intervals-selected-session.csv",4*1024*1024,1,false);
                string previousPath=Path.Combine(temp,"MfgUnlock-intervals-"+pid+".previous.csv");
                if(IsSessionBoundMfgIntervalTrace(previousPath,pid,Convert.ToInt64(map["processBirth"]),Convert.ToInt64(map["heartbeat"]),DateTime.UtcNow,r.Hours))
                    Log(previousPath,"providers/MfgUnlock-intervals-previous-selected-session.csv",4*1024*1024,1,false);
                ledger.AppendLine("MfgUnlock temporal interval trace matched selected installation receipt PID, process birth and heartbeat; current and previous bounded trace segments are collected when present. These record NGX request evidence, not proof of displayed output.");
            } else {
                string previousPath=Path.Combine(temp,"MfgUnlock-intervals-"+pid+".previous.csv");
                if(IsSessionBoundMfgIntervalTrace(previousPath,pid,Convert.ToInt64(map["processBirth"]),Convert.ToInt64(map["heartbeat"]),DateTime.UtcNow,r.Hours)) {
                    Log(previousPath,"providers/MfgUnlock-intervals-previous-selected-session.csv",4*1024*1024,1,false);
                    ledger.AppendLine("MfgUnlock previous temporal trace segment matched selected installation receipt PID, process birth and heartbeat; it records NGX request evidence, not proof of displayed output.");
                } else ledger.AppendLine("MfgUnlock temporal interval trace segments were not present or did not match selected installation receipt identity/time bounds.");
            }
        }catch(Exception e){ledger.AppendLine("MfgUnlock receipt unavailable or invalid: "+e.Message);}
    }
    void Hardware() {
        Stage("Reading hardware and driver information...");
        var b=new StringBuilder("Adapters below are enumerated hardware, not proof of the active rendering GPU. CPU clock is reported, not sampled telemetry.\r\n");
        foreach(string q in new[]{
            "SELECT Name,Version,BuildNumber,TotalVisibleMemorySize,FreePhysicalMemory FROM Win32_OperatingSystem",
            "SELECT Name,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed FROM Win32_Processor",
            "SELECT Name,DriverVersion,DriverDate,VideoModeDescription FROM Win32_VideoController"
        }) {
            cancel.ThrowIfCancellationRequested();
            try {
                using(var search=new ManagementObjectSearcher(new ManagementScope(@"\\.\root\cimv2"),new ObjectQuery(q),new EnumerationOptions{Timeout=TimeSpan.FromSeconds(8)}))
                using(var rows=search.Get()) foreach(ManagementObject o in rows) using(o) {
                    foreach(PropertyData p in o.Properties) b.AppendLine(p.Name+": "+Convert.ToString(p.Value));
                    b.AppendLine();
                }
            } catch(Exception e) { b.AppendLine("Query unavailable: "+e.Message); }
        }
        Add("system/hardware.txt",b.ToString(),0);
    }
    void Hashes() {
        Stage("Hashing installed runtime components...");
        var b=new StringBuilder("Installed files: size, SHA256 and file version. Files are read only; DLLs are not loaded.\r\n");
        var names=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach(string n in new[]{"glass-cockpit-dlss-fix.addon64","winmm.dll","dxgi.dll","version.dll","dinput8.dll","d3d12.dll","OptiScaler.dll","ReShade64.dll","nvngx.dll","nvngx_dlssnr.dll","nvngx.dll_dlssnr.dll","nvngx_dlss.dll","nvngx_dlssg.dll","sl.interposer.dll","sl.dlss_g.dll","OptiShadeData/Tools/OptiShadeSensors.exe"}) names.Add(n);
        foreach(string d in new[]{"OptiShadeData","OptiShadeData/Engine","OptiShadeData/Engine/Routes","OptiShadeData/Engine/D3D12_OptiScaler","OptiShadeData/Engine/streamline","OptiShadeData/MFG"}) {
            string path=Path.Combine(r.Game,d);
            if(Directory.Exists(path)) foreach(string f in Directory.GetFiles(path,"*.dll").Take(32)) names.Add(d+"/"+Path.GetFileName(f));
        }
        foreach(string n in names) {
            cancel.ThrowIfCancellationRequested();
            string path=Path.Combine(r.Game,n);
            if(!File.Exists(path)) {b.AppendLine(n+": absent");continue;}
            try {
                var fi=new FileInfo(path);
                if(fi.Length>600000000 || (fi.Attributes&FileAttributes.ReparsePoint)!=0) {b.AppendLine(n+": skipped (size/link)");continue;}
                progress("Hashing "+n+"...");
                using(var f=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete))
                using(var sha=SHA256.Create())
                    b.AppendLine(n+" | "+fi.Length+" bytes | "+BitConverter.ToString(sha.ComputeHash(f)).Replace("-","")+" | "+FileVersionInfo.GetVersionInfo(path).FileVersion+" | modified UTC "+fi.LastWriteTimeUtc.ToString("o"));
            } catch(Exception e) { b.AppendLine(n+": "+e.Message); }
        }
        Add("system/installed-hashes.txt",b.ToString(),0);
    }
    void Processes() {
        Stage("Checking the selected game process...");
        var b=new StringBuilder("Read-only process snapshot. No debugger attachment or injected code.\r\n");
        Process[] processes=Process.GetProcessesByName(Path.GetFileNameWithoutExtension(exe));
        if(processes.Length==0) b.AppendLine("Game not running. Live GPU/queue state cannot be recovered after exit.");
        foreach(Process p in processes) using(p) {
            try {
                b.AppendLine("PID "+p.Id+"; start UTC "+p.StartTime.ToUniversalTime().ToString("o")+"; responding "+p.Responding+"; private bytes "+p.PrivateMemorySize64);
                b.AppendLine("Executable: "+p.MainModule.FileName);
                if(SameGameExecutable(p.MainModule.FileName,exePath)){
                    try { Add("runtime/control-"+p.Id+".json",OptiShadeControlClient.Snapshot((uint)p.Id),0); }
                    catch(Exception e) { Add("runtime/control-"+p.Id+"-unavailable.txt",e.GetBaseException().Message,0); }
                }

                foreach(ProcessModule m in p.Modules) b.AppendLine(m.ModuleName+" | "+m.FileVersionInfo.FileVersion);
                b.Append(VrDiagnostics.SelectedGameVrModules(p.Modules.Cast<ProcessModule>()));
            } catch(Exception e) { b.AppendLine("Process detail unavailable: "+e.Message); }
        }
        Add("system/process.txt",b.ToString(),0);
    }
    void Installation() {
        Stage("Reading installation and graphics-runtime context...");
        string root=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"OptiShade","Games");
        try {
            if(Directory.Exists(root)) foreach(string dir in Directory.GetDirectories(root).Take(100)) {
                string manifest=Path.Combine(dir,"manifest.json");
                if(!File.Exists(manifest) || new FileInfo(manifest).Length>4000000)continue;
                var map=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(File.ReadAllText(manifest));
                object game; if(!map.TryGetValue("Game",out game) || !(game is string) || !String.Equals(Path.GetFullPath((string)game).TrimEnd('\\'),r.Game.TrimEnd('\\'),StringComparison.OrdinalIgnoreCase))continue;
                var selected=new Dictionary<string,object>();
                foreach(string key in new[]{"Version","Channel","Status","Installed","Updated","UpdatedUtc","InstallMethod","Game","RendererApi","Architecture","RouteDLL","Downloads"}) {
                    object value; if(map.TryGetValue(key,out value) && (value is string || value is bool || value is int))selected[key]=value;
                }
                Add("installation/manifest-summary.txt",new JavaScriptSerializer().Serialize(selected)+"\r\nOnly selected scalar metadata retained; source/private installer paths excluded.",0);
                Log(Path.Combine(dir,"Installer.log"),"installation/Installer.log.txt",1024*1024,1,false);
                Log(Path.Combine(dir,"PreRestoreDiagnostics.json"),"installation/PreRestoreDiagnostics.txt",1024*1024,2,false);
                break;
            }
        }catch(Exception e){ledger.AppendLine("Installation metadata: "+e.Message);}
        var b=new StringBuilder("Read-only registry context. Saved policy does not prove that the runtime used it.\r\n");
        foreach(var pair in new[]{
            new[]{@"SYSTEM\CurrentControlSet\Control\GraphicsDrivers","HwSchMode"},
            new[]{@"SOFTWARE\Khronos\OpenXR\1","ActiveRuntime"}
        })try{
            using(var key=Microsoft.Win32.Registry.LocalMachine.OpenSubKey(pair[0]))
                b.AppendLine(pair[0]+"\\"+pair[1]+": "+(key==null?"not present":Convert.ToString(key.GetValue(pair[1],"(default/not set)"))));
        }catch(Exception e){b.AppendLine(pair[1]+": unavailable "+e.Message);}
        Add("system/graphics-runtime-policy.txt",b.ToString(),1);
    }
    void VrRuntime() {
        Stage("Collecting VR and OpenXR runtime context...");
        var b=new StringBuilder(VrDiagnostics.OpenXrRegistrationEvidence());
        b.AppendLine();
        b.Append(VrDiagnostics.RuntimeProcessSnapshot());
        Add("system/vr-runtime.txt",b.ToString(),1);
        if(!String.Equals(exe,"X-Plane.exe",StringComparison.OrdinalIgnoreCase))return;
        string log=Path.Combine(r.Game,"Log.txt");
        try {
            if(!File.Exists(log)) {
                ledger.AppendLine("VR simulator log: selected X-Plane installation has no readable Log.txt.");
                return;
            }
            if((File.GetAttributes(log)&FileAttributes.ReparsePoint)!=0) {
                ledger.AppendLine("VR simulator log: linked Log.txt skipped.");
                return;
            }
            string captured=ReadWindow(log,2*1024*1024,false);
            Add("analysis/VR-simulator-log.txt",VrDiagnostics.FilterSimulatorLogEvidence(captured),0);
            ledger.AppendLine("VR simulator log: selected lines from the bounded 2 MiB X-Plane Log.txt tail; full bounded log is also in logs/Log.txt.txt.");
        } catch(Exception e) {
            ledger.AppendLine("VR simulator log unavailable: "+e.GetType().Name);
        }
    }
    void VrSessionTimeline() {
        Stage("Building a timestamped VR/OpenXR event timeline...");
        var output=new StringBuilder("VR/OpenXR lifecycle and performance clues from captured OptiShade logs. Lines retain their source timestamps; log filenames are not proof that the original lines belong to the selected process. Match logs/session-provenance.txt and the PID/process birth in system/process.txt. Absence of events does not prove VR was inactive.\r\n");
        var pattern=new Regex(@"(?i)(OpenXR|xrPollEvent|xrBeginSession|xrEndSession|xrCreateSession|xrDestroySession|session state|VR|stereo|headset|HMD|projection depth|swapchain|frame.?time|frametime|GPU.*(?:ms|busy)|VRAM|out of memory|device.?removed|device reset|queue.*(?:wait|timeout))");
        int written=0;
        foreach(Item item in items.Where(i=>i.Name.StartsWith("logs/",StringComparison.OrdinalIgnoreCase) && (i.Name.IndexOf("Performance",StringComparison.OrdinalIgnoreCase)>=0 || i.Name.IndexOf("ReShade",StringComparison.OrdinalIgnoreCase)>=0 || i.Name.IndexOf("OptiScaler",StringComparison.OrdinalIgnoreCase)>=0))) {
            string[] lines=(item.Text??"").Split(new[]{"\r\n","\n","\r"},StringSplitOptions.None);
            var matching=lines.Where(line=>pattern.IsMatch(line)).ToArray();
            if(matching.Length==0)continue;
            output.AppendLine("\r\n--- "+item.Name+" | matching lines="+matching.Length+" ---");
            int skip=Math.Max(0,matching.Length-120);
            if(skip>0)output.AppendLine("[older matching lines omitted: "+skip+"]");
            foreach(string line in matching.Skip(skip)) {
                if(written>=600 || output.Length>=240000)break;
                string safe=line.Length>700?line.Substring(0,700)+" [line truncated]":line;
                output.AppendLine(safe);written++;
            }
            if(written>=600 || output.Length>=240000)break;
        }
        if(written==0)output.AppendLine("No matching lifecycle/performance lines were present in captured logs.");
        output.AppendLine("\r\nNewer OptiShade builds log OpenXR session-state changes and xrBeginSession/xrEndSession results when the game-local layer receives those API calls. These markers can identify VR exit/re-entry boundaries; they do not measure headset compositor frame time or prove the cause of a slowdown.");
        Add("analysis/VR-session-timeline.txt",output.ToString(),0);
        findings.AppendLine("VR/OpenXR lifecycle and performance timeline: analysis/VR-session-timeline.txt. OpenXR transition markers are added by this build when the game-local layer receives them.");
    }
    void Events() {
        Stage("Reading recent game-crash and display-driver events...");
        foreach(string channel in new[]{"Application","System"}) {
            var b=new StringBuilder(); int scanned=0, matched=0; Stopwatch timer=Stopwatch.StartNew();
            try {
                using(var log=new EventLog(channel)) {
                    int count=log.Entries.Count;
                    for(int i=count-1;i>=0 && scanned<5000 && timer.Elapsed.TotalSeconds<15;i--) {
                        cancel.ThrowIfCancellationRequested(); scanned++;
                        EventLogEntry e=log.Entries[i];
                        if(e.TimeGenerated.ToUniversalTime()<DateTime.UtcNow.AddHours(-r.Hours)) break;
                        int id=(int)(e.InstanceId&0xffff);
                        if(channel=="Application" && id!=1000 && id!=1001 && id!=1002) continue;
                        // Unexpected restarts too: a whole-PC crash leaves no game crash
                        // report (OSD-FVVG), only Kernel-Power 41, EventLog 6008 and a bugcheck.
                        if(channel=="System" && !Regex.IsMatch(e.Source,@"(?i)Display|nvlddmkm|amdwddmg|WHEA") &&
                           !(id==41&&e.Source.EndsWith("Kernel-Power",StringComparison.OrdinalIgnoreCase)) && !(id==6008&&e.Source=="EventLog") &&
                           !(id==1001&&Regex.IsMatch(e.Source,@"(?i)^BugCheck$|WER-SystemErrorReporting"))) continue;
                        string msg; try {msg=e.Message;} catch {msg=String.Join("\n",e.ReplacementStrings);}
                        // OptiMFG's own crashes too (OSD-TZR9: it closed after elevating FPS capture, with no record).
                        if(channel=="Application" && msg.IndexOf(exe,StringComparison.OrdinalIgnoreCase)<0 && !(r.IncludeMfgLogs && msg.IndexOf("OptiMFG_Live.exe",StringComparison.OrdinalIgnoreCase)>=0)) continue;
                        if(msg.IndexOf("PrivateBuild",StringComparison.OrdinalIgnoreCase)>=0) continue;
                        if(msg.Length>64000) msg=msg.Substring(0,64000)+"\r\n[Event truncated]";
                        b.AppendLine(e.TimeGenerated.ToUniversalTime().ToString("o")+" | "+e.Source+" | "+id+"\r\n"+msg+"\r\n");
                        if(++matched>=80) break;
                    }
                }
            } catch(Exception e) {b.AppendLine("Event query incomplete: "+e.Message);}
            b.Insert(0,"Lookback hours: "+r.Hours+"; scanned: "+scanned+"; matched: "+matched+". Bounded to 5000 events / 15 seconds / 80 matches. Absence is not proof of no failure.\r\n\r\n");
            Add("events/"+channel+".txt",b.ToString(),1);
        }
    }
    // Only the selected simulator's NVIDIA crash directory. No recursive
    // disk crawl, linked directories, unrelated simulators or stale dumps.
    public static List<string> ProviderDumps(string root,string selected,DateTime since) {
        var found=new List<string>();
        if(selected!="FlightSimulator2024.exe" && selected!="FlightSimulator.exe" && selected!="X-Plane.exe")return found;
        string sim=Path.Combine(root,Path.GetFileNameWithoutExtension(selected));
        var timer=Stopwatch.StartNew();
        if(!Directory.Exists(root)||!Directory.Exists(sim))return found;
        for(string p=sim;!String.IsNullOrEmpty(p);p=Path.GetDirectoryName(p))
            if((File.GetAttributes(p)&FileAttributes.ReparsePoint)!=0)return found;
        var dirs=new List<string>{sim};
        foreach(string d in Directory.EnumerateDirectories(sim).Take(128)) {
            if(timer.ElapsedMilliseconds>3000)break;
            if((File.GetAttributes(d)&FileAttributes.ReparsePoint)==0)dirs.Add(d);
        }
        int inspected=0;
        foreach(string d in dirs)foreach(string f in Directory.EnumerateFiles(d,"*.dmp").Take(128)) {
            if(++inspected>1024 || timer.ElapsedMilliseconds>3000)return found;
            if((File.GetAttributes(f)&FileAttributes.ReparsePoint)==0 && File.GetLastWriteTimeUtc(f)>=since)found.Add(f);
        }
        return found;
    }
    void Crashes(string temporary) {
        if(!r.Crash) {ledger.AppendLine("Crash dump summaries: disabled by tester");return;}
        Stage("Reading recent crash dumps (structured metadata only)...");
        uint referencePid=selectedLogPid>0?(uint)selectedLogPid:0;
        long referenceBirth=selectedLogStartUtc.HasValue?selectedLogStartUtc.Value.ToFileTimeUtc():0;
        string referenceSource="live selected game process";
        if(referencePid==0||referenceBirth<=0) {
            referenceSource="selected installation LastSession";
            try {
                string lastPath=Path.Combine(r.Game,"OptiShadeData","LastSession.json");
                if(File.Exists(lastPath)&&new FileInfo(lastPath).Length<=262144&&(File.GetAttributes(lastPath)&FileAttributes.ReparsePoint)==0) {
                    var last=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(File.ReadAllText(lastPath));
                    object pidValue,birthValue;
                    if(last!=null&&last.TryGetValue("PID",out pidValue)&&last.TryGetValue("ProcessBirthFileTime",out birthValue)) {
                        referencePid=Convert.ToUInt32(pidValue);referenceBirth=Convert.ToInt64(birthValue);
                        if(referencePid==0||referenceBirth<=0){referencePid=0;referenceBirth=0;}
                    }
                }
            } catch {referencePid=0;referenceBirth=0;}
        }
        ledger.AppendLine(referencePid>0&&referenceBirth>0?"Crash-dump identity reference: "+referenceSource+" PID="+referencePid+" processBirthFileTime="+referenceBirth+".":"Crash-dump identity reference unavailable; executable-name matches remain unverified.");
        string werSetting=CrashDumps.Read(exe).Detail;
        findings.AppendLine("Windows crash dumps (WER LocalDumps): "+werSetting+(werSetting.StartsWith("Off")?" A crash before this report may have left no dump; turn crash dumps on in the Troubleshooter and reproduce.":""));
        ledger.AppendLine("WER LocalDumps: "+werSetting);
        var candidates=new List<string>();
        foreach(string dir in new[]{Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"CrashDumps"),r.Game,Path.Combine(r.Game,"OptiShadeData")}) {
            try {
                if(Directory.Exists(dir)) candidates.AddRange(Directory.GetFiles(dir,"*.dmp").Where(f=>File.GetLastWriteTimeUtc(f)>=DateTime.UtcNow.AddHours(-r.Hours) && (File.GetAttributes(f)&FileAttributes.ReparsePoint)==0 && (dir==r.Game || dir.EndsWith("OptiShadeData") || Path.GetFileName(f).StartsWith(exe+".",StringComparison.OrdinalIgnoreCase))));
            } catch(Exception e) {ledger.AppendLine("Dump discovery: "+e.Message);}
        }
        try {
            var provider=ProviderDumps(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),"NVIDIA","Streamline"),exe,DateTime.UtcNow.AddHours(-r.Hours));
            candidates.AddRange(provider);
            ledger.AppendLine("Selected-simulator Streamline dump candidates: "+provider.Count+" (bounded discovery; executable identity checked below).");
        }catch(Exception e){ledger.AppendLine("Streamline dump discovery incomplete: "+e.GetType().Name+": "+e.Message);}
        int captured=0, checkedCount=0;
        foreach(string path in candidates.OrderByDescending(File.GetLastWriteTimeUtc).Take(r.FullEvidence?24:12)) {
            cancel.ThrowIfCancellationRequested(); checkedCount++;
            string identity=OptiShade.Diagnostics.DumpSummary.Executable(path);
            if(!String.Equals(identity,exe,StringComparison.OrdinalIgnoreCase)) {ledger.AppendLine("Dump skipped: executable identity not selected simulator ("+identity+")");continue;}
            long rawCap=r.FullEvidence?900L*1024*1024:128L*1024*1024;
            bool rawQueued=false;
            // Check my setup reads the summary only; raw copies are for a sent report.
            if(!checkOnly&&new FileInfo(path).Length<=rawCap) {
                try {
                    string snapshot=Path.Combine(temporary,"crash-"+(captured+1)+"-"+Path.GetFileName(path));
                    File.Copy(path,snapshot);
                    items.Add(new Item("crashes/"+(captured+1)+"-"+Path.GetFileName(path),"",2){BinaryPath=snapshot});rawQueued=true;
                    ledger.AppendLine("Raw crash dump snapshot queued; ZIP budget may omit it: "+Path.GetFileName(path));
                }catch(Exception e){ledger.AppendLine("Raw crash snapshot unavailable: "+e.GetType().Name);}
            }else ledger.AppendLine("Raw crash dump omitted above the "+(rawCap/1048576)+" MiB snapshot cap; bounded summary/text export still attempted.");
            progress("Summarising crash dump "+Path.GetFileName(path)+"...");
            string association;
            try {association=ClassifyCrashDumpProcessIdentity(OptiShade.Diagnostics.DumpSummary.ReadProcessIdentity(path),referencePid,referenceBirth,referenceSource);}
            catch {association=ClassifyCrashDumpProcessIdentity(null,referencePid,referenceBirth,referenceSource);}
            Add("crashes/"+(++captured)+"-"+Path.GetFileName(path)+".txt","Dump modified UTC: "+File.GetLastWriteTimeUtc(path).ToString("o")+"\r\nDump-to-session association: "+association+"\r\n\r\n"+OptiShade.Diagnostics.DumpSummary.Analyze(path),0);
            // The raw dump already carries every byte; its hex text copy only helps
            // when the raw file cannot be attached (Discord-sized reports).
            if(r.FullEvidence && rawQueued) ledger.AppendLine("Memory text skipped for "+Path.GetFileName(path)+": the raw dump is attached in full (private upload profile).");
            else {
            items.Add(new Item("memory/"+captured+"-"+Path.GetFileName(path)+"-bytes.txt","",4){DumpPath=path,DumpBytes=new FileInfo(path).Length});
            ledger.AppendLine("Memory text queued inside ZIP: "+Path.GetFileName(path)+". Full bytes requested; see size-budget.txt for any reductions.");
            }
            if(captured==(r.FullEvidence?6:3)) break;
        }
        ledger.AppendLine("Crash dumps inspected: "+checkedCount+"; matching summaries: "+captured+"; memory text included subject to ZIP cap.");
        foreach(string baseDir in new[]{Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)}) {
            string root=Path.Combine(baseDir,"Microsoft","Windows","WER","ReportArchive");
            try {
                if(!Directory.Exists(root)) continue;
                int n=0;
                foreach(string dir in Directory.GetDirectories(root).OrderByDescending(Directory.GetLastWriteTimeUtc).Take(100)) {
                    string f=Path.Combine(dir,"Report.wer");
                    if(!File.Exists(f) || File.GetLastWriteTimeUtc(f)<DateTime.UtcNow.AddHours(-r.Hours)) continue;
                    string text=ReadWindow(f,256*1024,true);
                    if(text.IndexOf(exe,StringComparison.OrdinalIgnoreCase)<0) continue;
                    Add("crashes/WER-"+(baseDir==Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData)?"system":"user")+"-"+(++n)+".txt",text,0);
                    if(n==3) break;
                }
            } catch(Exception e) {ledger.AppendLine("WER archive: "+e.Message);}
        }
        int reports=items.Count(i=>i.Name.StartsWith("crashes/WER-",StringComparison.Ordinal)||i.Name.IndexOf("AsoboReport-Crash",StringComparison.OrdinalIgnoreCase)>=0);
        if(captured==0&&reports==0) findings.AppendLine("No recent crash dump or crash report found for this game.");
        else if(captured==0) findings.AppendLine("No raw crash dump for this game, but "+reports+" crash report(s) were captured; see VERDICTS.");
        else findings.AppendLine("Crash dumps captured: "+captured+"; crash reports: "+reports+".");
    }
    // ---- raw evidence (private upload) ----------------------------------
    // Untouched copies of the original files under raw/, alongside the
    // redacted text and analysis above. Each file is snapshotted with
    // shared-read access so running games and launchers keep writing, and
    // raw/RAW-MANIFEST.txt records size, SHA-256, modified time and any skip.
    const long RawFileCap=512L*1024*1024;
    const int RawFileLimit=600;
    static readonly Regex RawText=new Regex(@"(?i)\.(log|txt|json|jsonl|ini|csv|cfg|opt|xml|wer|toml)$");
    readonly StringBuilder rawManifest=new StringBuilder();
    readonly HashSet<string> rawSeen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    int rawCount;
    long rawBytes;
    void RawFile(string temporary,string path,string name) {
        cancel.ThrowIfCancellationRequested();
        string shown=Redact(path,r.Game);
        try {
            var info=new FileInfo(path);
            if(!info.Exists||!rawSeen.Add(info.FullName))return;
            if((info.Attributes&FileAttributes.ReparsePoint)!=0){rawManifest.AppendLine("SKIPPED linked file: "+shown);return;}
            if(rawCount>=RawFileLimit){rawManifest.AppendLine("SKIPPED file-count limit: "+shown);return;}
            if(info.Length>RawFileCap){rawManifest.AppendLine("SKIPPED over "+(RawFileCap>>20)+" MiB ("+info.Length+" bytes): "+shown);return;}
            string snapshot=Path.Combine(temporary,"raw-"+(++rawCount)+"-"+Path.GetFileName(path));
            string hash;
            using(var src=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete))
            using(var dst=new FileStream(snapshot,FileMode.CreateNew,FileAccess.Write))
            using(var sha=SHA256.Create()) {
                byte[] buffer=new byte[1<<20];int read;
                while((read=src.Read(buffer,0,buffer.Length))>0){cancel.ThrowIfCancellationRequested();dst.Write(buffer,0,read);sha.TransformBlock(buffer,0,read,null,0);}
                sha.TransformFinalBlock(buffer,0,0);hash=BitConverter.ToString(sha.Hash).Replace("-","").ToLowerInvariant();
            }
            long copied=new FileInfo(snapshot).Length;rawBytes+=copied;
            string entry="raw/"+name.Replace('\\','/');
            items.Add(new Item(entry,"",3){BinaryPath=snapshot});
            rawManifest.AppendLine(entry+"\tbytes="+copied+"\tsha256="+hash+"\tmodifiedUtc="+info.LastWriteTimeUtc.ToString("o")+"\tsource="+shown);
        } catch(OperationCanceledException){throw;}
        catch(Exception e){rawManifest.AppendLine("UNREADABLE "+e.GetType().Name+": "+shown+" ("+e.Message+")");}
    }
    // followLink: only for known simulator data folders that Windows stores as links.
    void RawFolder(string temporary,string dir,string prefix,Func<string,bool> include,int depth,int maxFiles,bool followLink=false) {
        try {
            if(!Directory.Exists(dir))return;
            if(!followLink&&(File.GetAttributes(dir)&FileAttributes.ReparsePoint)!=0){rawManifest.AppendLine("SKIPPED linked folder: "+Redact(dir,r.Game));return;}
            foreach(string f in Directory.GetFiles(dir).Where(include).OrderByDescending(File.GetLastWriteTimeUtc).Take(maxFiles))
                RawFile(temporary,f,prefix+"/"+Path.GetFileName(f));
            if(depth<=0)return;
            foreach(string sub in Directory.GetDirectories(dir)) {
                string leaf=Path.GetFileName(sub);
                // Shader caches, presets and backups are large and not evidence.
                if(Regex.IsMatch(leaf,@"(?i)^(Shaders|Textures|Cache|ShaderCache|Backup.*|Presets|Addons?|Fonts|PendingReports|Downloads|licenses)$"))continue;
                RawFolder(temporary,sub,prefix+"/"+leaf,include,depth-1,maxFiles);
            }
        } catch(OperationCanceledException){throw;}
        catch(Exception e){rawManifest.AppendLine("UNREADABLE folder "+Redact(dir,r.Game)+": "+e.GetType().Name);}
    }
    bool Recent(string f,double hours){try{return File.GetLastWriteTimeUtc(f)>=DateTime.UtcNow.AddHours(-hours);}catch{return false;}}
    void RawEvidence(string temporary) {
        Stage("Copying original log files...");
        double week=Math.Max(r.Hours,168);
        if(r.IncludeGameLogs||r.IncludeMfgLogs) {
            // Game folder: OptiShade, ReShade, OptiScaler, Streamline and NVIDIA logs/configs at the top level.
            RawFolder(temporary,r.Game,"game",f=>Regex.IsMatch(Path.GetFileName(f),@"(?i)^(.*\.log|.*\.log\.\d+|OptiScaler\.ini|ReShade\.ini|glass-cockpit.*\.(ini|log)|dxgi\.ini|nvngx.*\.(txt|log)|sl\..*\.(log|txt|json)|RTX.*MFG.*\.(json|ini)|dlss5-feed.*\.dmp|exception_\d+\.dmp)$"),0,80);
            RawFolder(temporary,Path.Combine(r.Game,"OptiShadeData"),"game/OptiShadeData",f=>RawText.IsMatch(f),4,200);
            // The legacy NR x64 worker writes its own crash dump here; it is not the game's
            // process, so the game-identity crash scan never picks it up.
            RawFolder(temporary,Path.Combine(r.Game,"host64"),"game/host64",f=>RawText.IsMatch(f)||Regex.IsMatch(Path.GetFileName(f),@"(?i)^dlss5-feed.*\.dmp$"),1,40);
        }
        if(r.IncludeMfgLogs) {
            RawFolder(temporary,Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"OptiMFG","runtime"),"mfg/runtime",f=>RawText.IsMatch(f)&&Recent(f,week),1,80);
            RawFolder(temporary,mfgTempDirectory,"mfg/temp",f=>Regex.IsMatch(Path.GetFileName(f),@"(?i)^(RTXMFG|MfgUnlock).*\.(log|csv|txt)$")&&Recent(f,week),0,40);
        }
        if(r.IncludeLauncherLogs) {
            string configured=Environment.GetEnvironmentVariable("OPTISHADE_STORE");
            string store=String.IsNullOrWhiteSpace(configured)?Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"OptiShade"):Path.GetFullPath(configured);
            RawFolder(temporary,store,"launcher",f=>RawText.IsMatch(f)&&!Path.GetFileName(f).EndsWith(".upload.json",StringComparison.OrdinalIgnoreCase)&&f.IndexOf(@"\PendingReports\",StringComparison.OrdinalIgnoreCase)<0&&f.IndexOf(@"\Downloads\",StringComparison.OrdinalIgnoreCase)<0,2,120);
        }
        if(r.IncludeGameLogs) {
            // Simulator crash reports and settings (MSFS keeps them outside the install).
            if(exe=="FlightSimulator2024.exe"||exe=="FlightSimulator.exe") {
                bool fs24=exe=="FlightSimulator2024.exe";
                string family=fs24?"Microsoft.Limitless_8wekyb3d8bbwe":"Microsoft.FlightSimulator_8wekyb3d8bbwe";
                var roots=new[]{Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),fs24?"Microsoft Flight Simulator 2024":"Microsoft Flight Simulator"),
                    Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Packages",family,"LocalState"),
                    Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Packages",family,"LocalCache")};
                int i=0;
                foreach(string root in roots)RawFolder(temporary,root,"simulator/"+(++i),f=>Regex.IsMatch(Path.GetFileName(f),@"(?i)^(AsoboReport.*\.txt|UserCfg\.opt|.*\.log)$")&&(Path.GetFileName(f).Equals("UserCfg.opt",StringComparison.OrdinalIgnoreCase)||Recent(f,week)),0,20,true);
            }
            // Windows Error Reporting folders for this game: Report.wer plus any attached minidumps.
            string stem=Path.GetFileNameWithoutExtension(exe);
            foreach(string baseDir in new[]{Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData)})
            foreach(string kind in new[]{"ReportArchive","ReportQueue"}) {
                string werRoot=Path.Combine(baseDir,"Microsoft","Windows","WER",kind);
                try {
                    if(!Directory.Exists(werRoot))continue;
                    foreach(string report in Directory.GetDirectories(werRoot).Where(d=>Path.GetFileName(d).IndexOf(stem.Length>20?stem.Substring(0,20):stem,StringComparison.OrdinalIgnoreCase)>=0&&Directory.GetLastWriteTimeUtc(d)>=DateTime.UtcNow.AddHours(-week)).OrderByDescending(Directory.GetLastWriteTimeUtc).Take(6))
                        RawFolder(temporary,report,"windows/WER/"+kind+"/"+Path.GetFileName(report),f=>true,0,20);
                } catch(Exception e){rawManifest.AppendLine("WER "+kind+": "+e.GetType().Name);}
            }
            RawFolder(temporary,Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),"NVIDIA","Streamline",stem),"nvidia/Streamline",f=>RawText.IsMatch(f)&&Recent(f,week),2,40);
            // Raw crash dumps already collected under crashes/ are not repeated here.
            WindowsEventLogs(temporary);
            // No dxdiag: it probes every display adapter and output, which with a
            // full-screen game running corrupted one tester's display until reboot.
        }
        Add("raw/RAW-MANIFEST.txt","ORIGINAL FILES (unredacted, byte-for-byte)\r\nFiles: "+rawCount+"; bytes: "+rawBytes+"\r\nSource paths below are shown with the user folder hidden; the files themselves are not redacted.\r\n\r\n"+rawManifest,-1);
        ledger.AppendLine("Raw original files: "+rawCount+" ("+rawBytes+" bytes); see raw/RAW-MANIFEST.txt.");
    }
    // Application and System event logs for the lookback window, in Windows'
    // own .evtx format (open in Event Viewer). DirectX/driver TDRs and
    // application crashes land here.
    void WindowsEventLogs(string temporary) {
        Stage("Exporting Windows event logs...");
        foreach(string log in new[]{"System","Application"}) {
            string target=Path.Combine(temporary,"events-"+log+".evtx");
            try {
                long ms=(long)TimeSpan.FromHours(Math.Max(r.Hours,48)).TotalMilliseconds;
                var start=new ProcessStartInfo("wevtutil.exe","epl "+log+" \""+target+"\" /q:\"*[System[TimeCreated[timediff(@SystemTime) <= "+ms+"]]]\" /ow:true"){UseShellExecute=false,CreateNoWindow=true,RedirectStandardError=true,RedirectStandardOutput=true};
                using(var p=Process.Start(start)) {
                    string err=p.StandardError.ReadToEnd();
                    if(!p.WaitForExit(120000)){try{p.Kill();}catch{}rawManifest.AppendLine("Event log "+log+": export timed out");continue;}
                    if(p.ExitCode!=0||!File.Exists(target)){rawManifest.AppendLine("Event log "+log+": export failed ("+p.ExitCode+") "+err.Trim());continue;}
                }
                RawFile(temporary,target,"windows/events/"+log+".evtx");
            } catch(OperationCanceledException){throw;}
            catch(Exception e){rawManifest.AppendLine("Event log "+log+": "+e.GetType().Name+" "+e.Message);}
        }
    }
    void SavedHangs(string temporary) {
        Stage("Collecting automatic suspected-stall evidence...");
        string root=AutoCapture.Root(r.Game);
        if(!Directory.Exists(root)){ledger.AppendLine("Automatic capture cache absent: older build, helper not started, or no retained evidence.");return;}
        int copiedDumps=0;
        foreach(string file in Directory.GetFiles(root).OrderByDescending(File.GetLastWriteTimeUtc)) {
            if((File.GetAttributes(file)&FileAttributes.ReparsePoint)!=0)continue;
            string name=Path.GetFileName(file);
            if(!Regex.IsMatch(name,@"^session-\d+-\d+(?:-(?:startup|stall))?\.(?:dmp|txt|context\.txt|status\.txt|error\.txt)$"))continue;
            if(File.GetLastWriteTimeUtc(file)<DateTime.UtcNow.AddDays(-3))continue;
            if(name.EndsWith(".dmp")) {
                try {
                    if(new FileInfo(file).Length<=(r.FullEvidence?900L:128L)*1024*1024){
                        string copy=Path.Combine(temporary,name);File.Copy(file,copy);
                        items.Add(new Item("automatic/"+name,"",2){BinaryPath=copy});copiedDumps++;
                    }
                }catch(Exception e){ledger.AppendLine("Automatic dump snapshot unavailable: "+name+" "+e.GetType().Name);}
            }else Log(file,"automatic/"+name,1024*1024,0,false);
        }
        findings.AppendLine("Automatic suspected-stall dumps collected: "+copiedDumps+". Raw inclusion remains subject to ZIP size budget.");
        double graceMinutes=StallPolicy.ForExecutable(exePath).ActiveStartupGraceSeconds/60;
        ledger.AppendLine("Automatic suspected-stall captures are historical evidence matched to selected installation. Match PID/birth/time to logs. Captures require a "+graceMinutes.ToString("0")+"-minute startup grace followed by sustained nonresponse or missing presentation-trace progress; thresholds are longer for MSFS 2024 and captures may still reflect a long load or pause, not a proven defect. Raw dumps are subject to ZIP budget.");
    }
    void LiveHang(string temporary) {
        Stage("Capturing the selected game while it is still running...");
        var evidence=new StringBuilder("Live thread/stack minidump. Captured even if Windows considers the window responsive: a black screen may still pump messages. No injection, no explicit suspension, no full heap dump. Capture can briefly slow the game.\r\n");
        int matched=0;
        foreach(var p in Process.GetProcessesByName(Path.GetFileNameWithoutExtension(exe))) using(p) {
            cancel.ThrowIfCancellationRequested();
            try {
                if(!SameGameExecutable(p.MainModule.FileName,exePath)) {evidence.AppendLine("Skipped different installation PID "+p.Id);continue;}
                if(++matched>2){evidence.AppendLine("Additional process skipped: capture limited to two matching instances.");continue;}
                string file=Path.Combine(temporary,"hang-"+p.Id+".dmp");
                evidence.AppendLine("PID "+p.Id+"; birth UTC "+p.StartTime.ToUniversalTime().ToString("o")+"; capture UTC "+DateTime.UtcNow.ToString("o")+"; responding "+p.Responding);
                HangCapture.Capture(p,exePath,file,cancel,progress);
                Add("hang/"+p.Id+"-summary.txt",OptiShade.Diagnostics.DumpSummary.Analyze(file),0);
                items.Add(new Item("hang/"+p.Id+".dmp","",2){BinaryPath=file});
                evidence.AppendLine("Capture succeeded: "+new FileInfo(file).Length+" bytes. Raw dump included only if ZIP budget permits; inspect size-budget.txt.");
            } catch(OperationCanceledException){throw;}
            catch(Exception e){evidence.AppendLine("Capture unavailable: "+e.GetType().Name+": "+e.Message+". If access is denied, run the troubleshooter at the same elevation as the game.");}
        }
        if(matched==0)evidence.AppendLine("Selected game is not running or its exact executable path could not be verified. No live dump captured. Leave the black-screen/frozen game open and collect again.");
        Add("hang/capture-status.txt",evidence.ToString(),-1);
        findings.AppendLine("Live hang capture details: hang/capture-status.txt. Missing captures are not evidence of a healthy game.");
    }
    // Windows Defender detections of OptiShade's files in the lookback window. The
    // Operational log may need administrator rights; an unreadable log is recorded,
    // not treated as clean.
    void Defender() {
        Stage("Checking Windows Security for blocked OptiShade files...");
        var b=new StringBuilder();int matched=0;
        try {
            long ms=(long)TimeSpan.FromHours(r.Hours).TotalMilliseconds;
            var query=new System.Diagnostics.Eventing.Reader.EventLogQuery("Microsoft-Windows-Windows Defender/Operational",System.Diagnostics.Eventing.Reader.PathType.LogName,
                "*[System[(EventID=1116 or EventID=1117) and TimeCreated[timediff(@SystemTime) <= "+ms+"]]]"){ReverseDirection=true};
            using(var reader=new System.Diagnostics.Eventing.Reader.EventLogReader(query)) {
                for(var e=reader.ReadEvent();e!=null&&matched<40;e=reader.ReadEvent()) using(e) {
                    cancel.ThrowIfCancellationRequested();
                    string text;try{text=e.FormatDescription()??"";}catch{text="";}
                    if(text.Length==0)text=String.Join(" ",e.Properties.Select(p=>Convert.ToString(p.Value)));
                    string path=Regex.Match(text,@"(?im)^\s*Path:\s*(.+?)\s*$").Groups[1].Value;
                    if(path.Length==0)path=Regex.Match(text,@"(?i)file:_([^;\r\n]+)").Groups[1].Value;
                    // Defender lists file:_, webfile:_ (with the download URL and its
                    // signed query) and process:_ resources; keep the file paths only.
                    var files=path.Split(';').Select(p=>p.Trim()).Where(p=>p.StartsWith("file:_",StringComparison.OrdinalIgnoreCase)).Select(p=>p.Substring(6)).ToList();
                    if(files.Count==0)files.Add(path.Split('|')[0].Trim());
                    // Localised descriptions can run the next fields onto the path
                    // (OSD-5E7M, German Windows); end each path at its file name.
                    files=files.Select(f=>{var m=Regex.Match(f,@"^.*?\.(?:exe|dll|asi|addon64|addon32|ini|json|zip|msi)\b",RegexOptions.IgnoreCase);return m.Success?m.Value:f;}).ToList();
                    path=String.Join("; ",files.Distinct(StringComparer.OrdinalIgnoreCase));
                    bool relevant=files.Any(f=>Verdicts.RelevantDefenderPath(f,r.Game));
                    if(!relevant)continue;
                    string threat=Regex.Match(text,@"(?im)^\s*Name:\s*(.+?)\s*$").Groups[1].Value;
                    string action=Regex.Match(text,@"(?im)^\s*Action:\s*(.+?)\s*$").Groups[1].Value;
                    b.AppendLine((e.TimeCreated??DateTime.MinValue).ToUniversalTime().ToString("o")+" | "+e.Id+" | Threat: "+threat+" | Path: "+path+" | Action: "+action);
                    matched++;
                }
            }
            b.Insert(0,"Windows Defender detections (events 1116/1117) of OptiShade, ReShade, OptiMFG or game-folder files in the last "+r.Hours+" hours: "+matched+". Other antivirus products are not read.\r\n");
        } catch(OperationCanceledException){throw;}
        catch(Exception e){b.Insert(0,"Windows Defender log unreadable ("+e.GetType().Name+": "+e.Message+"). Run the Troubleshooter as administrator to include it, or check Windows Security > Protection history yourself.\r\n");}
        Add("events/Defender.txt",b.ToString(),1);
    }
    // A launcher stub never loads proxy DLLs from its own folder (OSD-NXJ5).
    void GameExecutable() {
        var b=new StringBuilder("Executable: "+exePath+"\r\n");
        string leaf=Path.GetFileNameWithoutExtension(exePath);
        if(Regex.IsMatch(leaf,@"^(?i)FarmingSimulator20\d\d$")) {
            string target=Path.Combine(Path.GetDirectoryName(exePath),"x64",leaf+"Game.exe");
            if(File.Exists(target))b.AppendLine("StubTarget: "+target);
        }
        Add("checks/game-executable.txt",b.ToString(),1);
    }
    void Select() {
        if(!r.IncludeGameLogs&&!r.IncludeMfgLogs&&!r.IncludeLauncherLogs)throw new IOException("Select at least one diagnostic source.");
        if(r.IncludeGameLogs||r.IncludeMfgLogs) {
            r.Game=ResolveGameFolder(r.Game,r.Executable);
            if(r.Game==null)throw new IOException("Choose the actual game installation folder using Browse. For Xbox installs, choose the accessible game folder shown under Manage > Files.");
            exe=String.IsNullOrWhiteSpace(r.Executable)?Identity(r.Game):Path.GetFileName(r.Executable);
            exePath=String.IsNullOrWhiteSpace(r.Executable)?ExecutablePath(r.Game,exe):Path.GetFullPath(r.Executable);
            if(String.IsNullOrWhiteSpace(exe)||String.IsNullOrWhiteSpace(exePath)||!File.Exists(exePath)) throw new IOException("Choose a game folder with its main executable, or select the game's EXE directly.");
        } else {r.Game="";exe="Launcher";exePath="";}
    }
    // Check my setup: the same rules as a report over the light sources (logs,
    // settings, events, crash metadata). Nothing is packed, kept or sent; no dumps
    // or live capture are taken.
    public List<Finding> Check() {
        Select();checkOnly=true;
        string temporary=Path.Combine(Path.GetTempPath(),"OptiShade-Check-"+Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temporary);
        try {
            Logs();
            if(r.IncludeLauncherLogs)LauncherLogs();
            if(r.IncludeGameLogs){VrSessionTimeline();Hardware();Installation();Events();Defender();GameExecutable();Crashes(temporary);}
            Verdicts.Since=DateTime.UtcNow.AddHours(-r.Hours);
            return Verdicts.Analyze(items.Where(i=>i.Text!=null&&!i.Historical).Select(i=>new KeyValuePair<string,string>(i.Name,i.Text)));
        } finally { try{Directory.Delete(temporary,true);}catch{} }
    }
    public Result Run() {
        Select();
        long maxLimit=r.FullEvidence?MaxSentReportBytes:1000000000;
        if(r.Limit<1000000 || r.Limit>maxLimit) throw new ArgumentException("ZIP limit must be between 1 and "+(maxLimit/1000000)+" MB.");
        Directory.CreateDirectory(r.Output);
        string temporary=Path.Combine(Path.GetTempPath(),"OptiShade-Hang-"+Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temporary);
        try {
        if(r.IncludeGameLogs) {
            SavedHangs(temporary);
            if(r.CaptureLive)LiveHang(temporary);
        }
        Logs();
        if(r.IncludeLauncherLogs)LauncherLogs();
        if(r.IncludeGameLogs) {VrSessionTimeline(); Hardware(); Hashes(); Processes(); Installation(); VrRuntime(); Events(); Defender(); GameExecutable(); Crashes(temporary);}
        if(r.FullEvidence) RawEvidence(temporary);
        Item identity=items.FirstOrDefault(i=>i.Name=="logs/OptiShadeData_BuildIdentity.json.txt");
        string build=r.IncludeGameLogs?Verdicts.BuildLabel(identity==null?null:identity.Text):"not read (game logs not selected)";
        string verdicts,primary;
        try{
            Verdicts.Since=DateTime.UtcNow.AddHours(-r.Hours);
            var found=Verdicts.Analyze(items.Where(i=>i.Text!=null&&!i.Historical).Select(i=>new KeyValuePair<string,string>(i.Name,i.Text)));
            if(historical.Count>0)findings.AppendLine("Left out of the findings because they were not written in the last "+r.Hours+" h (still included under logs/ and raw/): "+String.Join(", ",historical)+".");
            verdicts=Verdicts.Format(found);primary=Verdicts.Primary(found);
        }
        catch(Exception e){verdicts="Verdict analysis failed: "+e.GetType().Name+": "+e.Message+"\r\n";primary="PRIMARY ISSUE: verdict analysis failed ("+e.GetType().Name+"); read the logs directly.";}
        string report="OPTISHADE TROUBLESHOOTER "+Version+"\r\nInstalled OptiShade build: "+build+"\r\n\r\n"+primary+"\r\n\r\nCaptured UTC: "+DateTime.UtcNow.ToString("o")+
            "\r\nSelected sources: "+String.Join(", ",new[]{r.IncludeGameLogs?"Game/OptiShade":"",r.IncludeMfgLogs?"OptiMFG":"",r.IncludeLauncherLogs?"Launcher/installer":""}.Where(s=>s.Length>0))+"\r\nGame executable: "+(String.IsNullOrWhiteSpace(exePath)?"not selected":exe)+"\r\nFolder: "+(String.IsNullOrWhiteSpace(r.Game)?"not selected":r.Game)+"\r\nProfile: "+r.Profile+"; full logs and raw dumps: "+(r.FullEvidence?"yes":"no")+"; ZIP byte cap: "+r.Limit+
            "\r\nLookback hours for events/dumps: "+r.Hours+"\r\n\r\nTESTER DESCRIPTION\r\n"+r.Notes+
            "\r\n\r\nVERDICTS\r\n"+verdicts+
            "\r\nOBSERVATIONS\r\n"+findings+
            "\r\nLIMITATIONS\r\nLogs may span earlier runs. Compare timestamps and installed hashes. No feature is verified by this collection. Missing data and truncation are listed in collection-manifest.txt and size-budget.txt. Older DLLs may not emit FGTRACE. Live thread/stack capture is attempted before other collection; this is not a full-memory dump. Capture and packaging failures are explicitly recorded. Running logs can change while read.\r\n"+
            "\r\nPRIVACY\r\n"+(r.FullEvidence?"Sent privately to the OptiShade developer; no copy is kept on this PC once it is sent. Original files under raw/ are byte-for-byte copies and are NOT redacted. ":"Share this archive privately with support. ")+(r.IncludeGameLogs?"Crash/hang dumps and memory text are NOT redacted and may contain credentials or other private content. ":"")+"Common user paths, emails and secret fields in the text logs outside raw/ are redacted on a best-effort basis. No unrelated documents or source files are collected; game files are not changed.\r\n";
        Add("ISSUE-DESCRIPTION.txt","USER-PROVIDED ISSUE DESCRIPTION\r\nGame executable: "+(String.IsNullOrWhiteSpace(exePath)?"not selected":exe)+"\r\nInstalled OptiShade build: "+build+"\r\n"+primary+"\r\n\r\n"+
            (String.IsNullOrWhiteSpace(r.Notes)?"No issue description provided.":r.Notes),-1);
        Add("REPORT.txt",report,-1);
        Add("collection-manifest.txt",ledger.ToString(),-1);
        Stage("Compressing and verifying the selected upload limit...");
        string gameToken=GameFileToken(String.IsNullOrWhiteSpace(exePath)?"OptiShade-Launcher.exe":exe);
        string stem=(r.AutomaticReport?"OptiShade-Hang-":"OptiShade-Tester-")+gameToken+(r.AutomaticReport?"-PID"+r.TargetPid:"")+"-"+DateTime.Now.ToString("yyyyMMdd-HHmmss")+"-"+Guid.NewGuid().ToString("N").Substring(0,6);
        string zip=Path.Combine(r.Output,stem+".zip");
        Pack(items,zip,r.Limit,cancel,progress);
        return new Result{Zip=zip,Report="REPORT.txt (inside ZIP)",Bytes=new FileInfo(zip).Length};
        } finally { Directory.Delete(temporary,true); }
    }
    public static void Pack(List<Item> entries,string path,long cap,CancellationToken token,Action<string> status=null) {
        string partial=path+".partial";
        var budget=new Item("size-budget.txt","Original collection windows are recorded in collection-manifest.txt.\r\n",-1);
        entries.Add(budget);
        try {
            for(int pass=0;pass<160;pass++) {
                token.ThrowIfCancellationRequested();
                bool overflow=false;
                try {
                using(var stream=new CappedFileStream(partial,cap))
                using(var zip=new ZipArchive(stream,ZipArchiveMode.Create)) {
                    foreach(Item item in entries) {
                        token.ThrowIfCancellationRequested();
                        if(item.BinaryPath!=null) {
                            using(var src=File.OpenRead(item.BinaryPath))
                            using(var dst=zip.CreateEntry(item.Name,CompressionLevel.Optimal).Open()) {
                                byte[] buffer=new byte[65536];int count;
                                while((count=src.Read(buffer,0,buffer.Length))>0){token.ThrowIfCancellationRequested();dst.Write(buffer,0,count);}
                            }
                            continue;
                        }
                        using(var writer=new StreamWriter(zip.CreateEntry(item.Name,CompressionLevel.Optimal).Open(),new UTF8Encoding(false))) {
                            if(item.DumpPath==null)writer.Write(item.Text);
                            else {
                                if(status!=null)status("Packing memory text: "+item.Name+" (budget pass "+(pass+1)+")...");
                                try{WriteMemory(item.DumpPath,item.DumpBytes,writer,token);}
                                catch(OperationCanceledException){throw;}
                                catch(ZipBudgetExceeded){throw;}
                                catch(Exception e){writer.WriteLine("\r\nMEMORY READ INCOMPLETE: "+e.GetType().Name+". Structured crash summary is retained.");}
                            }
                        }
                    }
                }
                } catch(ZipBudgetExceeded) {overflow=true;}
                if(!overflow && new FileInfo(partial).Length<=cap) {File.Move(partial,path);return;}
                File.Delete(partial);
                Item memory=entries.Where(i=>i.DumpPath!=null && i.DumpBytes>0).OrderByDescending(i=>i.DumpBytes).FirstOrDefault();
                if(memory!=null) {
                    memory.DumpBytes=memory.DumpBytes>65536?memory.DumpBytes/2:0;
                    budget.Text+="Memory byte budget for "+memory.Name+" reduced to "+memory.DumpBytes+" bytes. Summary retained; this is NOT a full dump export.\r\n";
                    continue;
                }
                Item binary=entries.LastOrDefault(i=>i.BinaryPath!=null);
                if(binary!=null) {
                    budget.Text+="Omitted entire raw hang dump "+binary.Name+" to meet ZIP cap. Structured summary retained; full thread/stack binary unavailable in this archive.\r\n";
                    entries.Remove(binary);continue;
                }
                Item cut=entries.Where(i=>i.Priority>=0 && i.Text.Length>2048).OrderByDescending(i=>i.Priority).ThenByDescending(i=>i.Text.Length).FirstOrDefault();
                if(cut==null) throw new IOException("Essential report exceeds the selected limit; no oversized ZIP was produced.");
                int keep=cut.Text.Length/2;
                cut.Text="[ZIP SIZE LIMIT: older text omitted; retained tail follows]\r\n"+cut.Text.Substring(cut.Text.Length-keep);
                budget.Text+="Reduced "+cut.Name+" to "+cut.Text.Length+" characters.\r\n";
            }
            throw new IOException("Could not meet ZIP size budget.");
        } finally {if(File.Exists(partial)) File.Delete(partial);}
    }
    public static void WriteMemory(string path,long budget,TextWriter writer,CancellationToken token) {
        using(var file=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read)) {
            long length=file.Length,remaining=Math.Min(length,budget),offset=0;
            writer.WriteLine("PRIVATE MEMORY TEXT: unredacted bytes; share privately with support.");
            writer.WriteLine("Original bytes: "+length+"; included byte budget: "+remaining);
            writer.WriteLine(remaining<length?"INCOMPLETE: size budget retains a leading byte window only. Use the separate structured summary for exception/module/stack evidence.":"FULL BYTE EXPORT");
            byte[] block=new byte[65536];char[] hex="0123456789ABCDEF".ToCharArray();
            while(remaining>0) {
                token.ThrowIfCancellationRequested();
                int count=file.Read(block,0,(int)Math.Min(block.Length,remaining));if(count==0)break;
                var batch=new StringBuilder(count*4);
                for(int i=0;i<count;i+=16) {
                    int n=Math.Min(16,count-i);batch.Append((offset+i).ToString("X16")).Append(" | ");
                    for(int j=0;j<n;j++){byte b=block[i+j];batch.Append(hex[b>>4]).Append(hex[b&15]).Append(' ');}
                    batch.Append("| ");for(int j=0;j<n;j++){byte b=block[i+j];batch.Append(b>=32&&b<127?(char)b:'.');}
                    batch.AppendLine();
                }
                writer.Write(batch.ToString());offset+=count;remaining-=count;
            }
            writer.WriteLine("Bytes actually exported: "+offset+"; omitted: "+(length-offset));
        }
    }
}
}

