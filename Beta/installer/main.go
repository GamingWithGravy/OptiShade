// Copyright (c) 2026 gravy / GamingWithGravy. All Rights Reserved.
// OptiShade Proprietary Material: standalone launcher source only.
// See LICENSES/OPTISHADE-PROPRIETARY.txt and OPTISHADE_LICENSING.md.
// Embedded third-party/GPL payloads retain their own licences.
// Earlier GPL grants and applicable platform permissions remain intact.
// No further copying, modification, redistribution or incorporation into
// another project is permitted except under the applicable licence or law.
package main

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"unsafe"
)

func resolveLocalAppData(localAppData string) (string, error) {
	if filepath.IsAbs(localAppData) {
		return filepath.Clean(localAppData), nil
	}
	if cache, err := os.UserCacheDir(); err == nil && filepath.IsAbs(cache) {
		return filepath.Clean(cache), nil
	}
	if home, err := os.UserHomeDir(); err == nil && filepath.IsAbs(home) {
		if runtime.GOOS == "windows" {
			return filepath.Join(home, "AppData", "Local"), nil
		}
		return filepath.Join(home, ".cache"), nil
	}
	return "", fmt.Errorf("LOCALAPPDATA is missing or relative and the current user's absolute data folder could not be determined")
}

func managerStore(executable, localAppData string) (string, bool, error) {
	if !filepath.IsAbs(executable) {
		return "", false, fmt.Errorf("OptiShade executable path is not absolute")
	}
	if info, err := os.Stat(filepath.Join(filepath.Dir(executable), "portable.txt")); err == nil && !info.IsDir() {
		return filepath.Join(filepath.Dir(executable), "Data"), true, nil
	}
	dataRoot, err := resolveLocalAppData(localAppData)
	if err != nil {
		return "", false, err
	}
	return filepath.Join(dataRoot, "OptiShade"), false, nil
}

func main() {
	if len(os.Args) == 4 && os.Args[1] == "--launcher-check-update" {
		result, err := checkLauncherUpdate(os.Args[2])
		if err != nil {
			_ = writeLauncherUpdateResult(os.Args[3], launcherUpdateCheck{Schema: 1, Message: err.Error()})
			os.Exit(1)
		}
		if err = writeLauncherUpdateResult(os.Args[3], result); err != nil {
			os.Exit(1)
		}
		return
	}
	if len(os.Args) == 3 && os.Args[1] == "--launcher-apply-update" {
		if err := runModularLauncherUpdate(os.Args[2]); err != nil {
			store, _, storeErr := managerStore(os.Args[0], os.Getenv("LOCALAPPDATA"))
			if storeErr == nil {
				_ = os.MkdirAll(store, 0700)
				_ = os.WriteFile(filepath.Join(store, "Launcher-update-error.txt"), []byte(err.Error()), 0600)
			}
			// A failed update changes nothing, so reopen the installed launcher; it
			// explains the failure in its own window. Plain box only if it cannot start.
			if restartErr := reopenInstalledLauncher(); restartErr != nil {
				showStartupError(fmt.Errorf("OptiShade manager update failed: %w", err))
			}
			os.Exit(1)
		}
		return
	}
	if len(os.Args) == 6 && os.Args[1] == "--component-stage-test" {
		payloadDestination := os.Args[3]
		var requested []string
		if os.Args[4] != "" {
			requested = strings.Split(os.Args[4], ",")
		}
		if err := runComponentStageTest(os.Args[2], payloadDestination, os.Args[5], requested...); err != nil {
			os.Exit(1)
		}
		return
	}
	if len(os.Args) == 5 && os.Args[1] == "--component-channel-check" {
		if err := runComponentChannelCheck(os.Args[2], os.Args[3], strings.Split(os.Args[4], ",")...); err != nil {
			os.Exit(1)
		}
		return
	}
	if len(os.Args) == 5 && os.Args[1] == "--component-compose-cached" {
		if err := runComponentComposeCached(os.Args[2], os.Args[3], os.Args[4]); err != nil {
			os.Exit(1)
		}
		return
	}
	if len(os.Args) == 3 && os.Args[1] == "--verify-package" {
		if err := extractVerifiedPackage(os.Args[2]); err != nil {
			os.Exit(1)
		}
		return
	}
	updating := len(os.Args) > 1 && (os.Args[1] == "--apply-update" || os.Args[1] == "--check-update")
	operationProgress := len(os.Args) == 3 && os.Args[1] == "--operation-progress"
	original, err := os.Executable()
	if err != nil {
		os.Exit(1)
	}
	// The app-bundled Uninstall.exe reuses the manager's verified uninstall
	// transaction for every recorded game before removing app-local files.
	if filepath.Base(original) == "Uninstall.exe" {
		if err = uninstallInstalledApp(original); err != nil {
			showStartupError(err)
			os.Exit(1)
		}
		return
	}
	// The modular launcher is installed and set up only by the OptiShade
	// installer. Without its set-up record it explains that and exits before
	// creating anything, so OptiShade folders in AppData come from the installer.
	// Uninstall is always allowed, so an incomplete set-up can still be removed.
	if modularPayloadBuild && !(len(os.Args) > 1 && os.Args[1] == "--uninstall-app") {
		if gateErr := checkInstallerSetup(original, os.Getenv("LOCALAPPDATA")); gateErr != nil {
			if !updating && !operationProgress {
				showSetupRequired(gateErr)
			}
			os.Exit(1)
		}
	}
	store, portable, err := managerStore(original, os.Getenv("LOCALAPPDATA"))
	if err != nil {
		showStartupError(err)
		os.Exit(1)
	}
	if portable {
		os.Setenv("OPTISHADE_PORTABLE", "1")
	} else {
		os.Unsetenv("OPTISHADE_PORTABLE")
	}
	os.Setenv("OPTISHADE_STORE", store)
	result := ""
	if updating && len(os.Args) > 2 {
		result = os.Args[2]
	}
	markOperationProgressFailure := func(operationErr error) {
		if !operationProgress {
			return
		}
		configData, readErr := os.ReadFile(os.Args[2])
		if readErr != nil {
			return
		}
		var config struct {
			ProgressPath string `json:"ProgressPath"`
		}
		if json.Unmarshal(configData, &config) != nil || config.ProgressPath == "" {
			return
		}
		state := map[string]any{"Title": "OptiShade operation", "Detail": operationErr.Error(), "Completed": 0, "Total": 0, "Status": "Failed"}
		failureData, marshalErr := json.Marshal(state)
		if marshalErr == nil {
			_ = os.WriteFile(config.ProgressPath, failureData, 0600)
		}
	}
	fail := func(err error) {
		if updating {
			folder := store
			os.MkdirAll(folder, 0700)
			os.WriteFile(filepath.Join(folder, "Update-error.txt"), []byte(err.Error()), 0600)
			if result != "" {
				os.WriteFile(result, []byte("ERROR: "+err.Error()), 0600)
			}
		}
		markOperationProgressFailure(err)
		if !updating && !operationProgress {
			showStartupError(err)
		}
		os.Exit(1)
	}
	root := filepath.Join(store, "Sessions")
	if err = os.MkdirAll(root, 0700); err != nil {
		fail(err)
	}
	var required uint64 = 64 * 1024 * 1024
	err = fs.WalkDir(bundle, ".", func(path string, d fs.DirEntry, e error) error {
		if e != nil {
			return e
		}
		if !d.IsDir() {
			info, e := d.Info()
			if e != nil {
				return e
			}
			required += uint64(info.Size())
		}
		return nil
	})
	if err != nil {
		fail(err)
	}
	root, err = chooseExtractionRoot(root, filepath.Join(filepath.Dir(original), "OptiShadeTemp"), required)
	if err != nil {
		fail(err)
	}
	work, err := os.MkdirTemp(root, "setup-")
	if err != nil {
		fail(err)
	}
	defer func() { os.RemoveAll(work); os.Remove(root) }()
	err = fs.WalkDir(bundle, ".", func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if path == "." {
			return nil
		}
		target := filepath.Join(work, filepath.FromSlash(path))
		if d.IsDir() {
			return os.MkdirAll(target, 0700)
		}
		data, e := bundle.ReadFile(path)
		if e != nil {
			return e
		}
		return os.WriteFile(target, data, 0600)
	})
	if err != nil {
		os.RemoveAll(work)
		fail(err)
	}
	args := []string{original}
	if updating {
		args = append(args, os.Args[1])
		os.Remove(filepath.Join(filepath.Dir(root), "Update-error.txt"))
	} else if operationProgress {
		args = append(args, os.Args[1:]...)
	} else if len(os.Args) > 1 && os.Args[1] == "--tray" {
		args = append(args, "--tray")
	} else if len(os.Args) > 1 && os.Args[1] == "--uninstall-app" {
		args = append(args, "--uninstall-app")
	}
	cmd := exec.Command(filepath.Join(work, "FusionSetup.exe"), args...)
	managerEnv := os.Environ()
	filteredEnv := make([]string, 0, len(managerEnv)+1)
	for _, entry := range managerEnv {
		if !strings.HasPrefix(strings.ToUpper(entry), "OPTISHADE_LAUNCHER_PID=") {
			filteredEnv = append(filteredEnv, entry)
		}
	}
	cmd.Env = append(filteredEnv, "OPTISHADE_LAUNCHER_PID="+strconv.Itoa(os.Getpid()))
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: 0x08000000}
	if output, runErr := cmd.CombinedOutput(); runErr != nil {
		if updating {
			detail, _ := os.ReadFile(filepath.Join(filepath.Dir(root), "Update-error.txt"))
			os.RemoveAll(work)
			fail(fmt.Errorf("Update helper failed: %v\n%s\n%s", runErr, output, detail))
		}
		message := fmt.Sprintf("OptiShade could not open: %v\n%s", runErr, output)
		if operationProgress {
			os.RemoveAll(work)
			fail(fmt.Errorf("Operation progress window failed: %v\n%s", runErr, output))
		}
		text, _ := syscall.UTF16PtrFromString(message)
		title, _ := syscall.UTF16PtrFromString("OptiShade setup")
		syscall.NewLazyDLL("user32.dll").NewProc("MessageBoxW").Call(0, uintptr(unsafe.Pointer(text)), uintptr(unsafe.Pointer(title)), 0x10)
	}
	if updating && result != "" {
		if err = os.WriteFile(result, []byte("OK"), 0600); err != nil {
			fail(err)
		}
	}
	// Older updater versions do not clean their recovery copy after success.
	// Only remove the exact sibling backup after the game-update helper succeeded.
	if updating && os.Args[1] == "--apply-update" {
		os.Remove(original + ".previous")
	}
}
