using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
namespace OptiShade.TesterKit {
// The optional reason a user gives when uninstalling OptiShade. Sent privately
// through the same relay as diagnostic reports, as a tiny report that holds only
// the reason, the user's uninstall choices and the OptiShade version. Nothing is
// collected from the PC or the game.
public static class UninstallFeedback {
    // Returns 0 when sent (or there was nothing to send), 1 when it could not be sent.
    // previewZip: write the report ZIP there instead of sending it (tests).
    public static int Run(string requestPath,string previewZip) {
        string dir=null;
        try {
            if(new FileInfo(requestPath).Length>16384)return 1;
            var data=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(File.ReadAllText(requestPath,Encoding.UTF8));
            string reason=Clean(Get(data,"Reason"),80),text=Clean(Get(data,"Text"),1000),version=Clean(Get(data,"Version"),40),scope=Clean(Get(data,"Scope"),20);
            if(reason.Length==0&&text.Length==0)return 0;
            bool keptPresets=Flag(data,"KeptPresets"),keptSnapshots=Flag(data,"KeptSnapshots");
            var notes=new StringBuilder();
            notes.Append("USER-PROVIDED ISSUE DESCRIPTION\r\n");
            notes.Append("Game executable: not selected\r\n");
            notes.Append("Installed OptiShade build: "+(version.Length>0?version:"unknown")+"\r\n");
            notes.Append("PRIMARY ISSUE: UNINSTALL FEEDBACK (no diagnostics were collected)\r\n\r\n");
            notes.Append("Reason: "+(reason.Length>0?reason:"not picked")+"\r\n");
            notes.Append("Uninstall: "+(scope=="games"?"removed from all games, app kept":"removed from this PC")+"; saved looks "+(keptPresets?"kept":"removed")+"; snapshots "+(keptSnapshots?"kept":"removed")+"\r\n");
            if(text.Length>0)notes.Append("\r\n"+text.Replace("\n","\r\n")+"\r\n");
            dir=Path.Combine(Path.GetTempPath(),"OptiShade-uninstall-feedback-"+Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            string zip=Path.Combine(dir,"uninstall-feedback.zip");
            using(var archive=ZipFile.Open(zip,ZipArchiveMode.Create)) {
                var entry=archive.CreateEntry("ISSUE-DESCRIPTION.txt");
                using(var writer=new StreamWriter(entry.Open(),new UTF8Encoding(false)))writer.Write(notes.ToString());
            }
            if(!String.IsNullOrEmpty(previewZip)){File.Copy(zip,previewZip,true);return 0;}
            string description="Uninstall feedback: "+(reason.Length>0?reason:"no reason picked")+(text.Length>0?" | "+text:"");
            var upload=new ReportUpload(ReportUpload.DefaultEndpoint,(message,sent,total)=>{}){RetryDelay=attempt=>TimeSpan.FromSeconds(3)};
            upload.Send(zip,CancellationToken.None,description,"Uninstall","uninstall-feedback").GetAwaiter().GetResult();
            return 0;
        } catch {
            return 1;
        } finally {
            try{if(dir!=null&&Directory.Exists(dir))Directory.Delete(dir,true);}catch{}
            try{File.Delete(requestPath);}catch{}
        }
    }
    static string Get(Dictionary<string,object> data,string key){object value;return data!=null&&data.TryGetValue(key,out value)&&value!=null?Convert.ToString(value):"";}
    static bool Flag(Dictionary<string,object> data,string key){object value;return data!=null&&data.TryGetValue(key,out value)&&value is bool&&(bool)value;}
    // Plain text only: keep line breaks, drop other control characters, cap the length.
    static string Clean(string value,int maximum){
        string text=Regex.Replace((value??"").Replace("\r\n","\n").Replace("\r","\n"),"[\\x00-\\x09\\x0B-\\x1F\\x7F]","").Trim();
        return text.Length>maximum?text.Substring(0,maximum):text;
    }
}
}
