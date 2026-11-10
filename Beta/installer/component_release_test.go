package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

func signedReleaseFixture(t *testing.T) ([]byte, string) {
	t.Helper()
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	r := signedComponentRelease{Schema: 1, ComponentID: "OptiShade.Core", Version: "1.0.77", Channel: "stable", PublishedUTC: "2026-11-08T00:00:00Z", SourceCommit: strings.Repeat("a", 40), Contracts: map[string]string{"core-api": "1"}, Dependencies: []struct {
		ComponentID    string `json:"componentId"`
		MinimumVersion string `json:"minimumVersion"`
	}{}, Files: []struct {
		PackagePath        string `json:"packagePath"`
		InstallPath        string `json:"installPath"`
		Bytes              int64  `json:"bytes"`
		SHA256             string `json:"sha256"`
		PreconditionSHA256 string `json:"preconditionSha256"`
	}{{PackagePath: "Payload/ReShade64.dll", InstallPath: "ReShade64.dll", Bytes: 12, SHA256: strings.Repeat("b", 64)}}}
	r.LauncherRange.MinInclusive = "1.0.0"
	r.LauncherRange.MaxExclusive = "2.0.0"
	r.Package.Branch = "core-stable"
	r.Package.Path = "packages/core.tar.gz"
	r.Package.LFSOID = strings.Repeat("c", 64)
	r.Package.SHA256 = strings.Repeat("c", 64)
	r.Package.Bytes = 100
	canonical, err := marshalComponentReleasePayload(&r)
	if err != nil {
		t.Fatal(err)
	}
	r.Signature.Algorithm = "Ed25519"
	r.Signature.KeyID = "test-key"
	r.Signature.Value = base64.StdEncoding.EncodeToString(ed25519.Sign(private, canonical))
	data, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	return data, base64.StdEncoding.EncodeToString(public)
}

func TestVerifySignedComponentRelease(t *testing.T) {
	data, public := signedReleaseFixture(t)
	if _, err := verifySignedComponentReleaseWithKey(data, public, "test-key"); err != nil {
		t.Fatalf("valid signed release rejected: %v", err)
	}
	var release signedComponentRelease
	if err := json.Unmarshal(data, &release); err != nil {
		t.Fatal(err)
	}
	release.Files[0].InstallPath = "../outside.dll"
	unsafe, err := json.Marshal(release)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := verifySignedComponentReleaseWithKey(unsafe, public, "test-key"); err == nil || !strings.Contains(err.Error(), "unsafe") {
		t.Fatalf("unsafe install path accepted, err=%v", err)
	}
}

func TestValidateSignedComponentReleaseAcceptsSplitProviderChannels(t *testing.T) {
	for _, test := range []struct{ id, branch, file string }{
		{"OptiShade.Providers.AMD", "providers-amd-stable", "amd_fidelityfx_upscaler_dx12.dll"},
		{"OptiShade.Providers.Intel", "providers-intel-stable", "libxess.dll"},
	} {
		t.Run(test.id, func(t *testing.T) {
			release := &signedComponentRelease{
				Schema: 1, ComponentID: test.id, Version: "1.0.77",
				Channel: "stable", PublishedUTC: "2026-11-08T00:00:00Z",
				SourceCommit: strings.Repeat("a", 40), Contracts: map[string]string{},
			}
			release.LauncherRange.MinInclusive = "1.0.0"
			release.LauncherRange.MaxExclusive = "2.0.0"
			release.Package.Branch = test.branch
			release.Package.Path = "packages/providers.tar.gz"
			release.Package.Bytes = 100
			release.Package.SHA256 = strings.Repeat("b", 64)
			release.Files = []struct {
				PackagePath        string `json:"packagePath"`
				InstallPath        string `json:"installPath"`
				Bytes              int64  `json:"bytes"`
				SHA256             string `json:"sha256"`
				PreconditionSHA256 string `json:"preconditionSha256"`
			}{{PackagePath: "OptiShadeData/Engine/" + test.file, InstallPath: "OptiShadeData/Engine/" + test.file, Bytes: 10, SHA256: strings.Repeat("c", 64)}}
			if err := validateSignedComponentRelease(release); err != nil {
				t.Fatalf("valid split provider channel rejected: %v", err)
			}
			release.Package.Branch = "effects-stable"
			if err := validateSignedComponentRelease(release); err == nil {
				t.Fatal("provider release with a foreign branch was accepted")
			}
		})
	}
}

func TestComponentTargetsExpandLogicalProviderSelection(t *testing.T) {
	targets, err := componentTargetsForSelection([]string{"OptiShade.Providers"})
	if err != nil {
		t.Fatal(err)
	}
	got := make(map[string]bool, len(targets))
	for _, target := range targets {
		got[target.id] = true
	}
	for _, id := range []string{"OptiShade.Core", "OptiShade.Providers.AMD", "OptiShade.Providers.Intel"} {
		if !got[id] {
			t.Errorf("logical Providers selection omitted %s", id)
		}
	}
	if len(targets) != 3 {
		t.Fatalf("logical Providers selection staged %d packages, want Core plus 2 provider archives", len(targets))
	}
}

func TestVerifySignedComponentReleaseRejectsTampering(t *testing.T) {
	data, public := signedReleaseFixture(t)
	var release signedComponentRelease
	if err := json.Unmarshal(data, &release); err != nil {
		t.Fatal(err)
	}
	release.Version = "1.0.78"
	tampered, err := json.Marshal(release)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := verifySignedComponentReleaseWithKey(tampered, public, "test-key"); err == nil || !strings.Contains(err.Error(), "signature verification failed") {
		t.Fatalf("tampered release accepted, err=%v", err)
	}
}

func TestValidateComponentLauncherRange(t *testing.T) {
	release := &signedComponentRelease{ComponentID: "OptiShade.Core", Version: "1.0.77"}
	release.LauncherRange.MinInclusive = "1.0.0"
	release.LauncherRange.MaxExclusive = "2.0.0"
	for _, test := range []struct {
		version string
		wantErr bool
	}{
		{version: "1.0.0"},
		{version: "1.9.9"},
		{version: "2.0.0", wantErr: true},
		{version: "0.99.9", wantErr: true},
		{version: "P1.0.77", wantErr: true},
	} {
		err := validateComponentLauncherRange(release, test.version)
		if (err != nil) != test.wantErr {
			t.Errorf("launcher %q error=%v, wantErr=%v", test.version, err, test.wantErr)
		}
	}
}

func TestSignedComponentReleaseRejectsWrongBranchAndUnknownFields(t *testing.T) {
	data, public := signedReleaseFixture(t)
	var release signedComponentRelease
	if err := json.Unmarshal(data, &release); err != nil {
		t.Fatal(err)
	}
	release.Package.Branch = "effects-stable"
	wrongBranch, _ := json.Marshal(release)
	if _, err := verifySignedComponentReleaseWithKey(wrongBranch, public, "test-key"); err == nil {
		t.Fatal("component release accepted a package from another component branch")
	}
	unknown := strings.TrimSuffix(string(data), "}") + `,"unexpected":true}`
	if _, err := verifySignedComponentReleaseWithKey([]byte(unknown), public, "test-key"); err == nil {
		t.Fatal("unknown manifest field was accepted")
	}
}
