package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type componentRoundTripper func(*http.Request) (*http.Response, error)

func (roundTrip componentRoundTripper) RoundTrip(request *http.Request) (*http.Response, error) {
	return roundTrip(request)
}

func TestComponentResultFolderFollowsInstalledAndPortableManager(t *testing.T) {
	base := t.TempDir()
	localAppData := filepath.Join(base, "LocalAppData")
	if err := os.MkdirAll(localAppData, 0700); err != nil {
		t.Fatal(err)
	}
	installedExe := filepath.Join(base, "installed", "OptiShade.exe")
	if err := os.MkdirAll(filepath.Dir(installedExe), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(installedExe, []byte("manager"), 0600); err != nil {
		t.Fatal(err)
	}
	installedSession, err := componentResultSessionDirectory(installedExe, localAppData)
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(localAppData, "OptiShade", "Sessions"); !strings.EqualFold(installedSession, want) {
		t.Fatalf("installed session folder = %q, want %q", installedSession, want)
	}

	portableExe := filepath.Join(base, "portable", "OptiShade.exe")
	if err := os.MkdirAll(filepath.Dir(portableExe), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(portableExe, []byte("manager"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(filepath.Dir(portableExe), "portable.txt"), []byte("portable"), 0600); err != nil {
		t.Fatal(err)
	}
	portableSession, err := componentResultSessionDirectory(portableExe, localAppData)
	if err != nil {
		t.Fatal(err)
	}
	wantPortable := filepath.Join(filepath.Dir(portableExe), "Data", "Sessions")
	if !strings.EqualFold(portableSession, wantPortable) {
		t.Fatalf("portable session folder = %q, want %q", portableSession, wantPortable)
	}

	resultPath := filepath.Join(portableSession, "component-stage-test-0123456789abcdef0123456789abcdef.json")
	if err := writeComponentDownloadResultForExecutable(resultPath, componentDownloadResult{Schema: 1, OK: true, Message: "portable"}, nil, portableExe, localAppData); err != nil {
		t.Fatalf("write portable result: %v", err)
	}
	if _, err := os.Stat(resultPath); err != nil {
		t.Fatalf("portable result was not written: %v", err)
	}
	channelResult := filepath.Join(portableSession, "component-channel-check-0123456789abcdef0123456789abcdef.json")
	if err := writeComponentDownloadResultForExecutable(channelResult, componentDownloadResult{Schema: 1, OK: true, Message: "channel check"}, nil, portableExe, localAppData); err != nil {
		t.Fatalf("write channel-check result: %v", err)
	}
	if _, err := os.Stat(channelResult); err != nil {
		t.Fatalf("channel-check result was not written: %v", err)
	}
	outside := filepath.Join(base, "outside", filepath.Base(resultPath))
	if err := writeComponentDownloadResultForExecutable(outside, componentDownloadResult{Schema: 1}, nil, portableExe, localAppData); err == nil {
		t.Fatal("result writer accepted a path outside the portable session folder")
	}
}

func TestValidateComponentDownloadArtifact(t *testing.T) {
	tests := []struct {
		name    string
		file    string
		bytes   int64
		digest  string
		wantErr bool
	}{
		{name: "valid", file: "OptiShade.Core.tar.gz", bytes: 100, digest: strings.Repeat("a", 64)},
		{name: "path traversal", file: "../payload.tar.gz", bytes: 100, digest: strings.Repeat("a", 64), wantErr: true},
		{name: "empty file", file: "", bytes: 100, digest: strings.Repeat("a", 64), wantErr: true},
		{name: "empty payload", file: "package.tar.gz", bytes: 0, digest: strings.Repeat("a", 64), wantErr: true},
		{name: "over limit", file: "package.tar.gz", bytes: componentDownloadMaxBytes + 1, digest: strings.Repeat("a", 64), wantErr: true},
		{name: "bad digest", file: "package.tar.gz", bytes: 100, digest: "not-a-hash", wantErr: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := validateComponentDownloadArtifact(componentDownloadArtifact{File: test.file, Bytes: test.bytes, SHA256: test.digest})
			if (err != nil) != test.wantErr {
				t.Fatalf("validate error = %v, wantErr %v", err, test.wantErr)
			}
		})
	}
}

func TestComponentChannelCheckSelectsOnlyRequestedInstalledChannels(t *testing.T) {
	for _, test := range []struct {
		name     string
		request  []string
		want     []string
		wantErr  bool
	}{
		{name: "Core only", request: []string{"OptiShade.Core"}, want: []string{"OptiShade.Core"}},
		{name: "Effects only", request: []string{"OptiShade.Effects"}, want: []string{"OptiShade.Effects"}},
		{name: "OptiMFG only", request: []string{"OptiShade.OptiMFG"}, want: []string{"OptiShade.OptiMFG"}},
		{name: "Providers split", request: []string{"OptiShade.Providers"}, want: []string{"OptiShade.Providers.AMD", "OptiShade.Providers.Intel"}},
		{name: "Unknown channel", request: []string{"OptiShade.Unknown"}, wantErr: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			got, err := componentTargetsForChannelCheck(test.request)
			if (err != nil) != test.wantErr {
				t.Fatalf("error = %v, wantErr %v", err, test.wantErr)
			}
			if err != nil {
				return
			}
			ids := make([]string, len(got))
			for i, target := range got {
				ids[i] = target.id
			}
			if strings.Join(ids, ",") != strings.Join(test.want, ",") {
				t.Fatalf("channel check selected %v, want %v", ids, test.want)
			}
		})
	}
}

func TestFetchComponentDownloadManifestRequiresDownloadOnly(t *testing.T) {
	for _, installable := range []bool{false, true} {
		t.Run(map[bool]string{false: "download only", true: "installable rejected"}[installable], func(t *testing.T) {
			body := `{"schema":1,"componentId":"OptiShade.Core","version":"1.0.77","channel":"download-only","installable":` + map[bool]string{false: "false", true: "true"}[installable] + `,"package":{"file":"OptiShade.Core.tar.gz","bytes":100,"sha256":"` + strings.Repeat("a", 64) + `"}}`
			client := &http.Client{Transport: componentRoundTripper(func(request *http.Request) (*http.Response, error) {
				if request.URL.Host != "raw.githubusercontent.com" {
					t.Fatalf("unexpected manifest request URL: %s", request.URL)
				}
				if request.URL.Path == "/GamingWithGravy/OptiShade/core-stable/channel.json" {
					return &http.Response{StatusCode: http.StatusNotFound, Body: io.NopCloser(strings.NewReader("not found")), Header: make(http.Header), Request: request}, nil
				}
				if request.URL.Path != "/GamingWithGravy/OptiShade/core-stable/manifest.json" {
					t.Fatalf("unexpected manifest request URL: %s", request.URL)
				}
				return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header), Request: request}, nil
			})}
			manifest, err := fetchComponentDownloadManifest(context.Background(), client, componentDownloadTargets[0])
			if installable && err == nil {
				t.Fatal("installable manifest was accepted by the download-only verifier")
			}
			if !installable && err != nil {
				t.Fatalf("valid download-only manifest rejected: %v", err)
			}
			if !installable && manifest.Package.Bytes != 100 {
				t.Fatalf("package size = %d, want 100", manifest.Package.Bytes)
			}
		})
	}
}

func TestFetchComponentDownloadPackageVerifiesAndReusesCache(t *testing.T) {
	body := []byte("verified component archive test")
	temp := t.TempDir()
	seed := temp + "\\seed"
	if err := os.WriteFile(seed, body, 0600); err != nil {
		t.Fatal(err)
	}
	digest, err := componentFileSHA256(seed)
	if err != nil {
		t.Fatal(err)
	}
	target := componentDownloadTarget{branch: "core-stable", id: "OptiShade.Core", label: "OptiShade Core"}
	artifact := componentDownloadArtifact{File: "package.tar.gz", Bytes: int64(len(body)), SHA256: digest}
	calls := 0
	client := &http.Client{Transport: componentRoundTripper(func(request *http.Request) (*http.Response, error) {
		calls++
		if request.URL.Host != "raw.githubusercontent.com" || request.URL.Path != "/GamingWithGravy/OptiShade/core-stable/packages/package.tar.gz" {
			t.Fatalf("unexpected package request URL: %s", request.URL)
		}
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(string(body))), Header: make(http.Header), Request: request}, nil
	})}
	path, cached, err := fetchComponentDownloadPackage(context.Background(), client, target, artifact, temp)
	if err != nil {
		t.Fatal(err)
	}
	if cached || calls != 1 {
		t.Fatalf("first fetch cached=%v calls=%d, want cached=false calls=1", cached, calls)
	}
	path2, cached, err := fetchComponentDownloadPackage(context.Background(), client, target, artifact, temp)
	if err != nil {
		t.Fatal(err)
	}
	if path2 != path || !cached || calls != 1 {
		t.Fatalf("second fetch path=%q cached=%v calls=%d, expected reuse without network", path2, cached, calls)
	}
}

func TestLocalComponentSourceRejectsUnsafePathsAndOversizedFiles(t *testing.T) {
	root := t.TempDir()
	branch := filepath.Join(root, "core-stable")
	packages := filepath.Join(branch, "packages")
	if err := os.MkdirAll(packages, 0700); err != nil {
		t.Fatal(err)
	}
	manifest := []byte(`{"schema":1}`)
	if err := os.WriteFile(filepath.Join(branch, "channel.json"), manifest, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packages, "package.tar.gz"), []byte("package"), 0600); err != nil {
		t.Fatal(err)
	}

	if _, configured, err := localComponentSourceRoot(); err != nil || configured {
		t.Fatalf("unset source root = configured %v, error %v; want unset", configured, err)
	}
	t.Setenv(componentSourceRootEnv, root)
	resolved, configured, err := localComponentSourceRoot()
	if err != nil || !configured || resolved != root {
		t.Fatalf("local source root = %q, configured %v, error %v", resolved, configured, err)
	}
	if _, err := openLocalComponentSourceFile(root, "../core-stable", "channel.json", 1024); err == nil {
		t.Fatal("branch traversal was accepted")
	}
	if _, err := openLocalComponentSourceFile(root, "core-stable", "../channel.json", 1024); err == nil {
		t.Fatal("file traversal was accepted")
	}
	if _, err := openLocalComponentSourceFile(root, "core-stable", "packages/package.tar.gz", 3); err == nil {
		t.Fatal("oversized local source file was accepted")
	}
	body, err := readLocalComponentSourceFile(root, "core-stable", "channel.json", int64(len(manifest)))
	if err != nil || string(body) != string(manifest) {
		t.Fatalf("bounded local manifest read = %q, error %v", body, err)
	}
}

func TestComponentStageCacheRootCreatesPrivateCacheDirectory(t *testing.T) {
	base := t.TempDir()
	t.Setenv("LOCALAPPDATA", base)
	root, err := componentStageCacheRoot()
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(base, "OptiShade", "ComponentPackages")
	if !strings.EqualFold(filepath.Clean(root), filepath.Clean(want)) {
		t.Fatalf("cache root = %q, want %q", root, want)
	}
	info, err := os.Stat(root)
	if err != nil || !info.IsDir() {
		t.Fatalf("cache root was not created as a directory: info=%v error=%v", info, err)
	}
}

func TestSavedComponentSetCanBeRevalidatedAndComposedAfterRestart(t *testing.T) {
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	base := t.TempDir()
	t.Setenv("LOCALAPPDATA", base)
	cache, err := componentStageCacheRoot()
	if err != nil {
		t.Fatal(err)
	}
	hash := func(value string) string {
		digest := sha256.Sum256([]byte(value))
		return fmt.Sprintf("%x", digest[:])
	}
	identity := `{"Version":"1.0.77"}`
	catalog := `[{"Path":"OptiShadeData/BuildIdentity.json","Hash":"` + hash(identity) + `"},{"Path":"ReShade64.dll","Hash":"` + hash("runtime") + `"}]`
	coreRoot := signedTestComponent(t, cache, public, private, "OptiShade.Core", []componentPayloadTestFile{
		{archivePath: "Payload/files.json", installPath: "files.json", data: catalog},
		{archivePath: "Payload/OptiShadeData/BuildIdentity.json", installPath: "OptiShadeData/BuildIdentity.json", data: identity},
		{archivePath: "Payload/ReShade64.dll", installPath: "ReShade64.dll", data: "runtime"},
	}, map[string]string{"core-api": "4"})
	effectsRoot := signedTestComponent(t, cache, public, private, "OptiShade.Effects", []componentPayloadTestFile{
		{archivePath: "Payload/OptiShadeData/Shaders/Custom/Test.fx", installPath: "OptiShadeData/Shaders/Custom/Test.fx", data: "shader"},
	}, map[string]string{"core-api": "4"})
	readRecord := func(root string) componentDownloadRecord {
		body, readErr := os.ReadFile(filepath.Join(root, componentStageReleaseManifest))
		if readErr != nil {
			t.Fatal(readErr)
		}
		release, verifyErr := verifySignedComponentReleaseWithKey(body, base64.StdEncoding.EncodeToString(public), "payload-test-key")
		if verifyErr != nil {
			t.Fatal(verifyErr)
		}
		return componentDownloadRecord{Component: release.ComponentID, Version: release.Version, Bytes: release.Package.Bytes, SHA256: release.Package.SHA256, StagePath: root, Trusted: true}
	}
	if err := saveComponentActiveSet(cache, "1.0.77", []componentDownloadRecord{readRecord(coreRoot), readRecord(effectsRoot)}); err != nil {
		t.Fatal(err)
	}
	session := filepath.Join(base, "OptiShade", "Sessions")
	if err := os.MkdirAll(session, 0700); err != nil {
		t.Fatal(err)
	}
	resultPath := filepath.Join(session, "component-compose-cache-0123456789abcdef0123456789abcdef.json")
	payload := filepath.Join(session, "PayloadFusion-staged-0123456789abcdef0123456789abcdef")
	if err := runComponentComposeCachedWithKey(resultPath, payload, "1.5.0", base64.StdEncoding.EncodeToString(public), "payload-test-key"); err != nil {
		t.Fatal(err)
	}
	resultBytes, err := os.ReadFile(resultPath)
	if err != nil {
		t.Fatal(err)
	}
	var result componentDownloadResult
	if err := json.Unmarshal(resultBytes, &result); err != nil {
		t.Fatal(err)
	}
	if !result.OK || result.ComposedPayload != payload || len(result.Packages) != 2 {
		t.Fatalf("cached compose result = %+v", result)
	}
	if body, err := os.ReadFile(filepath.Join(payload, "OptiShadeData", "Shaders", "Custom", "Test.fx")); err != nil || string(body) != "shader" {
		t.Fatalf("composed effect file = %q, error %v", body, err)
	}
	thirdID := "abcdef0123456789abcdef0123456789"
	thirdResult := filepath.Join(session, "component-compose-cache-"+thirdID+".json")
	thirdPayload := filepath.Join(session, "PayloadFusion-staged-"+thirdID)
	if err := runComponentComposeCachedWithKey(thirdResult, thirdPayload, "2.0.0", base64.StdEncoding.EncodeToString(public), "payload-test-key"); err == nil {
		t.Fatal("manager outside the signed launcher range was accepted")
	}
	thirdBytes, err := os.ReadFile(thirdResult)
	if err != nil {
		t.Fatal(err)
	}
	var incompatible componentDownloadResult
	if err := json.Unmarshal(thirdBytes, &incompatible); err != nil {
		t.Fatal(err)
	}
	if incompatible.OK || incompatible.ComposedPayload != "" || !strings.Contains(incompatible.Message, "incompatible with this manager") {
		t.Fatalf("out-of-range manager unexpectedly composed payload: %+v", incompatible)
	}
	if err := os.WriteFile(filepath.Join(effectsRoot, "OptiShadeData", "Shaders", "Custom", "Test.fx"), []byte("tampered"), 0600); err != nil {
		t.Fatal(err)
	}
	secondID := "fedcba9876543210fedcba9876543210"
	secondResult := filepath.Join(session, "component-compose-cache-"+secondID+".json")
	secondPayload := filepath.Join(session, "PayloadFusion-staged-"+secondID)
	if err := runComponentComposeCachedWithKey(secondResult, secondPayload, "1.5.0", base64.StdEncoding.EncodeToString(public), "payload-test-key"); err == nil {
		t.Fatal("tampered cached component set was accepted")
	}
	secondBytes, err := os.ReadFile(secondResult)
	if err != nil {
		t.Fatal(err)
	}
	var rejected componentDownloadResult
	if err := json.Unmarshal(secondBytes, &rejected); err != nil {
		t.Fatal(err)
	}
	if rejected.OK || rejected.ComposedPayload != "" {
		t.Fatalf("tampered cached set was not rejected: %+v", rejected)
	}
	if _, err := os.Stat(secondPayload); !os.IsNotExist(err) {
		t.Fatalf("tampered cached set created a payload path: stat error %v", err)
	}
}
