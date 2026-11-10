// Copyright (c) 2026 gravy / GamingWithGravy. All Rights Reserved.
// OptiShade Proprietary Material: standalone launcher source only.
// See LICENSES/OPTISHADE-PROPRIETARY.txt and OPTISHADE_LICENSING.md.
// Earlier GPL grants and applicable platform permissions remain intact.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

// The OptiShade installer (Beta/distribution/bootstrapper) creates the
// launcher's AppData folders and then writes this record. The modular launcher
// only runs when it is present, so a launcher EXE copied or downloaded on its
// own cannot start and never creates OptiShade folders in AppData itself.
const installSetupRecordName = "install-setup.json"
const installSetupRecordSchema = 1

type installSetupRecord struct {
	Schema   int      `json:"Schema"`
	App      string   `json:"App"`
	Version  string   `json:"Version"`
	SetupUtc string   `json:"SetupUtc"`
	Folders  []string `json:"Folders"`
}

type agreementRecord struct {
	Accepted         bool `json:"Accepted"`
	AgreementVersion int  `json:"AgreementVersion"`
}

var errInstallerSetupMissing = errors.New("OptiShade has not been set up by the OptiShade installer")

// checkInstallerSetup reads only; it never creates anything.
func checkInstallerSetup(executable, localAppData string) error {
	if !filepath.IsAbs(localAppData) || !filepath.IsAbs(executable) {
		return fmt.Errorf("%w: Windows did not provide a valid Local AppData folder", errInstallerSetupMissing)
	}
	store := filepath.Join(localAppData, "OptiShade")
	info, err := os.Lstat(store)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("%w: its data folder does not exist", errInstallerSetupMissing)
	}
	data, err := os.ReadFile(filepath.Join(store, installSetupRecordName))
	if err != nil {
		return fmt.Errorf("%w: the installer's set-up record is missing", errInstallerSetupMissing)
	}
	var record installSetupRecord
	if json.Unmarshal(data, &record) != nil || record.Schema != installSetupRecordSchema || record.App == "" || !filepath.IsAbs(record.App) {
		return fmt.Errorf("%w: the installer's set-up record is not valid", errInstallerSetupMissing)
	}
	if !strings.EqualFold(filepath.Clean(record.App), filepath.Clean(executable)) {
		return fmt.Errorf("%w: this copy is not the installed OptiShade (%s)", errInstallerSetupMissing, record.App)
	}
	for _, folder := range record.Folders {
		path := filepath.Join(localAppData, filepath.FromSlash(folder))
		if rel, relErr := filepath.Rel(localAppData, path); relErr != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			return fmt.Errorf("%w: the installer's set-up record is not valid", errInstallerSetupMissing)
		}
		if folderInfo, statErr := os.Lstat(path); statErr != nil || !folderInfo.IsDir() {
			return fmt.Errorf("%w: a required folder is missing (%s)", errInstallerSetupMissing, folder)
		}
	}
	agreementData, err := os.ReadFile(filepath.Join(store, "user-agreement-acceptance.json"))
	var agreement agreementRecord
	if err != nil || json.Unmarshal(agreementData, &agreement) != nil || !agreement.Accepted || agreement.AgreementVersion < 1 {
		return fmt.Errorf("%w: the User Agreement has not been accepted in the installer", errInstallerSetupMissing)
	}
	return nil
}

// showSetupRequired explains, in an OptiShade window, that the installer must
// be run. The window's files go in a Windows temporary folder that is removed
// when it closes; nothing is written to OptiShade's AppData folders.
func showSetupRequired(reason error) {
	if err := showSetupRequiredWindow(reason); err != nil {
		text, _ := syscall.UTF16PtrFromString("OptiShade needs to be installed with the OptiShade installer before it can open.\n\n" + reason.Error())
		title, _ := syscall.UTF16PtrFromString("OptiShade")
		syscall.NewLazyDLL("user32.dll").NewProc("MessageBoxW").Call(0, uintptr(unsafe.Pointer(text)), uintptr(unsafe.Pointer(title)), 0x30)
	}
}

func showSetupRequiredWindow(reason error) error {
	dir, err := os.MkdirTemp("", "OptiShade-setup-required-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	files := map[string]string{"FusionSetup.exe": "FusionSetup.exe", "setup-required.ps1": "installer-ui.ps1", "OptiShade-icon.png": "OptiShade-icon.png"}
	for source, target := range files {
		data, readErr := bundle.ReadFile(source)
		if readErr != nil {
			return readErr
		}
		if writeErr := os.WriteFile(filepath.Join(dir, target), data, 0600); writeErr != nil {
			return writeErr
		}
	}
	config, err := json.Marshal(map[string]string{"IconPath": filepath.Join(dir, "OptiShade-icon.png"), "Reason": reason.Error(), "DownloadUrl": "https://github.com/GamingWithGravy/OptiShade/releases/latest"})
	if err != nil {
		return err
	}
	configPath := filepath.Join(dir, "config.json")
	if err = os.WriteFile(configPath, config, 0600); err != nil {
		return err
	}
	cmd := exec.Command(filepath.Join(dir, "FusionSetup.exe"), "--installer-ui", configPath)
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: 0x08000000}
	return cmd.Run()
}
