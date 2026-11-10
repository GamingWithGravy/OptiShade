using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
namespace OptiShade.TesterKit {
// Private report upload through the OptiShade diagnostics relay (Cloudflare
// Worker -> private GitHub storage). This EXE holds no storage credential: the
// relay returns a report ID and an expiring upload pass for that report only.
// The local ZIP is never changed or deleted.
public sealed class UploadFailed : Exception {
    public readonly bool Retryable;
    public UploadFailed(string message,bool retryable):base(message){Retryable=retryable;}
}
public sealed class ReportUpload {
    public const string DefaultEndpoint="https://optishade-diagnostics.optishadedev.workers.dev";
    public const long PartSize=50000000;
    const int Schema=1, Attempts=4;
    static readonly HttpClient client=CreateClient();
    static HttpClient CreateClient() {
        // Normal certificate validation; TLS 1.2 or newer.
        ServicePointManager.SecurityProtocol|=SecurityProtocolType.Tls12|(SecurityProtocolType)12288;
        ServicePointManager.Expect100Continue=false;
        var c=new HttpClient{Timeout=TimeSpan.FromHours(3)};
        c.DefaultRequestHeaders.UserAgent.ParseAdd("OptiShade-Troubleshooter/"+Collector.Version);
        return c;
    }
    readonly string endpoint;
    readonly Action<string,long,long> progress;
    public Func<int,TimeSpan> RetryDelay=attempt=>TimeSpan.FromSeconds(5*Math.Pow(3,attempt));
    public ReportUpload(string endpoint,Action<string,long,long> progress) {
        var uri=new Uri(endpoint);
        if(uri.Scheme!="https")throw new ArgumentException("The diagnostics relay must use HTTPS.");
        this.endpoint=endpoint.TrimEnd('/');this.progress=progress;
    }
    public static string StatePath(string zip){return zip+".upload.json";}

    sealed class State { public string ReportId, UploadPass, ExpiresAt, Sha256; public long Size; public bool Complete; }

    // description: the tester's own words from the report screen (also inside
    // the ZIP); game: the tested executable name. Both are shown to the
    // developer in the private report index.
    public async Task<string> Send(string zip,CancellationToken token,string description=null,string game=null,string kind="zip") {
        var info=new FileInfo(zip);
        if(!info.Exists)throw new UploadFailed("The diagnostic ZIP is missing: "+Path.GetFileName(zip),false);
        long size=info.Length;
        int parts=(int)((size+PartSize-1)/PartSize);
        progress("Checking the report file before sending...",0,size);
        string whole;string[] partHashes=Hash(zip,parts,token,out whole);
        State state=Load(zip);
        if(state!=null && (state.Size!=size || state.Sha256!=whole))state=null;
        if(state!=null && state.Complete){progress("This report was already sent.",size,size);return state.ReportId;}
        var done=new HashSet<int>();
        if(state!=null) {
            DateTime expires;
            if(!DateTime.TryParse(state.ExpiresAt,null,System.Globalization.DateTimeStyles.RoundtripKind,out expires)||expires<DateTime.UtcNow.AddMinutes(30))state=null;
            else try {
                var status=await Call(HttpMethod.Get,"/v1/reports/"+state.ReportId,null,state.UploadPass,token);
                foreach(var p in (System.Collections.ArrayList)status["parts"]) {
                    var part=(Dictionary<string,object>)p;
                    if((string)part["state"]=="verified")done.Add(Convert.ToInt32(part["part"]));
                }
                progress("Resuming report "+state.ReportId+" ("+done.Count+" of "+parts+" part(s) already stored)...",done.Count*PartSize,size);
            } catch(UploadFailed e) {if(e.Retryable)throw;state=null;done.Clear();}
        }
        if(state==null) {
            progress("Starting a private report...",0,size);
            var body=new Dictionary<string,object>{{"schema",Schema},{"size",size},{"partSize",PartSize},{"parts",parts},{"sha256",whole},{"partSha256",partHashes},{"client","Troubleshooter "+Collector.Version},{"kind",kind},{"description",description??""},{"game",game??""}};
            var created=await Call(HttpMethod.Post,"/v1/reports",new StringContent(new JavaScriptSerializer().Serialize(body),Encoding.UTF8,"application/json"),null,token);
            state=new State{ReportId=(string)created["reportId"],UploadPass=(string)created["uploadPass"],ExpiresAt=(string)created["expiresAt"],Size=size,Sha256=whole};
            Save(zip,state);
        }
        for(int n=0;n<parts;n++) {
            if(done.Contains(n))continue;
            await SendPart(zip,state,n,parts,size,partHashes[n],token);
        }
        progress("Confirming every part with private storage...",size,size);
        Dictionary<string,object> complete=null;
        for(int attempt=0;;attempt++) {
            // C# 5: no await inside catch, so the retry wait follows it.
            try{complete=await Call(HttpMethod.Post,"/v1/reports/"+state.ReportId+"/complete",null,state.UploadPass,token);break;}
            catch(UploadFailed e){if(!e.Retryable||attempt>=Attempts-1)throw;}
            await Task.Delay(RetryDelay(attempt),token);
        }
        if(!(complete["complete"] is bool) || !(bool)complete["complete"])throw new UploadFailed("Private storage did not confirm the report.",true);
        state.Complete=true;Save(zip,state);
        return state.ReportId;
    }

    async Task SendPart(string zip,State state,int n,int parts,long size,string hash,CancellationToken token) {
        long offset=n*PartSize, length=Math.Min(PartSize,size-offset);
        for(int attempt=0;;attempt++) {
            token.ThrowIfCancellationRequested();
            try {
                using(var file=new FileStream(zip,FileMode.Open,FileAccess.Read,FileShare.Read,1<<16,FileOptions.SequentialScan)) {
                    var body=new PartStream(file,offset,length,sent=>progress("Sending part "+(n+1)+" of "+parts+"...",offset+sent,size),token);
                    var content=new StreamContent(body,1<<16);
                    content.Headers.ContentType=new MediaTypeHeaderValue("application/octet-stream");
                    content.Headers.ContentLength=length;
                    var request=new HttpRequestMessage(HttpMethod.Put,endpoint+"/v1/reports/"+state.ReportId+"/parts/"+n){Content=content};
                    request.Headers.Add("x-part-sha256",hash);
                    await Execute(request,state.UploadPass,token);
                }
                return;
            } catch(UploadFailed e) {
                if(!e.Retryable||attempt>=Attempts-1)throw;
                progress("Part "+(n+1)+" did not finish ("+e.Message+"). Retrying...",offset,size);
            }
            await Task.Delay(RetryDelay(attempt),token);
        }
    }

    Task<Dictionary<string,object>> Call(HttpMethod method,string path,HttpContent content,string pass,CancellationToken token) {
        return Execute(new HttpRequestMessage(method,endpoint+path){Content=content},pass,token);
    }
    async Task<Dictionary<string,object>> Execute(HttpRequestMessage request,string pass,CancellationToken token) {
        if(pass!=null)request.Headers.Authorization=new AuthenticationHeaderValue("Bearer",pass);
        HttpResponseMessage response;
        try{response=await client.SendAsync(request,token);}
        catch(OperationCanceledException){if(token.IsCancellationRequested)throw;throw new UploadFailed("the connection timed out",true);}
        catch(HttpRequestException e){throw new UploadFailed("could not reach the OptiShade diagnostics service ("+Innermost(e)+")",true);}
        using(response) {
            string text=await response.Content.ReadAsStringAsync();
            Dictionary<string,object> body=null;
            try{body=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(text);}catch{}
            int code=(int)response.StatusCode;
            if(code>=200&&code<300&&body!=null)return body;
            string message=body!=null&&body.ContainsKey("message")?Convert.ToString(body["message"]):"HTTP "+code+" from the diagnostics service";
            string error=body!=null&&body.ContainsKey("error")?Convert.ToString(body["error"]):"";
            bool retryable=code>=500||code==408||code==429||error=="part_conflict"||error=="part_hash_mismatch"||error=="part_size_mismatch"||error=="report_incomplete";
            throw new UploadFailed(message,retryable);
        }
    }
    static string Innermost(Exception e){while(e.InnerException!=null)e=e.InnerException;return e.Message;}

    string[] Hash(string zip,int parts,CancellationToken token,out string whole) {
        var result=new string[parts];
        using(var all=SHA256.Create())
        using(var file=new FileStream(zip,FileMode.Open,FileAccess.Read,FileShare.Read,1<<16,FileOptions.SequentialScan)) {
            byte[] buffer=new byte[1<<20];long total=file.Length,read=0;
            for(int n=0;n<parts;n++) {
                using(var part=SHA256.Create()) {
                    long remaining=Math.Min(PartSize,total-read);
                    while(remaining>0) {
                        token.ThrowIfCancellationRequested();
                        int got=file.Read(buffer,0,(int)Math.Min(buffer.Length,remaining));
                        if(got<=0)throw new UploadFailed("The diagnostic ZIP changed while it was being read.",false);
                        part.TransformBlock(buffer,0,got,null,0);all.TransformBlock(buffer,0,got,null,0);
                        remaining-=got;read+=got;
                    }
                    part.TransformFinalBlock(buffer,0,0);result[n]=Hex(part.Hash);
                }
                progress("Checking the report file before sending...",read,total);
            }
            all.TransformFinalBlock(buffer,0,0);whole=Hex(all.Hash);
        }
        return result;
    }
    static string Hex(byte[] b){return BitConverter.ToString(b).Replace("-","").ToLowerInvariant();}

    static State Load(string zip) {
        try{string path=StatePath(zip);return File.Exists(path)?new JavaScriptSerializer().Deserialize<State>(File.ReadAllText(path)):null;}catch{return null;}
    }
    static void Save(string zip,State state) {
        string path=StatePath(zip),temp=path+".tmp";
        File.WriteAllText(temp,new JavaScriptSerializer().Serialize(state));
        if(File.Exists(path))File.Delete(path);
        File.Move(temp,path);
    }
}
// Reports waiting to be sent live here, out of the tester's way, only until
// they are sent (or the 48-hour upload pass has expired).
public sealed class PendingReport { public string Zip, Notes, Game; }
public static class PendingReports {
    public static string Root {
        get {
            string configured=Environment.GetEnvironmentVariable("OPTISHADE_PENDING_REPORTS_DIR");
            return String.IsNullOrWhiteSpace(configured)?Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"OptiShade","PendingReports"):Path.GetFullPath(configured);
        }
    }
    static readonly TimeSpan Lifetime=TimeSpan.FromHours(47);
    public static string NewFolder() {
        string dir=Path.Combine(Root,DateTime.UtcNow.ToString("yyyyMMdd-HHmmss")+"-"+Guid.NewGuid().ToString("N").Substring(0,8));
        Directory.CreateDirectory(dir);return dir;
    }
    public static void Discard(string dir) {
        try {
            if(String.IsNullOrWhiteSpace(dir))return;
            string full=Path.GetFullPath(dir),root=Path.GetFullPath(Root).TrimEnd('\\')+"\\";
            // Only ever delete inside the pending store.
            if(full.StartsWith(root,StringComparison.OrdinalIgnoreCase)&&Directory.Exists(full))Directory.Delete(full,true);
        } catch {}
    }
    public static void Cleanup() {
        try {
            if(!Directory.Exists(Root))return;
            foreach(string dir in Directory.GetDirectories(Root)) {
                bool keep=Directory.GetCreationTimeUtc(dir)>DateTime.UtcNow-Lifetime && Directory.GetFiles(dir,"*.zip").Length>0;
                if(!keep)Discard(dir);
            }
        } catch {}
    }
    public static PendingReport Unsent() {
        try {
            if(!Directory.Exists(Root))return null;
            foreach(string dir in Directory.GetDirectories(Root).OrderByDescending(Directory.GetCreationTimeUtc)) {
                if(Directory.GetCreationTimeUtc(dir)<DateTime.UtcNow-Lifetime)continue;
                string zip=Directory.GetFiles(dir,"*.zip").FirstOrDefault();
                if(zip==null)continue;
                string notes="",game="";
                try {
                    using(var archive=System.IO.Compression.ZipFile.OpenRead(zip)) {
                        var entry=archive.GetEntry("ISSUE-DESCRIPTION.txt");
                        if(entry!=null)using(var reader=new StreamReader(entry.Open())) {
                            string text=reader.ReadToEnd();
                            var m=System.Text.RegularExpressions.Regex.Match(text,@"Game executable: (.+)\r?\n");
                            if(m.Success&&m.Groups[1].Value!="not selected")game=Path.GetFileNameWithoutExtension(m.Groups[1].Value.Trim());else game="Launcher only";
                            int body=text.IndexOf("\r\n\r\n",StringComparison.Ordinal);
                            notes=body>=0?text.Substring(body+4).Trim():"";
                            if(notes=="No issue description provided.")notes="";
                        }
                    }
                } catch {}
                return new PendingReport{Zip=zip,Notes=notes,Game=game};
            }
        } catch {}
        return null;
    }
}
// Read-only window over one part of the ZIP, reporting bytes as they are sent.
sealed class PartStream : Stream {
    readonly Stream file; readonly long start, length; long position;
    readonly Action<long> sent; readonly CancellationToken token; DateTime reported;
    public PartStream(Stream file,long start,long length,Action<long> sent,CancellationToken token){this.file=file;this.start=start;this.length=length;this.sent=sent;this.token=token;file.Position=start;}
    public override int Read(byte[] buffer,int offset,int count) {
        token.ThrowIfCancellationRequested();
        int got=file.Read(buffer,offset,(int)Math.Min(count,length-position));
        position+=got;
        if(DateTime.UtcNow-reported>TimeSpan.FromMilliseconds(250)||position==length){reported=DateTime.UtcNow;sent(position);}
        return got;
    }
    public override bool CanRead{get{return true;}}
    public override bool CanSeek{get{return true;}}
    public override bool CanWrite{get{return false;}}
    public override long Length{get{return length;}}
    public override long Position{get{return position;}set{if(value<0||value>length)throw new ArgumentOutOfRangeException();position=value;file.Position=start+value;}}
    public override long Seek(long offset,SeekOrigin origin){Position=origin==SeekOrigin.Begin?offset:origin==SeekOrigin.Current?position+offset:length+offset;return position;}
    public override void Flush(){}
    public override void SetLength(long value){throw new NotSupportedException();}
    public override void Write(byte[] buffer,int offset,int count){throw new NotSupportedException();}
}
}
