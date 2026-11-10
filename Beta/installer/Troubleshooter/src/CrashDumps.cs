using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using Microsoft.Win32;
namespace OptiShade.TesterKit {
// Windows Error Reporting "LocalDumps" for one game executable. When on,
// Windows itself writes a dump to %LOCALAPPDATA%\CrashDumps whenever that exe
// crashes; the collector already picks those up. The setting lives under
// HKLM, so turning it on or off needs one administrator prompt. Only keys
// OptiShade created (marked OptiShadeManaged) are ever removed.
public sealed class CrashDumpState {
    public bool Enabled, ManagedByOptiShade;
    public string Folder, Detail;
}
public static class CrashDumps {
    const string Root=@"SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps";
    // Custom minidump: thread stacks and contexts, data segments, handles,
    // unloaded modules, memory map and memory referenced from stacks. Usually
    // 50-400 MB, far smaller than a full dump of a simulator.
    public const int CustomFlags=0x1|0x4|0x20|0x40|0x100|0x800|0x1000;
    public const int Keep=5;
    static bool ValidExe(string exe){return !String.IsNullOrWhiteSpace(exe)&&exe.EndsWith(".exe",StringComparison.OrdinalIgnoreCase)&&exe.IndexOfAny(new[]{'\\','/','"','\'',';','&','|','`','$'})<0&&exe.Length<=100;}
    public static CrashDumpState Read(string exe) {
        var state=new CrashDumpState();
        if(!ValidExe(exe)){state.Detail="No game executable selected.";return state;}
        try {
            using(var baseKey=RegistryKey.OpenBaseKey(RegistryHive.LocalMachine,RegistryView.Registry64))
            using(var key=baseKey.OpenSubKey(Root+@"\"+exe)) {
                if(key==null){state.Detail="Off: Windows does not save a crash dump when "+exe+" crashes.";return state;}
                state.Enabled=true;
                state.ManagedByOptiShade=Convert.ToInt32(key.GetValue("OptiShadeManaged",0))==1;
                state.Folder=Convert.ToString(key.GetValue("DumpFolder","%LOCALAPPDATA%\\CrashDumps",RegistryValueOptions.DoNotExpandEnvironmentNames));
                int type=Convert.ToInt32(key.GetValue("DumpType",1));
                state.Detail="On: Windows saves a "+(type==2?"full":type==0?"detailed":"mini")+" crash dump for "+exe+" in "+state.Folder+(state.ManagedByOptiShade?" (set by OptiShade).":" (set outside OptiShade).");
            }
        } catch(Exception e){state.Detail="Could not read the crash dump setting: "+e.GetType().Name;}
        return state;
    }
    // Returns null on success, otherwise a reason. Declining the Windows
    // prompt changes nothing. Windows' own reg.exe does the elevated write from a
    // plain .reg file: an elevated, hidden, -EncodedCommand PowerShell did the
    // same job but is a classic malware pattern that antivirus flags.
    public static string Enable(string exe){
        if(!ValidExe(exe))return "No valid game executable selected.";
        return ImportAndCheck(exe,"HKEY_LOCAL_MACHINE",true,()=>Read(exe).Enabled);
    }
    public static string Disable(string exe){
        if(!ValidExe(exe))return "No valid game executable selected.";
        var state=Read(exe);
        if(!state.Enabled)return null;
        // Checked here, unelevated: only keys OptiShade made are ever removed.
        if(!state.ManagedByOptiShade)return "This crash dump setting was made outside OptiShade, so OptiShade left it in place.";
        string failure=RunReg(new[]{"delete","\"HKLM\\"+Root+"\\"+exe+"\"","/f","/reg:64"},true);
        if(failure!=null)return failure;
        return Read(exe).Enabled?"Windows reported success, but the setting did not change.":null;
    }
    // The .reg text, also imported into HKCU by the self-test (no elevation).
    internal static string RegistryText(string hive,string exe) {
        var folder=new StringBuilder();
        foreach(byte b in Encoding.Unicode.GetBytes(@"%LOCALAPPDATA%\CrashDumps").Concat(new byte[]{0,0}))folder.Append(folder.Length>0?",":"").Append(b.ToString("x2"));
        return "Windows Registry Editor Version 5.00\r\n\r\n["+hive+"\\"+Root+"\\"+exe+"]\r\n"+
            "\"DumpFolder\"=hex(2):"+folder+"\r\n\"DumpType\"=dword:00000000\r\n"+
            "\"CustomDumpFlags\"=dword:"+CustomFlags.ToString("x8")+"\r\n\"DumpCount\"=dword:"+Keep.ToString("x8")+"\r\n\"OptiShadeManaged\"=dword:00000001\r\n";
    }
    internal static string ImportAndCheck(string exe,string hive,bool elevate,Func<bool> applied) {
        string file=Path.Combine(Path.GetTempPath(),"OptiShade-crash-dumps-"+Guid.NewGuid().ToString("N")+".reg");
        try {
            File.WriteAllText(file,RegistryText(hive,exe),Encoding.Unicode);
            string failure=RunReg(new[]{"import","\""+file+"\"","/reg:64"},elevate);
            if(failure!=null)return failure;
        } finally { try{File.Delete(file);}catch{} }
        return applied()?null:"Windows reported success, but the setting did not change.";
    }
    static string RunReg(string[] arguments,bool elevate) {
        try {
            var start=new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),"System32","reg.exe"),String.Join(" ",arguments)){WindowStyle=ProcessWindowStyle.Hidden};
            if(elevate){start.UseShellExecute=true;start.Verb="runas";}else{start.UseShellExecute=false;start.CreateNoWindow=true;}
            using(var p=Process.Start(start)) {
                if(!p.WaitForExit(60000))return "Windows did not finish changing the setting in time.";
                if(p.ExitCode!=0)return "Windows could not change the setting (code "+p.ExitCode+").";
            }
        } catch(System.ComponentModel.Win32Exception e) {
            if(e.NativeErrorCode==1223)return "Not changed: the administrator prompt was declined.";
            return "Could not ask Windows for administrator approval: "+e.Message;
        }
        return null;
    }
}
}
