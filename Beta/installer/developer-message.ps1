# Live developer message for the Home page. The owner edits developer-message.json
# on the public repository's main branch; the launcher shows the newest copy and
# keeps the last good one for offline use. Plain text only: no markup, no links
# that open anything, bounded size, HTTPS from GitHub's raw host only.
$script:OptiShadeDeveloperMessageUrl='https://raw.githubusercontent.com/GamingWithGravy/OptiShade/main/developer-message.json'
$script:OptiShadeDeveloperMessageMaxBytes=32KB

function ConvertToOptiShadeDeveloperMessageText([string]$Text,[int]$Maximum){
 # Keep line breaks and tabs; drop every other control character.
 $unified=([string]$Text).Replace("`r`n","`n")
 $clean=[regex]::Replace($unified,'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]','').Trim()
 if($clean.Length -gt $Maximum){throw "The developer message is longer than $Maximum characters."}
 return $clean
}
function ConvertFromOptiShadeDeveloperMessage([string]$Json){
 if([string]::IsNullOrWhiteSpace($Json)){throw 'The developer message is empty.'}
 if([Text.Encoding]::UTF8.GetByteCount($Json) -gt $script:OptiShadeDeveloperMessageMaxBytes){throw 'The developer message file is too large.'}
 $data=$Json|ConvertFrom-Json -ErrorAction Stop
 if($data.schema -ne 1){throw 'The developer message uses an unknown schema.'}
 $title=ConvertToOptiShadeDeveloperMessageText ([string]$data.title) 160
 $body=ConvertToOptiShadeDeveloperMessageText ([string]$data.body) 6000
 if(-not $title -and -not $body){throw 'The developer message has no text.'}
 $updated=''
 if($data.PSObject.Properties['updated'] -and $data.updated){try{$updated=([DateTime]::Parse([string]$data.updated,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)).ToString('d MMMM yyyy',[Globalization.CultureInfo]::InvariantCulture)}catch{}}
 return [pscustomobject]@{Title=$title;Body=$body;Updated=$updated}
}
function GetOptiShadeDeveloperMessageCachePath([string]$Store){Join-Path $Store 'developer-message.json'}
function ReadOptiShadeCachedDeveloperMessage([string]$Store){
 $path=GetOptiShadeDeveloperMessageCachePath $Store
 try{if(Test-Path -LiteralPath $path -PathType Leaf){return ConvertFromOptiShadeDeveloperMessage ([IO.File]::ReadAllText($path,[Text.Encoding]::UTF8))}}catch{}
 return $null
}
function SaveOptiShadeDeveloperMessage([string]$Store,[string]$Json){
 [void](ConvertFromOptiShadeDeveloperMessage $Json)
 [void][IO.Directory]::CreateDirectory($Store)
 $path=GetOptiShadeDeveloperMessageCachePath $Store;$temp=$path+'.partial'
 [IO.File]::WriteAllText($temp,$Json,[Text.UTF8Encoding]::new($false))
 if([IO.File]::Exists($path)){[IO.File]::Delete($path)};[IO.File]::Move($temp,$path)
}
# Starts a bounded download and returns its task; the caller polls it on the UI
# thread so the window never waits on the network.
function StartOptiShadeDeveloperMessageDownload([string]$Url=$script:OptiShadeDeveloperMessageUrl){
 $uri=[Uri]$Url
 if($uri.Scheme -ne 'https' -or $uri.Host -ne 'raw.githubusercontent.com'){throw 'The developer message must come from GitHub over HTTPS.'}
 Add-Type -AssemblyName System.Net.Http
 [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
 $handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false
 $client=[Net.Http.HttpClient]::new($handler);$client.Timeout=[TimeSpan]::FromSeconds(15);$client.MaxResponseContentBufferSize=$script:OptiShadeDeveloperMessageMaxBytes
 $client.DefaultRequestHeaders.UserAgent.ParseAdd('OptiShade-launcher')
 # A cache-busting query keeps an edit from waiting on an intermediate cache.
 $request=$Url+'?t='+[DateTime]::UtcNow.ToString('yyyyMMddHHmm')
 return [pscustomobject]@{Client=$client;Task=$client.GetStringAsync($request)}
}
function CompleteOptiShadeDeveloperMessageDownload($Download){
 try{
  if($Download.Task.IsFaulted -or $Download.Task.IsCanceled){throw ($(if($Download.Task.Exception){$Download.Task.Exception.GetBaseException().Message}else{'The download was cancelled.'}))}
  return [string]$Download.Task.Result
 }finally{$Download.Client.Dispose()}
}
