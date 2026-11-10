// Read-only sensor bridge. No driver installation, administrator request or network access.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Management;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

internal static class HardwareSensors
{
    static string selectedGpu="",gpuHex="";
    internal static string NormalizeGpu(string name){return (name??"").ToLowerInvariant().Replace("nvidia ","").Replace("amd ","").Trim();}
    internal static bool MatchesGpu(string name){return selectedGpu.Length==0||NormalizeGpu(name)==NormalizeGpu(selectedGpu);}

    [DllImport("kernel32.dll", CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
    [DllImport("kernel32.dll")] static extern IntPtr GetProcAddress(IntPtr module,string name);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr Query(uint id);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Init();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int EnumGpu([Out] IntPtr[] handles,out int count);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int NameGpu(IntPtr gpu,StringBuilder name);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int ThermalGpu(IntPtr gpu,int target,ref Thermal readings);
    [StructLayout(LayoutKind.Sequential)] struct Sensor { public int controller,min,max,current,target; }
    [StructLayout(LayoutKind.Sequential)] struct Thermal {
        public uint version,count;
        [MarshalAs(UnmanagedType.ByValArray,SizeConst=3)] public Sensor[] sensors;
    }
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int UtilGpu(IntPtr gpu,ref Domains data);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int ClockGpu(IntPtr gpu,ref Clocks data);
    [StructLayout(LayoutKind.Sequential)] struct Domain { public uint present,value; }
    [StructLayout(LayoutKind.Sequential)] struct Domains { public uint version,flags; [MarshalAs(UnmanagedType.ByValArray,SizeConst=8)] public Domain[] domains; }
    [StructLayout(LayoutKind.Sequential)] struct Clocks { public uint version,type; [MarshalAs(UnmanagedType.ByValArray,SizeConst=32)] public Domain[] domains; }
    [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out long idle,out long kernel,out long user);
    [StructLayout(LayoutKind.Sequential)] class Memory { public uint length=(uint)Marshal.SizeOf(typeof(Memory)),load; public ulong total,available,pageTotal,pageAvailable,virtualTotal,virtualAvailable,extended; }
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GlobalMemoryStatusEx([In,Out] Memory data);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int MemoryGpu(IntPtr gpu,ref GpuMemory data);
    [StructLayout(LayoutKind.Sequential)] struct GpuMemory { public uint version,dedicated,available,system,shared,currentAvailable; }
    static MemoryGpu memoryGpu;
    static UtilGpu utilGpu; static ClockGpu clockGpu;
    static EnumGpu enumerate; static NameGpu nameGpu; static ThermalGpu thermalGpu;
    static T Function<T>(Query query,uint id) where T:class {
        var p=query(id);return p==IntPtr.Zero?null:Marshal.GetDelegateForFunctionPointer(p,typeof(T)) as T;
    }
    static volatile string nvidiaStatus="NVIDIA provider starting";
    static IntPtr nvidiaModule;
    static void InitNvidia() {
        var module=nvidiaModule; if(module==IntPtr.Zero)module=nvidiaModule=LoadLibraryEx("nvapi64.dll",IntPtr.Zero,0x800); // System32 only
        if(module==IntPtr.Zero){nvidiaStatus="NVIDIA provider DLL unavailable: Windows error "+Marshal.GetLastWin32Error();return;}
        var address=GetProcAddress(module,"nvapi_QueryInterface");if(address==IntPtr.Zero){nvidiaStatus="NVIDIA query interface unavailable";return;}
        var q=(Query)Marshal.GetDelegateForFunctionPointer(address,typeof(Query));
        var init=Function<Init>(q,0x0150e828);if(init==null){nvidiaStatus="NVIDIA initialize export unavailable";return;}int result=init();if(result!=0){nvidiaStatus="NVIDIA initialize result "+result+"; retrying";return;}
        enumerate=Function<EnumGpu>(q,0xe5ac921f);nameGpu=Function<NameGpu>(q,0xceee8e9f);
        thermalGpu=Function<ThermalGpu>(q,0xe3640a56);
        memoryGpu=Function<MemoryGpu>(q,0x07f9b368);utilGpu=Function<UtilGpu>(q,0x60ded2ed);clockGpu=Function<ClockGpu>(q,0xdcb616c3);
    }
    static string Clean(string s) {s=(s??"").Replace('\t',' ').Replace('\r',' ').Replace('\n',' ');while(Encoding.UTF8.GetByteCount(s)>160)s=s.Substring(0,s.Length-1);return s;}
    static void Add(List<string> rows,string label,double value) {
        if(rows.Count>=48||double.IsNaN(value)||double.IsInfinity(value)||value<0||value>150)return;
        rows.Add(Clean(label)+"\t"+value.ToString("F1",CultureInfo.InvariantCulture));
    }
    static void Metric(List<string> rows,string label,double value,string unit) {
        if(rows.Count>=48||double.IsNaN(value)||double.IsInfinity(value)||value<0)return;
        rows.Add(Clean(label)+"\t"+value.ToString("F1",CultureInfo.InvariantCulture)+"\t"+unit);
    }
    static long lastIdle,lastTotal;

    static void WindowsMetrics(List<string> rows) {
        long idle,kernel,user;
        if(GetSystemTimes(out idle,out kernel,out user)) {
            long total=kernel+user,delta=total-lastTotal;
            if(lastTotal>0&&delta>0)Metric(rows,"CPU usage",Math.Max(0,Math.Min(100,100.0*(delta-(idle-lastIdle))/delta)),"%");
            lastIdle=idle;lastTotal=total;
        }
        var m=new Memory();if(GlobalMemoryStatusEx(m)) {
            Metric(rows,"RAM usage",m.load,"%");Metric(rows,"RAM used",(m.total-m.available)/1073741824.0,"GiB");Metric(rows,"RAM total",m.total/1073741824.0,"GiB");
        }
    }
    static bool Nvidia(List<string> rows) {
        if(enumerate==null)return false;int before=rows.Count;
        IntPtr[] handles=new IntPtr[64];int count;int result=enumerate(handles,out count);if(result!=0){nvidiaStatus="NVIDIA enumeration result "+result+"; retrying";return false;}if(count==0)nvidiaStatus="No NVIDIA hardware handles returned; retrying";
        bool found=false;
        for(int i=0;i<Math.Min(count,64);i++) {
            var name=new StringBuilder(64);if(nameGpu==null||nameGpu(handles[i],name)!=0)name.Append("NVIDIA GPU "+(i+1));
            if(!MatchesGpu(name.ToString()))continue;
            rows.Add("NVIDIA GPU name\t"+Clean(name.ToString())+"\ttext");
            string prefix="NVIDIA GPU";
            var t=new Thermal{version=(uint)(Marshal.SizeOf(typeof(Thermal))|(2<<16)),sensors=new Sensor[3]};
            if(memoryGpu!=null) {
                var m=new GpuMemory{version=(uint)(Marshal.SizeOf(typeof(GpuMemory))|(2<<16))};
                if(memoryGpu(handles[i],ref m)==0&&m.currentAvailable<=m.dedicated){Metric(rows,prefix+" VRAM used",(m.dedicated-m.currentAvailable)/1048576.0,"GiB");Metric(rows,prefix+" VRAM total",m.dedicated/1048576.0,"GiB");}
            }
            if(utilGpu!=null) {
                var u=new Domains{version=(uint)(Marshal.SizeOf(typeof(Domains))|(1<<16)),domains=new Domain[8]};
                if(utilGpu(handles[i],ref u)==0&&(u.domains[0].present&1)!=0)Metric(rows,prefix+" usage",u.domains[0].value,"%");
            }
            if(clockGpu!=null) {
                var c=new Clocks{version=(uint)(Marshal.SizeOf(typeof(Clocks))|(3<<16)),domains=new Domain[32]};
                if(clockGpu(handles[i],ref c)==0) {
                    if((c.domains[0].present&1)!=0)Metric(rows,prefix+" core clock",c.domains[0].value/1000.0,"MHz");
                    if((c.domains[4].present&1)!=0)Metric(rows,prefix+" memory clock",c.domains[4].value/1000.0,"MHz");
                }
            }
            if(thermalGpu==null||thermalGpu(handles[i],15,ref t)!=0)continue;
            for(int j=0;j<Math.Min(t.count,3);j++) {
                var s=t.sensors[j];string kind=s.target==1?"":s.target==2?" memory":s.target==4?" power":null;
                if(kind==null)continue;Metric(rows,prefix+(kind==""?" temperature":kind+" temperature"),s.current,"C");found=true;
            }
        }
        if(rows.Count>before)nvidiaStatus="NVIDIA provider active: "+(rows.Count-before)+" readings";else if(count>0)nvidiaStatus="NVIDIA handles detected, but sensor queries returned no readings; retrying";
        return found||rows.Count>before;
    }

    // AMD ADL public ABI, derived from AMD's MIT-licensed display-library headers.
    // The driver library is loaded from System32; no service/driver is installed.
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate IntPtr AdlAlloc(int bytes);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int AdlCreate(AdlAlloc alloc,int connected,out IntPtr context);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int AdlCount(IntPtr context,out int count);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int AdlInfo(IntPtr context,IntPtr data,int bytes);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int AdlMetrics(IntPtr context,int adapter,ref AdlData data);
    [StructLayout(LayoutKind.Sequential)] struct AdlSensor {public int supported,value;}
    [StructLayout(LayoutKind.Sequential)] struct AdlData {public int size;[MarshalAs(UnmanagedType.ByValArray,SizeConst=256)]public AdlSensor[] sensors;}
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Ansi)] struct AdlAdapter {
        public int size,index;[MarshalAs(UnmanagedType.ByValTStr,SizeConst=256)]public string udid;
        public int bus,device,function,vendor;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=256)]public string name;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=256)]public string display;
        public int present,exist;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=256)]public string driver;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=256)]public string driverExt;
        [MarshalAs(UnmanagedType.ByValTStr,SizeConst=256)]public string pnp;public int osIndex;
    }
    static readonly AdlAlloc adlAlloc=bytes=>bytes>0?Marshal.AllocHGlobal(bytes):IntPtr.Zero;
    static IntPtr adlModule,adlContext;static AdlCount adlCount;static AdlInfo adlInfo;static AdlMetrics adlMetrics;
    static T Export<T>(IntPtr module,string name) where T:class {var p=GetProcAddress(module,name);return p==IntPtr.Zero?null:Marshal.GetDelegateForFunctionPointer(p,typeof(T)) as T;}
    static void Amd(List<string> rows){
        if(adlModule==IntPtr.Zero)adlModule=LoadLibraryEx("atiadlxx.dll",IntPtr.Zero,0x800);
        if(adlModule==IntPtr.Zero)return;
        if(adlContext==IntPtr.Zero){var create=Export<AdlCreate>(adlModule,"ADL2_Main_Control_Create");if(create==null||create(adlAlloc,1,out adlContext)!=0){adlContext=IntPtr.Zero;return;}
            adlCount=Export<AdlCount>(adlModule,"ADL2_Adapter_NumberOfAdapters_Get");adlInfo=Export<AdlInfo>(adlModule,"ADL2_Adapter_AdapterInfo_Get");adlMetrics=Export<AdlMetrics>(adlModule,"ADL2_New_QueryPMLogData_Get");}
        if(adlCount==null||adlInfo==null||adlMetrics==null)return;
        int count;if(adlCount(adlContext,out count)!=0||count<1||count>64)return;
        int size=Marshal.SizeOf(typeof(AdlAdapter));IntPtr buffer=Marshal.AllocHGlobal(size*count);
        try{for(int i=0;i<count;i++)Marshal.StructureToPtr(new AdlAdapter{size=size},IntPtr.Add(buffer,size*i),false);
            if(adlInfo(adlContext,buffer,size*count)!=0)return;
            var seen=new HashSet<string>();
            for(int i=0;i<count;i++){var a=(AdlAdapter)Marshal.PtrToStructure(IntPtr.Add(buffer,size*i),typeof(AdlAdapter));
                if(a.vendor!=1002&&a.vendor!=0x1002)continue;
                if(!MatchesGpu(a.name))continue;
                if(!seen.Add(a.bus+":"+a.device+":"+a.function))continue;
                rows.Add("AMD GPU name\t"+Clean(a.name)+"\ttext");
                var data=new AdlData{size=Marshal.SizeOf(typeof(AdlData)),sensors=new AdlSensor[256]};if(adlMetrics(adlContext,a.index,ref data)!=0)continue;
                int[] ids={8,27,19,1,2,23,73,14};string[] labels={" temperature"," hotspot"," usage"," core clock"," memory clock"," chip power"," board power"," fan"};string[] units={"C","C","%","MHz","MHz","W","W","RPM"};
                for(int j=0;j<ids.Length;j++){var value=data.sensors[ids[j]];if(value.supported!=0)Metric(rows,"AMD GPU"+labels[j],value.value,units[j]);}
            }
        }finally{Marshal.FreeHGlobal(buffer);}
    }

    // Slow vendor/WMI calls run in supervised child processes, never on the heartbeat thread.
    static void CpuClock(List<string> rows) {
        using(var search=new ManagementObjectSearcher("SELECT ProcessorFrequency FROM Win32_PerfFormattedData_Counters_ProcessorInformation WHERE Name='_Total'"))
        using(var values=search.Get())foreach(ManagementObject v in values)using(v)Metric(rows,"CPU reported clock",Convert.ToDouble(v["ProcessorFrequency"],CultureInfo.InvariantCulture),"MHz");
    }
    static void WindowsGpu(List<string> rows) {
        using(var search=new ManagementObjectSearcher("SELECT Name, UtilizationPercentage FROM Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine"))
        using(var values=search.Get()) {
            var loads=new Dictionary<string,double>();
            foreach(ManagementObject v in values)using(v) {
                string name=Convert.ToString(v["Name"]);int index=name.IndexOf("luid_",StringComparison.Ordinal);
                if(index<0)continue;string key=name.Substring(index);
                double old;loads.TryGetValue(key,out old);loads[key]=old+Convert.ToDouble(v["UtilizationPercentage"],CultureInfo.InvariantCulture);
            }
            double max=-1;foreach(var load in loads.Values)max=Math.Max(max,load);
            if(max>=0)Metric(rows,"Windows GPU busiest engine",Math.Min(100,max),"%");
        }
    }
    internal sealed class Provider : IDisposable {
        readonly string kind;
        readonly object gate=new object();
        Process child;List<string> rows=new List<string>(),pending=new List<string>();bool collecting;
        long started,lastFrame,retry;int generation;string stage="starting";
        internal bool FinishedStarting;internal string Status="starting";
        internal Provider(string kind){this.kind=kind;}
        void Line(string line,int expected) {
            lock(gate){if(expected!=generation||line==null||line.Length>512)return;
                if(line.StartsWith("STATUS\t")){stage=Clean(line.Substring(7));return;}
                if(line=="BEGIN"){pending.Clear();collecting=true;return;}
                if(line=="END"){if(collecting){rows=new List<string>(pending);lastFrame=DateTime.UtcNow.Ticks;FinishedStarting=true;}collecting=false;return;}
                if(collecting&&pending.Count<48&&line.IndexOf('\t')>0)pending.Add(line);
            }
        }
        internal void Tick(long now,SnapshotSchema schema) {
            lock(gate){
                if(child!=null&&(child.HasExited||now-Math.Max(started,lastFrame)>TimeSpan.FromSeconds(15).Ticks)){
                    string why=child.HasExited?"exited":"timed out at "+stage;
                    Stop();FinishedStarting=true;Status=kind+" provider "+why+"; retrying in 60s";retry=now+TimeSpan.FromSeconds(60).Ticks;
                }
                if(child==null&&now>=retry){
                    started=now;lastFrame=0;stage="starting";FinishedStarting=false;Status=kind+" provider starting";
                    int current=++generation;
                    try{
                        child=new Process();child.StartInfo=new ProcessStartInfo(System.Reflection.Assembly.GetExecutingAssembly().Location,Process.GetCurrentProcess().Id+" --provider "+kind+(gpuHex.Length==0?"":" --gpu "+gpuHex)){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true};
                        child.OutputDataReceived+=(sender,e)=>Line(e.Data,current);
                        child.ErrorDataReceived+=(sender,e)=>{};
                        if(!child.Start())throw new InvalidOperationException("provider process did not start");
                        child.BeginOutputReadLine();child.BeginErrorReadLine();
                    }catch(Exception e){Stop();FinishedStarting=true;Status=kind+" provider unavailable: "+e.GetType().Name;retry=now+TimeSpan.FromSeconds(60).Ticks;}
                }
                if(lastFrame!=0){schema.Update(rows,lastFrame);Status=kind+" provider "+(rows.Count>0?"active":"unavailable");}
            }
        }
        void Stop(){++generation;var previous=child;child=null;rows.Clear();pending.Clear();lastFrame=0;collecting=false;
            if(previous!=null){try{if(!previous.HasExited)previous.Kill();}catch{}previous.Dispose();}}
        public void Dispose(){lock(gate){Stop();}}
    }
    static int RunProvider(string kind,IntPtr parent) {
        while(WaitForSingleObject(parent,0)==258){
            var rows=new List<string>();
            try{
                Console.WriteLine("STATUS\t"+kind+" query");Console.Out.Flush();
                if(kind=="NVIDIA"){if(enumerate==null){Console.WriteLine("STATUS\tNVIDIA initialization");Console.Out.Flush();InitNvidia();}Console.WriteLine("STATUS\tNVIDIA sensors");Console.Out.Flush();Nvidia(rows);}
                else if(kind=="AMD")Amd(rows);
                else if(kind=="CPU-clock")CpuClock(rows);
                else if(kind=="Windows-GPU")WindowsGpu(rows);
                else return 2;
            }catch(Exception e){Console.WriteLine("STATUS\t"+kind+" "+e.GetType().Name);}
            Console.WriteLine("BEGIN");foreach(var row in rows)Console.WriteLine(row);Console.WriteLine("END");Console.Out.Flush();Thread.Sleep(2000);
        }return 0;
    }
    // Stable schema: unsupported sensors remain explicit, never timing-dependent.
    internal sealed class SnapshotSchema {
        internal static readonly string[] Keys={"CPU temperature","CPU usage","CPU reported clock","RAM usage","RAM used","RAM total",
            "NVIDIA GPU name","NVIDIA GPU temperature","NVIDIA GPU usage","NVIDIA GPU core clock","NVIDIA GPU memory clock","NVIDIA GPU VRAM used","NVIDIA GPU VRAM total","NVIDIA GPU power","NVIDIA GPU fan",
            "AMD GPU name","AMD GPU temperature","AMD GPU usage","AMD GPU core clock","AMD GPU memory clock","AMD GPU VRAM used","AMD GPU VRAM total","AMD GPU chip power","AMD GPU board power","AMD GPU fan","Windows GPU busiest engine"};
        readonly Dictionary<string,string> values=new Dictionary<string,string>();
        readonly Dictionary<string,long> times=new Dictionary<string,long>();
        internal void Update(IEnumerable<string> rows,long sampled){foreach(var row in rows){int tab=row.IndexOf('\t');if(tab<1)continue;string key=row.Substring(0,tab);values[key]=row;times[key]=sampled;}}
        internal List<string> Render(long now,bool gpuStarted,bool providerStarted){var rows=new List<string>();foreach(string key in Keys){long time;string row;
            bool starting=key.StartsWith("NVIDIA")?!gpuStarted:(key.StartsWith("AMD")||key=="CPU reported clock"||key.StartsWith("Windows"))&&!providerStarted;
            if(times.TryGetValue(key,out time)&&now>=time&&now-time<=TimeSpan.FromSeconds(10).Ticks&&values.TryGetValue(key,out row))rows.Add(row);
            else rows.Add(key+"\t"+(starting?"Starting...":"Unavailable")+"\ttext");
        }return rows;}
    }
    [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] static extern bool SetDefaultDllDirectories(uint flags);
    static int Main(string[] args) {
        if(args.Length>=3&&args[args.Length-2]=="--gpu"){
            gpuHex=args[args.Length-1];try{if(gpuHex.Length>1024||gpuHex.Length%2!=0)return 2;var bytes=new byte[gpuHex.Length/2];for(int i=0;i<bytes.Length;i++)bytes[i]=Convert.ToByte(gpuHex.Substring(i*2,2),16);selectedGpu=Encoding.UTF8.GetString(bytes);}catch{return 2;}
            Array.Resize(ref args,args.Length-2);
        }
        if(args.Length!=1&&args.Length!=3)return 2;int parent;if(!int.TryParse(args[0],out parent)||parent<=0)return 2;
        SetDefaultDllDirectories(0xA00);
        var parentHandle=OpenProcess(0x00100000,false,parent);
        if(parentHandle==IntPtr.Zero)return 3;
        Console.OutputEncoding=new UTF8Encoding(false);
        if(args.Length==3){try{return args[1]=="--provider"?RunProvider(args[2],parentHandle):2;}finally{CloseHandle(parentHandle);}}
        var providers=new[]{new Provider("NVIDIA"),new Provider("AMD"),new Provider("CPU-clock"),new Provider("Windows-GPU")};
        var schema=new SnapshotSchema();
        try{while(WaitForSingleObject(parentHandle,0)==258){
            long now=DateTime.UtcNow.Ticks;var rows=new List<string>();
            try{WindowsMetrics(rows);}catch{}schema.Update(rows,now);
            foreach(var provider in providers)provider.Tick(now,schema);
            rows=schema.Render(now,providers[0].FinishedStarting,providers[1].FinishedStarting&&providers[2].FinishedStarting&&providers[3].FinishedStarting);
            var status=new List<string>();foreach(var provider in providers)if(provider.Status.Contains("starting")||provider.Status.Contains("timed out")||provider.Status.Contains("exited"))status.Add(provider.Status);
            Console.WriteLine("STATUS\t"+Clean(status.Count==0?"Available hardware readings active":string.Join("; ",status.ToArray())));
            Console.WriteLine("BEGIN");foreach(var row in rows)Console.WriteLine(row);Console.WriteLine("END");Console.Out.Flush();Thread.Sleep(2000);
        }return 0;}catch{return 4;}finally{foreach(var provider in providers)provider.Dispose();CloseHandle(parentHandle);}
    }
}
