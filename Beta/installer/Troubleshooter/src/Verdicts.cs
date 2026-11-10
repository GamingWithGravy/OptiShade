using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace OptiShade.TesterKit {
// Plain-language conclusions drawn from the captured text. Each rule names the
// evidence it used so support can check it; rules that find nothing stay silent.
public sealed class Finding {
    public int Severity;          // 1 = breaks the game or a feature, 2 = feature not working, 3 = degrades/blocks evidence, 4 = context
    public string Area;           // where the fix belongs
    public string Text;
    public readonly List<string> Details=new List<string>();
}
public static class Verdicts {
    public static string Build(IEnumerable<KeyValuePair<string,string>> captured) {return Format(Analyze(captured));}
    public static List<Finding> Analyze(IEnumerable<KeyValuePair<string,string>> captured) {
        var items=captured.Where(p=>p.Value!=null).ToList();
        var lines=new List<string>();
        lines.AddRange(GpuRemoval(Texts(items,"ReShade.log")));
        lines.AddRange(Crash(items));
        lines.AddRange(DriverTimeouts(Texts(items,"events/System"),SavedSessionStart(items)));
        lines.AddRange(UnexpectedRestart(Texts(items,"events/System"),SavedSessionStart(items)));
        lines.AddRange(OptiMfgCrash(Texts(items,"events/Application")));
        lines.AddRange(SwapchainResize(Texts(items,"ReShade.log")));
        lines.AddRange(DuplicateSwapchain(Texts(items,"OptiScaler.log")));
        // Collector names are mfg/OptiMFG-controller-*; OptiMFG's own export uses controller-*.
        lines.AddRange(Mfg(SessionControllers(items),Texts(items,"fps-"),Texts(items,"logs/Performance").Distinct()));
        lines.AddRange(NeuralStall(Texts(items,"logs/Performance")));
        lines.AddRange(NeuralFrameSkips(Texts(items,"logs/Performance").Distinct()));
        lines.AddRange(NeuralMemoryPause(Texts(items,"logs/Performance-current")));
        lines.AddRange(HelperLogOverwrite(Texts(items,"logs/Performance").Distinct()));
        lines.AddRange(NeuralOnGeneratedFrames(Texts(items,"controller-"),Texts(items,"logs/Performance").Distinct()));
        lines.AddRange(EffectsDepth(Texts(items,"OptiShadeData_ReShade.log")));
        lines.AddRange(NeuralThreadCost(Texts(items,"logs/Performance").Distinct()));
        lines.AddRange(NeuralFrameRate(Texts(items,"logs/Performance-current")));
        lines.AddRange(NeuralInputs(Texts(items,"dlss5-feed")));
        string lastSession=Texts(items,"LastSession.json").FirstOrDefault();
        lines.AddRange(NeuralSession(lastSession));
        lines.AddRange(MissingRuntimeLog(items));
        lines.AddRange(Manager(Texts(items,"Installer.log")));
        lines.AddRange(GlassCockpitNotDrawing(Texts(items,"glass-cockpit-dlss-fix.log"),Texts(items,"logs/Performance")));
        lines.AddRange(FixedMfgWithSimVsync(Texts(items,"UserCfg"),Texts(items,"OptiMFG-controller")));
        lines.AddRange(StreamlineCaughtCrash(Texts(items,"-sl-sha-"),JsonString(Texts(items,"LastSession.json").FirstOrDefault()??"","PID")));
        lines.AddRange(UseAfterUnload(Texts(items,"crashes/")));
        lines.AddRange(NrPlatformError(Texts(items,"Performance"),Texts(items,"Installer.log")));
        lines.AddRange(AtmosphereModInvolved(lines,Texts(items,"OptiShadeData_ReShade.log"),Texts(items,"crashes/"),Texts(items,"-stall.txt").Count>0));
        lines.AddRange(DefenderBlocks(Texts(items,"events/Defender"),Since));
        // Performance logs can retain several simulator runs. Bind memory trends to
        // the selected LastSession PID so an older, longer log cannot be diagnosed
        // as the current crash session.
        lines.AddRange(MemoryTrend(Texts(items,"logs/Performance").Distinct(),lastSession==null?null:JsonString(lastSession,"PID")));
        lines.AddRange(EffectsNotLoaded(Texts(items,"settings/OptiScaler.ini").FirstOrDefault(),Texts(items,"system/installed-hashes").FirstOrDefault()));
        lines.AddRange(WrongGameExecutable(Texts(items,"checks/game-executable").FirstOrDefault()));
        lines.AddRange(MfgBackendModule(Texts(items,"logs/Performance").Distinct()));
        lines.AddRange(DisplayAdapters(Texts(items,"system/hardware").FirstOrDefault()));
        lines.AddRange(InputHookNoise(Texts(items,"OptiScaler.log")));
        lines.AddRange(ForeignReShade(Texts(items,"ReShade.log")));
        lines.AddRange(VrHeadsetEffects(Texts(items,"ReShade.log")));
        lines.AddRange(HungInCrashHandler(Texts(items,"hang/").Concat(Texts(items,"-stall.txt"))));
        var findings=new List<Finding>();
        foreach(string line in lines) {
            if(line.StartsWith(" ",StringComparison.Ordinal)&&findings.Count>0){findings[findings.Count-1].Details.Add(line.Trim());continue;}
            var f=Classify(line);findings.Add(f);
        }
        // A game that stops itself (0x80000003) is the symptom; point at the trigger.
        var trigger=findings.FirstOrDefault(f=>f.Text.StartsWith("GPU REMOVAL",StringComparison.Ordinal))??findings.FirstOrDefault(f=>f.Text.StartsWith("SWAPCHAIN RESIZE FAILED",StringComparison.Ordinal));
        foreach(var f in findings.Where(f=>f.Text.StartsWith("CRASH in ",StringComparison.Ordinal)&&f.Text.Contains("0x80000003")&&f.Area.StartsWith("Game executable",StringComparison.Ordinal))) {
            if(trigger!=null){f.Area=trigger.Area;f.Details.Add("Trigger: "+trigger.Text.Split(':')[0]+" (below).");}
            else{f.Area="GPU crash cause not recorded: set [OPTISHADE] GpuCrashBreadcrumbs=1 in ReShade.ini, reproduce, collect again";}
        }
        // A capture from an older build: name the findings a later build already fixes.
        var identity=items.FirstOrDefault(p=>p.Key.IndexOf("BuildIdentity.json",StringComparison.OrdinalIgnoreCase)>=0);
        Match rebuild=Regex.Match(identity.Value==null?"":JsonString(identity.Value,"PrivateBuildLabel"),@"R(\d+)");
        if(rebuild.Success) {
            int built=Int32.Parse(rebuild.Groups[1].Value);
            // R330+ loads ReShade when LoadReShade is auto, so that ini no longer stops effects (OSD-T9B7).
            if(built>=330)findings.RemoveAll(f=>f.Text.StartsWith("IMAGE EFFECTS NOT LOADED",StringComparison.Ordinal));
            var fixedLater=FixedIn.Where(x=>x.Value>built&&findings.Any(f=>f.Text.StartsWith(x.Key,StringComparison.Ordinal))).ToList();
            if(fixedLater.Count>0)findings.Insert(0,new Finding{Severity=1,Area="Tester build is out of date: install the current build, then retest",
                Text="OLD BUILD R"+built+": "+String.Join("; ",fixedLater.Select(x=>x.Key+" is fixed in R"+x.Value))+". Retest on the current build before treating these as open bugs."});
        }
        // Stable: most severe first, rule order within a severity.
        return findings.Select((f,i)=>new{f,i}).OrderBy(x=>x.f.Severity).ThenBy(x=>x.i).Select(x=>x.f).ToList();
    }
    public static string Primary(List<Finding> findings) {
        var first=findings.FirstOrDefault(f=>f.Severity<=3);
        if(first==null)return "PRIMARY ISSUE: none detected. No known failure pattern matched this capture; read OBSERVATIONS and the logs.";
        return "PRIMARY ISSUE: "+first.Text+"\r\n  Fix area: "+first.Area;
    }
    public static string Format(List<Finding> findings) {
        if(findings.Count==0)return "No known failure pattern was matched. Read OBSERVATIONS and the logs below.\r\n";
        var b=new StringBuilder();
        foreach(var f in findings) {
            b.Append("- [S").Append(f.Severity).Append(" | ").Append(f.Area).Append("] ").Append(f.Text).Append("\r\n");
            foreach(string d in f.Details)b.Append("    ").Append(d).Append("\r\n");
        }
        b.Append("S1 breaks the game or a feature; S2 a feature is not working; S3 degraded or missing evidence; S4 context.\r\n");
        return b.ToString();
    }
    // First build that fixes a finding, by prefix. Add an entry when a fix ships.
    static readonly Dictionary<string,int> FixedIn=new Dictionary<string,int>(StringComparer.Ordinal){
        {"NR STUCK REBUILDING",301},
        {"RUNTIME LOG MISSING",304},
        {"NR BLOCKS THE GAME THREAD",306},
        {"NR FLICKER",308},
        {"RUNTIME LOG OVERWRITTEN",309},
        {"RUNTIME LOG EMPTIED",338},
        {"NR RAN ON GENERATED FRAMES",311},
        {"NR MEMORY ON/OFF LOOP",312},
        {"IMAGE EFFECTS DEPTH FLICKER",313},
        {"NR PARKED-MODEL LIMIT",315},
    };
    // Severity and the component that owns the fix, by finding prefix.
    static Finding Classify(string line) {
        var rules=new[]{
            new{Prefix="GPU REMOVAL",S=1,A="GPU crash: fix the component that owns the failing GPU operation named below"},
            new{Prefix="HISTORICAL CRASH",S=4,A="Earlier game crash; predates the selected process session"},
            new{Prefix="HISTORICAL SYSTEM RESTART",S=4,A="Earlier system restart; predates the selected process session"},
            new{Prefix="HISTORICAL DISPLAY EVENT",S=4,A="Earlier Windows display event; predates saved game session"},
            new{Prefix="GPU DRIVER EVENT",S=3,A="Display-driver event; timeout and cause not established"},
            new{Prefix="GPU DRIVER TIMEOUT",S=1,A="NVIDIA driver / GPU workload (TDR)"},
            new{Prefix="LOW SYSTEM MEMORY",S=1,A="System memory / page file (out-of-memory crash risk)"},
            new{Prefix="MEMORY GROWTH",S=3,A="Game process memory trend (not attributed): compare with OptiShade features off"},
            new{Prefix="VIDEO MEMORY OVER BUDGET",S=2,A="GPU memory headroom (game settings, NR working resolution)"},
            new{Prefix="IMAGE EFFECTS NOT LOADED",S=2,A="OptiScaler.ini lost OptiShade's LoadReShade=true (reset to OptiScaler defaults); R330 defaults it on"},
            new{Prefix="WRONG GAME EXE",S=1,A="Install location: OptiShade sits beside a launcher stub, not the rendering EXE (user action: reinstall beside the game EXE; R328 resolves it)"},
            new{Prefix="WINDOWS SECURITY DETECTION",S=1,A="Windows Security detection history (verify file origin and current protection status)"},
            new{Prefix="SWAPCHAIN RESIZE FAILED",S=1,A="Swapchain resize: release back buffers in ReShade/OptiScaler/NR before ResizeBuffers"},
            new{Prefix="GPU DEVICE LOST",S=1,A="GPU device lifetime"},
            new{Prefix="NR FLICKER",S=2,A="NR binding pool (DlssNr_Dx12 ReserveBatch): update to R308+, which grows the pool instead of skipping"},
            new{Prefix="NR PARKED-MODEL LIMIT",S=1,A="NR rebuild lifetime (DlssNr_Dx12 ParkNrFeature): update to R315+, which charges a parked model only with the game lists that could have recorded it"},
            new{Prefix="NR STUCK REBUILDING",S=1,A="NR rebuild lifetime (DlssNr_Dx12 rebuild wait)"},
            new{Prefix="NR RAN ON GENERATED FRAMES",S=2,A="TAA NR after frame generation (DlssNr_Taa.inl late route): update to R311+, which pauses it while the game's frame generation is generating"},
            new{Prefix="TAA NR PAUSED FOR FRAME GENERATION",S=4,A="TAA NR with frame generation (expected in R311+)"},
            new{Prefix="NR NOT COMPLETING FRAMES",S=2,A="NR rebuild/dispatch (DlssNr_Dx12): see the last wait reason"},
            new{Prefix="IMAGE EFFECTS DEPTH FLICKER",S=2,A="ReShade depth selection (generic_depth_addon on_begin_render_effects): update to R313+, which keeps the depth buffer steady"},
            new{Prefix="IMAGE EFFECTS DEPTH STILL CHANGING",S=2,A="ReShade depth selection (generic_depth_addon): depth buffer still switching or lost in R313+"},
            new{Prefix="NR MEMORY ON/OFF LOOP",S=2,A="NR memory guard (DlssNr_Dx12 admission/recovery): update to R312+, which keeps a running NR on and spaces retries"},
            new{Prefix="NR LOW VIDEO MEMORY",S=4,A="GPU memory headroom (NR kept running; stutter possible)"},
            new{Prefix="NR PAUSED FOR GPU MEMORY",S=2,A="GPU memory headroom: NR's memory guard (lower graphics memory use)"},
            new{Prefix="RUNTIME LOG OVERWRITTEN",S=3,A="Diagnostics coverage: OptiScaler loaded into an OptiShade helper (Store package DLL resolution)"},
            new{Prefix="SIMULATOR CRASH REPORT",S=1,A="Game crash (see CRASH and GPU findings)"},
            new{Prefix="GAME FROZE IN A CRASH HANDLER",S=1,A="Game crash hidden as a freeze: an in-process crash handler hung while writing its dump"},
            new{Prefix="IMAGE EFFECTS IN THE VR HEADSET",S=2,A="Image effects on the headset image (user setting: Link headset look to desktop / headset preset)"},
            new{Prefix="ANOTHER RESHADE LOADED FIRST",S=2,A="Install conflict: a separate ReShade in the game folder (user action: remove it, then Repair)"},
            new{Prefix="GLASS COCKPIT FIX NOT DRAWING",S=2,A="Glass Cockpit fix (third party): it skipped these frames and logged why; cockpit screens stay blurry on them"},
            new{Prefix="FIXED OPTIMFG WITH SIM VSYNC ON",S=3,A="Sim setting: turn VSync off in the sim, or set OptiMFG to Follow game"},
            new{Prefix="FRAME GENERATION PLUGIN USED AFTER UNLOAD",S=1,A="OptiMFG RTX 40 backend: the patched frame-generation plugin stays loaded while Streamline restarts its other plugins"},
            new{Prefix="NR COULD NOT START ON THIS DRIVER",S=2,A="NVIDIA driver too old for Neural Rendering (user action: update the driver)"},
            new{Prefix="NR COULD NOT START",S=2,A="NVIDIA refused to create Neural Rendering on this system (driver or GPU support)"},
            new{Prefix="FSLABS AIRCRAFT CRASH",S=1,A="FSLabs aircraft (third party) with OptiMFG: fly it with OptiMFG off"},
            new{Prefix="USE AFTER UNLOAD",S=1,A="A DLL was unloaded while another module still used it: see the modules named"},
            new{Prefix="STREAMLINE CAUGHT A CRASH IN AN EARLIER SESSION",S=3,A="Crash dumps from an earlier game process, not the session in this report"},
            new{Prefix="STREAMLINE CAUGHT A CRASH",S=1,A="Game crash hidden as a freeze: Streamline's crash handler wrote a dump and did not return; see the module named"},
            new{Prefix="ATMOSPHEREMOD LOADED",S=2,A="AtmosphereMod add-on (third party): retest with it uninstalled to separate it from OptiShade"},
            new{Prefix="OPTIMFG CRASHED",S=2,A="OptiMFG app (OptiMFG_Live.exe) crash: see the faulting module"},
            new{Prefix="PC RESTARTED UNEXPECTEDLY",S=1,A="Whole-system crash or power loss (hardware, overclock, power supply or kernel driver)"},
            new{Prefix="TWO SWAPCHAINS ALIVE",S=2,A="OptiScaler/Streamline swapchain tracking"},
            new{Prefix="OPTISCALER FG",S=2,A="OptiScaler frame generation setup"},
            new{Prefix="MFG: OptiMFG applied",S=2,A="User setting: enable Frame Generation in the game"},
            new{Prefix="MFG: the OptiMFG backend never loaded",S=2,A="OptiMFG provider loading (version.dll proxy / controller attach)"},
            new{Prefix="MFG BACKEND SNAPSHOT",S=3,A="OptiMFG provider loading: early module snapshot (not proof of a later load failure)"},
            new{Prefix="MFG PAUSED IN BACKGROUND",S=4,A="Game window focus (frame generation pauses in the background)"},
            new{Prefix="MFG LOW-FRAME-COUNT WHILE UNFOCUSED",S=4,A="Low Streamline frame count during an unfocused sample; not proof of a fault"},
            new{Prefix="MFG LOW-FRAME-COUNT INTERVAL",S=3,A="Low Streamline frames-since-query samples; compare query timing and measured output FPS"},
            new{Prefix="MFG LOW-FRAME-COUNT SAMPLE",S=3,A="Single low Streamline frames-since-query sample; not proof generation stopped"},
            new{Prefix="MFG PRESENTATION ACTIVITY",S=4,A="Streamline reports frames since its prior state query; displayed multiplier/cadence unverified"},
            new{Prefix="MFG DROPPED OUT",S=2,A="Reduced generated-frame count; cause not established"},
            new{Prefix="GAME FRAME RATE DROPPED WHILE NR ON",S=2,A="Frame-rate slowdown: cause not established by NR timing alone"},
            new{Prefix="MFG NOT GENERATING",S=2,A="OptiMFG backend / game DLSS-G frame presentation"},
            new{Prefix="MFG NOT REQUESTED",S=4,A="OptiMFG (no multiplier requested)"},
            new{Prefix="MFG LIMITED BY AN FPS CAP",S=2,A="Display refresh rate, VSync/G-SYNC or a frame limiter caps output; higher multipliers cannot raise FPS"},
            new{Prefix="FRAME GENERATION NEVER STARTED",S=1,A="DLSS Frame Generation was never initialised in this session, so no multiplier could take effect"},
            new{Prefix="MFG FOLLOW GAME",S=4,A="Game-controlled frame generation; no forced OptiMFG multiplier"},
            new{Prefix="MFG WORKING",S=4,A="OptiMFG (working)"},
            new{Prefix="MFG:",S=2,A="OptiMFG backend / game DLSS-G"},
            new{Prefix="NR BLOCKS THE GAME THREAD",S=2,A="NR TAA submission (DlssNr_Taa.inl): update to R306+, which no longer waits for the GPU"},
            new{Prefix="NR GAME-THREAD COST HIGH",S=2,A="NR performance (DlssNr_Taa.inl submission / NR model GPU cost)"},
            new{Prefix="NR GAME-THREAD COST",S=4,A="NR performance (normal)"},
            new{Prefix="NR DEPTH INPUT IS FLAT",S=2,A="NR depth input selection"},
            new{Prefix="X-PLANE NR NOT ADMITTED",S=2,A="XP12 Vulkan NR admission"},
            new{Prefix="NR SAVED ROUTE NOTE",S=4,A="Saved NR route note; active failure not established"},
            new{Prefix="NR LAST FAILURE",S=2,A="NR runtime"},
            new{Prefix="MANAGER",S=2,A="Manager (installer/updater UI)"},
            new{Prefix="RUNTIME LOG MISSING",S=3,A="Diagnostics coverage: OptiScaler log path"},
            new{Prefix="RUNTIME LOG EMPTIED",S=3,A="Diagnostics coverage: a second process that loaded OptiScaler restarted the game's log (Logger.cpp)"},
            new{Prefix="FPS NOT MEASURED",S=3,A="OptiMFG controller FPS measurement (PresentMon permissions)"},
            new{Prefix="INPUT HOOK THRASH",S=3,A="OptiScaler input window tracking"},
            new{Prefix="VIRTUAL DISPLAY ADAPTER",S=3,A="System configuration: test with the virtual display driver disabled"},
            new{Prefix="NR REBUILD RECOVERED",S=4,A="NR rebuild (recovered)"},
            new{Prefix="NR WAS SWITCHED OFF",S=4,A="User action"},
            new{Prefix="HYBRID GPU",S=4,A="System configuration"},
        };
        foreach(var r in rules)if(line.StartsWith(r.Prefix,StringComparison.Ordinal))return new Finding{Severity=r.S,Area=r.A,Text=line};
        if(line.StartsWith("CRASH in ",StringComparison.Ordinal))return new Finding{Severity=1,Area=CrashArea(line),Text=line};
        if(line.StartsWith("CRASH DUMP",StringComparison.Ordinal))return new Finding{Severity=1,Area="Game crash dump (no WER or simulator report; see modules near the fault)",Text=line};
        return new Finding{Severity=3,Area="Unclassified",Text=line};
    }
    // Which component owns a crashing module.
    static string CrashArea(string line) {
        string m=line.Substring(9).Split(new[]{' ',':'},2)[0].ToLowerInvariant();
        if(m.Contains("glass-cockpit"))return "Glass Cockpit add-on (third party, IFreemz)";
        if(m.StartsWith("reshade"))return "OptiShade ReShade runtime";
        if(m.StartsWith("optiscaler")||m=="winmm.dll"||m=="dxgi.dll"||m=="d3d12.dll"||m=="dbghelp.dll"||m=="version.dll"||m=="nvngx.dll")return "OptiShade loader / OptiScaler (proxy DLL in the game folder)";
        if(m.StartsWith("rtx40mfg")||m.StartsWith("rtxmfg")||m.StartsWith("optishademfg"))return "OptiMFG provider";
        if(m.StartsWith("nvngx_dlss"))return "NVIDIA DLSS runtime (check the pinned DLSS version)";
        if(m.StartsWith("sl."))return "NVIDIA Streamline";
        if(m.StartsWith("nvwgf2um")||m.StartsWith("nvlddmkm")||m.StartsWith("nvapi"))return "NVIDIA driver";
        if(m.StartsWith("vcruntime")||m.StartsWith("msvcp")||m=="ntdll.dll"||m=="kernelbase.dll")return "Caller of a system/C runtime routine (needs the crash dump stack)";
        if(m.EndsWith(".exe"))return "Game executable (see GPU and swapchain findings for the trigger)";
        return "Module "+m;
    }
    // Never let an older game's successful controller session describe the selected session.
    public static List<string> SessionControllers(List<KeyValuePair<string,string>> items) {
        string session=items.Where(p=>p.Key.IndexOf("LastSession.json",StringComparison.OrdinalIgnoreCase)>=0).Select(p=>p.Value).FirstOrDefault();
        string pid=JsonString(session??"","PID"),birth=JsonString(session??"","ProcessBirthFileTime");
        var logs=Texts(items,"controller-");
        if(String.IsNullOrEmpty(pid)||String.IsNullOrEmpty(birth))return logs;
        var json=new JavaScriptSerializer{MaxJsonLength=16*1024*1024};
        var rows=new List<KeyValuePair<double,string>>();
        foreach(string text in logs)foreach(string raw in text.Split('\n')) {
            if(!raw.TrimStart().StartsWith("{",StringComparison.Ordinal))continue;
            try {
                var entry=json.Deserialize<Dictionary<string,object>>(raw);object value;
                if(!entry.TryGetValue("pid",out value)||Convert.ToString(value,System.Globalization.CultureInfo.InvariantCulture)!=pid)continue;
                if(!entry.TryGetValue("backend_snapshot",out value))continue;
                var snapshot=value as Dictionary<string,object>;
                if(snapshot==null||!snapshot.TryGetValue("processBirth",out value)||Convert.ToString(value,System.Globalization.CultureInfo.InvariantCulture)!=birth)continue;
                rows.Add(new KeyValuePair<double,string>(Number(entry,"tick_ms"),raw));
            }catch{ }
        }
        return new List<string>{String.Join("\n",rows.OrderBy(p=>p.Key).Select(p=>p.Value).Distinct())};
    }
    static List<string> Texts(List<KeyValuePair<string,string>> items,string nameFragment) {
        return items.Where(p=>p.Key.IndexOf(nameFragment,StringComparison.OrdinalIgnoreCase)>=0).Select(p=>p.Value).ToList();
    }

    // "Rebuild R283 (1.0.77, stable)" from OptiShadeData/BuildIdentity.json.
    public static string BuildLabel(string buildIdentityText) {
        if(String.IsNullOrWhiteSpace(buildIdentityText))return "unknown (BuildIdentity.json not captured)";
        string label=JsonString(buildIdentityText,"PrivateBuildLabel"),version=JsonString(buildIdentityText,"Version"),channel=JsonString(buildIdentityText,"Channel");
        string text=String.IsNullOrEmpty(label)?"no R label recorded":label;
        var detail=new[]{version,channel}.Where(s=>!String.IsNullOrEmpty(s)).ToArray();
        return detail.Length>0?text+" ("+String.Join(", ",detail)+")":text;
    }
    static string JsonString(string text,string name) {
        Match m=Regex.Match(text,"\""+Regex.Escape(name)+"\"\\s*:\\s*\"([^\"]*)\"");
        return m.Success?m.Groups[1].Value:"";
    }

    static readonly Dictionary<string,string> ExceptionMeaning=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase){
        {"80000003","breakpoint: the game stopped itself on purpose, usually after a fatal GPU error"},
        {"c0000005","access violation: code read or wrote invalid memory"},
        {"c0000409","fail-fast: the process detected corruption and terminated"},
        {"c00000fd","stack overflow"},
        {"e06d7363","unhandled C++ exception"}
    };
    // WER Report.wer and Asobo crash reports. WER field names are localised,
    // so read the Sig[n].Value lines by index only.
    public static List<string> Crash(IEnumerable<KeyValuePair<string,string>> items) {
        var result=new List<string>();
        var seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var itemList=items.ToList();
        var sessionStart=SavedSessionStart(itemList);
        foreach(var item in itemList) {
            if(item.Key.IndexOf("crashes/WER-",StringComparison.OrdinalIgnoreCase)<0)continue;
            // Store apps (MoAppCrash) carry the package name as an extra signature before
            // the module; desktop APPCRASH/BEX reports start the module at Sig[3].
            int b=Regex.IsMatch(item.Value,@"(?m)^EventType=MoAppCrash\s*$")?4:3;
            string module=WerSig(item.Value,b),version=WerSig(item.Value,b+1),code=WerSig(item.Value,b+3),offset=WerSig(item.Value,b+4);
            if(String.IsNullOrEmpty(module)||String.IsNullOrEmpty(code))continue;
            string key=module+"|"+version+"|"+code+"|"+offset;
            if(!seen.Add(key))continue;
            DateTime? eventTime=WerEventTime(item.Value);
            if(sessionStart.HasValue&&eventTime.HasValue&&eventTime.Value<sessionStart.Value) {
                result.Add("HISTORICAL CRASH: Windows recorded "+module+(String.IsNullOrEmpty(version)?"":" "+version)+" at "+eventTime.Value.ToString("o")+", before the selected game session started at "+sessionStart.Value.ToString("o")+". It is not evidence that the current session hung for the same reason. Source: "+item.Key+".");
                continue;
            }
            string meaning;ExceptionMeaning.TryGetValue(code,out meaning);
            string line="CRASH in "+module+(String.IsNullOrEmpty(version)?"":" "+version)+": exception 0x"+code+(String.IsNullOrEmpty(offset)?"":" at offset 0x"+offset.TrimStart('0'))+(meaning==null?"":" ("+meaning+")")+". Source: "+item.Key+".";
            if(module.IndexOf("glass-cockpit",StringComparison.OrdinalIgnoreCase)>=0)line+=" The fault is inside the Glass Cockpit add-on itself; compare its version with the pinned copy in system/installed-hashes.txt.";
            result.Add(line);
        }
        foreach(var item in itemList) {
            if(item.Key.IndexOf("AsoboReport-Crash",StringComparison.OrdinalIgnoreCase)<0)continue;
            Match msg=Regex.Match(item.Value,"(?m)^Msg=\"([^\"]+)\"");
            if(!msg.Success)continue;
            Match time=Regex.Match(item.Value,"(?m)^TimeUTC=(\\S+)");
            Match gpu=Regex.Match(item.Value,"(?m)^GPUName=\"([^\"]+)\"");
            Match driver=Regex.Match(item.Value,"(?m)^DriverVersion=\"([^\"]+)\"");
            DateTime crashTime;
            if(sessionStart.HasValue&&time.Success&&DateTime.TryParse(time.Groups[1].Value,System.Globalization.CultureInfo.InvariantCulture,System.Globalization.DateTimeStyles.AdjustToUniversal|System.Globalization.DateTimeStyles.AssumeUniversal,out crashTime)&&crashTime<sessionStart.Value) {
                result.Add("HISTORICAL CRASH: the simulator report at "+crashTime.ToUniversalTime().ToString("o")+" predates the selected game session starting "+sessionStart.Value.ToString("o")+". It is not evidence that the current session hung for the same reason. Source: "+item.Key+".");
                continue;
            }
            result.Add("SIMULATOR CRASH REPORT: \""+msg.Groups[1].Value+"\""+(time.Success?" at "+time.Groups[1].Value:"")+(gpu.Success?" on "+gpu.Groups[1].Value:"")+(driver.Success?" (driver "+driver.Groups[1].Value+")":"")+". Source: "+item.Key+".");
        }
        // A session-matched dump with no WER or simulator report (OSD-2WR6: a
        // Streamline sl-sha dump only) is still a crash of the reported session.
        if(result.Count==0) {
            foreach(var item in itemList) {
                if(item.Key.IndexOf("crashes/",StringComparison.OrdinalIgnoreCase)<0||!item.Key.EndsWith(".dmp.txt",StringComparison.OrdinalIgnoreCase))continue;
                if(item.Value.IndexOf("Dump-to-session association: MATCHED",StringComparison.Ordinal)<0)continue;
                Match code=Regex.Match(item.Value,@"(?m)^Exception thread: \d+; code=0x([0-9A-Fa-f]{8})");
                Match where=Regex.Match(item.Value,@"(?m)^Exception address: (0x[0-9A-Fa-f]+) \(([^)]*)\)");
                if(!code.Success||!where.Success)continue;
                Match access=Regex.Match(item.Value,@"(?m)^Access violation: (read|write|execute) at (0x[0-9A-Fa-f]+)");
                var near=Regex.Matches(item.Value,@"(?m)^  \[RSP\+0x[0-9A-Fa-f]+\] 0x[0-9A-Fa-f]+ ([^\s+]+)\+").Cast<Match>().Select(x=>x.Groups[1].Value).Distinct(StringComparer.OrdinalIgnoreCase).Take(4).ToList();
                string meaning;ExceptionMeaning.TryGetValue(code.Groups[1].Value,out meaning);
                string line="CRASH DUMP for this session: exception 0x"+code.Groups[1].Value.ToLowerInvariant()+(meaning==null?"":" ("+meaning+")")+" at "+(where.Groups[2].Value=="unmapped"?where.Groups[1].Value+", an address that holds no loaded module":where.Groups[2].Value)+".";
                if(access.Success&&access.Groups[1].Value=="execute"&&where.Groups[2].Value=="unmapped")line+=" The game jumped into memory that holds no code: a stale function pointer, usually a hook, overlay or add-on that was unloaded or freed while still called.";
                if(near.Count>0)line+=" Modules on the stack (not an unwound call stack): "+String.Join(", ",near)+".";
                result.Add(line+" Source: "+item.Key+".");
                break;
            }
        }
        return result;
    }
    static DateTime? WerEventTime(string text) {
        Match m=Regex.Match(text??"",@"(?m)^EventTime=(\d+)");
        long fileTime;
        if(!m.Success||!Int64.TryParse(m.Groups[1].Value,out fileTime)||fileTime<=0)return null;
        try{return DateTime.FromFileTimeUtc(fileTime);}catch(ArgumentOutOfRangeException){return null;}
    }
    static string WerSig(string text,int index) {
        Match m=Regex.Match(text,@"(?m)^Sig\["+index+@"\]\.Value=(.*?)\s*$");
        return m.Success?m.Groups[1].Value.Trim():"";
    }

    // DXGI rejects ResizeBuffers with INVALID_CALL while anything still holds
    // a reference to the old back buffers. The game then usually loses the device.
    // ReShade also runs image effects on the VR headset image, by default with the
    // desktop preset (OSD-Z4XF: the full preset on a 9534x2688 stereo image, and
    // the game ran past its video-memory budget at ~10 fps).
    public static List<string> VrHeadsetEffects(IEnumerable<string> reshadeLogs) {
        var result=new List<string>();
        var ci=System.Globalization.CultureInfo.InvariantCulture;
        foreach(string text in reshadeLogs) {
            Match vr=Regex.Match(text,@"OptiShade output context: api=\d+ vr=1 width=(\d+) height=(\d+)");
            if(!vr.Success)continue;
            int compiled=Regex.Matches(text.Substring(vr.Index),"Successfully compiled").Count;
            if(compiled<10)continue;
            long w=long.Parse(vr.Groups[1].Value),h=long.Parse(vr.Groups[2].Value);
            result.Add("IMAGE EFFECTS IN THE VR HEADSET: ReShade runs image effects on the headset image at "+w+"x"+h+" ("+(w*h/1e6).ToString("0.0",ci)+" megapixels every frame, both eyes) and compiled "+compiled+" effect shaders for it. At that size each effect costs several times its desktop GPU time, and one full-size 16-bit colour texture alone takes "+(w*h*8/1048576)+" MiB of video memory, so a desktop preset can push the game past its video-memory budget and down to a low frame rate. On the Image effects page turn off \"Link headset look to desktop\" and give the headset a light preset (or no effects), then compare.");
            break;
        }
        return result;
    }

    // The player's own ReShade (often dxgi.dll) started first, so OptiShade's copy
    // stopped itself (OSD-59M6): two setups hook the game and OptiShade's effects
    // and add-ons do not run.
    public static List<string> ForeignReShade(IEnumerable<string> reshadeLogs) {
        var result=new List<string>();
        foreach(string text in reshadeLogs) {
            Match m=Regex.Match(text,@"Another ReShade instance was already loaded from '([^']+)'");
            if(!m.Success)continue;
            string name=Regex.Match(m.Groups[1].Value,@"[^\\/]+$").Value;
            result.Add("ANOTHER RESHADE LOADED FIRST: "+m.Groups[1].Value+" is a separate ReShade that started before OptiShade's, so OptiShade's ReShade stopped itself. OptiShade's image effects and add-ons do not run, and both setups hook the game. Remove the other ReShade with its own installer (or move "+name+" out of the game folder), then Repair OptiShade.");
            break;
        }
        return result;
    }

    // A thread inside Windows' dump writer (dbgcore) under a game or Streamline
    // crash handler: the game hit a fatal error and froze while saving its own
    // dump (OSD-59M6). The original fault is not in a hang capture.
    public static List<string> HungInCrashHandler(IEnumerable<string> captures) {
        var result=new List<string>();
        foreach(string text in captures) {
            foreach(Match block in Regex.Matches(text,@"(?m)^Thread (\d+): RIP=[^\r\n]*(?:\r?\n  candidate [^\r\n]*)+")) {
                var modules=Regex.Matches(block.Value,@"(?m)^  candidate \[RSP\+0x[0-9A-Fa-f]+\] 0x[0-9A-Fa-f]+ ([^\s+]+)\+").Cast<Match>().Select(x=>x.Groups[1].Value).ToList();
                int writer=modules.FindIndex(x=>x.Equals("dbgcore.dll",StringComparison.OrdinalIgnoreCase));
                if(writer<0||writer>3)continue;
                string caller=modules.Skip(writer).FirstOrDefault(x=>!Regex.IsMatch(x,@"(?i)^(dbgcore|dbghelp|ntdll|kernel32|KERNELBASE|ucrtbase|VCRUNTIME140|msvcp140)\.dll$"));
                if(caller==null)continue;
                result.Add("GAME FROZE IN A CRASH HANDLER: thread "+block.Groups[1].Value+" is inside Windows' crash-dump writer, called from "+caller+(caller.StartsWith("sl.",StringComparison.OrdinalIgnoreCase)?" (NVIDIA Streamline's crash handler)":"")+". The game hit a fatal error and froze while saving its own dump instead of closing, so this is a crash, not a slow load. The original error is not in this capture; check for a Streamline sl-sha dump or a crash report from the same time.");
                return result;
            }
        }
        return result;
    }

    public static List<string> SwapchainResize(IEnumerable<string> reshadeLogs) {
        var result=new List<string>();
        var failed=new List<string>();var removed=new List<string>();var holders=new List<string>();
        foreach(string text in reshadeLogs) foreach(string raw in text.Split('\n')) {
            string line=raw.Trim();
            if(line.IndexOf("ResizeBuffers",StringComparison.Ordinal)>=0&&line.IndexOf("DXGI_ERROR_INVALID_CALL",StringComparison.Ordinal)>=0)failed.Add(Stamp(line));
            else if(Regex.IsMatch(line,"(?i)DXGI_ERROR_DEVICE_(REMOVED|HUNG|RESET)"))removed.Add(Stamp(line));
            else if(line.IndexOf("Back buffer references held",StringComparison.Ordinal)>=0)holders.Add(line.Substring(Math.Max(0,line.IndexOf("Back buffer references held",StringComparison.Ordinal))));
        }
        failed=failed.Distinct().ToList();removed=removed.Distinct().ToList();
        if(failed.Count>0)result.Add("SWAPCHAIN RESIZE FAILED "+failed.Count+" time(s), last at "+failed.Last()+": DXGI_ERROR_INVALID_CALL means another component still held the old back buffers when the game resized. In MSFS this is the anti-aliasing switch (TAA/DLSS), and it is what leads to \"GPU Device Removed\".");
        foreach(string h in holders.Distinct().Take(6))result.Add("  "+h);
        if(failed.Count>0&&holders.Count==0)result.Add("  This build did not record which buffers were still referenced; builds with back-buffer reference logging add a \"Back buffer references held\" line here.");
        if(removed.Count>0)result.Add("GPU DEVICE LOST "+removed.Count+" time(s), last at "+removed.Last()+" (ReShade log).");
        return result;
    }
    static string Stamp(string line) {
        Match m=Regex.Match(line,@"^(\d{2}:\d{2}:\d{2}[:.]\d{3})");
        return m.Success?m.Groups[1].Value:"(no timestamp)";
    }

    public static List<string> DuplicateSwapchain(IEnumerable<string> optiscalerLogs) {
        var result=new List<string>();
        int notReleased=0,onlyOne=0,fgInit=0;
        foreach(string text in optiscalerLogs) {
            notReleased+=Count(text,"Host did not release swap-chain");
            onlyOne+=Count(text,"Streamline supports only one DXGISwapChain");
            fgInit+=Count(text,"Can't init FG Feature");
        }
        if(notReleased+onlyOne>0)result.Add("TWO SWAPCHAINS ALIVE: the game created a new swapchain while the old one was still held (Streamline: \"did not release swap-chain\" x"+notReleased+", \"supports only one DXGISwapChain\" x"+onlyOne+"). Frame generation only follows one, so FG and NR can break after this point.");
        if(fgInit>0)result.Add("OPTISCALER FG could not initialise on the new swapchain x"+fgInit+" (\"Can't init FG Feature or invalid FGOutput setting\").");
        return result;
    }
    static int Count(string text,string needle) {
        int n=0,i=0;
        while((i=text.IndexOf(needle,i,StringComparison.Ordinal))>=0){n++;i+=needle.Length;}
        return n;
    }

    // The controller's own backend snapshot says whether the game had frame
    // generation on and how many frames each present carried.
    public static List<string> Mfg(IEnumerable<string> controllerLogs,IEnumerable<string> fpsLogs,IEnumerable<string> performanceLogs=null) {
        var result=new List<string>();
        var json=new JavaScriptSerializer{MaxJsonLength=16*1024*1024};
        Dictionary<string,object> last=null,lastRequested=null,lastLive=null,lastLiveRequested=null;bool backendWait=false,multiple=false;
        int snapshots=0,notInitialised=0,setOptionsOk=0;double maxSetOptionsCalls=0,maxFgCreates=0;bool everOn=false;
        var fpsByMultiplier=new Dictionary<int,List<double>>();var framesByMultiplier=new Dictionary<int,List<double>>();var allFps=new List<double>();
        var drops=new DropoutTracker();
        foreach(string text in controllerLogs) foreach(string raw in text.Split('\n')) {
            string line=raw.Trim();
            if(!line.StartsWith("{",StringComparison.Ordinal))continue;
            if(line.IndexOf("menu-free backend to load",StringComparison.OrdinalIgnoreCase)>=0||line.IndexOf("menu-free RTX provider to load",StringComparison.OrdinalIgnoreCase)>=0)backendWait=true;
            if(line.IndexOf("multiple simulators found",StringComparison.OrdinalIgnoreCase)>=0)multiple=true;
            if(line.IndexOf("\"backend_snapshot\"",StringComparison.Ordinal)<0)continue;
            Dictionary<string,object> entry;
            try{entry=json.Deserialize<Dictionary<string,object>>(line);}catch{continue;}
            last=entry;
            var fgState=entry.ContainsKey("backend_snapshot")?entry["backend_snapshot"] as Dictionary<string,object>:null;
            if(fgState!=null&&fgState.ContainsKey("setOptionsResult")) {
                snapshots++;double code=Number(fgState,"setOptionsResult");if(code==21)notInitialised++;else if(code==0)setOptionsOk++;
                maxSetOptionsCalls=Math.Max(maxSetOptionsCalls,Number(fgState,"setOptionsCalls"));maxFgCreates=Math.Max(maxFgCreates,Number(fgState,"ngxFrameGenerationCreateCalls"));
                if(fgState.ContainsKey("gameFrameGenerationOn")&&fgState["gameFrameGenerationOn"] is bool&&(bool)fgState["gameFrameGenerationOn"])everOn=true;
                double measured=Number(entry,"presentation_fps");
                if(measured>0) {
                    allFps.Add(measured);
                    int applied=(int)Number(fgState,"appliedMultiplier");
                    bool on=fgState.ContainsKey("gameFrameGenerationOn")&&fgState["gameFrameGenerationOn"] is bool&&(bool)fgState["gameFrameGenerationOn"];
                    if(on&&applied>=2) {
                        if(!fpsByMultiplier.ContainsKey(applied)){fpsByMultiplier[applied]=new List<double>();framesByMultiplier[applied]=new List<double>();}
                        fpsByMultiplier[applied].Add(measured);framesByMultiplier[applied].Add(Number(fgState,"actualFramesPresented"));
                    }
                }
            }
            if(Number(entry,"backend_requested")>1)lastRequested=entry;
            if(TrackDropout(entry,drops)){lastLive=entry;if(Number(entry,"backend_requested")>1)lastLiveRequested=entry;}
        }
        foreach(var open in drops.ByPid.Values.Where(v=>v.Open!=null))drops.Episodes.Add(open.Open);
        // OSD-BJ9N: 2x, 3x and 4x were applied and the provider reported 2, 3 and 4 frames per
        // query, yet measured FPS stayed ~83 at every multiplier and never passed ~85 in any
        // session: the output is capped (refresh rate, VSync/G-SYNC with Reflex, or a limiter).
        {
            Func<List<double>,double> median=v=>{var o=v.OrderBy(x=>x).ToList();return o[o.Count/2];};
            var levels=fpsByMultiplier.Where(kv=>kv.Value.Count>=3).OrderBy(kv=>kv.Key).ToList();
            if(levels.Count>=2) {
                var low=levels.First();var high=levels.Last();
                double lowFps=levels.Take(levels.Count-1).Max(kv=>median(kv.Value)),highFps=median(high.Value),highFrames=median(framesByMultiplier[high.Key]);
                double ceiling=allFps.OrderBy(x=>x).ElementAt((int)Math.Min(allFps.Count-1,Math.Floor(allFps.Count*0.95)));
                bool generated=highFrames>=high.Key-0.5;
                bool flat=highFps<=lowFps*1.1&&highFps>=ceiling*0.9&&levels.Count(kv=>median(kv.Value)>=ceiling*0.9)>=2;
                if(generated&&flat) {
                    var ci=System.Globalization.CultureInfo.InvariantCulture;
                    var capped=levels.Where(kv=>median(kv.Value)>=ceiling*0.9).ToList();
                    string steps=String.Join(", ",capped.Select(kv=>kv.Key+"x ~"+Math.Round(median(kv.Value)).ToString(ci)+" fps"));
                    string rendered=String.Join(", ",capped.Select(kv=>kv.Key+"x ~"+Math.Round(median(kv.Value)/kv.Key).ToString(ci)));
                    // OSD-BJ9N: the cap was NVIDIA VSync "Adaptive (half refresh rate)" on a 165 Hz
                    // display (82.5 fps). Name it when the ceiling sits just under half a common rate.
                    int halfOf=new[]{120,144,155,160,165,170,175,180,200,240,270,280,300,360}.Where(hz=>ceiling>=hz/2.0*0.95&&ceiling<=hz/2.0*1.02).OrderBy(hz=>Math.Abs(hz/2.0-ceiling)).FirstOrDefault();
                    string halfHint=halfOf>0?" The ceiling matches half of a "+halfOf+" Hz display: check the NVIDIA app or control panel for VSync set to \"Adaptive (half refresh rate)\", which caps output at half the monitor's refresh rate (OSD-BJ9N: 165 Hz, 82 fps; turning it off gave 180 fps at 3x).":"";
                    result.Add("MFG LIMITED BY AN FPS CAP: OptiMFG applied each multiplier and the provider generated the extra frames ("+high.Key+"x reported "+highFrames.ToString(ci)+" frames per query), but from "+capped.First().Key+"x upward measured output stayed flat ("+steps+"). Output never rose above about "+Math.Round(ceiling).ToString(ci)+" fps in this session, so a display refresh rate, VSync/G-SYNC with Reflex, or a frame limiter (game, NVIDIA app or RTSS) is capping it. Under a cap a higher multiplier cannot raise FPS; it only lowers the rendered frame rate ("+rendered+" rendered fps) and adds latency. Check the monitor's refresh rate and the NVIDIA app's Max Frame Rate, VSync (including \"Adaptive (half refresh rate)\") and G-SYNC settings, or use the lowest multiplier that reaches the cap."+halfHint);
                }
            }
        }
        // OSD-ANRW/5TFC: Streamline answered every slDLSSGSetOptions with eErrorNotInitialized (21)
        // for the whole session, no frame-generation feature was created and the game never
        // turned FG on, so X2/X3/X4 in the sim had no effect. Normal sessions return 21 only
        // briefly at start-up, then eOk.
        if(snapshots>=10&&maxSetOptionsCalls>0&&notInitialised>0&&setOptionsOk==0&&!everOn&&maxFgCreates==0)
            result.Add("FRAME GENERATION NEVER STARTED: the game sent DLSS Frame Generation settings "+maxSetOptionsCalls+" time(s), but Streamline answered \"not initialised\" in every one of "+snapshots+" OptiMFG samples, and no frame-generation feature was ever created. Frame generation was off for the whole session, so any multiplier chosen in the game or OptiMFG had nothing to multiply. Check that OptiMFG and its RTX backend are up to date, then restart the game with frame generation enabled.");
        // Mid-session dropouts: the final snapshot alone hides a game that stopped generating and recovered.
        // A focused blip of a sample or two is usually a loading screen: DLSS stops
        // evaluating, so fps reads 0 (unmeasured), not a measured fall. Require 5 s
        // or a real measured drop.
        var real=drops.Episodes.Where(e=>e.EndTick-e.StartTick>=5000||(e.FpsBefore>0&&e.FpsMin>0&&e.FpsMin<e.FpsBefore*0.7)).ToList();
        if(real.Count>0) {
            var ci=System.Globalization.CultureInfo.InvariantCulture;
            int afterChange=real.Count(e=>e.RecoveredAfterChange),unrecovered=real.Count(e=>!e.Recovered&&!e.LostFocus);
            var worst=real.OrderByDescending(e=>e.EndTick-e.StartTick).First();
            result.Add("MFG LOW-FRAME-COUNT INTERVAL "+real.Count+" time(s) during play: with game FG on and "+worst.Applied+"x applied, the backend reported at most one frame since its previous state query across an interval lasting up to "+(long)((worst.EndTick-worst.StartTick)/1000)+" s; presentation "+(worst.FpsBefore>0&&worst.FpsMin<worst.FpsBefore?"fell from "+worst.FpsBefore.ToString("0",ci)+" to "+worst.FpsMin.ToString("0",ci)+" fps":"fps was not measured")+" while the game had focus. "+
                (afterChange>0?afterChange+" recovered only right after the multiplier was changed. ":"")+(unrecovered>0?unrecovered+" had not recovered when the log ended. ":"")+
                "This counter is frames presented since the prior DLSS-G state query, not frames per present. A low count is a diagnostic signal, not proof generation stopped; correlate query timing, measured FPS, loading, focus, dynamic mode and provider state in the same session.");
            if(performanceLogs!=null)result.AddRange(DropoutCause(real,performanceLogs));
        }
        if(drops.Background>0)result.Add("MFG LOW-FRAME-COUNT WHILE UNFOCUSED: "+drops.Background+" sample(s) with at most one frame reported since the previous state query coincided with another window having focus. This may be expected background behavior; the counter alone cannot prove generation stopped. Keep the game focused for a controlled performance comparison.");
        // A capture taken while the game is paused or in the background can report a low
        // number of frames since the previous state query;
        // judge the final state from the last snapshot where the game was still rendering.
        var chosen=lastLive??last;
        if(chosen!=null) {
            var snapshot=chosen.ContainsKey("backend_snapshot")?chosen["backend_snapshot"] as Dictionary<string,object>:null;
            double requested=Number(chosen,"backend_requested");
            double applied=snapshot==null?0:Number(snapshot,"appliedMultiplier");
            object gameOn=snapshot!=null&&snapshot.ContainsKey("gameFrameGenerationOn")?snapshot["gameFrameGenerationOn"]:null;
            double presented=snapshot==null?-1:Number(snapshot,"actualFramesPresented");
            bool follow=snapshot!=null&&snapshot.ContainsKey("followGame")&&snapshot["followGame"] is bool&&(bool)snapshot["followGame"];
            if(follow)result.Add("MFG FOLLOW GAME: OptiMFG is not forcing a multiplier. The selected snapshot reports game FG "+(gameOn is bool?((bool)gameOn?"on":"off"):"unknown")+" and "+presented+" frame(s) since the previous DLSS-G state query. This is sampled provider state, not a multiplier or proof of display cadence or the cause of jitter.");
            else if(requested<=1&&applied<=1)result.Add("MFG NOT REQUESTED: no multiplier was requested in the captured controller sessions (backend_requested="+requested+").");
            else if(gameOn is bool&&!(bool)gameOn)result.Add("MFG: OptiMFG applied "+applied+"x, but the game's own Frame Generation was OFF (gameFrameGenerationOn=false), the selected snapshot does not show generation. Earlier samples may differ. Turn on Frame Generation in the game's graphics settings.");
            else if(presented>=0&&presented<=1)result.Add("MFG LOW-FRAME-COUNT SAMPLE: "+applied+"x applied with game FG on; the backend reported "+presented+" frame(s) since its previous state query. This single sample does not prove generation is stopped.");
            else if(presented>1)result.Add("MFG PRESENTATION ACTIVITY: "+applied+"x applied; backend reported "+presented+" frames since its previous state query. This confirms provider activity in the sampled interval, not the displayed multiplier or cadence.");
        }
        if(backendWait&&chosen==null)result.Add("MFG: the OptiMFG backend never loaded into the game (controller kept waiting for the menu-free provider)."+(multiple?" The controller also saw more than one simulator process and could not pick one automatically.":""));
        int denied=fpsLogs.Count(t=>t.IndexOf("access denied",StringComparison.OrdinalIgnoreCase)>=0);
        if(denied>0)result.Add("FPS NOT MEASURED: PresentMon was denied access in "+denied+" OptiMFG fps log(s). It needs administrator rights or membership of the \"Performance Log Users\" group; presentation_fps=0 in the controller log means \"unmeasured\", not 0 fps.");
        return result;
    }
    // R307+ NR observation lines carry the same tick clock as the OptiMFG controller,
    // so each dropout can be placed against NR's own rebuilds and toggles.
    static List<string> DropoutCause(List<Dropout> dropouts,IEnumerable<string> performanceLogs) {
        var result=new List<string>();
        var ci=System.Globalization.CultureInfo.InvariantCulture;
        var offsets=new List<double>();var events=new List<KeyValuePair<double,string>>();bool off=false,observed=false;
        foreach(string text in performanceLogs) {
            bool? enabled=null;
            foreach(string raw in text.Split('\n')) {
                Match t=Regex.Match(raw,@"^\[(\d\d):(\d\d):(\d\d(?:\.\d+)?)\]");
                if(!t.Success)continue;
                if(raw.Contains("reason='it is switched off'"))off=true;
                if(raw.Contains("NR observation:"))observed=true;
                double ms=(Int32.Parse(t.Groups[1].Value)*3600+Int32.Parse(t.Groups[2].Value)*60+Double.Parse(t.Groups[3].Value,ci))*1000;
                Match o=Regex.Match(raw,@"NR observation: pid=\d+ tick=(\d+) .*enabled=(true|false)");
                if(o.Success){
                    offsets.Add(Double.Parse(o.Groups[1].Value,ci)-ms);
                    bool on=o.Groups[2].Value=="true";
                    if(enabled.HasValue&&enabled.Value!=on)events.Add(new KeyValuePair<double,string>(ms,"NR switched "+(on?"on":"off")));
                    enabled=on;continue;
                }
                if(raw.Contains("DLSS-NR rebuild waiting")||raw.Contains("DLSS-NR rebuild proceeding"))events.Add(new KeyValuePair<double,string>(ms,"an NR model rebuild"));
                else if(raw.Contains("Swapchain resize proceeding")||raw.Contains("DLSS-NR running "))events.Add(new KeyValuePair<double,string>(ms,"an NR model (re)creation"));
            }
        }
        if(!observed&&off){result.Add("  NR was switched off for this whole session, so NR did not cause these dropouts.");return result;}
        if(offsets.Count==0&&!performanceLogs.Any())return result; // OptiMFG-only export: no NR log to line up with.
        if(offsets.Count==0){result.Add("  This build's NR log has no tick clock, so dropouts cannot be lined up with NR events; R307 and later add it.");return result;}
        double offset=Median(offsets);
        int near=0;var named=new List<string>();
        foreach(var d in dropouts) {
            double at=d.StartTick-offset;
            // NR observations are 5 s apart: an NR change up to ~6 s before the dropout counts.
            var hit=events.Where(e=>e.Key<=at+1000&&e.Key>=at-6000).OrderBy(e=>Math.Abs(e.Key-at)).FirstOrDefault();
            if(hit.Value==null)continue;
            ++near;
            if(named.Count<3){var ts=TimeSpan.FromMilliseconds(at);named.Add(ts.ToString(@"hh\:mm\:ss")+" after "+hit.Value);}
        }
        result.Add("  "+near+" of "+dropouts.Count+" dropout(s) began within 6 s of an NR change"+(named.Count>0?" (e.g. "+String.Join("; ",named)+")":"")+". "+
            (near*2>dropouts.Count?"NR changes occurred nearby; timing correlation alone does not establish the trigger.":"Most samples had no NR change nearby. This does not rule out NR or establish another cause."));
        return result;
    }
    sealed class Dropout {
        public double StartTick,EndTick,FpsBefore,FpsMin,Applied;
        public bool Recovered,RecoveredAfterChange,LostFocus;
    }
    sealed class DropoutState {
        public double Presented=-1,Fps,LastRequestTick=-1;
        public Dropout Open;
    }
    sealed class DropoutTracker {
        public readonly Dictionary<double,DropoutState> ByPid=new Dictionary<double,DropoutState>();
        public readonly List<Dropout> Episodes=new List<Dropout>();
        public int Background;
    }
    // Per game process: a low state-query frame count following a higher count while
    // the game's FG is still on and a multiplier above 1 is applied. Returns false while
    // another window has focus: the game stops DLSS-G in the background, which is not a dropout.
    static bool TrackDropout(Dictionary<string,object> entry,DropoutTracker drops) {
        double pid=Number(entry,"pid"),tick=Number(entry,"tick_ms"),fps=Number(entry,"presentation_fps");
        DropoutState s;
        if(!drops.ByPid.TryGetValue(pid,out s)){s=new DropoutState();drops.ByPid[pid]=s;}
        string kind=entry.ContainsKey("event")?Convert.ToString(entry["event"]):"";
        if(kind=="backend_request_written")s.LastRequestTick=tick;
        var snapshot=entry.ContainsKey("backend_snapshot")?entry["backend_snapshot"] as Dictionary<string,object>:null;
        if(snapshot==null)return false;
        // Streamline defines this as frames presented since the previous GetState call,
        // not a per-present multiplier. Keep the interval wording conservative below.
        double presented=Number(snapshot,"actualFramesPresented"),applied=Number(snapshot,"appliedMultiplier");
        object gameOn=snapshot.ContainsKey("gameFrameGenerationOn")?snapshot["gameFrameGenerationOn"]:null;
        bool fgOn=gameOn is bool&&(bool)gameOn;
        // Older controllers have no foreground_pid: treat every sample as focused.
        double foreground=Number(entry,"foreground_pid");
        bool focused=foreground<=0||pid<=0||foreground==pid;
        if(!focused) {
            if(fgOn&&applied>1&&presented>=0&&presented<=1&&(s.Presented>1||s.Open!=null))drops.Background++;
            // Keep only the part of a dropout that happened while the game had focus.
            if(s.Open!=null){s.Open.LostFocus=true;drops.Episodes.Add(s.Open);s.Open=null;}
            s.Presented=-1;
            return false;
        }
        if(s.Open!=null) {
            if(fps>0&&fps<s.Open.FpsMin)s.Open.FpsMin=fps;
            s.Open.EndTick=tick;
            if(presented>1||!fgOn) {
                s.Open.Recovered=presented>1;
                s.Open.RecoveredAfterChange=s.Open.Recovered&&s.LastRequestTick>=s.Open.StartTick;
                drops.Episodes.Add(s.Open);s.Open=null;
            }
        } else if(fgOn&&applied>1&&presented>=0&&presented<=1&&s.Presented>1) {
            s.Open=new Dropout{StartTick=tick,EndTick=tick,FpsBefore=s.Fps,FpsMin=fps>0?fps:s.Fps,Applied=applied};
        }
        s.Presented=presented;
        if(fps<=0)fps=Number(snapshot,"dlssFpsMilli")/1000;
        if(fps>0)s.Fps=fps;
        return true;
    }
    static double Number(Dictionary<string,object> map,string name) {
        object value;
        if(map==null||!map.TryGetValue(name,out value)||value==null)return 0;
        try{return Convert.ToDouble(value,System.Globalization.CultureInfo.InvariantCulture);}catch{return 0;}
    }

    // A skip report repeats as "first occurrence" only after NR ran in between, so
    // many of them mean NR is alternating with no-NR frames: visible flicker.
    public static List<string> NeuralFrameSkips(IEnumerable<string> performanceLogs) {
        var result=new List<string>();
        int count=0;string first="",last="";
        foreach(string text in performanceLogs) foreach(string raw in text.Split('\n')) {
            Match m=Regex.Match(raw,@"^\[([0-9:]+)[^\]]*\].*DLSS-NR pass skipped: reason='(NR is waiting for its previous GPU recordings to retire|NR binding pool is full[^']*)' \(first occurrence");
            if(!m.Success)continue;
            if(count++==0)first=m.Groups[1].Value;last=m.Groups[1].Value;
        }
        if(count>=20)result.Add("NR FLICKER: NR skipped single frames "+count+" times between "+first+" and "+last+" because its binding slots were still held by command lists the game had not reset. Each skipped frame reaches the screen without NR, so the picture alternates between NR and no NR; frame generation repeats it across its generated frames.");
        return result;
    }

    // NR's memory guard pauses NR when the game leaves too little of the Windows
    // video-memory budget; on 8 GB cards this looks like NR randomly switching off.
    public static List<string> NeuralMemoryPause(IEnumerable<string> performanceLogs) {
        var result=new List<string>();
        int count=0,quick=0,warned=0;string first="",last="",plan="",warnedFirst="";double previous=-1;
        var ci=System.Globalization.CultureInfo.InvariantCulture;
        foreach(string text in performanceLogs) foreach(string raw in text.Split('\n')) {
            Match p=Regex.Match(raw,@"DLSS-NR memory plan: .*budget=([0-9]+) MiB usage=([0-9]+) MiB reserve=([0-9]+) MiB(?: required=([0-9]+) MiB)?");
            // Quote a check that actually failed, not the last one that passed. R312+ logs
            // what a rebuild still needs after crediting the models it replaces.
            string need=p.Success&&p.Groups[4].Success?p.Groups[4].Value:p.Success?p.Groups[3].Value:"";
            if(p.Success&&long.Parse(p.Groups[2].Value)+long.Parse(need)>long.Parse(p.Groups[1].Value))
                plan="the game used "+p.Groups[2].Value+" MiB of a "+p.Groups[1].Value+" MiB budget and NR needed "+need+" MiB more";
            Match t=Regex.Match(raw,@"^\[(\d\d):(\d\d):(\d\d(?:\.\d+)?)\]");
            bool resumed=raw.Contains("resumed after skip: reason='Paused: GPU memory pressure")||raw.Contains("resumed after skip: reason='Paused: video memory is almost full");
            Match m=Regex.Match(raw,@"^\[([0-9:]+)[^\]]*\].*DLSS-NR stopped: Paused: (?:GPU memory pressure|video memory is almost full)");
            // R320+: by default NR is built anyway and only this warning is logged.
            if(raw.Contains("NR starts anyway because Pause NR when video memory is low is off")){if(warned++==0)warnedFirst=t.Success?raw.Substring(1,8):"";continue;}
            if(!t.Success||(!m.Success&&!resumed))continue;
            double seconds=Int32.Parse(t.Groups[1].Value)*3600+Int32.Parse(t.Groups[2].Value)*60+Double.Parse(t.Groups[3].Value,ci);
            // Before R312 a stop came within moments of the previous stop or resume:
            // the retry did not wait for the memory a restart needs.
            // One check is logged once per output (OSD-Z4XF: two lines 8 ms apart);
            // that is the same stop, not a retry.
            if(m.Success&&previous>=0&&seconds-previous>=0&&seconds-previous<0.25){previous=seconds;continue;}
            if(m.Success&&previous>=0&&seconds-previous>=0&&seconds-previous<2.5)quick++;
            previous=seconds;
            if(!m.Success)continue;
            if(count++==0)first=m.Groups[1].Value;last=m.Groups[1].Value;
        }
        if(count>=3&&quick>0)result.Add("NR MEMORY ON/OFF LOOP: NR's memory guard stopped NR "+count+" time(s) between "+first+" and "+last+", "+quick+" of them within moments of the previous stop or restart"+(plan.Length>0?" (latest check: "+plan+")":"")+". Before R312 the guard stopped a running NR near the memory limit and retried before a restart had room, so NR switched on and off, which looks like flicker or NR not coming back. R312 keeps a running NR on and spaces retries out; the panel also offers Restart NR and Keep NR on when memory is low.");
        else if(count>0)result.Add("NR PAUSED FOR GPU MEMORY "+count+" time(s) between "+first+" and "+last+(plan.Length>0?" (latest check: "+plan+")":"")+". NR stays off until video memory frees up, so it looks as if NR stopped working. Lower texture resolution or other memory-heavy graphics settings, or the resolution, to give NR room. In R320+ this pause only happens when Pause NR when video memory is low is switched on (off by default).");
        if(warned>0)result.Add("NR LOW VIDEO MEMORY: NR was built "+warned+" time(s) with video memory nearly full"+(warnedFirst.Length>0?" (first at "+warnedFirst+")":"")+"; it kept running because Pause NR when video memory is low is off. If the tester reports stutter, lower memory-heavy graphics settings or turn that pause on.");
        return result;
    }

    // On the estimated TAA route NR runs at ReShade's present. When the game's own
    // frame generation is generating there, presents include generated frames, so
    // NR's rate tracks displayed frames instead of the game's real frames.
    public static List<string> NeuralOnGeneratedFrames(IEnumerable<string> controllerLogs,IEnumerable<string> performanceLogs) {
        var result=new List<string>();
        var ci=System.Globalization.CultureInfo.InvariantCulture;
        bool paused=false,beforeFg=false,preFgOn=false;string waiting=null,gate=null;
        var nr=new List<Tuple<long,long,long>>(); // pid, tick, frame
        foreach(string text in performanceLogs) foreach(string raw in text.Split('\n')) {
            if(raw.Contains("TAA NR paused: the game's frame generation is generating"))paused=true;
            if(raw.Contains("TAA NR ownership: validated native FG frame contract"))beforeFg=true;
            // R327+ says this while TAA NR before frame generation is on and waiting.
            if(raw.Contains("TAA NR runs before frame generation once the game's frame inputs are confirmed"))preFgOn=true;
            Match w=Regex.Match(raw,@"TAA native FG: (.+?); viewport=");
            if(w.Success)waiting=w.Groups[1].Value;
            Match g=Regex.Match(raw,@"TAA pre-FG gate: (.+?); signature=");
            if(g.Success)gate=g.Groups[1].Value;
            Match o=Regex.Match(raw,@"NR observation: pid=(\d+) tick=(\d+) .*route=estimated TAA .* frame=(\d+) ");
            if(o.Success)nr.Add(Tuple.Create(Int64.Parse(o.Groups[1].Value),Int64.Parse(o.Groups[2].Value),Int64.Parse(o.Groups[3].Value)));
        }
        // R327+: TAA NR runs before frame generation once the game's tagged frame
        // inputs validate; the pause covers only the frames before that.
        if(paused)result.Add("TAA NR PAUSED FOR FRAME GENERATION: the TAA fallback path logged a generation guard. This does not establish that the user selected TAA or that the separate DLSS NR path stopped. "+
            (beforeFg?"It then ran before frame generation on the game's validated frame inputs.":
             waiting!=null?"The captured TAA path did not confirm its frame inputs; last recorded reason: "+waiting+".":
             gate!=null?"TAA NR before frame generation never started; the last check that stopped it: "+gate+".":
             preFgOn?"TAA NR before frame generation was on but never started, and this build does not log which check stopped it (R330+ does). DLSS with NR combines NR and frame generation.":
             "TAA NR with frame generation was off or not in this build (R327+); use DLSS with NR to combine NR and frame generation."));
        if(nr.Count<2)return result;
        var json=new JavaScriptSerializer{MaxJsonLength=16*1024*1024};
        var samples=new List<Tuple<long,long,double,double>>(); // pid, tick, real fps, multiplier
        foreach(string text in controllerLogs) foreach(string raw in text.Split('\n')) {
            string line=raw.Trim();
            if(!line.StartsWith("{",StringComparison.Ordinal)||line.IndexOf("\"backend_snapshot\"",StringComparison.Ordinal)<0)continue;
            Dictionary<string,object> entry;
            try{entry=json.Deserialize<Dictionary<string,object>>(line);}catch{continue;}
            var b=entry.ContainsKey("backend_snapshot")?entry["backend_snapshot"] as Dictionary<string,object>:null;
            double pid=Number(entry,"pid"),foreground=Number(entry,"foreground_pid"),real=Number(b,"realFpsMilli")/1000;
            object fgOn;bool on=b!=null&&b.TryGetValue("gameFrameGenerationOn",out fgOn)&&fgOn is bool&&(bool)fgOn;
            if(pid<=0||(foreground>0&&foreground!=pid)||!on||Number(b,"actualFramesPresented")<2||real<=0)continue;
            samples.Add(Tuple.Create((long)pid,(long)Number(entry,"tick_ms"),real,Number(b,"appliedMultiplier")));
        }
        var nrRates=new List<double>();var realRates=new List<double>();var multipliers=new List<double>();
        for(int i=1;i<nr.Count;i++) {
            var a=nr[i-1];var c=nr[i];
            long dt=c.Item2-a.Item2,df=c.Item3-a.Item3;
            if(c.Item1!=a.Item1||dt<2000||dt>20000||df<=0)continue;
            var window=samples.Where(s=>s.Item1==c.Item1&&s.Item2>=a.Item2&&s.Item2<=c.Item2).ToList();
            if(window.Count==0)continue;
            double nrRate=df*1000.0/dt,real=Median(window.Select(s=>s.Item3).ToList());
            if(nrRate<real*1.5)continue;
            nrRates.Add(nrRate);realRates.Add(real);multipliers.Add(Median(window.Select(s=>s.Item4).ToList()));
        }
        if(nrRates.Count<3)return result;
        double nrMed=Median(nrRates),realMed=Median(realRates);
        result.Add("NR RAN ON GENERATED FRAMES: on the estimated TAA route NR processed ~"+nrMed.ToString("0",ci)+" frames/s while the game rendered ~"+realMed.ToString("0",ci)+" real frames/s with "+Median(multipliers).ToString("0",ci)+"x frame generation ("+nrRates.Count+" windows). NR ran after frame generation on generated frames too, at about "+(nrMed/realMed).ToString("0.0",ci)+"x its normal GPU work, which lowers the real frame rate and can flicker. R311 pauses TAA NR while the game's frame generation is generating.");
        return result;
    }

    // Image effects read the depth ReShade's depth add-on selects on each present. Before
    // R313 it chose afresh every present; with frame generation it kept losing or swapping
    // the buffer, and depth-based effects flickered. Older builds log only the misses.
    public static List<string> EffectsDepth(IEnumerable<string> reshadeLogs) {
        var result=new List<string>();
        int misses=0;long switched=0,lost=0;bool effects=false;string first="",last="";
        foreach(string text in reshadeLogs) foreach(string raw in text.Split('\n')) {
            if(raw.Contains("Successfully compiled"))effects=true;
            Match t=Regex.Match(raw,@"^(\d\d:\d\d:\d\d)");
            if(raw.Contains("OptiShade depth scan:")&&raw.Contains("no depth candidate was selected")){
                if(misses++==0&&t.Success)first=t.Groups[1].Value;if(t.Success)last=t.Groups[1].Value;
            }
            Match h=Regex.Match(raw,@"OptiShade depth selection: kept=\d+ switched=(\d+) lost=(\d+)");
            if(h.Success){switched+=Int64.Parse(h.Groups[1].Value);lost+=Int64.Parse(h.Groups[2].Value);}
        }
        if(!effects)return result;
        if(switched+lost>=10)result.Add("IMAGE EFFECTS DEPTH STILL CHANGING: the depth buffer image effects read switched "+switched+" time(s) and was lost "+lost+" time(s). Depth-based effects (fog, ambient occlusion, depth of field, depth-masked sharpening) can still flicker; note which effects are on.");
        else if(misses>=10)result.Add("IMAGE EFFECTS DEPTH FLICKER: image effects were on and ReShade had no depth buffer for them in "+misses+" checks between "+first+" and "+last+". The depth input kept dropping out or swapping between frames, so depth-based effects (fog, ambient occlusion, depth of field, depth-masked sharpening) flickered, especially with frame generation. R313 keeps the depth buffer steady.");
        return result;
    }

    // Store packages resolve the game's proxy DLL into child processes. Before R309
    // OptiScaler bootstrapped inside OptiMFG's PresentMon and restarted the log.
    public static List<string> HelperLogOverwrite(IEnumerable<string> performanceLogs) {
        var result=new List<string>();
        foreach(string text in performanceLogs) {
            Match m=Regex.Match(text,@"Game's Exe: ((?:PresentMon|OptiMFG_[A-Za-z]+|OptiShade[A-Za-z-]*)\.exe)");
            if(!m.Success)continue;
            result.Add("RUNTIME LOG OVERWRITTEN by "+m.Groups[1].Value+": OptiScaler started inside this helper and restarted Performance.log, so the game session's NR and frame evidence was lost. The saved session summary below is all that remains.");
            break;
        }
        return result;
    }

    // A resize rebuild waits until every GPU-use lease on the previous model is
    // retired. If the completed frame stops advancing, that wait never ends.
    public static List<string> NeuralStall(IEnumerable<string> performanceLogs) {
        var result=new List<string>();
        long longest=0;
        var observations=new List<KeyValuePair<long,long>>();var stamps=new List<string>();
        foreach(string text in performanceLogs) foreach(string raw in text.Split('\n')) {
            string line=raw.Trim();
            Match stall=Regex.Match(line,@"stall/skip: reason='Waiting for previous neural-rendering model work[^']*' repeats=\d+ duration_ms=(\d+)");
            if(stall.Success){long d=Int64.Parse(stall.Groups[1].Value);if(d>longest)longest=d;}
            Match obs=Regex.Match(line,@"^\[([0-9:.]+)\].*NR observation:.* frame=(\d+) completedFrame=(\d+)");
            if(obs.Success){observations.Add(new KeyValuePair<long,long>(Int64.Parse(obs.Groups[2].Value),Int64.Parse(obs.Groups[3].Value)));stamps.Add(obs.Groups[1].Value);}
        }
        // Frozen: the last completed frame repeats while the game frame keeps rising.
        int run=0;long frozenAt=-1;string frozenSince="";
        for(int i=observations.Count-1;i>0;i--) {
            if(observations[i].Value==observations[i-1].Value&&observations[i].Key>observations[i-1].Key&&observations[i].Value>0){run++;frozenAt=observations[i].Value;frozenSince=stamps[i-1];}
            else break;
        }
        if(run>=2||longest>=10000) {
            string line="NR STUCK REBUILDING: after a size, pass-count or swapchain change, NR waited for its previous GPU work to be retired before rebuilding";
            if(longest>0)line+=", for up to "+(longest/1000)+" s (normally well under a second)";
            line+=". NR shows no effect while this wait lasts.";
            if(run>=2)line+=" NR's completed frame stayed at "+frozenAt+" from "+frozenSince+" while the game kept rendering, so it never recovered; toggling NR off/on does not clear it, a game restart does.";
            result.Add(line);
        }
        // Builds with the bounded rebuild log why the wait lasted and whether it was released.
        string lastWait="",lastProceed="";bool limitReached=false;
        foreach(string text in performanceLogs) foreach(string raw in text.Split('\n')) {
            Match wait=Regex.Match(raw,@"DLSS-NR rebuild waiting (\d+) ms on previous model leases: (inFlight=\d+ finishedNotReset=\d+ unsubmitted=\d+ unresolved=\d+ unknown=\d+ deferredModels=\d+)");
            if(wait.Success&&raw.Contains("parked-model limit reached"))limitReached=true;
            if(wait.Success)lastWait="waited "+(Int64.Parse(wait.Groups[1].Value)/1000)+" s; pending leases "+wait.Groups[2].Value;
            Match go=Regex.Match(raw,@"DLSS-NR rebuild proceeding after (\d+) ms: (\d+) lease\(s\)");
            if(go.Success)lastProceed=go.Groups[2].Value+" idle lease(s) released the rebuild after "+(Int64.Parse(go.Groups[1].Value)/1000.0).ToString("0.0",System.Globalization.CultureInfo.InvariantCulture)+" s";
        }
        if(limitReached)result.Add("NR PARKED-MODEL LIMIT: repeated NR rebuilds (settings changes) each parked the previous model behind the same game command list, which the game never reset again; once 6 models were parked NR waited for good. Toggling NR does not clear it, a game restart does.");
        if(lastProceed.Length>0)result.Add("NR REBUILD RECOVERED: "+lastProceed+" (game never reset those command lists; old model kept parked).");
        if(lastWait.Length>0)result.Add("  Latest NR rebuild wait: "+lastWait+". inFlight = GPU still working; unsubmitted = game recorded but never executed the list; unresolved = submission could not be tracked.");
        return result;
    }

    // Time NR adds to the game's own render/main thread, and NR's GPU cost. R305 and
    // older TAA builds blocked that thread on the whole frame's GPU work every frame.
    public static List<string> NeuralThreadCost(IEnumerable<string> performanceLogs) {
        var result=new List<string>();
        var ci=System.Globalization.CultureInfo.InvariantCulture;
        var blocking=new List<double>();var gpu=new List<double>();
        string latest="";double latestAvg=0;int latestFrames=0,latestWaits=0;
        foreach(string text in performanceLogs) foreach(string raw in text.Split('\n')) {
            Match old=Regex.Match(raw,@"TAA NR synchronous frame cost: ([0-9.]+) ms");
            if(old.Success)blocking.Add(Double.Parse(old.Groups[1].Value,ci));
            Match now=Regex.Match(raw,@"TAA NR game-thread cost: avg ([0-9.]+) ms, max ([0-9.]+) ms over (\d+) frames; GPU waits ([0-9.]+) ms total on (\d+) frames; mode=(\w+)");
            // A window of a handful of frames is the model being built (about 95 ms each in VR),
            // not steady cost: judge the latest window with at least 20 frames.
            if(now.Success&&(Int32.Parse(now.Groups[3].Value)>=20||latestFrames<20)){latestAvg=Double.Parse(now.Groups[1].Value,ci);latestFrames=Int32.Parse(now.Groups[3].Value);latestWaits=Int32.Parse(now.Groups[5].Value);
                latest="avg "+now.Groups[1].Value+" ms, max "+now.Groups[2].Value+" ms over "+latestFrames+" frames, "+now.Groups[6].Value+" mode, waited for the GPU on "+latestWaits+" frame(s)";}
            Match g=Regex.Match(raw,@"NR observation:.* completed=true .*gpuMs=([0-9.]+)");
            if(g.Success)gpu.Add(Double.Parse(g.Groups[1].Value,ci));
        }
        string gpuText=gpu.Count>0?" NR's own GPU time is "+Median(gpu).ToString("0.0",ci)+" ms per frame (median of "+gpu.Count+" samples).":"";
        // The first sample of a session includes model creation; the median ignores it.
        if(blocking.Count>0) {
            double med=Median(blocking),max=blocking.Max();
            if(med>=1.0)result.Add("NR BLOCKS THE GAME THREAD: this build's TAA NR waits on the CPU for the whole frame's GPU work before the game can continue, "+med.ToString("0.0",ci)+" ms per frame (median of "+blocking.Count+" samples, max "+max.ToString("0",ci)+" ms). That time is added directly to the game's main/render thread, which is why disabling NR restores performance. R306 and later submit TAA NR without waiting."+gpuText);
        } else if(latest.Length>0) {
            bool gpuBound=latestFrames>0&&latestWaits*10>latestFrames;
            if(latestFrames>=20&&(latestAvg>=2.0||gpuBound))result.Add("NR GAME-THREAD COST HIGH: "+latest+"."+(gpuBound?" The GPU is three frames behind, so the GPU (game plus NR) is the bottleneck, not NR's CPU work.":" NR's CPU recording itself is slow.")+gpuText);
            else result.Add("NR GAME-THREAD COST: "+latest+"."+gpuText);
        }
        return result;
    }
    // Rendered frame rate from consecutive NR observations (frame counter per wall time).
    // A sustained drop while NR's own GPU time is unchanged means the slowdown is elsewhere.
    public static List<string> NeuralFrameRate(IEnumerable<string> performanceLogs) {
        var result=new List<string>();
        var ci=System.Globalization.CultureInfo.InvariantCulture;
        var samples=new List<Tuple<string,double,double>>(); // time, fps, nr gpu ms
        foreach(string text in performanceLogs) {
            double prevSec=-1,prevFrame=-1;
            foreach(string raw in text.Split('\n')) {
                Match o=Regex.Match(raw,@"^\[(\d\d):(\d\d):(\d\d(?:\.\d+)?)\].*NR observation:.* frame=(\d+) .*enabled=(true|false).*?gpuMs=(-?[0-9.]+)");
                if(!o.Success)continue;
                double sec=Int32.Parse(o.Groups[1].Value)*3600+Int32.Parse(o.Groups[2].Value)*60+Double.Parse(o.Groups[3].Value,ci),frame=Double.Parse(o.Groups[4].Value,ci),gpuMs=Double.Parse(o.Groups[6].Value,ci);
                if(prevSec>=0&&sec>prevSec&&sec-prevSec<=12&&frame>=prevFrame&&o.Groups[5].Value=="true"&&gpuMs>0)
                    samples.Add(Tuple.Create(o.Groups[1].Value+":"+o.Groups[2].Value+":"+o.Groups[3].Value.Split('.')[0],(frame-prevFrame)/(sec-prevSec),gpuMs));
                prevSec=sec;prevFrame=frame;
            }
        }
        if(samples.Count<8)return result;
        double fpsMed=Median(samples.Select(x=>x.Item2).ToList()),gpuMed=Median(samples.Select(x=>x.Item3).ToList());
        // Longest run of samples well below the session's NR-on median.
        int bestStart=-1,bestLen=0;
        for(int i=0;i<samples.Count;) {
            if(samples[i].Item2>=fpsMed*0.65){i++;continue;}
            int j=i;while(j<samples.Count&&samples[j].Item2<fpsMed*0.65)j++;
            if(j-i>bestLen){bestLen=j-i;bestStart=i;}
            i=j;
        }
        if(bestLen<3)return result;
        var run=samples.Skip(bestStart).Take(bestLen).ToList();
        double low=Median(run.Select(x=>x.Item2).ToList()),runGpu=Median(run.Select(x=>x.Item3).ToList());
        if(runGpu>gpuMed*1.4)return result; // NR itself got slower; NR GPU findings cover that
        result.Add("GAME FRAME RATE DROPPED WHILE NR ON: the game rendered ~"+low.ToString("0",ci)+" fps from "+run.First().Item1+" to "+run.Last().Item1+" against ~"+fpsMed.ToString("0",ci)+" fps for the rest of the NR session, while NR's own GPU time stayed at "+runGpu.ToString("0.0",ci)+" ms (session median "+gpuMed.ToString("0.0",ci)+" ms). These samples do not identify the bottleneck. CPU/scenery load, memory pressure, other GPU work, frame generation, focus changes or presentation timing may contribute; NR GPU time alone cannot distinguish them.");
        return result;
    }
    static double Median(List<double> values) {
        var s=values.OrderBy(v=>v).ToList();
        return s.Count%2==1?s[s.Count/2]:(s[s.Count/2-1]+s[s.Count/2])/2;
    }

    public static List<string> NeuralInputs(IEnumerable<string> feedLogs) {
        var result=new List<string>();
        int flat=feedLogs.Sum(t=>Count(t,"sampled depth is flat"));
        if(flat>0)result.Add("NR DEPTH INPUT IS FLAT in "+flat+" depth probe(s) (min=max=0). NR without valid depth will ghost or flicker; check the depth buffer selection for this game.");
        return result;
    }

    // ReShade's device-removal watcher (R305+) quotes the reason and DRED data.
    public static List<string> GpuRemoval(IEnumerable<string> reshadeLogs) {
        var result=new List<string>();
        string reason="";var details=new List<string>();bool noDred=false;
        foreach(string text in reshadeLogs) foreach(string raw in text.Split('\n')) {
            int at=raw.IndexOf("OptiShade GPU removal: ",StringComparison.Ordinal);
            if(at<0)continue;
            string body=raw.Substring(at+23).Trim();
            Match r=Regex.Match(body,@"^device removed, reason (\S+?)\.?$");
            if(r.Success){reason=r.Groups[1].Value+" (at "+Stamp(raw.Trim())+")";details.Clear();noDred=false;continue;}
            if(body.StartsWith("no DRED data",StringComparison.Ordinal)){noDred=true;continue;}
            if(body.StartsWith("unfinished command list",StringComparison.Ordinal)||body.StartsWith("page fault",StringComparison.Ordinal)||body.StartsWith("DRED recorded",StringComparison.Ordinal))details.Add(body);
        }
        if(reason.Length==0)return result;
        string meaning=reason.StartsWith("DXGI_ERROR_DEVICE_HUNG")?" — the GPU took too long on submitted work (often an endless shader or a wait that never signals)":
                       reason.StartsWith("DXGI_ERROR_DEVICE_RESET")?" — a badly formed command reset the device":
                       reason.StartsWith("DXGI_ERROR_DRIVER_INTERNAL_ERROR")?" — the driver failed internally":
                       reason.StartsWith("DXGI_ERROR_DEVICE_REMOVED")?" — the device was removed (driver crash/TDR or page fault)":"";
        result.Add("GPU REMOVAL: device removed with "+reason+meaning+".");
        foreach(string d in details.Distinct().Take(10))result.Add("  "+d);
        if(noDred||details.Count==0)result.Add("  No DRED breadcrumbs were recorded. To name the failing GPU operation: set [OPTISHADE] GpuCrashBreadcrumbs=1 in the game's ReShade.ini, reproduce, then collect again.");
        return result;
    }

    // The Glass Cockpit fix logs running totals and why it skipped a frame. Blurry
    // cockpit screens (OSD-Q5M2, HK6M, STR2) were the fix not drawing, not a setting.
    public static List<string> GlassCockpitNotDrawing(IEnumerable<string> logs,IEnumerable<string> performanceLogs=null) {
        var result=new List<string>();
        var performance=(performanceLogs??Enumerable.Empty<string>()).ToList();
        foreach(string text in logs) {
            var stats=Regex.Matches(text,@"(?m)^\S+ stats overlay=(\d+).*?dlss_calls=(\d+) dlss_upscales=(\d+).*?overlay_frames=(\d+) skipped=(\d+)");
            if(stats.Count==0||text.Contains("(fixture=1"))continue;
            Match last=stats[stats.Count-1];
            long enabled=long.Parse(last.Groups[1].Value),calls=long.Parse(last.Groups[2].Value),frames=long.Parse(last.Groups[4].Value),skipped=long.Parse(last.Groups[5].Value);
            bool nothing=calls==0&&Regex.Matches(text,"cost frames=").Count>=6;
            bool neverDrew=frames==0&&skipped>=120;
            bool mostly=frames>0&&skipped>frames;
            if(enabled==0||!(nothing||neverDrew||mostly))continue;
            var reasons=Regex.Matches(text,@"skip reason=(\w+)").Cast<Match>().Select(m=>m.Groups[1].Value).Distinct().Take(4).ToList();
            bool notNvidia=text.Contains("note not an NVIDIA GPU");
            bool hookChanged=Regex.IsMatch(text,@"(?i)evaluate hook was changed by another mod");
            Match dlssOwner=Regex.Match(text,@"(?i)DLSS answered by another mod:\s*(?<owner>[^\s]+)");
            bool optiWinmm=performance.Any(p=>Regex.IsMatch(p,@"(?i)OptiScaler working as winmm\.dll"));
            bool amdAdapter=performance.Any(p=>Regex.IsMatch(p,@"(?i)Adapter Desc:\s*AMD"));
            bool nvidiaAdapter=performance.Any(p=>Regex.IsMatch(p,@"(?i)Adapter Desc:\s*NVIDIA GeForce"));
            string cause="";
            if(hookChanged&&dlssOwner.Success&&optiWinmm) {
                cause="The Glass Cockpit log says "+dlssOwner.Groups["owner"].Value+" answered DLSS and its evaluate hook was changed; this session's Performance log confirms OptiScaler was running through its WinMM route, so the two DLSS hooks conflict. ";
                if(notNvidia&&amdAdapter&&nvidiaAdapter)cause+="It first reported no NVIDIA GPU while the simulator created an AMD D3D12 device, then later created an NVIDIA GeForce device, which points to early adapter selection as well. ";
                else if(notNvidia)cause+="The early 'not an NVIDIA GPU' message may reflect adapter selection before the active NVIDIA device was ready. ";
                cause+="This is an integration/initialization-order finding, not evidence that the cockpit add-on is missing. ";
            } else if(notNvidia)cause+="The add-on reported \"not an NVIDIA GPU\"; verify the simulator is assigned to the high-performance NVIDIA GPU. ";
            result.Add("GLASS COCKPIT FIX NOT DRAWING: "+(nothing?"it received no DLSS calls this session":neverDrew?"it skipped all "+skipped+" frames it was given":"it skipped "+skipped+" frames and drew "+frames)+(reasons.Count>0?" (reasons: "+string.Join(", ",reasons)+")":"")+". "+cause+"Cockpit screens stay blurry on those frames. Check that the sim's anti-aliasing is set to DLSS; if the WinMM hook conflict remains, send this report to OptiShade and the Glass Cockpit fix developer.");
            break;
        }
        return result;
    }
    // The sim's VSync presents at interval 2. Across 14 reports with OptiMFG in Fixed
    // mode, all 5 with interval 2 had VSync 1 and stayed near 40 fps, mostly presenting
    // one frame; all 9 with interval 0 generated normally. Follow game was fine in both.
    public static List<string> FixedMfgWithSimVsync(IEnumerable<string> simSettings,IEnumerable<string> controllers) {
        var result=new List<string>();
        if(!simSettings.Any(t=>Regex.IsMatch(t,@"(?m)^\s*VSync\s+1\b")))return result;
        int rows=controllers.Sum(t=>Regex.Matches(t,"\"appliedMode\":\"fixed\"").Count);
        if(rows<5)return result;
        result.Add("FIXED OPTIMFG WITH SIM VSYNC ON: OptiMFG ran in Fixed mode for "+rows+" samples with VSync on in the sim. In every report with this combination, frame rate stayed near 40 fps instead of multiplying. Turn VSync off in the sim, or use Follow game.");
        return result;
    }
    // NVIDIA's NR feature returns FAIL_PlatformError (0xBAD00002) when the system
    // cannot run it, typically a driver older than the model needs. OSD-4FS4: RTX 3060
    // on driver 560.94 in 7 Days to Die, while the launcher recommended 616.92.
    public static List<string> NrPlatformError(IEnumerable<string> runtimeLogs,IEnumerable<string> launcherLogs) {
        var result=new List<string>();
        int failures=runtimeLogs.Sum(t=>Regex.Matches(t,@"DLSS-NR create failed: [^\r\n]*0xBAD00002").Count);
        if(failures==0)return result;
        Match driver=null;
        foreach(string t in launcherLogs){var m=Regex.Matches(t,@"Driver ([0-9]+\.[0-9]+) detected for ([^.]+?)\. Compatibility with this driver is unknown\. Please update to ([0-9]+\.[0-9]+)");if(m.Count>0)driver=m[m.Count-1];}
        if(driver!=null)result.Add("NR COULD NOT START ON THIS DRIVER: NVIDIA refused to create Neural Rendering "+failures+" time(s) (FAIL_PlatformError) on "+driver.Groups[2].Value+" with driver "+driver.Groups[1].Value+". OptiShade recommends "+driver.Groups[3].Value+" or newer. Update the NVIDIA driver, then try NR again.");
        else result.Add("NR COULD NOT START: NVIDIA refused to create Neural Rendering "+failures+" time(s) (FAIL_PlatformError). Update the NVIDIA driver; if it continues, the GPU or this game's rendering path is not supported.");
        return result;
    }
    // A crash that reads or runs inside a DLL the process had already unloaded.
    // OSD-ASBJ and OSD-PC48: NVIDIA's frame-generation plugin (patched and kept
    // loaded by OptiMFG's RTX 40 backend) read a pointer into another Streamline
    // plugin that had been unloaded and reloaded at a new address.
    public static List<string> UseAfterUnload(IEnumerable<string> dumps) {
        var result=new List<string>();
        var hits=new List<string>();bool optiMfg=false,streamline=true;
        foreach(string text in dumps) {
            var gone=Regex.Match(text,@"(?m)^(?:Access violation target|Exception address) is inside an UNLOADED module: ([^\s+]+)\+");
            if(!gone.Success)continue;
            var at=Regex.Match(text,@"(?m)^Exception address: 0x[0-9A-Fa-f]+ \(([^+)\s]+)");
            string crashed=at.Success?at.Groups[1].Value:"unknown";
            hits.Add(crashed+" -> "+gone.Groups[1].Value);
            optiMfg|=Regex.IsMatch(text,@"(?m)^RTX40MFGCore\.dll base=");
            streamline&=Regex.IsMatch(crashed,@"(?i)^(190_[0-9A-F]+\.dll|sl\..+|nvngx.*)$")&&Regex.IsMatch(gone.Groups[1].Value,@"(?i)^(190_[0-9A-F]+\.dll|sl\..+|nvngx.*)$");
        }
        if(hits.Count==0)return result;
        string summary=String.Join(", ",hits.GroupBy(h=>h).Select(g=>g.Count()+" x "+g.Key));
        // OSD-D8G7: the FSLabs A321's gauge code called FSLabs' interface module after
        // the sim had unloaded it, only with OptiMFG installed. FSLabs' protection is
        // strict about other software patching the sim, so this is named for what it is.
        if(hits.Any(h=>Regex.IsMatch(h,@"-> FSL_",RegexOptions.IgnoreCase))){
            result.Add("FSLABS AIRCRAFT CRASH: "+summary+". The aircraft's own code ran after FSLabs' interface module was unloaded while the aircraft loaded."+(optiMfg?" OptiMFG was loaded; the tester reports the aircraft loads without it. Turn OptiMFG off (or use Follow game with OptiMFG uninstalled) when flying FSLabs aircraft, and report it to FSLabs.":" Report it to FSLabs with this dump."));
            return result;
        }
        if(streamline&&optiMfg)result.Add("FRAME GENERATION PLUGIN USED AFTER UNLOAD: "+summary+". NVIDIA's frame-generation plugin used another Streamline plugin after the game had unloaded and reloaded it. OptiMFG's RTX 40 backend keeps the patched plugin loaded, so it is not restarted with the others. Turn OptiMFG off to confirm.");
        else result.Add("USE AFTER UNLOAD: "+summary+". The first module used the second after it had been unloaded.");
        return result;
    }
    // Streamline's handler writes sl-sha dumps and may never return, so the player sees a
    // freeze and Windows records no crash. OSD-4D5E: three of these, all at one address
    // in OptiShade's own module, were the real cause, and no finding named them.
    public static List<string> StreamlineCaughtCrash(IEnumerable<string> dumps) {return StreamlineCaughtCrash(dumps,null);}
    // The collector looks back 24 hours, so a report can carry dumps from an earlier
    // game process (OSD-ANRW/5TFC: the same six dumps from a morning session). Only
    // dumps from the reported session's process are its primary issue.
    public static List<string> StreamlineCaughtCrash(IEnumerable<string> dumps,string sessionPid) {
        var result=new List<string>();
        var all=dumps.ToList();
        Func<string,string> pidOf=t=>{var m=Regex.Match(t,@"(?m)^Dump process ID: (\d+)");return m.Success?m.Groups[1].Value:"";};
        var current=String.IsNullOrEmpty(sessionPid)?all:all.Where(t=>pidOf(t)==sessionPid||pidOf(t)=="").ToList();
        var earlier=all.Except(current).ToList();
        Func<List<string>,string> places=list=>String.Join(", ",list.Select(t=>Regex.Match(t,@"(?m)^Exception address: 0x[0-9A-Fa-f]+ \(([^)\r\n]+)\)")).Where(m=>m.Success)
            .GroupBy(m=>m.Groups[1].Value).OrderByDescending(g=>g.Count()).Take(4).Select(g=>g.Count()+" dump(s) at "+g.Key));
        string here=places(current);
        if(here.Length>0)result.Add("STREAMLINE CAUGHT A CRASH: "+here+". The game freezes when this handler does not return, and Windows records no crash.");
        string before=places(earlier);
        if(before.Length>0) {
            var times=earlier.Select(t=>Regex.Match(t,@"(?m)^Dump UTC: (\S+)")).Where(m=>m.Success).Select(m=>m.Groups[1].Value).OrderBy(v=>v).ToList();
            var pids=earlier.Select(pidOf).Where(v=>v!="").Distinct().ToList();
            result.Add("STREAMLINE CAUGHT A CRASH IN AN EARLIER SESSION: "+before+" from game process "+String.Join(", ",pids)+(times.Count>0?" ("+times.First()+(times.Count>1&&times.Last()!=times.First()?" to "+times.Last():"")+")":"")+", not the session in this report (process "+sessionPid+"). Look at these only if that earlier session also froze.");
        }
        return result;
    }
    // AtmosphereMod replaces game shaders and injects root parameters, so a crash or
    // freeze with it loaded cannot be told apart from OptiShade without a retest.
    // Every R348 freeze and GPU crash reviewed on 4 Nov had it loaded.
    public static List<string> AtmosphereModInvolved(IEnumerable<string> found,IEnumerable<string> reshadeLogs,IEnumerable<string> crashes,bool stalled) {
        var result=new List<string>();
        var logs=reshadeLogs.ToList();
        if(!logs.Any(t=>t.Contains("Registered add-on \"AtmosphereMod\"")))return result;
        bool problem=stalled||found.Any(l=>l.StartsWith("CRASH")||l.StartsWith("SIMULATOR CRASH")||l.StartsWith("GPU REMOVAL")||l.StartsWith("GPU DRIVER")||l.StartsWith("GAME FROZE"));
        if(!problem)return result;
        bool onStack=crashes.Any(t=>Regex.IsMatch(t,@"(?m)^Faulting thread context[\s\S]{0,4000}?\[RSP\+0x[0-9A-F]{1,3}\] 0x[0-9A-F]+ AtmosphereMod\.addon64"));
        bool vr=logs.Any(t=>t.Contains("OptiShade OpenXR layer connected"));
        result.Add("ATMOSPHEREMOD LOADED during a crash or freeze"+(onStack?" (it is on the crashing thread's stack)":"")+(vr?"; a VR runtime was also connected, and the mod's author does not cover VR":"")+". This does not show the mod caused it. Retest the same flight with AtmosphereMod uninstalled in OptiShade's Components page, then send a report either way.");
        return result;
    }
    // OptiMFG_Live.exe itself crashed: Application error 1000 names it as the
    // faulting application, with the faulting module after it.
    public static List<string> OptiMfgCrash(IEnumerable<string> applicationEvents) {
        var result=new List<string>();var stamps=new List<string>();string module=null,code=null;
        foreach(string text in applicationEvents)
            foreach(Match m in Regex.Matches(text,@"(?m)^(\S+) \| [^|\r\n]* \| 1000\r?\n([\s\S]*?)(?=\r?\n\S+ \| |\z)")) {
                string body=m.Groups[2].Value;
                if(!Regex.IsMatch(body,@"(?i)^\W*\w[^:\r\n]*:\s*OptiMFG_Live\.exe",RegexOptions.Multiline)&&!Regex.IsMatch(body,@"(?i)\bOptiMFG_Live\.exe,"))continue;
                stamps.Add(m.Groups[1].Value);
                var names=Regex.Matches(body,@"(?i)([A-Za-z0-9_.-]+\.(?:dll|exe))").Cast<Match>().Select(x=>x.Groups[1].Value).Where(x=>!x.Equals("OptiMFG_Live.exe",StringComparison.OrdinalIgnoreCase)).ToList();
                if(module==null&&names.Count>0)module=names[0];
                var c=Regex.Match(body,@"0x(c0000[0-9a-fA-F]{3}|80000003|e06d7363)");if(code==null&&c.Success)code=c.Groups[1].Value.ToLowerInvariant();
            }
        if(stamps.Count==0)return result;
        string meaning=null;if(code!=null)ExceptionMeaning.TryGetValue(code,out meaning);
        result.Add("OPTIMFG CRASHED: Windows recorded "+stamps.Count+" OptiMFG_Live.exe crash(es) (latest "+stamps.Max()+")"+(module!=null?" in "+module:"")+(code!=null?", exception 0x"+code+(meaning!=null?" ("+meaning+")":""):"")+". OptiMFG closed itself rather than being closed from the tray; the game and its frame generation keep running without it until it is started again.");
        return result;
    }

    // The whole PC stopped: Kernel-Power 41 / EventLog 6008 mark the restart and a
    // bugcheck (1001) names the stop code. No game crash report exists for these.
    public static List<string> UnexpectedRestart(IEnumerable<string> systemEvents) {return UnexpectedRestart(systemEvents,null);}
    public static List<string> UnexpectedRestart(IEnumerable<string> systemEvents,DateTime? sessionStart) {
        var result=new List<string>();
        var restarts=new List<string>();var historical=new List<string>();string stop=null;string historicalStop=null;
        foreach(string text in systemEvents) {
            foreach(Match m in Regex.Matches(text,@"(?m)^(\S+) \| (?:Microsoft-Windows-Kernel-Power \| 41|EventLog \| 6008)\b")) {
                DateTime at;
                if(sessionStart.HasValue&&DateTime.TryParse(m.Groups[1].Value,System.Globalization.CultureInfo.InvariantCulture,System.Globalization.DateTimeStyles.AdjustToUniversal|System.Globalization.DateTimeStyles.AssumeUniversal,out at)&&at<sessionStart.Value)historical.Add(m.Groups[1].Value);
                else restarts.Add(m.Groups[1].Value);
            }
            foreach(Match bug in Regex.Matches(text,@"(?m)^(\S+) \| (?:BugCheck|Microsoft-Windows-WER-SystemErrorReporting) \| 1001\r?\n[^\r\n]*?(0x[0-9a-fA-F]{8})")) {
                DateTime at;
                if(sessionStart.HasValue&&DateTime.TryParse(bug.Groups[1].Value,System.Globalization.CultureInfo.InvariantCulture,System.Globalization.DateTimeStyles.AdjustToUniversal|System.Globalization.DateTimeStyles.AssumeUniversal,out at)&&at<sessionStart.Value){if(historicalStop==null)historicalStop=bug.Groups[2].Value;}
                else if(stop==null)stop=bug.Groups[2].Value;
            }
        }
        if(historical.Count>0||historicalStop!=null)result.Add("HISTORICAL SYSTEM RESTART: Windows recorded "+(historical.Count>0?historical.Count+" unexpected restart(s) (latest "+historical.Max()+")":"a system crash")+(historicalStop!=null?" with stop code "+historicalStop:"")+(sessionStart.HasValue?" before the selected game session started at "+sessionStart.Value.ToString("o"):"")+". This does not establish a system failure during the current session.");
        if(restarts.Count==0&&stop==null)return result;
        string line="PC RESTARTED UNEXPECTEDLY: Windows recorded "+(restarts.Count>0?restarts.Count+" unexpected restart(s) (latest "+restarts.Max()+")":"a system crash")+(stop!=null?" with stop code "+stop:"")+". The whole computer stopped, not only the game: a game or add-on cannot do that by itself. Check GPU/CPU overclocks or undervolts, temperatures and the power supply, then the graphics driver.";
        if(systemEvents.Any(t=>t.IndexOf("WHEA-Logger",StringComparison.Ordinal)>=0))line+=" WHEA hardware-error events are also present (see events/System.txt).";
        result.Add(line);
        return result;
    }

    static DateTime? SavedSessionStart(List<KeyValuePair<string,string>> items) {
        var saved=items.FirstOrDefault(p=>p.Key.IndexOf("LastSession.json",StringComparison.OrdinalIgnoreCase)>=0);
        long birth;DateTime captured;
        if(saved.Value==null || !Int64.TryParse(JsonString(saved.Value,"ProcessBirthFileTime"),out birth) || birth<=0 ||
           !DateTime.TryParse(JsonString(saved.Value,"CapturedUtc"),System.Globalization.CultureInfo.InvariantCulture,System.Globalization.DateTimeStyles.AdjustToUniversal|System.Globalization.DateTimeStyles.AssumeUniversal,out captured))return null;
        try {var start=DateTime.FromFileTimeUtc(birth);return start<=captured?(DateTime?)start:null;}catch(ArgumentOutOfRangeException){return null;}
    }
    // Generic nvlddmkm event IDs are not proof of a TDR or its cause. Keep earlier
    // events as context; a saved session boundary is explicitly labelled as such.
    public static List<string> DriverTimeouts(IEnumerable<string> systemEvents,DateTime? sessionStart=null) {
        var result=new List<string>();var seen=new HashSet<string>();
        foreach(string text in systemEvents)foreach(Match m in Regex.Matches(text,@"(?m)^(\S+) \| (Display|nvlddmkm) \| (4101|13|14|153)\b")) {
            DateTime at;
            if(!DateTime.TryParse(m.Groups[1].Value,System.Globalization.CultureInfo.InvariantCulture,System.Globalization.DateTimeStyles.AdjustToUniversal|System.Globalization.DateTimeStyles.AssumeUniversal,out at))continue;
            if(Since.HasValue&&at<Since.Value.ToUniversalTime())continue;
            if(!seen.Add(m.Value))continue;
            string detail=m.Groups[1].Value+" "+m.Groups[2].Value+" event "+m.Groups[3].Value;
            if(sessionStart.HasValue&&at<sessionStart.Value)result.Add("HISTORICAL DISPLAY EVENT: "+detail+" predates the saved game session starting "+sessionStart.Value.ToString("o")+". It does not establish a failure in that session.");
            else if(m.Groups[2].Value=="Display"&&m.Groups[3].Value=="4101")result.Add("GPU DRIVER TIMEOUT: Windows recorded a display-driver recovery at "+detail+". This establishes a reset event, not which application or GPU operation caused it.");
            else result.Add("GPU DRIVER EVENT: Windows recorded "+detail+". This event ID alone does not establish a timeout, hardware fault, or an OptiShade failure. Correlate its timestamp with device-removal evidence and the affected session.");
        }
        return result;
    }

    // No OptiScaler runtime log means no MFG/NR/FG evidence at all.
    public static List<string> MissingRuntimeLog(List<KeyValuePair<string,string>> items) {
        var result=new List<string>();
        // A 0-byte current log is as blind as a missing one; the first-run snapshot is an older session.
        var logs=items.Where(p=>(p.Key.StartsWith("logs/Performance",StringComparison.OrdinalIgnoreCase)||p.Key.IndexOf("OptiScaler.log",StringComparison.OrdinalIgnoreCase)>=0)&&p.Key.IndexOf(".first.log",StringComparison.OrdinalIgnoreCase)<0).ToList();
        bool empty=logs.Count>0&&logs.All(p=>p.Value.Contains("Original bytes: 0;"));
        if(logs.Count>0&&!empty)return result;
        var ini=items.FirstOrDefault(p=>p.Key.IndexOf("OptiScaler.ini",StringComparison.OrdinalIgnoreCase)>=0);
        if(ini.Value==null)return result;
        Match configured=Regex.Match(ini.Value,@"(?m)^\s*LogFileName\s*=\s*(.+?)\s*$");
        string path=configured.Success?configured.Groups[1].Value:"(default)";
        // The game wrote its startup lines, so the log was emptied afterwards: the
        // rotating sink of a second process that loaded the proxy truncates a file
        // the game still holds when its rename fails (OSD-Y348/2WR6/KZHR).
        bool started=empty&&items.Any(p=>p.Key.IndexOf("Performance.log.first.log",StringComparison.OrdinalIgnoreCase)>=0&&!p.Value.Contains("Original bytes: 0;")&&p.Value.IndexOf("OptiScaler v",StringComparison.Ordinal)>=0);
        if(started){result.Add("RUNTIME LOG EMPTIED: Performance.log is 0 bytes although this session's startup lines reached Performance.log.first.log, so another process that loaded OptiShade (a Store-resolved helper or a second game instance) restarted the log while the game was writing it. MFG, NR and frame-generation state for this session cannot be shown. LogFileName = "+path+".");return result;}
        string line="RUNTIME LOG MISSING: "+(empty?"the current OptiScaler/Performance log is empty (0 bytes)":"no OptiScaler/Performance log was captured")+", so MFG, NR and frame-generation state for this session cannot be shown. LogFileName = "+path+".";
        if(empty&&Regex.IsMatch(path,@"(?i)^[a-z]:\\.*WindowsApps\\"))line+=" An absolute path inside the Store package folder stops working when a game update moves the package; R304 and later re-root a missing folder, and R338 saves this path relative when the game next starts.";
        Match stalePackage=Regex.Match(path,@"(?i)WindowsApps\\([^\\]+_)(\d+(?:\.\d+)+)(_[^\\]+)\\");
        if(stalePackage.Success) {
            foreach(string log in Texts(items,"ReShade.log")) {
                Match current=Regex.Match(log,@"(?i)WindowsApps\\"+Regex.Escape(stalePackage.Groups[1].Value)+@"(\d+(?:\.\d+)+)"+Regex.Escape(stalePackage.Groups[3].Value));
                if(current.Success&&current.Groups[1].Value!=stalePackage.Groups[2].Value){line+=" That path is the old game package "+stalePackage.Groups[2].Value+"; the game now runs from "+current.Groups[1].Value+", so the log is written nowhere (fixed from R304: the game re-roots the setting when it next starts).";break;}
            }
        }
        result.Add(line);
        return result;
    }

    // Entries before this (UTC) are history, not the reported session. Set by the
    // collector from its lookback window; null keeps every entry.
    public static DateTime? Since;
    // Manager failures recorded in Installer.log: the latest unresolved result per row.
    public static List<string> Manager(IEnumerable<string> installerLogs) {
        var result=new List<string>();
        var failures=new Dictionary<string,KeyValuePair<string,string>>(StringComparer.OrdinalIgnoreCase);
        var other=new List<KeyValuePair<string,string>>();string blocked="";
        // Retries 1-3 are the manager's own self-heal; they matter only if nothing follows them.
        KeyValuePair<string,string>? retry=null;
        foreach(string text in installerLogs) {
        string lastAt="";
        foreach(string raw in text.Split('\n')) {
            string line=raw.Trim().TrimStart('﻿');
            Match stamp=Regex.Match(line,@"^(\d{4}-\d\d-\d\dT\S+)(?: |$)");
            // Unstamped continuation lines belong to the last stamped entry.
            if(stamp.Success)lastAt=stamp.Groups[1].Value;
            string at=stamp.Success?stamp.Groups[1].Value:lastAt;
            DateTime atUtc;
            if(Since.HasValue&&at.Length>0&&DateTime.TryParse(at,System.Globalization.CultureInfo.InvariantCulture,System.Globalization.DateTimeStyles.AdjustToUniversal|System.Globalization.DateTimeStyles.AssumeUniversal,out atUtc)&&atUtc<Since.Value)continue;
            if(Regex.IsMatch(line,@"Component verification had no current result.*; retry [1-3]\.$")){retry=new KeyValuePair<string,string>(at,Regex.Replace(line,@"^\S+ ",""));continue;}
            if(stamp.Success)retry=null;
            // Windows Security quarantine of OptiShade's own EXE (any language: the
            // English text, or ERROR_VIRUS_INFECTED/0x800700E1).
            if(Regex.IsMatch(line,@"(?i)contains a virus|potentially unwanted software|ERROR_VIRUS_INFECTED|0x800700E1|enth.lt einen Virus|unerw.nschte Software"))blocked=Regex.Replace(line,@"^\S+ ","")+" (at "+at+")";
            Match failed=Regex.Match(line,@"^(\S+) Update Manager: (.+?) \| (.+)$");
            if(failed.Success){failures[failed.Groups[2].Value]=new KeyValuePair<string,string>(failed.Groups[1].Value,failed.Groups[3].Value);continue;}
            Match applied=Regex.Match(line,@"Update row applied(?: after adapter selection)?: (.+)$");
            if(applied.Success){failures.Remove(applied.Groups[1].Value.Trim());continue;}
            Match popup=Regex.Match(line,@"^(\S+) (Could not open .+?: .+?)(?: \| at |$)");
            if(popup.Success){other.Add(new KeyValuePair<string,string>(popup.Groups[1].Value,popup.Groups[2].Value));continue;}
            if(line.Contains("Component verification had no current result")||line.Contains("Component verification worker exceeded")||line.Contains("Background component check failed"))other.Add(new KeyValuePair<string,string>(at,Regex.Replace(line,@"^\S+ ","")));
        }
        if(retry.HasValue)other.Add(retry.Value);
        retry=null;
        }
        if(blocked.Length>0)result.Add("WINDOWS SECURITY DETECTION OptiShade: an OptiShade file was quarantined or refused as \"virus or potentially unwanted software\": "+(blocked.Length>400?blocked.Substring(0,400)+"...":blocked)+". Check the affected file and current action in Windows Security > Protection history, and verify its source before restoring anything.");
        // Newest unresolved failures first; ISO timestamps sort as text.
        var newest=failures.OrderByDescending(f=>f.Value.Key,StringComparer.Ordinal).ToList();
        foreach(var f in newest.Take(3))result.Add("MANAGER UPDATE FAILED for "+f.Key+": "+f.Value.Value+" (at "+f.Value.Key+")");
        if(newest.Count>3)result.Add("  "+(newest.Count-3)+" older unresolved update failure(s) are in launcher/Installer.log.");
        foreach(var o in other.GroupBy(o=>o.Value).Select(g=>g.OrderByDescending(x=>x.Key,StringComparer.Ordinal).First()).OrderByDescending(o=>o.Key,StringComparer.Ordinal).Take(3))result.Add("MANAGER ERROR: "+o.Value+" (latest at "+o.Key+")");
        return result;
    }

    // OptiScaler's once-a-minute "Memory sample" lines (R334+): the game's memory over
    // the session, so a crash report shows whether memory climbed or ran out first.
    // A trend, not attribution: it cannot say which part of the game or which mod used it.
    public static List<string> MemoryTrend(IEnumerable<string> performanceLogs) {
        return MemoryTrend(performanceLogs,null);
    }
    public static List<string> MemoryTrend(IEnumerable<string> performanceLogs,string selectedPid) {
        var result=new List<string>();
        var byPid=new Dictionary<string,SortedDictionary<long,long[]>>();
        foreach(string text in performanceLogs) foreach(Match m in Regex.Matches(text,@"Memory sample: pid=(\d+) tick=(\d+) privateMB=(\d+) workingSetMB=\d+ commitMB=(\d+) commitLimitMB=(\d+) availableRamMB=(\d+) vramMB=(\d+) vramBudgetMB=(\d+)")) {
            SortedDictionary<long,long[]> series;
            if(!byPid.TryGetValue(m.Groups[1].Value,out series))byPid[m.Groups[1].Value]=series=new SortedDictionary<long,long[]>();
            series[Int64.Parse(m.Groups[2].Value)]=Enumerable.Range(3,6).Select(g=>Int64.Parse(m.Groups[g].Value)).ToArray();
        }
        // Prefer the PID from LastSession. Only legacy/direct callers without an
        // identity fall back to the longest stream; archives commonly include
        // rotated logs from earlier simulator processes.
        SortedDictionary<long,long[]> session;
        if(!String.IsNullOrWhiteSpace(selectedPid)) {
            if(!byPid.TryGetValue(selectedPid.Trim(),out session))return result;
        } else {
            var longest=byPid.OrderByDescending(p=>p.Value.Count).FirstOrDefault();
            session=longest.Value;
        }
        if(session==null||session.Count==0)return result;
        // Growth is measured from 15 minutes in: before that the simulator is still
        // loading (OSD-ZXE4 "grew" 1.6 -> 40 GB in its first 36 minutes).
        var last=session.Last();
        var first=session.FirstOrDefault(p=>p.Key-session.First().Key>=15L*60000);
        if(first.Value==null)first=last;
        double hours=(last.Key-first.Key)/3600000.0;
        long[] a=first.Value,z=last.Value; // private, commit, commitLimit, availableRam, vram, vramBudget
        long peak=session.Values.Max(v=>v[0]);
        var ci=System.Globalization.CultureInfo.InvariantCulture;
        if(hours>=0.5&&z[0]-a[0]>=3000&&(z[0]-a[0])/hours>=1500)
            result.Add("MEMORY GROWTH: the game's private memory grew from "+(a[0]/1024.0).ToString("0.0",ci)+" GB to "+(z[0]/1024.0).ToString("0.0",ci)+" GB over "+(hours*60).ToString("0",ci)+" min ("+((z[0]-a[0])/1024.0/hours).ToString("0.0",ci)+" GB/h; peak "+(peak/1024.0).ToString("0.0",ci)+" GB). This is the whole game process: it does not show whether the simulator, an add-on or OptiShade used it. Compare a session of the same length with OptiShade's features off.");
        if(z[2]>0&&(z[1]>=z[2]*95/100||z[3]<1024))
            result.Add("LOW SYSTEM MEMORY: at the last sample Windows had committed "+(z[1]/1024.0).ToString("0.0",ci)+" of "+(z[2]/1024.0).ToString("0.0",ci)+" GB and "+(z[3]/1024.0).ToString("0.0",ci)+" GB of RAM free. A crash with this little left is often an out-of-memory crash; a larger page file or fewer background apps gives the game room.");
        if(z[5]>0&&z[4]>z[5])
            result.Add("VIDEO MEMORY OVER BUDGET: at the last sample the game used "+(z[4]/1024.0).ToString("0.0",ci)+" GB of video memory against a "+(z[5]/1024.0).ToString("0.0",ci)+" GB budget, so Windows was moving graphics data to system memory (stutter, and a crash risk). Lower texture or resolution settings, or NR's working resolution.");
        return result;
    }
    // OptiScaler.ini without OptiShade's own ReShade setting (OSD-Q54M: reset to "auto",
    // so before R330 image effects never loaded and the effects page said "not responding").
    public static List<string> EffectsNotLoaded(string optiscalerIni,string installedHashes) {
        var result=new List<string>();
        if(optiscalerIni==null||installedHashes==null||!Regex.IsMatch(installedHashes,@"(?m)^ReShade64\.dll \| \d+ bytes"))return result;
        Match load=Regex.Match(optiscalerIni,@"(?im)^\s*LoadReShade\s*=\s*(\S+)");
        if(load.Success&&String.Equals(load.Groups[1].Value,"true",StringComparison.OrdinalIgnoreCase))return result;
        result.Add("IMAGE EFFECTS NOT LOADED: ReShade64.dll is installed but OptiScaler.ini has LoadReShade = "+(load.Success?load.Groups[1].Value:"(missing)")+", so the game never loaded ReShade: no image effects, and the effects page says it is not responding."+
            (Regex.IsMatch(optiscalerIni,@"(?im)^\s*LogFileName\s*=\s*auto\s*$")?" The same file has LogFileName = auto, so it was reset to OptiScaler's defaults rather than edited.":"")+" R330 loads ReShade when this setting is auto; on older builds set LoadReShade=true under [Plugins] in OptiScaler.ini.");
        return result;
    }
    // Windows Defender detections of OptiShade files (collector events/Defender.txt):
    // one "time | id | Threat | Path | Action" line per detection of a relevant file.
    public static bool RelevantDefenderPath(string path,string gameFolder=null) {
        string p=(path??"").Replace('/','\\');
        var fileEnd=Regex.Match(p,@"^.*?\.(?:exe|dll|asi|addon64|addon32|ini|json|zip|msi)\b",RegexOptions.IgnoreCase);
        if(fileEnd.Success)p=fileEnd.Value;
        string game=(gameFolder??"").Replace('/','\\').TrimEnd('\\');
        if(p.StartsWith("<GAME>\\",StringComparison.OrdinalIgnoreCase) ||
           (game.Length>0&&p.StartsWith(game+"\\",StringComparison.OrdinalIgnoreCase)))return true;
        // A generic proxy filename in another game's directory proves no OptiShade ownership.
        return Regex.IsMatch(p,@"(?i)(?:^|\\)(?:OptiShade[^\\]*|OptiMFG[^\\]*|OptiScaler[^\\]*|RTX\w*MFG[^\\]*|glass-cockpit[^\\]*|dlss5-feed[^\\]*|FusionSetup\.exe)(?:\\|$)");
    }
    public static List<string> DefenderBlocks(IEnumerable<string> defenderLogs,DateTime? since=null) {
        var result=new List<string>();
        var hits=defenderLogs.SelectMany(t=>t.Split('\n')).Select(l=>l.Trim()).Where(l=>Regex.IsMatch(l,@"^\d{4}-\d\d-\d\dT\S+ \| 111[67] \|")).ToList();
        hits=hits.Where(l=>{
            DateTime at;
            if(since.HasValue && (!DateTime.TryParse(l.Split(' ')[0],System.Globalization.CultureInfo.InvariantCulture,System.Globalization.DateTimeStyles.AssumeUniversal|System.Globalization.DateTimeStyles.AdjustToUniversal,out at)||at<since.Value.ToUniversalTime()))return false;
            return Regex.Match(l,@"Path: (.*?)(?: \| |$)").Groups[1].Value.Split(';').Any(f=>RelevantDefenderPath(f.Trim()));
        }).ToList();
        if(hits.Count==0)return result;
        // Older captures kept Defender's webfile (download URL) and process entries; show files only.
        var files=hits.SelectMany(l=>Regex.Match(l,@"Path: (.*?)(?: \| |$)").Groups[1].Value.Split(';')).Select(f=>f.Trim())
            .Where(f=>f.Length>0&&f.IndexOf('|')<0&&!f.StartsWith("process:",StringComparison.OrdinalIgnoreCase)&&!f.StartsWith("web",StringComparison.OrdinalIgnoreCase))
            .Select(f=>{var m=Regex.Match(f,@"^.*?\.(?:exe|dll|asi|addon64|addon32|ini|json|zip|msi)\b",RegexOptions.IgnoreCase);return m.Success?m.Value:f;})
            .Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        result.Add("WINDOWS SECURITY DETECTION OptiShade: Windows Defender detected "+hits.Count+" OptiShade-related item(s) (latest "+hits.Max(l=>l.Substring(0,l.IndexOf(' ')))+"): "+String.Join("; ",files.Take(5))+(files.Count>5?"; ...":"")+". A detection event does not establish that the file is still blocked or caused this session issue. Check Protection history and verify the file source before taking action.");
        // Detail lines too: no download URL, and a localised description ends at the file name.
        foreach(string h in hits.Take(5))result.Add("  "+Regex.Replace(Regex.Replace(h,@"https?://[^|; ]+","<download URL>"),@"(\.(?:exe|dll|asi|addon64|addon32|ini|json|zip|msi))\b[^|]*?(?= \| Action:|$)","$1",RegexOptions.IgnoreCase));
        return result;
    }
    // Collector checks/game-executable.txt: "StubTarget: <path>" when the chosen EXE
    // is a launcher stub that only starts another EXE (GIANTS' Farming Simulator).
    public static List<string> WrongGameExecutable(string check) {
        var result=new List<string>();
        Match chosen=Regex.Match(check??"",@"(?m)^Executable: (.+?)\s*$"),target=Regex.Match(check??"",@"(?m)^StubTarget: (.+?)\s*$");
        if(!target.Success)return result;
        // Captured text is redacted (<USER>), so no System.IO path parsing here.
        result.Add("WRONG GAME EXE: OptiShade was checked beside "+Regex.Match(chosen.Groups[1].Value,@"[^\\/]*$").Value+", a launcher that only starts "+target.Groups[1].Value+". The game never loads OptiShade from the launcher's folder, so there are no OptiShade logs or menu. Reinstall OptiShade beside the game EXE: "+target.Groups[1].Value+".");
        return result;
    }
    // OptiScaler's one-off record at Streamline initialization (R327+). This
    // early snapshot cannot prove that the proxy never loads later.
    public static List<string> MfgBackendModule(IEnumerable<string> performanceLogs) {
        var result=new List<string>();string latest=null;
        foreach(string text in performanceLogs)foreach(string raw in text.Split('\n'))
            if(raw.Contains("OptiMFG backend check: "))latest=raw.Trim();
        if(latest!=null&&latest.Contains("game-folder backend not observed in this Streamline-initialization snapshot"))
            result.Add("MFG BACKEND SNAPSHOT: At Streamline initialization, the game-folder OptiMFG proxy was not among the loaded version.dll modules. This is an early snapshot only; it does not prove the proxy failed to load later. Keep other version.dll files in place until a process-bound controller/backend report confirms a conflict. "+latest.Substring(latest.IndexOf("loaded version.dll",StringComparison.Ordinal)));
        return result;
    }

    // Virtual displays and hybrid GPUs change which adapter presents frames.
    public static List<string> DisplayAdapters(string hardware) {
        var result=new List<string>();
        if(String.IsNullOrEmpty(hardware))return result;
        var names=Regex.Matches(hardware,@"(?m)^Name: (.+?)\s*$").Cast<Match>().Select(m=>m.Groups[1].Value).ToList();
        var virtualDisplays=names.Where(n=>Regex.IsMatch(n,@"(?i)parsec|virtual display|iddsample|indirect display|spacedesk|virtual desktop monitor|meta virtual monitor|sunshine|moonlight|usbmmidd|duet display")).ToList();
        if(virtualDisplays.Count>0)result.Add("VIRTUAL DISPLAY ADAPTER present: "+String.Join(", ",virtualDisplays)+". Virtual displays can take the game's output, change the presenting adapter and stop DLSS Frame Generation; disable it and retest before treating MFG/NR as broken.");
        bool nvidia=names.Any(n=>n.IndexOf("NVIDIA",StringComparison.OrdinalIgnoreCase)>=0);
        bool integrated=names.Any(n=>Regex.IsMatch(n,@"(?i)Intel\(R\) (UHD|Iris|Arc\(TM\) Graphics)|AMD Radeon\(TM\) Graphics|Radeon 7\d0M"));
        if(nvidia&&integrated)result.Add("HYBRID GPU system (integrated + NVIDIA): the game must render on the NVIDIA GPU. Check Windows Settings > Display > Graphics for this game, and the laptop's MUX/Advanced Optimus mode.");
        return result;
    }

    // Final NR state and the XP12 route gate from OptiShadeData/LastSession.json.
    public static List<string> NeuralSession(string lastSessionText) {
        var result=new List<string>();
        if(String.IsNullOrEmpty(lastSessionText))return result;
        int start=lastSessionText.IndexOf('{');
        if(start<0)return result;
        Dictionary<string,object> session;
        try{session=new JavaScriptSerializer{MaxJsonLength=4*1024*1024}.Deserialize<Dictionary<string,object>>(lastSessionText.Substring(start));}catch{return result;}
        string requested=Field(session,"Requested"),lastAction=Field(session,"NRActivationLastAction"),lastSource=Field(session,"NRActivationLastSource");
        string admission=Field(session,"XP12BridgeAdmissionStage"),block=Field(session,"XP12BridgeLatestBlockReason"),failure=Field(session,"LastFailure");
        if(String.Equals(requested,"Off",StringComparison.OrdinalIgnoreCase)&&String.Equals(lastAction,"Off",StringComparison.OrdinalIgnoreCase))
            result.Add("NR WAS SWITCHED OFF at the end of the session"+(lastSource.Length>0?" (last control from "+lastSource+")":"")+". If NR had already stopped working, check the earlier lines here for why.");
        if(admission.IndexOf("waiting",StringComparison.OrdinalIgnoreCase)>=0)
            result.Add("X-PLANE NR NOT ADMITTED: \""+admission+"\""+(block.Length>0?"; latest block: "+block:"; this build recorded no block reason")+".");
        if(failure.Length>0&&failure.IndexOf("Waiting",StringComparison.OrdinalIgnoreCase)<0)
            result.Add((String.Equals(requested,"Off",StringComparison.OrdinalIgnoreCase)||String.Equals(Field(session,"NRStage"),"Active",StringComparison.OrdinalIgnoreCase)?"NR SAVED ROUTE NOTE: ":"NR LAST FAILURE: ")+failure+". This saved field alone does not establish a current processing failure.");
        // The NR stall tracker survives in the session file even when the runtime log is lost.
        long stallMs,retired,ageMs,attempts;
        long.TryParse(Field(session,"NRStallDurationMs"),out stallMs);long.TryParse(Field(session,"NRStallRetiredItems"),out retired);
        long.TryParse(Field(session,"NRStallCompletionAgeMs"),out ageMs);long.TryParse(Field(session,"NRActivationAttemptCount"),out attempts);
        // A stall whose reason is the user's own Off is not a rebuild wait.
        bool switchedOff=Field(session,"NRStallReason").IndexOf("switched off",StringComparison.OrdinalIgnoreCase)>=0;
        if(!switchedOff&&String.Equals(Field(session,"NRStallState"),"Blocked",StringComparison.OrdinalIgnoreCase)&&stallMs>=10000&&retired>0)
            result.Add("NR STUCK REBUILDING (saved session): NR stopped completing frames at frame "+Field(session,"NRStallLastCompletedFrame")+" and then waited "+(stallMs/1000)+" s on "+retired+" retired item(s) of previous GPU work"+(ageMs>0?"; its last completed frame was "+(ageMs/1000)+" s before the session ended":"")+
                (attempts>0?". NR was switched on/off "+attempts+" times in this session; toggling cannot clear this wait, a game restart does":"")+". R301 and later release the rebuild once the old work is finished.");
        // NR requested on, yet nothing completed for a long time: what the panel shows
        // as "Waiting for supported frames". The stall reason names the last wait.
        else if(!switchedOff&&String.Equals(requested,"On",StringComparison.OrdinalIgnoreCase)&&ageMs>=60000)
            result.Add("NR NOT COMPLETING FRAMES (saved session): NR was on, but its last completed frame ("+Field(session,"NRStallLastCompletedFrame")+") was "+(ageMs/1000)+" s before the session summary was saved"+
                (Field(session,"NRStallReason").Length>0?"; last wait: \""+Field(session,"NRStallReason")+"\"":"")+(attempts>0?". NR was switched on/off "+attempts+" times in this session":"")+".");
        return result;
    }
    static string Field(Dictionary<string,object> map,string name) {
        object value;
        if(!map.TryGetValue(name,out value)||value==null)return "";
        string text=Convert.ToString(value,System.Globalization.CultureInfo.InvariantCulture).Trim();
        if(String.Equals(text,"Not observed",StringComparison.OrdinalIgnoreCase)||String.Equals(text,"None",StringComparison.OrdinalIgnoreCase))return "";
        return text.Length>300?text.Substring(0,300):text;
    }

    public static List<string> InputHookNoise(IEnumerable<string> optiscalerLogs) {
        var result=new List<string>();
        foreach(string text in optiscalerLogs) {
            // Throttled builds summarise as "Window retargeted N times in the last M ms (T total)".
            var summaries=Regex.Matches(text,@"Window retargeted (\d+) times in the last (\d+) ms \((\d+) total\)").Cast<Match>().ToList();
            if(summaries.Count>0) {
                Match latest=summaries.Last();
                result.Add("INPUT HOOK THRASH: the overlay input hook switched windows "+latest.Groups[3].Value+" times (latest "+latest.Groups[1].Value+" in "+latest.Groups[2].Value+" ms). Two windows/swapchains are presenting; this adds input latency.");
                break;
            }
            var all=text.Split('\n');
            int hook=all.Count(l=>l.IndexOf("OptiInput::",StringComparison.Ordinal)>=0);
            if(all.Length<200||hook*2<all.Length)continue;
            var windows=Regex.Matches(text,@"SetTargetWindow target window set hwnd:(0x[0-9a-fA-F]+)").Cast<Match>().Select(m=>m.Groups[1].Value).Distinct().Count();
            result.Add("INPUT HOOK THRASH: "+hook+" of "+all.Length+" OptiScaler log lines are OptiInput window re-targeting"+(windows>1?" across "+windows+" windows":"")+". The hook keeps switching windows, which adds input latency and pushes other log lines out of the capture.");
            break;
        }
        return result;
    }
}
}
