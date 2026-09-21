# FP8 / NVFP4 hybrid update — v0.7.1

- Model selector now contains only original FP8 and **attempt at NVFP4 hybrid**.
- **VERY minor improvements on Blackwell.** Measured complete NR-pass reduction at 4K: approximately 1–2%; this is not a game-FPS claim.
- Removed async NR and the two abandoned NVFP4 modes. Old precision values 1 and 3 now select FP8.
- Fixed startup crashes when NVIDIA overrides replace the bundled Streamline plugins. Function pointers now come from the active plugins after device initialization.
- Retains the v0.7.0 Vulkan and compatibility changes.

Close the game, back up your installation, extract the complete package and rerun `setup_windows.bat` using your existing proxy choice. Keep your existing `OptiScaler.ini` to preserve settings; the removed AsyncLatest setting is ignored. The hybrid is selected through Model precision; new installations default to FP8. Remove the old `nvngx_dlssnr_nvfp4.dll` if present. Keep `nvngx_dlssnr.dll` and the required `nvngx.dll_dlssnr.dll` forwarder.

The package includes the hybrid's packed weights and compiled kernels. It still requires your separately obtained original NVIDIA NR DLL; that DLL and NVIDIA Streamline/FG runtimes are not bundled. The hybrid requires Blackwell and the supported FP8 model; unsupported shapes retain FP8. The earlier releases remain available for rollback.

Validation: Release x64 build; original hybrid rendering and precision-switch references retained; isolated startup reproducer crashes through the old bundled Reflex pointer and succeeds through active feature resolution. Final BG3 gameplay acceptance remains pending. This is an experimental release.
