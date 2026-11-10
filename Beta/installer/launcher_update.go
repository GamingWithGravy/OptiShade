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
	"path"
	"path/filepath"
	"strings"
	"time"
)

const (
	launcherChannelURL   = "https://raw.githubusercontent.com/GamingWithGravy/OptiShade/launcher-stable/channel.json"
	launcherBranchURL    = "https://raw.githubusercontent.com/GamingWithGravy/OptiShade/launcher-stable/"
	launcherReleaseKeyID = "optishade-release-2026"
	launcherMaxBytes     = int64(99 << 20)
)

var errLauncherChannelNotPublished = errors.New("launcher update channel is not published yet")

type launcherChannelPayload struct {
	Schema       int               `json:"schema"`
	ComponentID  string            `json:"componentId"`
	Version      string            `json:"version"`
	Channel      string            `json:"channel"`
	SourceCommit string            `json:"sourceCommit"`
	Contracts    map[string]string `json:"contracts"`
	Dependencies []any             `json:"dependencies"`
	Package      struct {
		Path   string `json:"path"`
		Bytes  int64  `json:"bytes"`
		SHA256 string `json:"sha256"`
	} `json:"package"`
}

type signedLauncherChannel struct {
	Payload   launcherChannelPayload `json:"payload"`
	Signature struct {
		Algorithm string `json:"algorithm"`
		KeyID     string `json:"keyId"`
		Value     string `json:"value"`
	} `json:"signature"`
}

type launcherUpdateCheck struct {
	Schema          int    `json:"schema"`
	OK              bool   `json:"ok"`
	ChannelPublished bool   `json:"channelPublished"`
	Version         string `json:"version,omitempty"`
	Bytes           int64  `json:"bytes,omitempty"`
	SHA256          string `json:"sha256,omitempty"`
	Path            string `json:"path,omitempty"`
	Message         string `json:"message"`
}

type launcherUpdateConfig struct {
	Schema          int    `json:"schema"`
	InstallDir      string `json:"installDir"`
	ExpectedVersion string `json:"expectedVersion"`
	LauncherPID     int    `json:"launcherPid"`
	HostPID         int    `json:"hostPid"`
}

type modularInstallReceipt struct {
	Schema                    int    `json:"schema"`
	Version                   string `json:"version"`
	SHA256                    string `json:"sha256"`
	UninstallerSHA256         string `json:"uninstallerSha256"`
	PreviousSHA256            string `json:"previousSha256,omitempty"`
	PreviousUninstallerSHA256 string `json:"previousUninstallerSha256,omitempty"`
}

func verifyLauncherChannel(data []byte) (*signedLauncherChannel, error) {
	return verifyLauncherChannelWithKey(data, optiShadeReleasePublicKey, launcherReleaseKeyID)
}

func verifyLauncherChannelWithKey(data []byte, publicKeyB64, expectedKeyID string) (*signedLauncherChannel, error) {
	if len(data) == 0 || len(data) > 256<<10 {
		return nil, errors.New("launcher channel is empty or too large")
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	var signed signedLauncherChannel
	if err := dec.Decode(&signed); err != nil {
		return nil, fmt.Errorf("invalid launcher channel: %w", err)
	}
	var trailing any
	if err := dec.Decode(&trailing); err != io.EOF {
		return nil, errors.New("launcher channel contains trailing data")
	}
	p := signed.Payload
	if p.Schema != 1 || p.ComponentID != "OptiShade.Launcher" || p.Channel != "stable" || !releaseVersionPattern.MatchString(p.Version) || !regexpHexCommit(p.SourceCommit) || p.Package.Bytes < 1 || p.Package.Bytes > launcherMaxBytes || !releaseDigestPattern.MatchString(p.Package.SHA256) || !safeLauncherBranchPath(p.Package.Path) || path.Base(p.Package.Path) != "OptiShade.exe" {
		return nil, errors.New("launcher channel fields are invalid")
	}
	if signed.Signature.Algorithm != "Ed25519" || signed.Signature.KeyID != expectedKeyID {
		return nil, errors.New("launcher channel signing key is not trusted")
	}
	pub, err := base64.StdEncoding.DecodeString(publicKeyB64)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		return nil, errors.New("trusted launcher public key is invalid")
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

func regexpHexCommit(value string) bool {
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) >= 20 && len(decoded) <= 32
}

func safeLauncherBranchPath(value string) bool {
	return value != "" && !strings.Contains(value, `\`) && !strings.Contains(value, ":") && !strings.HasPrefix(value, "/") && path.Clean(value) == value && !strings.HasPrefix(value, "../")
}

func fetchLauncherChannel() (*signedLauncherChannel, error) {
	// A local release folder (the same one component channels use) lets a
	// release be tested before it is published. The signature still applies.
	if root, configured, err := localComponentSourceRoot(); configured {
		if err != nil {
			return nil, err
		}
		data, readErr := readLocalComponentSourceFile(root, "launcher-stable", "channel.json", 256<<10)
		if readErr != nil {
			return nil, errLauncherChannelNotPublished
		}
		return verifyLauncherChannel(data)
	}
	client := &http.Client{Timeout: 20 * time.Second, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if req.URL.Scheme != "https" || len(via) > 4 || !isGitHubRawHost(req.URL.Hostname()) {
			return errors.New("unsafe redirect while checking launcher updates")
		}
		return nil
	}}
	req, err := http.NewRequest(http.MethodGet, launcherChannelURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "OptiShade-Modular-Manager")
	res, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode == http.StatusNotFound {
		return nil, errLauncherChannelNotPublished
	}
	if res.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("launcher channel returned HTTP %d", res.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(res.Body, 256<<10+1))
	if err != nil || len(data) > 256<<10 {
		return nil, errors.New("launcher channel is too large or unreadable")
	}
	return verifyLauncherChannel(data)
}

func isGitHubRawHost(host string) bool {
	return strings.EqualFold(host, "raw.githubusercontent.com") || strings.HasSuffix(strings.ToLower(host), ".githubusercontent.com")
}

func downloadLauncherPackage(channel *signedLauncherChannel, dir string) (string, error) {
	if channel == nil || !safeLauncherBranchPath(channel.Payload.Package.Path) {
		return "", errors.New("invalid verified launcher package")
	}
	if root, configured, err := localComponentSourceRoot(); configured {
		if err != nil {
			return "", err
		}
		source, openErr := openLocalComponentSourceFile(root, "launcher-stable", channel.Payload.Package.Path, channel.Payload.Package.Bytes)
		if openErr != nil {
			return "", openErr
		}
		defer source.Close()
		return stageVerifiedLauncherPackage(channel, dir, source)
	}
	url := launcherBranchURL + channel.Payload.Package.Path
	client := &http.Client{Timeout: 20 * time.Minute, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if req.URL.Scheme != "https" || len(via) > 4 || !isGitHubRawHost(req.URL.Hostname()) {
			return errors.New("unsafe redirect while downloading launcher")
		}
		return nil
	}}
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", "OptiShade-Modular-Manager")
	res, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return "", fmt.Errorf("launcher package returned HTTP %d", res.StatusCode)
	}
	return stageVerifiedLauncherPackage(channel, dir, res.Body)
}

// stageVerifiedLauncherPackage writes the package beside the update config and
// keeps it only if its size and SHA-256 match the signed channel.
func stageVerifiedLauncherPackage(channel *signedLauncherChannel, dir string, body io.Reader) (string, error) {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return "", err
	}
	f, err := os.CreateTemp(dir, "OptiShade-verified-*.new")
	if err != nil {
		return "", err
	}
	name := f.Name()
	h := sha256.New()
	n, copyErr := io.Copy(io.MultiWriter(f, h), io.LimitReader(body, channel.Payload.Package.Bytes+1))
	if copyErr == nil {
		copyErr = f.Sync()
	}
	closeErr := f.Close()
	if copyErr == nil {
		copyErr = closeErr
	}
	if copyErr != nil {
		_ = os.Remove(name)
		return "", copyErr
	}
	if n != channel.Payload.Package.Bytes || !strings.EqualFold(hex.EncodeToString(h.Sum(nil)), channel.Payload.Package.SHA256) {
		_ = os.Remove(name)
		return "", errors.New("downloaded launcher size or SHA-256 did not match the signed channel")
	}
	return name, nil
}

func writeLauncherUpdateResult(path string, result launcherUpdateCheck) error {
	if !filepath.IsAbs(path) {
		return errors.New("launcher update result path must be absolute")
	}
	data, err := json.Marshal(result)
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0600)
}

func checkLauncherUpdate(currentVersion string) (launcherUpdateCheck, error) {
	result := launcherUpdateCheck{Schema: 1, ChannelPublished: true}
	if !releaseVersionPattern.MatchString(currentVersion) {
		return result, errors.New("current launcher version is invalid")
	}
	channel, err := fetchLauncherChannel()
	if err != nil {
		if errors.Is(err, errLauncherChannelNotPublished) {
			return launcherUpdateCheck{Schema: 1, OK: true, ChannelPublished: false, Version: currentVersion, Message: "Launcher updates are not published yet. Component installation and updates remain available."}, nil
		}
		return result, err
	}
	p := channel.Payload
	result.Version, result.Bytes, result.SHA256, result.Path = p.Version, p.Package.Bytes, strings.ToLower(p.Package.SHA256), p.Package.Path
	if compareComponentVersions(p.Version, currentVersion) <= 0 {
		result.OK = true
		result.Message = "OptiShade is up to date."
		return result, nil
	}
	result.OK = true
	result.Message = "A signed OptiShade launcher update is available."
	return result, nil
}

func runModularLauncherUpdate(configPath string) error {
	if !filepath.IsAbs(configPath) {
		return errors.New("launcher update config path must be absolute")
	}
	data, err := os.ReadFile(configPath)
	if err != nil {
		return err
	}
	if len(data) > 16<<10 {
		return errors.New("launcher update config is too large")
	}
	var config launcherUpdateConfig
	if err = json.Unmarshal(data, &config); err != nil {
		return err
	}
	if config.Schema != 1 || !releaseVersionPattern.MatchString(config.ExpectedVersion) || config.LauncherPID < 1 || config.HostPID < 1 {
		return errors.New("launcher update config is invalid")
	}
	local := os.Getenv("LOCALAPPDATA")
	if !filepath.IsAbs(local) {
		return errors.New("Windows Local AppData path is invalid")
	}
	expectedDir := filepath.Join(local, "Programs", "OptiShade")
	if !strings.EqualFold(filepath.Clean(config.InstallDir), filepath.Clean(expectedDir)) {
		return errors.New("launcher update target is not the per-user OptiShade installation folder")
	}
	updatesRoot := filepath.Join(local, "OptiShade", "Updates")
	stageLeaf := filepath.Base(filepath.Dir(configPath))
	stageID, stageErr := hex.DecodeString(strings.TrimPrefix(stageLeaf, "launcher-"))
	if !strings.EqualFold(filepath.Clean(filepath.Dir(filepath.Dir(configPath))), filepath.Clean(updatesRoot)) || filepath.Base(configPath) != "update.json" || !strings.HasPrefix(stageLeaf, "launcher-") || stageErr != nil || len(stageID) != 16 {
		return errors.New("launcher update helper is not in its expected per-user staging folder")
	}
	if err = rejectLauncherReparsePath(filepath.Dir(configPath)); err != nil {
		return fmt.Errorf("unsafe launcher update staging folder: %w", err)
	}
	channel, err := fetchLauncherChannel()
	if err != nil {
		return err
	}
	if channel.Payload.Version != config.ExpectedVersion {
		return errors.New("the signed launcher version changed after the update check; check again")
	}
	stageDir := filepath.Dir(configPath)
	packagePath, err := downloadLauncherPackage(channel, stageDir)
	if err != nil {
		return err
	}
	defer os.Remove(packagePath)
	if err = waitForLauncherProcesses(config.LauncherPID, config.HostPID); err != nil {
		return err
	}
	if err = applyVerifiedLauncherPackage(packagePath, channel.Payload, config.InstallDir); err != nil {
		return err
	}
	appPath := filepath.Join(config.InstallDir, "OptiShade.exe")
	cmd := execCommand(appPath)
	if err = cmd.Start(); err != nil {
		return fmt.Errorf("launcher updated successfully, but could not be restarted: %w", err)
	}
	startLauncherUpdateCleanup(stageDir)
	return nil
}

func applyVerifiedLauncherPackage(packagePath string, payload launcherChannelPayload, dir string) error {
	if !filepath.IsAbs(dir) || !filepath.IsAbs(packagePath) {
		return errors.New("launcher update paths must be absolute")
	}
	app := filepath.Join(dir, "OptiShade.exe")
	uninstaller := filepath.Join(dir, "Uninstall.exe")
	receiptPath := filepath.Join(dir, "install-receipt.json")
	for _, target := range []string{dir, app, uninstaller, receiptPath} {
		if err := rejectLauncherReparsePath(target); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("unsafe launcher update path: %w", err)
		}
	}
	if !releaseVersionPattern.MatchString(payload.Version) || payload.ComponentID != "OptiShade.Launcher" || payload.Channel != "stable" {
		return errors.New("verified launcher release identity is invalid")
	}
	var prior modularInstallReceipt
	receiptData, err := os.ReadFile(receiptPath)
	if err != nil || len(receiptData) > 64<<10 || json.Unmarshal(receiptData, &prior) != nil || prior.Schema != 1 {
		return errors.New("the installed manager receipt is missing or invalid; no files were changed")
	}
	currentAppHash, err := hashLocalFile(app)
	if err != nil || !strings.EqualFold(currentAppHash, prior.SHA256) {
		return errors.New("the installed manager no longer matches its receipt; no files were changed")
	}
	currentUninstallerHash, err := hashLocalFile(uninstaller)
	if err != nil || !strings.EqualFold(currentUninstallerHash, prior.UninstallerSHA256) {
		return errors.New("the installed uninstaller no longer matches its receipt; no files were changed")
	}
	packageHash, err := hashLocalFile(packagePath)
	if err != nil || !strings.EqualFold(packageHash, payload.Package.SHA256) {
		return errors.New("the downloaded launcher package failed SHA-256 verification")
	}
	info, err := os.Stat(packagePath)
	if err != nil || info.Size() != payload.Package.Bytes {
		return errors.New("the downloaded launcher package size is invalid")
	}
	appNew, uninstallerNew := app+".new", uninstaller+".new"
	appBackup, uninstallerBackup := app+".previous", uninstaller+".previous"
	if err = removeRecordedLauncherBackup(appBackup, prior.PreviousSHA256); err != nil {
		return err
	}
	if err = removeRecordedLauncherBackup(uninstallerBackup, prior.PreviousUninstallerSHA256); err != nil {
		return err
	}
	_ = os.Remove(appNew)
	_ = os.Remove(uninstallerNew)
	if err = copyLocalFile(packagePath, appNew); err != nil {
		return err
	}
	rollback := func(cause error, movedApp, movedUninstaller, installedApp, installedUninstaller bool) error {
		if installedUninstaller {
			_ = os.Remove(uninstaller)
		}
		if installedApp {
			_ = os.Remove(app)
		}
		_ = os.Remove(appNew)
		_ = os.Remove(uninstallerNew)
		if movedUninstaller {
			_ = os.Rename(uninstallerBackup, uninstaller)
		}
		if movedApp {
			_ = os.Rename(appBackup, app)
		}
		return cause
	}
	newHash, err := hashLocalFile(appNew)
	if err != nil || !strings.EqualFold(newHash, payload.Package.SHA256) {
		_ = os.Remove(appNew)
		return errors.New("staged launcher failed SHA-256 verification")
	}
	appMoved, uninstallMoved, appInstalled, uninstallInstalled := false, false, false, false
	if err = os.Rename(app, appBackup); err != nil {
		_ = os.Remove(appNew)
		return fmt.Errorf("could not preserve the previous launcher: %w", err)
	}
	appMoved = true
	if err = os.Rename(uninstaller, uninstallerBackup); err != nil {
		return rollback(err, appMoved, false, false, false)
	}
	uninstallMoved = true
	if err = os.Rename(appNew, app); err != nil {
		return rollback(err, appMoved, uninstallMoved, false, false)
	}
	appInstalled = true
	if err = copyLocalFile(app, uninstallerNew); err != nil {
		return rollback(err, appMoved, uninstallMoved, appInstalled, false)
	}
	if err = os.Rename(uninstallerNew, uninstaller); err != nil {
		return rollback(err, appMoved, uninstallMoved, appInstalled, false)
	}
	uninstallInstalled = true
	next := modularInstallReceipt{Schema: 1, Version: payload.Version, SHA256: newHash, UninstallerSHA256: newHash, PreviousSHA256: currentAppHash, PreviousUninstallerSHA256: currentUninstallerHash}
	updatedReceipt, err := json.Marshal(next)
	if err != nil {
		return rollback(err, appMoved, uninstallMoved, appInstalled, uninstallInstalled)
	}
	if err = writeLauncherReceipt(receiptPath, updatedReceipt); err != nil {
		return rollback(err, appMoved, uninstallMoved, appInstalled, uninstallInstalled)
	}
	return nil
}

func removeRecordedLauncherBackup(name, expectedHash string) error {
	if _, err := os.Lstat(name); os.IsNotExist(err) {
		return nil
	} else if err != nil {
		return err
	}
	if expectedHash == "" {
		return fmt.Errorf("unrecorded launcher recovery file %s was preserved", filepath.Base(name))
	}
	actual, err := hashLocalFile(name)
	if err != nil || !strings.EqualFold(actual, expectedHash) {
		return fmt.Errorf("launcher recovery file %s does not match its receipt and was preserved", filepath.Base(name))
	}
	return os.Remove(name)
}

func hashLocalFile(name string) (string, error) {
	f, err := os.Open(name)
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

func copyLocalFile(source, destination string) error {
	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0700)
	if err != nil {
		return err
	}
	_, err = io.Copy(out, in)
	if err == nil {
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

// reopenInstalledLauncher starts the per-user installed launcher after a failed
// update. Only the fixed installation path is used.
func reopenInstalledLauncher() error {
	local := os.Getenv("LOCALAPPDATA")
	if !filepath.IsAbs(local) {
		return errors.New("Windows Local AppData path is invalid")
	}
	app := filepath.Join(local, "Programs", "OptiShade", "OptiShade.exe")
	if info, err := os.Lstat(app); err != nil || !info.Mode().IsRegular() {
		return errors.New("the installed launcher is missing")
	}
	return execCommand(app).Start()
}
