// Copyright (c) 2026 GamingWithGravy. OptiShade proprietary bootstrapper source.
// The public Releases page is intended to contain this small installer only.
package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
	"unicode/utf16"
	"unsafe"
)

const (
	repoOwner = "GamingWithGravy"
	repoName  = "OptiShade"
	keyID     = "optishade-release-2026"
	// Ordinary GitHub branch files are free to fetch without LFS; keep the
	// launcher package below GitHub's 100 MiB repository-file limit.
	maxLauncherBytes = int64(99 << 20)
)

// Set at build time from a reviewed public key. Private signing keys never
// belong in this source tree or installer executable.
var releasePublicKeyB64 string

// Keep the receipt schema local to the bootstrapper module. The installed
// manager has its own copy because these are independently built programs.
type launcherInstallReceipt struct {
	Schema                    int    `json:"schema"`
	Version                   string `json:"version"`
	SHA256                    string `json:"sha256"`
	UninstallerSHA256         string `json:"uninstallerSha256"`
	PreviousSHA256            string `json:"previousSha256,omitempty"`
	PreviousUninstallerSHA256 string `json:"previousUninstallerSha256,omitempty"`
}

type channelPayload struct {
	Schema       int               `json:"schema"`
	ComponentID  string            `json:"componentId"`
	Version      string            `json:"version"`
	Channel      string            `json:"channel"`
	SourceCommit string            `json:"sourceCommit"`
	Contracts    map[string]string `json:"contracts"`
	Dependencies []any             `json:"dependencies"`
	Package      struct {
		Path   string `json:"path"`
		LFSOID string `json:"lfsOid,omitempty"`
		Bytes  int64  `json:"bytes"`
		SHA256 string `json:"sha256"`
	} `json:"package"`
}
type signedChannel struct {
	Payload   channelPayload `json:"payload"`
	Signature struct {
		Algorithm string `json:"algorithm"`
		KeyID     string `json:"keyId"`
		Value     string `json:"value"`
	} `json:"signature"`
}

func main() {
	if runtime.GOOS != "windows" {
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "--uninstall-app" {
		message("OptiShade uninstaller", "Run Uninstall.exe from the installed OptiShade folder to start the verified uninstall wizard.", 0x10)
		return
	}
	if err := install(); err != nil {
		message("OptiShade installer", err.Error(), 0x10)
	}
}

// installDirectory is the per-user application folder. It is only computed
// here; launcherInstall creates and checks it.
func installDirectory() string {
	return filepath.Join(os.Getenv("LOCALAPPDATA"), "Programs", "OptiShade")
}

func install() error {
	if releasePublicKeyB64 == "" {
		return errors.New("This installer has not been configured with the OptiShade release verification key.")
	}
	// The OptiShade-styled window asks for the choices and shows progress. If it
	// cannot start, or closes before a choice, use the plain prompts below.
	existing := detectExistingInstall()
	if ui, err := startInstallerUI(installDirectory(), existing); err == nil {
		choices, waitErr := ui.WaitChoice()
		if waitErr == nil {
			defer ui.Close()
			// Install is disabled in the window until the agreement is ticked;
			// refuse here too so no path installs without it.
			if !choices.Install || !choices.Accepted {
				return nil
			}
			if err := recordAgreementAcceptance("installer window"); err != nil {
				ui.Warn("Your acceptance of the User Agreement could not be saved: " + err.Error())
			}
			cleanUp := existing.Found && choices.CleanUp
			var app, detail string
			var installErr error
			if cleanUp && existing.Running > 0 {
				ui.Update("Closing the other version of OptiShade…", 0, 0)
				installErr = closeExistingLaunchers()
			}
			if installErr == nil {
				app, _, installErr = launcherInstall(ui.Update, ui.Warn)
			}
			if installErr == nil {
				applyInstallChoices(app, choices, ui.Warn)
				if cleanUp {
					ui.Update("Cleaning up the other version of OptiShade…", 0, 0)
					detail = runCleanUp(app, existing.Copies, ui.Warn)
				}
			}
			if ui.Finish(installErr, detail) && app != "" {
				if startErr := exec.Command(app).Start(); startErr != nil {
					return fmt.Errorf("OptiShade was installed, but it could not be started: %w", startErr)
				}
			}
			return nil
		}
		ui.Close()
	}
	return installWithPrompts()
}

// installWithPrompts is the fallback when the styled window is unavailable.
func installWithPrompts() error {
	agreement := userAgreementText()
	if agreement == "" {
		return errors.New("The OptiShade User Agreement is missing from this installer. Nothing was installed.")
	}
	if answer := message("OptiShade User Agreement", agreement+"\n\nDo you accept the OptiShade User Agreement? Choose No to cancel; nothing will be installed.", 0x124); answer != 6 {
		return nil
	}
	var warnings []string
	if err := recordAgreementAcceptance("installer prompt"); err != nil {
		warnings = append(warnings, "Your acceptance of the User Agreement could not be saved: "+err.Error())
	}
	existing := detectExistingInstall()
	cleanUp := existing.Found && message("OptiShade installer", existingPrompt(existing), 0x24) == 6
	if cleanUp && existing.Running > 0 {
		if err := closeExistingLaunchers(); err != nil {
			return err
		}
	}
	progress := startInstallerProgress()
	app, version, err := launcherInstall(func(text string, current, total int64) {
		if progress != nil {
			progress.Update(text, current, total)
		}
	}, func(text string) { warnings = append(warnings, text) })
	if progress != nil {
		progress.Close()
	}
	if err != nil {
		return err
	}
	choices := installChoices{Install: true}
	choices.Desktop = message("OptiShade installer", "OptiShade "+version+" is installed for this Windows user. Create a desktop shortcut?", 0x24) == 6
	choices.StartMenu = message("OptiShade installer", "Create an OptiShade shortcut in this user's Start Menu?", 0x24) == 6
	choices.Startup = message("OptiShade installer", "Start OptiShade with Windows? It runs in the system tray and shows a Windows notification when an update is available.", 0x124) == 6
	applyInstallChoices(app, choices, func(text string) { warnings = append(warnings, text) })
	if cleanUp {
		if detail := runCleanUp(app, existing.Copies, func(text string) { warnings = append(warnings, text) }); detail != "" {
			warnings = append(warnings, detail)
		}
	}
	if len(warnings) > 0 {
		message("OptiShade installer", "OptiShade is installed.\n\n"+strings.Join(warnings, "\n"), 0x30)
	}
	if err = exec.Command(app).Start(); err != nil {
		return fmt.Errorf("OptiShade was installed, but it could not be started: %w", err)
	}
	return nil
}

// applyInstallChoices runs after the launcher is installed and verified. A
// failure here leaves a working install, so it is reported, not fatal.
func applyInstallChoices(app string, choices installChoices, warn func(string)) {
	if choices.Desktop {
		if err := createDesktopShortcut(app); err != nil {
			warn("The desktop shortcut could not be created: " + err.Error())
		}
	}
	if choices.StartMenu {
		if err := createStartMenuShortcut(app); err != nil {
			warn("The Start menu shortcut could not be created: " + err.Error())
		}
	}
	if choices.Startup {
		if err := registerStartup(app); err != nil {
			warn("Start with Windows could not be turned on; turn it on in OptiShade's settings. " + err.Error())
		}
	}
}

// launcherInstall downloads, verifies and installs the launcher, then registers
// the uninstaller. It returns the installed app path and launcher version.
func launcherInstall(report func(string, int64, int64), warn func(string)) (string, string, error) {
	report("Checking the signed OptiShade launcher channel…", 0, 0)
	manifest, err := fetchChannel("stable")
	if err != nil {
		return "", "", fmt.Errorf("Could not verify the latest OptiShade launcher: %w", err)
	}
	report("Downloading the verified OptiShade launcher…", 0, manifest.Payload.Package.Bytes)
	packagePath, err := fetchGitHubBranchFile("launcher-stable", manifest.Payload.Package.Path, manifest.Payload.Package.Bytes, manifest.Payload.Package.SHA256, func(current, total int64) {
		percent := int64(100)
		if total > 0 {
			percent = current * 100 / total
			if percent > 100 {
				percent = 100
			}
		}
		report(fmt.Sprintf("Downloading the verified OptiShade launcher… %d%%", percent), current, total)
	})
	if err != nil {
		return "", "", fmt.Errorf("Could not download the verified launcher package: %w", err)
	}
	defer os.Remove(packagePath)
	digest, err := hashFile(packagePath)
	if err != nil {
		return "", "", fmt.Errorf("Could not verify the downloaded launcher: %w", err)
	}
	if digest != strings.ToLower(manifest.Payload.Package.SHA256) {
		return "", "", errors.New("The launcher package failed SHA-256 verification. Nothing was installed.")
	}
	report("Installing the verified launcher…", 0, 0)
	local := os.Getenv("LOCALAPPDATA")
	if !filepath.IsAbs(local) {
		return "", "", errors.New("Windows did not provide a valid per-user Local AppData directory.")
	}
	if err = rejectReparsePath(local); err != nil {
		return "", "", fmt.Errorf("unsafe Local AppData path: %w", err)
	}
	programs := filepath.Join(local, "Programs")
	if err = os.MkdirAll(programs, 0700); err != nil {
		return "", "", err
	}
	if err = rejectReparsePath(programs); err != nil {
		return "", "", fmt.Errorf("unsafe per-user programs path: %w", err)
	}
	dir := filepath.Join(programs, "OptiShade")
	if err = os.MkdirAll(dir, 0700); err != nil {
		return "", "", err
	}
	if err = rejectReparsePath(dir); err != nil {
		return "", "", fmt.Errorf("unsafe OptiShade install folder: %w", err)
	}
	installed, err := installVerifiedLauncherFiles(packagePath, manifest.Payload, dir)
	if err != nil {
		return "", "", err
	}
	report("Registering OptiShade with Windows…", 0, 0)
	if err = registerUninstaller(dir); err != nil {
		warn("Windows Apps & Features registration could not be written; use Uninstall.exe in the OptiShade app folder. " + err.Error())
	}
	report("Setting up OptiShade's folders…", 0, 0)
	if err = prepareLauncherSetup(installed.App, manifest.Payload.Version); err != nil {
		return "", "", fmt.Errorf("OptiShade was installed but could not be set up: %w", err)
	}
	return installed.App, manifest.Payload.Version, nil
}

func registerUninstaller(root string) error {
	key := `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\OptiShade`
	uninstall := `"` + filepath.Join(root, "Uninstall.exe") + `"`
	for _, pair := range [][2]string{{"DisplayName", "OptiShade"}, {"Publisher", "GamingWithGravy"}, {"UninstallString", uninstall}, {"DisplayIcon", filepath.Join(root, "OptiShade.exe")}} {
		cmd := exec.Command("reg.exe", "add", key, "/v", pair[0], "/t", "REG_SZ", "/d", pair[1], "/f")
		hideConsole(cmd)
		if output, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("registry value %s: %w %s", pair[0], err, strings.TrimSpace(string(output)))
		}
	}
	cmd := exec.Command("reg.exe", "add", key, "/v", "NoModify", "/t", "REG_DWORD", "/d", "1", "/f")
	hideConsole(cmd)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("registry uninstall entry: %w %s", err, strings.TrimSpace(string(output)))
	}
	return nil
}

func removeRecordedRecoveryBackups(appPath, appHash, uninstallerPath, uninstallerHash string) error {
	type recordedFile struct {
		path string
		hash string
	}
	files := []recordedFile{{appPath, appHash}, {uninstallerPath, uninstallerHash}}
	for _, file := range files {
		_, err := os.Lstat(file.path)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return fmt.Errorf("could not inspect launcher recovery file %s: %w", filepath.Base(file.path), err)
		}
		if file.hash == "" || len(file.hash) != 64 || !isHexString(file.hash) {
			return fmt.Errorf("an unrecorded launcher recovery file exists (%s); it was preserved", filepath.Base(file.path))
		}
		if err = rejectReparsePath(file.path); err != nil {
			return fmt.Errorf("unsafe launcher recovery file %s: %w", filepath.Base(file.path), err)
		}
		actual, hashErr := hashFile(file.path)
		if hashErr != nil || !strings.EqualFold(actual, file.hash) {
			return fmt.Errorf("launcher recovery file %s no longer matches its install receipt; it was preserved", filepath.Base(file.path))
		}
	}
	for _, file := range files {
		if _, err := os.Lstat(file.path); os.IsNotExist(err) {
			continue
		}
		if err := os.Remove(file.path); err != nil {
			return fmt.Errorf("could not rotate the verified launcher recovery file %s: %w", filepath.Base(file.path), err)
		}
	}
	return nil
}

func fetchChannel(channel string) (*signedChannel, error) {
	if channel != "stable" {
		return nil, errors.New("Unsupported release channel")
	}
	if root, configured, err := localSourceRoot(); configured {
		if err != nil {
			return nil, err
		}
		data, err := readLocalSourceFile(root, "launcher-stable", "channel.json", 256*1024)
		if err != nil {
			return nil, fmt.Errorf("local launcher channel: %w", err)
		}
		return verifySignedChannel(data, channel, releasePublicKeyB64)
	}
	client := http.Client{Timeout: 20 * time.Second, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if req.URL.Scheme != "https" || len(via) > 4 || !githubContentHostAllowed(req.URL.Hostname()) {
			return errors.New("Unsafe redirect while checking updates")
		}
		return nil
	}}
	url := fmt.Sprintf("https://raw.githubusercontent.com/%s/%s/launcher-stable/channel.json", repoOwner, repoName)
	req, _ := http.NewRequest(http.MethodGet, url, nil)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "OptiShade-Bootstrapper")
	res, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("channel returned HTTP %d", res.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(res.Body, 256*1024+1))
	if err != nil || len(data) > 256*1024 {
		return nil, errors.New("channel manifest is too large or unreadable")
	}
	return verifySignedChannel(data, channel, releasePublicKeyB64)
}

func verifySignedChannel(data []byte, channel, publicKeyB64 string) (*signedChannel, error) {
	if len(data) == 0 || len(data) > 256*1024 {
		return nil, errors.New("channel manifest is empty or too large")
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	var signed signedChannel
	if err := dec.Decode(&signed); err != nil {
		return nil, fmt.Errorf("invalid channel manifest: %w", err)
	}
	var trailing any
	if err := dec.Decode(&trailing); err != io.EOF {
		return nil, errors.New("channel manifest contains trailing data")
	}
	p := signed.Payload
	_, commitErr := hex.DecodeString(p.SourceCommit)
	_, hashErr := hex.DecodeString(p.Package.SHA256)
	if (channel != "stable" && channel != "beta") || p.Schema != 1 || p.ComponentID != "OptiShade.Launcher" || p.Channel != channel || p.Version == "" || len(p.SourceCommit) < 40 || len(p.SourceCommit) > 64 || commitErr != nil || p.Package.Bytes < 1 || p.Package.Bytes > maxLauncherBytes || len(p.Package.SHA256) != 64 || hashErr != nil || (p.Package.LFSOID != "" && !strings.EqualFold(p.Package.LFSOID, p.Package.SHA256)) {
		return nil, errors.New("launcher channel fields are invalid")
	}
	if strings.Contains(p.Package.Path, "..") || strings.HasPrefix(p.Package.Path, "/") || strings.Contains(p.Package.Path, "\\") || filepath.Base(p.Package.Path) != "OptiShade.exe" {
		return nil, errors.New("launcher package path is unsafe or is not OptiShade.exe")
	}
	if signed.Signature.Algorithm != "Ed25519" || signed.Signature.KeyID != keyID {
		return nil, errors.New("launcher channel signing key is not trusted")
	}
	pub, err := base64.StdEncoding.DecodeString(publicKeyB64)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		return nil, errors.New("installer release key is invalid")
	}
	sig, err := base64.StdEncoding.DecodeString(signed.Signature.Value)
	if err != nil || len(sig) != ed25519.SignatureSize {
		return nil, errors.New("launcher channel signature is malformed")
	}
	canonical, err := json.Marshal(p)
	if err != nil || !ed25519.Verify(ed25519.PublicKey(pub), canonical, sig) {
		return nil, errors.New("launcher channel signature verification failed")
	}
	return &signed, nil
}

func fetchGitHubBranchFile(branch, packagePath string, size int64, expectedSHA256 string, onProgress func(current, total int64)) (string, error) {
	if branch != "launcher-stable" || size < 1 || size > maxLauncherBytes || len(expectedSHA256) != 64 || strings.Contains(packagePath, "..") || strings.HasPrefix(packagePath, "/") || strings.Contains(packagePath, `\`) {
		return "", errors.New("invalid launcher branch-file identity")
	}
	if root, configured, err := localSourceRoot(); configured {
		if err != nil {
			return "", err
		}
		return copyLocalLauncher(root, branch, packagePath, size, onProgress)
	}
	url := fmt.Sprintf("https://raw.githubusercontent.com/%s/%s/%s/%s", repoOwner, repoName, branch, packagePath)
	return downloadVerifiedLauncher(url, size, expectedSHA256, githubContentHostAllowed, onProgress)
}

func githubContentHostAllowed(host string) bool {
	host = strings.ToLower(host)
	return host == "raw.githubusercontent.com" || strings.HasSuffix(host, ".githubusercontent.com")
}

func downloadVerifiedLauncher(url string, size int64, expectedSHA256 string, allowHost func(string) bool, onProgress func(current, total int64)) (string, error) {
	if size < 1 || size > maxLauncherBytes || len(expectedSHA256) != 64 || !isHexString(expectedSHA256) || allowHost == nil {
		return "", errors.New("invalid launcher download identity")
	}
	client := launcherHTTPClient(20*time.Minute, allowHost)
	return downloadVerifiedLauncherWithClient(url, size, expectedSHA256, allowHost, onProgress, client)
}

func launcherHTTPClient(timeout time.Duration, allowHost func(string) bool) *http.Client {
	return &http.Client{Timeout: timeout, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		host := strings.ToLower(req.URL.Hostname())
		if req.URL.Scheme != "https" || len(via) > 4 || !allowHost(host) {
			return errors.New("unsafe redirect while downloading launcher")
		}
		return nil
	}}
}

func downloadVerifiedLauncherWithClient(url string, size int64, expectedSHA256 string, allowHost func(string) bool, onProgress func(current, total int64), client *http.Client) (string, error) {
	if size < 1 || size > maxLauncherBytes || len(expectedSHA256) != 64 || !isHexString(expectedSHA256) || allowHost == nil || client == nil {
		return "", errors.New("invalid launcher download identity")
	}
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil || req.URL.Scheme != "https" || !allowHost(strings.ToLower(req.URL.Hostname())) {
		return "", errors.New("launcher download URL is not HTTPS or uses an untrusted host")
	}
	req.Header.Set("User-Agent", "OptiShade-Bootstrapper")
	file, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer file.Body.Close()
	if file.StatusCode != http.StatusOK {
		return "", fmt.Errorf("GitHub branch-file download returned HTTP %d", file.StatusCode)
	}
	temp, err := os.CreateTemp(os.TempDir(), "OptiShade-launcher-*.download")
	if err != nil {
		return "", err
	}
	tempPath := temp.Name()
	defer func() {
		if temp != nil {
			_ = temp.Close()
		}
	}()
	hasher := sha256.New()
	var count int64
	buffer := make([]byte, 256*1024)
	for {
		read, readErr := file.Body.Read(buffer)
		if read > 0 {
			written, writeErr := temp.Write(buffer[:read])
			if writeErr != nil {
				_ = os.Remove(tempPath)
				return "", writeErr
			}
			if written != read {
				_ = os.Remove(tempPath)
				return "", io.ErrShortWrite
			}
			_, _ = hasher.Write(buffer[:read])
			count += int64(read)
			if onProgress != nil {
				onProgress(count, size)
			}
			if count > size {
				_ = os.Remove(tempPath)
				return "", errors.New("launcher package exceeded the signed manifest size")
			}
		}
		if readErr != nil {
			if readErr != io.EOF {
				_ = os.Remove(tempPath)
				return "", readErr
			}
			break
		}
	}
	if count != size {
		_ = os.Remove(tempPath)
		return "", errors.New("launcher package size did not match its signed manifest")
	}
	if !strings.EqualFold(hex.EncodeToString(hasher.Sum(nil)), expectedSHA256) {
		_ = os.Remove(tempPath)
		return "", errors.New("launcher package SHA-256 did not match its signed manifest")
	}
	if err = temp.Sync(); err != nil {
		_ = os.Remove(tempPath)
		return "", err
	}
	if err = temp.Close(); err != nil {
		_ = os.Remove(tempPath)
		return "", err
	}
	temp = nil
	return tempPath, nil
}

func isHexString(value string) bool {
	_, err := hex.DecodeString(value)
	return err == nil
}

func hashFile(path string) (string, error) {
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

func copyFile(source, destination string) error {
	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0700)
	if err != nil {
		return err
	}
	if _, err = io.Copy(out, in); err == nil {
		err = out.Sync()
	}
	closeErr := out.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		_ = os.Remove(destination)
	}
	return err
}

func rejectReparsePath(path string) error {
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

func atomicWrite(path string, data []byte) error {
	tmp := path + ".new"
	if err := os.WriteFile(tmp, data, 0600); err != nil {
		return err
	}
	from, _ := syscall.UTF16PtrFromString(tmp)
	to, _ := syscall.UTF16PtrFromString(path)
	ok, _, e := syscall.NewLazyDLL("kernel32.dll").NewProc("MoveFileExW").Call(uintptr(unsafe.Pointer(from)), uintptr(unsafe.Pointer(to)), 0x1|0x8)
	if ok == 0 {
		_ = os.Remove(tmp)
		return e
	}
	return nil
}
func createDesktopShortcut(target string) error {
	ps := "$s=(New-Object -ComObject WScript.Shell).CreateShortcut([IO.Path]::Combine([Environment]::GetFolderPath('Desktop'),'OptiShade.lnk'));$s.TargetPath=$env:OPTISHADE_SHORTCUT_TARGET;$s.WorkingDirectory=[IO.Path]::GetDirectoryName($s.TargetPath);$s.Save()"
	return createShortcut(target, ps)
}
func createStartMenuShortcut(target string) error {
	ps := "$d=[IO.Path]::Combine([Environment]::GetFolderPath('StartMenu'),'Programs','OptiShade');[IO.Directory]::CreateDirectory($d)|Out-Null;$s=(New-Object -ComObject WScript.Shell).CreateShortcut([IO.Path]::Combine($d,'OptiShade.lnk'));$s.TargetPath=$env:OPTISHADE_SHORTCUT_TARGET;$s.WorkingDirectory=[IO.Path]::GetDirectoryName($s.TargetPath);$s.Save()"
	return createShortcut(target, ps)
}
func createShortcut(target, ps string) error {
	encoded := base64.StdEncoding.EncodeToString([]byte(utf16LE(ps)))
	cmd := exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded)
	cmd.Env = append(os.Environ(), "OPTISHADE_SHORTCUT_TARGET="+target)
	hideConsole(cmd)
	return cmd.Run()
}

// hideConsole stops console helpers (reg.exe, PowerShell) from flashing a
// window while the installer works.
func hideConsole(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: 0x08000000, HideWindow: true}
}
func utf16LE(s string) []byte {
	runes := utf16.Encode([]rune(s))
	out := make([]byte, len(runes)*2)
	for i, r := range runes {
		out[i*2] = byte(r)
		out[i*2+1] = byte(r >> 8)
	}
	return out
}
func message(title, text string, kind uintptr) int {
	t, _ := syscall.UTF16PtrFromString(title)
	m, _ := syscall.UTF16PtrFromString(text)
	r, _, _ := syscall.NewLazyDLL("user32.dll").NewProc("MessageBoxW").Call(0, uintptr(unsafe.Pointer(m)), uintptr(unsafe.Pointer(t)), kind)
	return int(r)
}
