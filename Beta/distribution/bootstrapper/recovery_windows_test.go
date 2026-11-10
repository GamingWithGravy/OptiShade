//go:build windows

package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func launcherTestPayload(t *testing.T, root, version string, body []byte) (string, channelPayload) {
	t.Helper()
	packagePath := filepath.Join(root, "downloaded-manager.exe")
	if err := os.WriteFile(packagePath, body, 0600); err != nil {
		t.Fatal(err)
	}
	payload := channelPayload{Version: version}
	payload.Package.Bytes = int64(len(body))
	payload.Package.SHA256 = hex.EncodeToString(sha256Sum(body))
	return packagePath, payload
}

func TestInstallVerifiedLauncherFilesCleanInstallAndThreeUpgradeRotation(t *testing.T) {
	root := t.TempDir()
	installDir := filepath.Join(root, "app")
	if err := os.Mkdir(installDir, 0700); err != nil {
		t.Fatal(err)
	}
	selfUpdaterBackup := filepath.Join(installDir, "OptiShade.exe.previous")
	if err := os.WriteFile(selfUpdaterBackup, []byte("manager self-updater recovery"), 0600); err != nil {
		t.Fatal(err)
	}

	var priorManager, priorUninstaller []byte
	for i, body := range [][]byte{[]byte("manager v1"), []byte("manager v2"), []byte("manager v3")} {
		packagePath, payload := launcherTestPayload(t, root, string(rune('1'+i)), body)
		installed, err := installVerifiedLauncherFiles(packagePath, payload, installDir)
		if err != nil {
			t.Fatalf("install %d failed: %v", i+1, err)
		}
		got, err := os.ReadFile(installed.App)
		if err != nil || string(got) != string(body) {
			t.Fatalf("install %d manager mismatch: %q, %v", i+1, got, err)
		}
		gotUninstaller, err := os.ReadFile(installed.Uninstaller)
		if err != nil || string(gotUninstaller) != string(body) {
			t.Fatalf("install %d uninstaller mismatch: %q, %v", i+1, gotUninstaller, err)
		}
		if i == 0 {
			if _, err := os.Lstat(installed.App + ".installer-previous"); !os.IsNotExist(err) {
				t.Fatalf("clean install unexpectedly created previous manager: %v", err)
			}
		} else {
			backup, err := os.ReadFile(installed.App + ".installer-previous")
			if err != nil || string(backup) != string(priorManager) {
				t.Fatalf("upgrade %d did not preserve immediately prior manager: %q, %v", i+1, backup, err)
			}
			backup, err = os.ReadFile(installed.Uninstaller + ".installer-previous")
			if err != nil || string(backup) != string(priorUninstaller) {
				t.Fatalf("upgrade %d did not preserve immediately prior uninstaller: %q, %v", i+1, backup, err)
			}
		}
		priorManager, priorUninstaller = append([]byte(nil), body...), append([]byte(nil), body...)
	}
	if got, err := os.ReadFile(selfUpdaterBackup); err != nil || string(got) != "manager self-updater recovery" {
		t.Fatalf("installer modified the manager self-updater backup: %q, %v", got, err)
	}
	var receipt launcherInstallReceipt
	data, err := os.ReadFile(filepath.Join(installDir, "install-receipt.json"))
	if err != nil || json.Unmarshal(data, &receipt) != nil {
		t.Fatalf("install receipt unreadable: %v", err)
	}
	if receipt.Version != "3" || receipt.SHA256 != hex.EncodeToString(sha256Sum([]byte("manager v3"))) || receipt.PreviousSHA256 != hex.EncodeToString(sha256Sum([]byte("manager v2"))) {
		t.Fatalf("unexpected final receipt state: %+v", receipt)
	}
}

func TestInstallVerifiedLauncherFilesPreservesForeignInstall(t *testing.T) {
	root := t.TempDir()
	installDir := filepath.Join(root, "app")
	if err := os.Mkdir(installDir, 0700); err != nil {
		t.Fatal(err)
	}
	app := filepath.Join(installDir, "OptiShade.exe")
	foreign := []byte("user-owned manager")
	if err := os.WriteFile(app, foreign, 0600); err != nil {
		t.Fatal(err)
	}
	packagePath, payload := launcherTestPayload(t, root, "2", []byte("new manager"))
	if _, err := installVerifiedLauncherFiles(packagePath, payload, installDir); err == nil || !strings.Contains(err.Error(), "receipt") {
		t.Fatalf("foreign install was not rejected safely: %v", err)
	}
	got, err := os.ReadFile(app)
	if err != nil || string(got) != string(foreign) {
		t.Fatalf("foreign manager was changed: %q, %v", got, err)
	}
}

func TestInstallVerifiedLauncherFilesRejectsTamperedPackageWithoutMutation(t *testing.T) {
	root := t.TempDir()
	installDir := filepath.Join(root, "app")
	if err := os.Mkdir(installDir, 0700); err != nil {
		t.Fatal(err)
	}
	packagePath, payload := launcherTestPayload(t, root, "1", []byte("manager"))
	payload.Package.SHA256 = strings.Repeat("0", 64)
	if _, err := installVerifiedLauncherFiles(packagePath, payload, installDir); err == nil || !strings.Contains(err.Error(), "SHA-256") {
		t.Fatalf("tampered package was not rejected: %v", err)
	}
	for _, name := range []string{"OptiShade.exe", "Uninstall.exe", "install-receipt.json", "OptiShade.exe.new", "Uninstall.exe.new"} {
		if _, err := os.Lstat(filepath.Join(installDir, name)); !os.IsNotExist(err) {
			t.Errorf("failed install left or modified %s: %v", name, err)
		}
	}
}

func TestRemoveRecordedRecoveryBackupsOnlyRemovesReceiptMatches(t *testing.T) {
	root := t.TempDir()
	app := filepath.Join(root, "OptiShade.exe.installer-previous")
	uninstaller := filepath.Join(root, "Uninstall.exe.installer-previous")
	appData := []byte("previous manager")
	uninstallerData := []byte("previous uninstaller")
	if err := os.WriteFile(app, appData, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(uninstaller, uninstallerData, 0600); err != nil {
		t.Fatal(err)
	}
	appHash := sha256.Sum256(appData)
	uninstallerHash := sha256.Sum256(uninstallerData)
	appDigest := hex.EncodeToString(appHash[:])
	uninstallerDigest := hex.EncodeToString(uninstallerHash[:])
	if err := removeRecordedRecoveryBackups(app, appDigest, uninstaller, uninstallerDigest); err != nil {
		t.Fatalf("receipt-matched recovery files rejected: %v", err)
	}
	for _, path := range []string{app, uninstaller} {
		if _, err := os.Lstat(path); !os.IsNotExist(err) {
			t.Errorf("verified stale backup remains at %s", path)
		}
	}
}

func TestRecoveryRotationPreservesUnknownOrChangedFiles(t *testing.T) {
	root := t.TempDir()
	app := filepath.Join(root, "OptiShade.exe.installer-previous")
	uninstaller := filepath.Join(root, "Uninstall.exe.installer-previous")
	if err := os.WriteFile(app, []byte("owned prior"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(uninstaller, []byte("untracked"), 0600); err != nil {
		t.Fatal(err)
	}
	appHash := sha256.Sum256([]byte("owned prior"))
	err := removeRecordedRecoveryBackups(app, hex.EncodeToString(appHash[:]), uninstaller, "")
	if err == nil || !strings.Contains(err.Error(), "unrecorded") {
		t.Fatalf("unrecorded recovery file was not rejected: %v", err)
	}
	for _, path := range []string{app, uninstaller} {
		if _, err = os.Stat(path); err != nil {
			t.Errorf("preflight changed a recovery file before validating all files: %v", err)
		}
	}

	err = removeRecordedRecoveryBackups(app, strings.Repeat("0", 64), uninstaller, hex.EncodeToString(sha256Sum([]byte("untracked"))))
	if err == nil || !strings.Contains(err.Error(), "no longer matches") {
		t.Fatalf("modified recovery file was not rejected: %v", err)
	}
	for _, path := range []string{app, uninstaller} {
		if _, err = os.Stat(path); err != nil {
			t.Errorf("mismatched recovery files were removed: %v", err)
		}
	}
}

func sha256Sum(data []byte) []byte {
	h := sha256.Sum256(data)
	return h[:]
}
