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
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
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
    static EnumGpu enumerate; static NameGpu nameGpu; static ThermalGpu thermalGpu;
    static T Function<T>(Query query,uint id) where T:class {
        var p=query(id);return p==IntPtr.Zero?null:Marshal.GetDelegateForFunctionPointer(p,typeof(T)) as T;
    }
    static void InitNvidia() {
        var module=LoadLibraryEx("nvapi64.dll",IntPtr.Zero,0x800); // System32 only
        if(module==IntPtr.Zero)return;
        var address=GetProcAddress(module,"nvapi_QueryInterface");if(address==IntPtr.Zero)return;
        var q=(Query)Marshal.GetDelegateForFunctionPointer(address,typeof(Query));
        var init=Function<Init>(q,0x0150e828);if(init==null||init()!=0)return;
        enumerate=Function<EnumGpu>(q,0xe5ac921f);nameGpu=Function<NameGpu>(q,0xceee8e9f);
        thermalGpu=Function<ThermalGpu>(q,0xe3640a56);
    }
    static string Clean(string s) {return (s??"").Replace('\t',' ').Replace('\r',' ').Replace('\n',' ');}
    static void Add(List<string> rows,string label,double value) {
        if(rows.Count>=16||double.IsNaN(value)||double.IsInfinity(value)||value<0||value>150)return;
        rows.Add(Clean(label)+"\t"+value.ToString("F1",CultureInfo.InvariantCulture));
    }
    static bool Nvidia(List<string> rows) {
        if(enumerate==null||thermalGpu==null)return false;
        IntPtr[] handles=new IntPtr[64];int count;if(enumerate(handles,out count)!=0)return false;
        bool found=false;
        for(int i=0;i<Math.Min(count,64);i++) {
            var name=new StringBuilder(64);if(nameGpu==null||nameGpu(handles[i],name)!=0)name.Append("NVIDIA GPU "+(i+1));
            var t=new Thermal{version=(uint)(Marshal.SizeOf(typeof(Thermal))|(2<<16)),sensors=new Sensor[3]};
            if(thermalGpu(handles[i],15,ref t)!=0)continue;
            for(int j=0;j<Math.Min(t.count,3);j++) {
                var s=t.sensors[j];string kind=s.target==1?"":s.target==2?" memory":s.target==4?" power":null;
                if(kind==null)continue;Add(rows,name+kind,s.current);found=true;
            }
        }
        return found;
    }
    static bool Provider(List<string> rows,bool nvidia) {
        // The optional running provider supplies CPU/motherboard/AMD/Intel sensors.
        // ACPI thermal zones are deliberately not relabelled as CPU temperature.
        using(var search=new ManagementObjectSearcher(new ManagementScope(@"\\.\root\LibreHardwareMonitor"),
              new ObjectQuery("SELECT Name, Parent, Value FROM Sensor WHERE SensorType='Temperature'"),
              new EnumerationOptions{Timeout=TimeSpan.FromMilliseconds(700),ReturnImmediately=true})) {
            using(var sensors=search.Get()) {
                double cpu=-1;string cpuLabel="CPU (hottest sensor)";bool package=false;
                foreach(ManagementObject sensor in sensors)using(sensor) {
                    if(sensor["Value"]==null)continue;
                    string parent=Convert.ToString(sensor["Parent"]),name=Convert.ToString(sensor["Name"]);
                    double value=Convert.ToDouble(sensor["Value"],CultureInfo.InvariantCulture);
                    if(value<0||value>150||double.IsNaN(value)||double.IsInfinity(value))continue;
                    bool isCpu=parent.StartsWith("/amdcpu/",StringComparison.Ordinal)||parent.StartsWith("/intelcpu/",StringComparison.Ordinal);
                    if(isCpu) {
                        bool preferred=name.IndexOf("Package",StringComparison.OrdinalIgnoreCase)>=0||name.IndexOf("Tctl/Tdie",StringComparison.OrdinalIgnoreCase)>=0;
                        if((preferred&&!package)||(preferred==package&&value>cpu)){cpu=value;package=preferred;cpuLabel=preferred?"CPU package":"CPU (hottest sensor)";}
                    } else if(!(nvidia&&parent.StartsWith("/gpu-nvidia/",StringComparison.Ordinal))) {
                        // Include provider identity so two different cards/disks are not conflated.
                        Add(rows,name+" ["+parent+"]",value);
                    }
                }
                if(cpu>=0){if(rows.Count==16)rows.RemoveAt(15);rows.Insert(0,cpuLabel+"\t"+cpu.ToString("F1",CultureInfo.InvariantCulture));return true;}
            }
        }
        return false;
    }
    static int Main(string[] args) {
        if(args.Length!=1)return 2;int parent;if(!int.TryParse(args[0],out parent)||parent<=0)return 2;
        Console.OutputEncoding=new UTF8Encoding(false);try{InitNvidia();}catch{}
        while(true) {
            try{using(var p=Process.GetProcessById(parent))if(p.HasExited)return 0;}catch{return 0;}
            var rows=new List<string>();bool cpu=false,nvidia=false;
            try{nvidia=Nvidia(rows);}catch{}
            try{cpu=Provider(rows,nvidia);}catch{}
            try {
                Console.WriteLine("BEGIN");
                if(!cpu)Console.WriteLine("CPU\t-");
                if(!nvidia&&!rows.Exists(s=>s.IndexOf("gpu-",StringComparison.Ordinal)>=0))Console.WriteLine("GPU\t-");
                foreach(var row in rows)Console.WriteLine(row);
                Console.WriteLine("END");Console.Out.Flush();
            }catch{return 0;}
            Thread.Sleep(2000);
        }
    }
}
