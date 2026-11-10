using System;
using System.IO;
using System.Text;

namespace OptiShade.TesterKit {
static class VrDiagnosticsTests {
    static void Check(bool condition,string message) {
        if(!condition)throw new Exception("VR diagnostics assertion failed: "+message);
    }
    static void Main() {
        string root=Path.Combine(Path.GetTempPath(),"optishade-vr-diagnostics-"+Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try {
            string library=Path.Combine(root,"runtime.dll");
            File.WriteAllText(library,"test runtime identity fixture");
            string manifest=Path.Combine(root,"runtime.json");
            File.WriteAllText(manifest,"{\"file_format_version\":\"1.0.0\",\"runtime\":{\"name\":\"Fixture OpenXR Runtime\",\"api_version\":\"1.0\",\"library_path\":\"runtime.dll\"}}");
            string runtime=VrDiagnostics.DescribeOpenXrRuntimeManifest(manifest);
            Check(runtime.Contains("Fixture OpenXR Runtime"),"runtime manifest name is retained");
            Check(runtime.Contains("Runtime API version: 1.0"),"runtime API version is retained");
            Check(runtime.Contains("runtime.dll"),"runtime library identity is retained");
            Check(!runtime.Contains("test runtime identity fixture"),"manifest content is not copied into the report");

            string remote=VrDiagnostics.DescribeOpenXrRuntimeManifest(@"\\example.invalid\share\runtime.json");
            Check(remote.Contains("not a readable local path"),"network runtime manifests are not opened");
            string oversized=Path.Combine(root,"oversized.json");
            File.WriteAllText(oversized,new string('x',256*1024+1),Encoding.UTF8);
            Check(VrDiagnostics.DescribeOpenXrRuntimeManifest(oversized).Contains("above 256 KiB"),"oversized manifests are bounded");

            Check(VrDiagnostics.IsVrModule("openxr_loader.dll"),"OpenXR loader is recognized");
            Check(VrDiagnostics.IsVrModule("vrclient_x64.dll"),"OpenVR client is recognized");
            Check(!VrDiagnostics.IsVrModule("d3d12.dll"),"ordinary graphics modules are not classified as VR");
            Check(VrDiagnostics.IsVrLogLine("VDXR runtime detected: version 1.0.10"),"VDXR startup evidence is recognized");
            Check(VrDiagnostics.IsVrLogLine("OpenXR session created"),"OpenXR session evidence is recognized");

            var log=new StringBuilder();
            log.AppendLine("X-Plane startup");
            log.AppendLine("VDXR runtime detected: version 1.0.10");
            for(int i=0;i<300;i++)log.AppendLine("VR frame sample "+i);
            log.AppendLine("OpenXR session created; stereo view family");
            log.AppendLine("VR session stopping");
            string filtered=VrDiagnostics.FilterSimulatorLogEvidence(log.ToString());
            Check(filtered.Contains("VDXR runtime detected: version 1.0.10"),"initial runtime discovery is preserved");
            Check(filtered.Contains("VR frame sample 299"),"recent VR activity is preserved");
            Check(filtered.Contains("VR session stopping"),"latest session state is preserved");
            Check(!filtered.Contains("X-Plane startup"),"unrelated simulator lines are excluded");
            Check(filtered.Length<=128*1024,"filtered VR evidence is capped");
            Check(filtered.Contains("Matching lines found: 303"),"line count makes truncation explicit");
            Check(VrDiagnostics.FilterSimulatorLogEvidence("ordinary simulator line").Contains("does not prove VR was inactive"),"absence is not interpreted as VR being off");

            Check(VrDiagnostics.OpenXrRegistrationEvidence().Contains("do not prove a headset is connected"),"registry evidence is explicitly qualified");
            Console.WriteLine("VR diagnostics manifest, module classification, bounded log filtering and evidence wording passed.");
        } finally {
            try{Directory.Delete(root,true);}catch{}
        }
    }
}
}
