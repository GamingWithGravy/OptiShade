//go:build windows

package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func prepareOwnedUninstallFixture(t *testing.T) (string, string, string) {
	t.Helper()
	root := filepath.Join(t.TempDir(), "Programs", "OptiShade")
	if err := os.MkdirAll(root, 0700); err != nil {
		t.Fatal(err)
	}
	app := []byte("verified OptiShade manager")
	uninstaller := []byte("verified OptiShade uninstaller")
	appPath := filepath.Join(root, "OptiShade.exe")
	uninstallerPath := filepath.Join(root, "Uninstall.exe")
	if err := os.WriteFile(appPath, app, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(uninstallerPath, uninstaller, 0600); err != nil {
		t.Fatal(err)
	}
	appHash := sha256.Sum256(app)
	uninstallerHash := sha256.Sum256(uninstaller)
	receipt := installedAppReceipt{Schema: 1, Version: "1.0.77", SHA256: hex.EncodeToString(appHash[:]), UninstallerSHA256: hex.EncodeToString(uninstallerHash[:])}
	data, err := json.Marshal(receipt)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "install-receipt.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	return root, uninstallerPath, root
}

func TestValidateInstalledAppFilesAcceptsMatchingReceipt(t *testing.T) {
	root, uninstaller, expected := prepareOwnedUninstallFixture(t)
	if err := validateInstalledAppFiles(root, uninstaller, expected); err != nil {
		t.Fatalf("valid AppData ownership receipt was rejected: %v", err)
	}
}

func TestValidateInstalledAppFilesRejectsChangedManagerAndUninstaller(t *testing.T) {
	for _, changed := range []string{"OptiShade.exe", "Uninstall.exe"} {
		t.Run(changed, func(t *testing.T) {
			root, uninstaller, expected := prepareOwnedUninstallFixture(t)
			path := filepath.Join(root, changed)
			if err := os.WriteFile(path, []byte("changed by another process"), 0600); err != nil {
				t.Fatal(err)
			}
			err := validateInstalledAppFiles(root, uninstaller, expected)
			if err == nil || !strings.Contains(err.Error(), "changed since installation") {
				t.Fatalf("changed owned file was not refused: %v", err)
			}
			if _, err := os.Stat(path); err != nil {
				t.Fatalf("validation removed the changed file: %v", err)
			}
		})
	}
}

func TestValidateInstalledAppFilesRejectsForeignRootAndUninstaller(t *testing.T) {
	root, uninstaller, _ := prepareOwnedUninstallFixture(t)
	if err := validateInstalledAppFiles(root, uninstaller, filepath.Join(root, "another-install")); err == nil || !strings.Contains(err.Error(), "registered per-user") {
		t.Fatalf("foreign install root was not rejected: %v", err)
	}
	if err := validateInstalledAppFiles(root, filepath.Join(filepath.Dir(root), "Uninstall.exe"), root); err == nil || !strings.Contains(err.Error(), "registered per-user") {
		t.Fatalf("foreign uninstaller path was not rejected: %v", err)
	}
}

func TestUninstallCleanupRemovesOnlyOptiShadeShortcuts(t *testing.T) {
	for _, keepExtraFile := range []bool{false, true} {
		t.Run(map[bool]string{false: "remove empty Start Menu folder", true: "preserve unrelated Start Menu file"}[keepExtraFile], func(t *testing.T) {
			root := t.TempDir()
			local := filepath.Join(root, "LocalAppData")
			app := filepath.Join(local, "Programs", "OptiShade")
			data := filepath.Join(local, "OptiShade")
			desktop := filepath.Join(root, "Desktop")
			startMenu := filepath.Join(root, "StartMenu")
			startFolder := filepath.Join(startMenu, "Programs", "OptiShade")
			for _, dir := range []string{app, data, desktop, startFolder} {
				if err := os.MkdirAll(dir, 0700); err != nil {
					t.Fatal(err)
				}
			}
			for path, body := range map[string]string{
				filepath.Join(app, "OptiShade.exe"):            "owned manager",
				filepath.Join(data, "Uninstall-Complete.json"): `{"schema":1,"complete":true}`,
				filepath.Join(desktop, "OptiShade.lnk"):        "OptiShade desktop shortcut",
				filepath.Join(startFolder, "OptiShade.lnk"):    "OptiShade Start Menu shortcut",
			} {
				if err := os.WriteFile(path, []byte(body), 0600); err != nil {
					t.Fatal(err)
				}
			}
			if keepExtraFile {
				if err := os.WriteFile(filepath.Join(startFolder, "user-note.txt"), []byte("keep this"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			// The startup entry goes only when it starts this app; another program's stays.
			startupKey := `HKCU:\Software\OptiShadeUninstallTests\` + filepath.Base(root) + `-Run`
			startupTarget := `"` + filepath.Join(app, "OptiShade.exe") + `" --tray`
			if keepExtraFile {
				startupTarget = `"C:\Other\OptiShade.exe" --tray`
			}
			defer exec.Command("powershell.exe", "-NoProfile", "-Command", "Remove-Item -LiteralPath '"+startupKey+"' -Recurse -Force -ErrorAction SilentlyContinue").Run()
			if output, err := exec.Command("powershell.exe", "-NoProfile", "-Command", "New-Item -Path '"+startupKey+"' -Force|Out-Null;New-ItemProperty -LiteralPath '"+startupKey+"' -Name OptiShadeManager -Value '"+startupTarget+"' -Force|Out-Null").CombinedOutput(); err != nil {
				t.Fatalf("could not create the test startup entry: %v %s", err, output)
			}
			cmd := exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", uninstallCleanupScript())
			cmd.Env = overrideEnvironment(os.Environ(), map[string]string{
				"OPTISHADE_REMOVE_STARTUP_KEY":  startupKey,
				"LOCALAPPDATA":                  local,
				"OPTISHADE_REMOVE_APP":          app,
				"OPTISHADE_REMOVE_DATA":         data,
				"OPTISHADE_REMOVE_DESKTOP":      desktop,
				"OPTISHADE_REMOVE_STARTMENU":    startMenu,
				"OPTISHADE_REMOVE_REGISTRY_KEY": `HKCU:\Software\OptiShadeUninstallTests\` + filepath.Base(root),
			})
			if output, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("cleanup script failed: %v\n%s", err, output)
			}
			for _, path := range []string{app, data, filepath.Join(desktop, "OptiShade.lnk"), filepath.Join(startFolder, "OptiShade.lnk")} {
				if _, err := os.Lstat(path); !os.IsNotExist(err) {
					t.Errorf("OptiShade-owned path remains after cleanup: %s (err=%v)", path, err)
				}
			}
			remaining, _ := exec.Command("powershell.exe", "-NoProfile", "-Command", "[string](Get-ItemProperty -LiteralPath '"+startupKey+"' -Name OptiShadeManager -ErrorAction SilentlyContinue).OptiShadeManager").Output()
			if left := strings.TrimSpace(string(remaining)); keepExtraFile && left == "" {
				t.Errorf("a startup entry for another program was removed")
			} else if !keepExtraFile && left != "" {
				t.Errorf("OptiShade's startup entry remains after uninstall: %s", left)
			}
			if keepExtraFile {
				if _, err := os.Stat(filepath.Join(startFolder, "user-note.txt")); err != nil {
					t.Fatalf("unrelated Start Menu file was removed: %v", err)
				}
			} else if _, err := os.Lstat(startFolder); !os.IsNotExist(err) {
				t.Fatalf("empty OptiShade Start Menu folder remains: %v", err)
			}
		})
	}
}

func overrideEnvironment(base []string, replacements map[string]string) []string {
	out := make([]string, 0, len(base)+len(replacements))
	for _, entry := range base {
		name, _, found := strings.Cut(entry, "=")
		if found {
			if _, replace := replacements[strings.ToUpper(name)]; replace {
				continue
			}
		}
		out = append(out, entry)
	}
	for name, value := range replacements {
		out = append(out, name+"="+value)
	}
	return out
}
