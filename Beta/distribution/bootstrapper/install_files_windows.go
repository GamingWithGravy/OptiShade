//go:build windows

package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type installedLauncherPaths struct {
	App         string
	Uninstaller string
	Receipt     string
}

// installVerifiedLauncherFiles performs only the AppData file transaction.
// Network access, registry entries, shortcuts, prompts, and process launch are
// deliberately kept outside so the transaction can be exercised in a sandbox.
func installVerifiedLauncherFiles(packagePath string, payload channelPayload, dir string) (installedLauncherPaths, error) {
	paths := installedLauncherPaths{
		App:         filepath.Join(dir, "OptiShade.exe"),
		Uninstaller: filepath.Join(dir, "Uninstall.exe"),
		Receipt:     filepath.Join(dir, "install-receipt.json"),
	}
	if err := rejectReparsePath(dir); err != nil {
		return paths, fmt.Errorf("unsafe OptiShade install folder: %w", err)
	}
	var prior launcherInstallReceipt
	currentAppHash, currentUninstallerHash := "", ""
	if _, err := os.Lstat(paths.App); err == nil {
		if err = rejectReparsePath(paths.App); err != nil {
			return paths, fmt.Errorf("existing launcher is unsafe: %w", err)
		}
		if err = rejectReparsePath(paths.Receipt); err != nil {
			return paths, errors.New("existing launcher receipt is missing or unsafe; existing files were left untouched")
		}
		data, readErr := os.ReadFile(paths.Receipt)
		if readErr != nil || len(data) > 64*1024 || json.Unmarshal(data, &prior) != nil || prior.Schema != 1 {
			return paths, errors.New("the existing OptiShade receipt is unreadable; existing files were left untouched")
		}
		currentAppHash, err = hashFile(paths.App)
		if err != nil {
			return paths, err
		}
		if !strings.EqualFold(currentAppHash, prior.SHA256) {
			return paths, errors.New("the existing OptiShade executable changed since installation; it was left untouched")
		}
		if _, err = os.Lstat(paths.Uninstaller); err == nil {
			if err = rejectReparsePath(paths.Uninstaller); err != nil {
				return paths, fmt.Errorf("existing uninstaller is unsafe: %w", err)
			}
			if prior.UninstallerSHA256 == "" {
				return paths, errors.New("an untracked Uninstall.exe exists; it was preserved for review")
			}
			currentUninstallerHash, err = hashFile(paths.Uninstaller)
			if err != nil || !strings.EqualFold(currentUninstallerHash, prior.UninstallerSHA256) {
				return paths, errors.New("the existing uninstaller changed since installation; it was left untouched")
			}
		} else if !os.IsNotExist(err) {
			return paths, err
		} else if prior.UninstallerSHA256 != "" {
			return paths, errors.New("the recorded uninstaller is missing; repair the OptiShade application before updating")
		}
	} else if !os.IsNotExist(err) {
		return paths, err
	} else {
		if _, err = os.Lstat(paths.Receipt); err == nil {
			return paths, errors.New("the manager is missing but its install receipt remains; existing files were left untouched for repair")
		} else if !os.IsNotExist(err) {
			return paths, err
		}
		if _, err = os.Lstat(paths.Uninstaller); err == nil {
			return paths, errors.New("an Uninstall.exe exists without its verified manager and receipt; it was left untouched for review")
		} else if !os.IsNotExist(err) {
			return paths, err
		}
	}

	appNew := paths.App + ".new"
	uninstallerNew := paths.Uninstaller + ".new"
	appBackup := paths.App + ".installer-previous"
	uninstallerBackup := paths.Uninstaller + ".installer-previous"
	cleanupStaging := func() {
		_ = os.Remove(appNew)
		_ = os.Remove(uninstallerNew)
	}
	if err := copyFile(packagePath, appNew); err != nil {
		return paths, err
	}
	newInfo, err := os.Stat(appNew)
	if err != nil || newInfo.Size() != payload.Package.Bytes {
		cleanupStaging()
		return paths, errors.New("the staged launcher size did not match its signed manifest")
	}
	newHash, err := hashFile(appNew)
	if err != nil || len(payload.Package.SHA256) != 64 || !strings.EqualFold(newHash, payload.Package.SHA256) {
		cleanupStaging()
		return paths, errors.New("the staged launcher failed SHA-256 verification; nothing was installed")
	}
	if err = removeRecordedRecoveryBackups(appBackup, prior.PreviousSHA256, uninstallerBackup, prior.PreviousUninstallerSHA256); err != nil {
		cleanupStaging()
		return paths, err
	}

	appMoved, uninstallerMoved := false, false
	appInstalled, uninstallerInstalled := false, false
	rollback := func(cause error) error {
		var rollbackErrors []string
		if uninstallerInstalled {
			if err := os.Remove(paths.Uninstaller); err != nil && !os.IsNotExist(err) {
				rollbackErrors = append(rollbackErrors, "remove new uninstaller: "+err.Error())
			}
		}
		cleanupStaging()
		if uninstallerMoved {
			if err := os.Rename(uninstallerBackup, paths.Uninstaller); err != nil {
				rollbackErrors = append(rollbackErrors, "restore previous uninstaller: "+err.Error())
			}
		}
		if appInstalled {
			if err := os.Remove(paths.App); err != nil && !os.IsNotExist(err) {
				rollbackErrors = append(rollbackErrors, "remove new manager: "+err.Error())
			}
		}
		if appMoved {
			if err := os.Rename(appBackup, paths.App); err != nil {
				rollbackErrors = append(rollbackErrors, "restore previous manager: "+err.Error())
			}
		}
		if len(rollbackErrors) != 0 {
			return fmt.Errorf("%w; rollback needs attention: %s", cause, strings.Join(rollbackErrors, "; "))
		}
		return cause
	}

	if _, err := os.Lstat(paths.App); err == nil {
		if err = os.Rename(paths.App, appBackup); err != nil {
			cleanupStaging()
			return paths, fmt.Errorf("could not safely move the previous launcher: %w", err)
		}
		appMoved = true
	} else if !os.IsNotExist(err) {
		cleanupStaging()
		return paths, err
	}
	if err = os.Rename(appNew, paths.App); err != nil {
		return paths, rollback(err)
	}
	appInstalled = true
	if err = copyFile(paths.App, uninstallerNew); err != nil {
		return paths, rollback(fmt.Errorf("could not stage the app-local uninstaller: %w", err))
	}
	uninstallerHash, err := hashFile(uninstallerNew)
	if err != nil || uninstallerHash != newHash {
		return paths, rollback(errors.New("the staged uninstaller did not match the verified manager executable"))
	}
	if _, err = os.Lstat(paths.Uninstaller); err == nil {
		if err = os.Rename(paths.Uninstaller, uninstallerBackup); err != nil {
			return paths, rollback(fmt.Errorf("could not safely move the previous uninstaller: %w", err))
		}
		uninstallerMoved = true
	} else if !os.IsNotExist(err) {
		return paths, rollback(err)
	}
	if err = os.Rename(uninstallerNew, paths.Uninstaller); err != nil {
		return paths, rollback(err)
	}
	uninstallerInstalled = true

	next := launcherInstallReceipt{
		Schema: 1, Version: payload.Version, SHA256: newHash, UninstallerSHA256: uninstallerHash,
		PreviousSHA256: currentAppHash, PreviousUninstallerSHA256: currentUninstallerHash,
	}
	receiptData, err := json.Marshal(next)
	if err != nil {
		return paths, rollback(err)
	}
	if err = atomicWrite(paths.Receipt, receiptData); err != nil {
		return paths, rollback(err)
	}
	return paths, nil
}
