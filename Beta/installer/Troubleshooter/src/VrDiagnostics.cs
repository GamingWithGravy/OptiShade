using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32;
using System.Web.Script.Serialization;

namespace OptiShade.TesterKit {
internal static class VrDiagnostics {
    const int ManifestLimit = 256 * 1024;
    const int MaxVrLogLines = 256;
    const int MaxVrLogLineLength = 480;
    const int MaxVrLogChars = 128 * 1024;
    static readonly Regex VrLogPattern = new Regex(
        @"(?i)(\bVR\b|OpenXR|OpenVR|XR_[A-Z0-9_]+|VDXR|Virtual Desktop|SteamVR|OpenComposite|Oculus|Mixed Reality|headset|HMD|stereo(?:scopic)?|\beyes?\b)",
        RegexOptions.Compiled);
    static readonly Regex VrModulePattern = new Regex(
        @"(?i)(openxr|openvr|vrclient|steamvr|oculus|ovr|mixed.?reality|virtual.?desktop|pimax|varjo|vive|opencomposite)",
        RegexOptions.Compiled);
    static readonly string[] RuntimeProcesses = new[]{
        "vrserver","vrmonitor","vrcompositor","vrdashboard","OVRServer_x64","OculusClient",
        "MixedRealityPortal","MixedRealityRuntime","VirtualDesktop.Streamer","VirtualDesktop.Service",
        "PimaxClient","PimaxRuntimeService","VarjoBase","VarjoCompositor","ViveConsole"
    };

    public static string OpenXrRegistrationEvidence() {
        var output=new StringBuilder(
            "Read-only OpenXR registration snapshot for 64-bit applications. Registered runtimes/layers do not prove a headset is connected or that the selected simulator opened a VR session.\r\n");
        bool found=false;
        foreach(RegistryHive hive in new[]{RegistryHive.CurrentUser,RegistryHive.LocalMachine}) {
            RegistryKey baseKey=null;
            try {
                baseKey=RegistryKey.OpenBaseKey(hive,RegistryView.Registry64);
                using(RegistryKey runtimeKey=baseKey.OpenSubKey(@"SOFTWARE\Khronos\OpenXR\1",false)) {
                    object value=runtimeKey==null?null:runtimeKey.GetValue("ActiveRuntime",null,RegistryValueOptions.DoNotExpandEnvironmentNames);
                    string path=Convert.ToString(value);
                    if(!String.IsNullOrWhiteSpace(path)) {
                        found=true;
                        output.AppendLine(hive+" ActiveRuntime: "+path);
                        output.Append(DescribeOpenXrRuntimeManifest(path));
                    } else output.AppendLine(hive+" ActiveRuntime: not registered");
                }
                foreach(string kind in new[]{"Implicit","Explicit"}) {
                    using(RegistryKey layerKey=baseKey.OpenSubKey(@"SOFTWARE\Khronos\OpenXR\1\ApiLayers\"+kind,false)) {
                        if(layerKey==null)continue;
                        string[] manifests=layerKey.GetValueNames()
                            .Where(n=>n.EndsWith(".json",StringComparison.OrdinalIgnoreCase))
                            .OrderBy(n=>n,StringComparer.OrdinalIgnoreCase).Take(32).ToArray();
                        foreach(string manifest in manifests) {
                            try {
                                if(layerKey.GetValueKind(manifest)!=RegistryValueKind.DWord)continue;
                                int disabled=Convert.ToInt32(layerKey.GetValue(manifest,null,RegistryValueOptions.DoNotExpandEnvironmentNames));
                                found=true;
                                output.AppendLine(hive+" "+kind+" API layer: "+(disabled==0?"enabled registration":"disabled registration")+" | "+manifest);
                                output.Append(DescribeOpenXrLayerManifest(manifest));
                            } catch(Exception e) {
                                output.AppendLine(hive+" "+kind+" API layer registration unavailable: "+e.GetType().Name);
                            }
                        }
                    }
                }
            } catch(Exception e) {
                output.AppendLine(hive+" OpenXR registry unavailable: "+e.GetType().Name);
            } finally {
                if(baseKey!=null)baseKey.Dispose();
            }
        }
        if(!found)output.AppendLine("No 64-bit OpenXR runtime or API-layer registration was readable.");
        output.AppendLine("Registration is configuration evidence only. See system/process.txt and analysis/VR-simulator-log.txt for selected-process and simulator evidence.");
        return output.ToString();
    }

    public static string DescribeOpenXrRuntimeManifest(string path) {
        var output=new StringBuilder();
        string manifest=NormalizeLocalPath(path);
        if(manifest==null) return "Runtime manifest: path is not a readable local path; it was not opened.\r\n";
        try {
            var info=new FileInfo(manifest);
            if(!info.Exists)return "Runtime manifest: not found at registered path.\r\n";
            if((info.Attributes&FileAttributes.ReparsePoint)!=0)return "Runtime manifest: linked file skipped.\r\n";
            if(info.Length>ManifestLimit)return "Runtime manifest: skipped above 256 KiB safety limit.\r\n";
            var serializer=new JavaScriptSerializer{MaxJsonLength=ManifestLimit,RecursionLimit=16};
            var document=serializer.Deserialize<Dictionary<string,object>>(File.ReadAllText(manifest,Encoding.UTF8));
            object runtimeValue;
            var runtime=document!=null&&document.TryGetValue("runtime",out runtimeValue)?runtimeValue as Dictionary<string,object>:null;
            if(runtime==null)return "Runtime manifest: JSON has no runtime object.\r\n";
            string name=ReadString(runtime,"name");
            string api=ReadString(runtime,"api_version");
            string library=ReadString(runtime,"library_path");
            output.AppendLine("Runtime name: "+Limited(name,256,"not listed"));
            output.AppendLine("Runtime API version: "+Limited(api,64,"not listed"));
            output.AppendLine("Runtime manifest: "+manifest+" | "+info.Length+" bytes | modified UTC "+info.LastWriteTimeUtc.ToString("o"));
            if(String.IsNullOrWhiteSpace(library)) {
                output.AppendLine("Runtime library: not listed");
                return output.ToString();
            }
            string libraryPath=ResolveManifestPath(manifest,library);
            output.AppendLine("Runtime library: "+libraryPath);
            if(libraryPath.StartsWith(@"\\",StringComparison.Ordinal)) {
                output.AppendLine("Runtime library file: network path; metadata not read");
                return output.ToString();
            }
            try {
                var libraryInfo=new FileInfo(libraryPath);
                if(!libraryInfo.Exists)output.AppendLine("Runtime library file: not found");
                else if((libraryInfo.Attributes&FileAttributes.ReparsePoint)!=0)output.AppendLine("Runtime library file: linked file; version not read");
                else output.AppendLine("Runtime library file: "+libraryInfo.Name+" | "+libraryInfo.Length+" bytes | version "+Limited(FileVersionInfo.GetVersionInfo(libraryInfo.FullName).FileVersion,64,"unavailable"));
            } catch(Exception e) {
                output.AppendLine("Runtime library file details unavailable: "+e.GetType().Name);
            }
        } catch(Exception e) {
            output.AppendLine("Runtime manifest unavailable or invalid: "+e.GetType().Name);
        }
        return output.ToString();
    }

    static string DescribeOpenXrLayerManifest(string path) {
        string manifest=NormalizeLocalPath(path);
        if(manifest==null)return "Layer manifest: non-local path skipped.\r\n";
        try {
            var info=new FileInfo(manifest);
            if(!info.Exists)return "Layer manifest: not found.\r\n";
            if((info.Attributes&FileAttributes.ReparsePoint)!=0 || info.Length>ManifestLimit)return "Layer manifest: linked or above 256 KiB; skipped.\r\n";
            var serializer=new JavaScriptSerializer{MaxJsonLength=ManifestLimit,RecursionLimit=16};
            var document=serializer.Deserialize<Dictionary<string,object>>(File.ReadAllText(manifest,Encoding.UTF8));
            object layerValue;
            var layer=document!=null&&document.TryGetValue("api_layer",out layerValue)?layerValue as Dictionary<string,object>:null;
            if(layer==null)return "Layer manifest: JSON has no api_layer object.\r\n";
            string name=ReadString(layer,"name");
            string api=ReadString(layer,"api_version");
            string library=ReadString(layer,"library_path");
            var output=new StringBuilder();
            output.AppendLine("Layer name: "+Limited(name,256,"not listed")+" | API "+Limited(api,64,"not listed"));
            if(!String.IsNullOrWhiteSpace(library))output.AppendLine("Layer library: "+ResolveManifestPath(manifest,library));
            return output.ToString();
        } catch(Exception e) {
            return "Layer manifest unavailable or invalid: "+e.GetType().Name+"\r\n";
        }
    }

    static string NormalizeLocalPath(string path) {
        if(String.IsNullOrWhiteSpace(path))return null;
        try {
            string expanded=Environment.ExpandEnvironmentVariables(path.Trim());
            if(!Path.IsPathRooted(expanded)||expanded.StartsWith(@"\\",StringComparison.Ordinal))return null;
            return Path.GetFullPath(expanded);
        } catch {return null;}
    }
    static string ResolveManifestPath(string manifest,string value) {
        try {
            string expanded=Environment.ExpandEnvironmentVariables(value.Trim());
            string candidate=Path.IsPathRooted(expanded)?expanded:Path.Combine(Path.GetDirectoryName(manifest),expanded);
            return Path.GetFullPath(candidate);
        } catch {return value;}
    }
    static string ReadString(Dictionary<string,object> map,string name) {
        object value;
        return map!=null&&map.TryGetValue(name,out value)?Convert.ToString(value):"";
    }
    static string Limited(string value,int max,string fallback) {
        if(String.IsNullOrWhiteSpace(value))return fallback;
        string normalized=value.Replace('\r',' ').Replace('\n',' ').Trim();
        return normalized.Length>max?normalized.Substring(0,max):normalized;
    }

    public static string RuntimeProcessSnapshot() {
        var output=new StringBuilder("Read-only snapshot of common VR runtime/helper processes at collection time. Presence does not prove the selected simulator is using a runtime or that a headset session is active.\r\n");
        int captured=0;
        foreach(string name in RuntimeProcesses) {
            Process[] processes;
            try {processes=Process.GetProcessesByName(name);} catch {continue;}
            foreach(Process process in processes.Take(8)) using(process) {
                if(captured>=64)break;
                string started="unavailable",fileName="unavailable",version="unavailable";
                try {started=process.StartTime.ToUniversalTime().ToString("o");} catch {}
                try {
                    string full=process.MainModule.FileName;
                    fileName=Path.GetFileName(full);
                    version=Limited(FileVersionInfo.GetVersionInfo(full).FileVersion,64,"unavailable");
                } catch {}
                output.AppendLine(process.ProcessName+" | PID "+process.Id+" | started UTC "+started+" | "+fileName+" | version "+version);
                captured++;
            }
            foreach(Process process in processes) {
                try {process.Dispose();} catch {}
            }
            if(captured>=64)break;
        }
        if(captured==0)output.AppendLine("No process from the bounded common-runtime list was observed.");
        return output.ToString();
    }

    public static bool IsVrModule(string moduleName) {
        return !String.IsNullOrWhiteSpace(moduleName)&&VrModulePattern.IsMatch(moduleName);
    }

    public static string SelectedGameVrModules(IEnumerable<ProcessModule> modules) {
        var output=new StringBuilder("VR/OpenXR-related modules observed in the selected simulator process; module presence is not proof of an active headset session or rendered VR output:\r\n");
        int count=0;
        try {
            foreach(ProcessModule module in modules.Where(m=>m!=null&&IsVrModule(m.ModuleName)).Take(64)) {
                output.AppendLine(module.ModuleName+" | version "+Limited(module.FileVersionInfo.FileVersion,64,"unavailable"));
                count++;
            }
        } catch(Exception e) {
            output.AppendLine("Module snapshot incomplete: "+e.GetType().Name);
            return output.ToString();
        }
        if(count==0)output.AppendLine("No matching VR/OpenXR module observed in this process snapshot.");
        return output.ToString();
    }

    public static bool IsVrLogLine(string line) {
        return !String.IsNullOrWhiteSpace(line)&&VrLogPattern.IsMatch(line);
    }

    public static string FilterSimulatorLogEvidence(string text) {
        var matches=new List<string>();
        string[] lines=(text??"").Split(new[]{"\r\n","\n","\r"},StringSplitOptions.None);
        foreach(string raw in lines) {
            if(!IsVrLogLine(raw))continue;
            string line=raw.Trim();
            if(line.Length>MaxVrLogLineLength)line=line.Substring(0,MaxVrLogLineLength)+" [line truncated]";
            matches.Add(line);
        }
        var output=new StringBuilder();
        output.AppendLine("VR-focused lines from the selected simulator's Log.txt capture. These lines are evidence only and do not establish that a headset session or OptiShade output was active.");
        output.AppendLine("Matching lines found: "+matches.Count+"; maximum retained: "+MaxVrLogLines+"; maximum line length: "+MaxVrLogLineLength+".");
        if(matches.Count==0) {
            output.AppendLine("No VR/OpenXR-related lines found in the captured window; this does not prove VR was inactive.");
            return output.ToString();
        }
        var retained=new List<string>();
        if(matches.Count<=MaxVrLogLines)retained.AddRange(matches);
        else {
            retained.AddRange(matches.Take(24));
            retained.Add("[... older matching lines omitted ...]");
            retained.AddRange(matches.Skip(matches.Count-(MaxVrLogLines-25)));
        }
        int written=0;
        foreach(string line in retained) {
            if(output.Length+line.Length+2>MaxVrLogChars)break;
            output.AppendLine(line);written++;
        }
        if(written<retained.Count)output.AppendLine("[remaining lines omitted at 128 KiB cap]");
        return output.ToString();
    }
}
}
