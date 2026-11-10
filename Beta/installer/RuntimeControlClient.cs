// OptiShade additions. Local control client; no filesystem writes or game launch.
using System;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Runtime.InteropServices;
using System.Diagnostics;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using Microsoft.Win32.SafeHandles;
public static class OptiShadeControlClient {
 public const int ProtocolSchema=2;
 sealed class RuntimeResponseException:IOException { public RuntimeResponseException(string message):base(message){} }
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe,out uint pid);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFile(string name,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint GetFinalPathNameByHandle(SafeFileHandle file,StringBuilder path,uint size,uint flags);
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,uint pid);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool QueryFullProcessImageName(IntPtr process,uint flags,StringBuilder name,ref uint size);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
 static string ResponseCode(IDictionary<string,object> response){
  object raw;if(response==null||!response.TryGetValue("code",out raw)||!(raw is string))return "missing_code";
  string code=(string)raw;if(code.Length==0||code.Length>64)return "invalid_error_code";
  foreach(char ch in code)if(!((ch>='a'&&ch<='z')||(ch>='0'&&ch<='9')||ch=='_'))return "invalid_error_code";
  return code;
 }
 static string ResolveFolder(string path){
  path=Path.GetFullPath(path).TrimEnd('\\','/');
  using(var handle=CreateFile(path,0,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero)){
   if(handle.IsInvalid)throw new IOException("Cannot identify the selected installation folder");
   var value=new StringBuilder(32768);uint n=GetFinalPathNameByHandle(handle,value,(uint)value.Capacity,0);
   if(n==0||n>=value.Capacity)throw new IOException("Cannot resolve the selected installation folder");
   return value.ToString().TrimEnd('\\','/');
  }
 }
 sealed class Candidate { public uint Pid; public string Birth,Executable; }
 static Candidate Identify(Process process){
  // Query limited process information; reading MainModule is unreliable when
  // the manager and a legacy game have different bitness.
  IntPtr handle=OpenProcess(0x1000,false,(uint)process.Id);
  if(handle==IntPtr.Zero)throw new IOException("Cannot identify the game process");
  try{
   var name=new StringBuilder(32768);uint size=(uint)name.Capacity;
   if(!QueryFullProcessImageName(handle,0,name,ref size)||size==0)throw new IOException("Cannot identify the game executable");
   return new Candidate{Pid=(uint)process.Id,Executable=Path.Combine(ResolveFolder(Path.GetDirectoryName(name.ToString())),Path.GetFileName(name.ToString())),Birth=process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString(System.Globalization.CultureInfo.InvariantCulture)};
  }finally{CloseHandle(handle);}
 }
 static object ReadReceiptField(IDictionary<string,object> source,string name){object value;return source!=null&&source.TryGetValue(name,out value)?value:null;}
 static object ReadReceiptBoolean(IDictionary<string,object> source,string name){object value=ReadReceiptField(source,name);return value is bool?value:null;}
 static object ReadReceiptString(IDictionary<string,object> source,string name){object value=ReadReceiptField(source,name);return value is string?value:null;}
 static object ReadInstallerReceipt(string path){
  if(String.IsNullOrWhiteSpace(path))return null;
  try{
   string full=Path.GetFullPath(path);var attributes=File.GetAttributes(full);
   if((attributes&FileAttributes.Directory)!=0||(attributes&FileAttributes.ReparsePoint)!=0)return null;
   using(var stream=new FileStream(full,FileMode.Open,FileAccess.Read,FileShare.Read|FileShare.Delete)){
    if(stream.Length<=0||stream.Length>4*1024*1024)return null;
    using(var reader=new StreamReader(stream,new UTF8Encoding(false,true),true)){
     string text=reader.ReadToEnd();
     var parser=new JavaScriptSerializer{MaxJsonLength=4*1024*1024,RecursionLimit=32};
     var source=parser.Deserialize<Dictionary<string,object>>(text);
     if(source==null)return null;
     var policy=ReadReceiptField(source,"ProviderPolicy") as IDictionary<string,object>;
     var result=new Dictionary<string,object>{{"Game",ReadReceiptString(source,"Game")},{"Status",ReadReceiptString(source,"Status")},{"LaunchExe",ReadReceiptString(source,"LaunchExe")},
      {"SourceMfg",ReadReceiptBoolean(source,"SourceMfg")},{"OptionalMfg",ReadReceiptBoolean(source,"OptionalMfg")},{"Sm86Mfg",ReadReceiptBoolean(source,"Sm86Mfg")},{"FrameGenerationRoute",ReadReceiptString(source,"FrameGenerationRoute")}};
     if(policy!=null)result["ProviderPolicy"]=new Dictionary<string,object>{{"Schema",ReadReceiptField(policy,"Schema")},{"Channel",ReadReceiptString(policy,"Channel")},{"Requested",ReadReceiptString(policy,"Requested")},
      {"RecordedSource",ReadReceiptBoolean(policy,"RecordedSource")},{"RecordedLegacy",ReadReceiptBoolean(policy,"RecordedLegacy")},{"RecordedSm86",ReadReceiptBoolean(policy,"RecordedSm86")},{"Evidence",ReadReceiptString(policy,"Evidence")}};
     return result;
    }
   }
  }catch{return null;}
 }
 static string AttachInstallerReceipt(string snapshot,string path){
  object receipt=ReadInstallerReceipt(path);if(receipt==null)return snapshot;
  try{var parser=new JavaScriptSerializer{MaxJsonLength=32768,RecursionLimit=16};var value=parser.Deserialize<Dictionary<string,object>>(snapshot);if(value==null)return snapshot;value["installerReceipt"]=receipt;return parser.Serialize(value);}catch{return snapshot;}
 }
 static string ResolveExecutable(string executable){
  executable=Path.GetFullPath(executable);
  return Path.Combine(ResolveFolder(Path.GetDirectoryName(executable)),Path.GetFileName(executable));
 }
 static string ReadBoundSnapshot(Candidate bound){
  string result=Snapshot(bound.Pid,bound.Birth);
  using(var process=Process.GetProcessById((int)bound.Pid)){
   var current=Identify(process);
   if(current.Birth!=bound.Birth||!String.Equals(current.Executable,bound.Executable,StringComparison.OrdinalIgnoreCase))throw new InvalidDataException("Rendering process changed while reading its runtime");
  }
  var json=new JavaScriptSerializer{MaxJsonLength=32768,RecursionLimit=16};
  var value=json.Deserialize<Dictionary<string,object>>(result);
  // Manager-side operating-system evidence; never supplied by a saved receipt.
  value["binding"]=new Dictionary<string,object>{{"executable",bound.Executable},{"birth",bound.Birth},{"evidence","os_image_birth_and_pipe_pid"}};
  return json.Serialize(value);
 }
 public static Task<string> BeginSnapshot(string folder){return BeginSnapshot(folder,null,"0",0,null,null);}
 public static Task<string> BeginSnapshot(string folder,string expectedExecutable,string notBeforeBirth){return BeginSnapshot(folder,expectedExecutable,notBeforeBirth,0,null,null);}
 public static Task<string> BeginSnapshot(string folder,string expectedExecutable,string notBeforeBirth,uint expectedPid,string expectedBirth){return BeginSnapshot(folder,expectedExecutable,notBeforeBirth,expectedPid,expectedBirth,null);}
 public static Task<string> BeginSnapshot(string folder,string expectedExecutable,string notBeforeBirth,uint expectedPid,string expectedBirth,string installationReceiptPath){return Task.Run(()=>{
  string root=ResolveFolder(folder),expected=String.IsNullOrEmpty(expectedExecutable)?null:ResolveExecutable(expectedExecutable);ulong minimum;
  if(!UInt64.TryParse(notBeforeBirth,System.Globalization.NumberStyles.None,System.Globalization.CultureInfo.InvariantCulture,out minimum))throw new ArgumentException("Invalid launch session boundary");
  if(expected!=null&&!expected.StartsWith(root+"\\",StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("The rendering executable is outside the selected installation");
  Func<Candidate,bool> matches=candidate=>{
   string directory=Path.GetDirectoryName(candidate.Executable);ulong birth;
   return (String.Equals(directory,root,StringComparison.OrdinalIgnoreCase)||directory.StartsWith(root+"\\",StringComparison.OrdinalIgnoreCase))&&
    (expected==null||String.Equals(candidate.Executable,expected,StringComparison.OrdinalIgnoreCase))&&
    UInt64.TryParse(candidate.Birth,out birth)&&birth>=minimum&&
    (expectedPid==0||(candidate.Pid==expectedPid&&candidate.Birth==expectedBirth));
  };
  if(expectedPid!=0){
   using(var process=Process.GetProcessById((int)expectedPid)){
    var bound=Identify(process);if(!matches(bound))throw new InvalidDataException("The bound game session ended or changed");return AttachInstallerReceipt(ReadBoundSnapshot(bound),installationReceiptPath);
   }
  }
  var candidates=new List<Candidate>();
  // A title/helper filename is not a rendering identity. Bind the real image
  // and birth first, then require a live PID-verified OptiShade endpoint.
  foreach(var process in Process.GetProcesses())using(process){
   try{var candidate=Identify(process);if(matches(candidate))candidates.Add(candidate);}
   catch(System.ComponentModel.Win32Exception){}catch(InvalidOperationException){}catch(IOException){}catch(ArgumentException){}
  }
  if(candidates.Count>32)throw new InvalidOperationException("Too many processes match this installation. Select the actual rendering executable's folder.");
  var queries=new List<Task<string>>();
  foreach(var candidate in candidates){var bound=candidate;queries.Add(Task.Run(()=>{
   try{return ReadBoundSnapshot(bound);}
   catch(RuntimeResponseException error){return "\0"+error.Message;}
   catch(IOException){return null;}catch(TimeoutException){return null;}catch(ObjectDisposedException){return null;}catch(InvalidOperationException){return null;}catch(ArgumentException){return null;}catch(System.ComponentModel.Win32Exception){return null;}
  }));}
  Task.WaitAll(queries.ToArray());string selected=null;
  var responseErrors=new List<string>();
  foreach(var query in queries){if(query.Result==null)continue;if(query.Result.StartsWith("\0",StringComparison.Ordinal)){responseErrors.Add(query.Result.Substring(1));continue;}if(selected!=null)throw new InvalidOperationException("Multiple live OptiShade game sessions match this installation. Close the other session before changing controls.");selected=query.Result;}
  if(selected==null){if(responseErrors.Count>0)throw new InvalidDataException(String.Join("; ",responseErrors));throw new InvalidOperationException("No live OptiShade runtime matches this rendering executable and launch session. Wait for the game to render or start it through its supported launcher.");}
  return AttachInstallerReceipt(selected,installationReceiptPath);
 });}
 public static string Snapshot(uint selected){
  using(var process=Process.GetProcessById((int)selected)){return ReadBoundSnapshot(Identify(process));}
 }
 static string Snapshot(uint selected,string expectedBirth) {
  var json=new JavaScriptSerializer{MaxJsonLength=32768,RecursionLimit=16};
  var request=new Dictionary<string,object>{{"schema",ProtocolSchema},{"pid",selected},{"id",Guid.NewGuid().ToString("N")},{"operation","discover"}};
  var hello=json.Deserialize<Dictionary<string,object>>(Send(selected,json.Serialize(request)));
  if(!hello.ContainsKey("schema")||Convert.ToInt32(hello["schema"])!=ProtocolSchema||!hello.ContainsKey("pid")||Convert.ToUInt32(hello["pid"])!=selected||!hello.ContainsKey("birth")||!String.Equals(Convert.ToString(hello["birth"],System.Globalization.CultureInfo.InvariantCulture),expectedBirth,StringComparison.Ordinal))throw new InvalidDataException("Runtime discovery does not match the operating-system process birth");
  string discoveryCode=ResponseCode(hello);if(discoveryCode!="ok")throw new RuntimeResponseException("Runtime discovery failed: "+discoveryCode);
  request["birth"]=hello["birth"];request["operation"]="snapshot";request["id"]=Guid.NewGuid().ToString("N");
  string result=Send(selected,json.Serialize(request));var check=json.Deserialize<Dictionary<string,object>>(result);
  if(!check.ContainsKey("schema")||Convert.ToInt32(check["schema"])!=ProtocolSchema||!check.ContainsKey("pid")||Convert.ToUInt32(check["pid"])!=selected||!check.ContainsKey("birth")||!Equals(check["birth"],hello["birth"]))throw new InvalidDataException("Runtime session changed");
  string snapshotCode=ResponseCode(check);if(snapshotCode!="ok")throw new RuntimeResponseException("Runtime snapshot failed: "+snapshotCode);
  return result;
 }
 public static Task<string> Begin(uint pid,string request) { return Task.Run(()=>Send(pid,request)); }
 public static string Send(uint pid,string request) {
  byte[] input=Encoding.UTF8.GetBytes(request);if(input.Length>16384)throw new InvalidDataException("Control request exceeds limit");
  using(var pipe=new NamedPipeClientStream(".","OptiShade.Control.v1."+pid,PipeDirection.InOut,PipeOptions.Asynchronous))
  using(var deadline=new Timer(_=>{try{pipe.Dispose();}catch{}},null,2000,Timeout.Infinite)) {
   pipe.Connect(500);uint actual;
   if(!GetNamedPipeServerProcessId(pipe.SafePipeHandle,out actual)||actual!=pid)throw new InvalidDataException("Runtime endpoint belongs to another process");
   pipe.ReadMode=PipeTransmissionMode.Message;pipe.Write(input,0,input.Length);
   using(var output=new MemoryStream()){
    var buffer=new byte[4096];do {int count=pipe.Read(buffer,0,buffer.Length);if(count==0)throw new EndOfStreamException();output.Write(buffer,0,count);if(output.Length>32768)throw new InvalidDataException("Runtime snapshot exceeds limit");}while(!pipe.IsMessageComplete);
    pipe.Write(new byte[]{1},0,1);return Encoding.UTF8.GetString(output.ToArray());
   }
  }
 }
}
