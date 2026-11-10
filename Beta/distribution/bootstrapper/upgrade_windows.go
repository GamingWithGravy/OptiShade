//go:build windows

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
)

// existingInstall describes an OptiShade launcher from an earlier private test
// build (or its data folder) found before installing. ui/upgrade.ps1 does the
// detection, closing and clean-up; see the comment at its top for what it keeps.
type existingInstall struct {
	Found    bool     `json:"Found"`
	Versions []string `json:"Versions"`
	Copies   []string `json:"Copies"`
	Games    int      `json:"Games"`
	Running  int      `json:"Running"`
}

type upgradeCloseResult struct {
	Running []string `json:"Running"`
}

type upgradeCleanupResult struct {
	Done []string `json:"Done"`
	Kept []string `json:"Kept"`
}

func runUpgradeScript(mode, app, known string, result any) error {
	dir, err := os.MkdirTemp("", "OptiShade-upgrade-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	script, err := uiFiles.ReadFile("ui/upgrade.ps1")
	if err != nil {
		return err
	}
	scriptPath := filepath.Join(dir, "upgrade.ps1")
	out := filepath.Join(dir, "result.json")
	if err = os.WriteFile(scriptPath, script, 0600); err != nil {
		return err
	}
	args := []string{"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", scriptPath, "-Mode", mode, "-Out", out}
	if app != "" {
		args = append(args, "-App", app)
	}
	if known != "" {
		args = append(args, "-Known", known)
	}
	cmd := exec.Command("powershell.exe", args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: 0x08000000}
	if output, runErr := cmd.CombinedOutput(); runErr != nil {
		return fmt.Errorf("%v %s", runErr, strings.TrimSpace(string(output)))
	}
	data, err := os.ReadFile(out)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, result)
}

// detectExistingInstall never changes anything; a failure means "nothing found".
func detectExistingInstall() existingInstall {
	var found existingInstall
	if runUpgradeScript("Detect", "", "", &found) != nil {
		return existingInstall{}
	}
	return found
}

// closeExistingLaunchers asks running older launchers to close. It does not
// force them, because one may be in the middle of changing a game.
func closeExistingLaunchers() error {
	var result upgradeCloseResult
	if err := runUpgradeScript("Close", "", "", &result); err != nil {
		return fmt.Errorf("could not check for a running OptiShade: %w", err)
	}
	if len(result.Running) > 0 {
		return errors.New("another OptiShade is still running. Close it from its system tray icon (right-click, Exit), then run the installer again. Nothing was changed")
	}
	return nil
}

// cleanUpExistingInstall runs after the new launcher is installed and verified.
func cleanUpExistingInstall(app string, known []string) (upgradeCleanupResult, error) {
	var result upgradeCleanupResult
	err := runUpgradeScript("Cleanup", app, strings.Join(known, "|"), &result)
	return result, err
}

func existingSummary(found existingInstall) string {
	parts := []string{}
	if len(found.Versions) > 0 {
		parts = append(parts, "version "+strings.Join(found.Versions, ", "))
	}
	if len(found.Copies) > 0 {
		shown := found.Copies
		if len(shown) > 3 {
			shown = shown[:3]
		}
		more := ""
		if len(found.Copies) > 3 {
			more = fmt.Sprintf(" and %d more", len(found.Copies)-3)
		}
		parts = append(parts, "old launcher: "+strings.Join(shown, "; ")+more)
	}
	if found.Games > 0 {
		parts = append(parts, fmt.Sprintf("%d game(s) set up", found.Games))
	}
	if len(parts) == 0 {
		return "OptiShade settings from an earlier version"
	}
	return strings.Join(parts, ", ")
}

// The wording the owner asked for; existingSummary adds what was found.
func existingPrompt(found existingInstall) string {
	return "Another version of OptiShade has been detected on this system (" + existingSummary(found) + ").\n\n" +
		"Would you like to run a clean up? This removes the old OptiShade launcher and its temporary files, " +
		"and keeps your current ini files, snapshots and settings. Games set up with OptiShade stay as they are."
}

// runCleanUp reports what it did as the finished page's detail text. Anything it
// could not do is a note, not a failure: the new launcher is already installed.
func runCleanUp(app string, known []string, warn func(string)) string {
	result, err := cleanUpExistingInstall(app, known)
	if err != nil {
		warn("The clean up of the other OptiShade version did not finish: " + err.Error())
		return ""
	}
	for _, kept := range result.Kept {
		warn(kept)
	}
	detail := "The OptiShade launcher is installed and verified. Clean up finished; your ini files, snapshots and settings were kept."
	if len(result.Done) > 0 {
		detail += "\n- " + strings.Join(result.Done, "\n- ")
	}
	return detail
}
