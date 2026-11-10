package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type tarTestEntry struct {
	name     string
	data     string
	typeflag byte
	link     string
}

func TestComponentTargetsForSelection(t *testing.T) {
	for _, test := range []struct {
		name      string
		requested []string
		want      []string
		wantError bool
	}{
		{name: "core only", requested: []string{"OptiShade.Core"}, want: []string{"OptiShade.Core"}},
		{name: "effects only optional package", requested: []string{"OptiShade.Effects"}, want: []string{"OptiShade.Core", "OptiShade.Effects"}},
		{name: "MFG only optional package", requested: []string{"OptiShade.OptiMFG"}, want: []string{"OptiShade.Core", "OptiShade.OptiMFG"}},
		{name: "all packages", want: []string{"OptiShade.Core", "OptiShade.Effects", "OptiShade.OptiMFG", "OptiShade.Providers.AMD", "OptiShade.Providers.Intel"}},
		{name: "unknown package rejected", requested: []string{"OptiShade.Neural"}, wantError: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			got, err := componentTargetsForSelection(test.requested)
			if test.wantError {
				if err == nil {
					t.Fatal("unsupported component selection was accepted")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if len(got) != len(test.want) {
				t.Fatalf("selected %d targets, want %d", len(got), len(test.want))
			}
			for i, target := range got {
				if target.id != test.want[i] {
					t.Fatalf("target %d is %s, want %s", i, target.id, test.want[i])
				}
			}
		})
	}
}

func writeComponentTestTarGz(t *testing.T, path string, entries []tarTestEntry) {
	t.Helper()
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	gz := gzip.NewWriter(file)
	tw := tar.NewWriter(gz)
	for _, entry := range entries {
		typeflag := entry.typeflag
		if typeflag == 0 {
			typeflag = tar.TypeReg
		}
		header := &tar.Header{Name: entry.name, Typeflag: typeflag, Linkname: entry.link, Mode: 0600}
		if typeflag == tar.TypeReg || typeflag == tar.TypeRegA {
			header.Size = int64(len(entry.data))
		}
		if err := tw.WriteHeader(header); err != nil {
			t.Fatal(err)
		}
		if header.Size > 0 {
			if _, err := tw.Write([]byte(entry.data)); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestExtractVerifiedComponentTarGz(t *testing.T) {
	t.Run("complete hash-verified inventory", func(t *testing.T) {
		root := t.TempDir()
		archive := filepath.Join(root, "component.tar.gz")
		stage := filepath.Join(root, "stage")
		if err := os.Mkdir(stage, 0700); err != nil {
			t.Fatal(err)
		}
		payload := "verified component payload"
		digest := sha256.Sum256([]byte(payload))
		writeComponentTestTarGz(t, archive, []tarTestEntry{{name: "Package/Runtime/helper.dll", data: payload}})
		expected := map[string]verifiedComponentArchiveFile{
			"Package/Runtime/helper.dll": {install: "Runtime/helper.dll", bytes: int64(len(payload)), digest: hex.EncodeToString(digest[:])},
		}
		if err := extractVerifiedComponentTarGz(archive, stage, expected, 1024); err != nil {
			t.Fatal(err)
		}
		actual, err := os.ReadFile(filepath.Join(stage, "Runtime", "helper.dll"))
		if err != nil || string(actual) != payload {
			t.Fatalf("staged payload=%q err=%v", actual, err)
		}
	})
	t.Run("normalizes ordinary tar root prefixes and ignores bounded catalogue metadata", func(t *testing.T) {
		root := t.TempDir()
		archive := filepath.Join(root, "component.tar.gz")
		stage := filepath.Join(root, "stage")
		if err := os.Mkdir(stage, 0700); err != nil {
			t.Fatal(err)
		}
		payload := "root-prefixed payload"
		digest := sha256.Sum256([]byte(payload))
		entries := []tarTestEntry{
			{name: "./", typeflag: tar.TypeDir},
			{name: "./component-package.json", data: `{"schema":1}`},
			{name: "./files.json", data: `[]`},
			{name: "./Payload/Runtime/helper.dll", data: payload},
		}
		writeComponentTestTarGz(t, archive, entries)
		expected := map[string]verifiedComponentArchiveFile{
			"Payload/Runtime/helper.dll": {install: "Runtime/helper.dll", bytes: int64(len(payload)), digest: hex.EncodeToString(digest[:])},
		}
		if err := extractVerifiedComponentTarGz(archive, stage, expected, 1024); err != nil {
			t.Fatal(err)
		}
		actual, err := os.ReadFile(filepath.Join(stage, "Runtime", "helper.dll"))
		if err != nil || string(actual) != payload {
			t.Fatalf("staged payload=%q err=%v", actual, err)
		}
	})

	for _, test := range []struct {
		name     string
		entry    tarTestEntry
		expected map[string]verifiedComponentArchiveFile
	}{
		{name: "unlisted file", entry: tarTestEntry{name: "unexpected.dll", data: "x"}, expected: map[string]verifiedComponentArchiveFile{}},
		{name: "path traversal", entry: tarTestEntry{name: "../escape.dll", data: "x"}, expected: map[string]verifiedComponentArchiveFile{"../escape.dll": {install: "escape.dll", bytes: 1, digest: strings.Repeat("a", 64)}}},
		{name: "symbolic link", entry: tarTestEntry{name: "linked.dll", typeflag: tar.TypeSymlink, link: "outside.dll"}, expected: map[string]verifiedComponentArchiveFile{"linked.dll": {install: "linked.dll", bytes: 0, digest: strings.Repeat("a", 64)}}},
		{name: "wrong hash", entry: tarTestEntry{name: "file.dll", data: "different"}, expected: map[string]verifiedComponentArchiveFile{"file.dll": {install: "file.dll", bytes: 9, digest: strings.Repeat("a", 64)}}},
		{name: "omitted file", entry: tarTestEntry{name: "other.dll", data: "x"}, expected: map[string]verifiedComponentArchiveFile{"missing.dll": {install: "missing.dll", bytes: 1, digest: strings.Repeat("a", 64)}}},
	} {
		t.Run(test.name, func(t *testing.T) {
			root := t.TempDir()
			archive := filepath.Join(root, "component.tar.gz")
			stage := filepath.Join(root, "stage")
			if err := os.Mkdir(stage, 0700); err != nil {
				t.Fatal(err)
			}
			writeComponentTestTarGz(t, archive, []tarTestEntry{test.entry})
			if err := extractVerifiedComponentTarGz(archive, stage, test.expected, 1024); err == nil {
				t.Fatal("unsafe or incomplete component archive was accepted")
			}
		})
	}
}

func TestStageSignedComponentArchive(t *testing.T) {
	root := t.TempDir()
	archive := filepath.Join(root, "core.tar.gz")
	cache := filepath.Join(root, "cache")
	payload := "signed staged component"
	payloadHash := sha256.Sum256([]byte(payload))
	writeComponentTestTarGz(t, archive, []tarTestEntry{{name: "Payload/Runtime/helper.dll", data: payload}})
	archiveHash, err := componentFileSHA256(archive)
	if err != nil {
		t.Fatal(err)
	}
	archiveInfo, err := os.Stat(archive)
	if err != nil {
		t.Fatal(err)
	}
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	release := signedComponentRelease{
		Schema: 1, ComponentID: "OptiShade.Core", Version: "1.2.3", Channel: "stable",
		PublishedUTC: "2026-11-08T00:00:00Z", SourceCommit: strings.Repeat("a", 40),
		Contracts: map[string]string{"core-api": "1"},
		Dependencies: []struct {
			ComponentID    string `json:"componentId"`
			MinimumVersion string `json:"minimumVersion"`
		}{},
		Files: []struct {
			PackagePath        string `json:"packagePath"`
			InstallPath        string `json:"installPath"`
			Bytes              int64  `json:"bytes"`
			SHA256             string `json:"sha256"`
			PreconditionSHA256 string `json:"preconditionSha256"`
		}{{PackagePath: "Payload/Runtime/helper.dll", InstallPath: "OptiShadeData/Runtime/helper.dll", Bytes: int64(len(payload)), SHA256: hex.EncodeToString(payloadHash[:])}},
	}
	release.LauncherRange.MinInclusive = "1.0.0"
	release.LauncherRange.MaxExclusive = "2.0.0"
	release.Package.Branch = "core-stable"
	release.Package.Path = "packages/OptiShade.Core.tar.gz"
	release.Package.Bytes = archiveInfo.Size()
	release.Package.SHA256 = archiveHash
	canonical, err := marshalComponentReleasePayload(&release)
	if err != nil {
		t.Fatal(err)
	}
	release.Signature.Algorithm = "Ed25519"
	release.Signature.KeyID = "stage-test-key"
	release.Signature.Value = base64.StdEncoding.EncodeToString(ed25519.Sign(private, canonical))
	manifestBytes, err := json.Marshal(release)
	if err != nil {
		t.Fatal(err)
	}
	publicB64 := base64.StdEncoding.EncodeToString(public)

	stage, err := stageSignedComponentArchiveWithKey(manifestBytes, archive, cache, publicB64, "stage-test-key")
	if err != nil {
		t.Fatal(err)
	}
	staged, err := os.ReadFile(filepath.Join(stage, "OptiShadeData", "Runtime", "helper.dll"))
	if err != nil || string(staged) != payload {
		t.Fatalf("staged bytes=%q err=%v", staged, err)
	}
	if _, err := os.Stat(filepath.Join(stage, "stage-receipt.json")); err != nil {
		t.Fatalf("stage receipt missing: %v", err)
	}
	stageAgain, err := stageSignedComponentArchiveWithKey(manifestBytes, archive, cache, publicB64, "stage-test-key")
	if err != nil || stageAgain != stage {
		t.Fatalf("verified staged cache not reused: stage=%q again=%q err=%v", stage, stageAgain, err)
	}

	tampered := strings.Replace(string(manifestBytes), `"version":"1.2.3"`, `"version":"1.2.4"`, 1)
	if _, err := stageSignedComponentArchiveWithKey([]byte(tampered), archive, cache, publicB64, "stage-test-key"); err == nil {
		t.Fatal("tampered signed manifest was accepted")
	}
}

type componentPayloadTestFile struct {
	archivePath string
	installPath string
	data        string
}

func signedTestComponent(t *testing.T, cache string, public ed25519.PublicKey, private ed25519.PrivateKey, id string, files []componentPayloadTestFile, contracts map[string]string) string {
	t.Helper()
	archivePath := filepath.Join(t.TempDir(), "component.tar.gz")
	entries := make([]tarTestEntry, 0, len(files))
	for _, file := range files {
		entries = append(entries, tarTestEntry{name: file.archivePath, data: file.data})
	}
	writeComponentTestTarGz(t, archivePath, entries)
	archiveHash, err := componentFileSHA256(archivePath)
	if err != nil {
		t.Fatal(err)
	}
	archiveInfo, err := os.Stat(archivePath)
	if err != nil {
		t.Fatal(err)
	}
	release := signedComponentRelease{
		Schema: 1, ComponentID: id, Version: "1.2.3", Channel: "stable", PublishedUTC: "2026-11-08T00:00:00Z",
		SourceCommit: strings.Repeat("b", 40), Contracts: contracts,
		Dependencies: []struct {
			ComponentID    string `json:"componentId"`
			MinimumVersion string `json:"minimumVersion"`
		}{},
		Files: []struct {
			PackagePath        string `json:"packagePath"`
			InstallPath        string `json:"installPath"`
			Bytes              int64  `json:"bytes"`
			SHA256             string `json:"sha256"`
			PreconditionSHA256 string `json:"preconditionSha256"`
		}{},
	}
	for _, file := range files {
		digest := sha256.Sum256([]byte(file.data))
		release.Files = append(release.Files, struct {
			PackagePath        string `json:"packagePath"`
			InstallPath        string `json:"installPath"`
			Bytes              int64  `json:"bytes"`
			SHA256             string `json:"sha256"`
			PreconditionSHA256 string `json:"preconditionSha256"`
		}{file.archivePath, file.installPath, int64(len(file.data)), hex.EncodeToString(digest[:]), ""})
	}
	release.LauncherRange.MinInclusive = "1.0.0"
	release.LauncherRange.MaxExclusive = "2.0.0"
	branch := map[string]string{"OptiShade.Core": "core-stable", "OptiShade.Effects": "effects-stable", "OptiShade.OptiMFG": "optimfg-stable"}[id]
	release.Package.Branch = branch
	release.Package.Path = "packages/test.tar.gz"
	release.Package.Bytes = archiveInfo.Size()
	release.Package.SHA256 = archiveHash
	canonical, err := marshalComponentReleasePayload(&release)
	if err != nil {
		t.Fatal(err)
	}
	release.Signature.Algorithm = "Ed25519"
	release.Signature.KeyID = "payload-test-key"
	release.Signature.Value = base64.StdEncoding.EncodeToString(ed25519.Sign(private, canonical))
	manifest, err := json.Marshal(release)
	if err != nil {
		t.Fatal(err)
	}
	stage, err := stageSignedComponentArchiveWithKey(manifest, archivePath, cache, base64.StdEncoding.EncodeToString(public), "payload-test-key")
	if err != nil {
		t.Fatal(err)
	}
	return stage
}

func TestComposeVerifiedComponentPayload(t *testing.T) {
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	cache := filepath.Join(t.TempDir(), "cache")
	identity := `{"Version":"1.0.77"}`
	fileHash := func(value string) string {
		digest := sha256.Sum256([]byte(value))
		return hex.EncodeToString(digest[:])
	}
	catalog := `[{"Path":"OptiShadeData/BuildIdentity.json","Hash":"` + fileHash(identity) + `"},{"Path":"ReShade64.dll","Hash":"` + fileHash("runtime") + `"}]`
	core := signedTestComponent(t, cache, public, private, "OptiShade.Core", []componentPayloadTestFile{
		{archivePath: "Payload/files.json", installPath: "files.json", data: catalog},
		{archivePath: "Payload/OptiShadeData/BuildIdentity.json", installPath: "OptiShadeData/BuildIdentity.json", data: identity},
		{archivePath: "Payload/ReShade64.dll", installPath: "ReShade64.dll", data: "runtime"},
	}, map[string]string{"core-api": "4"})
	effects := signedTestComponent(t, cache, public, private, "OptiShade.Effects", []componentPayloadTestFile{
		{archivePath: "Payload/OptiShadeData/Shaders/Custom/Test.fx", installPath: "OptiShadeData/Shaders/Custom/Test.fx", data: "shader"},
	}, map[string]string{"core-api": "4"})
	destination := filepath.Join(t.TempDir(), "PayloadFusion")
	if err := composeVerifiedComponentPayloadWithKey([]string{core, effects}, destination, base64.StdEncoding.EncodeToString(public), "payload-test-key"); err != nil {
		t.Fatal(err)
	}
	for _, relative := range []string{"files.json", "OptiShadeData/BuildIdentity.json", "ReShade64.dll", "OptiShadeData/Shaders/Custom/Test.fx"} {
		if _, err := os.Stat(filepath.Join(destination, filepath.FromSlash(relative))); err != nil {
			t.Fatalf("composed payload missing %s: %v", relative, err)
		}
	}
	mergedCatalog, err := os.ReadFile(filepath.Join(destination, "files.json"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(mergedCatalog), `"Path": "OptiShadeData/Shaders/Custom/Test.fx"`) || !strings.Contains(string(mergedCatalog), fileHash("shader")) {
		t.Fatal("signed optional component was not added to the composed install catalogue")
	}
	for i := 0; i < 4; i++ {
		second := filepath.Join(t.TempDir(), "PayloadFusion")
		if err := composeVerifiedComponentPayloadWithKey([]string{effects, core}, second, base64.StdEncoding.EncodeToString(public), "payload-test-key"); err != nil {
			t.Fatal(err)
		}
		otherCatalog, err := os.ReadFile(filepath.Join(second, "files.json"))
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(mergedCatalog, otherCatalog) {
			t.Fatal("composing the same signed component set in another order produced a different installer catalogue")
		}
	}
	if err := composeVerifiedComponentPayloadWithKey([]string{core}, destination, base64.StdEncoding.EncodeToString(public), "payload-test-key"); err == nil {
		t.Fatal("composer overwrote an existing payload destination")
	}
}

func TestComposeVerifiedComponentPayloadRejectsContractConflict(t *testing.T) {
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	cache := filepath.Join(t.TempDir(), "cache")
	core := signedTestComponent(t, cache, public, private, "OptiShade.Core", []componentPayloadTestFile{
		{archivePath: "Payload/files.json", installPath: "files.json", data: `[{"Path":"a.dll","Hash":"` + strings.Repeat("a", 64) + `"}]`},
		{archivePath: "Payload/OptiShadeData/BuildIdentity.json", installPath: "OptiShadeData/BuildIdentity.json", data: `{"Version":"1.0.77"}`},
	}, map[string]string{"core-api": "4"})
	effects := signedTestComponent(t, cache, public, private, "OptiShade.Effects", []componentPayloadTestFile{
		{archivePath: "Payload/effect.fx", installPath: "OptiShadeData/Shaders/Custom/effect.fx", data: "shader"},
	}, map[string]string{"core-api": "5"})
	destination := filepath.Join(t.TempDir(), "PayloadFusion")
	if err := composeVerifiedComponentPayloadWithKey([]string{core, effects}, destination, base64.StdEncoding.EncodeToString(public), "payload-test-key"); err == nil {
		t.Fatal("conflicting component compatibility contracts were accepted")
	}
	if _, err := os.Lstat(destination); !os.IsNotExist(err) {
		t.Fatalf("failed composition left a destination behind: %v", err)
	}
}

func TestCompareComponentVersions(t *testing.T) {
	for _, tc := range []struct {
		left, right string
		want        int
	}{
		{"1.0.0", "1.0.0", 0},
		{"1.0.1", "1.0.0", 1},
		{"1.0.0-alpha.2", "1.0.0-alpha.10", -1},
		{"1.0.0-rc.1", "1.0.0", -1},
	} {
		if got := compareComponentVersions(tc.left, tc.right); got != tc.want {
			t.Errorf("compareComponentVersions(%q, %q)=%d, want %d", tc.left, tc.right, got, tc.want)
		}
	}
}
