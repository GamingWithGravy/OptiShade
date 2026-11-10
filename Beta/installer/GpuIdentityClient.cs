// Inventory only. A DXGI/CUDA match can prepare a candidate; the game's actual
// rendering device and provider/output generation still qualify each session.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

public sealed class OptiShadeAdapterFact {
 public string Name,Luid,LuidHex,ArchitectureEvidence,DriverVersion;
 public uint VendorId,DeviceId,SubSystemId,Revision,NodeMask;
 public bool Software,ComputeCapabilityKnown;
 public int ComputeMajor,ComputeMinor,Family;
}
public sealed class OptiShadeGpuProbe { public OptiShadeAdapterFact[] Adapters; public string Error; public bool Complete; }
public static class OptiShadeGpuIdentity {
 [StructLayout(LayoutKind.Sequential)] struct Luid { public uint Low; public int High; public ulong Value {get{return ((ulong)(uint)High<<32)|Low;}} }
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct AdapterDescription {
  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string Description;
  public uint VendorId,DeviceId,SubSystemId,Revision;
  public UIntPtr DedicatedVideoMemory,DedicatedSystemMemory,SharedSystemMemory;
  public Luid AdapterLuid; public uint Flags;
 }
 [DllImport("dxgi.dll",ExactSpelling=true),DefaultDllImportSearchPaths(DllImportSearchPath.System32)] static extern int CreateDXGIFactory1(ref Guid iid,out IntPtr factory);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr LoadLibraryEx(string file,IntPtr reserved,uint flags);
 [DllImport("kernel32.dll",CharSet=CharSet.Ansi,ExactSpelling=true)] static extern IntPtr GetProcAddress(IntPtr module,string name);
 [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr module);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int EnumAdapters1(IntPtr factory,uint index,out IntPtr adapter);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int GetDescription1(IntPtr adapter,out AdapterDescription description);
 [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int CudaInit(uint flags);
 [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int CudaCount(out int count);
 [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int CudaDevice(out int device,int ordinal);
 [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int CudaLuid([Out,MarshalAs(UnmanagedType.LPArray,SizeConst=8)] byte[] luid,out uint nodeMask,int device);
 [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int CudaAttribute(out int value,int attribute,int device);
 static T Function<T>(IntPtr pointer) where T:class {
  if(pointer==IntPtr.Zero)throw new EntryPointNotFoundException(typeof(T).Name);
  return (T)(object)Marshal.GetDelegateForFunctionPointer(pointer,typeof(T));
 }
 static T Method<T>(IntPtr instance,int index) where T:class {return Function<T>(Marshal.ReadIntPtr(Marshal.ReadIntPtr(instance),index*IntPtr.Size));}
 // CUDA capability, not the digits in a marketing name. Turing also includes
 // GTX parts without RTX tensor features, so they are not NR/MFG candidates.
 // https://developer.nvidia.com/cuda/gpus
 public static int FamilyFor(string name,int major,int minor){
  if(String.IsNullOrEmpty(name)||!Regex.IsMatch(name,@"\bRTX\b",RegexOptions.IgnoreCase))return 0;
  if(major==7&&minor==5)return 20;
  if(major==8&&minor==6)return 30;
  if(major==8&&minor==9)return 40;
  if(major==12&&minor==0)return 50;
  return 0;
 }
 public static OptiShadeGpuProbe Read(){
  var facts=new List<OptiShadeAdapterFact>();string error="";bool complete=false;
  if(Environment.OSVersion.Platform!=PlatformID.Win32NT)return new OptiShadeGpuProbe{Adapters=facts.ToArray(),Error="DXGI hardware identity requires Windows"};
  IntPtr factory=IntPtr.Zero;
  try{
   Guid iid=new Guid("770aae78-f26f-4dba-a829-253c83d1b387");Marshal.ThrowExceptionForHR(CreateDXGIFactory1(ref iid,out factory));
   var enumerate=Method<EnumAdapters1>(factory,12);
   for(uint index=0;index<64;index++){
    IntPtr adapter;int result=enumerate(factory,index,out adapter);if(result==unchecked((int)0x887A0002)){complete=true;break;}Marshal.ThrowExceptionForHR(result);
    try{
     AdapterDescription description;Marshal.ThrowExceptionForHR(Method<GetDescription1>(adapter,10)(adapter,out description));
     facts.Add(new OptiShadeAdapterFact{Name=description.Description,Luid=description.AdapterLuid.Value.ToString(System.Globalization.CultureInfo.InvariantCulture),LuidHex=description.AdapterLuid.Value.ToString("X16"),VendorId=description.VendorId,DeviceId=description.DeviceId,SubSystemId=description.SubSystemId,Revision=description.Revision,Software=(description.Flags&2)!=0,ArchitectureEvidence="DXGI inventory; compute capability unknown",DriverVersion=""});
    }finally{if(adapter!=IntPtr.Zero)Marshal.Release(adapter);}
   }
  }catch(Exception failure){error="DXGI inventory unavailable: "+failure.GetType().Name;}
  finally{if(factory!=IntPtr.Zero)Marshal.Release(factory);}
  bool nvidia=false;foreach(var fact in facts)if(fact.VendorId==0x10DE&&!fact.Software)nvidia=true;
  if(nvidia){
   IntPtr driver=IntPtr.Zero;
   try{
    // Never load a similarly named game-local DLL or an arbitrary download.
    string path=Path.Combine(Environment.SystemDirectory,"nvcuda.dll");driver=LoadLibraryEx(path,IntPtr.Zero,0x800);
    if(driver==IntPtr.Zero)throw new DllNotFoundException("System NVIDIA CUDA driver");
    var init=Function<CudaInit>(GetProcAddress(driver,"cuInit"));var count=Function<CudaCount>(GetProcAddress(driver,"cuDeviceGetCount"));
    var get=Function<CudaDevice>(GetProcAddress(driver,"cuDeviceGet"));var luid=Function<CudaLuid>(GetProcAddress(driver,"cuDeviceGetLuid"));var attribute=Function<CudaAttribute>(GetProcAddress(driver,"cuDeviceGetAttribute"));
    int devices;if(init(0)!=0||count(out devices)!=0||devices<0||devices>64)throw new InvalidOperationException("CUDA inventory unavailable");
    var versionInfo=FileVersionInfo.GetVersionInfo(path);
    string version=String.Format(System.Globalization.CultureInfo.InvariantCulture,"nvcuda-file:{0}.{1}.{2}.{3}",versionInfo.FileMajorPart,versionInfo.FileMinorPart,versionInfo.FileBuildPart,versionInfo.FilePrivatePart);
    if(versionInfo.FileMajorPart==0&&versionInfo.FileMinorPart==0&&versionInfo.FileBuildPart==0&&versionInfo.FilePrivatePart==0)throw new InvalidOperationException("NVIDIA system driver file version unavailable");
    // cuDeviceGetLuid is the documented DXGI interop identity; no context or
    // feature is created. Attribute 75/76 are CUDA's major/minor capability.
    // https://docs.nvidia.com/cuda/cuda-driver-api/cuda_driver_api/group__CUDA__DEVICE.html
    for(int index=0;index<devices;index++){
     int device,major,minor;uint mask;var bytes=new byte[8];
     if(get(out device,index)!=0||luid(bytes,out mask,device)!=0||mask==0||attribute(out major,75,device)!=0||attribute(out minor,76,device)!=0)continue;
     ulong value=BitConverter.ToUInt64(bytes,0);if(value==0)continue;
     var matches=facts.FindAll(f=>f.VendorId==0x10DE&&!f.Software&&f.Luid==value.ToString(System.Globalization.CultureInfo.InvariantCulture));
     if(matches.Count!=1)continue;
     var fact=matches[0];fact.ComputeCapabilityKnown=true;fact.ComputeMajor=major;fact.ComputeMinor=minor;fact.NodeMask=mask;fact.Family=FamilyFor(fact.Name,major,minor);fact.DriverVersion=version;fact.ArchitectureEvidence="System CUDA driver matched to DXGI LUID; compute capability "+major+"."+minor;
    }
   }catch(Exception failure){error+=(error.Length>0?"; ":"")+"NVIDIA architecture unavailable: "+failure.GetType().Name;}
   finally{if(driver!=IntPtr.Zero)FreeLibrary(driver);}
  }
  return new OptiShadeGpuProbe{Adapters=facts.ToArray(),Error=error,Complete=complete};
 }
}
