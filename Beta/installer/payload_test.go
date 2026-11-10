package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"testing"
)

// Check the embedded bytes, not just the staging directory: go:embed normally
// excludes dot files such as Cache/.keep, even when files.json includes them.
func TestEmbeddedPayload(t *testing.T) {
	data, err := bundle.ReadFile("PayloadFusion/files.json")
	if modularPayloadBuild {
		if err == nil {
			t.Fatal("modular manager unexpectedly embeds the game payload")
		}
		return
	}
	if err != nil {
		t.Fatal(err)
	}
	var entries []struct{ Path, Hash string }
	if err := json.Unmarshal([]byte(strings.TrimPrefix(string(data), "\ufeff")), &entries); err != nil {
		t.Fatal(err)
	}
	if len(entries) == 0 {
		t.Fatal("empty payload catalogue")
	}
	for _, entry := range entries {
		path := "PayloadFusion/" + strings.ReplaceAll(entry.Path, "\\", "/")
		bytes, err := bundle.ReadFile(path)
		if err != nil {
			t.Errorf("missing embedded file %s: %v", path, err)
			continue
		}
		if !strings.EqualFold(fmt.Sprintf("%x", sha256.Sum256(bytes)), entry.Hash) {
			t.Errorf("embedded hash mismatch: %s", path)
		}
	}
	t.Logf("Verified all %d embedded payload files", len(entries))
}

func TestDlssRuntimeProfilesAreEmbeddedAndLimitedToSrRr(t *testing.T) {
	data, err := bundle.ReadFile("nvidia-runtime-profiles.json")
	if err != nil {
		t.Fatal(err)
	}
	var catalog struct {
		SchemaVersion int      `json:"schemaVersion"`
		Default       string   `json:"default"`
		Scope         []string `json:"scope"`
		Profiles      []struct {
			ID    string `json:"id"`
			Files []struct {
				Name      string `json:"Name"`
				Version   string `json:"Version"`
				SourceTag string `json:"SourceTag"`
				SHA256    string `json:"SHA256"`
			} `json:"files"`
		} `json:"profiles"`
	}
	if err := json.Unmarshal(data, &catalog); err != nil {
		t.Fatal(err)
	}
	wantScope := []string{"nvngx_dlss.dll", "nvngx_dlssd.dll"}
	if catalog.SchemaVersion != 1 || catalog.Default != "nvidia-310.9.16" || strings.Join(catalog.Scope, ",") != strings.Join(wantScope, ",") || len(catalog.Profiles) != 1 {
		t.Fatalf("unexpected DLSS runtime catalog structure: %+v", catalog)
	}
	baseData, err := bundle.ReadFile("nvidia-files.json")
	if err != nil {
		t.Fatal(err)
	}
	var baseFiles []struct {
		Name    string `json:"Name"`
		Version string `json:"Version"`
	}
	if err := json.Unmarshal([]byte(strings.TrimPrefix(string(baseData), "\ufeff")), &baseFiles); err != nil {
		t.Fatal(err)
	}
	if len(baseFiles) != 1 || baseFiles[0].Name != "nvngx_dlssg.dll" || baseFiles[0].Version != "310.9.16.0" {
		t.Fatalf("base NVIDIA catalogue must contain only the Streamline-pinned DLSS-G runtime: %+v", baseFiles)
	}
	seen := map[string]bool{}
	for _, profile := range catalog.Profiles {
		if seen[profile.ID] || len(profile.Files) != len(wantScope) {
			t.Fatalf("duplicate or incomplete runtime profile %q", profile.ID)
		}
		seen[profile.ID] = true
		for i, file := range profile.Files {
			if file.Name != wantScope[i] || !regexp.MustCompile(`^\d+\.\d+\.\d+\.\d+$`).MatchString(file.Version) || !regexp.MustCompile(`^v\d+\.\d+\.\d+$`).MatchString(file.SourceTag) || !regexp.MustCompile(`^[A-Fa-f0-9]{64}$`).MatchString(file.SHA256) {
				t.Fatalf("invalid profile entry in %q: %+v", profile.ID, file)
			}
			for _, base := range baseFiles {
				if file.Name == base.Name {
					t.Fatalf("NVIDIA runtime %s is duplicated between base and profile catalogs", file.Name)
				}
			}
		}
	}
	installer, err := bundle.ReadFile("nvidia.ps1")
	if err != nil || !strings.Contains(string(installer), "nvidia-runtime-profiles.json") || !strings.Contains(string(installer), "AssertNvidiaFile $dest") {
		t.Fatal("embedded installer must load runtime profiles and validate NVIDIA signatures")
	}
	manager, err := bundle.ReadFile("manager.xaml")
	if err != nil || !strings.Contains(string(manager), `x:Name="DlssRuntimeProfile"`) || !strings.Contains(string(manager), "Frame Generation and Streamline remain pinned to their qualified compatibility group") {
		t.Fatal("manager must expose the per-game SR/RR choice and explain the independent FG stack")
	}
}

// Windows PowerShell 5.1 interprets BOM-less scripts using the ANSI code page.
// Non-ASCII punctuation can then become quote characters and break parsing.
func TestEmbeddedPowerShellEncoding(t *testing.T) {
	entries, err := bundle.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), ".ps1") {
			continue
		}
		data, err := bundle.ReadFile(entry.Name())
		if err != nil {
			t.Fatal(err)
		}
		if !strings.HasPrefix(string(data), "\ufeff") {
			t.Errorf("%s needs a UTF-8 BOM for Windows PowerShell 5.1", entry.Name())
		}
	}
}

func TestExecutableDiscoveryDependencyIsEmbedded(t *testing.T) {
	library, err := bundle.ReadFile("library.ps1")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(library), `. "$PSScriptRoot/executable.ps1"`) {
		t.Fatal("installer library no longer declares its executable discovery dependency")
	}
	helper, err := bundle.ReadFile("executable.ps1")
	if err != nil {
		t.Fatalf("installer helper bundle is missing executable.ps1: %v", err)
	}
	if !strings.Contains(string(helper), "function GetOptiShadeExecutableIdentity") {
		t.Fatal("embedded executable.ps1 does not define the discovery API required by library.ps1")
	}
}

func TestGlassCockpitUpdateHelperIsEmbedded(t *testing.T) {
	manager, err := bundle.ReadFile("manager.ps1")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(manager), `. "$PSScriptRoot/glass-cockpit-update.ps1"`) {
		t.Fatal("manager.ps1 no longer declares the Glass Cockpit update helper dependency")
	}
	helper, err := bundle.ReadFile("glass-cockpit-update.ps1")
	if err != nil {
		t.Fatalf("installer helper bundle is missing glass-cockpit-update.ps1: %v", err)
	}
	if !strings.Contains(string(helper), "function GetGlassCockpitLatestRelease") || !strings.Contains(string(helper), "function SaveGlassCockpitReleaseAsset") {
		t.Fatal("embedded Glass Cockpit helper does not define the APIs required by manager.ps1")
	}
}

func TestAtmosphereModPackageIsEmbedded(t *testing.T) {
	manager, err := bundle.ReadFile("manager.ps1")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(manager), `. "$PSScriptRoot/atmosphere-mod.ps1"`) {
		t.Fatal("manager.ps1 no longer declares the AtmosphereMod helper dependency")
	}
	for _, name := range []string{"atmosphere-mod.ps1", "AtmosphereMod/PROVENANCE.json", "AtmosphereMod/LICENSE.txt"} {
		if _, err := bundle.ReadFile(name); err != nil {
			t.Fatalf("installer bundle is missing %s: %v", name, err)
		}
	}
}

func TestLocalComponentPackageHelperIsEmbedded(t *testing.T) {
	helper, err := bundle.ReadFile("component-packages.ps1")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(helper), "function InstallLocalComponentPackage") {
		t.Fatal("local component updater entry point missing")
	}
}

func TestAntiCheatConsentResourcesEmbedded(t *testing.T) {
	for _, name := range []string{"anti-cheat.ps1", "anti-cheat-rules.json", "anti-cheat-dialog.xaml", "anti-cheat-agreement.xaml", "consent.ps1"} {
		data, err := bundle.ReadFile(name)
		if err != nil || len(data) == 0 {
			t.Fatalf("missing consent resource %s: %v", name, err)
		}
	}
}

func TestStartupUsesConsentWithoutTesterLoginOrAuthResources(t *testing.T) {
	manager, err := bundle.ReadFile("manager.ps1")
	if err != nil {
		t.Fatal(err)
	}
	text := string(manager)
	consentGate := strings.Index(text, "TestOptiShadeAntiCheatAccepted")
	consentDialog := strings.Index(text, "ConfirmOptiShadeAntiCheatAgreement")
	if consentGate < 0 || consentDialog < consentGate {
		t.Fatal("anti-cheat consent must remain ahead of manager initialization")
	}
	for _, token := range []string{"OPTISHADE_PRIVATE_TESTER_AUTH", "Test-OptiShadePrivateTesterAccess", "StartOptiShadePrivateTesterHeartbeat"} {
		if strings.Contains(text, token) {
			t.Fatalf("manager still contains private tester auth integration: %s", token)
		}
	}
	lifetime, err := bundle.ReadFile("manager-lifetime.ps1")
	if err != nil {
		t.Fatal(err)
	}
	for _, token := range []string{"StartOptiShadePrivateTesterHeartbeat", "/v1/session/heartbeat"} {
		if strings.Contains(string(lifetime), token) {
			t.Fatalf("manager lifetime helper still contains private tester heartbeat: %s", token)
		}
	}
	for _, name := range []string{"tester-auth.ps1", "tester-login.xaml"} {
		if _, err := bundle.ReadFile(name); err == nil {
			t.Fatalf("manager bundle unexpectedly contains removed tester resource %s", name)
		}
	}
}

func TestEmbeddedManagerHelperClosure(t *testing.T) {
	// These APIs must exist in the bytes shipped by go:embed. Checking source
	// files on disk would miss an extracted-manager startup failure.
	for name, api := range map[string]string{
		"manager-lifetime.ps1":     "function InitializeOptiShadeManagerLifetime",
		"xplane-compatibility.ps1": "function SetOptiShadeXPlaneRoute",
	} {
		data, err := bundle.ReadFile(name)
		if err != nil || !strings.Contains(string(data), api) {
			t.Errorf("embedded manager helper %s is missing its required API: %v", name, err)
		}
	}
	// Enforce static dot-source closure for every top-level shipped script,
	// including imports inside optional branches. Dynamic filenames require
	// separate execution fixtures; do not mistake them for literal paths.
	dependency := regexp.MustCompile(`(?m)(?:^|[;{}\s])\.\s+["']\$PSScriptRoot/([^"'$\r\n]+)["']`)
	entries, err := bundle.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".ps1") {
			continue
		}
		data, err := bundle.ReadFile(entry.Name())
		if err != nil {
			t.Fatal(err)
		}
		for _, match := range dependency.FindAllSubmatch(data, -1) {
			name := string(match[1])
			bytes, err := bundle.ReadFile(name)
			if err != nil || len(bytes) == 0 {
				t.Errorf("%s dot-sources %s, absent or empty in the embedded bundle: %v", entry.Name(), name, err)
			}
		}
	}
}
