$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('optishade-control-fixture-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$binary=Join-Path $fixture 'ForzaHorizon4.exe'
$helperBinary=Join-Path $fixture 'ForzaWebHelper.exe'
$otherFolder=$fixture+'-other';[void][IO.Directory]::CreateDirectory($otherFolder)
$otherBinary=Join-Path $otherFolder 'ForzaHorizon4.exe'
$secondBinary=Join-Path $fixture 'OtherRenderer.exe'
Copy-Item -LiteralPath (Join-Path $root 'test-results/control-tests.exe') -Destination $binary
$process=$null;$helper=$null;$other=$null;$second=$null
try{
 # These are isolated CPU/pipe fixtures, never actual games or game helpers.
 Copy-Item -LiteralPath $binary -Destination $helperBinary
 Copy-Item -LiteralPath $binary -Destination $otherBinary
 Copy-Item -LiteralPath $binary -Destination $secondBinary
 $helper=Start-Process -FilePath $helperBinary -ArgumentList 'idle-fixture' -WindowStyle Hidden -PassThru
 $other=Start-Process -FilePath $otherBinary -ArgumentList 'pipe-fixture' -WindowStyle Hidden -PassThru
 $process=Start-Process -FilePath $binary -ArgumentList 'pipe-fixture' -WindowStyle Hidden -PassThru
 $assembly=[Reflection.Assembly]::LoadFrom((Join-Path $root 'Beta/installer/OptiShade-Troubleshooter.exe'))
 $task=[OptiShadeControlClient]::BeginSnapshot($fixture)
 if(-not $task.Wait(4000)){throw 'Installation-bound discovery exceeded deadline'}
 $snapshot=$task.Result|ConvertFrom-Json
 if($snapshot.pid -ne $process.Id -or $snapshot.code -ne 'ok'){throw 'Selected installation resolved to wrong session'}
 $request=New-Object OptiShade.TesterKit.Request;$request.Game=$fixture
 $collector=New-Object OptiShade.TesterKit.Collector($request,[Action[string]]{param($message)},[Threading.CancellationToken]::None)
 $flags=[Reflection.BindingFlags]'NonPublic,Instance'
 $collector.GetType().GetField('exe',$flags).SetValue($collector,'ForzaHorizon4.exe')
 # Processes compares the running module against the executable path resolved
 # by Collector.Run. Seed the same production state in this direct method test.
 $collector.GetType().GetField('exePath',$flags).SetValue($collector,$binary)
 [void]$collector.GetType().GetMethod('Processes',$flags).Invoke($collector,@())
 $items=$collector.GetType().GetField('items',$flags).GetValue($collector)
 $entry=@($items|Where-Object {$_.Name -eq ('runtime/control-'+$process.Id+'.json')})
 if($entry.Count -ne 1 -or ($entry[0].Text|ConvertFrom-Json).pid -ne $process.Id){throw 'Bundled collector omitted the live runtime snapshot'}
 $second=Start-Process -FilePath $secondBinary -ArgumentList 'pipe-fixture' -WindowStyle Hidden -PassThru
 $ambiguous=$false;try{$task=[OptiShadeControlClient]::BeginSnapshot($fixture);[void]$task.GetAwaiter().GetResult()}catch{$ambiguous=$_.Exception.GetBaseException().Message -like 'Multiple live OptiShade game sessions*'}
 if(-not $ambiguous){throw 'Multiple live endpoints were not rejected.'}
 'Generic renderer discovered by actual path, pipe PID and OS birth; same-folder helper and sibling installation excluded; multiple live sessions rejected. Packaged collector captured the bound runtime. No game/GPU test.'
}finally{
 foreach($item in @($process,$helper,$other,$second)){if($item){if(-not $item.HasExited){Stop-Process -Id $item.Id -Force};$item.Dispose()}}
 foreach($file in @($binary,$helperBinary,$otherBinary,$secondBinary)){if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file -Force}}
 [IO.Directory]::Delete($fixture);[IO.Directory]::Delete($otherFolder)
}
