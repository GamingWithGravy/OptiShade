//go:build optishade_modular

// Copyright (c) 2026 gravy / GamingWithGravy. All Rights Reserved.
// OptiShade Proprietary Material: standalone launcher source only.
// See LICENSES/OPTISHADE-PROPRIETARY.txt and OPTISHADE_LICENSING.md.
// Earlier GPL grants and applicable platform permissions remain intact.
package main

import "embed"

const modularPayloadBuild = true

//go:embed OptiShadeDriver.exe driver-settings.ps1 anti-cheat.ps1 anti-cheat-rules.json anti-cheat-dialog.xaml anti-cheat-agreement.xaml components.ps1 optimfg-headless.ps1 component-packages.ps1 component-policy.ps1 dialogs.ps1 provider-policy.json provider-policy.ps1 glass-cockpit-update.ps1 atmosphere-mod.ps1 AtmosphereMod/PROVENANCE.json AtmosphereMod/LICENSE.txt runtime-control.ps1 RuntimeControlClient.cs GpuIdentityClient.cs gpu-identity.ps1 neural-model-policy.json qualified-plan-ranking.ps1 qualification-policy.json qualified-plans.ps1 auto-compatibility.ps1 OptiShade-Troubleshooter.exe diagnostic-worker.ps1 json-state.ps1 update-lifecycle.ps1 store-paths.ps1 mfg.ps1 sm86-mfg.ps1 DumpSummary.cs crash-dumps.ps1 diagnostics.ps1 menu-settings.ps1 snapshot-library.ps1 import-effects.ps1 dialog-theme.xaml support.ps1 release-notes.ps1 developer-message.ps1 setup-required.ps1 neural-download.ps1 recovery.ps1 FusionCinema/* Help/*.txt updates.ps1 update-worker.ps1 operation-progress.ps1 operation-progress-store.ps1 update-install.ps1 compatibility.ps1 manager.ps1 manager-lifetime.ps1 manager-status.ps1 xplane-compatibility.ps1 library.ps1 executable.ps1 ownership.ps1 effects.ps1 consent.ps1 EffectPackages.ini FusionSetup.exe manager.xaml OptiShade.ico OptiShade-app.ico OptiShade-icon.png nvidia.ps1 nvidia-files.json nvidia-runtime-profiles.json streamline-files.json
var bundle embed.FS
