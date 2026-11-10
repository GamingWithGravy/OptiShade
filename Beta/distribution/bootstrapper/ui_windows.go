//go:build windows

// Copyright (c) 2026 GamingWithGravy. OptiShade proprietary bootstrapper source.
package main

import (
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

// The installer window runs in the same PowerShell host and theme as the
// launcher's own windows. build.ps1 copies FusionSetup.exe and the icon in
// from Beta/installer before building, so both stay in step with the launcher.
//
//go:embed ui/FusionSetup.exe ui/installer-ui.ps1 ui/OptiShade-icon.png ui/user-agreement.txt ui/upgrade.ps1
var uiFiles embed.FS

type installChoices struct {
	Install   bool `json:"Install"`
	Accepted  bool `json:"AcceptedAgreement"`
	Desktop   bool `json:"Desktop"`
	StartMenu bool `json:"StartMenu"`
	Startup   bool `json:"Startup"`
	Open      bool `json:"Open"`
	CleanUp   bool `json:"CleanUp"`
}

type installerUIState struct {
	Status   string   `json:"Status"`
	Detail   string   `json:"Detail"`
	Current  int64    `json:"Current"`
	Total    int64    `json:"Total"`
	Warnings []string `json:"Warnings"`
}

type installerUI struct {
	mu       sync.Mutex
	dir      string
	state    string
	choice   string
	cmd      *exec.Cmd
	exited   chan struct{}
	warnings []string
}

var errInstallerUIUnavailable = errors.New("the installer window could not start")

// startInstallerUI writes the window files to a private temporary folder and
// starts it. Any failure returns errInstallerUIUnavailable so the caller can
// fall back to plain prompts rather than leave the user without a way to install.
func startInstallerUI(installDir string, existing existingInstall) (*installerUI, error) {
	dir, err := os.MkdirTemp("", "OptiShade-installer-")
	if err != nil {
		return nil, errInstallerUIUnavailable
	}
	u := &installerUI{dir: dir, state: filepath.Join(dir, "state.json"), choice: filepath.Join(dir, "choice.json"), exited: make(chan struct{})}
	for _, name := range []string{"FusionSetup.exe", "installer-ui.ps1", "OptiShade-icon.png", "user-agreement.txt"} {
		data, readErr := uiFiles.ReadFile("ui/" + name)
		if readErr != nil || os.WriteFile(filepath.Join(dir, name), data, 0600) != nil {
			os.RemoveAll(dir)
			return nil, errInstallerUIUnavailable
		}
	}
	config := map[string]any{"StatePath": u.state, "ChoicePath": u.choice, "ParentPid": os.Getpid(), "IconPath": filepath.Join(dir, "OptiShade-icon.png"), "AgreementPath": filepath.Join(dir, "user-agreement.txt"), "InstallDir": installDir, "ExistingFound": existing.Found, "ExistingSummary": existingSummary(existing)}
	data, _ := json.Marshal(config)
	configPath := filepath.Join(dir, "config.json")
	if err = os.WriteFile(configPath, data, 0600); err != nil {
		os.RemoveAll(dir)
		return nil, errInstallerUIUnavailable
	}
	u.cmd = exec.Command(filepath.Join(dir, "FusionSetup.exe"), "--installer-ui", configPath)
	u.cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: 0x08000000}
	if err = u.cmd.Start(); err != nil {
		os.RemoveAll(dir)
		return nil, errInstallerUIUnavailable
	}
	go func() { _ = u.cmd.Wait(); close(u.exited) }()
	return u, nil
}

// readChoice returns the last choice the window wrote, if any.
func (u *installerUI) readChoice() (installChoices, bool) {
	var c installChoices
	data, err := os.ReadFile(u.choice)
	if err != nil || json.Unmarshal(data, &c) != nil {
		return c, false
	}
	return c, true
}

// WaitChoice blocks until the user presses Install or Cancel. A window that
// closes or fails without writing a choice is reported as unavailable before
// anything was installed, so the caller can fall back to plain prompts.
func (u *installerUI) WaitChoice() (installChoices, error) {
	for {
		if c, ok := u.readChoice(); ok {
			return c, nil
		}
		select {
		case <-u.exited:
			if c, ok := u.readChoice(); ok {
				return c, nil
			}
			return installChoices{}, errInstallerUIUnavailable
		case <-time.After(150 * time.Millisecond):
		}
	}
}

func (u *installerUI) write(state installerUIState) {
	u.mu.Lock()
	defer u.mu.Unlock()
	state.Warnings = append([]string(nil), u.warnings...)
	data, err := json.Marshal(state)
	if err == nil {
		_ = atomicWrite(u.state, data)
	}
}

func (u *installerUI) Update(detail string, current, total int64) {
	u.write(installerUIState{Status: "Running", Detail: detail, Current: current, Total: total})
}

func (u *installerUI) Warn(text string) {
	u.mu.Lock()
	u.warnings = append(u.warnings, text)
	u.mu.Unlock()
}

// Finish shows the result and waits for the user to close the window or press
// Open OptiShade. It reports whether the app should be opened.
func (u *installerUI) Finish(err error, detail string) bool {
	if err != nil {
		u.write(installerUIState{Status: "Failed", Detail: err.Error()})
	} else {
		if detail == "" {
			detail = "The OptiShade launcher is installed and verified."
		}
		u.write(installerUIState{Status: "Done", Detail: detail})
	}
	<-u.exited
	c, _ := u.readChoice()
	return err == nil && c.Open
}

func (u *installerUI) Close() {
	select {
	case <-u.exited:
	default:
		if u.cmd != nil && u.cmd.Process != nil {
			_ = u.cmd.Process.Kill()
			<-u.exited
		}
	}
	os.RemoveAll(u.dir)
}

// registerStartup adds the per-user startup entry the launcher's own
// "Launch with Windows" setting reads and removes, so both stay in step.
func registerStartup(app string) error {
	value := `"` + app + `" --tray`
	cmd := exec.Command("reg.exe", "add", `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, "/v", "OptiShadeManager", "/t", "REG_SZ", "/d", value, "/f")
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: 0x08000000}
	if output, err := cmd.CombinedOutput(); err != nil {
		return errors.New(err.Error() + " " + string(output))
	}
	return nil
}

// The agreement version changes whenever user-agreement.txt changes meaning.
const userAgreementVersion = 1

func userAgreementText() string {
	data, err := uiFiles.ReadFile("ui/user-agreement.txt")
	if err != nil {
		return ""
	}
	return string(data)
}

// recordAgreementAcceptance keeps a local record of what was accepted and
// when: the agreement version and the SHA-256 of its exact text.
func recordAgreementAcceptance(source string) error {
	text := userAgreementText()
	if text == "" {
		return errors.New("the user agreement is missing from this installer")
	}
	local := os.Getenv("LOCALAPPDATA")
	if !filepath.IsAbs(local) {
		return errors.New("Windows did not provide a valid per-user Local AppData directory")
	}
	sum := sha256.Sum256([]byte(text))
	record := map[string]any{"Schema": 1, "Accepted": true, "AgreementVersion": userAgreementVersion, "AgreementSHA256": hex.EncodeToString(sum[:]), "AcceptedUtc": time.Now().UTC().Format(time.RFC3339), "Source": source}
	data, err := json.MarshalIndent(record, "", "  ")
	if err != nil {
		return err
	}
	dir := filepath.Join(local, "OptiShade")
	if err = os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	return atomicWrite(filepath.Join(dir, "user-agreement-acceptance.json"), data)
}
