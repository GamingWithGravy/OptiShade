using System;
using System.IO;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
namespace OptiShade.TesterKit {
public static class HangCapture {
    [DllImport("dbghelp.dll",SetLastError=true)] static extern bool MiniDumpWriteDump(IntPtr process,uint pid,IntPtr file,uint flags,IntPtr exception,IntPtr streams,ref CallbackInfo callback);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate bool Callback(IntPtr param,IntPtr input,IntPtr output);
    [StructLayout(LayoutKind.Sequential)] struct CallbackInfo { public Callback Routine; public IntPtr Param; }
    public static bool Matches(Process p,string expected,long birth) {
        return p.StartTime.ToUniversalTime().ToFileTimeUtc()==birth && Collector.SameGameExecutable(p.MainModule.FileName,expected);
    }
    public static int Worker(string[] args) {
        string output=args[4];
        try {
            using(var p=Process.GetProcessById(Int32.Parse(args[1]))) {
                if(!Matches(p,args[3],Int64.Parse(args[2])))throw new IOException("Process identity changed; capture refused.");
                using(var f=new FileStream(output,FileMode.CreateNew,FileAccess.ReadWrite,FileShare.Read)) {
                    var timer=Stopwatch.StartNew();
                    Callback callback=(param,input,result)=> {
                        // MINIDUMP_CALLBACK_INPUT on x64 is packed to 4 bytes: PID, HANDLE, type.
                        if(Marshal.ReadInt32(input,12)==6) {
                            Marshal.WriteInt32(result,0,1);
                            Marshal.WriteInt32(result,4,(timer.Elapsed.TotalSeconds>35 || f.Length>128L*1024*1024)?1:0);
                        }
                        return true;
                    };
                    var info=new CallbackInfo{Routine=callback};
                    // Thread contexts/stacks, module list, unloaded modules, thread information and memory map.
                    // Deliberately excludes full process/heap memory (often many GB).
                    if(!MiniDumpWriteDump(p.Handle,(uint)p.Id,f.SafeFileHandle.DangerousGetHandle(),0x1820,IntPtr.Zero,IntPtr.Zero,ref info))
                        throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                    GC.KeepAlive(callback);
                    if(f.Length>128L*1024*1024)throw new IOException("Dump exceeded capture limit.");
                }
            }
            return 0;
        } catch(Exception e) {
            File.WriteAllText(output+".error.txt",e.GetType().Name+": "+e.Message);
            if(File.Exists(output))File.Delete(output);
            return 1;
        }
    }
    public static void Capture(Process target,string expected,string output,CancellationToken token,Action<string> progress) {
        long birth=target.StartTime.ToUniversalTime().ToFileTimeUtc();
        if(!Matches(target,expected,birth))throw new IOException("Selected installation does not match running process.");
        string command="--hang-worker "+target.Id+" "+birth+" \""+expected+"\" \""+output+"\"";
        using(var worker=Process.Start(new ProcessStartInfo(System.Reflection.Assembly.GetExecutingAssembly().Location,command){UseShellExecute=false,CreateNoWindow=true,WindowStyle=ProcessWindowStyle.Hidden})) {
            var timer=Stopwatch.StartNew();
            try {
                while(!worker.WaitForExit(250)) {
                    token.ThrowIfCancellationRequested();
                    progress("Capturing simulator threads and stacks ("+(int)timer.Elapsed.TotalSeconds+"s). Leave the simulator open...");
                    if(timer.Elapsed.TotalSeconds>45)throw new TimeoutException("Hang capture timed out; remaining evidence will still be collected.");
                }
                if(worker.ExitCode!=0 || !File.Exists(output))throw new IOException(File.Exists(output+".error.txt")?File.ReadAllText(output+".error.txt"):"Capture worker failed.");
            } finally {
                if(!worker.HasExited){worker.Kill();worker.WaitForExit(5000);}
            }
        }
    }
}
}
