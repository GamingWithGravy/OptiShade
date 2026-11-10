package main

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func signedTestLauncherChannel(t *testing.T, version string, archive []byte) ([]byte, string) {
	t.Helper()
	pub, private, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	p := launcherChannelPayload{Schema: 1, ComponentID: "OptiShade.Launcher", Version: version, Channel: "stable", SourceCommit: strings.Repeat("a", 40), Contracts: map[string]string{}, Dependencies: []any{}}
	p.Package.Path = "releases/OptiShade.exe"
	p.Package.Bytes = int64(len(archive))
	sum := sha256.Sum256(archive)
	p.Package.SHA256 = hex.EncodeToString(sum[:])
	canonical, err := json.Marshal(p)
	if err != nil {
		t.Fatal(err)
	}
	signed := signedLauncherChannel{Payload: p}
	signed.Signature.Algorithm = "Ed25519"
	signed.Signature.KeyID = "test-key"
	signed.Signature.Value = base64.StdEncoding.EncodeToString(ed25519.Sign(private, canonical))
	data, err := json.Marshal(signed)
	if err != nil {
		t.Fatal(err)
	}
	return data, base64.StdEncoding.EncodeToString(pub)
}

func TestVerifyLauncherChannelAndRejectTampering(t *testing.T) {
	data, pub := signedTestLauncherChannel(t, "1.0.78", []byte("signed launcher bytes"))
	if _, err := verifyLauncherChannelWithKey(data, pub, "test-key"); err != nil {
		t.Fatalf("valid signed channel rejected: %v", err)
	}
	changed := bytesReplaceOnce(data, []byte("1.0.78"), []byte("1.0.79"))
	if _, err := verifyLauncherChannelWithKey(changed, pub, "test-key"); err == nil {
		t.Fatal("tampered channel accepted")
	}
	if _, err := verifyLauncherChannelWithKey(data, pub, "different-key"); err == nil {
		t.Fatal("untrusted signing key accepted")
	}
}

func TestVerifyPreparedLauncherChannelWhenRequested(t *testing.T) {
	channelPath := os.Getenv("OPTISHADE_LAUNCHER_CHANNEL_FIXTURE")
	if channelPath == "" {
		t.Skip("no local signed launcher-channel fixture requested")
	}
	data, err := os.ReadFile(channelPath)
	if err != nil {
		t.Fatal(err)
	}
	channel, err := verifyLauncherChannel(data)
	if err != nil {
		t.Fatalf("prepared launcher channel rejected: %v", err)
	}
	packagePath := filepath.Join(filepath.Dir(channelPath), filepath.FromSlash(channel.Payload.Package.Path))
	info, err := os.Stat(packagePath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Size() != channel.Payload.Package.Bytes {
		t.Fatal("prepared launcher package size differs from its channel")
	}
	digest, err := hashLocalFile(packagePath)
	if err != nil || !strings.EqualFold(digest, channel.Payload.Package.SHA256) {
		t.Fatal("prepared launcher package hash differs from its channel")
	}
}

func TestLauncherChannelRejectsUnsafePathsAndOversizedPackage(t *testing.T) {
	for _, name := range []string{"../OptiShade.exe", "folder/../OptiShade.exe", "/OptiShade.exe", `folder\\OptiShade.exe`} {
		data, pub := signedTestLauncherChannel(t, "1.0.78", []byte("x"))
		var signed signedLauncherChannel
		if err := json.Unmarshal(data, &signed); err != nil {
			t.Fatal(err)
		}
		signed.Payload.Package.Path = name
		data, _ = json.Marshal(signed)
		if _, err := verifyLauncherChannelWithKey(data, pub, "test-key"); err == nil {
			t.Fatalf("unsafe path accepted: %q", name)
		}
	}
	data, pub := signedTestLauncherChannel(t, "1.0.78", []byte("x"))
	var signed signedLauncherChannel
	_ = json.Unmarshal(data, &signed)
	signed.Payload.Package.Bytes = launcherMaxBytes + 1
	data, _ = json.Marshal(signed)
	if _, err := verifyLauncherChannelWithKey(data, pub, "test-key"); err == nil {
		t.Fatal("oversized package accepted")
	}
}

func bytesReplaceOnce(data, old, replacement []byte) []byte {
	return []byte(strings.Replace(string(data), string(old), string(replacement), 1))
}

func TestApplyVerifiedLauncherPackageRotatesAndVerifiesRecovery(t *testing.T) {
	dir := t.TempDir()
	archive := []byte("new signed manager bytes")
	old := []byte("old verified manager bytes")
	app := filepath.Join(dir, "OptiShade.exe")
	uninstaller := filepath.Join(dir, "Uninstall.exe")
	if err := os.WriteFile(app, old, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(uninstaller, old, 0700); err != nil {
		t.Fatal(err)
	}
	oldHash := sha256.Sum256(old)
	oldDigest := hex.EncodeToString(oldHash[:])
	receipt, _ := json.Marshal(modularInstallReceipt{Schema: 1, Version: "1.0.77", SHA256: oldDigest, UninstallerSHA256: oldDigest})
	if err := os.WriteFile(filepath.Join(dir, "install-receipt.json"), receipt, 0600); err != nil {
		t.Fatal(err)
	}
	gameData := filepath.Join(dir, "game-install-receipt.json")
	if err := os.WriteFile(gameData, []byte("game state must not be modified by launcher self-update"), 0600); err != nil {
		t.Fatal(err)
	}
	packagePath := filepath.Join(dir, "incoming.exe")
	if err := os.WriteFile(packagePath, archive, 0700); err != nil {
		t.Fatal(err)
	}
	data, pub := signedTestLauncherChannel(t, "1.0.78", archive)
	channel, err := verifyLauncherChannelWithKey(data, pub, "test-key")
	if err != nil {
		t.Fatal(err)
	}
	if err = applyVerifiedLauncherPackage(packagePath, channel.Payload, dir); err != nil {
		t.Fatalf("update failed: %v", err)
	}
	for _, name := range []string{"OptiShade.exe", "Uninstall.exe"} {
		got, _ := os.ReadFile(filepath.Join(dir, name))
		if string(got) != string(archive) {
			t.Fatalf("%s was not replaced", name)
		}
	}
	backup, err := os.ReadFile(app + ".previous")
	if err != nil || string(backup) != string(old) {
		t.Fatal("verified previous manager was not retained")
	}
	var updated modularInstallReceipt
	bytes, _ := os.ReadFile(filepath.Join(dir, "install-receipt.json"))
	if err = json.Unmarshal(bytes, &updated); err != nil {
		t.Fatal(err)
	}
	if updated.Version != "1.0.78" || updated.PreviousSHA256 != oldDigest || updated.PreviousUninstallerSHA256 != oldDigest {
		t.Fatalf("updated receipt does not record correct recovery data: %+v", updated)
	}
	gameAfter, err := os.ReadFile(gameData)
	if err != nil || string(gameAfter) != "game state must not be modified by launcher self-update" {
		t.Fatal("launcher self-update touched unrelated installation state")
	}
}

func TestApplyVerifiedLauncherPackageRefusesTamperedInstallReceipt(t *testing.T) {
	dir := t.TempDir()
	old := []byte("locally changed manager")
	if err := os.WriteFile(filepath.Join(dir, "OptiShade.exe"), old, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "Uninstall.exe"), old, 0700); err != nil {
		t.Fatal(err)
	}
	receipt, _ := json.Marshal(modularInstallReceipt{Schema: 1, Version: "1.0.77", SHA256: strings.Repeat("0", 64), UninstallerSHA256: strings.Repeat("0", 64)})
	if err := os.WriteFile(filepath.Join(dir, "install-receipt.json"), receipt, 0600); err != nil {
		t.Fatal(err)
	}
	if err := applyVerifiedLauncherPackage(filepath.Join(dir, "unused"), launcherChannelPayload{Schema: 1, ComponentID: "OptiShade.Launcher", Version: "1.0.78", Channel: "stable"}, dir); err == nil {
		t.Fatal("tampered installation was modified")
	}
	if _, err := os.Stat(filepath.Join(dir, "OptiShade.exe.previous")); !os.IsNotExist(err) {
		t.Fatal("refused update created a recovery file")
	}
}
