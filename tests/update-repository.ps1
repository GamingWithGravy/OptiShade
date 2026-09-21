$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/updates.ps1"
function Invoke-RestMethod { param($Uri,$Headers,$TimeoutSec)
 @{draft=$false;prerelease=$false;tag_name='v0.19.20';assets=@(@{name='OptiShade_Version_0.19.20.exe';digest=('sha256:'+('a'*64));browser_download_url=$script:testUrl});body='test'}
}
foreach($repo in @('OptiShade','OptiShade_V0.19.17')) {
 $script:testUrl="https://github.com/GamingWithGravy/$repo/releases/download/v0.19.20/test.exe"
 if(-not (GetOptiShadeUpdate)){throw "Rejected trusted repository $repo"}
 "PASS: $repo update accepted"
}
foreach($url in @('https://github.com/AnotherOwner/OptiShade/releases/download/v0.19.20/test.exe','https://github.com/GamingWithGravy/OptiShadeFake/releases/download/v0.19.20/test.exe','https://evil.example/GamingWithGravy/OptiShade/releases/download/v0.19.20/test.exe')) {
 $script:testUrl=$url
 if(GetOptiShadeUpdate){throw "Accepted untrusted URL $url"}
}
'PASS: unrelated repositories and hosts rejected'
