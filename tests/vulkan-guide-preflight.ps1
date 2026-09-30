$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$source=[IO.File]::ReadAllText((Join-Path $root 'reshade/source/runtime.cpp'))
$start=$source.IndexOf('void reshade::runtime::render_effects(')
$end=$source.IndexOf('// Lock input so it cannot be modified',$start)
if($start -lt 0 -or $end -le $start){throw 'Could not locate the real render-effects preflight'}
# Execute the actual production preflight in a strict mock. RequiresGuides throws
# if it observes loading metadata, rather than checking for a source string.
$prefix=$source.Substring($start,$end-$start)
$fixture=Join-Path $env:TEMP ('OptiShade-guide-preflight-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture|Out-Null
$harness=@'
#include <algorithm>
#include <cassert>
#include <iostream>
#include <stdexcept>
#include <vector>
namespace reshade {
namespace api { struct command_list {}; using resource_view=int; }
struct effect { bool addon=false; };
struct runtime {
 bool _effects_rendered_this_frame=false,loading=false,_effects_enabled=true,required=false,reachedRender=false;
 unsigned queries=0,loadingNotes=0;
 std::vector<int> _techniques{1};std::vector<effect> _effects{{false}};
 bool is_loading()const{return loading;}
 void render_effects(api::command_list*,api::resource_view,api::resource_view);
};
}
namespace osvnr_impl {
bool RequiresGuides(reshade::runtime* r){if(r->loading)throw std::runtime_error("Metadata queried while compilation is running");++r->queries;return r->required;}
void Loading(reshade::runtime* r){++r->loadingNotes;}
}
'@
$harness+="`n"+$prefix+"reachedRender=true; }`n"
$harness+=@'
int main(){
 reshade::runtime compiling;compiling.loading=true;
 compiling.render_effects(nullptr,0,0);
 assert(compiling.queries==0&&compiling.loadingNotes==1&&!compiling.reachedRender);
 reshade::runtime empty;empty._techniques.clear();
 empty.render_effects(nullptr,0,0);
 assert(empty.queries==1&&empty.loadingNotes==0&&!empty.reachedRender);
 reshade::runtime ordinary;ordinary.render_effects(nullptr,0,0);
 assert(ordinary.queries==1&&ordinary.reachedRender);
 reshade::runtime disabled;disabled._effects_enabled=false;
 disabled.render_effects(nullptr,0,0);assert(disabled.queries==1&&!disabled.reachedRender);
 reshade::runtime required;required._effects_enabled=false;required.required=true;
 required.render_effects(nullptr,0,0);assert(required.queries==1&&required.reachedRender);
 required.render_effects(nullptr,0,0);assert(required.queries==1); // No double render/query.
 std::cout<<"PASS: production preflight defers guide lookup until compilation completes, keeps empty-technique recovery reachable, preserves FX-off and required-guide semantics\n";
}
'@
[IO.File]::WriteAllText((Join-Path $fixture 'preflight.cpp'),$harness,[Text.UTF8Encoding]::new($false))
$build="@echo off`r`ncall `"$root\build-env.cmd`" >nul`r`nif errorlevel 1 exit /b 1`r`ncl /nologo /utf-8 /std:c++17 /EHsc `"$fixture\preflight.cpp`" /Fo:`"$fixture\preflight.obj`" /Fe:`"$fixture\preflight.exe`"`r`nif errorlevel 1 exit /b 1`r`n`"$fixture\preflight.exe`"`r`n"
[IO.File]::WriteAllText((Join-Path $fixture 'build.cmd'),$build,[Text.Encoding]::ASCII)
& (Join-Path $fixture 'build.cmd')
if($LASTEXITCODE){throw 'Vulkan guide preflight regression failed'}
