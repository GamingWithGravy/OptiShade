// Reads documented Windows MINIDUMP streams without loading DLLs from the dump,
// executing debugger extensions, downloading symbols, or copying memory strings.
// Layout reference: Windows SDK minidumpapiset.h (4-byte structure packing).
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Diagnostics;

namespace OptiShade.Diagnostics {
public sealed class DumpSummary {
    sealed class Module { public ulong Base; public uint Size; public string Name; }
    sealed class Location { public uint Size; public uint Rva; }
    FileStream file;
    long readBytes;
    readonly Stopwatch clock = Stopwatch.StartNew();
    readonly StringBuilder text = new StringBuilder();
    readonly Dictionary<uint, Location> streams = new Dictionary<uint, Location>();
    readonly List<Module> modules = new List<Module>();
    ushort architecture = 0xffff;
    uint faultThread;
    bool hasException;

    byte[] Read(ulong offset, int count) {
        if (clock.Elapsed.TotalSeconds > 10 || readBytes + count > 8 * 1024 * 1024)
            throw new InvalidDataException("Analysis read/time budget reached");
        if (count < 0 || count > 1024 * 1024 || offset > (ulong)file.Length || (ulong)count > (ulong)file.Length - offset)
            throw new InvalidDataException("Truncated or invalid dump range");
        file.Position = (long)offset;
        byte[] data = new byte[count];
        int n = 0;
        while (n < count) { int got = file.Read(data, n, count - n); if (got == 0) throw new EndOfStreamException(); n += got; }
        readBytes += count;
        return data;
    }
    static uint U32(byte[] b, int p) { return BitConverter.ToUInt32(b, p); }
    static ulong U64(byte[] b, int p) { return BitConverter.ToUInt64(b, p); }
    static string Hex(ulong n) { return "0x" + n.ToString("X"); }
    byte[] Stream(uint kind, int required) {
        Location loc;
        if (!streams.TryGetValue(kind, out loc)) return null;
        if (loc.Size < required) throw new InvalidDataException("Truncated stream");
        return Read(loc.Rva, required);
    }
    string Name(uint rva) {
        uint size = U32(Read(rva, 4), 0);
        if (size > 32768 || (size & 1) != 0) throw new InvalidDataException("Invalid module name");
        string s = Encoding.Unicode.GetString(Read((ulong)rva + 4, (int)size));
        int slash = Math.Max(s.LastIndexOf('/'), s.LastIndexOf('\\'));
        s = s.Substring(slash + 1);
        var safe = new StringBuilder();
        foreach (char c in s) { if (safe.Length >= 256) break; if (!Char.IsControl(c)) safe.Append(c); }
        return safe.ToString();
    }
    string Resolve(ulong address) {
        foreach (var m in modules) if (address >= m.Base && address - m.Base < m.Size)
            return m.Name + "+" + Hex(address - m.Base);
        return "unmapped";
    }
    void Header() {
        byte[] h = Read(0, 32);
        if (U32(h, 0) != 0x504d444d) throw new InvalidDataException("Not a Windows MDMP file");
        if ((U32(h, 4) & 0xffff) != 0xa793) throw new InvalidDataException("Unsupported dump format version");
        uint count = U32(h, 8), rva = U32(h, 12);
        if (count > 256) throw new InvalidDataException("Too many streams");
        text.AppendLine("Dump UTC: " + new DateTime(1970,1,1,0,0,0,DateTimeKind.Utc).AddSeconds(U32(h,20)).ToString("o"));
        text.AppendLine("Dump bytes: " + file.Length + "; flags: " + Hex(U64(h,24)));
        byte[] dirs = Read(rva, (int)count * 12);
        for (int i=0;i<count;i++) {
            int p=i*12; uint kind=U32(dirs,p);
            if (!streams.ContainsKey(kind)) streams.Add(kind,new Location { Size=U32(dirs,p+4), Rva=U32(dirs,p+8) });
        }
        byte[] system = Stream(7, 24);
        if (system != null) {
            architecture=BitConverter.ToUInt16(system,0);
            text.AppendLine("Architecture: " + (architecture==9?"x64":architecture==0?"x86":architecture.ToString()) + "; processors: " + system[6]);
            text.AppendLine("Windows: " + U32(system,8)+"."+U32(system,12)+"."+U32(system,16));
        } else text.AppendLine("System information stream absent");
    }
    void Modules() {
        byte[] head=Stream(4,4);
        if(head==null) { text.AppendLine("Module list absent"); return; }
        uint count=U32(head,0); Location loc=streams[4];
        if(count>4096 || 4UL+108UL*count>loc.Size) throw new InvalidDataException("Invalid module list");
        text.AppendLine("\nLoaded modules (base, size, file version, PE timestamp; paths omitted):");
        byte[] data=Read((ulong)loc.Rva+4,(int)count*108);
        for(int i=0;i<count;i++) {
            int p=i*108; var m=new Module {Base=U64(data,p),Size=U32(data,p+8),Name=Name(U32(data,p+20))}; modules.Add(m);
            uint ms=U32(data,p+32),ls=U32(data,p+36);
            text.AppendLine(m.Name+" base="+Hex(m.Base)+" size="+Hex(m.Size)+" version="+(ms>>16)+"."+(ms&65535)+"."+(ls>>16)+"."+(ls&65535)+" timestamp="+Hex(U32(data,p+16)));
        }
    }
    void Exception() {
        byte[] e=Stream(6,168);
        if(e==null) { text.AppendLine("\nNo exception stream: this may be a manual/hang dump. No crash cause inferred."); return; }
        hasException=true; faultThread=U32(e,0); uint code=U32(e,8); ulong address=U64(e,24);
        text.AppendLine("\nException thread: "+faultThread+"; code="+Hex(code)+"; flags="+Hex(U32(e,12)));
        string kind=code==0xc0000005?"Access violation":code==0xc0000374?"Heap corruption reported":code==0xc0000409?"Fast-fail/security check failure":code==0x80000003?"Breakpoint":code==0xe06d7363?"Microsoft C++ exception":"Unclassified exception";
        text.AppendLine("Exception category: "+kind+" (category is not root cause)");
        text.AppendLine("Exception address: "+Hex(address)+" ("+Resolve(address)+")");
        uint count=U32(e,32); if(count>15) throw new InvalidDataException("Invalid exception parameters");
        if(code==0xc0000005 && count>=2) {
            ulong operation=U64(e,40);
            text.AppendLine("Access violation: "+(operation==0?"read":operation==1?"write":operation==8?"execute":"unknown")+" at "+Hex(U64(e,48)));
        }
        for(int i=0;i<count;i++) text.AppendLine("Exception parameter "+i+": "+Hex(U64(e,40+i*8)));
        Context(U32(e,164),U32(e,160),"Faulting thread context",true);
    }
    void Context(uint rva,uint size,string label,bool stack) {
        if(architecture!=9 || size<256) { text.AppendLine(label+": x64 context unavailable/unsupported"); return; }
        byte[] c=Read(rva,256);
        uint flags=U32(c,48);
        if((flags&0x100001)!=0x100001) { text.AppendLine(label+": control registers absent"); return; }
        ulong rsp=U64(c,152),rip=U64(c,248);
        text.AppendLine(label+": RIP="+Hex(rip)+" ("+Resolve(rip)+") RSP="+Hex(rsp)+" RBP="+Hex(U64(c,160)));
        if((flags&2)!=0) {
            string[] names={"RAX","RCX","RDX","RBX","RSP","RBP","RSI","RDI","R8","R9","R10","R11","R12","R13","R14","R15"};
            for(int i=0;i<names.Length;i++) text.AppendLine("  "+names[i]+"="+Hex(U64(c,120+i*8)));
        }
        if(stack) Stack(rsp);
    }
    byte[] Range(ulong address,ulong start,ulong length,ulong rva) {
        if(address<start || address-start>=length) return null;
        ulong delta=address-start;
        if(rva>ulong.MaxValue-delta) throw new InvalidDataException("Overflowed memory range");
        return Read(rva+delta,(int)Math.Min(16384UL,length-delta));
    }
    byte[] Memory(ulong address) {
        // Prefer the faulting thread's captured stack, then memory-list streams.
        byte[] head=Stream(3,4);
        if(head!=null) {
            uint count=U32(head,0); Location loc=streams[3];
            if(count>4096 || 4UL+48UL*count>loc.Size) throw new InvalidDataException("Invalid thread list");
            byte[] t=Read((ulong)loc.Rva+4,(int)count*48);
            for(int i=0;i<count;i++) {int p=i*48; if(U32(t,p)!=faultThread)continue; var b=Range(address,U64(t,p+24),U32(t,p+32),U32(t,p+36)); if(b!=null)return b;}
        }
        head=Stream(5,4);
        if(head!=null) {
            uint count=U32(head,0); Location loc=streams[5];
            if(count>65536 || 4UL+16UL*count>loc.Size) throw new InvalidDataException("Invalid memory list");
            byte[] data=Read((ulong)loc.Rva+4,(int)count*16);
            for(int i=0;i<count;i++) {int p=i*16;var b=Range(address,U64(data,p),U32(data,p+8),U32(data,p+12));if(b!=null)return b;}
        }
        head=Stream(9,16);
        if(head!=null) {
            ulong count=U64(head,0),rva=U64(head,8);Location loc=streams[9];
            if(count>65536 || 16UL+16UL*count>loc.Size) throw new InvalidDataException("Invalid full-memory list");
            byte[] data=Read((ulong)loc.Rva+16,(int)count*16);
            for(int i=0;i<(int)count;i++) {int p=i*16;ulong length=U64(data,p+8);var b=Range(address,U64(data,p),length,rva);if(b!=null)return b;if(rva>ulong.MaxValue-length)throw new InvalidDataException("Overflowed memory list");rva+=length;}
        }
        return null;
    }
    void Stack(ulong rsp) {
        text.AppendLine("\nStack address candidates: module-mapped values only. NOT an unwound call stack; values can be data/stale pointers. No function names inferred.");
        byte[] memory=Memory(rsp);
        if(memory==null) {text.AppendLine("Faulting stack memory absent from dump");return;}
        int count=0;
        for(int p=0;p+8<=memory.Length && count<128;p+=8) {
            ulong value=U64(memory,p);string name=Resolve(value);
            if(name=="unmapped")continue;
            text.AppendLine("  [RSP+"+Hex((ulong)p)+"] "+Hex(value)+" "+name);count++;
        }
        text.AppendLine("Scanned "+memory.Length+" bytes maximum; reported "+count+" candidates (cap 128).");
    }
    void Threads() {
        byte[] head=Stream(3,4);if(head==null){text.AppendLine("Thread list absent");return;}
        uint count=U32(head,0);Location loc=streams[3];
        if(count>4096 || 4UL+48UL*count>loc.Size)throw new InvalidDataException("Invalid thread list");
        text.AppendLine("\nThreads: "+count+"; first 64 instruction locations (not stacks):");
        byte[] data=Read((ulong)loc.Rva+4,(int)Math.Min(count,64)*48);
        for(int i=0;i<Math.Min(count,64);i++) {
            int p=i*48;uint id=U32(data,p),size=U32(data,p+40);
            if(architecture==9 && size>=256){byte[] c=Read(U32(data,p+44),256);if((U32(c,48)&0x100001)==0x100001)text.AppendLine("Thread "+id+(hasException&&id==faultThread?" [exception]":"")+": "+Hex(U64(c,248))+" "+Resolve(U64(c,248)));}
        }
    }
    public static string Analyze(string path) {
        var a=new DumpSummary();
        a.text.AppendLine("OptiShade crash dump summary v1\nLocal, bounded metadata extraction; no symbol downloads. Original dump unchanged.\nModule filenames retained; source paths and raw memory strings omitted.\nThis is evidence, not a root-cause verdict or a debugger-unwound stack.");
        try {
            using(a.file=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read)) {
                a.Header();a.Modules();a.Exception();a.Threads();
                if (!a.streams.ContainsKey(4) && !a.streams.ContainsKey(6) && !a.streams.ContainsKey(3))
                    throw new InvalidDataException("No usable crash streams");
                a.text.AppendLine("\nAnalysis status: completed metadata extraction");
            }
        } catch(Exception e) {
            // Do not expose exception messages containing local source paths.
            a.text.AppendLine("\nAnalysis status: incomplete/unavailable ("+e.GetType().Name+"). Dump may be locked, truncated, unsupported or exceed parser bounds. Earlier sections, if any, remain useful.");
            if(e is InvalidDataException) a.text.AppendLine("Reader detail: "+e.Message);
        }
        a.text.AppendLine("Bytes read: "+a.readBytes+"; elapsed ms: "+a.clock.ElapsedMilliseconds);
        return a.text.ToString();
    }
}
}
