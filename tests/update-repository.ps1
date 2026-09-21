$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/updates.ps1"
function Invoke-RestMethod { param($Uri,$Headers,$TimeoutSec)
 @{draft=$false;prerelease=$false;tag_name=('v'+$script:testVersion);assets=@(@{name=("OptiShade_Version_"+$script:testVersion+".exe");digest=('sha256:'+('a'*64));browser_download_url=$script:testUrl});body='test'}
}
$script:testVersion='0.20'
foreach($repo in @('OptiShade','OptiShade_V0.19.17')) {
 $script:testUrl="https://github.com/GamingWithGravy/$repo/releases/download/v0.19.20/test.exe"
 if(-not (GetOptiShadeUpdate -Current '0.19.19')){throw "Rejected trusted repository $repo"}
 "PASS: $repo update accepted"
}
foreach($url in @('https://github.com/AnotherOwner/OptiShade/releases/download/v0.19.20/test.exe','https://github.com/GamingWithGravy/OptiShadeFake/releases/download/v0.19.20/test.exe','https://evil.example/GamingWithGravy/OptiShade/releases/download/v0.19.20/test.exe')) {
 $script:testUrl=$url
 if(GetOptiShadeUpdate -Current '0.19.19'){throw "Accepted untrusted URL $url"}
}
'PASS: unrelated repositories and hosts rejected'

foreach($version in @('0.20','0.20.1','0.21','1.0.0')){
 $script:testVersion=$version
 $script:testUrl="https://github.com/GamingWithGravy/OptiShade/releases/download/v$version/OptiShade_Version_$version.exe"
 if(-not(GetOptiShadeUpdate -Current '0.19.19')){throw "Failed version $version"}
}
$script:testVersion='0.20'
if(GetOptiShadeUpdate -Current '0.20'){throw 'Current version falsely offers an update'}
'PASS: two- and three-part versions and current-version suppression'