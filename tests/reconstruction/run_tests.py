#!/usr/bin/env python3
"""Portable reconstruction regression runner. Never launches or installs a game."""
from pathlib import Path
import argparse
import base64
import json
import hashlib
import os
import platform
import shutil
import subprocess
import tempfile
import time
from datetime import datetime, timezone

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]

def windows_no_console_options():
 """Suppress transient console windows for captured Windows helper output."""
 if os.name=='nt':return {'creationflags':getattr(subprocess,'CREATE_NO_WINDOW',0x08000000)}
 return {}

def environment_identity(compiler):
 result={'os':platform.platform(),'python':os.sys.version,'python_executable':os.sys.executable,
         'compiler_executable':shutil.which(compiler)}
 if result['compiler_executable']:
  option='/?' if Path(result['compiler_executable']).name.lower() in ('cl','cl.exe','clang-cl','clang-cl.exe') else '--version'
  try:
   version=subprocess.run([result['compiler_executable'],option],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                          text=True,encoding='utf-8',errors='replace',timeout=10,**windows_no_console_options())
   result['compiler_version_command']=[result['compiler_executable'],option]
   result['compiler_version_exit_code']=version.returncode
   result['compiler_version_output']='\n'.join(version.stdout.splitlines()[:12])
  except (OSError,subprocess.SubprocessError) as error:result['compiler_version_error']=str(error)
 return result

def source_identity(root):
 """Record actual checkout/diff identity, including newly authored test inputs."""
 try:
  def git(*args):
   return subprocess.run(['git','-C',str(root),*args],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=20).stdout
  scopes=['Beta','Common','Stable','Research/Compositor','tests/reconstruction','.github/workflows']
  head=git('rev-parse','HEAD').decode('ascii').strip()
  difference=git('diff','--binary','HEAD','--',*scopes)
  added=[]
  for raw in git('ls-files','--others','--exclude-standard','-z','--',*scopes).split(b'\0'):
   if not raw:continue
   relative=os.fsdecode(raw)
   if '__pycache__' in Path(relative).parts or relative.endswith('.pyc'):continue
   path=root/relative
   if path.is_file():added.append({'path':relative,'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
  return {'git_head':head,'tracked_diff_sha256':hashlib.sha256(difference).hexdigest(),'untracked_inputs':added}
 except (OSError,subprocess.SubprocessError) as error:
  return {'git_identity':'unavailable','reason':str(error)}

class RegressionFailure(RuntimeError):
 """A recorded command failed; the suite must not report success."""

class RegressionRecorder:
 def __init__(self, test_directory=HERE):
  self.records=[]
  self.test_directory=Path(test_directory).resolve()

 def run(self, command, timeout=120, **kw):
  command=list(map(str,command))
  if Path(command[0]).name.lower() in ('powershell.exe','pwsh','pwsh.exe') and '-File' in command:
   index=command.index('-File')+1
   test=Path(command[index])
   if test.parent.resolve()==self.test_directory and test.name not in ('test_anti_cheat.ps1','test_anti_cheat_ui.ps1','test_anti_cheat_routes.ps1'):
    encoded=base64.b64encode(json.dumps(command[index+1:]).encode('utf-8')).decode('ascii')
    command=command[:index]+[str(self.test_directory/'run_installer_fixture.ps1'),'-TestScript',str(test),'-ArgumentsBase64',encoded]
  if os.name=='nt' and Path(command[0]).name.lower() in ('powershell.exe','pwsh','pwsh.exe') and not any(arg.lower()=='-executionpolicy' for arg in command):
   command[1:1]=['-ExecutionPolicy','Bypass']
  start=time.monotonic()
  record={'command':command,'status':'running','exit_code':None,'seconds':0,'output':''}
  self.records.append(record)
  try:
   if os.name=='nt' and 'creationflags' not in kw:kw['creationflags']=getattr(subprocess,'CREATE_NO_WINDOW',0x08000000)
   result=subprocess.run(command,text=True,encoding='utf-8',errors='replace',stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout,**kw)
   record.update(status='passed' if result.returncode==0 else 'failed',exit_code=result.returncode,output=result.stdout)
  except subprocess.TimeoutExpired as error:
   output=error.stdout or ''
   if isinstance(output,bytes):output=output.decode('utf-8',errors='replace')
   record.update(status='timed_out',output=output,error=f'Command exceeded {timeout} seconds')
  except OSError as error:
   record.update(status='could_not_start',error=str(error))
  except KeyboardInterrupt:
   record.update(status='interrupted',error='Command interrupted')
   raise
  finally:
   record['seconds']=round(time.monotonic()-start,3)
  print(record['output'],end='')
  if record['status']!='passed':
   raise RegressionFailure(f"Regression command {record['status']}: {command[0]}" + (': '+record['error'] if 'error' in record else ''))
  return record

def execute(args, recorder):
 root=args.root.resolve();channel=root/'Beta';shared=channel/'shared';project=channel/'optiscaler/OptiScaler';includes=project/'include';compiler=shutil.which(args.compiler)
 if not compiler:
  raise RegressionFailure(f'Compiler unavailable: {args.compiler}. No C++ tests were run.')
 run=recorder.run
 with tempfile.TemporaryDirectory(prefix='optishade-regressions-') as tmp:
  temp=Path(tmp);env=os.environ.copy();env['OPTISHADE_TEST_ROOT']=str(root)
  if os.name=='nt':
   # The build shell may prepend a reduced PowerShell module mirror that
   # shadows Windows PowerShell's full utility module (including Get-FileHash).
   env['PSModulePath']=os.pathsep.join(map(str,[
    Path(os.environ.get('USERPROFILE',r'C:\Users\Default'))/'Documents/WindowsPowerShell/Modules',
    Path(os.environ.get('ProgramFiles',r'C:\Program Files'))/'WindowsPowerShell/Modules',
    Path(os.environ.get('WINDIR',r'C:\Windows'))/'System32/WindowsPowerShell/v1.0/Modules']))
  powershell=args.powershell or ('powershell.exe' if os.name=='nt' else None)
  if powershell:
   if not shutil.which(powershell):raise RegressionFailure('PowerShell unavailable: '+powershell)
   # Legacy OptiShade MFG install/qualification fixtures are intentionally
   # retired. Their active replacement is the OptiMFG component and in-game
   # bridge; the production retirement regression runs immediately below.
   for fixture in ('test_build_inputs.ps1','test_build_presentation.ps1','test_powershell_module_path.ps1','test_legacy_worker_build.ps1','test_legacy_worker_channel_overlay.ps1','test_route_transaction.ps1','test_receipt_read.ps1','test_mfg_adapter_selection.ps1','test_sm86_mfg.ps1','test_whole_manager_update.ps1','test_canonical_cleanup.ps1','test_core_guide_package.ps1','test_packaged_helper_closure.ps1','test_gpu_identity.ps1','test_compatibility_hybrid_gpu.ps1','test_neural_preparation.ps1','test_neural_component_adapter_prompt.ps1','test_auto_compatibility.ps1','test_auto_component_intent.ps1','test_store_mutation.ps1','test_cross_game_diagnostics.ps1','test_library_removal.ps1','test_library_store_discovery.ps1','test_manager_status_missing_game.ps1','test_release_notes.ps1','test_play_auto_failure.ps1','test_simple_install.ps1','test_reshade_search_paths.ps1'):
    run([powershell,'-NoProfile','-ExecutionPolicy','Bypass','-File',HERE/fixture],env=env)
   run([powershell,'-NoProfile','-ExecutionPolicy','Bypass','-File',HERE.parents[1]/'Beta/installer/mfg-loader.test.ps1'],env=env)
   run([powershell,'-NoProfile','-ExecutionPolicy','Bypass','-File',HERE.parents[1]/'Beta/installer/mfg-retirement.test.ps1'],env=env)

  run([os.sys.executable,HERE/'test_runner_reporting.py'],env=env)
  run([os.sys.executable,HERE/'test_channel_version.py'],env=env)
  run([os.sys.executable,HERE/'test_sources.py'],env=env)
  run([os.sys.executable,HERE/'test_reference_record.py'],env=env)
  run([os.sys.executable,HERE/'test_symbol_identity.py'],env=env)
  run([os.sys.executable,HERE/'test_candidate_receipt.py'],env=env)
  run([os.sys.executable,HERE/'test_taa_package_contract.py'],env=env)
  guide_command=[os.sys.executable,HERE/'test_core_guides_glsl.py']
  guide_env=env.copy()
  if args.software_gl:
   guide_command.append('--software-gl')
   # Windows Mesa's portable build may otherwise select its D3D12/WDDM driver,
   # which is not the deterministic software-rendering gate requested here.
   guide_env.update(LIBGL_ALWAYS_SOFTWARE='1',MESA_SHADER_CACHE_DISABLE='true',GALLIUM_DRIVER='llvmpipe')
  run(guide_command,env=guide_env)
  transfer_command=[os.sys.executable,HERE/'test_guide_depth_transfer.py']
  if args.software_gl:transfer_command.append('--software-gl')
  run(transfer_command,env=guide_env)
  run([os.sys.executable,HERE/'test_dlss_runtime_catalogue.py'],env=env)
  run([os.sys.executable,HERE/'test_nr_runtime_selector.py'],env=env)
  run([os.sys.executable,HERE/'test_cross_runtime_ui.py'],env=env)
  run([os.sys.executable,root/'Research/Compositor/test_prototype.py'],env=env)
  msvc=Path(compiler).name.lower() in ('cl','cl.exe','clang-cl','clang-cl.exe')
  def build(name,sources,include_dirs,defines=(),standard='c++17'):
   binary=temp/(name+('.exe' if os.name=='nt' else ''))
   if msvc:
    command=[compiler,'/nologo','/std:'+standard,'/EHsc','/utf-8','/Od','/W4',
             *['/I'+str(p) for p in include_dirs],*['/D'+d for d in defines],*sources,'/Fe:'+str(binary)]
   else:
    command=[compiler,'-std='+standard,'-O0','-Wall','-Wextra','-pthread',
             *['-I'+str(p) for p in include_dirs],*['-D'+d for d in defines],*sources,'-o',binary]
   # Some Windows cleanup jobs may remove a long-lived temporary build
   # directory while nested reconstruction fixtures are running. Restore the
   # workspace before each compiler or test process instead of failing the
   # remaining suite with WinError 267.
   temp.mkdir(parents=True,exist_ok=True)
   run(command,cwd=temp)
   temp.mkdir(parents=True,exist_ok=True)
   run([binary],cwd=temp)
   return binary
  run([os.sys.executable,channel/'reconstruction/channel_version.py','--check'])
  run([os.sys.executable,channel/'reconstruction/generate_provider_policy.py','--check'])
  run([os.sys.executable,HERE/'run_native_fg_state_tests.py','--compiler',compiler,'--root',root])
  run([os.sys.executable,HERE/'run_safe_dlss_getstate_tests.py','--compiler',compiler,'--root',root])
  run([os.sys.executable,HERE/'run_native_control_authority_tests.py','--compiler',compiler,'--root',root])
  run([os.sys.executable,HERE/'run_external_init_ownership_tests.py','--compiler',compiler,'--root',root])
  run([os.sys.executable,HERE/'run_runtime_auto_tests.py','--compiler',compiler,'--root',root])
  run([os.sys.executable,HERE/'run_vulkan_fg_tests.py','--compiler',compiler,'--root',root])
  run([os.sys.executable,HERE/'run_legacy_preparation_tests.py','--compiler',compiler,'--root',root])
  run([os.sys.executable,HERE/'run_legacy_preparation_lifetime_tests.py','--compiler',compiler,'--root',root])
  run([os.sys.executable,HERE/'run_legacy_runtime_owner_tests.py','--compiler',compiler,'--root',root])
  run([os.sys.executable,HERE/'run_nr_submission_tests.py','--compiler',compiler,'--root',root])
  run([os.sys.executable,HERE/'run_nr_capture_tests.py','--compiler',compiler,'--root',root])
  if os.name=='nt':
   run([os.sys.executable,HERE/'run_temporal_interval_trace_tests.py','--compiler',compiler,'--root',root])
  control_binary=build('control',[HERE/'control_tests.cpp'],[shared,channel/'optiscaler/external/nlohmann'])
  if powershell and os.name=='nt':
   run([powershell,'-NoProfile','-File',HERE/'test_provider_policy.ps1','-ControlTests',control_binary],env=env)
   run([powershell,'-NoProfile','-File',HERE/'test_control_pipe.ps1','-ControlTests',control_binary],env=env)
  build('auto-compatibility',[HERE/'auto_compatibility_tests.cpp'],[shared,channel/'optiscaler/external/nlohmann'])
  build('neural-model-policy',[HERE/'neural_model_policy_tests.cpp'],[shared])
  build('menu-settings',[HERE/'menu_settings_tests.cpp'],[shared,channel/'optiscaler/external/simpleini'])
  build('compositor-live-timing',[HERE/'compositor_live_timing_tests.cpp'],[root/'Research/Compositor'])
  build('fg-display-extent',[HERE/'fg_display_extent_tests.cpp'],[])
  build('low-latency-input-setting',[HERE/'low_latency_input_setting_tests.cpp'],[shared])
  build('legacy-adapter',[HERE/'legacy_adapter_tests.cpp'],[channel/'legacy-nr/upstream/src'])
  build('legacy-guide',[HERE/'legacy_guide_tests.cpp'],[shared],standard='c++20')
  build('format-view',[HERE/'format_view_tests.cpp'],[shared])
  build('output-retirement',[HERE/'output_retirement_tests.cpp'],[shared])
  build('dlss-runtime-selection',[HERE/'dlss_runtime_selection_tests.cpp'],[shared])
  build('device-creation-scope',[HERE/'device_creation_scope_tests.cpp'],[shared])
  build('xplane-vulkan-target',[HERE/'xplane_vulkan_target_tests.cpp'],[shared])
  build('prepared-overlay',[HERE/'prepared_overlay_tests.cpp'],[shared])
  build('overlay-preparation',[HERE/'overlay_preparation_tests.cpp'],[shared])
  build('overlay-submission-lock',[HERE/'overlay_submission_lock_tests.cpp'],[shared])
  build('vulkan-overlay-retirement',[HERE/'vulkan_overlay_retirement_tests.cpp'],[shared])
  build('vulkan-present-batch',[HERE/'vulkan_present_batch_tests.cpp'],[shared])
  build('vulkan-acquire-dependency',[HERE/'vulkan_acquire_dependency_tests.cpp'],[shared])
  build('vulkan-acquire-api-adapter',[HERE/'vulkan_acquire_api_adapter_tests.cpp'],[shared,channel/'optiscaler/external/vulkan/include'])
  build('vulkan-present-observation',[HERE/'vulkan_present_observation_tests.cpp'],[shared,channel/'optiscaler/external/vulkan/include'])
  build('vulkan-acquire-observation',[HERE/'vulkan_acquire_observation_tests.cpp'],[shared,channel/'optiscaler/external/vulkan/include'])
  build('vulkan-submit-observation',[HERE/'vulkan_submit_observation_tests.cpp'],[shared,channel/'optiscaler/external/vulkan/include'])
  build('vulkan-sync-observation',[HERE/'vulkan_sync_observation_tests.cpp'],[shared,channel/'optiscaler/external/vulkan/include'])
  build('overlay-input-admission',[HERE/'overlay_input_admission_tests.cpp'],[shared])
  build('taa-pre-fg-observer',[HERE/'taa_pre_fg_observer_tests.cpp'],[project/'dlssnr',shared,channel/'optiscaler/external/streamline'])
  build('self-help',[HERE/'self_help_tests.cpp'],[project/'dlssnr'])
  build('xp12-camera-record',[HERE/'xp12_camera_record_tests.cpp'],[channel/'xplane-camera/include'])
  if os.name=='nt':
   run([os.sys.executable,HERE/'run_xplane_graphics_routes.py','--compiler',compiler],env=env)
   psenv=env.copy()
   run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',HERE/'test_helper_receipts.ps1'],env=psenv)
   run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',HERE/'test_manager_receipt_discovery.ps1'],env=psenv)
   run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',HERE/'test_xplane_compatibility.ps1'],env=psenv)
   run(['powershell.exe','-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',HERE/'test_manager_lifetime.ps1'],env=psenv)
   run(['powershell.exe','-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',HERE/'test_manager_responsiveness.ps1'],env=psenv)
   run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',HERE/'test_anti_cheat.ps1'],env=psenv)
   run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',HERE/'test_anti_cheat_routes.ps1'],env=psenv)
   run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',HERE/'test_portable_fsr.ps1'],env=psenv)
   run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',HERE/'test_vr_diagnostics.ps1'],env=psenv)
   run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',HERE/'test_launcher_diagnostic_export.ps1'],env=psenv)
   run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',HERE/'test_candidate_diagnostics.ps1'],env=psenv)
   build('last-session',[HERE/'last_session_tests.cpp'],[shared])
   run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',HERE/'test_generic_executable.ps1'],env=psenv)
   run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',HERE/'test_menu_settings_x86.ps1'],env=psenv)
   run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',HERE/'test_operation_progress_store.ps1'],env=psenv)
   run(['powershell.exe','-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',HERE/'test_install_progress_consent.ps1'],env=psenv)
   run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',HERE/'test_components.ps1','-Output',temp/'components'],env=psenv)
   run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',HERE/'test_storage_cleanup.ps1','-Output',temp/'storage-cleanup'],env=psenv)
   run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',HERE/'test_snapshot_library.ps1'],env=psenv)
   run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',HERE/'test_glass_cockpit_startup.ps1'],env=psenv)
   run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',HERE/'test_manager_popup_helpers.ps1'],env=psenv)
   run(['powershell.exe','-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',HERE/'test_manager_compatibility_callbacks.ps1'],env=psenv)
   run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',HERE/'test_nvidia_file_version.ps1'],env=psenv)
   build('generic-route',[HERE/'generic_route_tests.cpp',channel/'routes/generic.cpp'],[shared])
   build('boundary',[HERE/'boundary_tests.cpp'],[shared,HERE/'boundary_stubs'])
   build('boundary-native',[HERE/'boundary_native_tests.cpp',project/'library/detours/detours.lib'],[shared,includes,HERE/'boundary_stubs'])
   build('submission-gpu',[HERE/'submission_gpu_tests.cpp'],[shared],standard='c++20')
   build('nr-capture-gpu',[HERE/'nr_capture_gpu_tests.cpp'],[shared],standard='c++20')
   build('nr-foveated-shader-gpu',[HERE/'nr_foveated_shader_gpu_tests.cpp'],[project/'shaders/dlssnr'],standard='c++20')
   build('legacy-d3d10-guides-gpu',[HERE/'legacy_d3d10_guides_gpu_tests.cpp'],[shared],standard='c++20')
   build('output-owner',[HERE/'output_owner_tests.cpp'],[shared])
   build('render-window',[HERE/'render_window_tests.cpp'],[shared])
   build('nr-observation',[HERE/'nr_observation_tests.cpp'],[shared])
   build('vr-depth',[HERE/'vr_depth_tests.cpp'],[shared])
   build('compositor-gpu',[root/'Research/Compositor/gpu_tests.cpp'],[],['NOMINMAX'])
  build('input-handle-filter',[HERE/'input_handle_filter_tests.cpp'],[shared])
  build('source-policy',[HERE/'source_policy_tests.cpp'],[shared,channel/'optiscaler/external/simpleini'])
  build('effect-editor',[HERE/'effect_editor_tests.cpp'],[shared])
  build('effects-edit-ack',[HERE/'effects_edit_ack_tests.cpp'],[shared])
  build('editing',[HERE/'editing_tests.cpp'],[shared])
  build('guide-extent',[HERE/'guide_extent_tests.cpp'],[shared])
  build('taa-routing',[HERE/'taa_routing_tests.cpp'],[shared,channel/'optiscaler/external/streamline'])
  build('core',[HERE/'core_tests.cpp'],[shared,channel/'optiscaler/external/nlohmann',channel/'optiscaler/external/streamline'])
  stubs=temp/'stubs';stubs.mkdir()
  for name in ['ProducerDependencies.h','ReadinessTrace.h']:shutil.copyfile(shared/name,stubs/name)
  shutil.copyfile(HERE/'producer_stubs.h',stubs/'producer_stubs.h')
  for name in ['SimulatorRoute.h','D3D12FrameContext.h']:(stubs/name).write_text('#include "producer_stubs.h"\n')
  build('producer',[HERE/'producer_tests.cpp'],[stubs])
  imgui=includes/'imgui'
  build('panel',[HERE/'panel_tests.cpp',*[imgui/n for n in ['imgui.cpp','imgui_draw.cpp','imgui_tables.cpp','imgui_widgets.cpp']]],
        [HERE,shared,includes,imgui],['IMGUI_USER_CONFIG="test_imgui_config.h"'])

def main(argv=None):
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('--root',type=Path,default=ROOT)
 parser.add_argument('--compiler',default='g++')
 parser.add_argument('--report',type=Path)
 parser.add_argument('--powershell',help='Run portable installer fixtures with this PowerShell; Windows product gates remain separate')
 parser.add_argument('--software-gl',action='store_true',help='Also execute the original guide kernels with Mesa/EGL software OpenGL; requires libEGL and llvmpipe')
 parser.add_argument('--mesa-directory',type=Path,help='Portable x64 Mesa directory containing libEGL.dll; pairs with --software-gl and avoids manual DLL/Gallium environment setup')
 args=parser.parse_args(argv)
 if args.mesa_directory:
  if not args.software_gl:parser.error('--mesa-directory requires --software-gl')
  if os.name!='nt':parser.error('--mesa-directory is for the portable Windows Mesa DLL build')
  mesa=args.mesa_directory.resolve()
  egl=mesa/'libEGL.dll'
  if not egl.is_file():parser.error(f'--mesa-directory must contain libEGL.dll: {mesa}')
  os.environ['OPTISHADE_EGL_LIBRARY']=str(egl)
  os.environ['OPTISHADE_EGL_DLL_DIR']=str(mesa)
  os.environ['GALLIUM_DRIVER']='llvmpipe'
  os.environ['LIBGL_ALWAYS_SOFTWARE']='1'
 recorder=RegressionRecorder()
 started=datetime.now(timezone.utc).isoformat()
 source_before=source_identity(args.root.resolve())
 status='failed';error=None;exit_code=1
 try:
  execute(args,recorder)
  status='passed';exit_code=0
  if source_identity(args.root.resolve())!=source_before:
   status='source_changed';error='Source inputs changed during the run; rerun the affected suite against a stable checkout';exit_code=2
 except KeyboardInterrupt:
  status='interrupted';error='Regression run interrupted';exit_code=130
 except Exception as failure:
  error=f'{type(failure).__name__}: {failure}'
 finally:
  if args.report:
   report={'status':status,'error':error,'started_utc':started,'finished_utc':datetime.now(timezone.utc).isoformat(),
    'root':str(args.root.resolve()),'compiler':args.compiler,'platform':os.name,'powershell':args.powershell,'software_gl_requested':args.software_gl,
    'environment':environment_identity(args.compiler),
    'source_start':source_before,'source_end':source_identity(args.root.resolve()),
    'scope':'CPU policy, native Auto callback/owner seams, interposer installation/cleanup and accepted-input lifecycle, worker, source/build-contract, headless native ImGui and offline compositor; Windows also attempts D3D12 capture/submission and D3D10 guide-relay WARP fixtures',
    'full_native_build':'not run by this runner',
    'gpu_harness':'WARP submission command passed' if any(r['status']=='passed' and Path(r['command'][0]).name.lower()=='submission-gpu.exe' for r in recorder.records) else 'not completed',
    'software_gl':'Mesa/EGL original-guide kernel execution passed' if any(r['status']=='passed' and '--software-gl' in r['command'] and any(Path(value).name=='test_core_guides_glsl.py' for value in r['command']) for r in recorder.records) else 'not completed',
    'simulator_or_physical_gpu':'not run','records':recorder.records}
   args.report.parent.mkdir(parents=True,exist_ok=True)
   temporary=args.report.with_name(args.report.name+'.tmp')
   temporary.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
   temporary.replace(args.report)
 if status=='passed':
  print('Reconstruction regressions passed. Full product build and simulator/physical-hardware gates remain separate.')
 else:
  print(error or 'Reconstruction regressions failed.',file=os.sys.stderr)
 return exit_code

if __name__=='__main__':raise SystemExit(main())
