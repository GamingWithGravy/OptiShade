"""Source extraction and build-identity regressions; not Windows/simulator tests."""
from pathlib import Path
import hashlib
import importlib.util
import json
import os
import re
import shutil
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT=Path(os.environ.get('OPTISHADE_TEST_ROOT',Path(__file__).resolve().parents[2]))
CHANNEL=ROOT/'Beta'
PROJECT=CHANNEL/'optiscaler/OptiScaler'
def load(name,path):
 spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
views=load('views',CHANNEL/'reconstruction/check_native_views.py')
guard=load('guard',CHANNEL/'reconstruction/check_source_provider.py')

def sha(data):return hashlib.sha256(data).hexdigest()
class R295Regression(unittest.TestCase):
 def test_dx12_cleanup_precedes_context_shutdown_and_does_not_depend_on_initialized_flag(self):
  source=(PROJECT/'menu/menu_overlay_dx.cpp').read_text(encoding='utf-8-sig')
  cleanup=source[source.index('static bool CleanupRenderTargetDx12'):source.index('static void CreateRenderTargetDx11')]
  self.assertNotIn('if (!_isInited',cleanup)
  self.assertLess(cleanup.index('overlayCompletion.Drain()'),cleanup.index('SAFE_RELEASE(g_pd3dRtvDescHeap)'))
  switch=source[source.index('// Process window handle changed'):source.index('// Init\n',source.index('// Process window handle changed'))]
  self.assertLess(switch.index('!CleanupRenderTargetDx12(true)'),switch.index('MenuOverlayBase::Shutdown()'))
  self.assertIn('if (!overlayRetry.Ready(GetTickCount64())) return;',source)
 def test_nr_uses_model_creation_tuning_during_pending_edit(self):
  source=(PROJECT/'shaders/dlssnr/DlssNr_Dx12.cpp').read_text(encoding='utf-8-sig')
  loop=source[source.index('for (unsigned int pass = 0; pass < effectivePasses'):source.index('// Supersampling probe:')]
  self.assertIn('const auto tuning = g_nr.builtPassTuning[pass];',loop)
  self.assertIn('(int) g_nr.builtStyle[pass]',loop)
  self.assertNotIn('PassTuning(cfg, pass)',loop)
 def test_browsing_effects_does_not_implicitly_compile_and_tabs_balance(self):
  source=(PROJECT/'menu/optishade_effects_ui.inl').read_text(encoding='utf-8-sig')
  self.assertIn('!selectedMissing&&ImGui::Button("Load shader settings")',source)
  self.assertIn('BeginTabBar("FX views"',source)
  self.assertIn('ImGui::EndTabItem()',source)
  self.assertIn('ImGuiListClipper clipper',source)
  self.assertIn('std::to_string(lookNames.size())',source)
  self.assertIn('std::to_string(favourites.size())',source)
  self.assertIn('MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH',source)
 def test_absent_component_is_not_waiting(self):
  source=(PROJECT/'menu/optishade_mfg_ui.inl').read_text(encoding='utf-8-sig')
  self.assertIn('installed?"Waiting for game connection":"OptiMFG not installed"',source)
  self.assertIn('if(!installed&&!connected)',source)

class StreamlineRegistrationRegression(unittest.TestCase):
 def test_registration_gate_precedes_all_shared_pointer_access(self):
  source=(PROJECT/'hooks/Streamline_Hooks.cpp').read_text(encoding='utf-8-sig')
  body=source[source.index('void StreamlineHooks::hookInterposer('):source.index('// SL PLUGINS')]
  self.assertLess(body.index('registrationInProgress.test_and_set'),body.index('hookedInterposerModule'))
  self.assertLess(body.index('registrationReset{registrationInProgress}'),body.index('KernelBaseProxy::GetProcAddress_()'))
  self.assertIn('flag.clear(std::memory_order_release)',body)
  self.assertNotIn('while (registrationInProgress',body)

class LoggerExitRegression(unittest.TestCase):
 def test_only_os_termination_skips_registry_destruction(self):
  source=(CHANNEL/'optiscaler/external/spdlog/include/spdlog/details/registry-inl.h').read_text(encoding='utf-8-sig')
  self.assertIn('if (!RtlDllShutdownInProgress()) delete value;',source)
  self.assertIn('defined(OPTISHADE_SAFE_PROCESS_EXIT) && defined(_WIN32)',source)
  project=ET.parse(PROJECT/'OptiScaler.vcxproj')
  definitions=project.findall('.//{http://schemas.microsoft.com/developer/msbuild/2003}PreprocessorDefinitions')
  self.assertTrue(definitions)
  self.assertTrue(all('OPTISHADE_SAFE_PROCESS_EXIT' in (node.text or '') for node in definitions))
 def test_notification_does_not_own_watcher_lifetime(self):
  source=(CHANNEL/'installer/Troubleshooter/src/CaptureNotice.cs').read_text(encoding='utf-8-sig')
  self.assertIn('thread.IsBackground=true;',source)
  self.assertNotIn('thread.IsBackground=false;',source)

class SharedLowLatencyStateRegression(unittest.TestCase):
 def test_inline_atomic_shared_ptr_has_explicit_cross_tu_alignment(self):
  header=(PROJECT/'low_latency/input/input_common.h').read_text(encoding='utf-8-sig')
  self.assertRegex(header,r'alignas\(16\)\s+inline static std::atomic<std::shared_ptr<LowLatencyTech>> currently_active_tech;')

class Fsr4PresetPolicyRegression(unittest.TestCase):
 def test_production_fsr4_hooks_use_the_current_upstream_scale_policy(self):
  source=(PROJECT/'fsr4/FSR4ModelSelection.cpp').read_text(encoding='utf-8-sig')
  policy=(PROJECT/'fsr4/FSR4PresetPolicy.h').read_text(encoding='utf-8-sig')
  self.assertIn('#include "FSR4PresetPolicy.h"',source)
  self.assertIn('optishade::fsr4::CorrectPreset(',source)
  self.assertIn('QualityModel1ScaleThreshold = 1.29f',policy)
  self.assertNotIn('ratio >= 1.49f',source)

 def test_model_selection_hooks_use_serialized_process_wide_detours(self):
  source=(PROJECT/'fsr4/FSR4ModelSelection.cpp').read_text(encoding='utf-8-sig')
  self.assertIn('#include <hooks/ProcessDetourTransaction.h>',source)
  self.assertEqual(source.count('AttachProcessDetour('),6)
  self.assertNotIn('DetourTransactionBegin()',source)
  self.assertNotIn('DetourTransactionCommit()',source)
  self.assertIn('g_modelSelectionHookMutex',source)

class Fsr31DefaultTuningRegression(unittest.TestCase):
 def test_upstream_dynamic_defaults_are_used_only_when_extents_are_valid_and_user_values_unset(self):
  source=(PROJECT/'upscalers/fsr31/FSR31Feature_Dx11.cpp').read_text(encoding='utf-8-sig')
  policy=(PROJECT/'upscalers/fsr31/FSR31DefaultTuning.h').read_text(encoding='utf-8-sig')
  self.assertIn('#include "FSR31DefaultTuning.h"',source)
  self.assertIn('TryCalculateDefaultTuning(',source)
  self.assertIn('value_for_config() == std::nullopt',source)
  self.assertIn('std::max(ratioX, ratioY)',policy)
  self.assertIn('scaleRatio / 10.0f',policy)
  self.assertIn('scaleRatio / 20.0f',policy)
  self.assertIn('!std::isfinite(scaleRatio)',policy)

class UpstreamOptiScalerQuirkRegression(unittest.TestCase):
 def test_missing_v094_game_profiles_are_carried_into_the_fork(self):
  source=(PROJECT/'misc/Quirks.h').read_text(encoding='utf-8-sig')
  self.assertIn('QUIRK_ENTRY("afop_plus.exe", GameQuirk::DisableFSR2Inputs, GameQuirk::DisableFSR3Inputs,',source)
  self.assertIn('QUIRK_ENTRY("splitfiction.exe", GameQuirk::FastFeatureReset)',source)
  self.assertIn('QUIRK_ENTRY("wwzretailegs.exe", GameQuirk::UseFsr2VulkanInputs, GameQuirk::EnableVulkanExtensionSpoofing,',source)
  for quirk in ('DisableFSR2Inputs','DisableFSR3Inputs','DisableDxgiSpoofing','FastFeatureReset',
                'UseFsr2VulkanInputs','EnableVulkanExtensionSpoofing','ForceDepthD32S8'):
   self.assertRegex(source,rf'\b{quirk}\b')

class LoaderLockDetachRegression(unittest.TestCase):
 def test_process_detach_does_not_unload_modules_or_stop_runtime_services(self):
  detach=(PROJECT/'dllmain.cpp').read_text(encoding='utf-8-sig').split('case DLL_PROCESS_DETACH:',1)[1].split('case DLL_THREAD_ATTACH:',1)[0]
  self.assertNotIn('FreeLibrary',detach)
  self.assertNotIn('CloseLogger',detach)
  self.assertNotIn('ForEach',detach)
  self.assertIn('loader lock',detach)
  state=(CHANNEL/'optiscaler/OptiScaler/State.h').read_text(encoding='utf-8-sig')
  loader=(PROJECT/'hooks/LibraryLoad_Hooks.cpp').read_text(encoding='utf-8-sig')
  self.assertNotIn('modulesToFree',state)
  self.assertNotIn('modulesToFree',loader)
  self.assertNotIn('DeferredModuleUnloads.h',state)

class MenuShutdownLifecycleRegression(unittest.TestCase):
 def test_shutdown_signal_is_atomic_and_published_before_backend_teardown(self):
  state=(PROJECT/'State.h').read_text(encoding='utf-8-sig')
  common=(PROJECT/'menu/menu_common.cpp').read_text(encoding='utf-8-sig')
  dx11=(PROJECT/'menu/menu_dx11.cpp').read_text(encoding='utf-8-sig')
  dx12=(PROJECT/'menu/menu_dx12.cpp').read_text(encoding='utf-8-sig')
  self.assertRegex(state,r'std::atomic<bool>\s+isShuttingDown\{false\}')
  common_init=common[common.index('void MenuCommon::Init('):common.index('void MenuCommon::Shutdown(')]
  common_shutdown=common[common.index('void MenuCommon::Shutdown('):common.index('void MenuCommon::HideMenu(')]
  dx11_start=dx11.index('Menu_Dx11::~Menu_Dx11()')
  dx11_shutdown=dx11[dx11_start:dx11.index('// hackzor',dx11_start)]
  dx12_shutdown=dx12[dx12.index('Menu_Dx12::~Menu_Dx12()'):dx12.index('void Menu_Dx12::CreateRenderTarget(')]
  self.assertIn('State::Instance().isShuttingDown = false;',common_init)
  self.assertLess(common_shutdown.index('State::Instance().isShuttingDown = true;'),common_shutdown.index('SaveMenuGeometryBoundary(true);'))
  self.assertLess(dx11_shutdown.index('State::Instance().isShuttingDown = true;'),dx11_shutdown.index('ImGui_ImplDX11_Shutdown(false);'))
  self.assertLess(dx12_shutdown.index('State::Instance().isShuttingDown = true;'),dx12_shutdown.index('ImGui_ImplDX12_Shutdown(true, !State::Instance().isShuttingDown);'))

class VulkanHookLifetimeRegression(unittest.TestCase):
 def test_pinned_loader_hooks_have_no_unsafe_one_thread_detach_path(self):
  header=(PROJECT/'hooks/Vulkan_Hooks.h').read_text(encoding='utf-8-sig')
  source=(PROJECT/'hooks/Vulkan_Hooks.cpp').read_text(encoding='utf-8-sig')
  loader=(PROJECT/'hooks/LibraryLoad_Hooks.cpp').read_text(encoding='utf-8-sig')
  self.assertIn('static void Hook(HMODULE vulkan1);',header)
  self.assertNotIn('static void Unhook();',header)
  self.assertNotIn('void VulkanHooks::Unhook()',source)
  self.assertNotIn('DetourDetach',source)
  self.assertIn('GET_MODULE_HANDLE_EX_FLAG_PIN, L"vulkan-1"',loader)

class VulkanFfxApiHookLifetimeRegression(unittest.TestCase):
 def test_vulkan_ffx_hooks_target_and_pin_the_game_loaded_module(self):
  source=(PROJECT/'proxies/FfxApi_Proxy.h').read_text(encoding='utf-8-sig')
  init=source[source.index('static bool InitFfxVk('):source.index('static feature_version VersionVk(')]
  self.assertIn('if (module != nullptr && main_vk_hooked.dll == nullptr)',init)
  self.assertIn('if (main_vk.dll == nullptr && main_vk_hooked.dll != nullptr)',init)
  self.assertIn('if (main_vk_hooked.dll != nullptr && main_vk_hooked.Configure == nullptr)',init)
  for member,hook in (
   ('Configure','ffxConfigure_Vk'),('CreateContext','ffxCreateContext_Vk'),
   ('DestroyContext','ffxDestroyContext_Vk'),('Dispatch','ffxDispatch_Vk'),('Query','ffxQuery_Vk')):
   self.assertIn(f'QueueProcessDetour(attachResult, &(PVOID&) main_vk_hooked.{member}, {hook})',init)
   self.assertNotIn(f'QueueProcessDetour(attachResult, &(PVOID&) main_vk.{member}, {hook})',init)
  self.assertIn('if (main_vk_hooked.dll == main_vk.dll)',init)
  self.assertIn('main_vk_hooked.hooked = true;',init)
  self.assertIn('GET_MODULE_HANDLE_EX_FLAG_PIN | GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS',init)
  self.assertIn('(LPCWSTR) main_vk_hooked.dll',init)

class D3DHookLifetimeRegression(unittest.TestCase):
 def test_d3d_device_hooks_do_not_expose_partial_one_thread_detach_paths(self):
  d3d11_header=(PROJECT/'hooks/D3D11_Hooks.h').read_text(encoding='utf-8-sig')
  d3d11=(PROJECT/'hooks/D3D11_Hooks.cpp').read_text(encoding='utf-8-sig')
  d3d12_header=(PROJECT/'hooks/D3D12_Hooks.h').read_text(encoding='utf-8-sig')
  d3d12=(PROJECT/'hooks/D3D12_Hooks.cpp').read_text(encoding='utf-8-sig')
  self.assertIn('static void HookToDevice(ID3D11Device* InDevice);',d3d11_header)
  self.assertNotIn('Unhook',d3d11_header+d3d11)
  self.assertNotIn('DetourDetach',d3d11)
  self.assertIn('static void HookDevice(ID3D12Device* device);',d3d12_header)
  self.assertNotIn('Unhook',d3d12_header+d3d12)
  self.assertNotIn('DetourDetach',d3d12)
  self.assertIn('if (o_CreateSampler != nullptr || InDevice == nullptr)',d3d12)
  self.assertIn('QueueProcessDetour',d3d12)
  self.assertNotIn('DetourAttach(',d3d12)
  tracker=(PROJECT/'resource_tracking/ResTrack_dx12.cpp').read_text(encoding='utf-8-sig')
  tracker_header=(PROJECT/'resource_tracking/ResTrack_dx12.h').read_text(encoding='utf-8-sig')
  self.assertNotIn('ReleaseDeviceHooks',tracker+tracker_header)
  self.assertNotIn('ReleaseHooks',tracker+tracker_header)
  self.assertNotIn('DetourDetach',tracker)
  self.assertIn('void ResTrack_Dx12::HookDevice(ID3D12Device* device)',tracker)
  interop=(PROJECT/'hooks/VulkanwDx12_Hooks.cpp').read_text(encoding='utf-8-sig')
  interop_header=(PROJECT/'hooks/VulkanwDx12_Hooks.h').read_text(encoding='utf-8-sig')
  spoof=(PROJECT/'spoofing/User32_Spoofing.cpp').read_text(encoding='utf-8-sig')
  spoof_header=(PROJECT/'spoofing/User32_Spoofing.h').read_text(encoding='utf-8-sig')
  self.assertNotIn('Vulkan_wDx12::Unhook',interop)
  self.assertNotIn('Unhook',interop_header)
  self.assertNotIn('DetourDetach',interop)
  self.assertNotIn('User32Spoofing::Unhook',spoof)
  self.assertNotIn('Unhook',spoof_header)
  self.assertNotIn('DetourDetach',spoof)
  for name in ('Advapi32_Hooks.h','Crypt32_Hooks.h','Gdi32_Hooks.h','Wintrust_Hooks.h'):
   api_hooks=(PROJECT/'hooks'/name).read_bytes().decode('latin-1')
   self.assertNotIn('unhook',api_hooks.lower())
   self.assertNotIn('DetourDetach',api_hooks)
  dxgi_proxy=(PROJECT/'proxies/Dxgi_Proxy.h').read_text(encoding='utf-8-sig')
  self.assertNotIn('static void Unhook(',dxgi_proxy)
  self.assertNotIn('DetourDetach',dxgi_proxy)

class InputHookLifetimeRegression(unittest.TestCase):
 def test_input_detours_have_process_lifetime_targets_and_enlist_process_threads(self):
  sources={name:(PROJECT/'menu/input'/name).read_text(encoding='utf-8-sig') for name in (
   'input_system.cpp','input_system_detours.cpp','input_system_directinput.cpp',
   'input_system_gameinput.cpp','input_system_xinput.cpp')}
  for name,source in sources.items():
   self.assertNotIn('DetourDetach',source,f'{name} must not detach active input callbacks during a live game')
   self.assertNotIn('DetourTransactionBegin()',source,f'{name} must use the all-thread transaction helper')
   self.assertNotIn('DetourAttach(',source,f'{name} must propagate each attach result through the transaction helper')
   self.assertNotIn('DetourUpdateThread(GetCurrentThread())',source)
  helper=(PROJECT/'menu/input/InputDetourTransaction.h').read_text(encoding='utf-8-sig')
  process_helper=(PROJECT/'hooks/ProcessDetourTransaction.h').read_text(encoding='utf-8-sig')
  self.assertIn('WithProcessDetourTransaction(std::forward<Action>(action))',helper)
  self.assertIn('QueueProcessDetour(previousResult, original, detour)',helper)
  self.assertIn('DetourTransactionBegin()',process_helper)
  self.assertIn('inline std::mutex& ProcessDetourTransactionMutex()',process_helper)
  self.assertIn('std::lock_guard<std::mutex> transactionLock(ProcessDetourTransactionMutex());',process_helper)
  self.assertLess(process_helper.index('transactionLock(ProcessDetourTransactionMutex())'),process_helper.index('DetourTransactionBegin();'))
  self.assertIn('return DetourAttach(original, detour);',process_helper)
  self.assertIn('result = action();',process_helper)
  self.assertIn('DetourUpdateThread(',process_helper)
  self.assertIn('CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD',process_helper)
  self.assertIn('OpenThread(',process_helper)
  self.assertIn('GET_MODULE_HANDLE_EX_FLAG_PIN',helper)
  state=sources['input_system.cpp']
  gameinput=sources['input_system_gameinput.cpp']
  self.assertIn('_state.GameInputCreateHookAttempted = true;',gameinput)
  self.assertIn('_state.GameInputCreateHookAttempted = false;',gameinput)
  self.assertIn('gameInputModule != _state.GameInputModule',gameinput)
  xinput=sources['input_system_xinput.cpp']
  self.assertIn('module == nullptr || _state.XInputHookAttempted',xinput)
  self.assertIn('_state.XInputHookAttempted = true;',xinput)
  reserved=state[state.index('bool IsReservedMenuKeyLocked(int vk)'):state.index('\nbool IsPhysicalMenuBindingLocked()')]
  self.assertIn('_state.Initialized',reserved,
                'retained callbacks must stop filtering reserved keys after input shutdown')
  self.assertIn('blocking decisions are inactive once _state.Initialized becomes false',
                sources['input_system_directinput.cpp'])
  reset=state[state.index('void ResetStateAfterShutdown()'):state.index('\nvoid Shutdown()')]
  for field in ('GameInputCreateHookInstalled','XInputGetStateHookInstalled',
                'DirectInput8CreateHookInstalled','DirectInputDeviceSlots'):
   self.assertNotIn(f'_state.{field} =',reset)
  self.assertIn('_state.Initialized = false;',reset)
  self.assertIn('_state.XInputHookAttempted = false;',reset)

class D3D11HookTransactionRegression(unittest.TestCase):
 def test_d3d11_hooks_enlist_process_threads_and_propagate_attach_errors(self):
  source=(PROJECT/'hooks/D3D11_Hooks.cpp').read_text(encoding='utf-8-sig')
  self.assertIn('#include <hooks/ProcessDetourTransaction.h>',source)
  self.assertEqual(source.count('WithProcessDetourTransaction('),2)
  self.assertEqual(source.count('QueueProcessDetour('),5)
  self.assertNotIn('DetourTransactionBegin()',source)
  self.assertNotIn('DetourTransactionCommit()',source)
  self.assertNotIn('DetourUpdateThread(GetCurrentThread())',source)
  helper=(PROJECT/'hooks/ProcessDetourTransaction.h').read_text(encoding='utf-8-sig')
  self.assertIn('LONG WithProcessDetourTransaction(',helper)
  self.assertIn('inline LONG QueueProcessDetour(',helper)
  self.assertIn('result = EnlistCurrentProcessThreads(threadHandles);',helper)
  self.assertIn('return DetourAttach(original, detour);',helper)
  self.assertIn('DetourTransactionAbort();',helper)

class D3D12HookTransactionRegression(unittest.TestCase):
 def test_device_and_agility_hooks_use_process_transactions(self):
  source=(PROJECT/'hooks/D3D12_Hooks.cpp').read_text(encoding='utf-8-sig')
  self.assertIn('#include <hooks/ProcessDetourTransaction.h>',source)
  device=source[source.index('static void HookToDevice(ID3D12Device* InDevice)\n{'):source.index('\nvoid D3D12Hooks::Hook()')]
  self.assertIn('WithProcessDetourTransaction(',device)
  self.assertGreaterEqual(device.count('QueueProcessDetour('),8)
  self.assertNotIn('DetourTransactionBegin()',device)
  factory=source[source.index('static HRESULT hkD3D12GetInterface(REFCLSID'):source.index('\nstatic void HookToDevice(ID3D12Device* InDevice)\n{')]
  self.assertIn('WithProcessDetourTransaction(',factory)
  self.assertIn('QueueProcessDetour(',factory)
  agility=source[source.index('void D3D12Hooks::HookAgility('):source.index('\nvoid D3D12Hooks::SetRootSignatureTracking(')]
  self.assertIn('WithProcessDetourTransaction(',agility)
  self.assertIn('QueueProcessDetour(',agility)
  for start,end in ((source.index('void D3D12Hooks::HookToCommandListLate('),
                         source.index('static void HookToCommandList(')),
                        (source.index('static void HookToCommandList('),
                         source.index('VALIDATE_HOOK(hkD3D12CreateDevice'))):
   group=source[start:end]
   self.assertIn('WithProcessDetourTransaction(',group)
   self.assertIn('QueueProcessDetour(',group)
   self.assertNotIn('DetourAttach(',group)
  self.assertNotIn('DetourTransactionBegin()',source)
  self.assertNotIn('DetourTransactionCommit()',source)

class GraphicsProxyTransactionRegression(unittest.TestCase):
 def test_dxgi_and_d3d12_proxy_exports_enlist_process_threads(self):
  for name,count in (('Dxgi_Proxy.h',5),('D3D12_Proxy.h',8)):
   source=(PROJECT/'proxies'/name).read_text(encoding='utf-8-sig')
   self.assertIn('#include <hooks/ProcessDetourTransaction.h>',source)
   self.assertEqual(source.count('AttachProcessDetour('),count)
   self.assertNotIn('DetourTransactionBegin()',source)
   self.assertNotIn('DetourUpdateThread(GetCurrentThread())',source)
   self.assertNotIn('DetourAttach(',source)
  helper=(PROJECT/'hooks/ProcessDetourTransaction.h').read_text(encoding='utf-8-sig')
  self.assertIn('inline LONG AttachProcessDetour(PVOID* original, PVOID detour)',helper)
  self.assertIn('return WithProcessDetourTransaction([&]() { return QueueProcessDetour(NO_ERROR, original, detour); });',helper)
  ffx=(PROJECT/'proxies/FfxApi_Proxy.h').read_text(encoding='utf-8-sig')
  self.assertEqual(ffx.count('WithProcessDetourTransaction('),6)
  self.assertEqual(ffx.count('QueueProcessDetour(attachResult,'),30)
  self.assertNotIn('DetourTransactionBegin()',ffx)
  self.assertNotIn('DetourTransactionCommit()',ffx)
  factory=(PROJECT/'hooks/DxgiFactory_Hooks.cpp').read_text(encoding='utf-8-sig')
  self.assertEqual(factory.count('WithProcessDetourTransaction('),2)
  self.assertGreaterEqual(factory.count('QueueProcessDetour(attachResult,'),10)
  self.assertNotIn('DetourTransactionBegin()',factory)
  self.assertNotIn('DetourAttach(',factory)
  self.assertIn('Failed to hook DLSS-G IDXGIFactory:',factory)
  for name,count in (('KernelBase_Proxy.h',10),('Ntdll_Proxy.h',4),('Kernel32_Proxy.h',1)):
   source=(PROJECT/'proxies'/name).read_text(encoding='utf-8-sig')
   self.assertIn('#include <hooks/ProcessDetourTransaction.h>',source)
   self.assertEqual(source.count('AttachProcessDetour('),count)
   self.assertNotIn('DetourTransactionBegin()',source)
  fg=(PROJECT/'hooks/FG_Hooks.cpp').read_text(encoding='utf-8-sig')
  self.assertEqual(fg.count('WithProcessDetourTransaction('),1)
  self.assertGreaterEqual(fg.count('QueueProcessDetour(attachResult,'),10)
  self.assertNotIn('DetourTransactionBegin()',fg)
  self.assertNotIn('DetourAttach(',fg)

class StreamlineHookTransactionRegression(unittest.TestCase):
 def test_streamline_transactions_enlist_process_threads_and_check_attaches(self):
  source=(PROJECT/'hooks/Streamline_Hooks.cpp').read_text(encoding='utf-8-sig')
  transaction=source[source.index('class InterposerDetourTransaction'):source.index('static void ObserveAcceptedTagMode')]
  self.assertIn('transactionLock{OptiShade::Detours::ProcessDetourTransactionMutex()}',transaction)
  self.assertIn('EnlistCurrentProcessThreads(threadHandles,&deniedThreads)',transaction)
  self.assertIn('CloseThreadHandles();',transaction)
  common=source[source.index('void StreamlineHooks::hkcommon_slSetParameters_sl1'):source.index('void* StreamlineHooks::hkcommon_slGetPluginFunction')]
  self.assertIn('WithProcessDetourTransaction(',common)
  plugin=source[source.index('void StreamlineHooks::hookPlugin('):source.index('bool StreamlineHooks::isPluginHooked(')]
  self.assertIn('AttachProcessDetour(',plugin)
  self.assertNotIn('DetourTransactionBegin()',plugin)

class D3D12ResourceTrackerTransactionRegression(unittest.TestCase):
 def test_resource_tracker_hooks_use_process_thread_transactions(self):
  source=(PROJECT/'resource_tracking/ResTrack_dx12.cpp').read_text(encoding='utf-8-sig')
  self.assertIn('#include <hooks/ProcessDetourTransaction.h>',source)
  self.assertEqual(source.count('WithProcessDetourTransaction('),6)
  self.assertGreaterEqual(source.count('QueueProcessDetour(attachResult,'),16)
  self.assertNotIn('DetourTransactionBegin()',source)
  self.assertNotIn('DetourAttach(',source)
  self.assertIn('Failed to hook CommandList methods:',source)

class VulkanHookTransactionRegression(unittest.TestCase):
 def test_vulkan_and_ngx_hooks_enlist_threads_and_check_attach_results(self):
  vulkan=(PROJECT/'hooks/Vulkan_Hooks.cpp').read_text(encoding='utf-8-sig')
  self.assertEqual(vulkan.count('WithProcessDetourTransaction('),1)
  self.assertGreaterEqual(vulkan.count('QueueProcessDetour(attachResult,'),12)
  self.assertNotIn('DetourTransactionBegin()',vulkan)
  self.assertNotIn('DetourAttach(',vulkan)
  ngx=(PROJECT/'proxies/NVNGX_Proxy.h').read_text(encoding='utf-8-sig')
  self.assertIn('WithProcessDetourTransaction(',ngx)
  self.assertEqual(ngx.count('QueueProcessDetour(attachResult,'),3)
  self.assertNotIn('DetourTransactionBegin()',ngx)
  self.assertNotIn('DetourAttach(',ngx)
  vkdx12=(PROJECT/'hooks/VulkanwDx12_Hooks.cpp').read_text(encoding='utf-8-sig')
  self.assertEqual(vkdx12.count('WithProcessDetourTransaction('),1)
  self.assertGreaterEqual(vkdx12.count('QueueProcessDetour(attachResult,'),250)
  self.assertNotIn('DetourTransactionBegin()',vkdx12)
  self.assertNotIn('DetourAttach(',vkdx12)

class FsrFrameGenerationTransactionRegression(unittest.TestCase):
 def test_fsr3_fg_hooks_enlist_process_threads_and_fail_closed(self):
  source=(PROJECT/'inputs/FG/FSR3_Dx12_FG.cpp').read_text(encoding='utf-8-sig')
  self.assertIn('#include <hooks/ProcessDetourTransaction.h>',source)
  self.assertEqual(source.count('WithProcessDetourTransaction('),2)
  self.assertEqual(source.count('QueueProcessDetour('),24)
  self.assertNotIn('DetourTransactionBegin()',source)
  self.assertNotIn('DetourAttach(',source)
  self.assertEqual(source.count('Detours transaction result:'),2)
  self.assertIn('State::Instance().fsrHooks = o_ffxReplaceSwapchainForFrameinterpolationDX12 != nullptr;',source)

class LoaderHookTransactionRegression(unittest.TestCase):
 def test_fsr2_vulkan_executable_hooks_resolve_before_checked_process_transaction(self):
  source=(PROJECT/'inputs/FSR2_Vk.cpp').read_text(encoding='utf-8-sig')
  hook=source[source.index('void HookFSR2VkExeInputs()'):]
  self.assertIn('#include <hooks/ProcessDetourTransaction.h>',source)
  self.assertEqual(hook.count('KernelBaseProxy::GetProcAddress_()'),8)
  self.assertEqual(hook.count('QueueProcessDetour(\n'),8)
  self.assertLess(hook.index('KernelBaseProxy::GetProcAddress_()'),hook.index('WithProcessDetourTransaction('))
  self.assertIn('if (detourResult != NO_ERROR)',hook)
  for unmanaged in ('DetourTransactionBegin()','DetourTransactionCommit()','DetourUpdateThread(','DetourAttach('):
   self.assertNotIn(unmanaged,hook)

 def test_fsr2_dx12_executable_scans_before_atomic_process_wide_attach(self):
  import re
  source=(PROJECT/'inputs/FSR2_Dx12.cpp').read_text(encoding='utf-8-sig')
  hook=source[source.index('void HookFSR2ExeInputs()'):source.index('\nvoid HookFSR2Inputs(',source.index('void HookFSR2ExeInputs()'))]
  active=re.sub(r'//[^\n]*','',hook)
  self.assertIn('#include <hooks/ProcessDetourTransaction.h>',source)
  self.assertEqual(active.count('QueueProcessDetour('),11)
  self.assertEqual(active.count('WithProcessDetourTransaction('),1)
  self.assertLess(active.index('scanner::GetAddress'),active.index('WithProcessDetourTransaction('))
  self.assertIn('if (detourResult != NO_ERROR)',active)
  for unmanaged in ('DetourTransactionBegin()','DetourTransactionCommit()','DetourUpdateThread(','DetourAttach('):
   self.assertNotIn(unmanaged,active)

 def test_fsr2_dx11_executable_hooks_resolve_before_checked_process_transaction(self):
  source=(PROJECT/'inputs/FSR2_Dx11.cpp').read_text(encoding='utf-8-sig')
  hook=source[source.index('void HookFSR2Dx11ExeInputs()'):]
  self.assertIn('#include <hooks/ProcessDetourTransaction.h>',source)
  self.assertEqual(hook.count('KernelBaseProxy::GetProcAddress_()'),6)
  self.assertEqual(hook.count('QueueProcessDetour('),6)
  self.assertLess(hook.index('KernelBaseProxy::GetProcAddress_()'),hook.index('WithProcessDetourTransaction('))
  self.assertIn('if (detourResult != NO_ERROR)',hook)
  for unmanaged in ('DetourTransactionBegin()','DetourTransactionCommit()','DetourUpdateThread(','DetourAttach('):
   self.assertNotIn(unmanaged,hook)

 def test_ffx_dx12_executable_hooks_use_checked_process_wide_transaction(self):
  source=(PROJECT/'inputs/FfxApiExe_Dx12.cpp').read_text(encoding='utf-8-sig')
  self.assertIn('#include <hooks/ProcessDetourTransaction.h>',source)
  self.assertIn('WithProcessDetourTransaction(',source)
  self.assertEqual(source.count('QueueProcessDetour('),5)
  self.assertIn('if (detourResult != NO_ERROR)',source)
  for unmanaged in ('DetourTransactionBegin()','DetourTransactionCommit()','DetourUpdateThread(','DetourAttach('):
   self.assertNotIn(unmanaged,source)

 def test_wrapped_dxgi_adapter_parent_hook_enlists_process_threads(self):
  source=(PROJECT/'wrapped/wrapped_factory.cpp').read_text(encoding='utf-8-sig')
  self.assertIn('#include <hooks/ProcessDetourTransaction.h>',source)
  self.assertIn('AttachProcessDetour(&(PVOID&) o_GetParent, hkGetParent)',source)
  for unmanaged in ('DetourTransactionBegin()','DetourTransactionCommit()','DetourUpdateThread(','DetourAttach('):
   self.assertNotIn(unmanaged,source)

 def test_platform_and_xell_hooks_check_process_wide_transactions(self):
  for name,count in (('Advapi32_Hooks.h',5),('Crypt32_Hooks.h',1),('Gdi32_Hooks.h',1),('Wintrust_Hooks.h',1)):
   source=(PROJECT/'hooks'/name).read_text(encoding='latin-1' if name=='Advapi32_Hooks.h' else 'utf-8-sig')
   self.assertIn('WithProcessDetourTransaction(',source)
   self.assertEqual(source.count('QueueProcessDetour(attachResult,'),count)
   self.assertNotIn('DetourTransactionBegin()',source)
  amd=(PROJECT/'hooks/Amdxc64_Hooks.cpp').read_text(encoding='utf-8-sig')
  self.assertIn('AttachProcessDetour(',amd)
  self.assertNotIn('DetourTransactionBegin()',amd)
  xell=(PROJECT/'hooks/Xell_Hooks.cpp').read_text(encoding='utf-8-sig')
  self.assertIn('WithProcessDetourTransaction(',xell)
  self.assertIn('QueueProcessDetour(attachResult,',xell)
  self.assertEqual(xell.count('\n        HOOK('),8)
  self.assertIn('if (detourResult != NO_ERROR)',xell)
  self.assertIn('return false;',xell)
  self.assertNotIn('DetourTransactionBegin()',xell)

 def test_xess_proxy_batches_check_all_attachments_and_enlist_process_threads(self):
  proxy=(PROJECT/'proxies/XeSS_Proxy.h').read_text(encoding='utf-8-sig')
  self.assertIn('#include <hooks/ProcessDetourTransaction.h>',proxy)
  self.assertEqual(proxy.count('WithProcessDetourTransaction('),2)
  self.assertEqual(proxy.count('QueueProcessDetour(\n'),58)
  self.assertEqual(proxy.count('attachResult, &(PVOID&)'),58)
  self.assertEqual(proxy.count('return attachResult;'),2)
  for unmanaged in ('DetourTransactionBegin()','DetourTransactionCommit()','DetourUpdateThread(GetCurrentThread())','DetourAttach('):
   self.assertNotIn(unmanaged,proxy)
  self.assertIn('Failed to install XeSS D3D12/Vulkan hooks',proxy)
  self.assertIn('Failed to install XeSS D3D11 hooks',proxy)

 def test_xell_export_redirect_is_process_wide_and_fails_closed_on_attach_errors(self):
  proxy=(PROJECT/'proxies/XeLL_Proxy.h').read_text(encoding='utf-8-sig')
  self.assertIn('#include <hooks/ProcessDetourTransaction.h>',proxy)
  self.assertIn('ExportRedirectContext context { hNew, NO_ERROR };',proxy)
  self.assertIn('WithProcessDetourTransaction(',proxy)
  self.assertIn('DetourEnumerateExports(hOld, &context, ExportCallback)',proxy)
  self.assertIn('std::deque<PVOID> originalFunctions;',proxy)
  self.assertIn('context->originalFunctions.push_back(pOldFunction);',proxy)
  self.assertIn('DetourAttach(&context->originalFunctions.back(), pNewFunction)',proxy)
  self.assertIn('return context.attachResult != NO_ERROR ? context.attachResult : ERROR_PROC_NOT_FOUND;',proxy)
  self.assertNotIn('DetourTransactionBegin()',proxy)

class NgxHookLifetimeRegression(unittest.TestCase):
 def test_feature_shutdown_does_not_detach_process_lifetime_callbacks(self):
  proxy=(PROJECT/'proxies/NVNGX_Proxy.h').read_text(encoding='utf-8-sig')
  nvapi=(PROJECT/'nvapi/NvApiHooks.cpp').read_text(encoding='utf-8-sig')
  feature=(PROJECT/'upscalers/dlss/DLSSFeature.cpp').read_text(encoding='utf-8-sig')
  feature_header=(PROJECT/'upscalers/dlss/DLSSFeature.h').read_text(encoding='utf-8-sig')
  dx12=(PROJECT/'upscalers/dlss/DLSSFeature_Dx12.cpp').read_text(encoding='utf-8-sig')
  self.assertIn('#include <hooks/ProcessDetourTransaction.h>',nvapi)
  self.assertIn('AttachProcessDetour(',nvapi)
  for unmanaged in ('DetourTransactionBegin()','DetourTransactionCommit()','DetourUpdateThread(','DetourAttach('):
   self.assertNotIn(unmanaged,nvapi)
  for source in (proxy,nvapi):
   self.assertIn('GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN',source)
   self.assertIn('GetModuleHandleExW(',source)
  self.assertIn('Original_Vulkan_GetFeatureRequirements != nullptr',proxy)
  self.assertNotIn('UnhookApis',proxy)
  self.assertNotIn('NvApiHooks::Unhook',proxy)
  self.assertNotIn('static void Shutdown();',feature_header)
  self.assertNotIn('DLSSFeature::Shutdown()',feature)
  self.assertNotIn('DLSSFeature::Shutdown()',dx12)

class Fsr4ModelSelectionHookLifetimeRegression(unittest.TestCase):
 def test_model_selection_callbacks_pin_targets_and_are_not_detached_on_replacement(self):
  source=(PROJECT/'fsr4/FSR4ModelSelection.cpp').read_text(encoding='utf-8-sig')
  hook=source[source.index('void FSR4ModelSelection::Hook'):]
  self.assertIn('GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN',source)
  self.assertIn('PinModelSelectionModule(module)',hook)
  self.assertIn('g_modelSelectionHookMutex',hook)
  self.assertIn('ignoring replacement module',hook)
  self.assertNotIn('DetourDetach',hook)
  self.assertIn('hookedModule = module;',hook)

class AgilityUpgradeLoaderLockRegression(unittest.TestCase):
 def test_agility_sdk_upgrade_is_deferred_to_first_device_request(self):
  entry=(PROJECT/'dllmain.cpp').read_text(encoding='utf-8-sig')
  upgrade=entry[entry.index('void RunAgilityUpgrade'):entry.index('\nvoid LoadAsiPlugins',entry.index('void RunAgilityUpgrade'))]
  self.assertIn('std::call_once',upgrade)
  self.assertIn('D3D12GetInterface(CLSID_D3D12SDKConfiguration',upgrade)
  self.assertIn('SetSDKVersion(customD3D12SDKVersion',upgrade)
  self.assertNotIn('DetourDetach',upgrade)
  self.assertIn('thread_local bool g_forceDeveloperModeForAgilityUpgrade',entry)
  self.assertIn('g_originalIsDeveloperModeEnabled(isEnabled)',entry)
  self.assertNotIn('RunAgilityUpgrade(',entry[entry.index('static void CheckWorkingMode'):entry.index('BOOL APIENTRY DllMain')])
  hooks=(PROJECT/'hooks/D3D12_Hooks.cpp').read_text(encoding='utf-8-sig')
  create=hooks[hooks.index('static HRESULT hkD3D12CreateDevice'):hooks.index('VALIDATE_HOOK(hkD3D12SerializeRootSignature')]
  self.assertIn('RunAgilityUpgrade();',create)
  self.assertLess(create.index('RunAgilityUpgrade();'),create.index('o_D3D12CreateDevice('))
  self.assertIn('Config::Instance()->FsrAgilitySDKUpgrade.value_or_default()',entry[entry.index('static void CheckWorkingMode'):entry.index('BOOL APIENTRY DllMain')])

class StreamlinePluginHookLifetimeRegression(unittest.TestCase):
 def test_plugin_slots_only_retire_unmapped_modules_without_detach(self):
  source=(PROJECT/'hooks/Streamline_Hooks.cpp').read_text(encoding='utf-8-sig')
  header=(PROJECT/'hooks/Streamline_Hooks.h').read_text(encoding='utf-8-sig')
  self.assertNotIn('DetourDetach',source)
  self.assertNotIn('unhookPlugin',source+header)
  self.assertIn('if (isSlotAlive(slot))',source)
  self.assertIn('releaseDeadSlot(plugin, i);',source)
  module_free=source[source.index('void StreamlineHooks::onModuleFreed'):source.index('// SL DLSS',source.index('void StreamlineHooks::onModuleFreed'))]
  self.assertIn('releaseDeadSlots(plugin);',module_free)

class StreamlineFgDisplayExtentRegression(unittest.TestCase):
 def test_streamline_fg_state_uses_output_extent_and_fails_closed_if_unknown(self):
  source=(PROJECT/'inputs/FG/Streamline_Inputs_Dx12.cpp').read_text(encoding='utf-8-sig')
  self.assertIn('state.currentFGSwapchain->GetDesc(&fgSwapchainDesc)',source)
  self.assertIn('fgSwapchainDesc.OutputWindow == fgOutput->Hwnd()',source)
  self.assertIn('state.currentSwapchainDesc.OutputWindow == fgOutput->Hwnd()',source)
  self.assertIn('SelectDisplayExtent(outputExtent, sameOutputFallback)',source)
  self.assertIn('if (!displayExtent.IsValid())',source)
  self.assertIn('return true;',source[source.index('if (!displayExtent.IsValid())'):source.index('// FG Evaluate part')])
  self.assertNotIn('fgConstants.displayWidth = 0;',source)
  self.assertNotIn('fgConstants.displayHeight = 0;',source)

class VulkanRenderingAdapterRegression(unittest.TestCase):
 def test_vulkan_ngx_create_feature_validates_and_checks_returned_handles(self):
  source=(PROJECT/'inputs/NVNGX_DLSS_Vk.cpp').read_text(encoding='utf-8-sig')
  feature1=source[source.index('NVSDK_NGX_API NVSDK_NGX_Result NVSDK_NGX_VULKAN_CreateFeature1('):source.index('\nNVSDK_NGX_API NVSDK_NGX_Result NVSDK_NGX_VULKAN_CreateFeature(',source.index('NVSDK_NGX_API NVSDK_NGX_Result NVSDK_NGX_VULKAN_CreateFeature1('))]
  feature=source[source.index('NVSDK_NGX_API NVSDK_NGX_Result NVSDK_NGX_VULKAN_CreateFeature('):source.index('\nNVSDK_NGX_API NVSDK_NGX_Result NVSDK_NGX_VULKAN_ReleaseFeature(',source.index('NVSDK_NGX_API NVSDK_NGX_Result NVSDK_NGX_VULKAN_CreateFeature('))]
  for body in (feature1,feature):
   self.assertIn('if (!OutHandle)',body)
   self.assertIn('return NVSDK_NGX_Result_FAIL_InvalidParameter;',body)
   self.assertIn('*OutHandle = nullptr;',body)
   self.assertRegex(body,r'result == NVSDK_NGX_Result_Success && \*OutHandle\s*\)\s*\{\s*LOG_INFO\([^;]*\(\*OutHandle\)->Id')
   self.assertIn('Vulkan DLSSG provider succeeded without returning a feature handle',body)
   self.assertIn('return NVSDK_NGX_Result_FAIL_PlatformError;',body)

 def test_dlss_selection_uses_the_vulkan_rendering_device_luid(self):
  provider=(PROJECT/'upscalers/FeatureProvider_Vk.cpp').read_text(encoding='utf-8-sig')
  identify=(PROJECT/'misc/IdentifyGpu.cpp').read_text(encoding='utf-8-sig')
  init=(PROJECT/'inputs/NVNGX_DLSS_Vk.cpp').read_text(encoding='utf-8-sig')
  dx12=(PROJECT/'inputs/NVNGX_DLSS_Dx12.cpp').read_text(encoding='utf-8-sig')
  self.assertIn('getGpuForVulkanPhysicalDevice(state.currentVkPhysicalDevice)',provider)
  self.assertIn('getGpuForVulkanPhysicalDevice(pd)',provider)
  self.assertNotIn('getPrimaryGpu()',provider)
  self.assertIn('State::Instance().currentVkPhysicalDevice = InPD;',init)
  self.assertIn('getGpuForVulkanPhysicalDevice(vkPD)',init)
  self.assertIn('getGpuForAdapter(Adapter)',dx12)
  self.assertNotIn('getPrimaryGpu().dlssCapable',dx12)
  self.assertNotIn('getPrimaryGpu().dlssCapable',init)
  self.assertIn('GpuInformation IdentifyGpu::getGpuForAdapter(IDXGIAdapter* adapter)',identify)
  self.assertIn('idProperties.deviceLUIDValid != VK_TRUE',identify)
  self.assertIn('getGpuByLuid(luid)',identify)
  self.assertIn('gpu.deviceId != properties.properties.deviceID',identify)
  self.assertIn('NvidiaUpscalerUnavailableReason(hardware, state.NVNGX_DLSS_Path.has_value())',provider)

 def test_ngx_and_menu_capability_checks_follow_the_active_renderer(self):
  parameters=(PROJECT/'NVNGX_Parameter.cpp').read_text(encoding='utf-8-sig')
  menu=(PROJECT/'menu/menu_common.cpp').read_text(encoding='utf-8-sig')
  panel=(PROJECT/'menu/OptiShadePanel.inl').read_text(encoding='utf-8-sig')
  vk_hooks=(PROJECT/'hooks/Vulkan_Hooks.cpp').read_text(encoding='utf-8-sig')
  vk_dx12=(PROJECT/'hooks/VulkanwDx12_Hooks.cpp').read_text(encoding='utf-8-sig')
  self.assertIn('getGpuForDx11Device(state.currentD3D11Device)',parameters)
  self.assertIn('getGpuForDevice(state.currentD3D12Device)',parameters)
  self.assertIn('getGpuForVulkanPhysicalDevice(state.currentVkPhysicalDevice)',parameters)
  self.assertIn('renderingGpu.vendorId != VendorId::Invalid && !renderingGpu.dlssCapable',parameters)
  self.assertIn('getGpuForVulkanPhysicalDevice(ctx.state.currentVkPhysicalDevice)',panel)
  self.assertIn('primaryGpu.vendorId != VendorId::Invalid && !primaryGpu.dlssCapable',menu)
  self.assertIn('getGpuForVulkanPhysicalDevice(dispatch->second.physical)',vk_hooks)
  self.assertNotIn('if (!IdentifyGpu::getPrimaryGpu().usesDxvk)',vk_hooks)
  self.assertIn('getGpuForVulkanPhysicalDevice(State::Instance().currentVkPhysicalDevice)',vk_dx12)

 def test_nvapi_fallback_never_replaces_a_measured_nvidia_adapter(self):
  loader=(PROJECT/'hooks/LibraryLoad_Hooks.cpp').read_text(encoding='utf-8-sig')
  policy=(CHANNEL/'shared/BackendSelection.h').read_text(encoding='utf-8-sig')
  self.assertIn('const auto adapters = IdentifyGpu::getAllGpus();',loader)
  self.assertIn('ShouldSubstituteFakeNvApi(',loader)
  self.assertIn('gpu.vendorId == VendorId::Nvidia',loader)
  self.assertNotIn('IdentifyGpu::getPrimaryGpu().vendorId != VendorId::Nvidia',loader)
  self.assertIn('if (!enabled) return false;',policy)
  self.assertIn('anyMeasuredAdapter = true;',policy)
  self.assertIn('if (isNvidia(adapter)) return false;',policy)
  self.assertIn('return anyMeasuredAdapter;',policy)

class FreeTypeAllocatorContract(unittest.TestCase):
 def test_freetype_library_uses_matching_imgui_heap_callbacks(self):
  source=(PROJECT/'include/imgui/misc/freetype/imgui_freetype.cpp').read_text(encoding='utf-8-sig')
  self.assertIn('return IM_ALLOC(size);',source)
  self.assertIn('IM_FREE(ptr);',source)
  self.assertIn('return GImGuiFreeTypeAllocFunc((size_t)size, GImGuiFreeTypeAllocatorUserData);',source)
  self.assertIn('GImGuiFreeTypeFreeFunc(block, GImGuiFreeTypeAllocatorUserData);',source)
  setup=source[source.index('bd->MemoryManager.alloc = &FreeType_Alloc;'):source.index('// Store our data')]
  self.assertIn('bd->MemoryManager.free = &FreeType_Free;',setup)
  self.assertIn('bd->MemoryManager.realloc = &FreeType_Realloc;',setup)
  self.assertLess(setup.index('FT_New_Library(&bd->MemoryManager'),setup.index('FT_Add_Default_Modules(bd->Library)'))
  shutdown=source[source.index('void ImGui_ImplFreeType_LoaderShutdown'):]
  self.assertLess(shutdown.index('FT_Done_Library(bd->Library)'),shutdown.index('IM_DELETE(bd);'))

class MfgHookRegression(unittest.TestCase):
 def test_legacy_interval_logging_setting_cannot_disable_release_trace(self):
  copies=(
   CHANNEL/'installer/OptionalMFG/Source203040/native/patcher.cpp',
   CHANNEL/'optiscaler/external/RTX40MFG-Unlock/source/native/patcher.cpp',
  )
  blocks=[]
  for path in copies:
   source=path.read_text(encoding='utf-8-sig')
   start=source.index('size_t intervalLoggingOffset = 0;')
   end=source.index('size_t generatedOnlyOffset = 0;',start)
   block=source[start:end]
   self.assertIn('bool legacyIntervalLogging = true;',block)
   self.assertIn('TryParseBoolean(content, "intervalLogging",\n            legacyIntervalLogging)',block)
   self.assertRegex(block,r'parsed\.intervalLogging\s*=\s*true\s*;')
   self.assertGreater(block.index('parsed.intervalLogging = true;'),block.index('TryParseBoolean'))
   self.assertIn('snapshot.control.intervalLogging = temporal_interval_trace::Enabled();',source)
   self.assertIn('intervalLoggingEnabled',source)
   blocks.append(block)
  self.assertEqual(blocks[0],blocks[1], 'Packaged and upstream MFG control parsing must stay aligned.')

 def test_automatic_runtime_diagnostics_are_not_simulator_name_gated(self):
  source=(ROOT/'Beta/shared/AutoDiagnostics.h').read_text(encoding='utf-8')
  self.assertIn('arbitrary selected game executables',source)
  self.assertIn('if(exe.empty()||component.empty())return;',source)
  self.assertNotIn('FlightSimulator2024.exe',source)
  self.assertNotIn('X-Plane.exe',source)

 def test_unresolved_mfg_provider_is_captured_with_present_correlation(self):
  hooks=(CHANNEL/'optiscaler/OptiScaler/hooks/Streamline_Hooks.cpp').read_text(encoding='utf-8-sig')
  managed=hooks[hooks.index('sl::Result StreamlineHooks::hkslDLSSGGetState('):hooks.index('bool StreamlineHooks::hkreflex_slOnPluginLoad',hooks.index('sl::Result StreamlineHooks::hkslDLSSGGetState('))]
  self.assertLess(managed.index('RecordStateCall'),managed.index('if (!o_slDLSSGGetState)'))
  self.assertIn('Managed provider function unavailable',managed)
  self.assertIn('PutCritical',managed)
  self.assertIn('OptiScaler primary game swapchain Present',managed)
  external=hooks[hooks.index('sl::Result StreamlineHooks::ExternalState('):hooks.index('sl::Result StreamlineHooks::ExternalPcl(')]
  self.assertIn('External provider function unavailable',external)
  self.assertIn('FGProviderFunctionAvailable',external)
  self.assertIn('"No"',external)
  diagnostics=(CHANNEL/'installer/diagnostics.ps1').read_text(encoding='utf-8-sig')
  safe=diagnostics[diagnostics.index('function GetSafeLastSessionSnapshot'):diagnostics.index('function GetDiagnosticContext')]
  self.assertIn("'FGProviderFunctionAvailable'",safe)
  self.assertIn("'FGPresentSwapchainId'",safe)

 def test_streamline_slinit_enables_bounded_relocated_fallback(self):
  source=(CHANNEL/'installer/OptionalMFG/Source203040/native/patcher.cpp').read_text(encoding='utf-8-sig')
  start=source.index('bool TryInstallSlInitEntryDetour(HMODULE interposer, void* resolvedTarget)\n{')
  end=source.index('\nFARPROC WINAPI HookMainGetProcAddress',start)
  body=source[start:end]
  self.assertIn('options.allowRelocated = true;',body)
  self.assertIn('entry_detour::InstallOptions options{};',body)
  detour=(CHANNEL/'installer/OptionalMFG/Source203040/native/entry_detour.cpp').read_text(encoding='utf-8-sig')
  self.assertIn('hotpatchFailure == Failure::eUnsupportedEntry',detour)
  self.assertIn('const bool relocatedInstalled = mayRelocate',detour)
 def test_loaded_module_inventory_records_paths_without_opening_module_files(self):
  patcher=(CHANNEL/'installer/OptionalMFG/Source203040/native/patcher.cpp').read_text(encoding='utf-8-sig')
  start=patcher.index('ModuleRecord InspectLoadedModule(HMODULE module, const std::wstring& suppliedPath)\n{')
  end=patcher.index('\nvoid RemoveLoadedModule(HMODULE module)',start)
  self.assertNotIn('ReadFileVersion(',patcher[start:end])
  self.assertNotIn('GetFileVersionInfo',patcher[start:end])
  diagnostics=(CHANNEL/'installer/diagnostics.ps1').read_text(encoding='utf-8-sig')
  module_record=diagnostics[diagnostics.index('$report.LoadedModules+='):].splitlines()[0]
  self.assertIn('Name=$_.ModuleName',module_record)
  self.assertIn('Path=$_.FileName',module_record)
  self.assertNotIn('FileVersionInfo',module_record)
 def test_glass_cockpit_component_licenses_and_provenance_are_visible(self):
  provenance=json.loads((CHANNEL/'installer/GlassCockpit/PROVENANCE.json').read_text(encoding='utf-8-sig'))
  xaml=(CHANNEL/'installer/manager.xaml').read_text(encoding='utf-8-sig')
  panel=(PROJECT/'menu/OptiShadePanel.inl').read_text(encoding='utf-8-sig')
  package=(CHANNEL/'package.ps1').read_text(encoding='utf-8-sig')
  status=(CHANNEL/'installer/manager-status.ps1').read_text(encoding='utf-8-sig')
  self.assertEqual('v1.0.3',provenance['Version'])
  self.assertEqual('524cbd27601bc8e1904e76ecf7f0702cdef8dbc81f089a8c88adf622a66f16e3',provenance['SHA256'])
  self.assertIn('Glass Cockpit DLSS Fix by IFreemz',xaml)
  self.assertIn('github.com/IFreemz/msfs2024-glass-cockpit-dlss-fix',xaml)
  self.assertIn('NOTICE.md',package)
  self.assertIn('GPL-3.0-only',panel)

class CrashDumpEvidence(unittest.TestCase):
 def test_crash_dump_attribution_requires_embedded_pid_and_birth_match(self):
  summary=(CHANNEL/'installer/Troubleshooter/src/DumpSummary.cs').read_text(encoding='utf-8-sig')
  collector=(CHANNEL/'installer/Troubleshooter/src/Collector.cs').read_text(encoding='utf-8-sig')
  program=(CHANNEL/'installer/Troubleshooter/src/Program.cs').read_text(encoding='utf-8-sig')
  self.assertIn('public static DumpProcessIdentityInfo ReadProcessIdentity(string path)',summary)
  self.assertIn('ProcessBirthFileTime=a.dumpProcessBirthFileTime',summary)
  self.assertIn('internal static string ClassifyCrashDumpProcessIdentity',collector)
  self.assertIn('dump.ProcessId==selectedPid&&dump.ProcessBirthFileTime/TimeSpan.TicksPerSecond==selectedBirth/TimeSpan.TicksPerSecond',collector)
  self.assertIn('minidump time is second-resolution',collector)
  self.assertIn('selected installation LastSession',collector)
  self.assertIn('Dump-to-session association:',collector)
  self.assertIn('different birth time is not treated as the selected game session',program)
  self.assertIn('Missing dump identity remains explicitly unverified',program)

class CommonBuildConfiguration(unittest.TestCase):
 def test_common_build_can_place_disposable_workspace_on_another_volume(self):
  script=(ROOT/'Common/build-private-channel.ps1').read_text(encoding='utf-8-sig')
  readme=(ROOT/'Common/README.md').read_text(encoding='utf-8-sig')
  self.assertIn("[string]$WorkspaceRoot=''",script)
  self.assertIn('[ValidateRange(0,99999)][int]$PrivateTestNumber=0',script)
  self.assertIn('[switch]$ReuseVerifiedLegacyNRHost',script)
  self.assertIn('AssertOptiShadeLegacyWorkerReuse',script)
  self.assertIn('-ReuseVerifiedLegacyNRHost:$ReuseVerifiedLegacyNRHost',script)
  self.assertIn('$versionMetadata.version -notmatch',script)
  self.assertIn('-PrivateTestNumber $privateTestNumber',script)
  self.assertIn("Join-Path $repository 'PrivateBuild'",script)
  self.assertIn("if(-not [IO.Path]::IsPathRooted($WorkspaceRoot))",script)
  self.assertIn("WorkspaceRoot must be outside the canonical Beta source tree",script)
  self.assertIn("Join-Path $workspaceRoot ('Common-'+$Channel+'-'",script)
  self.assertIn("-WorkspaceRoot 'D:\\OptiShadeBuilds'",readme)
  self.assertIn('patch component',readme)

 def test_common_build_does_not_reintroduce_removed_tester_auth(self):
  script=(ROOT/'Common/build-private-channel.ps1').read_text(encoding='utf-8-sig')
  readme=(ROOT/'Common/README.md').read_text(encoding='utf-8-sig')
  package=(CHANNEL/'package.ps1').read_text(encoding='utf-8-sig')
  self.assertNotIn('TesterAuthURL',script)
  self.assertNotIn('TesterAuthURL',readme)
  self.assertNotIn('requires the host\'s active https',readme.lower())
  self.assertNotIn('add-user',readme)
  self.assertNotIn('tunnel',readme.lower())
  self.assertIn('-PrivateTesting $true -PrivateTestNumber $privateTestNumber',script)
  self.assertNotIn('TesterAuthURL',package)

 def test_low_latency_input_preference_is_persisted_and_validated(self):
  config=(CHANNEL/'optiscaler/OptiScaler/Config.cpp').read_text(encoding='utf-8-sig')
  header=(CHANNEL/'optiscaler/OptiScaler/Config.h').read_text(encoding='utf-8-sig')
  setting=(CHANNEL/'shared/LowLatencyInputSetting.h').read_text(encoding='utf-8-sig')
  self.assertIn('readUInt("fakenvapi", "LowLatencyInput")',config)
  self.assertIn('ParseLowLatencyInput',config)
  self.assertIn('"LowLatencyInput"',config)
  self.assertIn('SerializeLowLatencyInput',config)
  self.assertNotIn('TODO: no reading/saving to config',header)
  self.assertIn('value >= static_cast<uint32_t>(LowLatencyInput::_)',setting)
  self.assertIn('raw >= static_cast<uint32_t>(LowLatencyInput::_)',setting)

class CrashSymbolBuild(unittest.TestCase):
 def test_optimized_native_candidate_builds_and_binds_private_symbols(self):
  project=ET.parse(CHANNEL/'reshade/ReShade.vcxproj').getroot()
  ns={'m':'http://schemas.microsoft.com/developer/msbuild/2003'}
  for platform in ('Win32','x64'):
   condition=f"'$(Configuration)|$(Platform)'=='Release|{platform}'"
   group=next(node for node in project.findall('m:ItemDefinitionGroup',ns) if node.attrib.get('Condition')==condition)
   compile_node=group.find('m:ClCompile',ns);link=group.find('m:Link',ns)
   self.assertEqual('MaxSpeed',compile_node.findtext('m:Optimization',namespaces=ns))
   self.assertEqual('ProgramDatabase',compile_node.findtext('m:DebugInformationFormat',namespaces=ns))
   self.assertIn('/Zi',compile_node.findtext('m:AdditionalOptions',namespaces=ns))
   self.assertEqual('true',link.findtext('m:GenerateDebugInformation',namespaces=ns))
   self.assertEqual('$(OutDir)$(TargetName).pdb',link.findtext('m:ProgramDatabaseFile',namespaces=ns))
   self.assertEqual('false',link.findtext('m:LinkIncremental',namespaces=ns))
   self.assertEqual('false',link.findtext('m:EnableCOMDATFolding',namespaces=ns))
   self.assertEqual('true',link.findtext('m:OptimizeReferences',namespaces=ns))
   self.assertIn('/PDBALTPATH:$(TargetName).pdb',link.findtext('m:AdditionalOptions',namespaces=ns))
  routes=(CHANNEL/'build-routes.cmd').read_text(encoding='utf-8-sig')
  self.assertEqual(4,routes.count('/O2 /Zi /LD'))
  self.assertEqual(4,routes.count('/DEBUG /PDB:bin\\'))
  forwarder=ET.parse(CHANNEL/'optiscaler/OptiScaler/dlssnr/forwarder/dlssnr_forwarder.vcxproj').getroot()
  group=next(node for node in forwarder.findall('m:ItemDefinitionGroup',ns) if node.attrib.get('Condition')=="'$(Configuration)'=='Release'")
  link=group.find('m:Link',ns)
  self.assertEqual('true',link.findtext('m:GenerateDebugInformation',namespaces=ns))
  self.assertEqual('$(OutDir)$(TargetName).pdb',link.findtext('m:ProgramDatabaseFile',namespaces=ns))
  self.assertIn('/PDBALTPATH:$(TargetName).pdb',link.findtext('m:AdditionalOptions',namespaces=ns))
  candidate=(CHANNEL/'build-candidate.ps1').read_text(encoding='utf-8-sig')
  self.assertIn('reconstruction/symbol_identity.py',candidate)
  for relative in ('OptiScaler.pdb','nvngx.dll_dlssnr.pdb','ReShade64.pdb','ReShade32.pdb','OptiShadeMSFS2024.pdb','OptiShadeMSFS2020.pdb','OptiShadeXPlane12.pdb','OptiShadeGeneric.pdb'):
   self.assertIn(relative,candidate)
  package_verifier=(CHANNEL/'installer/verify_package.go').read_text(encoding='utf-8')
  self.assertIn('".pdb"',package_verifier)
  self.assertNotIn('.pdb',json.dumps(json.loads((CHANNEL/'package-inputs.json').read_text(encoding='utf-8-sig'))))

class ManagerUi(unittest.TestCase):
 def test_new_optimg_component_is_selectable_without_bundling_legacy_provider(self):
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  xaml=(CHANNEL/'installer/manager.xaml').read_text(encoding='utf-8-sig')
  package=(CHANNEL/'package.ps1').read_text(encoding='utf-8-sig')
  status=(CHANNEL/'installer/manager-status.ps1').read_text(encoding='utf-8-sig')
  self.assertIn("$form.FindName('PrepareMfg').IsEnabled=$false",manager)
  self.assertNotIn("$form.FindName('PrepareMfg').Add_Click({",manager)
  self.assertIn("$form.FindName('PrepareFsr').IsEnabled=$false",manager)
  self.assertNotIn("$form.FindName('PrepareFsr').Add_Click({",manager)
  self.assertIn("$form.FindName('SelectNativeFg').IsEnabled=$false",manager)
  self.assertIn("$record.Info.Components=@(GetComponentUpdateIds $m|Where-Object {$_ -ne 'Mfg'})",status)
  self.assertIn("'AddonMfgSelected'",manager[manager.index('$componentHandlers='):manager.index('foreach($name in $componentHandlers)')])
  self.assertIn("return 'OptiMfg'",manager[manager.index('function GetOptiMfgCardComponentId'):manager.index('function GetSelectedComponentIds')])
  self.assertIn('CopyOptiShadePackageInputs $root OptiMFG',package)
  self.assertIn("@('Effects','Neural','Cockpit','Providers','Atmosphere')|Where-Object",manager)
  self.assertIn('x:Name="AddonMfgSelected" Content="Install OptiMFG"',xaml)
  self.assertIn('retired MFG',package)
  self.assertNotIn("CopyOptiShadePackageInputs $root Mfg",package)
  self.assertNotIn("$sourceMfg.RuntimeGroup",package)

class LocalComponentPackageSetSource(unittest.TestCase):
 def test_existing_update_manager_can_select_and_stage_complete_schema2_sets(self):
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  status=(CHANNEL/'installer/manager-status.ps1').read_text(encoding='utf-8-sig')
  packages=(CHANNEL/'installer/component-packages.ps1').read_text(encoding='utf-8-sig')
  xaml=(CHANNEL/'installer/manager.xaml').read_text(encoding='utf-8-sig')
  self.assertIn('$picker.Multiselect=$true',manager)
  self.assertIn('TestLocalComponentPackageSetContract $candidates',manager)
  self.assertIn("'Stage package set'",manager)
  self.assertIn('GetLocalComponentPackageSetReadOnlyPlan $folders $Manifest',packages)
  self.assertIn('StageLocalComponentPackageSet $folders $m $plan $cacheRoot',packages)
  self.assertIn('TestLocalComponentPackageSelectionSet $Package',packages)
  self.assertIn('PackageSet=',status)
  self.assertIn('Select local package(s)',xaml)

class NativeMfgStaleOff(unittest.TestCase):
 def test_stale_provider_allows_only_a_local_off_draft(self):
  control=(CHANNEL/'shared/NativeMfgControl.h').read_text(encoding='utf-8-sig')
  state=(CHANNEL/'optiscaler/OptiScaler/menu/native_mfg_ui_state.h').read_text(encoding='utf-8-sig')
  panel=(CHANNEL/'optiscaler/OptiScaler/menu/optishade_mfg_ui.inl').read_text(encoding='utf-8-sig')
  self.assertIn('inline bool StageOffWhileWaiting(Draft& draft,const Snapshot& state)',state)
  self.assertIn('state.generation!=draft.generation||state.revision!=draft.revision',state)
  self.assertIn('draft.feedback="OFF staged. Save when fresh provider control returns."',state)
  self.assertNotIn('StageOffWhileWaiting',control)
  self.assertIn('const bool canStageOffWhileWaiting=',panel)
  self.assertIn('native_mfg_ui::StageOffWhileWaiting(nativePanel,s)',panel)
  self.assertIn('else if(!enabled)optishade::native_mfg_ui::StageOffWhileWaiting(nativePanel,s);',panel)
  self.assertIn('if(!NativeCanSave())',panel)

 def test_manager_literal_named_control_references_resolve(self):
  xaml=(CHANNEL/'installer/manager.xaml').read_text(encoding='utf-8-sig')
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  components=(CHANNEL/'installer/components.ps1').read_text(encoding='utf-8-sig')
  namespace='{http://schemas.microsoft.com/winfx/2006/xaml}Name'
  controls={node.attrib[namespace] for node in ET.fromstring(xaml).iter() if namespace in node.attrib}
  references=set(re.findall(r"\$form\.FindName\(\s*['\"]([^'\"]+)['\"]\s*\)",manager))
  self.assertTrue(references, 'manager source contains no literal main-window control references')
  missing=sorted(references-controls)
  self.assertEqual([],missing,f'manager.ps1 references controls missing from manager.xaml: {missing}')
  self.assertNotRegex(manager,r"\$form\.FindName\(\s*\$pair\[0\]\s*\)\.Add_Click")

 def test_page_heading_and_update_state_live_in_the_header(self):
  xaml=(CHANNEL/'installer/manager.xaml').read_text(encoding='utf-8-sig')
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  self.assertIn('x:Name="HeaderBuildType"',xaml)
  self.assertIn('x:Name="HeaderSubtitle"',xaml)
  self.assertIn("Home='Manage OptiShade across your games from one place.'",manager)
  self.assertIn("if($pageTitles.ContainsKey($name)){$form.FindName('HeaderBuildType').Text=$pageTitles[$name];$form.FindName('HeaderSubtitle').Text=$pageSubtitles[$name]}",manager)
  self.assertIn('x:Name="HeaderVersionLight"',xaml)
  self.assertLess(xaml.index('x:Name="HeaderVersion"'),xaml.index('x:Name="HeaderVersionLight"'))
  self.assertIn('<RowDefinition Height="132" />',xaml)
  self.assertIn('x:Name="HeaderVersion" TextWrapping="NoWrap"',xaml)
  self.assertIn('FontSize="14" x:Name="HeaderVersion"',xaml)
  self.assertIn('x:Name="HeaderVersionState"',xaml)
  self.assertIn('FontSize="14" Margin="7,0,0,0" VerticalAlignment="Center" TextWrapping="NoWrap"',xaml)
  self.assertIn('Margin="0,45,8,0"',xaml)
  self.assertIn('Margin="0,73,8,0"',xaml)
  self.assertIn('x:Name="HeaderComponentUpdateAvailable"',xaml)
  self.assertNotIn('HeaderGlassCockpitUpdateAvailable',xaml)
  self.assertIn('x:Name="HeaderVersionAction" Background="Transparent" BorderThickness="0" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,45,8,0"',xaml)
  self.assertIn('<Grid Grid.Row="1" Margin="0,10,0,8">',xaml)
  self.assertIn('<Grid x:Name="HomeContent" Margin="0,0,0,0">',xaml)
  self.assertNotIn('HomeSpacer',xaml)
  self.assertIn("'Current' {$light.Fill=[Windows.Media.BrushConverter]::new().ConvertFromString('#56D9A0')",manager)
  self.assertIn("'Available' {$light.Fill=[Windows.Media.BrushConverter]::new().ConvertFromString('#FF9E42')",manager)
  self.assertIn("$label.Visibility='Visible';$update.Content='OptiShade update available';$update.Visibility='Visible'",manager)
  self.assertIn("$form.FindName('HeaderUpdateAvailable').Add_Click({if($script:availableUpdate){StartManagerUpdate $script:availableUpdate}})",manager)
  self.assertIn('Update=$update;UpdateError=$updateError',manager)
 def test_failed_update_results_keep_attention_visible_without_pending_rows(self):
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  self.assertIn("[string]$script:updateResults[$_] -cne 'Complete'",manager)
  self.assertIn("$button.Visibility=if($componentCount -or $glassCount -or $failed -or $script:componentCheckWarning){'Visible'}else{'Collapsed'}",manager)
  self.assertIn("'No pending updates found. Earlier update attempts still need attention below.'",manager)
 def test_glass_cockpit_release_check_has_a_verified_install_action(self):
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  helper=(CHANNEL/'installer/glass-cockpit-update.ps1').read_text(encoding='utf-8-sig')
  components=(CHANNEL/'installer/components.ps1').read_text(encoding='utf-8-sig')
  xaml=(CHANNEL/'installer/manager.xaml').read_text(encoding='utf-8-sig')
  self.assertIn("https://api.github.com/repos/IFreemz/msfs2024-glass-cockpit-dlss-fix/releases?per_page=20",helper)
  self.assertIn('-TimeoutSec 8',helper)
  self.assertIn("$assetUri.Host -cne 'github.com'",helper)
  self.assertIn('function SaveGlassCockpitReleaseAsset',helper)
  self.assertIn('release-assets.githubusercontent.com',helper)
  self.assertIn("$actualHash -cne $identity.SHA256",helper)
  self.assertIn('function UpdateGlassCockpitAddon',components)
  self.assertIn("InvokeAddonTransaction $ManifestPath 'Cockpit'",components)
  self.assertIn("$null=UpdateGlassCockpitAddon $item.ManifestPath $script:glassCockpitLatestRelease $progress",manager)
  self.assertIn("$selected -contains $_ -and $_ -ne 'Cockpit'",manager)
  self.assertIn('NewOptiShadeManagerWorker',manager)
  lifetime=(CHANNEL/'installer/manager-lifetime.ps1').read_text(encoding='utf-8-sig')
  self.assertIn('[PowerShell]::Create()',lifetime)
  self.assertIn('RefreshHeaderComponentUpdateState',manager[manager.index('function RefreshHeaderGlassCockpitUpdateState'):manager.index('function StartGlassCockpitReleaseCheck')])
  self.assertIn("$form.FindName('HeaderComponentUpdateAvailable').Add_Click({ShowPage 'Updates'})",manager)
  self.assertIn("$form.FindName('AddonCockpitOpenRelease').Add_Click({ShowPage 'Updates'})",manager)
  self.assertIn("'AddonCockpitOpenRelease'",manager)
  self.assertIn('x:Name="AddonCockpitOpenRelease"',xaml)
  self.assertIn('Download and install developer update',xaml)
  self.assertNotIn('HeaderGlassCockpitUpdateAvailable',xaml)
 def test_page_navigation_avoids_rebuilding_all_game_cards(self):
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  home=manager[manager.index('function RefreshHomeState{'):manager.index('function RefreshLibrary(')]
  self.assertNotIn('ShowGames',home)
  self.assertNotIn('RefreshComponentsGameSelector',home)
  self.assertNotIn('RefreshAddonCards',home)
  self.assertIn('$script:pathRefreshTimer.Interval=[TimeSpan]::FromMilliseconds(160)',manager)
  self.assertIn("$form.FindName('HomeNav').Add_Click({ShowPage 'Home'})",manager)
  refresh=manager[manager.index('function RefreshLibrary('):manager.index('function SelectGame(')]
  # Batch completion must refresh every card, while ordinary navigation avoids it.
  self.assertIn('foreach($game in $items)',refresh)
  self.assertIn('GetCachedManagerGameStatus $game',refresh)
  self.assertIn('RequestManagerStatusScan -Force',refresh)
  self.assertNotIn('GetFusionInstallState',refresh)
  self.assertNotIn('ReadOptiShadeState',home)
  self.assertIn('[string]::Equals([string]$card.Folder,[string]$game.Folder,[StringComparison]::OrdinalIgnoreCase)',refresh)
  self.assertIn('UpdateLibraryGrid',refresh)
 def test_library_is_a_real_game_neutral_destination(self):
  xaml=(CHANNEL/'installer/manager.xaml').read_text(encoding='utf-8-sig')
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  library=(CHANNEL/'installer/library.ps1').read_text(encoding='utf-8-sig')
  self.assertIn('x:Name="LibraryNav"',xaml);self.assertIn('x:Name="LibraryPage"',xaml)
  self.assertIn("$form.FindName('LibraryNav').Add_Click({ShowPage 'Library'})",manager)
  self.assertIn("$form.FindName('HomeOpenLibrary').Add_Click({ShowPage 'Library'})",manager)
  self.assertIn("foreach($page in @('Home','Library','Setup'",manager)
  self.assertIn('steamapps/common/$dir',library);self.assertIn('Epic Games registrations',library)
  for root in ('GOG Games','EA Games','Origin Games','GOG Galaxy\\Games','Ubisoft Game Launcher\\games','Ubisoft Connect\\games','Program Files (x86)\\Battle.net\\Games'):
   self.assertIn(root,library)
  self.assertIn('Select-Object -First 200',library)
  self.assertIn('AssertFusionPhysicalFolder $storeRoot',library)
  self.assertIn('$name=if($knownTitle)',library);self.assertIn('if($knownTitle){$executable=@(FindFusionExecutable $folder $launcher)',library)
  self.assertIn('x:Name="ComponentsGame"',xaml)
  self.assertIn('x:Name="ComponentsTargetPath"',xaml)
  self.assertIn("$form.FindName('ComponentsGame').Add_SelectionChanged",manager)
  self.assertIn('RefreshComponentsGameSelector',manager)
  self.assertIn('$folder=& $getGameTargetFolderCommand $game',manager)
  self.assertIn("Install target: '+$target",manager)
  selector=manager[manager.index('function RefreshComponentsGameSelector{'):manager.index('function UpdateLibraryGrid{')]
  self.assertNotIn('if($script:gameRoot -and',selector)
  self.assertIn("$image=$form.FindName('BrandIcon').Source",manager)
  self.assertIn('RenderOptions.BitmapScalingMode="HighQuality"',xaml)
  self.assertIn('<TextBox x:Name="SnapshotParent" IsReadOnly="True"',xaml)
  self.assertIn('Snapshot location changed. The shared folder is ready; game folders are created when a snapshot is taken.',manager)
  self.assertIn('x:Name="SnapshotPathBorder"',xaml)
  self.assertIn('x:Name="ComponentsPage" VerticalScrollBarVisibility="Auto"',xaml)
  self.assertIn('<Setter Property="Width" Value="8" />',xaml)
  self.assertIn('Value="#8B70AF"',xaml);self.assertIn('Value="#B276FF"',xaml)
  start=manager.index('CompleteManualManagerInstall $script:manifest $manualPrevious')
  self.assertIn("ShowPage 'Components'",manager[start:start+500])
  self.assertIn('FormatOptiShadeAutoPreparation $prepared',manager)
  self.assertNotIn('x:Name="Browse"',xaml)
 def test_snapshot_startup_creates_only_the_shared_root(self):
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  module=(CHANNEL/'installer/snapshot-library.ps1').read_text(encoding='utf-8-sig')
  runtime=(CHANNEL/'reshade/source/runtime.cpp').read_text(encoding='utf-8-sig')
  menu=(CHANNEL/'optiscaler/OptiScaler/menu/menu_common.cpp').read_text(encoding='utf-8-sig')
  self.assertIn('EnsureOptiShadeSnapshotLibrary (GetOptiShadeSnapshotParent)',manager)
  self.assertIn("$pictures=[Environment]::GetFolderPath([Environment+SpecialFolder]::MyPictures)",module)
  self.assertIn("Join-Path $parentPath 'OptiShade Snapshots'",module)
  self.assertIn("[IO.File]::Open($probe,[IO.FileMode]::CreateNew",module)
  self.assertIn('SnapshotError=$snapshotError',manager)
  self.assertIn('create_directories(screenshot_path.parent_path(), ec)',runtime)
  self.assertIn('library_root(optishade::snapshot::utf8(saved.parent))',menu)
  self.assertNotIn('[IO.Directory]::CreateDirectory($gameFolder)',manager)
 def test_home_support_and_global_uninstall_actions_are_direct(self):
  xaml=(CHANNEL/'installer/manager.xaml').read_text(encoding='utf-8-sig')
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  self.assertIn('YOUR GAME, YOUR WAY',xaml)
  self.assertIn('x:Name="HomeGettingStarted"',xaml)
  self.assertIn('One setup flow for every game',xaml)
  self.assertIn('Your game library',xaml);self.assertIn('Manage OptiShade across your games',xaml)
  self.assertIn('x:Name="HomeCoffee"',xaml)
  home=xaml[xaml.index('<Grid x:Name="HomeContent"'):xaml.index('x:Name="LibraryPage"')]
  main_cards=home[:home.index('<Border Grid.Row="3"')]
  self.assertIn('x:Name="HomeDiscord"',main_cards)
  self.assertIn('x:Name="HomeCoffee"',main_cards)
  self.assertIn('MinHeight="58" x:Name="HomeDiscord"',main_cards)
  self.assertIn('Padding="12,12" MinHeight="58" ToolTip="Open Buy Me a Coffee"',main_cards)
  self.assertIn('x:Name="HomeUpdateStatusCard"',main_cards)
  self.assertIn('x:Name="HomeHardwareSummary"',main_cards)
  self.assertIn('x:Name="HomeStableUpdateState" Text="{Binding Text, ElementName=HeaderVersionState}"',main_cards)
  self.assertIn('x:Name="HomePatchNotes" Content="Open patch notes',main_cards)
  self.assertIn('Text="Future branch"',xaml)
  dashboard=re.search(r'<Grid Grid.Row="1"[^>]*>',main_cards)
  self.assertIsNotNone(dashboard,'Home dashboard grid is missing')
  self.assertNotIn('Grid.RowSpan',dashboard.group(0),'Home dashboard must not extend into the unused auto row')
  self.assertIn('<Grid Grid.Column="0"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>',main_cards,'Developer message must share the left column below Quick Actions rather than wait for the taller right-hand row')
  self.assertIn('<Grid Grid.Column="1"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>',main_cards,'Hardware and feature cards must retain their own aligned right-column layout')
  self.assertRegex(main_cards,r'<Border Grid.Row="1" VerticalAlignment="Stretch"[^>]*>.*?x:Name="HomeDeveloperMessage"', 'Developer message must stretch in the aligned lower dashboard row')
  self.assertNotIn('SidebarBetaStatus',xaml)
  self.assertNotIn("FindName('SidebarBetaStatus')",manager)
  self.assertNotIn('Text="BETA"',xaml)
  lower=home[home.index('x:Name="HomeDeveloperMessage"'):]
  self.assertIn('x:Name="HomeDeveloperMessage" Text="Welcome to the 1.0 public test!"',lower)
  self.assertIn('Text="NVIDIA"',lower);self.assertIn('Text="AMD"',lower)
  self.assertIn('Neural rendering  ·  IN TESTING',lower)
  self.assertIn('Some systems have issues with some games. Compatibility with your setup isn\'t confirmed yet.',lower)
  self.assertIn('export and share diagnostics.',lower)
  self.assertIn('Support target: RTX 20, 30, 40 and 50 series. NR is experimental and game/render-path dependent.',lower)
  self.assertIn('Optional FSR/XeSS support depends on the game and graphics API.',lower)
  self.assertIn('Neural rendering  ·  NOT SUPPORTED',lower)
  self.assertEqual(xaml.count('x:Name="HomeHardwareSummary"'),1)
  self.assertEqual(xaml.count('x:Name="HomeDiscord"'),1)
  self.assertEqual(xaml.count('x:Name="HomeCoffee"'),1)
  self.assertIn("$form.FindName('HomeCoffee').Add_Click({OpenBuyMeACoffee})",manager)
  self.assertIn("$form.FindName('HomeCheckUpdates').Add_Click",manager)
  self.assertIn("$form.FindName('HomePatchNotes').Add_Click({ShowReleaseNotes $form $store -Reopen})",manager)
  release=(CHANNEL/'installer/release-notes.ps1').read_text(encoding='utf-8-sig')
  self.assertIn('function ShowReleaseNotes($Owner,[string]$Store,[switch]$Reopen)',release)
  self.assertIn('function TestOptiShadeReleaseNotesDismissed([string]$Store,[string]$NotesKey,[switch]$Reopen)',release)
  self.assertIn('if(TestOptiShadeReleaseNotesDismissed $Store $notesKey -Reopen:$Reopen){return}',release)
  self.assertNotIn('Grid.Column="0" Grid.RowSpan="2"',xaml)
  self.assertIn(' OpenBuyMeACoffee\n if(Test-Path',manager)
  self.assertNotIn('ShowSupportDevelopment $form $store',manager)
  self.assertIn('Restores original files for every managed game.',xaml)
  self.assertIn('Uninstall OptiShade from all games',xaml)
 def test_components_batch_selection_and_restore_progress_are_wired(self):
  xaml=(CHANNEL/'installer/manager.xaml').read_text(encoding='utf-8-sig')
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  ownership=(CHANNEL/'installer/ownership.ps1').read_text(encoding='utf-8-sig')
  for item in ('AddonEffectsSelected','AddonNeuralSelected','AddonMfgSelected','AddonCockpitSelected','AddonProvidersSelected','ComponentsApply','ComponentsInstallAll','ComponentsUninstallSelected','AddonEffectsUninstall','AddonNeuralUninstall','AddonMfgUninstall','AddonCockpitUninstall','AddonProvidersUninstall'):
   self.assertIn(f'x:Name="{item}"',xaml)
  for item in ('AddonEffectsInstall','AddonEffectsRemove','AddonNeuralInstall','AddonNeuralRemove','AddonMfgInstall','AddonMfgRemove','AddonCockpitInstall','AddonCockpitRemove','AddonProvidersInstall','AddonProvidersRemove'):
   self.assertNotIn(f'x:Name="{item}"',xaml)
  self.assertIn('function InvokeComponentSelection{',manager)
  self.assertIn('function ConfirmAndUninstallComponents([string[]]$Ids)',manager)
  self.assertIn("$selector.Content=if($on){'Select to uninstall'}elseif($isOptiMfg){'Install OptiMFG'}else{'Select to install'}",manager)
  self.assertIn("$blockedProvider=('Providers' -in $selectedForRemoval -and 'Mfg' -in $current -and 'Mfg' -notin $selectedForRemoval)",manager)
  self.assertIn("RemoveOptiShadeAddon $mp $id",manager)
  self.assertIn("'Uninstalling selected components'",manager)
  self.assertIn("$form.FindName('ComponentsApply').Add_Click",manager)
  self.assertIn("$form.FindName('ComponentsInstallAll').Add_Click",manager)
  self.assertIn("RestoreFusion $m -KeepPresets ([bool]$script:restoreKeepPresets) -Progress $progress",manager)
  self.assertIn("-Progress $progress",manager[manager.index("RemoveSelectedOptiShadeData $store"):manager.index("$form.FindName('Retry')")])
  self.assertIn('[scriptblock]$Progress=',ownership[ownership.index('function RestoreFusion'):ownership.index('function FindNrRuntime')])
  self.assertIn('[scriptblock]$Progress=',ownership[ownership.index('function UninstallFusion'):ownership.index('function GetSnapshotRemovalPlan')])
  self.assertIn("'Restoring original game files'",manager);self.assertIn("'Uninstalling OptiShade'",manager)
 def test_game_library_uses_one_continuous_scrollable_grid(self):
  xaml=(CHANNEL/'installer/manager.xaml').read_text(encoding='utf-8-sig')
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  self.assertIn('<UniformGrid Columns="3" />',xaml)
  self.assertIn('x:Name="LibraryPageStatus"',xaml)
  self.assertIn('x:Name="LibraryPage" VerticalScrollBarVisibility="Auto"',xaml)
  self.assertIn("$form.FindName('LibraryGames').ItemsSource=$all",manager)
  self.assertIn('function UpdateLibraryGrid',manager)
  for item in ('LibraryPager','LibraryPrevious','LibraryNext','$pageSize=6'):
   self.assertNotIn(item,xaml+manager)
 def test_library_status_store_and_preferences_are_detected_automatically(self):
  xaml=(CHANNEL/'installer/manager.xaml').read_text(encoding='utf-8-sig')
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  self.assertLess(xaml.index('x:Name="LibraryPageStatus"'),xaml.index('x:Name="LibraryGames"'))
  self.assertIn('x:Name="LibraryInstalledFirst"',xaml);self.assertIn('x:Name="LibraryFavoritesOnly"',xaml)
  self.assertIn('Binding FavoriteGlyph',xaml);self.assertIn('Binding StoreDisplay',xaml)
  self.assertIn('public string State {get;set;}',manager)
  self.assertIn('$card.State=$game.State',manager)
  self.assertIn('function GetDetectedStoreDisplay',manager)
  self.assertIn("$form.FindName('DetectedStore').Text=if($selected){GetDetectedStoreDisplay $selected}",manager)
  self.assertNotIn('x:Name="EditionSteam"',xaml);self.assertNotIn('x:Name="EditionXbox"',xaml)
 def test_game_triggered_controller_is_not_a_logon_service(self):
  launch=(CHANNEL/'optiscaler/shared/OptiMfgComponent.h').read_text(encoding='utf-8-sig')
  present=(CHANNEL/'optiscaler/OptiScaler/wrapped/wrapped_swapchain.cpp').read_text(encoding='utf-8-sig')
  self.assertIn('StartControllerOnPresent()',present)
  self.assertIn('attempted.exchange(true)',launch)
  self.assertIn('--game-pid ',launch);self.assertIn('--game-birth ',launch)
  self.assertIn('start-with-game.disabled',launch)
  self.assertIn('FreeLibraryAndExitThread',launch)
  self.assertNotIn('ShellExecute',launch)
 def test_nr_page_does_not_request_removed_preparation_script(self):
  panel=(CHANNEL/'optiscaler/OptiScaler/menu/OptiShadePanel.inl').read_text(encoding='utf-8-sig')
  common=(CHANNEL/'optiscaler/OptiScaler/menu/menu_common.cpp').read_text(encoding='utf-8-sig')
  self.assertNotIn('OptiShadeNeuralDependencies::Poll',panel)
  self.assertNotIn('#include "optishade_neural_dependencies.inl"',common)
  self.assertIn('DlssNr::RenderMenu',panel)
 def test_optimfg_automatic_start_has_no_card_toggle_or_play_launch(self):
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  xaml=(CHANNEL/'installer/manager.xaml').read_text(encoding='utf-8-sig')
  self.assertNotIn('AddonMfgAutoStart',manager);self.assertNotIn('AddonMfgAutoStart',xaml)
  self.assertNotIn('OptiMfgAutoStartOnPlay',manager)
  self.assertIn("$form.FindName('AddonMfgStart').Add_Click",manager)
 def test_startup_splash_waits_for_initialization(self):
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  self.assertNotIn("if($elapsed -ge 10){$form.FindName('Intro').Visibility='Collapsed'}",manager)
  self.assertNotIn('$elapsed -ge 6',manager)
  self.assertIn("RestoreStartupCache;$form.FindName('Intro').Visibility='Visible'",manager)
  self.assertIn('ApplyStartupGameResults $copies',manager)
  self.assertIn('Game scan failed; showing saved entries. Open Library and select Scan for games to retry.',manager)
  self.assertIn('Game scan failed. Open Library and select Scan for games to retry.',manager)
  self.assertIn('RegisterOptiShadeManagerTimer $script:startupTimer {\n if($script:busy){return}',manager)
  self.assertIn('RequestManagerStatusScan -Force',manager)
  self.assertIn("if($script:startupFailed){CompleteManagerStartup}",manager)
  self.assertIn("function CompleteManagerStartup",manager)
  self.assertIn('StopOptiShadeManagerLifetime',manager)
  self.assertIn('function RestoreStartupCache',manager)
  self.assertIn('ShowGames $cachedGames -SkipUpdateCheck',manager)
  for stage in ('Loading your saved setup...','Scanning libraries...','Checking hardware...','Checking for OptiShade updates...','Opening the main app...'):
   self.assertIn("$progress.Stage='"+stage+"'",manager)
 def test_recovery_tools_use_themed_popups_and_safe_direct_actions(self):
  xaml=(CHANNEL/'installer/manager.xaml').read_text(encoding='utf-8-sig')
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  popup=manager[manager.index('function NewManagerPopup'):manager.index("$form.FindName('OpenTroubleshooter').Add_Click")]
  self.assertIn('[Windows.SizeToContent]::Manual',popup)
  self.assertIn('Height=[double][Math]::Min(500,$maxHeight)',popup)
  self.assertIn('$picker.Style=$form.FindResource([Windows.Controls.ComboBox])',popup)
  self.assertIn('function ShowManagerPopup',popup)
  # Popup callbacks are GetNewClosure() blocks; they reach manager functions
  # through captured commands (see closure-scope.test.ps1).
  self.assertIn("& $manager.Commands.RunAction {& $manager.Commands.InvokeRepairInstall} 'Repairing OptiShade'",popup)
  self.assertIn("& $manager.Commands.RunAction {& $manager.Commands.InvokeRestoreInstall} 'Restoring original game files'",popup)
  self.assertIn("& $manager.SetScript 'restoreKeepPresets'",popup)
  self.assertNotIn("RaiseEvent([Windows.RoutedEventArgs]::new('confirm'))",popup)
  self.assertIn('x:Name="ComponentsPage" VerticalScrollBarVisibility="Auto"',xaml)
 def test_generic_diagnostics_are_saved_under_app_data(self):
  ui=(CHANNEL/'installer/Troubleshooter/src/UI.xaml').read_text(encoding='utf-8-sig')
  shell=(CHANNEL/'installer/Troubleshooter/src/Shell.cs').read_text(encoding='utf-8-sig')
  collector=(CHANNEL/'installer/Troubleshooter/src/Collector.cs').read_text(encoding='utf-8-sig')
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  location=(CHANNEL/'installer/Troubleshooter/src/DiagnosticsLocation.cs').read_text(encoding='utf-8-sig')
  self.assertIn('Name="GameChoices"',ui)
  self.assertIn('Name="ContinueGame"',ui)
  self.assertIn('Game executable (*.exe)',shell)
  self.assertIn('RefreshGameChoices();',shell)
  self.assertIn('SelectSimulator(Path.GetFileName(choice.Executable),choice.Label,choice.Folder,choice.Executable)',shell)
  self.assertIn('The last launched game is not selected automatically.',shell)
  self.assertNotIn('var identity=SafeIdentity(selectedGame)',shell)
  self.assertNotIn("$mode=if($Quick){'--quick-collect'}else{'--game'}",manager)
  self.assertIn('Start-Process -FilePath $tool -WindowStyle Normal',manager)
  self.assertIn('Executable=selectedExecutablePath',shell)
  self.assertIn('ManifestExecutable',collector)
  self.assertIn('OPTISHADE_DIAGNOSTICS_DIR',location)
  self.assertIn('DiagnosticsLocation.Root',shell)
  self.assertIn('GameFileToken(String.IsNullOrWhiteSpace(exePath)?"OptiShade-Launcher.exe":exe)',collector)
  self.assertIn('"OptiShade-Tester-")+gameToken',collector)
  self.assertIn('Window.Loaded+=(s,e)=>Window.Dispatcher.BeginInvoke',shell)
  self.assertIn('Window.Topmost=true',shell)
  self.assertNotIn('RunAction {OpenDiagnosticTool',manager)
  self.assertNotIn('your Desktop',shell)
 def test_manager_loads_auto_preparation_guard_module(self):
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  auto=(CHANNEL/'installer/auto-compatibility.ps1').read_text(encoding='utf-8-sig')
  load='. "$PSScriptRoot/auto-compatibility.ps1"'
  self.assertIn('function AssertOptiShadeAutoPreparationCurrent(',auto)
  self.assertIn('$assertCurrentCommand=(Get-Command AssertOptiShadeAutoPreparationCurrent -CommandType Function).ScriptBlock',auto)
  self.assertNotRegex(auto,r'(?<![&\w])AssertOptiShadeAutoPreparationCurrent\s+\$ManifestPath\s+\$guard')
  self.assertIn('$current=& $assertCurrentCommand $ManifestPath $guard',auto)
  self.assertIn(load,manager)
  self.assertLess(manager.index(load),manager.index('function StartManagerAutoSession'))
 def test_generic_mfg_gate_points_to_live_provider_capture(self):
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  components=(CHANNEL/'installer/components.ps1').read_text(encoding='utf-8-sig')
  provider_policy=(CHANNEL/'installer/provider-policy.ps1').read_text(encoding='utf-8-sig')
  self.assertIn('RecordOptiShadeDeferredMfgSelection',components)
  self.assertIn("Requested='deferred'",(CHANNEL/'installer/mfg.ps1').read_text(encoding='utf-8-sig'))
  self.assertIn('activation requires a compatible live DLSS Frame Generation provider',provider_policy)
  self.assertIn('game/provider compatibility limitation, not an OptiShade installation failure.',provider_policy)
  self.assertIn('If you expected the game to support MFG, or are unsure',provider_policy)
  self.assertIn('send diagnostics to the Discord channel',provider_policy)
  self.assertIn('TestOptiShadeMfgPreparationGame $Manifest $GpuNames',provider_policy)
  self.assertIn('TestOptiShadeMfgInstallTarget',provider_policy)
  self.assertIn('Ready to install • compatibility checked in-game',manager)
  self.assertIn('switch($route)',manager)
  self.assertNotIn('then run Check compatibility',components)
 def test_launcher_log_export_is_one_click_local_and_includes_compatibility_evidence(self):
  xaml=(CHANNEL/'installer/manager.xaml').read_text(encoding='utf-8-sig')
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  self.assertIn('x:Name="ExportLauncherLogs"',xaml)
  self.assertEqual(xaml.count('x:Name="ExportLauncherLogs"'),1)
  self.assertLess(xaml.index('x:Name="OpenTroubleshooter"'),xaml.index('x:Name="ExportLauncherLogs"'))
  self.assertLess(xaml.index('x:Name="ExportLauncherLogs"'),xaml.index('x:Name="ResetDownloadCache"'))
  self.assertIn("$form.FindName('ExportLauncherLogs').Add_Click({",manager)
  self.assertIn('OpenDiagnosticTool -LauncherOnly',manager)
  self.assertIn("-ArgumentList '--launcher-only'",manager)
  collector=(CHANNEL/'installer/Troubleshooter/src/Collector.cs').read_text(encoding='utf-8-sig')
  for launcher_log in ('Installer.log','Manager-error.txt','Update-error.txt'):
   self.assertIn('File="'+launcher_log+'"',collector)
  self.assertIn('if(r.IncludeLauncherLogs)LauncherLogs();',collector)
  self.assertIn('OptiShadeData/Compatibility.json',collector)
  self.assertIn('Unified launcher diagnostics could not be opened:',manager)
  self.assertIn('rendering executable is not recorded; renderer/API and PE hash unknown', (CHANNEL/'installer/executable.ps1').read_text(encoding='utf-8-sig'))
  components=(CHANNEL/'installer/components.ps1').read_text(encoding='utf-8-sig')
  self.assertIn('Neural component preparation allowed; runtime API admission remains separate',components)
  auto=(CHANNEL/'installer/auto-compatibility.ps1').read_text(encoding='utf-8-sig')
  self.assertIn('$nrUnsupportedReason=',auto)
  self.assertIn("$nrUnsupportedReason='Static executable imports: '+$nrApiEvidence",auto)
 def test_nr_binding_pool_grows_instead_of_skipping_frames(self):
  header=(CHANNEL/'optiscaler/OptiScaler/shaders/dlssnr/DlssNr_Dx12.h').read_text(encoding='utf-8-sig')
  dx12=(CHANNEL/'optiscaler/OptiScaler/shaders/dlssnr/DlssNr_Dx12.cpp').read_text(encoding='utf-8-sig')
  verdicts=(CHANNEL/'installer/Troubleshooter/src/Verdicts.cs').read_text(encoding='utf-8-sig')
  self.assertIn('#define DLSSNR_MAX_HEAPS 256',header)
  self.assertIn('FrameDescriptorHeap _frameHeaps[DLSSNR_MAX_HEAPS];',header)
  self.assertIn('_init = GrowHeaps(DLSSNR_NUM_OF_HEAPS);',dx12)
  self.assertIn('while(found<count&&_heapCount<DLSSNR_MAX_HEAPS){',dx12)
  # Reuse still requires the game's real reset of the recording command list.
  self.assertIn('if(!_bindingLeases[i]||_bindingLeases[i]->Ready())_reservedSlots[found++]=i;',dx12)
  self.assertIn('bool Ready()const{return Registry().Retired(command.Get(),generation);}',(CHANNEL/'shared/NrGpuLifetime.h').read_text(encoding='utf-8-sig'))
  self.assertNotIn('DLSSNR_NUM_OF_HEAPS;++i',dx12)
  self.assertIn('NR binding pool is full',dx12)
  self.assertIn('{"NR FLICKER",308}',verdicts)
 def test_effects_depth_selection_is_kept_steady(self):
  depth=(CHANNEL/'reshade/examples/09-depth/generic_depth_addon.cpp').read_text(encoding='utf-8-sig')
  verdicts=(CHANNEL/'installer/Troubleshooter/src/Verdicts.cs').read_text(encoding='utf-8-sig')
  present=depth.split('static void on_present(',1)[1].split('device_data->frame_index++;',1)[0]
  # Small slices of drawing carry to the next present (bounded), instead of being discarded.
  self.assertLess(present.index('queue_state.merge(*queue->get_private_data<state_tracking>());'),present.index('reset_on_present()'))
  self.assertIn('if (++device_data->presents_without_activity > 8)',present)
  select=depth.split('static void on_begin_render_effects(',1)[1].split('static void on_finish_render_effects(',1)[0]
  # The current depth-stencil is kept while recently used; switching needs consecutive wins.
  self.assertIn('current->second.last_used_in_frame + keep_frames >= device_data->frame_index',select)
  self.assertIn('selected_depth_stencil == data.switch_candidate && ++data.switch_wins >= switch_after',select)
  # The sticky choice is made before the miss warning, the override and the bind.
  self.assertLess(select.index('constexpr uint32_t switch_after = 8;'),select.index('no depth candidate was selected'))
  self.assertLess(select.index('constexpr uint32_t switch_after = 8;'),select.index('if (data.override_depth_stencil != 0)'))
  self.assertIn('OptiShade depth selection: kept=%llu switched=%llu lost=%llu',select)
  # The queue list on_present walks is only changed under its lock, and a queue is
  # unlisted before its state is freed (R314: freeze leaving a flight).
  init=depth.split('static void on_init_command_queue(',1)[1].split('static void on_destroy_command_queue(',1)[0]
  self.assertLess(init.index('const std::unique_lock<std::shared_mutex> lock(s_mutex);'),init.index('device_data->queues.push_back(cmd_queue);'))
  destroy=depth.split('static void on_destroy_command_queue(',1)[1].split('static void on_init_effect_runtime(',1)[0]
  self.assertLess(destroy.index('const std::unique_lock<std::shared_mutex> lock(s_mutex);'),destroy.index('device_data->queues.erase('))
  self.assertLess(destroy.index('device_data->queues.erase('),destroy.index('cmd_queue->destroy_private_data<state_tracking>();'))
  self.assertIn('lines.AddRange(EffectsDepth(',verdicts)
  self.assertIn('{"IMAGE EFFECTS DEPTH FLICKER",313}',verdicts)
 def test_memory_guard_never_stops_running_nr_and_spaces_retries(self):
  dx12=(CHANNEL/'optiscaler/OptiScaler/shaders/dlssnr/DlssNr_Dx12.cpp').read_text(encoding='utf-8-sig')
  guard=(CHANNEL/'optiscaler/OptiScaler/dlssnr/NrMemoryGuard.h').read_text(encoding='utf-8-sig')
  panel=(CHANNEL/'optiscaler/OptiScaler/dlssnr/DlssNrPanel.inl').read_text(encoding='utf-8-sig')
  verdicts=(CHANNEL/'installer/Troubleshooter/src/Verdicts.cs').read_text(encoding='utf-8-sig')
  self.assertIn('#include <dlssnr/NrMemoryGuard.h>',dx12)
  # Only a new allocation can be refused, and only when the user opted in;
  # by default NR is built anyway and the panel warns.
  self.assertIn('const bool admitted=!allocationNeeded||guard::Admits(memory.Budget,memory.CurrentUsage,required);',dx12)
  self.assertIn('if(!admitted&&cfg.DlssNrPauseOnLowMemory.value_or_default()){',dx12)
  self.assertIn('NR starts anyway because Pause NR when video memory is low is off',dx12)
  self.assertNotIn('g_memoryPressureOverride',dx12)
  config=(CHANNEL/'optiscaler/OptiScaler/Config.h').read_text(encoding='utf-8-sig')
  self.assertIn('CustomOptional<bool> DlssNrPauseOnLowMemory { false };',config)
  self.assertIn('ini.SetValue("DlssNr", "PauseOnLowMemory"',(CHANNEL/'optiscaler/OptiScaler/Config.cpp').read_text(encoding='utf-8-sig'))
  self.assertIn('Bind("Pause On Low Memory", &Config::DlssNrPauseOnLowMemory);',(CHANNEL/'optiscaler/OptiScaler/dlssnr/NrSettingsDraft.h').read_text(encoding='utf-8-sig'))
  self.assertNotIn(':64ull*1024*1024;',dx12)
  self.assertIn('NR keeps running, the game may stutter',dx12)
  # Rebuilds are credited with the models they replace.
  self.assertIn('guard::RequiredFree(reserve,rebuild?guard::ModelReserve(g_nr.workWidth,g_nr.workHeight,currentPasses):0)',dx12)
  # Retries wait for the refused requirement and back off.
  self.assertIn('memoryState.recovery.Refused(required);',dx12)
  self.assertIn('optishade::nr::memory_guard::Recovery recovery;',dx12)
  self.assertIn('kWaitsMs[3] = {3000, 10000, 30000}',guard)
  self.assertIn('return std::max(required_, kMinimumHeadroom);',guard)
  # Beside the NR switch: the warning, the saved opt-in pause, and Restart NR.
  self.assertIn('if(enabled&&DlssNr::MemoryPressureStopped()){',panel)
  self.assertIn('}else if(enabled&&DlssNr::MemoryLow()){',panel)
  self.assertIn('DlssNr::RetryAfterFailure();',panel)
  self.assertIn('ImGui::Checkbox("Pause NR when video memory is low",&pauseOnLowMemory)',panel)
  self.assertNotIn('MemoryPressureOverride',panel)
  self.assertIn('NR LOW VIDEO MEMORY',verdicts)
  self.assertIn('{"NR MEMORY ON/OFF LOOP",312}',verdicts)
  # The verified legacy worker hashes Beta/shared; NR-only policy stays out of it.
  self.assertFalse((CHANNEL/'shared/NrMemoryGuard.h').exists())
  self.assertTrue((Path(__file__).resolve().parent/'nr_memory_guard_tests.cpp').exists())
 def test_streamline_hook_reports_lookups_and_skips_denied_threads(self):
  hooks=(CHANNEL/'optiscaler/OptiScaler/hooks/Streamline_Hooks.cpp').read_text(encoding='utf-8-sig')
  enlist=(CHANNEL/'optiscaler/OptiScaler/hooks/ProcessDetourTransaction.h').read_text(encoding='utf-8-sig')
  # Only the interposer transaction skips threads Windows will not open.
  self.assertIn('std::vector<DWORD>* deniedThreads=nullptr',enlist)
  self.assertIn('if (error == ERROR_ACCESS_DENIED && deniedThreads)',enlist)
  self.assertIn('EnlistCurrentProcessThreads(threadHandles,&deniedThreads)',hooks)
  self.assertEqual(enlist.count('EnlistCurrentProcessThreads(threadHandles)'),1)
  self.assertIn("Failed to hook sl.interposer v2: {:X} at stage '{}'",hooks)
  self.assertIn('Streamline hooks: externalFG={} observer={} nativeTaaObserver={}',hooks)
  self.assertIn('Streamline feature lookup: feature={} function={} handling={}',hooks)
  self.assertIn('native, not observed (OptiMFG controls DLSS-G)',hooks)
  self.assertIn('Streamline PCL markers observed: first marker={} frame={}',hooks)
 def test_dialogs_hide_the_progress_window_and_dx11_offers_the_nr_bridge(self):
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  progress=(CHANNEL/'installer/operation-progress.ps1').read_text(encoding='utf-8-sig')
  panel=(CHANNEL/'optiscaler/OptiScaler/dlssnr/DlssNrPanel.inl').read_text(encoding='utf-8-sig')
  # A dialog during an operation hides the progress window (Choose Neural GPU hid behind it).
  self.assertIn("Status='AwaitingConsent'",manager)
  self.assertIn('$chosen=InvokeWithOperationProgressHidden {$dialog.ShowDialog()}',manager)
  self.assertIn('try{[void](InvokeWithOperationProgressHidden {$Popup.Window.ShowDialog()})}',manager)
  self.assertIn("if($state.Status -eq 'AwaitingConsent'){$window.Hide()}",progress)
  # Cancel stays readable once pressed.
  self.assertIn("$button.Content='Cancelling...';$button.Opacity=0.7",progress)
  self.assertNotIn("$button.Content='Cancelling...';$button.IsEnabled=$false",progress)
  # DirectX 11: NR needs the D3D12 bridge; the panel offers the switch.
  self.assertIn('dynamic_cast<IFeature_Dx11*>(active)&&!dynamic_cast<IFeature_Dx11wDx12*>(active)',panel)
  self.assertIn('State::Instance().newBackend=Upscaler::DLSS_on12;',panel)
  # These sit inside the appearance card, below the page title, not above it.
  look=panel[panel.index('auto look=[&]{'):panel.index('optishade::panel::Appearance(')]
  self.assertIn('nrAlerts();',look)
  before=panel[panel.index('optishade::panel::DrawNr(')-400:panel.index('optishade::panel::DrawNr(')]
  self.assertNotIn('Pause NR when video memory is low',before)
 def test_colour_strength_is_shown_with_the_nr_look(self):
  panel=(CHANNEL/'optiscaler/OptiScaler/dlssnr/DlssNrPanel.inl').read_text(encoding='utf-8-sig')
  strength=(CHANNEL/'optiscaler/OptiScaler/dlssnr/reconstruction/NRStrength.inl').read_text(encoding='utf-8-sig')
  self.assertIn('ImGui::SliderFloat("Colour strength", &colour, 0.0f, 4.0f, "%.2f")',strength)
  self.assertIn('ImGui::SliderFloat("Detail strength", &transfer, 0.0f, 2.0f, "%.2f")',strength)
  # Exactly once, in the always-visible appearance card, not a collapsed header.
  self.assertEqual(panel.count('#include "reconstruction/NRStrength.inl"'),1)
  look=panel[panel.index('auto look=[&]{'):panel.index('auto qualityControls=[&]{')]
  self.assertIn('#include "reconstruction/NRStrength.inl"',look)
  self.assertNotIn('Per-pass and output-strength tuning',panel)
 def test_parked_model_only_waits_for_lists_that_could_record_it(self):
  dx12=(CHANNEL/'optiscaler/OptiScaler/shaders/dlssnr/DlssNr_Dx12.cpp').read_text(encoding='utf-8-sig')
  verdicts=(CHANNEL/'installer/Troubleshooter/src/Verdicts.cs').read_text(encoding='utf-8-sig')
  # Every model creation remembers the lists already submitted before it existed.
  self.assertEqual(dx12.count('NoteNrModelBirth(0);\n        g_nr.feature ='),1)
  self.assertEqual(dx12.count('NoteNrModelBirth(pass);\n                g_nr.passFeature[pass] = g_nr.create('),1)
  self.assertIn('if (state == Wait::InFlight || state == Wait::FinishedNotReset)',dx12)
  # Parking drops exactly those lists; everything else still holds the model.
  park=dx12[dx12.index('void ParkNrFeature('):dx12.index('void NoteNrModelBirth(')]
  self.assertIn('r.uses=optishade::nr_lifetime::Active().items;',park)
  self.assertIn('std::erase_if(r.uses,',park)
  self.assertIn('return std::any_of(closed.begin(), closed.end(), [&](const auto& c) { return c.lock() == use; });',park)
  # The parked-model limit and real retirement are unchanged.
  self.assertIn('constexpr size_t MaxDeferredModels = 6;',dx12)
  self.assertIn('{"NR PARKED-MODEL LIMIT",315}',verdicts)
 def test_taa_nr_pauses_while_external_frame_generation_is_generating(self):
  taa=(CHANNEL/'optiscaler/OptiScaler/shaders/dlssnr/DlssNr_Taa.inl').read_text(encoding='utf-8-sig')
  dx12=(CHANNEL/'optiscaler/OptiScaler/shaders/dlssnr/DlssNr_Dx12.cpp').read_text(encoding='utf-8-sig')
  status=(CHANNEL/'optiscaler/OptiScaler/dlssnr/ExternalFgStatus.h').read_text(encoding='utf-8-sig')
  verdicts=(CHANNEL/'installer/Troubleshooter/src/Verdicts.cs').read_text(encoding='utf-8-sig')
  self.assertIn('#include <dlssnr/ExternalFgStatus.h>',dx12)
  # The gate follows the native-contract block and precedes any late submission.
  gate=taa.index('optishade::external_fg_status::Session().Generating(&externalMultiplier)')
  self.assertLess(taa.index('optishade::taa::BlocksLateComposition(managedFg,nativeFgSignature,validatedNativeContract)'),gate)
  self.assertLess(gate,taa.index('if (!input->providerReady || !input->queue'))
  self.assertIn('!input->projection && !managedFg && !validatedNativeContract &&',taa)
  # Only this process's fresh status counts, and FG must be producing frames.
  for check in ('statusPid != pid','statusBirth != birth','now - heartbeat > kMaxHeartbeatAgeSeconds','if (applied < 2) return Generation::None;','presented < 2 ? Generation::Paused : Generation::Generating','flag("gameFrameGenerationOn")'):
   self.assertIn(check,status)
  self.assertIn('lines.AddRange(NeuralOnGeneratedFrames(',verdicts)
  self.assertIn('{"NR RAN ON GENERATED FRAMES",311}',verdicts)
  self.assertTrue((Path(__file__).resolve().parent/'external_fg_status_tests.cpp').exists())
 def test_taa_nr_runs_before_frame_generation_under_optimfg(self):
  root=CHANNEL/'optiscaler/OptiScaler'
  policy=(root/'dlssnr/TaaPreFgObserver.h').read_text(encoding='utf-8-sig')
  dx12=(root/'shaders/dlssnr/DlssNr_Dx12.cpp').read_text(encoding='utf-8-sig')
  native=(root/'shaders/dlssnr/DlssNr_TaaNativeFg.inl').read_text(encoding='utf-8-sig')
  taa=(root/'shaders/dlssnr/DlssNr_Taa.inl').read_text(encoding='utf-8-sig')
  hooks=(root/'hooks/Streamline_Hooks.cpp').read_text(encoding='utf-8-sig')
  d3d12=(root/'hooks/D3D12_Hooks.cpp').read_text(encoding='utf-8-sig')
  cfg=(root/'Config.h').read_text(encoding='utf-8-sig')
  # Final builds observe tags for MSFS when OptiMFG or the game keeps DLSS-G
  # options native; beta builds keep their existing observer.
  self.assertIn('return betaObserver || (enabled && msfs && unobservedFg && routeObserver);',policy)
  self.assertIn('const bool nativeTaaObserver=DlssNr::TaaPreFgObserver();',hooks)
  self.assertIn('NativeStateCapture(DlssNr::TaaPreFgObserver(),',d3d12)
  self.assertIn('optishade::taa::MsfsExecutable(exe), state.optiMfgExternalController,',dx12)
  self.assertIn('CustomOptional<bool> DlssNrTaaWithFrameGeneration { true };',cfg)
  # The backend status file stands in for the unobserved SetOptions signature,
  # refreshed before every reader of it on the TAA routes.
  self.assertIn('state.dlssgTemporalSignature.store(optishade::taa::StatusSignature(generating, applied), std::memory_order_relaxed);',dx12)
  self.assertLess(taa.index('RefreshUnobservedFgSignature();'),taa.index('const auto nativeFgSignature=fgState.dlssgTemporalSignature.load'))
  before=native.index('void TaaFgBeforeTags(ID3D12GraphicsCommandList* cmd')
  self.assertLess(native.index('RefreshUnobservedFgSignature();',before),native.index('NativeCompositionAllowed',before))
  prepare=native.index('bool TaaFgPrepare(uint32_t marker')
  self.assertLess(native.index('RefreshUnobservedFgSignature();',prepare),native.index('NativeCompositionAllowed',prepare))
  # DLSS NR owns the device: no per-frame producer pins or volatile tag copies.
  self.assertLess(native.index("if(DlssRouteOwnsDevice()){PreFgGate(",before),native.index('auto* f=Find(frame,view,true);',before))
  # Unvalidated frames still fall back to the R311 pause, never to late NR on generated frames.
  self.assertIn('!input->projection && !managedFg && !validatedNativeContract &&',taa)
  self.assertTrue((Path(__file__).resolve().parent/'taa_pre_fg_observer_tests.cpp').exists())
 def test_nr_rebuilds_only_after_a_new_frame_size_settles(self):
  dx12=(CHANNEL/'optiscaler/OptiScaler/shaders/dlssnr/DlssNr_Dx12.cpp').read_text(encoding='utf-8-sig')
  # One odd-sized frame (OSD-NB9Q, OSD-DDB5) must not park the running model.
  gate=dx12.index('constexpr unsigned kExtentSettleFrames = 3;')
  self.assertLess(gate,dx12.index('const bool allocationNeeded=missingPasses||resolutionChanged'))
  self.assertIn('if (g_nr.feature != nullptr && resolutionChanged && !g_nr.resizeRebuildPending)',dx12)
  self.assertIn('if (tuningState.settleFrames < kExtentSettleFrames)',dx12)
  # OSD-5H4E: a transient odd size skips one frame and keeps the running model's history.
  self.assertIn('LOG_INFO("DLSS-NR odd frame size {}x{} (model {}x{}) skipped; running model kept"',dx12)
  self.assertNotIn('g_nr.reset = true; // the next frame NR does run starts its history afresh',dx12)
 def test_defaulted_ini_still_writes_the_diagnostics_log(self):
  cfg=(CHANNEL/'optiscaler/OptiScaler/Config.h').read_text(encoding='utf-8-sig')
  # OSD-2TBF: an ini reset to "auto" must not silence Performance.log.
  self.assertIn('CustomOptional<bool> LogToFile { true };',cfg)
  self.assertIn('CustomOptional<int> LogLevel { 2 };',cfg)
  self.assertIn('CustomOptional<std::wstring> LogFileName { L"OptiShadeData/Performance.log" };',cfg)
 def test_troubleshooter_reports_memory_pauses_and_lost_logs_not_user_off_stalls(self):
  verdicts=(CHANNEL/'installer/Troubleshooter/src/Verdicts.cs').read_text(encoding='utf-8-sig')
  # A saved stall whose reason is the user's Off is not a stuck rebuild.
  self.assertIn('if(!switchedOff&&String.Equals(Field(session,"NRStallState"),"Blocked"',verdicts)
  self.assertIn('NR NOT COMPLETING FRAMES (saved session)',verdicts)
  self.assertIn('lines.AddRange(NeuralMemoryPause(',verdicts)
  self.assertIn('DLSS-NR stopped: Paused: (?:GPU memory pressure|video memory is almost full)',verdicts)
  self.assertIn('lines.AddRange(HelperLogOverwrite(',verdicts)
  self.assertIn('{"RUNTIME LOG OVERWRITTEN",309}',verdicts)
  installer=(CHANNEL/'installer/ownership.ps1').read_text(encoding='utf-8-sig')
  assert_closed=installer.split('function AssertClosed(',1)[1].split('\nfunction ',1)[0]
  # The OptiMFG tray controller runs from a subfolder and holds its runtime DLLs.
  self.assertIn("$folder.StartsWith($root.TrimEnd('\\')+'\\',[StringComparison]::OrdinalIgnoreCase)",assert_closed)
  self.assertIn("'OptiMFG_Live','PresentMon'",assert_closed)
  # Loading-screen blips (DLSS idle, fps unmeasured) are not dropouts.
  self.assertIn('e.EndTick-e.StartTick>=5000||(e.FpsBefore>0&&e.FpsMin>0&&',verdicts)
  self.assertIn('if(offsets.Count==0&&!performanceLogs.Any())return result;',verdicts)
 def test_mfg_dropouts_ignore_background_focus_and_self_healed_retries(self):
  verdicts=(CHANNEL/'installer/Troubleshooter/src/Verdicts.cs').read_text(encoding='utf-8-sig')
  self.assertIn('bool focused=foreground<=0||pid<=0||foreground==pid;',verdicts)
  self.assertIn('MFG PAUSED IN BACKGROUND',verdicts)
  self.assertIn('unrecovered=real.Count(e=>!e.Recovered&&!e.LostFocus);',verdicts)
  self.assertIn('var chosen=lastLive??last;',verdicts)
  self.assertIn('Mfg(SessionControllers(items)',verdicts)
  self.assertIn('processBirth',verdicts)
  self.assertIn('NR was switched off for this whole session',verdicts)
  self.assertIn('; retry [1-3]',verdicts)
 def test_nr_releases_models_after_it_is_switched_off(self):
  nr=(CHANNEL/'optiscaler/OptiScaler/shaders/dlssnr/DlssNr_Dx12.cpp').read_text(encoding='utf-8-sig')
  # Off used to keep every model for the session; VR holds one per eye plus the mirror.
  self.assertIn('constexpr ULONGLONG kNrOffReleaseGraceMs = 20000;',nr)
  # Parked models beyond the usual 6 only while video memory has clear headroom.
  self.assertIn('constexpr size_t MaxDeferredModelsWithHeadroom = 24;',nr)
  self.assertIn('deferredModels < parkingLimit)',nr)
  self.assertNotIn('deferredModels < MaxDeferredModels)',nr)
  hooks=(CHANNEL/'optiscaler/OptiScaler/hooks/Streamline_Hooks.cpp').read_text(encoding='utf-8-sig')
  # Record an early version.dll snapshot without claiming a later load never occurred.
  self.assertIn('static void LogOptiMfgBackendModule()',hooks)
  self.assertIn('OptiMFG backend check: version.dll in game folder={}',hooks)
  self.assertIn('a later load is not ruled out',hooks)
  trouble=(CHANNEL/'installer/Troubleshooter/src/Verdicts.cs').read_text(encoding='utf-8-sig')
  self.assertIn('MFG BACKEND SNAPSHOT',trouble)
  self.assertIn('does not prove the proxy failed to load later',trouble)
  help_text=(CHANNEL/'installer/Troubleshooter/src/SelfHelp.cs').read_text(encoding='utf-8-sig')
  self.assertIn('Keep other version.dll files in place',help_text)
  # NR game-thread cost is judged on windows of at least 20 frames (not model builds).
  self.assertIn('if(latestFrames>=20&&(latestAvg>=2.0||gpuBound))',trouble)
  dlss=(CHANNEL/'optiscaler/OptiScaler/inputs/NVNGX_DLSS_Dx12.cpp').read_text(encoding='utf-8-sig')
  # The missing-input pop-up only after 2 s of continuous skips; each skip is still logged.
  self.assertIn('if (!streak.second && now - streak.first >= 2000)',dlss)
  self.assertNotIn('"DLSS skipped this frame because the game did not provide a required input."',dlss)
  self.assertIn('void ReleaseWhileSwitchedOff()',nr)
  off=nr[nr.index('ReportSkipOnce("it is switched off");'):][:120]
  self.assertIn('ReleaseWhileSwitchedOff();',off)
  # Released through the exact-retirement path, never freed directly.
  body=nr[nr.index('void ReleaseWhileSwitchedOff()'):nr.index('void Barrier(ID3D12GraphicsCommandList* cmdList')]
  self.assertIn('ParkModelsAndSurfaces();',body)
  self.assertIn('ParkNrResource(*r);',body)
  self.assertNotIn('->Release()',body)
  self.assertIn('TickNrRetired();',body)
  # The TAA route (VR desktop mirror) never reaches EvaluateInternal while off.
  taa=nr[nr.index('extern "C" __declspec(dllexport) bool OptiShadeTaaRequested()\n{'):][:600]
  self.assertIn('ForEachOutput([]{ReleaseWhileSwitchedOff();})',taa)
  self.assertIn('OutputOwned<NrEngineState,1>().switchedOffAt=0;',nr)
 def test_vr_headset_nr_setting_and_desktop_mirror_skip(self):
  base=CHANNEL/'optiscaler/OptiScaler'
  nr=(base/'shaders/dlssnr/DlssNr_Dx12.cpp').read_text(encoding='utf-8-sig')
  cfg=(base/'Config.h').read_text(encoding='utf-8-sig')
  cfgcpp=(base/'Config.cpp').read_text(encoding='utf-8-sig')
  draft=(base/'dlssnr/NrSettingsDraft.h').read_text(encoding='utf-8-sig')
  panel=(base/'dlssnr/DlssNrPanel.inl').read_text(encoding='utf-8-sig')
  runtime=(CHANNEL/'reshade/source/runtime.cpp').read_text(encoding='utf-8-sig')
  xr=(CHANNEL/'reshade/source/openxr/openxr_hooks_swapchain.cpp').read_text(encoding='utf-8-sig')
  # Saved setting, on by default, in the review draft and the panel.
  self.assertIn('CustomOptional<bool> DlssNrInVrHeadset { true };',cfg)
  self.assertIn('readBool("DlssNr", "InVrHeadset")',cfgcpp)
  self.assertIn('ini.SetValue("DlssNr", "InVrHeadset"',cfgcpp)
  self.assertIn('Bind("NR In VR Headset", &Config::DlssNrInVrHeadset);',draft)
  self.assertIn('ImGui::Checkbox("Use NR in the VR headset",&inHeadset)',panel)
  # Headset heartbeat from ReShade's OpenXR layer, timed out after 1.5 s.
  self.assertIn('extern "C" __declspec(dllexport) void OptiShadeXrFrame(uint32_t version)',nr)
  self.assertIn('return at && GetTickCount64() - at < 1500;',nr)
  self.assertIn('reshade::vr_frame_presented();',xr)
  self.assertIn('GetProcAddress(module,"OptiShadeXrFrame")',runtime)
  # The desktop mirror gets neither NR nor guides in VR, and releases its model.
  submit=nr[nr.index('extern "C" __declspec(dllexport) void OptiShadeTaaSubmit(const ostaa::Frame* frame)\n{'):]
  self.assertLess(submit.index('if(!frame->projection&&HeadsetPresenting()){'),submit.index('DlssNr::Taa::Instance().Submit(frame'))
  self.assertIn('if (HeadsetPresenting()) return false;  // flat runtime = desktop mirror in VR',nr)
  # Setting off: eyes are treated as switched off and release their memory.
  off=nr[nr.index('if (NrOffInHeadset())'):][:200]
  self.assertIn('ReleaseWhileSwitchedOff();',off)
  self.assertIn('if(offHere)return false;',nr)
  # Headset eyes use their own, lower model resolution (default 65%).
  self.assertIn('CustomOptional<float> DlssNrVrWorkingScale { 0.65f };',cfg)
  self.assertIn('readFloat("DlssNr", "VrWorkingScale")',cfgcpp)
  self.assertIn('Bind("VR Working Scale", &Config::DlssNrVrWorkingScale);',draft)
  self.assertIn('headsetEye ? std::min(cfg.DlssNrVrWorkingScale.value_or_default(), 1.0f)',nr)
  self.assertIn('ImGui::SliderInt("VR model resolution",&vrPercent,25,100,"%d%%")',panel)
  self.assertIn('DLSS-NR headset eye: model resolution {}%, {}',nr)
  # Foveated NR: settings, the window passed to downsample/resolve and the guide crop.
  self.assertIn('CustomOptional<bool> DlssNrVrFoveated { true };',cfg)
  self.assertIn('CustomOptional<float> DlssNrVrFoveaSize { 0.70f };',cfg)
  self.assertIn('CustomOptional<float> DlssNrVrFoveaFeather { 0.25f };',cfg)
  self.assertIn('readBool("DlssNr", "VrFoveated")',cfgcpp)
  self.assertIn('ImGui::SliderInt("Foveated area",&fovea,30,100,"%d%%")',panel)
  self.assertIn('ImGui::SliderInt("Foveated edge softness",&feather,2,100,"%d%%")',panel)
  self.assertIn('evalDepthX = depthBaseX + part(fovX, guideWidth, width);',nr)
  self.assertIn('down.Foveate = 1;',nr)
  self.assertIn('resolveParams.Foveate = 1;',nr)
  common=(base/'shaders/dlssnr/DlssNr_Common.h').read_text(encoding='utf-8-sig')
  hlsl=(base/'shaders/dlssnr/precompile/dlssnr.hlsl').read_text(encoding='utf-8-sig')
  # Appended after the residual fields in C++, after four placeholders in the shader.
  self.assertLess(common.index('uint32_t ResidualMotionBaseY;'),common.index('uint32_t Foveate;'))
  self.assertLess(hlsl.index('uint  gResidualMotionBaseYUnused;'),hlsl.index('uint  gFoveate;'))
  self.assertIn('if (gFoveate == 0 && srcW == gWidth && srcH == gHeight)',hlsl)
  self.assertIn('result = lerp(originalSample.rgb, result, foveaWeight);',hlsl)
  runner=(CHANNEL.parent/'tests/reconstruction/run_tests.py').read_text(encoding='utf-8')
  self.assertIn("build('nr-foveated-shader-gpu'",runner)
 def test_troubleshooter_sends_reports_privately_through_the_relay(self):
  root=CHANNEL/'installer/Troubleshooter'
  upload=(root/'src/ReportUpload.cs').read_text(encoding='utf-8-sig')
  shell=(root/'src/Shell.cs').read_text(encoding='utf-8-sig')
  ui=(root/'src/UI.xaml').read_text(encoding='utf-8-sig')
  collector=(root/'src/Collector.cs').read_text(encoding='utf-8-sig')
  build=(root/'build.ps1').read_text(encoding='utf-8-sig')
  relay=(CHANNEL/'diagnostics-relay/src/worker.js').read_text(encoding='utf-8')
  wrangler=(CHANNEL/'diagnostics-relay/wrangler.jsonc').read_text(encoding='utf-8')
  # The EXE talks only to the relay over HTTPS and holds no storage credential.
  self.assertIn('https://optishade-diagnostics.optishadedev.workers.dev',upload)
  self.assertNotIn('github.com',upload)
  self.assertNotRegex(upload+relay+wrangler,r'gh[po]_|github_pat_')
  self.assertNotIn('ServerCertificateValidationCallback',upload)
  self.assertNotIn('GITHUB_TOKEN',wrangler.split('// GITHUB_TOKEN stays a dashboard secret')[1].split('"vars"')[1])
  self.assertIn('"invocation_logs": false',wrangler)
  # Bounded part reads, resume state, cancellation and server-confirmed completion.
  self.assertIn('PartSize=50000000',upload)
  self.assertIn('class PartStream',upload)
  self.assertIn('StatePath(zip)',upload)
  self.assertIn('/complete',upload)
  self.assertIn('token.ThrowIfCancellationRequested()',upload)
  self.assertIn(r'src\ReportUpload.cs',build)
  self.assertIn('/r:System.Net.Http.dll',build)
  # Nothing leaves the PC until the tester confirms; the ZIP is kept.
  # One step: styled confirmation, collect into the hidden pending store,
  # send, delete; only the report ID is left. No Discord size profiles.
  self.assertIn('Window BuildConfirm(bool includeGame)',shell)
  self.assertNotIn('MessageBox.Show',shell)
  self.assertIn('No copy is kept on this PC once it is sent.',shell)
  self.assertIn('PendingReports.Discard(Path.GetDirectoryName(zip))',shell)
  self.assertIn('FullEvidence=true',shell)
  self.assertIn('Copy report ID',shell)
  self.assertIn('Name="SendReport" Content="Send unsent report"',ui)
  self.assertIn('Collect and send report',ui)
  self.assertNotIn('Discord upload size',ui)
  self.assertNotIn('OpenFolder',ui+shell)
  self.assertIn('class PendingReports',upload)
  self.assertIn('Only ever delete inside the pending store.',upload)
  self.assertIn('Sent privately to the OptiShade developer; no copy is kept on this PC',collector)
  # Full evidence: whole logs and raw dumps for the private upload profile.
  self.assertIn('FullMainLogBytes=192*1024*1024',collector)
  # Raw originals: byte-for-byte copies with a hashed manifest, event logs,
  # dxdiag, legacy NR worker dumps, Streamline logs, WER folders.
  self.assertIn('void RawEvidence(string temporary)',collector)
  self.assertIn('raw/RAW-MANIFEST.txt',collector)
  self.assertIn('wevtutil.exe',collector)
  # dxdiag probes every display output; with a full-screen game it corrupted one tester's display.
  self.assertNotIn('dxdiag.exe',collector)
  # Old logs are sent but kept out of the findings; old launcher entries are skipped.
  self.assertIn('items[items.Count-1].Historical=true;',collector)
  self.assertIn('items.Where(i=>i.Text!=null&&!i.Historical)',collector)
  self.assertIn('Verdicts.Since=DateTime.UtcNow.AddHours(-r.Hours);',collector)
  verdicts=(root/'src/Verdicts.cs').read_text(encoding='utf-8-sig')
  self.assertIn('public static DateTime? Since;',verdicts)
  self.assertIn('atUtc<Since.Value)continue;',verdicts)
  self.assertIn('dlss5-feed.*\.dmp',collector)
  self.assertIn('"NVIDIA","Streamline",stem',collector)
  self.assertIn('MaxSentReportBytes = 2000000000',collector)
  # Crash dumps: opt-in per game via WER LocalDumps, one elevation prompt,
  # only OptiShade-made keys removed, status recorded in every report.
  dumps=(root/'src/CrashDumps.cs').read_text(encoding='utf-8-sig')
  self.assertIn('Windows Error Reporting\LocalDumps',dumps)
  self.assertIn('Verb="runas"',dumps)
  self.assertIn('OptiShadeManaged',dumps)
  self.assertIn('"\\"DumpFolder\\"=hex(2):"',dumps)
  self.assertIn('"System32","reg.exe"',dumps)
  self.assertNotIn('-EncodedCommand "+',dumps)
  self.assertIn('NativeErrorCode==1223',dumps)
  self.assertIn('Name="CrashDumpToggle"',ui)
  self.assertIn('Windows crash dumps (WER LocalDumps): ',collector)
  self.assertIn(r'src\CrashDumps.cs',build)
  self.assertIn('r.FullEvidence?900L*1024*1024:128L*1024*1024',collector)
  # Relay: scoped expiring passes, no list/download routes, digest-verified completion.
  self.assertIn('upload_pass_expired',relay)
  self.assertIn('manifest.reportId !== reportId',relay)
  self.assertIn('FixedLengthStream',relay)
  self.assertIn('parts_unverifiable',relay)
  self.assertIn('INDEX_PATH = "INDEX.md"',relay)
  self.assertIn('index = "failed"',relay)
  self.assertIn("What happened (tester's words)",relay)
  self.assertIn('MAX_DESCRIPTION = 4000',relay)
  abuse=(CHANNEL/'diagnostics-relay/src/abuse.js').read_text(encoding='utf-8')
  self.assertIn('perHour: 3',abuse)
  self.assertIn('env.SENDER_SALT',abuse)
  self.assertIn('blocked-senders.txt',abuse)
  self.assertIn('sender_blocked',relay)
  self.assertIn('BURST_LIMITER',wrangler)
  self.assertNotIn('cf-connecting-ip',relay)
  self.assertIn('upload.Send(zip,cancel.Token,notes,game)',shell)
  self.assertIn('{"description",description??""}',upload)
  self.assertNotRegex(relay,r'releases/assets/\$\{[^}]+\}`, \{ expect: \[200')
 def test_self_help_explains_causes_without_sending_a_report(self):
  root=CHANNEL/'installer/Troubleshooter'
  shell=(root/'src/Shell.cs').read_text(encoding='utf-8-sig')
  collector=(root/'src/Collector.cs').read_text(encoding='utf-8-sig')
  verdicts=(root/'src/Verdicts.cs').read_text(encoding='utf-8-sig')
  ui=(root/'src/UI.xaml').read_text(encoding='utf-8-sig')
  build=(root/'build.ps1').read_text(encoding='utf-8-sig')
  # Check my setup: same rules, nothing packed or sent, player advice shown.
  self.assertIn('Name="CheckSetup"',ui)
  self.assertIn(r'src\SelfHelp.cs',build)
  check=collector[collector.index('public List<Finding> Check()'):collector.index('public Result Run()')]
  self.assertNotIn('Pack(',check)
  self.assertNotIn('LiveHang(',check)
  self.assertNotIn('RawEvidence(',check)
  self.assertIn('SelfHelp.Build(findings)',shell)
  self.assertIn('Defender();GameExecutable();',check)
  self.assertIn('Defender(); GameExecutable();',collector)
  self.assertIn('lines.AddRange(DefenderBlocks(',verdicts)
  self.assertIn('lines.AddRange(WrongGameExecutable(',verdicts)
  # In game: the waiting reason and flicker suspects come from runtime facts.
  panel=(CHANNEL/'optiscaler/OptiScaler/dlssnr/DlssNrPanel.inl').read_text(encoding='utf-8-sig')
  self.assertIn('optishade::selfhelp::NrWaiting(facts)',panel)
  self.assertNotIn('Enter the scene with a compatible input path',panel)
  self.assertIn('DlssNr::FlickerSuspects()',panel)
  self.assertIn('bool TaaRouteSeen() {',(CHANNEL/'optiscaler/OptiScaler/shaders/dlssnr/DlssNr_Taa.inl').read_text(encoding='utf-8-sig'))
 def test_reports_of_31_october_fixes_stay_in_place(self):
  project=CHANNEL/'optiscaler/OptiScaler'
  # OSD-C8R4: one menu context stays on its window while that window presents.
  overlay=(project/'menu/menu_overlay_dx.cpp').read_text(encoding='utf-8-sig')
  bind=overlay.index('else if (bound && IsWindow(bound) && now - boundPresentAt < 2000 && area(bound) >= area(hWnd)) return;')
  self.assertLess(bind,overlay.index('// Process window handle changed, update base'))
  # OSD-Q54M: an ini reset to auto still loads the ReShade OptiShade ships.
  self.assertIn('CustomOptional<bool> LoadReShade { true };',(project/'Config.h').read_text(encoding='utf-8-sig'))
  # OSD-22P4: the check that keeps TAA NR from running before FG is logged.
  native=(project/'shaders/dlssnr/DlssNr_TaaNativeFg.inl').read_text(encoding='utf-8-sig')
  self.assertIn('LOG_INFO("TAA pre-FG gate: {}; signature=',native)
  self.assertIn('if(gate==last||changes>=64)return;',native)
  verdicts=(CHANNEL/'installer/Troubleshooter/src/Verdicts.cs').read_text(encoding='utf-8-sig')
  self.assertIn('lines.AddRange(EffectsNotLoaded(',verdicts)
  self.assertIn('TAA pre-FG gate: (.+?); signature=',verdicts)
 def test_reports_of_1_november_fixes_stay_in_place(self):
  project=CHANNEL/'optiscaler/OptiScaler'
  # OSD-3NCN/6NCE/RF5J/ETTD: pre-FG hooks stay out of the game's calls until TAA NR has run.
  native=(project/'shaders/dlssnr/DlssNr_TaaNativeFg.inl').read_text(encoding='utf-8-sig')
  for entry in ('void TaaFgNewFrameToken(uint32_t f){if(!TaaPreFgUsed())return;',
                'void TaaFgPresentReturned(uint32_t f){if(!TaaPreFgUsed())return;',
                'void TaaFgBeforePresent(IDXGISwapChain* s,ID3D12CommandQueue* q){if(!TaaPreFgUsed())return;',
                'if(HeadsetPresenting()||!TaaPreFgUsed()||!OptiShadeTaaRequested())return false;'):
   self.assertIn(entry,native)
  # Binding and release keep the swapchain lifetime correct before first use.
  self.assertNotIn('void TaaFgReleaseOutput(IDXGISwapChain* s){if(!TaaPreFgUsed())',native)
  self.assertIn('g_taaRouteUsed.store(true, std::memory_order_relaxed);',(project/'shaders/dlssnr/DlssNr_Taa.inl').read_text(encoding='utf-8-sig'))
  # OSD-6K6T/22P4: the tag hooks infer D3D12 when slInit was not hooked; the warning is logged once.
  hooks=(project/'hooks/Streamline_Hooks.cpp').read_text(encoding='utf-8-sig')
  self.assertEqual(hooks.count('const auto api = EffectiveRenderApi(renderApi);'),2)
  # OSD-AFZJ: the pre-FG prepare, provider Present and inputs-consumed paths use
  # the same inference; none still require slInit's API directly.
  self.assertIn('return api == sl::RenderAPI::eCount && State::Instance().swapchainApi == DX12 ? sl::RenderAPI::eD3D12 : api;',hooks)
  self.assertNotIn('renderApi!=sl::RenderAPI::eD3D12',hooks)
  self.assertNotIn('renderApi==sl::RenderAPI::eD3D12',hooks)
  self.assertEqual(hooks.count('EffectiveRenderApi(renderApi)'),5)
  self.assertNotIn('        LOG_WARN("Incomplete Streamline hooks");',hooks)
  # OSD-EFVE: no NVIDIA spoofing on a non-NVIDIA GPU while fakenvapi is off.
  main=(project/'dllmain.cpp').read_text(encoding='utf-8-sig')
  self.assertLess(main.index('CheckQuirks(possibleNvidia);'),main.index('if (!possibleNvidia && State::Instance().externalFrameGeneration &&'))
 def test_game_memory_is_sampled_for_crash_reports(self):
  # "Any memory leaks with OptiShade?" could not be answered from a report: sample once a minute.
  sample=(CHANNEL/'optiscaler/OptiScaler/dlssnr/MemorySample.h').read_text(encoding='utf-8-sig')
  self.assertIn('constexpr ULONGLONG kSampleIntervalMs = 60000;',sample)
  self.assertIn('LOG_INFO("Memory sample: pid={} tick={} privateMB={}',sample)
  swap=(CHANNEL/'optiscaler/OptiScaler/wrapped/wrapped_swapchain.cpp').read_text(encoding='utf-8-sig')
  self.assertIn('if(!(Flags & DXGI_PRESENT_TEST))optishade::memory::SampleOnPresent();',swap)
  verdicts=(CHANNEL/'installer/Troubleshooter/src/Verdicts.cs').read_text(encoding='utf-8-sig')
  self.assertIn('lines.AddRange(MemoryTrend(',verdicts)
 def test_optimfg_reports_go_through_the_troubleshooter(self):
  # OptiMFG no longer writes its own ZIP; it opens the Troubleshooter for its game.
  program=(CHANNEL/'installer/Troubleshooter/src/Program.cs').read_text(encoding='utf-8-sig')
  shell=(CHANNEL/'installer/Troubleshooter/src/Shell.cs').read_text(encoding='utf-8-sig')
  self.assertIn('if(args.Length>=2 && args[0]=="--game")ui.OpenGame(args[1],Array.IndexOf(args,"--mfg")>1);',program)
  self.assertIn('if(includeMfg)Find<CheckBox>("IncludeMfgLogs").IsChecked=true;',shell)
  # OSD-N94F: the pre-FG wait says which frame-constants condition failed.
  native=(CHANNEL/'optiscaler/OptiScaler/shaders/dlssnr/DlssNr_TaaNativeFg.inl').read_text(encoding='utf-8-sig')
  self.assertIn('Waiting: the game sent frame constants for more than one viewport on the same frame.',native)
  self.assertIn('LOG_INFO("TAA pre-FG constants: frame={} viewport={} seen={}"',native)
 def test_crash_dumps_are_on_by_default_after_install(self):
  # Players with crashes to desktop never turned dumps on; the manager now asks once after install.
  ownership=(CHANNEL/'installer/ownership.ps1').read_text(encoding='utf-8-sig')
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  dumps=(CHANNEL/'installer/Troubleshooter/src/CrashDumps.cs').read_text(encoding='utf-8-sig')
  self.assertIn("try{WriteInstallerLog ('Crash dumps: '+(EnableOptiShadeCrashDumps $Executable))}catch{",ownership)
  self.assertLess(manager.index('Core install verified: executable='),manager.index(' EnsureOptiShadeCrashDumps $exe'))
  # Same values and marker as the Troubleshooter, so it can still turn them off.
  self.assertIn('CustomFlags=0x1|0x4|0x20|0x40|0x100|0x800|0x1000;',dumps)
  self.assertEqual(0x1|0x4|0x20|0x40|0x100|0x800|0x1000,6501)
  self.assertIn("'\"CustomDumpFlags\"=dword:00001965'",ownership)
  self.assertIn('\"OptiShadeManaged\"=dword:00000001',ownership)
  # Windows' reg.exe, not an elevated hidden -EncodedCommand PowerShell (antivirus pattern).
  self.assertIn(r"$reg=Join-Path $env:WINDIR 'System32\reg.exe'",ownership)
  self.assertNotIn("'-EncodedCommand',$encoded",ownership)
  self.assertIn("if(Test-Path -LiteralPath $key){return ('already on for '+$exe)}",ownership)
 def test_manager_explains_protected_game_folders(self):
  # DCS World under F:\Program Files: install and restore failed with "access denied"
  # and a restore message that named MSFS. Explain the protected folder instead.
  ownership=(CHANNEL/'installer/ownership.ps1').read_text(encoding='utf-8-sig')
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  self.assertIn('function GetOptiShadeFriendlyError($ErrorRecord){',ownership)
  self.assertIn('choose Run as administrator',ownership)
  self.assertIn('$status.Text=GetOptiShadeFriendlyError $_;',manager)
  # OSD-AZH3: the update path gives the same help as install.
  self.assertIn('$failure=GetOptiShadeFriendlyError $_;$retried=$false',manager)
  self.assertNotIn('Close MSFS and any log viewers',ownership)
 def test_atmosphere_mod_is_installed_by_its_own_installer_outside_the_receipt(self):
  # Owner agreement with the author (2 Nov 2026): the unchanged release zip, run
  # with its own installer; its files are never added to OptiShade's receipt.
  module=(CHANNEL/'installer/atmosphere-mod.ps1').read_text(encoding='utf-8')
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  policy=(CHANNEL/'installer/component-policy.ps1').read_text(encoding='utf-8')
  # OptiShade performs the install itself; only the shader patch runs the author's scripts.
  self.assertIn("InvokeAtmosphereModPython $Parts @((Join-Path $Parts.Installer 'extract_pak.py'),'--pak',$Pack,'--out',(Join-Path $work 'extracted')) $Pump",module)
  self.assertIn('patch_dxil.patch_all(root=Path(sys.argv[2]), dxc=Path(sys.argv[3]), strict=False)',module)
  self.assertIn("Copy-Item -LiteralPath $parts.Addon -Destination (Join-Path $Game $script:AtmosphereModAddon) -Force",module)
  self.assertIn("Copy-Item -LiteralPath $Source -Destination $target -Recurse",module)
  self.assertIn("@('InjectRootSignature','1'),@('InjectGraphicsRootSignature','1')",module)
  self.assertNotIn('install.py',module.split('$script:AtmosphereModDxcVersion')[1])
  self.assertIn("does not match GitHub''s SHA-256 for the release",module)
  self.assertIn('api.github.com/repos/tomwhoca/AtmosphereMod/releases/latest',module)
  self.assertIn('. "$PSScriptRoot/atmosphere-mod.ps1"',manager)
  self.assertIn('RefreshAtmosphereModCard $ready',manager)
  # Same tick box, bulk install and uninstall flow as the other cards.
  self.assertIn("'AddonProvidersSelected','AddonAtmosphereSelected')",manager)
  self.assertIn("elseif($id -eq 'Atmosphere'){",manager)
  self.assertIn("if($id -eq 'Atmosphere'){$null=UninstallAtmosphereMod",manager)
  self.assertNotIn('AtmosphereMod',policy)
  self.assertNotIn('.zip',(CHANNEL/'installer/public_bundle.go').read_text(encoding='utf-8'))
 def test_taa_pre_fg_names_every_stop_and_optimfg_crashes_are_collected(self):
  # OSD-HAV3: tags observed, prepare running, but no frame was ever assembled
  # and nothing said why. Each silent exit now names itself.
  native=(PROJECT/'shaders/dlssnr/DlssNr_TaaNativeFg.inl').read_text(encoding='utf-8-sig')
  self.assertIn("Native FG tags arrived while the bound swapchain is not the game's primary presentation window.",native)
  self.assertIn('Native FG frame assembly refused a new frame for these tags.',native)
  self.assertIn('Native FG could not snapshot the volatile {} input (DXGI format {}, flags {:X}, HRESULT {:08X}).',native)
  self.assertIn('if(!f){if(!lastFindFailure.empty())Say(lastFindFailure.c_str(),view);return;}',native)
  # OSD-3RRK: tagged frames that never reached presentation were never retired
  # and filled the route's 24 assembly slots; each new tag retires older ones.
  find=native[native.index('Frame* Find(uint32_t frame,uint32_t view,bool create){'):]
  find=find[:find.index('Native FG input slots are still owned')]
  self.assertIn('for(auto& f:frames)if(f&&!f->sealed&&f->id.owner==id.owner&&f->id.view==view&&static_cast<int32_t>(frame-f->id.frame)>0)f->retired=true;',find)
  self.assertLess(find.index('f->retired=true;'),find.index('Collect();'))
  # OSD-TZR9: OptiMFG's own crashes reach the report and are named.
  collector=(CHANNEL/'installer/Troubleshooter/src/Collector.cs').read_text(encoding='utf-8-sig')
  verdicts=(CHANNEL/'installer/Troubleshooter/src/Verdicts.cs').read_text(encoding='utf-8-sig')
  self.assertIn('r.IncludeMfgLogs && msg.IndexOf("OptiMFG_Live.exe",StringComparison.OrdinalIgnoreCase)>=0',collector)
  self.assertIn('OPTIMFG CRASHED: Windows recorded ',verdicts)
  # OSD-3A5R: a sim still closing in the background is named as such.
  ownership=(CHANNEL/'installer/ownership.ps1').read_text(encoding='utf-8-sig')
  self.assertIn('is still running in the background with no window: it may still be closing.',ownership)
 def test_atmosphere_bridge_lookup_and_latest_glass_cockpit_on_install(self):
  # A [string] parameter turns an omitted $null into '': the Community lookup
  # must test for empty, or the EFB sim bridge is never installed.
  module=(CHANNEL/'installer/atmosphere-mod.ps1').read_text(encoding='utf-8-sig')
  self.assertIn('if([string]::IsNullOrEmpty($Community)){$Community=GetAtmosphereModCommunityFolder $Game}',module)
  self.assertNotIn('if($null -eq $Community)',module)
  # Installing the Glass Cockpit card takes the latest verified developer release.
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  self.assertIn("if($id -eq 'Cockpit'){InstallLatestGlassCockpitRelease $mp}",manager)
  self.assertIn('$null=UpdateGlassCockpitAddon $ManifestPath $release $progress',manager)
  # No re-patch step for the player: the card finishes the install itself.
  self.assertNotIn('AddonAtmosphereRepatch',manager)
  self.assertNotIn('AddonAtmosphereRepatch',(CHANNEL/'installer/manager.xaml').read_text(encoding='utf-8-sig'))
  self.assertIn('if($state.NeedsRepatch -or -not $state.SectionPresent -or $missingBridge){',manager)
  self.assertIn('StartAtmosphereModAutoRepair $path.Text',manager)
  self.assertNotIn('}.GetNewClosure())\n}\n$form.FindName(\'ComponentsUpdateAll\')',manager)
 def test_atmosphere_finish_runs_only_the_missing_step(self):
  # The card finishes an existing install with the least work, and the patch
  # driver survives 0.6.0's spawn worker pool (the automatic finish hung).
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  module=(CHANNEL/'installer/atmosphere-mod.ps1').read_text(encoding='utf-8-sig')
  self.assertIn('$state=RepairAtmosphereMod $Game {',manager)
  self.assertIn('$missingBridge=(-not $state.Community) -and $state.CommunityAvailable',manager)
  self.assertIn("if __name__ == '__main__':",module)
  self.assertIn('StopAtmosphereModProcessTree $p.Id',module)
  self.assertIn('[IO.Directory]::Delete($Target,$false)',module)
 def test_manager_window_errors_are_logged_not_fatal(self):
  # A callback error used to end the manager ("could not open: exit status 1",
  # nothing logged); UserCfg.opt held open by the sim must not raise.
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  module=(CHANNEL/'installer/atmosphere-mod.ps1').read_text(encoding='utf-8-sig')
  guard=manager.index('$form.Dispatcher.Add_UnhandledException(')
  self.assertLess(guard,manager.rindex('[void]$form.ShowDialog()'))
  self.assertIn('$e.Handled=$true',manager[guard:])
  self.assertIn('[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete',module)
 def test_reshade_keeps_atmosphere_mod_loaded_across_probe_devices(self):
  # Unloading AtmosphereMod at a probe device's teardown left its SimConnect
  # weather thread pointing into freed code: CTD at startup (OSD-FBPW).
  source=(ROOT/'Beta/reshade/source/addon_manager.cpp').read_text(encoding='utf-8')
  unload=source[source.index('void reshade::unload_addons()'):]
  self.assertIn('info.file == "AtmosphereMod.addon64"',unload)
  self.assertIn('s_retained_atmosphere_addon = info.handle',unload)
  self.assertIn('info.handle == s_retained_glass_addon || info.handle == s_retained_atmosphere_addon',source)
 def test_taa_routes_hold_through_dynamic_fg_pauses(self):
  # Dynamic DLSS-G presented single frames about once a second with FG on, and
  # both TAA routes flipped with it (OSD-XGNZ flicker). One reader decides for
  # both; a pause is held, FG off or a stale status is not.
  status=(CHANNEL/'optiscaler/OptiScaler/dlssnr/ExternalFgStatus.h').read_text(encoding='utf-8')
  self.assertIn('inline constexpr uint64_t kPauseHoldMs = 5000;',status)
  self.assertIn('return presented < 2 ? Generation::Paused : Generation::Generating;',status)
  self.assertIn('generating = hold.Update(reading, found, tick, multiplier);',status)
  taa=(CHANNEL/'optiscaler/OptiScaler/shaders/dlssnr/DlssNr_Taa.inl').read_text(encoding='utf-8')
  self.assertIn('optishade::external_fg_status::Session().Generating(&externalMultiplier)',taa)
  tests=(Path(__file__).resolve().parent/'external_fg_status_tests.cpp').read_text(encoding='utf-8')
  self.assertIn('a long dropout falls back',tests)
 def test_r348_freezes_pre_fg_paths_and_descriptor_heap_lock(self):
  # R342 opened the per-frame pre-FG paths to every OptiMFG session; R348 DLSS NR
  # sessions froze (OSD-VHTX, KCF5, ZXRV, CHMG; hangs PID 41920, 54044).
  project=CHANNEL/'optiscaler/OptiScaler'
  hooks=(project/'hooks/Streamline_Hooks.cpp').read_text(encoding='utf-8-sig')
  self.assertIn('return DlssNr::TaaPreFgUsed() && OptiShadeTaaRequested();',hooks)
  prepare=hooks[hooks.index('void StreamlineHooks::ExternalPrepare('):]
  self.assertLess(prepare.index('if(!TaaPreFgRouteLive())return;'),prepare.index('session::State().Put'))
  present=hooks[hooks.index('void StreamlineHooks::NativeProviderPresentBegin('):]
  self.assertLess(present.index('!TaaPreFgRouteLive())return;'),present.index('g_legacyProviderPresent=swap;'))
  # No COM or driver call while descriptorHeapsMutex is held; the holder is named after 5 s.
  d3d=(project/'hooks/D3D12_Hooks.cpp').read_text(encoding='utf-8-sig')
  self.assertEqual(d3d.count('DescriptorHeapsHold hold;'),3)
  self.assertNotIn('descriptorHeaps.insert_or_assign(CaptureCommandListKey',d3d)
  restore=d3d[d3d.index('bool D3D12Hooks::RestoreDescriptorHeaps('):d3d.index('bool D3D12Hooks::RestorePipelineState(')]
  self.assertLess(restore.index('std::shared_lock<std::shared_mutex> lock(descriptorHeapsMutex);'),restore.index('if (found)'))
  self.assertLess(restore.index('heaps = entry->second;'),restore.index('s_SetDescriptorHeaps.Invoke('))
  self.assertIn('Lock watchdog: descriptorHeapsMutex busy for {} ms; holder thread {}',d3d)
  self.assertIn('Lock watchdog: the NR event lock has been busy',d3d)
 def test_review_of_4_november_open_items(self):
  installer=CHANNEL/'installer'
  # OSD-9BB5: regenerated cache files never enter a receipt, and an oversized one reads again.
  own=(installer/'ownership.ps1').read_text(encoding='utf-8-sig')
  loop=own[own.index('foreach($entry in $dataItems){'):]
  self.assertLess(loop.index('if(TestOptiShadeRegeneratedData $relative){continue}'),loop.index('$previous=HashFile $entry.FullName'))
  self.assertIn('$bytes -gt 16MB',own)
  self.assertIn("ReadOptiShadeJson $file 'Installation receipt' -MaxBytes 16777216",(installer/'library.ps1').read_text(encoding='utf-8-sig'))
  self.assertIn("-MaxBytes 16777216",(installer/'update-lifecycle.ps1').read_text(encoding='utf-8-sig'))
  self.assertTrue((Path(__file__).resolve().parent/'test_receipt_size.ps1').exists())
  # OSD-YQ25: a missing EXE says so; OSD-CHMG: restore gaps no longer flood the log.
  self.assertIn('The OptiShade EXE is no longer where it was started from',(installer/'manager.ps1').read_text(encoding='utf-8-sig'))
  d3d=(CHANNEL/'optiscaler/OptiScaler/hooks/D3D12_Hooks.cpp').read_text(encoding='utf-8-sig')
  self.assertEqual(d3d.count('if (LogRestoreGap()) LOG_WARN("Can\'t restore index'),d3d.count('Can\'t restore index'))
  # Reports name AtmosphereMod and a Glass Cockpit fix that is not drawing.
  verdicts=(installer/'Troubleshooter/src/Verdicts.cs').read_text(encoding='utf-8-sig')
  for name in ('lines.AddRange(GlassCockpitNotDrawing(','lines.AddRange(AtmosphereModInvolved(','{Prefix="GLASS COCKPIT FIX NOT DRAWING",S=2','{Prefix="ATMOSPHEREMOD LOADED",S=2'):
   self.assertIn(name.replace('{Prefix','new{Prefix'),verdicts)
  self.assertIn('VR is not covered',(installer/'manager.xaml').read_text(encoding='utf-8-sig'))
 def test_uninstall_removes_runtime_leftovers(self):
  installer=CHANNEL/'installer'
  own=(installer/'ownership.ps1').read_text(encoding='utf-8-sig')
  restore=own[own.index('function RestoreFusion('):own.index('function RestoreFusion(')+40000]
  self.assertLess(restore.index('WriteState $m $ManifestPath;RemoveUnreferencedBackups $m $folder'),restore.index('$null=RemoveOptiShadeRuntimeLeftovers $m.Game $KeepPresets'))
  self.assertIn("[string]$saved.installedBy -cne 'OptiShade'",own)
  self.assertIn('$value.OptiShadeManaged -eq 1',own)
  manager=(installer/'manager.ps1').read_text(encoding='utf-8-sig')
  self.assertIn('$null=RemoveOptiShadeCrashDumps $crashDumpExecutables',manager)
  self.assertIn('Remove-ItemProperty -LiteralPath $script:startupRegistry -Name OptiShadeManager',manager)
  self.assertTrue((Path(__file__).resolve().parent/'test_uninstall_leftovers.ps1').exists())
 def test_launcher_in_the_game_folder_does_not_block_itself(self):
  own=(CHANNEL/'installer/ownership.ps1').read_text(encoding='utf-8-sig')
  closed=own[own.index('function AssertClosed('):own.index('function GetOptiShadeMutationStore(')]
  self.assertLess(closed.index('if(TestOptiShadeLauncherImageName (Split-Path $p.Path -Leaf)){continue}'),closed.index('is still running in the background with no window'))
  self.assertLess(closed.index('if($p.Id -in $launcherIds){continue}'),closed.index('is still running in the background with no window'))
  self.assertTrue((Path(__file__).resolve().parent/'test_assert_closed.ps1').exists())
 def test_command_list_reset_drops_the_previous_recording_capture(self):
  hooks=(CHANNEL/'optiscaler/OptiScaler/hooks/D3D12_Hooks.cpp').read_text(encoding='utf-8-sig')
  forget=hooks[hooks.index('static void ForgetPreviousRecording('):hooks.index('VALIDATE_HOOK(hkCommandListReset, PFN_CommandListReset)')]
  for capture in ('descriptorHeaps.insert_or_assign(key,DescriptorHeap{})','pipelineStates.insert_or_assign(key,initialState)','signatures.insert_or_assign(key,SignatureEntry{})','rootStates[key].clear()','graphicsRootStates[key].clear()','computeCaptureSignatures[key]=nullptr','graphicsCaptureSignatures[key]=nullptr'):
   self.assertIn(capture,forget)
  # Slot 10 is ID3D12GraphicsCommandList::Reset, and both hook domains install it.
  self.assertIn('o_commandListResetEarly = (PFN_CommandListReset) pVTable[10];',hooks)
  self.assertIn('o_commandListResetLate = (PFN_CommandListReset) pVTable[10];',hooks)
  self.assertIn('&(PVOID&) o_commandListResetEarly, hkCommandListReset)',hooks)
  self.assertIn('&(PVOID&) o_commandListResetLate, hkCommandListResetLate)',hooks)
  # "Reset, nothing bound" has nothing to replay and must not stop NR running.
  self.assertLess(hooks.index('if (heaps.NumDescriptorHeaps == 0)'),hooks.index('return s_SetDescriptorHeaps.Invoke(cmdList, heaps.NumDescriptorHeaps'))
  self.assertLess(hooks.index('if (!pipelineState)'),hooks.index('return s_SetPipelineState.Invoke(cmdList, pipelineState)'))
  self.assertNotIn('if(!compute&&!graphics)return;',hooks)
  self.assertIn('if(entry->second&&!TryGetRootParameterCount(entry->second,parameters))',hooks)
 def test_fixed_mfg_with_sim_vsync_is_named(self):
  installer=CHANNEL/'installer'
  verdicts=(installer/'Troubleshooter/src/Verdicts.cs').read_text(encoding='utf-8-sig')
  for name in ('lines.AddRange(FixedMfgWithSimVsync(Texts(items,"UserCfg"),Texts(items,"OptiMFG-controller")))','new{Prefix="FIXED OPTIMFG WITH SIM VSYNC ON",S=3'):
   self.assertIn(name,verdicts)
  self.assertIn('Fixed multipliers need VSync off in the sim',(installer/'manager.xaml').read_text(encoding='utf-8-sig'))
 def test_streamline_crash_dumps_are_named(self):
  verdicts=(CHANNEL/'installer/Troubleshooter/src/Verdicts.cs').read_text(encoding='utf-8-sig')
  for name in ('lines.AddRange(StreamlineCaughtCrash(Texts(items,"-sl-sha-")))','new{Prefix="STREAMLINE CAUGHT A CRASH",S=1'):
   self.assertIn(name,verdicts)
 def test_settings_split_remove_from_games_and_system_uninstall(self):
  installer=CHANNEL/'installer'
  xaml=(installer/'manager.xaml').read_text(encoding='utf-8-sig')
  manager=(installer/'manager.ps1').read_text(encoding='utf-8-sig')
  support=(installer/'support.ps1').read_text(encoding='utf-8-sig')
  uninstall=(installer/'uninstall_windows.go').read_text(encoding='utf-8')
  # Two separate actions: games only (app stays), and the whole system.
  self.assertLess(xaml.index('x:Name="RemoveFromAllGames" Content="Remove OptiShade from all games'),xaml.index('x:Name="Uninstall" Content="Uninstall OptiShade from this system'))
  self.assertIn("RemoveOptiShadeFromAllGames $store -KeepPresets $choice.KeepPresets -Snapshots $choice.Snapshots",manager)
  self.assertIn('$choice=ShowOptiShadeUninstallPage $form',manager)
  # The installed app hands the system uninstall to Uninstall.exe, which removes the app folder.
  self.assertIn('$installedUninstaller=GetOptiShadeInstalledUninstaller',manager)
  # Keeping saved looks or snapshots must not stop the app being removed.
  self.assertIn("if($UninstallMode -and $choice.AppFiles -and -not $cleanupResult.UnrestoredOriginalFiles.Count){",manager)
  # Cancel closes quietly; the page is the confirmation, not a plain Windows box.
  self.assertIn('Uninstall-Cancelled.json',manager);self.assertIn('Uninstall-Cancelled.json',uninstall)
  self.assertNotIn('The manager will first restore every recorded game installation and show the uninstall choices',uninstall)
  # The reason is optional and only sent when given.
  self.assertIn("if(-not $Choice -or (-not $Choice.ReasonChoice -and -not $Choice.ReasonText)){return $null}",support)
  self.assertIn('WaitOptiShadeUninstallFeedback $feedback',manager)
 def test_native_fg_assembly_checks_its_own_abi(self):
  # AssemblyRequest has its own ABI; checking it against the route ABI refused
  # every TAA pre-FG frame (OSD-HP3C), so TAA NR never ran before frame generation.
  adapter=(CHANNEL/'routes/adapter_exports.inl').read_text(encoding='utf-8-sig')
  native=adapter.split('OptiShadeRouteNativeFrame(',1)[1].split('switch(r->event)',1)[0]
  self.assertIn('r->abi!=AssemblyRequest{}.abi',native)
  self.assertNotIn('r->abi!=Abi',native)
 def test_vr_troubleshooter_collects_bounded_runtime_and_simulator_evidence(self):
  collector=(CHANNEL/'installer/Troubleshooter/src/Collector.cs').read_text(encoding='utf-8-sig')
  vr=(CHANNEL/'installer/Troubleshooter/src/VrDiagnostics.cs').read_text(encoding='utf-8-sig')
  build=(CHANNEL/'installer/Troubleshooter/build.ps1').read_text(encoding='utf-8-sig')
  program=(CHANNEL/'installer/Troubleshooter/src/Program.cs').read_text(encoding='utf-8-sig')
  self.assertIn('system/vr-runtime.txt',collector)
  self.assertIn('analysis/VR-simulator-log.txt',collector)
  self.assertIn('VrDiagnostics.SelectedGameVrModules',collector)
  self.assertIn('OpenXrRegistrationEvidence()',collector)
  self.assertIn('RuntimeProcessSnapshot()',collector)
  self.assertIn('FilterSimulatorLogEvidence(captured)',collector)
  self.assertIn('RegistryView.Registry64',vr)
  self.assertIn('do not prove a headset',vr.lower())
  self.assertIn('MaxVrLogChars = 128 * 1024',vr)
  self.assertIn(r'src\VrDiagnostics.cs',build)
  self.assertIn('0.2.34',program)
  self.assertIn('NeuralSessionAssessment(session)',collector)
  self.assertIn("not requested in this saved session's final state",collector)
  self.assertIn('NeuralRuntimeActivityEvidence()',collector)
  self.assertIn('XP12 Vulkan NR:',collector)
  self.assertIn('NR runtime activity was found in the captured logs',collector)
  self.assertIn('saved-session process identities may differ',collector)
  self.assertIn('does not prove that the processed image was visible',collector)
 def test_components_show_only_the_download_queue_and_fx_actions(self):
  xaml=(CHANNEL/'installer/manager.xaml').read_text(encoding='utf-8-sig')
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  components=(CHANNEL/'installer/components.ps1').read_text(encoding='utf-8-sig')
  page=xaml[xaml.index('x:Name="ComponentsPage"'):xaml.index('</ScrollViewer>',xaml.index('x:Name="ComponentsPage"'))]
  self.assertEqual(page.count('<ProgressBar '),1)
  self.assertIn('x:Name="ComponentProgress"',page)
  self.assertNotIn('ComponentCountBar',xaml+manager)
  self.assertIn('x:Name="InstallAllFx"',page);self.assertIn('x:Name="ImportFxIni"',page)
  self.assertIn('<CheckBox x:Name="InstallAllFx"',page)
  self.assertIn('OptiShade FSR / XeSS providers',page)
  self.assertIn('Alternative upscaling libraries for OptiScaler',page)
  self.assertIn('built-in game FSR/DLSS works without them',page)
  self.assertNotIn("Required by OptiShade's optional MFG add-on",page)
  self.assertIn("InstallOptiShadeAddon $mp $Payload $id (GetFusionGpu) $progress -SkipAllFx:$skipAllFx",manager)
  self.assertIn("$script:pendingFxPresetPath=$selectedIni",manager)
  self.assertIn('press Apply selected changes to install',manager)
  preset_handler=manager[manager.index("$form.FindName('ImportFxIni').Add_Click({"):manager.index("$form.FindName('Install').Add_Click({")]
  self.assertNotIn('RunAction',preset_handler)
  self.assertIn("$form.FindName('ComponentsApply').Add_Click({RunAction {InvokeComponentSelection}",manager)
  self.assertIn('SaveOwnPreset $presetToApply',manager)
  self.assertIn('SetOptiShadeReShadePreset $path.Text $relative',manager)
  self.assertIn('if($Id -eq \'Effects\'){$paths+=\'ReShade.ini\'}',components)
  self.assertIn('set to load automatically when the game starts',manager)
  self.assertIn('Navigate to an INI file or drag and drop it below.',manager)
  self.assertIn('Add_Drop',manager);self.assertIn('queueOnlyProgress',manager)
  self.assertIn("Start-Process -FilePath $Installer -ArgumentList $arguments -WindowStyle Normal",manager)
  self.assertIn("UpdateOperationProgress $text $completed $total",manager)
  self.assertIn("Status='Running'",manager);self.assertIn("Status=$(if($Cancelled){'Cancelled'}elseif($Failed){'Failed'}elseif($Attention){'Attention'}else{'Completed'})",manager)
  self.assertIn('$script:operationProgressLastState=$state',manager)
  self.assertIn("if($succeeded){$script:operationAttention=$true}else{$script:operationFailed=$true}",manager)
  progress=(CHANNEL/'installer/operation-progress.ps1').read_text(encoding='utf-8-sig')
  self.assertIn('DispatcherTimer',progress);self.assertIn("Status -in @('Completed','Failed','Attention','Cancelled')",progress)
  self.assertIn("'COMPLETED WITH ISSUES — '",progress)
  self.assertIn("'Some steps need attention. Review the details and manager results, then dismiss this window.'",progress)
  progress_store=(CHANNEL/'installer/operation-progress-store.ps1').read_text(encoding='utf-8-sig')
  self.assertIn('WriteOptiShadeOperationProgressState',manager)
  self.assertIn('ReadOptiShadeOperationProgressState',progress)
  self.assertIn('[IO.File]::Replace($temporary,$Path',progress_store)
  self.assertIn('[IO.FileShare]::Delete',progress_store)
  self.assertNotIn('ProgressClose',progress);self.assertNotIn('Content="Close"',progress)
  self.assertIn("'FAILED. Review the error above and the manager refreshed component statuses.'",progress)
  self.assertIn("$window.FindName('Dismiss').Visibility='Visible'",progress)
  self.assertNotIn("$script:terminalStatus -ne 'Completed' -and",progress)
  self.assertIn('function PumpManagerDispatcher',manager)
  progress_callback=manager[manager.index('$progress={'):manager.index("$script:pendingFxPresetPath=")]
  self.assertIn('PumpManagerDispatcher',progress_callback)
  components=(CHANNEL/'installer/components.ps1').read_text(encoding='utf-8-sig')
  self.assertIn('InstallAddonPayload $ManifestPath $Payload $Id $Progress',components)
  host=(CHANNEL/'installer/main.go').read_text(encoding='utf-8-sig')+'\n'+(CHANNEL/'installer/public_bundle.go').read_text(encoding='utf-8-sig')
  self.assertIn('operation-progress.ps1',host);self.assertIn('operationProgress',host)
  run_action=manager[manager.index('function RunAction('):manager.index('$form.Add_Closing(')]
  self.assertNotIn('$form.Topmost=$true',run_action);self.assertNotIn('$form.Topmost=$false',run_action)
  self.assertIn('if($script:operationProgressAttempted){return}',manager)
  self.assertIn("$form.FindName('ComponentProgress').Visibility='Collapsed'",run_action)
  self.assertIn("$form.FindName('InstallProgress').Visibility='Collapsed'",run_action)
  self.assertIn("try{RefreshLibrary}catch",run_action)
  self.assertIn("RefreshAddonCards}}catch",run_action)
  component_apply=manager[manager.index('function InvokeComponentSelection{'):manager.index('function ConfirmAndUninstallComponents(')]
  self.assertNotIn('ConfirmOptionalDlss',component_apply)
  self.assertIn("$popup=NewManagerPopup 'Choose an FX preset'",manager)
  self.assertNotIn('Title="Choose an FX preset" Width="540"',manager)
  component_page=xaml[xaml.index('x:Name="ComponentsPage"'):]
  self.assertIn('VerticalScrollBarVisibility="Auto"',component_page)
  self.assertIn('CanContentScroll="False"',component_page)
  self.assertLess(component_page.index('DockPanel.Dock="Left"'),component_page.index('x:Name="ComponentsGame"'))
 def test_help_guides_are_game_neutral_and_main_launcher_pages_do_not_scroll(self):
  xaml=(CHANNEL/'installer/manager.xaml').read_text(encoding='utf-8-sig')
  trouble=(CHANNEL/'installer/Troubleshooter/src/UI.xaml').read_text(encoding='utf-8-sig')
  for name in ('Tutorial.txt','How-it-works.txt','Features.txt'):
   text=(CHANNEL/'installer/Help'/name).read_text(encoding='utf-8-sig')
   self.assertNotRegex(text,r'(?i)flight simulator|\bsimulator\b')
  for page in ('KeybindsPage','SettingsPage','TroubleshootingPage'):
   self.assertIn(f'x:Name="{page}" VerticalScrollBarVisibility="Disabled" HorizontalScrollBarVisibility="Disabled"',xaml)
  self.assertIn('x:Name="HomePage" VerticalScrollBarVisibility="Auto"',xaml)
  self.assertIn('x:Name="SetupPage" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" CanContentScroll="False"',xaml)
  self.assertIn('x:Name="LibraryPage" VerticalScrollBarVisibility="Auto"',xaml)
  self.assertIn('x:Name="ComponentsPage" VerticalScrollBarVisibility="Auto"',xaml)
  self.assertIn('MaxHeight="280" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"',xaml)
  self.assertIn('x:Name="ManagerSearchResults"',xaml)
  search_results=xaml[xaml.index('x:Name="ManagerSearchResults"'):xaml.index('>',xaml.index('x:Name="ManagerSearchResults"'))]
  self.assertIn('ScrollViewer.VerticalScrollBarVisibility="Auto"',search_results)
  self.assertIn('x:Name="ComponentOptions"',xaml)
  self.assertIn('x:Name="RenderingComponentOptions"',xaml)
  self.assertIn('x:Name="CompatibilityOptions"',xaml)
  self.assertIn('Choose the game you tested',trouble)
  self.assertNotRegex(trouble,r'(?i)choose your simulator|troubleshoot your simulator')
  collector=(CHANNEL/'installer/Troubleshooter/src/Collector.cs').read_text(encoding='utf-8-sig')
  self.assertIn('analysis/VR-session-timeline.txt',collector)
  self.assertIn('OpenXR lifecycle and performance timeline',collector)
  self.assertIn('LastSession process identity',collector)
  self.assertIn('MATCHES LASTSESSION PID AND BIRTH',collector)
  streamline=(PROJECT/'hooks/Streamline_Hooks.cpp').read_text(encoding='utf-8')
  self.assertIn('dynamicRequested && state.api == API::DX12',streamline)
  self.assertIn('native_mfg::DynamicSupported(',streamline)
  self.assertIn('Session().Observe(identity,static_cast<uint32_t>(viewport),effectiveMaximum,true,evidence.dynamicKnown,dynamicSupported)',streamline)
  self.assertIn('api == GraphicsApi::Direct3D12', (CHANNEL/'shared/NativeMfgControl.h').read_text(encoding='utf-8'))
  menu=(PROJECT/'menu/menu_common.cpp').read_text(encoding='utf-8')
  self.assertIn('state.api==API::DX12 && state.dlssgGameDMFGSupported',menu)
 def test_msfs_hang_capture_waits_longer_during_loading(self):
  capture=(CHANNEL/'installer/Troubleshooter/src/AutoCapture.cs').read_text(encoding='utf-8-sig')
  program=(CHANNEL/'installer/Troubleshooter/src/Program.cs').read_text(encoding='utf-8-sig')
  collector=(CHANNEL/'installer/Troubleshooter/src/Collector.cs').read_text(encoding='utf-8-sig')
  self.assertIn('var policy=StallPolicy.ForExecutable(expected)',capture)
  self.assertIn('Msfs2024StartupGraceSeconds=600',capture)
  self.assertIn('Msfs2024UnresponsiveThresholdSeconds=90',capture)
  self.assertIn('Msfs2024TraceStallThresholdSeconds=180',capture)
  self.assertIn('new StallPolicy(Msfs2024StartupGraceSeconds,Msfs2024UnresponsiveThresholdSeconds,Msfs2024TraceStallThresholdSeconds)',capture)
  self.assertIn('Automatic suspected-stall captures are historical evidence',collector)
  self.assertIn('MSFS 2024 gets a ten-minute load grace, then 90 s nonresponse or 180 s pending GPU work',program)
class NrSessionDisable(unittest.TestCase):
 def test_recovery_never_turns_a_user_off_request_back_on(self):
  dx12=(PROJECT/'shaders/dlssnr/DlssNr_Dx12.cpp').read_text(encoding='utf-8')
  retry=dx12[dx12.index('void RetryAfterFailure()'):dx12.index('void SetEnabled(bool enabled,')]
  self.assertIn('if (g_nrDeviceLost) return;',retry)
  self.assertIn('g_memoryPressureStopped = false;',retry)
  self.assertNotRegex(retry,r'DlssNrEnabled\s*=\s*true')
  self.assertNotIn('Config::Instance()->DlssNrEnabled',retry)

 def test_disabling_nr_gates_bridge_residual_and_pending_output_commit(self):
  dx12=(PROJECT/'shaders/dlssnr/DlssNr_Dx12.cpp').read_text(encoding='utf-8')
  bridge=dx12[dx12.index('bool EvaluatePrivateVulkanBridge('):dx12.index('void RetryAfterFailure()')]
  gate='if(!Config::Instance()->DlssNrEnabled.value_or_default())return false;'
  self.assertIn(gate,bridge);self.assertLess(bridge.index(gate),bridge.index('g_compose->Dispatch('))
  residual=dx12[dx12.index('void ApplyResidualAcrossRr('):dx12.index('#include "DlssNr_Late.inl"')]
  self.assertIn('if(!Config::Instance()->DlssNrEnabled.value_or_default())',residual)
  self.assertIn('g_nr.residualPair.Cancel()',residual)
  native_fg=(PROJECT/'shaders/dlssnr/DlssNr_TaaNativeFg.inl').read_text(encoding='utf-8')
  before_present=native_fg[native_fg.index('void TaaFgBeforePresent('):native_fg.index('bool TaaFgProviderPrepare(')]
  disable=before_present.index('if(!OptiShadeTaaRequested())')
  self.assertLess(disable,before_present.index('SubmitPrivateRecording(presentingQueue,f->commit.Get())'))
  self.assertIn('f->outputPending=false;f->retired=true;',before_present)

class TaaFgFallbackOwnership(unittest.TestCase):
 def test_fallback_yields_only_to_a_matching_validated_native_frame(self):
  policy=(CHANNEL/'shared/TaaFgAdmission.h').read_text(encoding='utf-8')
  fallback=(PROJECT/'shaders/dlssnr/DlssNr_Taa.inl').read_text(encoding='utf-8')
  native=(PROJECT/'shaders/dlssnr/DlssNr_TaaNativeFg.inl').read_text(encoding='utf-8')
  self.assertIn('validatedFrameContract && NativeCompositionAllowed(acceptedNativeSignature)',policy)
  self.assertIn('BlocksLateComposition(managedFg,nativeFgSignature,validatedNativeContract)',fallback)
  self.assertIn('TAA NR fallback is active until a matching native-FG frame contract is available.',fallback)
  self.assertIn('frame->id.device!=deviceIdentity',native)
  self.assertIn('frame->sealed&&!frame->retagged',native)
  self.assertIn('desc.Width==width&&desc.Height==height',native)
  self.assertIn('fallback remains available until a valid frame contract is received',native)
class ProcessScopedVulkan(unittest.TestCase):
 def test_xplane_vulkan_environment_is_not_applied_to_other_games(self):
  target=(CHANNEL/'shared/XPlaneVulkanTarget.h').read_text(encoding='utf-8')
  process=(CHANNEL/'shared/XPlaneVulkanProcess.h').read_text(encoding='utf-8')
  configure=process[process.index('inline const char* Configure'):]
  self.assertIn('IsXPlaneProcessName(executable.filename().wstring())',configure)
  gate=configure.index('IsXPlaneProcessName(executable.filename().wstring())')
  self.assertLess(gate,configure.index('SetEnvironmentVariableW'))
  self.assertIn('std::wstring_view',target)
  self.assertIn('L"X-Plane.exe"',target)
class Views(unittest.TestCase):
 def test_mfg_components_copy_describe_global_capability_bound_support(self):
  xaml=(CHANNEL/'installer/manager.xaml').read_text(encoding='utf-8-sig')
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  self.assertIn('Text="Optional tray controller for extra live MFG controls.',xaml)
  self.assertIn('Content="Start OptiMFG"',xaml)
  self.assertIn("$form.FindName('PrepareMfg').IsEnabled=$false",manager)
  self.assertNotIn("$form.FindName('PrepareMfg').Add_Click({",manager)

 def test_dx12_ngx_contexts_serialize_global_evaluation_state_and_identify_missing_dlssd_inputs(self):
  ngx=(PROJECT/'inputs/NVNGX_DLSS_Dx12.cpp').read_text(encoding='utf-8')
  contexts=ngx[ngx.index('static ankerl::unordered_dense::map<unsigned int, ContextData<IFeature_Dx12>>'):ngx.index('static NgxFeatureRegistry HandleToFeature')]
  evaluate=ngx[ngx.index('static NVSDK_NGX_Result TryEvaluateOptiFeature(ID3D12GraphicsCommandList* InCmdList,',ngx.index('NVSDK_NGX_D3D12_GetFeatureRequirements')):ngx.index('NVSDK_NGX_API NVSDK_NGX_Result NVSDK_NGX_D3D12_EvaluateFeature')]
  self.assertIn('std::shared_mutex Dx12ContextsMutex',contexts)
  self.assertIn('std::mutex Dx12EvaluationMutex',contexts)
  self.assertIn('std::unique_lock evaluationLock(Dx12EvaluationMutex)',evaluate)
  self.assertIn('std::shared_lock contextsLock(Dx12ContextsMutex)',evaluate)
  self.assertLess(evaluate.index('std::unique_lock evaluationLock(Dx12EvaluationMutex)'),evaluate.index('std::shared_lock contextsLock(Dx12ContextsMutex)'))
  self.assertIn('Concurrent D3D12 NGX evaluation serialized across handles',evaluate)
  self.assertNotIn('evaluateMutex',evaluate)
  self.assertIn('FAIL_MissingInput',evaluate)
  self.assertIn('return result == NVSDK_NGX_Result_FAIL_MissingInput ? result : NVSDK_NGX_Result_Fail;',evaluate)
  self.assertIn('DLSS is skipping frames because the game has not provided a required input for a few seconds.',evaluate)
  dlss=(PROJECT/'upscalers/dlss/DLSSFeature_Dx12.cpp').read_text(encoding='utf-8')
  self.assertIn('RecordEvaluateResult(nvResult)',dlss)
  self.assertIn('FAIL_MissingInput; the game did not provide a required input this frame',dlss)
  dlssd=(PROJECT/'upscalers/dlssd/DLSSDFeature_Dx12.cpp').read_text(encoding='utf-8')
  self.assertIn('RecordEvaluateResult(nvResult)',dlssd)
  self.assertIn('the game did not provide a required input this frame',dlssd)

 def test_input_callbacks_never_wait_on_busy_overlay_state_and_late_dinput_is_not_patched_on_render_thread(self):
  messages=(PROJECT/'menu/input/input_system_messages.cpp').read_text(encoding='utf-8')
  wndproc=messages[messages.index('LRESULT CALLBACK OptiInputWndProc'):messages.index('bool ProcessRemovedMessage')]
  queue=messages[messages.index('bool ProcessRemovedMessage'):messages.index('void ConsumeMessage')]
  self.assertIn('std::try_to_lock',wndproc)
  self.assertIn('if (!lock.owns_lock())',wndproc)
  self.assertIn('CallWindowProcW(originalWndProc, hwnd, msg, wParam, lParam)',wndproc)
  self.assertIn('std::try_to_lock',queue)
  self.assertIn('if (!lock.owns_lock())',queue)
  self.assertIn('return false;',queue)
  input_system=(PROJECT/'menu/input/input_system.cpp').read_text(encoding='utf-8')
  begin=input_system[input_system.index('static void BeginFrameLocked'):input_system.index('void BeginFrame(HWND targetHwnd, bool isUwp)')]
  self.assertNotIn('UpdateDirectInputIntegrationLocked();',begin)
  initialize=input_system[input_system.index('bool Initialize(const InitializeOptions& options)'):input_system.index('bool Initialize(HWND targetHwnd, bool isUwp)')]
  self.assertIn('UpdateDirectInputIntegrationLocked();',initialize)

 def test_nr_model_transactions_keep_installer_function_scope(self):
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  components=(CHANNEL/'installer/components.ps1').read_text(encoding='utf-8-sig')
  start=manager.index("InvokeAddonTransaction $mp 'Neural' {")
  end=manager.index("$status.Text=$label+' runtime hash verified",start)
  self.assertNotIn('.GetNewClosure()',manager[start:end])
  install=components[components.index('function InstallOptiShadeAddon'):components.index('function UpdateGlassCockpitAddon')]
  remove=components[components.index('function RemoveOptiShadeAddon'):]
  self.assertNotIn('.GetNewClosure()',install)
  self.assertNotIn('.GetNewClosure()',remove)
 def test_manager_focus_loss_does_not_invoke_powershell_from_wndproc(self):
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  self.assertIn('public sealed class FusionFocusCaptureGuard',manager)
  self.assertIn('_window.Deactivated += OnDeactivated',manager)
  self.assertIn('[FusionFocusCaptureGuard]::new',manager)
  self.assertNotRegex(manager,r'\$form\.Add_Deactivated\s*\(')
 def test_wpf_focus_guard_references_system_xaml_for_windows_powershell(self):
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  self.assertIn("[System.Xaml.XamlReader].Assembly.Location",manager)
 def test_manual_game_browse_control_is_removed(self):
  manager=(CHANNEL/'installer/manager.ps1').read_text(encoding='utf-8-sig')
  xaml=(CHANNEL/'installer/manager.xaml').read_text(encoding='utf-8-sig')
  self.assertNotIn("$form.FindName('Browse').Add_Click",manager)
  self.assertNotIn('x:Name=\"Browse\"',xaml)
 def test_directx_menu_captures_input_only_after_drawable_ui(self):
  base=(PROJECT/'menu/menu_dx_base.cpp').read_text(encoding='utf-8')
  dx11=(PROJECT/'menu/menu_dx11.cpp').read_text(encoding='utf-8')
  dx12=(PROJECT/'menu/menu_dx12.cpp').read_text(encoding='utf-8')
  self.assertIn('BeginMenuDrawOwner()',base)
  self.assertIn('TotalVtxCount > 0',base)
  self.assertIn('ReportMenuDrawSubmission(submitted, menuDrawOwner, reason)',base)
  self.assertIn('DirectX menu produced no draw vertices',base)
  for source,api in ((dx11,'DirectX 11'),(dx12,'DirectX 12')):
   self.assertIn(f'{api} menu draw data recorded',source)
   self.assertIn('ReportMenuDrawResult(true',source)
  self.assertIn('SetMenuVisible(false)',base)
 def test_mfg_draw_uses_one_publication_for_acknowledgement_and_state(self):
  text=(PROJECT/'menu/optishade_mfg_ui.inl').read_text()
  draw=text[text.index('static bool Draw(bool supported)'):]
  self.assertEqual(draw.count('service.worker.Peek()'),1)
  self.assertIn('service.Read(result)',draw)
  self.assertIn('result->saveMessage,snapshot',draw)
 def test_native_mfg_uses_the_same_visible_multiplier_range_on_every_adapter(self):
  text=(PROJECT/'menu/optishade_mfg_ui.inl').read_text()
  native=text[text.index('static void DrawNative(API api)'):]
  self.assertIn('ClassifyAvailability',native)
  self.assertIn('NoNativeProviderOnDirect3D11',text)
  self.assertIn('NoNativeProviderOnDirect3D12',text)
  self.assertIn('NoNativeProviderOnVulkan',text)
  self.assertIn('private Vulkan-to-D3D12 bridge used for neural rendering',text)
  self.assertIn('game/provider compatibility limitation, not an OptiShade installation failure.',text)
  self.assertIn('This is an OptiShade compatibility issue; send diagnostics to Discord.',text)
  self.assertIn('The active provider rejected the MFG request (result %d). This does not by itself show that OptiShade is at fault; the game/provider may not support this request. If you expected MFG to work here, or are unsure, send diagnostics to Discord.',text)
  self.assertNotIn('ImGui::TextWrapped("%s",ActivationHelp);ImGui::TextWrapped("The game has requested frame generation',text)
  self.assertIn('If you expected the game to support MFG, or are unsure, send diagnostics to Discord.',text)
  self.assertIn('TestOptiShadeMfgInstallTarget', (CHANNEL/'installer/provider-policy.ps1').read_text(encoding='utf-8-sig'))
  policy=(CHANNEL/'installer/provider-policy.ps1').read_text(encoding='utf-8-sig')
  self.assertIn('[switch]$AllowPreinstall',policy)
  self.assertIn('TestOptiShadeMfgPreparationGame $Manifest $GpuNames',policy)
  self.assertIn('for(int multiplier=2;multiplier<=6;++multiplier)',native)
  self.assertIn('generated<=int(s.maximum)',native)
  self.assertIn('CapabilityRangeDetail(s.maximum)',native)
  diagnostic=(PROJECT/'menu/native_mfg_ui_diagnostics.h').read_text()
  self.assertIn('one generated frame (2x)',diagnostic)
  self.assertIn('has not exposed 3x or higher Multi Frame Generation',diagnostic)
  ui=(PROJECT/'menu/optishade_mfg_ui.inl').read_text()
  self.assertIn('Reason::TwoXOnly:return "The active game provider supports 2x frame generation',ui)
  self.assertIn('The game has exposed a valid 2x frame-generation range.',ui)
  self.assertIn('MFG request saved, not applied: the game has not exposed an active DLSS Frame Generation path.',ui)
  panel=(PROJECT/'menu/OptiShadePanel.inl').read_text()
  self.assertNotIn('page==0&&frameGenerationStatus',panel)
 def test_native_mfg_explains_install_is_ready_while_game_provider_is_missing(self):
  text=(PROJECT/'menu/native_mfg_ui_diagnostics.h').read_text()
  self.assertIn('No live DLSS-G provider callback has been exposed to OptiShade yet.',text)
  self.assertIn("MFG setup does not require that callback; enable the game's supported DLSS Frame Generation option (in MSFS, use Graphics settings) and return to a rendered scene so OptiShade can check it in-game.",text)
  self.assertIn('A missing callback alone does not mean MFG installation failed.',text)
  performance=(PROJECT/'menu/reconstruction/Performance.inl').read_text()
  self.assertNotIn('OptiShadeMfgUI::DrawNative(ctx.state.swapchainApi);',performance)
 def test_nr_idle_private_recordings_retire_without_releasing_game_recordings(self):
  shader=(PROJECT/'shaders/dlssnr/DlssNr_Dx12.cpp').read_text()
  late=(PROJECT/'shaders/dlssnr/DlssNr_Late.inl').read_text()
  taa=(PROJECT/'shaders/dlssnr/DlssNr_Taa.inl').read_text()
  maintenance=shader.split('void RetireCompletedPrivateRecordings()\n{',1)[1].split('// Called under the NR event lock.',1)[0]
  self.assertIn('RetireCompletedTaaRecordings(false);',maintenance)
  self.assertIn('!slot.recording && !slot.pending && late.Finished(slot)',maintenance)
  self.assertIn('RetirePrivate(slot.commands.Get())',maintenance)
  self.assertNotIn('->Release()',maintenance)
  self.assertIn('RetireCompletedPrivateRecordings();',shader.split('void TickNrRetired()\n{',1)[1].split('void ForgetCalibration',1)[0])
  self.assertLess(late.index('slot.recording = true;'),late.index('FAILED(slot.commands->Reset'))
  self.assertGreater(late.index('slot.recording = false;'),late.index('FAILED(queue->Signal(slot.fence.Get(), slot.done))'))
  self.assertIn('if(c.poisoned||c.Borrowing())return;',taa)
  self.assertIn('if(any&&resetHistory)c.lastRun=0;',taa)
 def test_diagnostic_collector_uses_system_forwarding_before_runtime_bootstrap(self):
  source=(PROJECT/'dllmain.cpp').read_text()
  predicate=source.split('static bool IsOptiShadeUtilityProcess()',1)[1].split('static bool InitUtilitySystemForwarder',1)[0]
  self.assertIn('L"OptiShadeSensors.exe"',predicate)
  self.assertIn('L"OptiShade-Troubleshooter.exe"',predicate)
  for name in ('OptiMFG_Live.exe','OptiMFG_Controller.exe','OptiMFG_LiveCtl.exe','PresentMon.exe'):
   self.assertIn('L"'+name+'"',predicate)
  # Store packages resolve the game proxy into OptiMFG's PresentMon child; a full
  # bootstrap there truncated the simulator's Performance.log (R309).
  self.assertIn('L"\\\\optishadedata\\\\"',predicate)
  attach=source.split('case DLL_PROCESS_ATTACH:',1)[1]
  self.assertLess(attach.index('if(IsOptiShadeUtilityProcess()||ProxyLoadedOutsideExeFolder(hModule))'),attach.index('Config::Instance()'))
  self.assertIn('return InitUtilitySystemForwarder(hModule)?TRUE:FALSE;',attach)
 def test_process_termination_skips_reshade_teardown_locks(self):
  source=(CHANNEL/'reshade/source/dll_main.cpp').read_text()
  detach=source.split('case DLL_PROCESS_DETACH:',1)[1]
  self.assertIn('if (reserved != nullptr)\n\t\t\treturn TRUE;',detach)
  self.assertLess(detach.index('if (reserved != nullptr)'),detach.index('reshade::hooks::uninstall()'))
  self.assertLess(detach.index('return TRUE;'),detach.index('reshade::log::message'))
 def test_failed_resize_does_not_query_provider_buffers_or_mask_hresult(self):
  source=(PROJECT/'wrapped/wrapped_swapchain.cpp').read_text()
  for method in ('ResizeBuffers','ResizeBuffers1'):
   body=source.split('HRESULT STDMETHODCALLTYPE WrappedIDXGISwapChain4::'+method+'(',1)[1].split('\nHRESULT STDMETHODCALLTYPE ',1)[0]
   guard=body.split('if (FAILED(result))',1)[1].split('if (result == S_OK && State::Instance().currentFeature == nullptr)',1)[0]
   self.assertIn('return result;',guard)
   self.assertIn('currentFG->Mutex.unlockThis(3)',guard)
   self.assertIn('scBuffers.clear()',guard)
   self.assertNotIn('GetBuffer(',guard)
   self.assertLess(body.index('if (FAILED(result))'),body.index('Config::Instance()->ForceHDR'))
   self.assertLess(body.index('if (FAILED(result))'),body.index('    State::Instance().scBuffers.clear();\n    UINT bc'))
   self.assertIn('IUnknown* buffer = nullptr;',body)
   self.assertIn('== S_OK && buffer != nullptr)',body)
 def test_d3d12_swapchain_resize_retains_pending_nr_leases_without_refusing_resize(self):
  swapchain=(PROJECT/'wrapped/wrapped_swapchain.cpp').read_text()
  shutdown=(PROJECT/'shaders/dlssnr/DlssNr_Dx12.cpp').read_text()
  native_fg=(PROJECT/'shaders/dlssnr/DlssNr_TaaNativeFg.inl').read_text()
  queue_wait=(CHANNEL/'shared/D3D12QueueWait.h').read_text()
  self.assertEqual(swapchain.count('DlssNr::PrepareForSwapchainResize()'),2)
  self.assertNotIn('DlssNr::Shutdown(5000)',swapchain)
  self.assertIn('RetirementResult PrepareForSwapchainResize()',shutdown)
  self.assertIn('g_nr.resizeRebuildPending = true;',shutdown)
  self.assertIn('||\n        resizeRebuildPending)',shutdown)
  self.assertIn('resolutionChanged || placementChanged || resizeRebuildPending',shutdown)
  self.assertIn('NativeFgResizeGuard nativeFgResize(_device)',swapchain)
  self.assertIn('QueueIdleProof idleProof',swapchain)
  self.assertIn('DlssNr::TaaFgQueueIdleCompleted(idleProof.queue.Get(), idleProof.fence.Get(), idleProof.value)',swapchain)
  self.assertIn('bool Complete() const',queue_wait)
  self.assertIn('f->queueIdleFence=fence;f->queueIdleValue=value',native_fg)
  self.assertIn('Completed(f->queueIdleFence.Get(),f->queueIdleValue)',native_fg)
  self.assertIn('f->retagged&&f->presentReturnedAtResizeBegin',native_fg)
  self.assertIn('presentReturnedAtResizeBegin=f->presentReturned',native_fg)
  self.assertIn('NR shutdown retained output leases: waitedMs={} nativeFgFrames={} activeCommandUses={} retiredDomains={} lateSlots={}',shutdown)
  self.assertIn('unsigned resizeDepth=0;bool resizePending=false',native_fg)
  self.assertIn('if(resizePending)return false',native_fg)
  self.assertIn('RetirementResult Shutdown(uint32_t waitTimeoutMs)',shutdown)
  self.assertIn('Sleep(1);',shutdown)
 def test_log_path_is_saved_as_written_and_heals_after_store_package_moves(self):
  # A resolved absolute log path saved to OptiScaler.ini goes stale when an
  # MSFS Store/Xbox update moves its versioned WindowsApps package folder.
  source=(PROJECT/'Config.cpp').read_text(encoding='utf-8')
  block=source[source.index('readString("Log", "LogFileName", false)'):source.index('readString("Log", "LogFileName", false)')+2600]
  self.assertIn('LogFileName.set_from_config(configured.wstring());',block)
  self.assertIn('!std::filesystem::is_directory(path.parent_path(), exists)',block)
  self.assertIn('configured = path.parent_path().filename() / path.filename();',block)
  self.assertIn('LogFileName.set_volatile_value(',block)
  self.assertNotIn('LogFileName.set_from_config((Util::DllPath()',block)
  self.assertIn('LogFileName=OptiShadeData/Performance.log',(CHANNEL/'package.ps1').read_text(encoding='utf-8'))
  # OSD-Y348/KZHR: an absolute path to OptiShade's own data folder is saved relative.
  self.assertIn('_wcsicmp(path.parent_path().filename().c_str(), L"OptiShadeData") == 0',block)
 def test_second_process_never_truncates_the_live_log(self):
  # OSD-Y348/2WR6/KZHR: spdlog's rotate-on-open truncates a log the game still
  # holds when its rename fails, leaving Performance.log at 0 bytes.
  logger=(PROJECT/'Logger.cpp').read_text(encoding='utf-8')
  self.assertIn('static std::wstring LogFileForThisProcess(const std::wstring& path, bool& shared)',logger)
  self.assertIn('if (GetLastError() != ERROR_SHARING_VIOLATION)',logger)
  self.assertLess(logger.index('logFile = LogFileForThisProcess('),logger.index('std::make_shared<OptiShadeLog::BoundedFileSink>(logFile, logBytes)'))
  verdicts=(CHANNEL/'installer/Troubleshooter/src/Verdicts.cs').read_text(encoding='utf-8-sig')
  self.assertIn('{"RUNTIME LOG EMPTIED",338},',verdicts)
  self.assertNotIn('Repair rewrites the setting',verdicts)
  # OSD-59M6: a separate ReShade loaded first, and a freeze inside Streamline's crash handler.
  self.assertIn('Another ReShade instance was already loaded from',verdicts)
  self.assertIn('GAME FROZE IN A CRASH HANDLER: thread ',verdicts)
  # OSD-Z4XF: image effects on the VR headset image; collect its config and presets.
  self.assertIn('IMAGE EFFECTS IN THE VR HEADSET: ',verdicts)
  collector=(CHANNEL/'installer/Troubleshooter/src/Collector.cs').read_text(encoding='utf-8-sig')
  self.assertIn('"settings/ReShadeVR.ini.txt"',collector)
  self.assertIn('if(!full.StartsWith(root,StringComparison.OrdinalIgnoreCase)||!presets.Add(full))continue;',collector)
 def test_nr_rebuild_waits_for_retired_model_before_creating_next_generation(self):
  source=(PROJECT/'shaders/dlssnr/DlssNr_Dx12.cpp').read_text()
  guard=source.index('Waiting for previous neural-rendering model work to finish before rebuilding')
  create=source.index('g_nr.create(snippet->wstring().c_str()')
  self.assertLess(guard,create)
  block=source.rindex('std::any_of(g_nrRetired.begin(), g_nrRetired.end(), BlocksNrRebuild)',0,guard)
  self.assertLess(guard-block,6000)  # the wait block includes the headroom-based parking limit
  self.assertIn('return item.feature != nullptr && !item.deferred;',source)
  # The bounded release never frees a model: GPU work in flight keeps waiting,
  # untracked leases wait longer, and deferred models stay parked until Ready().
  self.assertIn('waited >= required && pending > 0 && inFlight == 0',source[block:guard])
  self.assertIn('untracked ? UntrackedRebuildWaitMs : IdleRebuildWaitMs',source[block:guard])
  self.assertIn('deferredModels < MaxDeferredModels',source[block:guard])
  tick=source[source.index('void TickNrRetired()'):source.index('// The inject point decides')]
  self.assertIn('use->Ready()',tick)
  self.assertNotIn('deferred',tick)
  self.assertIn('TickNrRetired();',source[source.index('void DlssNr_Dx12::Dispatch'):guard])
  self.assertIn('device->Release();\n            return;',source[guard:guard+250])
 def test_d3d12_create_device_recursion_is_thread_local_and_scoped(self):
  helper=(CHANNEL/'shared/D3D12CreateDeviceScope.h').read_text(encoding='utf-8')
  hooks=(PROJECT/'hooks/D3D12_Hooks.cpp').read_text(encoding='utf-8')
  self.assertIn('inline thread_local unsigned createDeviceDepth',helper)
  self.assertIn('inline thread_local bool creatingD3DDevice',helper)
  self.assertIn('class CreateDeviceScope',helper)
  self.assertIn('CreatingD3DDeviceScope',helper)
  self.assertIn('CreateDeviceScope createDeviceScope',hooks)
  self.assertIn('IsCreatingDevice()',hooks)
  self.assertNotIn('_creatingD3D12Device',hooks)
  state=(PROJECT/'State.h').read_text(encoding='utf-8')
  vulkan=(PROJECT/'spoofing/Vulkan_Spoofing.cpp').read_text(encoding='utf-8')
  self.assertNotIn('bool creatingD3DDevice = false',state)
  self.assertIn('using ScopedCreatingD3DDevice = optishade::d3d12::CreatingD3DDeviceScope',state)
  self.assertEqual(vulkan.count('IsCreatingD3DDevice()'),2)
 def test_mfg_draw_uses_one_publication_for_acknowledgement_and_state(self):
  text=(PROJECT/'menu/optishade_mfg_ui.inl').read_text()
  draw=text[text.index('static bool Draw(bool supported)'):]
  self.assertEqual(draw.count('service.worker.Peek()'),1)
  self.assertIn('service.Read(result)',draw)
  self.assertIn('result->saveMessage,snapshot',draw)
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.channel=Path(self.temp.name)/'Beta';self.project=self.channel/'optiscaler/OptiScaler'
  self.contract=json.loads((CHANNEL/'reconstruction/native-view-contract.json').read_text(encoding='utf-8-sig'))
  names=[r['source'] for r in self.contract['files']]+['menu/OptiShadePanel.inl','dlssnr/DlssNrPanel.inl','OptiScaler.vcxproj']
  for name in names:
   path=self.project/name;path.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(PROJECT/name,path)
  for name in ['native-view-contract.json','OptiShade.Reconstruction.targets']:
   path=self.channel/'reconstruction'/name;path.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(CHANNEL/'reconstruction'/name,path)
  self.original={str(p.relative_to(self.project)):p.read_bytes() for p in self.project.rglob('*') if p.is_file()}
 def tearDown(self):self.temp.cleanup()
 def test_checked_native_sources_are_read_only(self):
  result=views.verify(self.channel);self.assertEqual(result['native_sources'],19);self.assertFalse(result['legacy_generation'])
  for n,b in self.original.items():self.assertEqual((self.project/n).read_bytes(),b,n)
 def test_missing_binding_rejected_without_outputs(self):
  p=self.project/'dlssnr/reconstruction/NRHdr.inl';p.write_text(p.read_text(encoding='utf-8').replace('config->DlssNrHdrPaperWhite','config->RemovedHdrPaperWhite'),encoding='utf-8')
  # Remove a known binding from every view so source drift cannot hide a lost control.
  key=self.contract['nr_required_fields'][0]
  for file in self.project.rglob('*.inl'):
   file.write_text(file.read_text(encoding='utf-8').replace('config->'+key,'config->Removed_'+key),encoding='utf-8')
  with self.assertRaisesRegex(ValueError,'missing native NR bindings'):views.verify(self.channel)
 def test_startup_drift_refused(self):
  p=self.project/'dllmain.cpp';p.write_text(p.read_text(encoding='utf-8').replace('optishade::control::StartRuntimeControl(sourceMfgReserved);',''),encoding='utf-8')
  with self.assertRaisesRegex(ValueError,'startup binding'):views.verify(self.channel)
 def test_startup_other_edits_preserved(self):
  p=self.project/'dllmain.cpp';p.write_text(p.read_text(encoding='utf-8')+'\n// unrelated newer source stays intact\n',encoding='utf-8');before=p.read_bytes();views.verify(self.channel)
  self.assertEqual(before,p.read_bytes())
 def test_nr_controls_not_lost_or_rebound(self):
  views.verify(self.channel)
  new=(PROJECT/'dlssnr/DlssNrPanel.inl').read_text(encoding='utf-8')+''.join(p.read_text(encoding='utf-8') for p in (self.project/'dlssnr/reconstruction').glob('*.inl'))
  self.assertTrue(set(self.contract['nr_required_fields'])<=set(re.findall(r'config->(\w+)',new)))
  self.assertIn('DeferredSlider("##NR strength",&config->DlssNrIntensity',new)
  draft=(PROJECT/'dlssnr/NrSettingsDraft.h').read_text(encoding='utf-8-sig')
  self.assertNotIn('review.Bind("Enable for this session"',draft)
  # Session enable is a direct runtime action; tuning remains previewable and saveable.
  self.assertIn('config->DlssNrEnabled=liveConfig->DlssNrEnabled',new)
  self.assertIn('config->DlssNrEnabled=value',new);self.assertIn('DlssNr::SetEnabled(value,"in-game-panel")',new)
  self.assertIn('edits.review.Preview()',new)
  self.assertIn('edits.review.Apply()',new)
  for member in ('style','autoMask','intensity','structure','tone','skin'):self.assertIn('d.'+member+',',draft)
  self.assertEqual(new.count('if(ImGui::Combo("##NR look"'),1)
 def test_single_nr_owner_and_owner_requested_sidebar(self):
  views.verify(self.channel);main=(self.project/'menu/menu_common.cpp').read_text(encoding='utf-8');panel=(PROJECT/'menu/OptiShadePanel.inl').read_text(encoding='utf-8')
  self.assertNotIn('void MenuCommon::RenderMainMenuWindow(RenderMenuContext& ctx)',main)
  self.assertEqual(panel.count('DlssNr::RenderMenu('),1);self.assertEqual(panel.count('optishade::panel::ShellHeader('),1);self.assertEqual(panel.count('optishade::panel::BeginSidebarPage(page,true)'),1);self.assertEqual(panel.count('optishade::panel::EndSidebarPage()'),1)
  nav=(CHANNEL/'shared/PanelUi.h').read_text(encoding='utf-8-sig')
  self.assertIn('"Performance","Neural rendering","Image effects","Glass cockpit","Monitoring","Settings & status"',nav)
  self.assertIn('if(page==6)page=0;',nav);self.assertNotIn('OptiShadeMfgUI::DrawOptiMfgPage()',panel);self.assertNotIn('simpleMode',panel)
 def test_performance_preserves_external_owner_and_promotes_mfg(self):
  views.verify(self.channel);text=(self.project/'menu/reconstruction/Performance.inl').read_text(encoding='utf-8')
  self.assertIn('OptiShadeMfgUI::DrawFrameGeneration()',text)
  self.assertNotIn('CollapsingHeader("Frame generation options")',text)
  self.assertIn('backendEvidence.active = optishade::Evidence::Unknown',text)
 def test_fps_fragment_has_own_size_tables(self):
  text=(self.project/'menu/reconstruction/FpsPreferences.inl').read_text(encoding='utf-8')
  self.assertIn('const char* sizeNames[]=',text);self.assertIn('const float sizeValues[]=',text)
 def test_fg_settings_do_not_load_or_replace_provider(self):
  text=(self.project/'menu/menu_common.cpp').read_text(encoding='utf-8')
  start=text.index('void MenuCommon::RenderFrameGenerationSelection(')
  end=text.index('void MenuCommon::',start+10)
  section=text[start:end]
  self.assertNotIn('InitFfxDx12(',section);self.assertNotIn('InitXeFG(',text)
  self.assertNotRegex(section,r'state\.activeFg(?:Input|Output|Nvngx)\s*=(?!=)')
  self.assertNotIn('FGNvngxReplacement.set_volatile_value(',section)
  self.assertNotIn('FfxApiProxy::IsFGReady()',text)
 def test_effect_operations_retained_and_vertical(self):
  text=(self.project/'menu/optishade_effects_ui.inl').read_text(encoding='utf-8')
  for item in ['Save a copy...','Save your look','FX LIBRARY','Preset tools & advanced shader options','This look (','All installed (','Look editor selected effect','Reset to saved','optishade::effects_ui::Numeric("value"','u.uiKind==osfx::UiCombo']:self.assertIn(item,text)
  bridge=(CHANNEL/'reshade/source/optishade_effects_bridge.inl').read_text(encoding='utf-8')
  abi=(CHANNEL/'shared/EffectsBridge.h').read_text(encoding='utf-8')
  self.assertIn('"ui_type"',bridge);self.assertIn('"ui_items"',bridge);self.assertIn('Version=15',abi)
  self.assertIn('command.editRequest=++nextEditRequest',text);self.assertIn('pendingUniformEdits[command.editRequest]',text)
  self.assertIn('ReadUniformEditAcks();',text);self.assertIn('editAcks.entries[sequence%osfx::EditAckCapacity]',text)
  self.assertIn('snapshot.editAcks.record(c.editRequest,osfx::EditResultApplied',bridge)
  self.assertIn('snapshot.editAcks.record(c.editRequest,editFailure',bridge)
  self.assertIn('ImGui::BeginDisabled(fx.loading||zipProcess!=nullptr||fx.performanceMode);',text)
  self.assertIn('ui_tooltip',bridge);self.assertIn('inspectedDescription',abi)
  panel=(self.project/'menu/OptiShadePanel.inl').read_text(encoding='utf-8')
  self.assertIn('OptiShadeLookEditorR30',panel);self.assertIn('ImGuiCond_FirstUseEver,ImVec2(.5f,.5f)',panel)
  for item in ['DrawFxGlyph','DrawSearchGlyph','DrawFilterGlyph','FavoriteButton','FX library filters','File information','Reset to saved']:
   self.assertIn(item,text)
  self.assertIn('Save as...',(self.project/'menu/OptiShadePanel.inl').read_text(encoding='utf-8'))
  self.assertNotIn('ImVec2(width*.45f,0)',text)
 def test_active_fx_uniforms_remain_editable(self):
  text=(self.project/'menu/optishade_effects_ui.inl').read_text(encoding='utf-8')
  start=text.index('static void DrawLookEditor(')
  end=text.index('static void DrawEffects(',start)
  editor=text[start:end]
  self.assertIn('You can edit settings while this FX is enabled; changes apply live.',editor)
  self.assertIn('ImGui::BeginDisabled(fx.loading||zipProcess!=nullptr||fx.performanceMode);',editor)
  self.assertNotIn('ImGui::BeginDisabled(on',editor)
  self.assertNotIn('ImGui::BeginDisabled(activeEffects',editor)
  bridge=(CHANNEL/'reshade/source/optishade_effects_bridge.inl').read_text(encoding='utf-8')
  start=bridge.index('static bool ApplyEdit(')
  end=bridge.index('static bool Ready(',start)
  apply=bridge[start:end]
  uniform=apply[apply.index('case osfx::Uniform:'):apply.index('default:',apply.index('case osfx::Uniform:'))]
  self.assertIn('runtime->set_uniform_value_float(u,c.value,n,c.arrayIndex)',uniform)
  self.assertIn('runtime->set_uniform_value_int(u,c.signedValue,n,c.arrayIndex)',uniform)
  self.assertIn('runtime->set_uniform_value_uint(u,c.unsignedValue,n,c.arrayIndex)',uniform)
  self.assertNotIn('get_technique_state',uniform)
 def test_startup_wait_does_not_discard_requested_overlay_menu(self):
  panel=(self.project/'menu/OptiShadePanel.inl').read_text(encoding='utf-8')
  self.assertIn('OptiShadeUI::DrawStartup(_isVisible);',panel)
  self.assertNotIn('if(!OptiShadeUI::DrawStartup(_isVisible)){_isVisible=false;return;}',panel)
 def test_scaled_taa_depth_is_shared_by_renderers(self):
  helper=(CHANNEL/'shared/GuideExtent.h').read_text(encoding='utf-8')
  shader=(CHANNEL/'reshade/res/shaders/optishade_guides.hlsl').read_text(encoding='utf-8')
  core=(CHANNEL/'reshade/source/optishade_core_guides.inl').read_text(encoding='utf-8')
  taa=(CHANNEL/'reshade/source/optishade_taa_bridge.inl').read_text(encoding='utf-8')
  vulkan=(CHANNEL/'reshade/source/optishade_vulkan_nr.inl').read_text(encoding='utf-8')
  self.assertIn('CompatibleDepthExtent',helper)
  self.assertIn('sourcePixel=',shader);self.assertIn('depthWidth, depthHeight',shader)
  for source in (taa,vulkan):self.assertIn('CompatibleDepthExtent',source)
  adapter=(CHANNEL/'reshade/source/optishade_format_view.inl').read_text(encoding='utf-8')
  contract=(CHANNEL/'shared/FormatViewContract.h').read_text(encoding='utf-8')
  self.assertIn('optishade_format_view.inl',core);self.assertIn('osformat::Inspect(',core)
  self.assertIn('fv::CoreGuideReason(',adapter);self.assertIn('guides::CompatibleDepthExtent(',contract)
 def test_source_escape_refused(self):
  contract=self.channel/'reconstruction/native-view-contract.json';data=json.loads(contract.read_text());data['files'][0]['source']='../../../../outside.cpp';contract.write_text(json.dumps(data))
  with self.assertRaisesRegex(ValueError,'escapes project'):views.verify(self.channel)
 def test_shader_no_fake_fps_or_prototype_import(self):
  text=(PROJECT/'menu/OptiShadePanel.inl').read_text(encoding='utf-8')
  for forbidden in ['WebView','localhost:','165 FPS','192 FPS','prototype.html']:self.assertNotIn(forbidden,text)
 def test_build_compiles_canonical_units_once(self):
  views.verify(self.channel)
  targets=(self.channel/'reconstruction/OptiShade.Reconstruction.targets').read_text(encoding='utf-8')
  self.assertNotIn('<ClCompile Remove=',targets);self.assertNotIn('generate_views.py',targets)
  self.assertIn('check_source_provider.py',targets)
 def test_duplicate_compile_entry_refused(self):
  p=self.project/'OptiScaler.vcxproj';s=p.read_text(encoding='utf-8-sig');s=s.replace('<ClCompile Include="dllmain.cpp" />','<ClCompile Include="dllmain.cpp" /><ClCompile Include="dllmain.cpp" />');p.write_text(s,encoding='utf-8')
  with self.assertRaisesRegex(ValueError,'compile count'):views.verify(self.channel)

class Sm86MfgRoute(unittest.TestCase):
 def test_x86_effects_only_route_keeps_the_reshade_editor_available(self):
  gui=(CHANNEL/'reshade/source/runtime_gui.cpp').read_text(encoding='utf-8')
  draw=gui[gui.index('void reshade::runtime::draw_gui()'):]
  self.assertIn('#if defined(_WIN64)',draw)
  self.assertIn('if (!glassPanel) { oscockpit::Missing(); _show_overlay = false; return; }',draw)
  self.assertIn('#else\n    // The x86 package uses ReShade\'s architecture-matched hook for its branded',draw)
  self.assertIn('const bool cockpitPoll = false;',draw)
  self.assertIn('ReShade32.dll', (CHANNEL/'package.ps1').read_text(encoding='utf-8'))

 def test_rtx20_30_use_the_pinned_upstream_route_without_packaging_the_binary(self):
  policy=json.loads((CHANNEL/'shared/provider-policy.json').read_text(encoding='utf-8'))
  for channel in ('stable','beta'):
   self.assertEqual(policy['channels'][channel]['20'],'sm86')
   self.assertEqual(policy['channels'][channel]['30'],'sm86')
  self.assertEqual(policy['channels']['stable']['40'],'legacy')
  self.assertEqual(policy['channels']['beta']['40'],'source')
  self.assertEqual(policy['channels']['stable']['50'],'native')
  installer=(CHANNEL/'installer/sm86-mfg.ps1').read_text(encoding='utf-8-sig')
  self.assertIn("Version='0.4.0'",installer)
  self.assertIn('5865360C3295038F0FF979D303BB7EB9437EEC09FBC08686967D3B5D41D9C019',installer)
  self.assertIn('External\' \'true\'',installer)
  self.assertIn('AmpereMfgUnlock\' \'true\'',installer)
  self.assertIn('OptiShadeData/Engine/dlssg_sm86/dlssg_sm86.dll',installer)
  self.assertIn('The SM86 provider must be hosted by OptiScaler',installer)
  self.assertNotIn('MaxGeneratedFrames=',installer)
  hosted=(PROJECT/'framegen/dlssg/AmpereMfgLoader.cpp').read_text(encoding='utf-8-sig')
  self.assertIn('basePath / L"OptiShadeData" / L"Engine" / L"dlssg_sm86" / L"dlssg_sm86.dll"',hosted)
  main=(CHANNEL/'installer/public_bundle.go').read_text(encoding='utf-8')
  self.assertIn('sm86-mfg.ps1',main)
  self.assertNotIn('dlssg-release-0.4.0-x64.zip',main)
 def test_dlssg_capabilities_come_from_the_games_thread_affine_state_callback(self):
  query=(PROJECT/'hooks/NativeFgStateQueryLock.h').read_text(encoding='utf-8')
  self.assertNotIn('std::mutex',query)
  self.assertIn('return call();',query)
  self.assertIn('synchronization must remain with the host integration',query)
  self.assertIn('QueryNativeStateOnce',query)
  self.assertIn('InvokeProviderCallDirect',query)
  dx12=(PROJECT/'framegen/dlssg/DLSSG_Dx12.cpp').read_text(encoding='utf-8')
  self.assertNotIn('native_mfg::QueryNativeStateOnce(',dx12)
  self.assertNotIn('StreamlineProxy::DLSSGGetState()(',dx12)
  self.assertNotIn('_reportedCapabilities.Reset()',dx12)
  self.assertIn('State::Instance().dlssgCapabilities.Read()',dx12)
  self.assertIn('GetMaxInterpolationCount() const',dx12)
  state=(PROJECT/'State.h').read_text(encoding='utf-8')
  self.assertIn('CapabilityCache dlssgCapabilities',state)
  hooks=(PROJECT/'hooks/Streamline_Hooks.cpp').read_text(encoding='utf-8')
  init=hooks[hooks.index('sl::Result StreamlineHooks::hkslInit('):hooks.index('sl::Result StreamlineHooks::hkslIsFeatureSupported(')]
  self.assertIn('dlssgCapabilities.Reset()',init)
  managed=hooks[hooks.index('sl::Result StreamlineHooks::hkslDLSSGGetState'):hooks.index('bool StreamlineHooks::hkreflex_slOnPluginLoad')]
  self.assertIn('optiState.dlssgCapabilities.Observe(',managed)
  self.assertIn('evidence.maximum,evidence.dynamicKnown',managed)
  self.assertIn('evidence.maximum,static_cast<uint32_t>(viewport),evidence.dynamicKnown',managed)
  self.assertLess(managed.index('optiState.dlssgCapabilities.Observe('),managed.index('if(evidence.dynamicKnown)'))
  cache_response=managed.index('PopulateCachedCapabilityState(')
  self.assertIn('Cached capability served after contained provider fault',managed)
  self.assertIn('Cached capability served after contained GetState fault',managed)
  rejected_response=managed.index('persistStateCall(reason,"eErrorFeatureMissing")')
  self.assertLess(cache_response,rejected_response)
  query_helper=(CHANNEL/'shared/NativeFgStateQuery.h').read_text(encoding='utf-8')
  cached_helper=query_helper[query_helper.index('inline bool PopulateCachedCapabilityState'):query_helper.index('// Managed input emulation')]
  self.assertIn('snapshot.viewport!=viewport',cached_helper)
  self.assertIn('caller.numFramesActuallyPresented=0',cached_helper)
  self.assertIn('caller.inputsProcessingCompletionFence=nullptr',cached_helper)
  self.assertIn('caller.lastPresentInputsProcessingCompletionFenceValue=0',cached_helper)

 def test_all_dlss_getstate_routes_contain_provider_access_violations(self):
  guard=(PROJECT/'hooks/SafeDlssGetState.h').read_text(encoding='utf-8')
  self.assertIn('EXCEPTION_ACCESS_VIOLATION',guard)
  self.assertIn('eErrorExceptionHandler',guard)
  self.assertIn('faultLatch->store(true',guard)
  self.assertIn('suppressedAfterFault=true',guard)
  hooks=(PROJECT/'hooks/Streamline_Hooks.cpp').read_text(encoding='utf-8')
  managed=hooks[hooks.index('sl::Result StreamlineHooks::hkslDLSSGGetState'):hooks.index('bool StreamlineHooks::hkreflex_slOnPluginLoad')]
  self.assertIn('dlssgStateProviderFaulted.load',managed)
  self.assertIn('InvokeGetStateGuarded(o_slDLSSGGetState',managed)
  self.assertIn('Provider access violation contained',managed)
  self.assertIn('Provider query disabled after contained fault',managed)
  passive=hooks[hooks.index('sl::Result StreamlineHooks::PassiveState'):hooks.index('sl::Result StreamlineHooks::ExternalState')]
  external=hooks[hooks.index('sl::Result StreamlineHooks::ExternalState'):hooks.index('void StreamlineHooks::ExternalPrepare')]
  self.assertIn('InvokeGetStateGuarded(target.function',passive)
  self.assertIn('InvokeGetStateGuarded(target.function',external)
  self.assertIn('RecordDlssGStateProviderFault',passive)
  self.assertIn('RecordDlssGStateProviderFault',external)
  self.assertIn('FGStateProviderExceptionAddress',hooks)
  self.assertIn('FGStateProviderAccessOperation',hooks)
  self.assertIn('FGStateProviderFaultAddress',hooks)
  self.assertIn('PutResolvedProviderCall',hooks)
  journal=(CHANNEL/'shared/LastSession.h').read_text(encoding='utf-8')
  self.assertIn('void PutResolvedProviderCall(',journal)
  self.assertIn('lastPersistedProviderCallPending',journal)
  self.assertIn('FGStateProviderFaulted',journal)
  self.assertIn('FGStateProviderExceptionCode',journal)
  for key in ('FGStateProviderExceptionAddress','FGStateProviderAccessOperation','FGStateProviderFaultAddress'):
   self.assertIn(key,journal)

 def test_selected_imported_look_is_persisted_as_the_next_reshade_preset(self):
  bridge=(ROOT/'Beta/reshade/source/optishade_effects_bridge.inl').read_text(encoding='utf-8-sig')
  preset=bridge[bridge.index('case osfx::Preset:'):bridge.index('case osfx::Technique:',bridge.index('case osfx::Preset:'))]
  self.assertIn('std::filesystem::is_regular_file(path,ec)',preset)
  self.assertIn('runtime->set_current_preset_path(c.path)',preset)
  api=(ROOT/'Beta/reshade/source/runtime_api.cpp').read_text(encoding='utf-8-sig')
  setter=api[api.index('void reshade::runtime::set_current_preset_path('):api.index('\nvoid reshade::runtime::reorder_techniques',api.index('void reshade::runtime::set_current_preset_path('))]
  self.assertIn('_current_preset_path = std::move(preset_path);',setter)
  self.assertIn('save_config();',setter)
  config=(ROOT/'Beta/reshade/source/runtime.cpp').read_text(encoding='utf-8-sig')
  self.assertIn('config.set("GENERAL", "PresetPath", make_relative_path(_current_preset_path));',config)

 def test_existing_ui_controls_forward_live_external_streamline_requests(self):
  hooks=(PROJECT/'hooks/Streamline_Hooks.cpp').read_text(encoding='utf-8')
  external=hooks[hooks.index('sl::Result StreamlineHooks::ExternalOptions'):hooks.index('sl::Result StreamlineHooks::ExternalState')]
  self.assertIn('control.ForCall(target.NativeIdentity()',external)
  self.assertIn('changed.numFramesToGenerate=static_cast<uint32_t>(request.desired)',external)
  self.assertIn('request.desired>0&&request.desired<=int(request.maximum)',external)
  self.assertNotIn('else if(options.mode!=sl::DLSSGMode::eOff)',external)
  self.assertIn('InvokeProviderCallDirect([&]{return target.function(view,*sent);})',external)
  self.assertIn('dlssgStateProviderFaulted.load(std::memory_order_acquire)',external)
  self.assertIn('CopyKnownDlssgOptions(options,changed)',external)
  self.assertIn('eErrorInvalidParameter',external)
  self.assertIn('RecordAcceptedOptions',external)
  self.assertIn('FGOptionsMaxAcceptedAdditionalFramesThisRun',external)
  state=hooks[hooks.index('sl::Result StreamlineHooks::ExternalState'):hooks.index('void StreamlineHooks::ExternalPrepare')]
  self.assertIn('Session().Observe(target.NativeIdentity()',state)
  self.assertIn('QueryNativeStateOnce(guardedProviderCall,identity!=0,view,state,options,evidence,1)',state)
  self.assertIn('InvokeGetStateGuarded(target.function',state)
  self.assertIn('&dlssgStateProviderFaulted',state)
  self.assertIn('RecordStateSample(evidence.providerFramesPresented)',state)
  self.assertIn('result==sl::Result::eOk&&evidence.stateKnown',state)
  self.assertIn('Provider-reported presentation count only; scanout not observed',state)
  self.assertIn('RecordStateCall(GetCurrentThreadId(),GetTickCount64())',state)
  self.assertLess(state.index('PutCritical(values)'),state.index('QueryNativeStateOnce(guardedProviderCall'))
  self.assertIn('Provider call pending',state)
  self.assertIn('FGPresentSwapchainId',state)
  self.assertIn('Streamline provider Present boundary',state)
  self.assertIn('FGStateCallerThreadId',state)
  self.assertIn('DlssgCallerSite(_ReturnAddress())',state)
  self.assertIn('FGStateCallerModule',state)
  self.assertIn('FGStateCallerModuleOffset',state)
  self.assertIn('FGStateThreadMatchesLastPresent',state)
  self.assertIn('FGStateIntervalMs',state)
  managed=hooks[hooks.index('sl::Result StreamlineHooks::hkslDLSSGGetState'):hooks.index('bool StreamlineHooks::hkreflex_slOnPluginLoad')]
  self.assertIn('RecordStateCall(GetCurrentThreadId(),GetTickCount64())',managed)
  self.assertLess(managed.index('persistStateCall("Provider call pending"'),managed.index('QueryNativeStateOnce('))
  self.assertIn('OptiScaler primary game swapchain Present',managed)
  self.assertIn('FGStateThreadMatchesLastPresent',managed)
  self.assertIn('DlssgCallerSite(_ReturnAddress())',managed)
  self.assertIn('FGStateCallerModule',managed)
  self.assertIn('FGStateCallerModuleOffset',managed)
  self.assertIn('persistStateCall("Provider call completed"',managed)
  present=hooks[hooks.index('void StreamlineHooks::NativeProviderPresentBegin('):hooks.index('void StreamlineHooks::NativeProviderPresentEnd(')]
  self.assertIn('Session().RecordPresentCall(',present)
  self.assertIn('GetCurrentThreadId(),GetTickCount64(),reinterpret_cast<uintptr_t>(swap)',present)
  self.assertIn('FGPresentCallerThreadId',present)
  self.assertIn('FGPresentCallCount',present)
  wrapped=(ROOT/'Beta/optiscaler/OptiScaler/wrapped/wrapped_swapchain.cpp').read_text(encoding='utf-8-sig')
  local_present=wrapped[wrapped.index('static HRESULT LocalPresent('):wrapped.index('HRESULT STDMETHODCALLTYPE WrappedIDXGISwapChain4::Present(')]
  self.assertIn('Session().RecordPresentCall(',local_present)
  self.assertIn('GetCurrentThreadId(), GetTickCount64(), reinterpret_cast<uintptr_t>(pSwapChain)',local_present)
  self.assertIn('DXGI_PRESENT_TEST',local_present)
  self.assertIn('if ((Flags & DXGI_PRESENT_TEST) == 0)',local_present)
  self.assertNotIn('ExternalFgObserver()',local_present)
  self.assertNotIn('Unrecognised provider; no native override',state)
  query=(ROOT/'Beta/shared/NativeFgStateQuery.h').read_text(encoding='utf-8-sig')
  body=query[query.index('sl::Result QueryNativeState('):query.index('\n}\n}',query.index('sl::Result QueryNativeState('))+2]
  self.assertIn('const auto result=call(view,caller,options);',body)
  self.assertEqual(body.count('call(view,'),1)
  self.assertNotIn('extended',body)
  self.assertNotIn('retry',body.lower())
  self.assertIn('if(result!=sl::Result::eOk&&known)CopyStateOutputs(original,caller);',body)
  self.assertIn('CopyStateOutputs(caller,original);',body)
  journal=(ROOT/'Beta/shared/LastSession.h').read_text(encoding='utf-8-sig')
  persisted=journal[journal.index('std::string state;'):journal.index('std::string json=',journal.index('std::string state;'))]
  for key in ('FGStateQueryStage','FGStateResult','FGStateCallerModule','FGStateCallerModuleOffset','FGStateCallerThreadId','FGStateQueryCount','FGStateIntervalMs','FGStateAgeSincePresentMs','FGPresentSampleSource','FGPresentCallerThreadId','FGPresentSwapchainId','FGStateThreadMatchesLastPresent','FGPresentCallCount','FGPresentCallCountAtStateQuery','XP12VulkanPresentQueue','XP12VulkanPresentWaitCount','XP12VulkanPresentWaitHandles','XP12VulkanPresentWaitHandlesCaptured','XP12VulkanPresentWaitHandlesTruncated','XP12VulkanPresentSwapchainCount','XP12VulkanPresentImages','XP12VulkanPresentResults','XP12VulkanPresentGlobalResult','XP12VulkanPresentPerResultsKnown','XP12VulkanPresentHasPNext','XP12VulkanPresentTruncated','XP12VulkanPresentSnapshotValid','XP12VulkanAcquireApi','XP12VulkanAcquireResult','XP12VulkanAcquireDevice','XP12VulkanAcquireSwapchain','XP12VulkanAcquireTimeout','XP12VulkanAcquireSemaphore','XP12VulkanAcquireFence','XP12VulkanAcquireDeviceMask','XP12VulkanAcquireHasPNext','XP12VulkanAcquireImageIndexValid','XP12VulkanAcquireImageIndex'):
   self.assertIn(key,persisted)
  diagnostics=(CHANNEL/'installer/diagnostics.ps1').read_text(encoding='utf-8-sig')
  session_filter=diagnostics[diagnostics.index('function GetSafeLastSessionSnapshot'):diagnostics.index('function GetDiagnosticContext')]
  for key in ('FGStateQueryStage','FGStateResult','FGStateCallerModule','FGStateCallerModuleOffset','FGStateCallerThreadId','FGStateQueryCount','FGStateIntervalMs','FGStateAgeSincePresentMs','FGPresentSampleSource','FGPresentCallerThreadId','FGPresentSwapchainId','FGStateThreadMatchesLastPresent','FGPresentCallCount','FGPresentCallCountAtStateQuery','XP12VulkanPresentQueue','XP12VulkanPresentWaitCount','XP12VulkanPresentWaitHandles','XP12VulkanPresentWaitHandlesCaptured','XP12VulkanPresentWaitHandlesTruncated','XP12VulkanPresentSwapchainCount','XP12VulkanPresentImages','XP12VulkanPresentResults','XP12VulkanPresentGlobalResult','XP12VulkanPresentPerResultsKnown','XP12VulkanPresentHasPNext','XP12VulkanPresentTruncated','XP12VulkanPresentSnapshotValid','XP12VulkanAcquireApi','XP12VulkanAcquireResult','XP12VulkanAcquireDevice','XP12VulkanAcquireSwapchain','XP12VulkanAcquireTimeout','XP12VulkanAcquireSemaphore','XP12VulkanAcquireFence','XP12VulkanAcquireDeviceMask','XP12VulkanAcquireHasPNext','XP12VulkanAcquireImageIndexValid','XP12VulkanAcquireImageIndex'):
   self.assertIn(key,session_filter)
  for key in ('FGStateProviderFaulted','FGStateProviderExceptionCode','FGStateProviderExceptionAddress','FGStateProviderAccessOperation','FGStateProviderFaultAddress'):
   self.assertIn(key,session_filter)
  self.assertIn('$value.Length -le 512',session_filter)
  self.assertIn('GetSafeLastSessionSnapshot $saved',diagnostics)
  self.assertIn('function GetAutomaticCaptureSessionCorrelation',diagnostics)
  self.assertIn('$report.AutomaticCapture.SessionCorrelation=',diagnostics)
  self.assertIn('does not prove time-window overlap or displayed output',diagnostics)
  ui=(PROJECT/'menu/optishade_mfg_ui.inl').read_text(encoding='utf-8')
  native=ui[ui.index('static void DrawNative(API api)'):]
  self.assertIn('generated<=int(s.maximum)',native)
  self.assertIn('active game provider',native)
 def test_mfg_ui_stages_save_go_and_applies_native_requests_live(self):
  ui=(PROJECT/'menu/optishade_mfg_ui.inl').read_text(encoding='utf-8')
  compatibility=ui[ui.index('static bool Draw(bool supported)'):ui.index('namespace OptiShadeMfgUI {',ui.index('static bool Draw(bool supported)'))]
  self.assertIn('OptiShade MFG override',compatibility)
  self.assertIn('Changes staged. Save to apply them to the running game.',compatibility)
  self.assertNotIn('Save(supported);',compatibility)
  native=ui[ui.index('static void DrawNative(API api)'):]
  self.assertIn('nativePanel.Stage(s,generated)',native)
  self.assertIn('nativePanel.StagePending(s,generated)',native)
  self.assertIn('ToggleEnabled(available,nativePanel.initialized,nativePanel.desired,s.acceptedGenerated,nativePanel.dynamic,nativePanel.pendingProvider)',native)
  self.assertIn('const bool canStageProbe=',native)
  self.assertIn('CanStageInitialRequest(',native)
  stage_gate=native[native.index('const bool canStageProbe='):native.index('const bool canStagePending=')]
  self.assertNotIn('alternateOutputOwns',stage_gate)
  self.assertNotIn('backend->state.owned',stage_gate)
  self.assertIn('OFF staged; use Save & Go below to apply it to the running game.',native)
  self.assertIn('ON staged; choose a multiplier, then use Save & Go below.',native)
  self.assertIn('nativePanel.Submit(control,snapshot)',native)
  self.assertIn('StreamlineHooks::updateDlssgOptions()',native)
  self.assertIn('alternateOutputOwns',native)
  self.assertNotIn('Session().Request(s,generated)',native)
  self.assertIn("Turn ON, choose a multiplier, then Save & Go.",native)
  menu=(PROJECT/'hooks/Streamline_Hooks.cpp').read_text(encoding='utf-8')
  set_options=menu[menu.index('sl::Result StreamlineHooks::hkslDLSSGSetOptions'):menu.index('sl::Result StreamlineHooks::hkslDLSSGGetState')]
  get_state=menu[menu.index('sl::Result StreamlineHooks::hkslDLSSGGetState'):menu.index('bool StreamlineHooks::hkreflex_slOnPluginLoad')]
  self.assertIn('nativeControl.ForCall(nativeProvider',set_options)
  self.assertIn('Session().Complete(nativeRequest',set_options)
  self.assertIn('RecordManagedDlssgOptions(options,newOptions,result,nativeRequest,explicitNativeRequest',set_options)
  options_diagnostics=menu[menu.index('static void RecordManagedDlssgOptions('):menu.index('static void RecordDlssGStateProviderFault(')]
  self.assertIn('FGSetOptionsInputAdditionalFrames',options_diagnostics)
  self.assertIn('FGSetOptionsForwardedAdditionalFrames',options_diagnostics)
  self.assertIn('FGSetOptionsProviderResult',options_diagnostics)
  self.assertIn('now - recorder.lastPersistMs >= 30000',options_diagnostics)
  self.assertIn('zero generated frames',options_diagnostics)
  self.assertIn('Session().Observe(identity',get_state)
  self.assertIn('CopyKnownDlssgOptions(options,newOptions)',set_options)
  self.assertNotIn('lastDlssgOptions',menu)
  state=(PROJECT/'menu/native_mfg_ui_state.h').read_text(encoding='utf-8')
  self.assertIn('CanStageInitialRequest(bool providerAvailable,bool initialized,',state)
  control=(PROJECT.parents[1]/'shared/NativeMfgControl.h').read_text(encoding='utf-8')
  pending=control[control.index('bool StagePending('):control.index('bool Submit(',control.index('bool StagePending('))]
  pending_code='\n'.join(line.split('//',1)[0] for line in pending.splitlines())
  self.assertNotIn('Observe(state)',pending_code)
  self.assertNotIn('Control::Fresh(state)',pending_code)
  self.assertIn('nothing is sent until then',pending)
  update=menu[menu.index('void StreamlineHooks::updateDlssgOptions()'):menu.index('void StreamlineHooks::applyMenuDlssgInterlock')]
  self.assertNotIn('hkslDLSSGSetOptions(',update)
  self.assertIn('next game-owned SetOptions callback',update)
  panel=(PROJECT/'menu/OptiShadePanel.inl').read_text(encoding='utf-8')
  self.assertIn('ChooseFooterAction',panel)
  self.assertIn('footerAction.saveLabel',panel)
 def test_sm86_diagnostics_are_bounded_and_do_not_claim_rendered_output(self):
  diagnostics=(CHANNEL/'installer/diagnostics.ps1').read_text(encoding='utf-8-sig')
  self.assertIn("Provider='Pinned upstream DLSSG for SM86 (OptiScaler-hosted experiment)'",diagnostics)
  self.assertIn("Select-Object -First 4",diagnostics)
  self.assertIn('ReadDiagnosticTail $file.FullName 65536',diagnostics)
  self.assertIn('do not prove that generated frames reached the display',diagnostics)

class ProviderGuard(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.channel=Path(self.temp.name)/'Beta';self.root=self.channel/'installer/OptionalMFG';self.source=self.root/'Source203040'
  self.source.mkdir(parents=True);(self.channel/'shared').mkdir();(self.source/'provider.cpp').write_bytes(b'// reviewed provider\n')
  (self.root/'OptiShadeMFG.dll').write_bytes(b'TEST FIXTURE, NOT A DLL');self.symbols=Path(self.temp.name)/'test.pdb';self.symbols.write_bytes(b'TEST FIXTURE, NOT A PDB')
  self.sdk=Path(self.temp.name)/'sdk';self.sdk.mkdir();(self.sdk/'header.h').write_bytes(b'// fake header\n')
  self.runtime_group={'streamlineVersion':'2.14.16','streamlineArchiveSha256':'a'*64,'dlssgVersion':'310.9.16.0','dlssgSha256':'b'*64}
  (self.channel/'installer').mkdir(parents=True,exist_ok=True)
  (self.channel/'installer/streamline-files.json').write_text(json.dumps({'version':'2.14.16','archiveSha256':'a'*64}))
  (self.channel/'installer/nvidia-files.json').write_text(json.dumps([{'Name':'nvngx_dlssg.dll','Version':'310.9.16.0','SHA256':'b'*64}]))
  self.manifest={'schema':1,'abi':131072,'sha256':sha((self.root/'OptiShadeMFG.dll').read_bytes()),'RuntimeGroup':self.runtime_group,'SourceFiles':{'provider.cpp':sha((self.source/'provider.cpp').read_bytes())},'SymbolsSHA256':sha(self.symbols.read_bytes()),'SdkHeaders':{'header.h':sha((self.sdk/'header.h').read_bytes())}}
  self.save();pin=self.manifest['sha256'];(self.channel/'shared/SourceMfgIdentity.h').write_text(f'char kSourceDllSha256[]="{pin}";');(self.channel/'installer/mfg.ps1').write_text(f'$script:SourceMfgSha256="{pin}"')
 def save(self):(self.root/'source-build.json').write_text(json.dumps(self.manifest))
 def tearDown(self):self.temp.cleanup()
 def test_exact_inputs_accepted_without_hardware_claim(self):
  result=guard.verify(self.channel,self.symbols,self.sdk);self.assertEqual(result['source_files_verified'],1);self.assertIn('not performed',result['hardware_validation']);self.assertEqual(result['symbols'],'matching PDB bytes verified')
 def test_changed_source_rejected(self):
  (self.source/'provider.cpp').write_bytes(b'// changed\n')
  with self.assertRaisesRegex(ValueError,'Stale MFG'):guard.verify(self.channel)
 def test_new_source_requires_rebuild(self):
  (self.source/'new.cpp').write_bytes(b'new')
  with self.assertRaisesRegex(ValueError,'inventory changed'):guard.verify(self.channel)
 def test_changed_dll_rejected(self):
  (self.root/'OptiShadeMFG.dll').write_bytes(b'wrong')
  with self.assertRaisesRegex(ValueError,'Provider DLL differs'):guard.verify(self.channel)
 def test_changed_runtime_pin_rejected(self):
  (self.channel/'shared/SourceMfgIdentity.h').write_text('missing')
  with self.assertRaisesRegex(ValueError,'Runtime/provider'):guard.verify(self.channel)
 def test_changed_installer_pin_rejected(self):
  (self.channel/'installer/mfg.ps1').write_text('missing')
  with self.assertRaisesRegex(ValueError,'Installer/provider'):guard.verify(self.channel)
 def test_wrong_pdb_rejected(self):
  self.symbols.write_bytes(b'wrong')
  with self.assertRaisesRegex(ValueError,'PDB does not match'):guard.verify(self.channel,self.symbols)
 def test_wrong_sdk_rejected(self):
  (self.sdk/'header.h').write_bytes(b'wrong')
  with self.assertRaisesRegex(ValueError,'SDK header changed'):guard.verify(self.channel,None,self.sdk)
 def test_runtime_group_mismatch_rejected(self):
  runtime=json.loads((self.channel/'installer/streamline-files.json').read_text());runtime['version']='2.15.0';(self.channel/'installer/streamline-files.json').write_text(json.dumps(runtime))
  with self.assertRaisesRegex(ValueError,'compatibility group mismatch'):guard.verify(self.channel)
 def test_missing_runtime_group_rejected(self):
  self.manifest.pop('RuntimeGroup');self.save()
  with self.assertRaisesRegex(ValueError,'compatibility-group receipt is missing'):guard.verify(self.channel)
 def test_duplicate_manifest_keys_rejected(self):
  (self.root/'source-build.json').write_text('{"schema":1,"schema":2}')
  with self.assertRaisesRegex(ValueError,'Duplicate'):guard.verify(self.channel)
 def test_path_escape_rejected(self):
  self.manifest['SourceFiles']={'../escape':sha(b'')};self.save()
  with self.assertRaisesRegex(ValueError,'Invalid recorded source path'):guard.verify(self.channel)
 def test_unprovided_symbols_not_certified(self):
  result=guard.verify(self.channel);self.assertIn('not supplied',result['symbols']);self.assertIn('not supplied',result['sdk'])

class MfgRuntimeCompatibilityGroup(unittest.TestCase):
 def test_provider_rebuild_and_package_share_the_exact_runtime_group(self):
  build=(CHANNEL/'installer/OptionalMFG/build-source203040.ps1').read_text(encoding='utf-8-sig')
  package=(CHANNEL/'package.ps1').read_text(encoding='utf-8-sig')
  self.assertIn("installer/streamline-files.json",build)
  self.assertIn("SL_VERSION_$part",build)
  self.assertIn("streamlineSdkVersion -cne [string]$streamlineManifest.version",build)
  self.assertIn('RuntimeGroup=$runtimeGroup',build)
  self.assertIn('retired MFG',package)
  self.assertNotIn("$sourceMfg.RuntimeGroup",package)
  self.assertNotIn('streamlineArchiveSha256',package)
  self.assertNotIn('dlssgSha256',package)

class VulkanOverlayRetirement(unittest.TestCase):
 def test_multi_window_present_preserves_batch_and_consumes_waits_once(self):
  menu=(PROJECT/'menu/menu_overlay_vk.cpp').read_text(encoding='utf-8')
  hook=(PROJECT/'hooks/Vulkan_Hooks.cpp').read_text(encoding='utf-8')
  prepare=menu[menu.index('void MenuOverlayVk::PreparePresent'):menu.index('void MenuOverlayVk::PresentProgress')]
  self.assertNotIn('pImageIndices[0]',prepare)
  self.assertNotIn('pSwapchains[0]',prepare)
  self.assertIn('pImageIndices[ownerIndex]',prepare)
  submit=prepare[prepare.index('bool MenuOverlayVk::QueuePresent'):]
  self.assertRegex(submit,r'info.waitSemaphoreCount\s*=\s*pPresentInfo->waitSemaphoreCount')
  self.assertRegex(submit,r'info.pWaitSemaphores\s*=\s*pPresentInfo->pWaitSemaphores')
  self.assertNotRegex(submit,r'pPresentInfo->(?:pNext|swapchainCount|pSwapchains|pImageIndices|pResults)\s*=')
  self.assertIn('TakePrepared(',submit)
  self.assertIn('PresentResult(result,hasPerChainResult,',hook)
  self.assertIn('pPresentInfo->pResults,ownerIndex,pPresentInfo->swapchainCount',hook)
 def test_xplane_busy_fence_replaces_pending_resources_only_after_overlay_present_proof(self):
  policy=(CHANNEL/'shared/VulkanOverlayRetirement.h').read_text(encoding='utf-8')
  menu=(PROJECT/'menu/menu_overlay_vk.cpp').read_text(encoding='utf-8')
  hook=(PROJECT/'hooks/Vulkan_Hooks.cpp').read_text(encoding='utf-8')
  self.assertIn('if (previouslyPresented && retiredResources < MaxRetiredFrameResources)',policy)
  self.assertIn('_imagePresentedSuccessfully[semaphoreIndex] = 0',menu)
  self.assertIn('DecideAcquiredImageFence(',menu)
  self.assertIn('RetireCurrentFrameResources',menu)
  self.assertIn('vkGetFenceStatus',menu)
  self.assertIn('_pendingOverlaySubmission[image]',menu)
  self.assertIn('result==VK_SUCCESS||result==VK_SUBOPTIMAL_KHR',menu)
  self.assertIn('MenuOverlayVk::PresentProgress(menuDrawOwner,ownerResult,ownerImage)',hook)
  self.assertNotIn('vkQueueWaitIdle',menu)
  self.assertNotIn('vkDeviceWaitIdle',menu[menu.index('void MenuOverlayVk::PreparePresent'):menu.index('bool MenuOverlayVk::QueuePresent')])

 def test_imgui_upload_buffers_share_the_per_image_retirement_fence(self):
  menu=(PROJECT/'menu/menu_overlay_vk.cpp').read_text(encoding='utf-8')
  backend=(PROJECT/'include/imgui/imgui_impl_vulkan.cpp').read_text(encoding='utf-8')
  self.assertIn('ImGui_ImplVulkan_SetFrameRenderBufferIndex(idx)',menu)
  self.assertIn('ImGui_ImplVulkan_TakeFrameRenderBuffers(image,&renderBuffers)',menu)
  self.assertIn('ImGui_ImplVulkan_FrameRenderBuffers RenderBuffers{}',menu)
  self.assertIn('ReapCompletedResources(imageResources',menu)
  self.assertIn('ImGui_ImplVulkan_DestroyRetiredFrameRenderBuffers(device,&resources.RenderBuffers',menu)
  self.assertIn('wrb->Index = bd->FrameRenderBufferIndex;',backend)
  self.assertIn('ImGui_ImplVulkan_FrameRenderBuffers* source = &render_buffers->FrameRenderBuffers[frame_index];',backend)
  self.assertIn('memset(source, 0, sizeof(*source));',backend)
 def test_vk_input_capture_waits_for_a_nonempty_overlay_present(self):
  menu=(PROJECT/'menu/menu_overlay_vk.cpp').read_text(encoding='utf-8')
  panel=(PROJECT/'menu/OptiShadePanel.inl').read_text(encoding='utf-8')
  common=(PROJECT/'menu/menu_common.h').read_text(encoding='utf-8')+(PROJECT/'menu/menu_common.cpp').read_text(encoding='utf-8')
  input_source=(PROJECT/'menu/input/input_system.cpp').read_text(encoding='utf-8')
  policy=(CHANNEL/'shared/OverlayInputAdmission.h').read_text(encoding='utf-8')
  self.assertIn('OptiInput::RequireMenuPresentProgress(true)',menu)
  self.assertIn('overlayPresented=presentSucceeded&&overlayWasSubmitted',menu)
  self.assertIn('OptiInput::ReportMenuPresentProgress(owner,overlayPresented)',menu)
  self.assertIn('prepared.nonempty&&prepared.interactive',menu)
  self.assertIn('MenuCommon::InteractivePanelDrawList()',menu)
  self.assertNotIn('ImGui::FindWindowByName',menu)
  self.assertIn('_interactivePanelDrawList = nullptr',common)
  self.assertIn('mainContentsVisible&&visible&&mainDrawList&&mainDrawList->VtxBuffer.Size>0&&mainIntersectsViewport',panel)
  self.assertIn('editorContentsVisible&&editorVisible&&editorDrawList&&editorDrawList->VtxBuffer.Size>0&&editorIntersectsViewport',panel)
  self.assertIn('Visible Vulkan menu panel was not present in the submitted ImGui draw data',menu)
  self.assertIn('MenuAdmission.AllowsInputBlock(recentSubmission, recentPresentation)',input_source)
  self.assertIn('bool ReportPresentation(bool presented)',policy)
  self.assertIn('(!requiresPresentation_ || recentPresentedFrame)',policy)

class VulkanNrBridgeRetirement(unittest.TestCase):
 def test_completed_private_nr_lists_retire_before_shared_shutdown(self):
  bridge=(CHANNEL/'shared/PrivateVulkanNrBridge.h').read_text(encoding='utf-8')
  ring=(CHANNEL/'shared/PrivateVulkanNrRing.h').read_text(encoding='utf-8')
  hook=(PROJECT/'hooks/Vulkan_Hooks.cpp').read_text(encoding='utf-8')
  retire=bridge[bridge.index('bool RetireCompletedRecording()'):bridge.index('bool Matches(')]
  self.assertLess(retire.index('if(!ReadyToRetire())return false'),retire.index('nr_lifetime::RetirePrivate'))
  self.assertIn('for(auto& s:slots)if(s.bridge&&!s.bridge->RetireCompletedRecording())return false;',ring)
  mismatch=hook[hook.index('if(bridge->transport&&('):hook.index('if(!bridge->transport){',hook.index('if(bridge->transport&&('))]
  self.assertLess(mismatch.index('RetireCompletedRecordings()'),mismatch.index('DlssNr::Shutdown()'))
  destroyed=hook[hook.index('if(bridge->transport&&bridge->transport->OwnsDevice'):hook.index('bridge->owner=bridge->generation',hook.index('if(bridge->transport&&bridge->transport->OwnsDevice'))]
  self.assertIn('RetireCompletedRecordings()&&DlssNr::Shutdown()',destroyed)

class VulkanAcquireDependencyModel(unittest.TestCase):
 def test_cpu_proof_model_is_tested_but_not_wired_into_runtime(self):
  policy=(CHANNEL/'shared/VulkanAcquireDependency.h').read_text(encoding='utf-8')
  hook=(PROJECT/'hooks/Vulkan_Hooks.cpp').read_text(encoding='utf-8')
  runner=(Path(__file__).resolve().parent/'run_tests.py').read_text(encoding='utf-8')
  self.assertIn('CPU-only synchronization proof model',policy)
  self.assertIn('unsupportedPNext || batch.deviceGroup',policy)
  self.assertIn('QuarantineUnobservedSubmit(device, batches, count)',policy)
  self.assertIn('pre-call tokens would let a consumed binary acquire semaphore prove a later submission',policy)
  self.assertIn('StateResult ObservePresent(',policy)
  self.assertIn('struct PresentWait',policy)
  self.assertIn('hostReadyImageCount',policy)
  self.assertIn('build(\'vulkan-acquire-dependency\'',runner)
  adapter=(CHANNEL/'shared/VulkanAcquireApiAdapter.h').read_text(encoding='utf-8')
  adapter_test=(Path(__file__).resolve().parent/'vulkan_acquire_api_adapter_tests.cpp').read_text(encoding='utf-8')
  self.assertIn('CaptureLegacySubmit(',adapter)
  self.assertIn('CaptureSubmit2(',adapter)
  self.assertIn('CapturePresentResult(',adapter)
  self.assertIn('ObserveAcquireInfoResult(',adapter)
  self.assertIn('ObserveFenceStatus(',adapter)
  self.assertIn('source.pNext != nullptr || source.flags != 0',adapter)
  self.assertIn('info.value != 0 || info.deviceIndex != 0',adapter)
  self.assertIn('ApplySubmitResult(',adapter)
  self.assertIn('vulkan-acquire-api-adapter',runner)
  self.assertIn('VK_ERROR_DEVICE_LOST',adapter_test)
  self.assertIn('VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT',adapter_test)
  self.assertIn('timelineSnapshot',adapter_test)
  self.assertIn('perResultsKnown',adapter_test)
  self.assertIn('swapchainFixture.terminal=HandleValue(reshadeCompletion)',adapter_test)
  self.assertIn('waits[0].semaphore == HandleValue(reshadeCompletion)',adapter_test)
  self.assertIn('wait list actually passed downstream',adapter_test)
  self.assertIn('waitAll = VK_FALSE',adapter)
  self.assertNotIn('VulkanAcquireDependency.h',hook)
  self.assertNotIn('vulkan_sync::AcquireDependencyTracker',hook)
  self.assertNotIn('VulkanAcquireApiAdapter.h',hook)

class VulkanReShadePresentBoundary(unittest.TestCase):
 def test_overlay_bridge_catches_exceptions_inside_noexcept_callback_boundary(self):
  bridge=(CHANNEL/'shared/VulkanOverlayBridge.h').read_text(encoding='utf-8')
  preparation=(CHANNEL/'shared/OverlayPreparation.h').read_text(encoding='utf-8')
  swapchain=(CHANNEL/'reshade/source/vulkan/vulkan_hooks_swapchain.cpp').read_text(encoding='utf-8')
  hooks=(PROJECT/'hooks/Vulkan_Hooks.cpp').read_text(encoding='utf-8')
  self.assertIn('using DrawOverlay = bool (*)(VkQueue, VkPresentInfoKHR*, PFN_vkQueueSubmit) noexcept;',bridge)
  self.assertIn('using PrepareOverlay = bool (*)(VkQueue,const VkPresentInfoKHR*) noexcept;',bridge)
  self.assertIn('std::is_nothrow_invocable_r_v<bool,Prepare>',preparation)
  self.assertIn('bool DrawIfPrepared(bool preparationRequired, bool preparationSucceeded, Draw&& draw) noexcept',preparation)
  self.assertIn('overlayPreparationRequired=overlay_callbacks.prepare!=nullptr',swapchain)
  self.assertIn('DrawIfPrepared(overlayPreparationRequired,overlayPreparationSucceeded,',swapchain)
  self.assertIn('[&]() noexcept -> bool { return overlay_callbacks.prepare(queue, pPresentInfo); }',swapchain)
  self.assertIn('static bool PrepareMenuOutsideQueueLocks(VkQueue queue,const VkPresentInfoKHR* info) noexcept',hooks)
  self.assertIn('static bool SubmitMenuWithOwner(VkQueue queue,VkPresentInfoKHR* info,PFN_vkQueueSubmit submit) noexcept',hooks)
  self.assertIn('} catch (...) { return false; }',hooks)
  self.assertIn('OptiShade Vulkan menu preparation callback failed.',swapchain)

 def test_final_driver_present_receives_reshade_waits_and_original_result_storage(self):
  source=(CHANNEL/'reshade/source/vulkan/vulkan_hooks_swapchain.cpp').read_text(encoding='utf-8')
  start=source.index('VkResult VKAPI_CALL vkQueuePresentKHR(')
  end=source.index('\n}\n#endif',start)
  present=source[start:end]
  copied=present.index('VkPresentInfoKHR present_info = *pPresentInfo;')
  effect_flush=present.index('queue_impl->flush_immediate_command_list(&submit_info);')
  rewrite_count=present.index('present_info.waitSemaphoreCount = submit_info.waitSemaphoreCount;')
  rewrite_array=present.index('present_info.pWaitSemaphores = submit_info.pWaitSemaphores;')
  driver_call=present.index('trampoline(queue, &present_info)')
  self.assertLess(copied,effect_flush)
  self.assertLess(effect_flush,rewrite_count)
  self.assertLess(rewrite_count,rewrite_array)
  self.assertLess(rewrite_array,driver_call)
  self.assertNotIn('present_info.pResults =',present)

 def test_optishade_external_flushes_join_present_wait_chain_before_runtime_callbacks(self):
  source=(CHANNEL/'reshade/source/vulkan/vulkan_hooks_swapchain.cpp').read_text(encoding='utf-8')
  queue=(CHANNEL/'reshade/source/vulkan/vulkan_impl_command_queue.cpp').read_text(encoding='utf-8')
  header=(CHANNEL/'reshade/source/vulkan/vulkan_impl_command_queue.hpp').read_text(encoding='utf-8')
  start=source.index('VkResult VKAPI_CALL vkQueuePresentKHR(')
  end=source.index('\n}\n#endif',start)
  present=source[start:end]
  setup=present.index('queue_impl->set_external_present_wait_info(&submit_info);')
  callbacks=present.index('reshade::present_effect_runtime(swapchain_impl);')
  final_flush=present.index('queue_impl->flush_immediate_command_list(&submit_info);')
  clear=present.index('queue_impl->set_external_present_wait_info(nullptr);')
  self.assertLess(setup,callbacks)
  self.assertLess(callbacks,final_flush)
  self.assertLess(final_flush,clear)
  external=queue[queue.index('void reshade::vulkan::command_queue_impl::flush_external_immediate_commands()'):queue.index('extern "C" void OptiShadeFlushExternalVulkanCommands')]
  self.assertIn('flush_immediate_command_list(_external_present_wait_info);',external)
  self.assertIn('VkSubmitInfo *_external_present_wait_info = nullptr;',header)

class VulkanDownstreamPresentObservation(unittest.TestCase):
 def test_rewritten_present_snapshot_is_dispatched_after_reshade_unlocks(self):
  source=(CHANNEL/'reshade/source/vulkan/vulkan_hooks_swapchain.cpp').read_text(encoding='utf-8')
  start=source.index('VkResult VKAPI_CALL vkQueuePresentKHR(');end=source.index('\n}\n#endif',start);present=source[start:end]
  driver=present.index('trampoline(queue, &present_info)')
  capture=present.index('Capture(queue, &present_info, static_cast<int32_t>(result), downstream_present)')
  unlock=present.index('queue_impl->_mutex.unlock();')
  notify=present.index('OptiShadeVulkanNotifyPresent(downstream_present)')
  self.assertLess(driver,capture);self.assertLess(capture,unlock);self.assertLess(unlock,notify)
  bridge=(CHANNEL/'shared/VulkanOwnerBridge.h').read_text(encoding='utf-8')
  self.assertIn('GetProcAddress(module,"OptiShadeVulkanNrPresentObserved")',bridge)
  consumer=(CHANNEL/'optiscaler/OptiScaler/hooks/Vulkan_Hooks.cpp').read_text(encoding='utf-8')
  observer=consumer[consumer.index('void OptiShadeVulkanNrPresentObserved('):consumer.index('static VkResult VKAPI_CALL ObserveQueueSubmit',consumer.index('void OptiShadeVulkanNrPresentObserved('))]
  self.assertIn('CurrentSimulator()!=optishade::route::Simulator::XPlane12',observer)
  self.assertIn('now-prior<1000',observer)
  self.assertIn('State().Put(',observer)
  for key in ('XP12VulkanPresentWaitHandlesCaptured','XP12VulkanPresentWaitHandlesTruncated','XP12VulkanPresentImages','XP12VulkanPresentResults','XP12VulkanPresentGlobalResult'):
   self.assertIn(key,observer)
  self.assertIn('_owners.findQueue(correlated.queue).device',observer)
  self.assertIn('_owners.swapchainGeneration(correlated.device,correlated.chains[i].swapchain)',observer)
  for key in ('XP12VulkanPresentDevice','XP12VulkanPresentGenerations'):
   self.assertIn(key,observer)
  self.assertIn('std::min<uint32_t>(snapshot->capturedWaitCount,20)',observer)
 def test_xplane_acquire_calls_are_observed_without_changing_other_routes(self):
  consumer=(CHANNEL/'optiscaler/OptiScaler/hooks/Vulkan_Hooks.cpp').read_text(encoding='utf-8-sig')
  for name in ('ObserveAcquireNextImageKHR','ObserveAcquireNextImage2KHR'):
   self.assertIn(name,consumer)
  gipa=consumer[consumer.index('PFN_vkVoidFunction hkvkGetInstanceProcAddr('):consumer.index('VALIDATE_HOOK(hkvkGetDeviceProcAddr')]
  gdpa=consumer[consumer.index('PFN_vkVoidFunction hkvkGetDeviceProcAddr('):consumer.index('if (procName == std::string("vkCreateInstance"))',consumer.index('PFN_vkVoidFunction hkvkGetDeviceProcAddr('))]
  for dispatch in (gipa,gdpa):
   self.assertIn('CurrentSimulator()==optishade::route::Simulator::XPlane12',dispatch)
   self.assertIn('vkAcquireNextImageKHR',dispatch)
   self.assertIn('vkAcquireNextImage2KHR',dispatch)

  for name in ('CaptureLegacy','CaptureDeviceGroup','RecordAcquireObservation'):
   self.assertIn(name,consumer)
  self.assertEqual(consumer.count('snapshot.swapchainGeneration=_owners.swapchainGeneration(snapshot.device,snapshot.swapchain)'),2)
  journal=(CHANNEL/'shared/LastSession.h').read_text(encoding='utf-8-sig')
  self.assertIn('void Put(const std::map<std::string,std::string>& values)',journal)
  diagnostics=(CHANNEL/'installer/diagnostics.ps1').read_text(encoding='utf-8-sig')
  session_filter=diagnostics[diagnostics.index('function GetSafeLastSessionSnapshot'):diagnostics.index('function GetDiagnosticContext')]
  for key in ('XP12VulkanAcquireApi','XP12VulkanAcquireResult','XP12VulkanAcquireDevice','XP12VulkanAcquireSwapchain','XP12VulkanAcquireSwapchainGeneration','XP12VulkanAcquireImageIndexValid','XP12VulkanAcquireImageIndex'):
   self.assertIn(key,session_filter);self.assertIn(key,journal)
  for key in ('XP12VulkanPresentDevice','XP12VulkanPresentGenerations'):
   self.assertIn(key,journal);self.assertIn(key,session_filter)
  host=(CHANNEL/'shared/SimulatorRouteHost.h').read_text(encoding='utf-8')
  route=(CHANNEL/'routes/xplane12.cpp').read_text(encoding='utf-8')
  self.assertIn('swapchainGeneration(uint64_t device,uint64_t swapchain)',host)
  self.assertIn('VulkanEvent::FindSwapchainGeneration',route)
 def test_application_and_reshade_submissions_are_captured_after_dispatch(self):
  device=(CHANNEL/'reshade/source/vulkan/vulkan_hooks_device.cpp').read_text(encoding='utf-8')
  for name,capture in (('vkQueueSubmit(','CaptureLegacy(queue, pSubmits'),('vkQueueSubmit2(','CaptureSubmit2(queue, pSubmits')):
   start=device.index('VkResult VKAPI_CALL '+name);end=device.index('\n}',start);hook=device[start:end]
   self.assertLess(hook.index('trampoline(queue, submitCount, pSubmits, fence)'),hook.index(capture))
   self.assertLess(hook.index(capture),hook.index('lock.unlock()'))
   self.assertLess(hook.index('lock.unlock()'),hook.index('OptiShadeVulkanNotifySubmit(observation)'))
  bridge=(CHANNEL/'shared/VulkanOwnerBridge.h').read_text(encoding='utf-8')
  self.assertIn('VulkanSubmitObservation.h',bridge)
  for relative in ('reshade/source/vulkan/vulkan_impl_command_list_immediate.cpp','reshade/source/vulkan/vulkan_impl_command_queue.cpp','reshade/source/vulkan/vulkan_hooks_swapchain.cpp'):
   source=(CHANNEL/relative).read_text(encoding='utf-8')
   self.assertIn('VulkanOwnerBridge.h',source)
   self.assertIn('OptiShadeVulkanNotifySubmit(',source)
  direct_submit_files={
   'reshade/source/vulkan/vulkan_impl_command_list_immediate.cpp':1,
   'reshade/source/vulkan/vulkan_impl_command_queue.cpp':3,
   'reshade/source/vulkan/vulkan_hooks_swapchain.cpp':2,
  }
  for relative,expected_calls in direct_submit_files.items():
   source=(CHANNEL/relative).read_text(encoding='utf-8')
   self.assertEqual(source.count('vk.QueueSubmit('),expected_calls,relative)
   self.assertEqual(source.count('OptiShadeVulkanNotifySubmit('),expected_calls,relative)
  menu=(CHANNEL/'optiscaler/OptiScaler/menu/menu_overlay_vk.cpp').read_text(encoding='utf-8')
  menu_submit=menu[menu.index('const auto result=(submit?submit:vkQueueSubmit)'):menu.index('if(prepared.image<_menuTraceSamples.size())',menu.index('const auto result=(submit?submit:vkQueueSubmit)'))]
  self.assertLess(menu_submit.index('CaptureLegacy('),menu_submit.index('OptiShadeVulkanNrQueueSubmitObserved('))
  self.assertIn('Source::OptiShadeMenu',menu_submit)
  consumer=(CHANNEL/'optiscaler/OptiScaler/hooks/Vulkan_Hooks.cpp').read_text(encoding='utf-8-sig')
  self.assertIn('OptiShadeVulkanNrQueueSubmitObserved',consumer)
  self.assertIn('SubmitObservationFields(submit,observedSubmits)',consumer)
  for key in ('XP12VulkanSubmitWaitDetails','XP12VulkanSubmitSignalDetails','XP12VulkanSubmitBatchSummary','XP12VulkanSubmitOmittedSinceWrite'):
   self.assertIn(key,consumer)
  journal=(CHANNEL/'shared/LastSession.h').read_text(encoding='utf-8-sig')
  diagnostics=(CHANNEL/'installer/diagnostics.ps1').read_text(encoding='utf-8-sig')
  for key in ('XP12VulkanSubmitApi','XP12VulkanSubmitWaitHandles','XP12VulkanSubmitSignalHandles','XP12VulkanSubmitCommandHandles','XP12VulkanSubmitSnapshotValid'):
   self.assertIn(key,journal);self.assertIn(key,diagnostics)
 def test_vulkan_sync_object_lifecycle_is_observed_and_exported(self):
  device=(CHANNEL/'reshade/source/vulkan/vulkan_hooks_device.cpp').read_text(encoding='utf-8')
  for signature,dispatch in (('VkResult VKAPI_CALL vkCreateSemaphore(','trampoline(device, pCreateInfo, pAllocator, pSemaphore)'),('void VKAPI_CALL vkDestroySemaphore(','trampoline(device, semaphore, pAllocator)'),('VkResult VKAPI_CALL vkCreateFence(','trampoline(device, pCreateInfo, pAllocator, pFence)'),('void VKAPI_CALL vkDestroyFence(','trampoline(device, fence, pAllocator)')):
   start=device.index(signature);end=device.index('\n}',start);hook=device[start:end]
   self.assertLess(hook.index(dispatch),hook.index('OptiShadeVulkanNotifySync(event)'))
   self.assertIn('event.valid',hook)
  create=device[device.index('VkResult VKAPI_CALL vkCreateSemaphore('):device.index('\n}',device.index('VkResult VKAPI_CALL vkCreateSemaphore('))]
  self.assertIn('VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO',create)
  self.assertIn('VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO',create)
  proc=(CHANNEL/'reshade/source/vulkan/vulkan.cpp').read_text(encoding='utf-8')
  for name in ('CreateSemaphore','DestroySemaphore','CreateFence','DestroyFence'):
   self.assertIn(f'RESHADE_VULKAN_HOOK_PROC({name})',proc)
  bridge=(CHANNEL/'shared/VulkanOwnerBridge.h').read_text(encoding='utf-8')
  self.assertIn('OptiShadeVulkanNrSyncObjectObserved',bridge)
  consumer=(CHANNEL/'optiscaler/OptiScaler/hooks/Vulkan_Hooks.cpp').read_text(encoding='utf-8-sig')
  self.assertIn('VulkanSyncObservationFields()',consumer)
  self.assertIn('VulkanSyncEventCapacity=4',consumer)
  self.assertIn('Simulator::XPlane12',consumer[consumer.index('OptiShadeVulkanNrSyncObjectObserved'):consumer.index('static VkResult VKAPI_CALL ObserveAcquireNextImageKHR')])
  journal=(CHANNEL/'shared/LastSession.h').read_text(encoding='utf-8-sig')
  diagnostics=(CHANNEL/'installer/diagnostics.ps1').read_text(encoding='utf-8-sig')
  for key in ('XP12VulkanSyncEventSequence','XP12VulkanSyncEventsDropped','XP12VulkanSyncSemaphoreCreates','XP12VulkanSyncSemaphoreDestroys','XP12VulkanSyncFenceCreates','XP12VulkanSyncFenceDestroys','XP12VulkanSyncRecentEvents'):
   self.assertIn(key,journal);self.assertIn(key,diagnostics)

class VulkanPresentSemaphoreReuse(unittest.TestCase):
 def test_final_present_wait_is_relayed_to_swapchain_image_owned_semaphores(self):
  source=(CHANNEL/'reshade/source/vulkan/vulkan_hooks_swapchain.cpp').read_text(encoding='utf-8')
  create=source[source.index('static bool CreateOptiShadePresentTerminalSet'):source.index('static void DestroyOptiShadePresentTerminalSet')]
  lookup=source[source.index('static bool GetOptiShadePresentTerminalSemaphores'):source.index('#if VK_KHR_swapchain')]
  present=source[source.index('VkResult VKAPI_CALL vkQueuePresentKHR('):source.index('\n}\n#endif',source.index('VkResult VKAPI_CALL vkQueuePresentKHR('))]
  destroy=source[source.index('void     VKAPI_CALL vkDestroySwapchainKHR('):source.index('VkResult VKAPI_CALL vkQueuePresentKHR(')]
  self.assertIn('std::unordered_map<VkSwapchainKHR, OptiShadePresentTerminalSet>',source)
  self.assertIn('created.byImage.resize(image_count, VK_NULL_HANDLE)',create)
  self.assertIn('create_semaphore(device, &create_info',create)
  self.assertIn('created.deferredUntilDeviceDestroy.reserve(OptiShadeMaxRetiredPresentSemaphores)',create)
  self.assertIn('image_indices[i] >= found->second.byImage.size()',lookup)
  self.assertIn('found->second.byImage[image_indices[i]]',lookup)
  self.assertIn('CreateOptiShadePresentTerminalSet(device, swapchain_impl->_orig, num_images',source)
  relay=present.index('const VkResult relay_result = vk.QueueSubmit(queue, 1, &relay_info, VK_NULL_HANDLE);')
  draw=max(present.index('overlay_callbacks.draw(queue,&present_info,vk.QueueSubmit)'),present.index('draw(queue, &present_info, vk.QueueSubmit)'))
  driver=present.index('trampoline(queue, &present_info)')
  self.assertLess(draw,relay)
  self.assertLess(relay,driver)
  retire=present.index('RetireOptiShadePresentTerminalsAfterFailure(present_info.swapchainCount')
  self.assertLess(driver,retire)
  self.assertIn('VK_PIPELINE_STAGE_ALL_COMMANDS_BIT',present)
  self.assertIn('present_info.pWaitSemaphores = terminal_semaphores.data();',present)
  self.assertIn('queue_impl->present_batch <= 1',present)
  self.assertIn('VK_QUEUE_PROTECTED_BIT',present)
  self.assertIn('VK_STRUCTURE_TYPE_DEVICE_GROUP_PRESENT_INFO_KHR',present)
  self.assertIn('CaptureLegacy(queue, &relay_info',present)
  self.assertIn('preserving the existing present wait chain',present)
  self.assertIn('terminal_relay_submitted = true;',present)
  self.assertIn('const VkResult item_result = per_swapchain_results != nullptr ? per_swapchain_results[i] : present_result;',source)
  self.assertIn('IsVulkanPresentOperationQueued(item_result)',source)
  self.assertIn('set.disabled = true;',source)
  self.assertIn('set.deferredUntilDeviceDestroy.push_back(set.byImage[image]);',source)
  self.assertIn('DestroyOptiShadePresentTerminalSet(swapchain, vk.WaitForFences, vk.DestroyFence, vk.DestroySemaphore);',destroy)
  self.assertLess(destroy.index('trampoline(device, swapchain, pAllocator);'),destroy.index('DestroyOptiShadePresentTerminalSet'))
  self.assertNotIn('present_info.pResults =',present)
  for manifest in (CHANNEL/'reshade/deps/glad.vcxproj',CHANNEL/'reshade/deps/CMakeLists.txt'):
   generated=manifest.read_text(encoding='utf-8')
   for extension in ('VK_KHR_get_surface_capabilities2','VK_EXT_surface_maintenance1','VK_EXT_swapchain_maintenance1'):
    self.assertIn(extension,generated)
class VulkanNrEffectReloadRegression(unittest.TestCase):
 def test_effect_reload_increments_history_identity_and_invalidates(self):
  source=(CHANNEL/'reshade/source/optishade_vulkan_nr.inl').read_text(encoding='utf-8-sig')
  start=source.index('static void Changed(')
  end=source.index('\nstatic void Loading(',start)
  changed=source[start:end]
  self.assertNotIn('if(!surface)return;',changed)
  self.assertIn('state->life.change(state->surface)',changed)
  self.assertIn('state->life.change(state->effects)',changed)
  lifecycle=(CHANNEL/'shared/VulkanNrLifecycle.h').read_text(encoding='utf-8-sig')
  self.assertIn('void change(uint64_t& revision)',lifecycle)
  target=(Path(__file__).resolve().parent/'xplane_vulkan_target_tests.cpp').read_text(encoding='utf-8-sig')
  self.assertIn('life.change(effectRevision);',target)

class XPlaneNrFirstBlockDiagnostics(unittest.TestCase):
 def test_first_vulkan_nr_block_is_bound_to_the_current_owner_context(self):
  journal=(CHANNEL/'shared/LastSession.h').read_text(encoding='utf-8-sig')
  collector=(CHANNEL/'optiscaler/OptiScaler/hooks/Vulkan_Hooks.cpp').read_text(encoding='utf-8-sig')
  bridge=(CHANNEL/'reshade/source/optishade_vulkan_nr.inl').read_text(encoding='utf-8-sig')
  exporter=(CHANNEL/'installer/diagnostics.ps1').read_text(encoding='utf-8-sig')
  self.assertIn('RecordXP12BridgeBlock',journal)
  for field in ('XP12BridgeFirstBlockReason','XP12BridgeLatestBlockReason','XP12BridgeLatestBlockUtc','XP12BridgeBlockCount','XP12BridgeBlockAPI','XP12BridgeBlockDevice','XP12BridgeBlockOwner','XP12BridgeBlockGeneration','XP12BridgeBlockQueue'):
   self.assertIn(field,journal)
   self.assertIn(field,exporter)
  self.assertIn('OptiShadeVulkanNrReportBlock',collector)
  self.assertIn('OptiShadeVulkanNrReportBlock',bridge)
  self.assertIn('Reason::BridgeUnavailable',bridge)
  self.assertIn('DlssNr::VulkanBridgeStatus()',collector)
  self.assertIn('XP12BridgeLatestBlockReason', (CHANNEL/'installer/Troubleshooter/src/Collector.cs').read_text(encoding='utf-8-sig'))
  self.assertIn('result.owner.chain',bridge)
  self.assertIn('result.owner.generation',bridge)
  self.assertIn('get_command_queue()',bridge)

 def test_xplane_user_toggle_is_saved_as_an_explicit_activation_attempt(self):
  journal=(CHANNEL/'shared/LastSession.h').read_text(encoding='utf-8-sig')
  observation=(PROJECT/'dlssnr/NrObservationConfig.h').read_text(encoding='utf-8-sig')
  feature=(PROJECT/'shaders/dlssnr/DlssNr_Dx12.cpp').read_text(encoding='utf-8-sig')
  panel=(PROJECT/'dlssnr/DlssNrPanel.inl').read_text(encoding='utf-8-sig')
  trouble=(CHANNEL/'installer/Troubleshooter/src/Collector.cs').read_text(encoding='utf-8-sig')
  self.assertIn('RecordNRActivation(cfg.DlssNrEnabled.value_or_default(),source?source:"unknown")',observation)
  set_enabled=feature[feature.index('void SetEnabled(bool enabled,'):feature.index('\nnamespace {',feature.index('void SetEnabled(bool enabled,'))]
  self.assertIn('ObserveRequest(*Config::Instance(),true,source);',set_enabled)
  self.assertIn('DlssNr::SetEnabled(value,"in-game-panel")',panel)
  self.assertIn('NRActivationHistory',journal)
  self.assertIn('cannot establish that NR was never attempted',trouble)

class XPlaneVulkanOwnerLayerFallback(unittest.TestCase):
 def test_reshade_vulkan_layer_publishes_xplane_owner_lifecycle(self):
  helper=(CHANNEL/'reshade/source/vulkan/optishade_route_owner.hpp').read_text(encoding='utf-8-sig')
  instance=(CHANNEL/'reshade/source/vulkan/vulkan_hooks_instance.cpp').read_text(encoding='utf-8-sig')
  device=(CHANNEL/'reshade/source/vulkan/vulkan_hooks_device.cpp').read_text(encoding='utf-8-sig')
  swapchain=(CHANNEL/'reshade/source/vulkan/vulkan_hooks_swapchain.cpp').read_text(encoding='utf-8-sig')
  for event in ('Surface','Swapchain','Queue','Present'):
   self.assertIn('VulkanEvent::'+event,helper)
  self.assertIn('IsXPlaneMainWindow(window)',helper)
  self.assertIn('reshade_vulkan_owner::Surface',instance)
  self.assertIn('reshade_vulkan_owner::Queue',device)
  self.assertIn('reshade_vulkan_owner::Swapchain',swapchain)
  self.assertIn('reshade_vulkan_owner::Present',swapchain)
  self.assertIn('VulkanEvent::EraseInstance',instance)
  self.assertIn('VulkanEvent::EraseSurface',instance)
  self.assertIn('VulkanEvent::EraseDevice',device)
  self.assertIn('VulkanEvent::EraseChain',swapchain)

 def test_duplicate_layer_observation_keeps_the_existing_swapchain_generation(self):
  owner=(CHANNEL/'shared/VulkanOwner.h').read_text(encoding='utf-8-sig')
  fixture=(Path(__file__).resolve().parent/'vulkan_present_batch_tests.cpp').read_text(encoding='utf-8-sig')
  self.assertIn('existing.device != device || existing.surface != surface || existing.chain != chain',owner)
  self.assertIn('registry.owner.generation == firstRegistrationGeneration',fixture)

class NrTaaTransitionRegression(unittest.TestCase):
 def test_taa_reuse_checks_its_fence_without_draining_producer_queue(self):
  text=(CHANNEL/'optiscaler/OptiScaler/shaders/dlssnr/DlssNr_Taa.inl').read_text(encoding='utf-8-sig')
  submit=text[text.index('optishade::nr_submission::Result Submit('):]
  before=submit[:submit.index('if (!slot->allocator &&')]
  self.assertIn('priorCompletion == UINT64_MAX',before)
  self.assertIn('Reclaim();',before)
  # A full ring waits for the oldest frame only; a free slot never waits.
  self.assertIn('if (!slot) {',before)
  self.assertIn('WaitFor(oldest->value)',before)
  after=submit[submit.index('queue->ExecuteCommandLists(1, lists);'):]
  self.assertLess(after.index('queue->Signal(fence.Get(), ++fenceValue)'),after.index('slot->busy = true;'))
  self.assertLess(after.index('if (synchronous) {'),after.index('WaitFor(slot->value)'))
  reclaim=text[text.index('void Reclaim() {'):text.index('bool WaitFor(')]
  self.assertLess(reclaim.index('Completed(oldest->ticket'),reclaim.index('oldest->color.Reset()'))
 def test_flat_taa_nr_is_pipelined_and_vr_or_d3d11_still_waits(self):
  shader=(CHANNEL/'optiscaler/OptiScaler/shaders/dlssnr/DlssNr_Dx12.cpp').read_text(encoding='utf-8-sig')
  taa=(CHANNEL/'optiscaler/OptiScaler/shaders/dlssnr/DlssNr_Taa.inl').read_text(encoding='utf-8-sig')
  self.assertIn('Submit(const ostaa::Frame* input, bool synchronous = true)',taa)
  self.assertIn('DlssNr::Taa::Instance().Submit(frame,frame->projection!=0)',shader)
  self.assertIn('return state.Submit(&frame);',shader)
  self.assertIn('TAA NR game-thread cost: avg',taa)
  self.assertNotIn('synchronous frame cost',taa)
 def test_nr_domain_changes_reset_history_without_releasing_resources(self):
  text=(CHANNEL/'optiscaler/OptiScaler/shaders/dlssnr/DlssNr_Dx12.cpp').read_text(encoding='utf-8-sig')
  domain=text[text.index('if(frame.Reset || g_timingDomain.device'):text.index('// The LUID comes')]
  self.assertIn('g_nr.reset = true;',domain)
  self.assertIn('g_nr.residualHistoryPrimed = false;',domain)
  self.assertNotIn('Shutdown',domain)
  self.assertIn('nativeNow - nativeHistory > 500',text)

class VulkanBridgeRecoveryRegression(unittest.TestCase):
 def test_missing_producer_recording_does_not_open_private_command_list(self):
  s=(CHANNEL/'shared/PrivateVulkanNrBridge.h').read_text()
  run=s[s.index(' int Run('):]
  self.assertLess(run.index('f.currentCommands(f.commandContext)'),run.index('allocator->Reset()'))
  self.assertLess(run.index('No current Vulkan recording'),run.index('nr_lifetime::Reset(commands.Get())'))
 def test_failed_initialization_retries_without_per_frame_device_creation(self):
  s=(CHANNEL/'optiscaler/OptiScaler/hooks/Vulkan_Hooks.cpp').read_text(encoding='utf-8-sig')
  block=s[s.index('    if(!bridge->transport){'):]
  self.assertLess(block.index('initializationRetry.Begin'),block.index('candidate->Init'))
  self.assertIn('frame->device,frame->queue,bridgeOwner,bridgeGeneration,frame->runtime,frame->width,frame->height',block)

class InGameBuildLabel(unittest.TestCase):
 def test_overlay_reads_version_and_private_revision_from_packaged_identity(self):
  header=(CHANNEL/'shared/BuildDisplayLabel.h').read_text(encoding='utf-8-sig')
  panel=(CHANNEL/'optiscaler/OptiScaler/menu/OptiShadePanel.inl').read_text(encoding='utf-8-sig')
  package=(CHANNEL/'package.ps1').read_text(encoding='utf-8-sig')
  self.assertIn('ReadField(json,"Version")',header)
  self.assertIn('ReadField(json,"PrivateBuildLabel")',header)
  self.assertIn('prefix="Rebuild R"',header)
  self.assertIn('revision.find_first_not_of("0123456789")',header)
  self.assertIn('OptiShadeData"/L"BuildIdentity.json',panel)
  self.assertIn('ShellHeader(buildDisplay.c_str()',panel)
  self.assertIn('PrivateBuildLabel=$PrivateBuildLabel',package)

if __name__=='__main__':unittest.main(verbosity=2)
