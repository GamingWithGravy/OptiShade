//go:build windows

package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

type installedAppReceipt struct {
	Schema            int    `json:"schema"`
	Version           string `json:"version"`
	SHA256            string `json:"sha256"`
	UninstallerSHA256 string `json:"uninstallerSha256"`
}

// uninstallInstalledApp is called only when this binary is running from the
// exact per-user OptiShade application folder as Uninstall.exe. It delegates
// game-file restoration and the user's uninstall choices to the manager's
// existing ownership/backup transaction, and deletes AppData only after that
// transaction reports success.
func uninstallInstalledApp(uninstaller string) error {
	local := os.Getenv("LOCALAPPDATA")
	if !filepath.IsAbs(local) {
		return errors.New("Windows did not provide a valid per-user Local AppData directory.")
	}
	if err := rejectUninstallReparsePath(local); err != nil {
		return fmt.Errorf("unsafe Local AppData path: %w", err)
	}
	root, err := filepath.Abs(filepath.Dir(uninstaller))
	if err != nil {
		return err
	}
	expected := filepath.Join(local, "Programs", "OptiShade")
	if err = rejectUninstallReparsePath(filepath.Join(local, "Programs")); err != nil {
		return fmt.Errorf("unsafe OptiShade Programs folder: %w", err)
	}
	app := filepath.Join(root, "OptiShade.exe")
	if err = validateInstalledAppFiles(root, uninstaller, expected); err != nil {
		return err
	}
	store := filepath.Join(local, "OptiShade")
	if err = os.MkdirAll(store, 0700); err != nil {
		return fmt.Errorf("could not prepare the uninstall result folder: %w", err)
	}
	if err = rejectUninstallReparsePath(store); err != nil {
		return fmt.Errorf("unsafe OptiShade data folder: %w", err)
	}
	marker := filepath.Join(store, "Uninstall-Complete.json")
	cancelled := filepath.Join(store, "Uninstall-Cancelled.json")
	for _, stale := range []string{marker, cancelled} {
		if err = os.Remove(stale); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("could not clear the previous uninstall result: %w", err)
		}
	}
	// The manager's uninstall page explains what happens and is the confirmation.
	cmd := exec.Command(app, "--uninstall-app")
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: 0x08000000}
	if err = cmd.Start(); err != nil {
		return fmt.Errorf("could not open the OptiShade uninstall wizard: %w", err)
	}
	if err = cmd.Wait(); err != nil {
		return fmt.Errorf("the OptiShade uninstall wizard did not finish successfully: %w. App files were preserved.", err)
	}
	if _, statErr := os.Stat(cancelled); statErr == nil {
		_ = os.Remove(cancelled)
		return nil
	}
	result, err := os.ReadFile(marker)
	if err != nil || len(result) > 16*1024 {
		return errors.New("The uninstall wizard was cancelled or did not confirm that game files were restored. App files were preserved.")
	}
	var completed struct {
		Schema      int    `json:"schema"`
		Complete    bool   `json:"complete"`
		InstallRoot string `json:"installRoot"`
	}
	if json.Unmarshal(result, &completed) != nil || completed.Schema != 1 || !completed.Complete || !strings.EqualFold(filepath.Clean(completed.InstallRoot), filepath.Clean(root)) {
		return errors.New("The uninstall wizard returned an invalid completion record. App files were preserved.")
	}
	// The running uninstaller cannot delete itself. A narrowly scoped cleanup
	// process waits for it to exit, rechecks the exact roots, and removes only
	// OptiShade's own app directory, local data, shortcuts and registration.
	cleanup := uninstallCleanupScript()
	cleanupCmd := exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-Command", cleanup)
	cleanupCmd.Env = append(os.Environ(), "OPTISHADE_REMOVE_APP="+root, "OPTISHADE_REMOVE_DATA="+store)
	cleanupCmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: 0x08000000, HideWindow: true}
	// Never run from inside a folder it is about to delete: Windows keeps a
	// process's working folder in use, so the app folder could not be removed.
	cleanupCmd.Dir = os.TempDir()
	if err = cleanupCmd.Start(); err != nil {
		return fmt.Errorf("game installations were restored, but final app cleanup could not start: %w", err)
	}
	return nil
}

func uninstallCleanupScript() string {
	return `$ErrorActionPreference='Stop';Start-Sleep -Seconds 2;$local=[IO.Path]::GetFullPath($env:LOCALAPPDATA);$app=[IO.Path]::GetFullPath($env:OPTISHADE_REMOVE_APP);$data=[IO.Path]::GetFullPath($env:OPTISHADE_REMOVE_DATA);$expectedApp=[IO.Path]::GetFullPath((Join-Path $local 'Programs/OptiShade'));$expectedData=[IO.Path]::GetFullPath((Join-Path $local 'OptiShade'));if($app -ine $expectedApp -or $data -ine $expectedData){throw 'OptiShade cleanup path validation failed'};$marker=Join-Path $data 'Uninstall-Complete.json';if(-not(Test-Path -LiteralPath $marker -PathType Leaf)){throw 'OptiShade cleanup completion record is missing'};$desktopRoot=if($env:OPTISHADE_REMOVE_DESKTOP){$env:OPTISHADE_REMOVE_DESKTOP}else{[Environment]::GetFolderPath('Desktop')};$startMenuRoot=if($env:OPTISHADE_REMOVE_STARTMENU){$env:OPTISHADE_REMOVE_STARTMENU}else{[Environment]::GetFolderPath('StartMenu')};$desktop=Join-Path $desktopRoot 'OptiShade.lnk';$startFolder=Join-Path (Join-Path $startMenuRoot 'Programs') 'OptiShade';$startLink=Join-Path $startFolder 'OptiShade.lnk';Remove-Item -LiteralPath $desktop -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $startLink -Force -ErrorAction SilentlyContinue;if((Test-Path -LiteralPath $startFolder -PathType Container) -and -not @(Get-ChildItem -LiteralPath $startFolder -Force).Count){Remove-Item -LiteralPath $startFolder -Force};$registryKey=if($env:OPTISHADE_REMOVE_REGISTRY_KEY){$env:OPTISHADE_REMOVE_REGISTRY_KEY}else{'HKCU:/Software/Microsoft/Windows/CurrentVersion/Uninstall/OptiShade'};Remove-Item -LiteralPath $registryKey -Recurse -Force -ErrorAction SilentlyContinue;$startupKey=if($env:OPTISHADE_REMOVE_STARTUP_KEY){$env:OPTISHADE_REMOVE_STARTUP_KEY}else{'HKCU:/Software/Microsoft/Windows/CurrentVersion/Run'};$startup=(Get-ItemProperty -LiteralPath $startupKey -Name OptiShadeManager -ErrorAction SilentlyContinue).OptiShadeManager;if($startup -and ([string]$startup).IndexOf($app,[StringComparison]::OrdinalIgnoreCase) -ge 0){Remove-ItemProperty -LiteralPath $startupKey -Name OptiShadeManager -ErrorAction SilentlyContinue};$last='';for($try=0;$try -lt 30 -and ((Test-Path -LiteralPath $app) -or (Test-Path -LiteralPath $data));$try++){try{if(Test-Path -LiteralPath $app){Remove-Item -LiteralPath $app -Recurse -Force};if(Test-Path -LiteralPath $data){Remove-Item -LiteralPath $data -Recurse -Force}}catch{$last=$_.Exception.Message;Start-Sleep -Seconds 1}};if((Test-Path -LiteralPath $app) -or (Test-Path -LiteralPath $data)){$note=Join-Path ([IO.Path]::GetTempPath()) 'OptiShade-uninstall-cleanup.txt';[IO.File]::WriteAllText($note,('OptiShade uninstall could not remove: '+$app+' / '+$data+' ('+$last+')'))}`
}

// validateInstalledAppFiles is kept separate from UI/process orchestration so
// ownership and path safety can be regression-tested with isolated folders.
func validateInstalledAppFiles(root, uninstaller, expectedRoot string) error {
	root, err := filepath.Abs(root)
	if err != nil {
		return err
	}
	uninstaller, err = filepath.Abs(uninstaller)
	if err != nil {
		return err
	}
	expectedRoot, err = filepath.Abs(expectedRoot)
	if err != nil {
		return err
	}
	if !strings.EqualFold(filepath.Clean(root), filepath.Clean(expectedRoot)) || !strings.EqualFold(filepath.Base(uninstaller), "Uninstall.exe") || !strings.EqualFold(filepath.Dir(uninstaller), filepath.Clean(root)) {
		return errors.New("This uninstaller is not running from the registered per-user OptiShade application folder. Nothing was removed.")
	}
	if err = rejectUninstallReparsePath(root); err != nil {
		return fmt.Errorf("unsafe OptiShade application folder: %w", err)
	}
	app := filepath.Join(root, "OptiShade.exe")
	receiptPath := filepath.Join(root, "install-receipt.json")
	if err = rejectUninstallReparsePath(app); err != nil {
		return fmt.Errorf("OptiShade manager is missing or unsafe: %w", err)
	}
	if err = rejectUninstallReparsePath(uninstaller); err != nil {
		return fmt.Errorf("OptiShade uninstaller is missing or unsafe: %w", err)
	}
	if err = rejectUninstallReparsePath(receiptPath); err != nil {
		return errors.New("The installation receipt is missing or unsafe. Existing files were left untouched.")
	}
	data, err := os.ReadFile(receiptPath)
	if err != nil || len(data) > 64*1024 {
		return errors.New("The OptiShade installation receipt is unreadable. Existing files were left untouched.")
	}
	var receipt installedAppReceipt
	if json.Unmarshal(data, &receipt) != nil || receipt.Schema != 1 || len(receipt.SHA256) != 64 || len(receipt.UninstallerSHA256) != 64 {
		return errors.New("The OptiShade installation receipt does not prove ownership of both application files. Existing files were left untouched.")
	}
	appHash, err := hashUninstallFile(app)
	if err != nil || !strings.EqualFold(appHash, receipt.SHA256) {
		return errors.New("The OptiShade manager changed since installation. Repair or review it before uninstalling; no files were removed.")
	}
	uninstallerHash, err := hashUninstallFile(uninstaller)
	if err != nil || !strings.EqualFold(uninstallerHash, receipt.UninstallerSHA256) {
		return errors.New("The uninstaller changed since installation. Repair or review it before uninstalling; no files were removed.")
	}
	return nil
}

func hashUninstallFile(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err = io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func rejectUninstallReparsePath(path string) error {
	p, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	attributes, _, callErr := syscall.NewLazyDLL("kernel32.dll").NewProc("GetFileAttributesW").Call(uintptr(unsafe.Pointer(p)))
	if uint32(attributes) == 0xffffffff {
		if callErr != syscall.Errno(0) {
			return callErr
		}
		return os.ErrNotExist
	}
	if attributes&0x400 != 0 {
		return errors.New("path contains a Windows reparse point")
	}
	return nil
}

func uninstallMessage(title, text string, kind uintptr) int {
	t, _ := syscall.UTF16PtrFromString(title)
	m, _ := syscall.UTF16PtrFromString(text)
	r, _, _ := syscall.NewLazyDLL("user32.dll").NewProc("MessageBoxW").Call(0, uintptr(unsafe.Pointer(m)), uintptr(unsafe.Pointer(t)), kind)
	return int(r)
}
