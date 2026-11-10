// Copyright (c) 2026 GamingWithGravy. All rights reserved.
// Component transport verifier and signed local-cache staging prototype.
// Neither command executes packages nor writes to game directories.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// GitHub serves ordinary repository files without LFS or authentication and
// rejects files at 100 MiB. Leave a small margin under that hard limit.
const componentDownloadMaxBytes int64 = 99 << 20

type componentDownloadTarget struct {
	branch string
	id     string
	label  string
}

var componentDownloadTargets = []componentDownloadTarget{
	{branch: "core-stable", id: "OptiShade.Core", label: "OptiShade Core"},
	{branch: "effects-stable", id: "OptiShade.Effects", label: "Image Effects"},
	{branch: "optimfg-stable", id: "OptiShade.OptiMFG", label: "OptiMFG"},
	{branch: "providers-amd-stable", id: "OptiShade.Providers.AMD", label: "AMD FidelityFX providers"},
	{branch: "providers-intel-stable", id: "OptiShade.Providers.Intel", label: "Intel XeSS providers"},
}

type componentDownloadArtifact struct {
	File   string `json:"file"`
	Bytes  int64  `json:"bytes"`
	SHA256 string `json:"sha256"`
	Path   string `json:"-"`
}

type componentDownloadManifest struct {
	Schema      int                       `json:"schema"`
	ComponentID string                    `json:"componentId"`
	Version     string                    `json:"version"`
	Channel     string                    `json:"channel"`
	Installable *bool                     `json:"installable"`
	Package     componentDownloadArtifact `json:"package"`
	Trusted     bool                      `json:"-"`
	Release     *signedComponentRelease   `json:"-"`
	SignedBytes []byte                    `json:"-"`
}

type componentDownloadResult struct {
	Schema          int                       `json:"schema"`
	OK              bool                      `json:"ok"`
	Cache           string                    `json:"cache"`
	ComposedPayload string                    `json:"composedPayload,omitempty"`
	Message         string                    `json:"message"`
	Packages        []componentDownloadRecord `json:"packages"`
	ChannelVersions []componentChannelVersion `json:"channelVersions,omitempty"`
	Failures        []string                  `json:"failures,omitempty"`
}

type componentChannelVersion struct {
	Component string `json:"component"`
	Version   string `json:"version"`
	SHA256    string `json:"sha256"`
}

type componentActiveSet struct {
	Schema          int                      `json:"schema"`
	LauncherVersion string                   `json:"launcherVersion"`
	Packages        []componentActivePackage `json:"packages"`
}

type componentActivePackage struct {
	Component string `json:"component"`
	Version   string `json:"version"`
	SHA256    string `json:"sha256"`
}

type componentDownloadRecord struct {
	Component string `json:"component"`
	Version   string `json:"version"`
	Bytes     int64  `json:"bytes"`
	SHA256    string `json:"sha256"`
	Path      string `json:"path"`
	StagePath string `json:"stagePath,omitempty"`
	Cached    bool   `json:"cached"`
	Trusted   bool   `json:"trusted"`
}

var componentVersionPattern = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$`)
var componentSHA256Pattern = regexp.MustCompile(`(?i)^[a-f0-9]{64}$`)
var componentArchiveNamePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,120}\.tar\.gz$`)

const componentSourceRootEnv = "OPTISHADE_COMPONENT_SOURCE_ROOT"

// runComponentStageTest downloads only publisher-signed releases, verifies
// each signed file inventory, and stages the complete package in the local
// component cache. It never writes to a game directory.
func componentTargetsForSelection(requested []string) ([]componentDownloadTarget, error) {
	selected := map[string]bool{"OptiShade.Core": true}
	if len(requested) == 0 {
		selected["OptiShade.Effects"] = true
		selected["OptiShade.OptiMFG"] = true
		selected["OptiShade.Providers.AMD"] = true
		selected["OptiShade.Providers.Intel"] = true
	}
	for _, id := range requested {
		id = strings.TrimSpace(id)
		if id == "" {
			continue
		}
		if id == "OptiShade.Providers" {
			selected["OptiShade.Providers.AMD"] = true
			selected["OptiShade.Providers.Intel"] = true
			continue
		}
		if id != "OptiShade.Core" && id != "OptiShade.Effects" && id != "OptiShade.OptiMFG" && id != "OptiShade.Providers.AMD" && id != "OptiShade.Providers.Intel" {
			return nil, fmt.Errorf("unsupported first-party component selection %q", id)
		}
		selected[id] = true
	}
	targets := make([]componentDownloadTarget, 0, len(selected))
	for _, target := range componentDownloadTargets {
		if selected[target.id] {
			targets = append(targets, target)
		}
	}
	if len(targets) != len(selected) {
		return nil, errors.New("component selection does not map to known stable package channels")
	}
	return targets, nil
}

func componentTargetsForChannelCheck(requested []string) ([]componentDownloadTarget, error) {
	if len(requested) == 0 || len(requested) > len(componentDownloadTargets) {
		return nil, errors.New("select one or more component channels to check")
	}
	selected := map[string]bool{}
	for _, id := range requested {
		id = strings.TrimSpace(id)
		if id == "OptiShade.Providers" {
			selected["OptiShade.Providers.AMD"] = true
			selected["OptiShade.Providers.Intel"] = true
			continue
		}
		if id == "" {
			continue
		}
		found := false
		for _, target := range componentDownloadTargets {
			if id == target.id {
				selected[id] = true
				found = true
				break
			}
		}
		if !found {
			return nil, fmt.Errorf("unsupported component channel %q", id)
		}
	}
	var targets []componentDownloadTarget
	for _, target := range componentDownloadTargets {
		if selected[target.id] {
			targets = append(targets, target)
		}
	}
	return targets, nil
}

// runComponentChannelCheck reads signed manifests only. It never fetches the
// package archive, so Update Manager can find independent release versions
// without downloading or staging every installed component.
func runComponentChannelCheck(resultPath, launcherVersion string, requested ...string) error {
	result := componentDownloadResult{Schema: 1, Message: "Component channel check did not complete."}
	targets, err := componentTargetsForChannelCheck(requested)
	if err != nil {
		return writeComponentDownloadResult(resultPath, result, err)
	}
	if !componentVersionPattern.MatchString(launcherVersion) {
		return writeComponentDownloadResult(resultPath, result, errors.New("manager version is invalid"))
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	client := newComponentDownloadHTTPClient()
	for _, target := range targets {
		manifest, fetchErr := fetchComponentDownloadManifest(ctx, client, target)
		if fetchErr != nil {
			result.Failures = append(result.Failures, fmt.Sprintf("%s: %v", target.label, fetchErr))
			continue
		}
		if !manifest.Trusted || manifest.Release == nil {
			result.Failures = append(result.Failures, fmt.Sprintf("%s is unsigned or download-only", target.label))
			continue
		}
		if rangeErr := validateComponentLauncherRange(manifest.Release, launcherVersion); rangeErr != nil {
			result.Failures = append(result.Failures, fmt.Sprintf("%s: %v", target.label, rangeErr))
			continue
		}
		result.ChannelVersions = append(result.ChannelVersions, componentChannelVersion{Component: target.id, Version: manifest.Version, SHA256: strings.ToLower(manifest.Package.SHA256)})
	}
	result.OK = len(result.Failures) == 0 && len(result.ChannelVersions) == len(targets)
	if result.OK {
		result.Message = "Signed component release versions checked. No package archives were downloaded."
	} else if len(result.ChannelVersions) > 0 {
		result.Message = "Some component channels could not be checked; successful channels remain available. No package archives were downloaded."
	} else {
		result.Message = "No signed component channels could be checked. No package archives were downloaded."
	}
	return writeComponentDownloadResult(resultPath, result, nil)
}

func runComponentStageTest(resultPath, payloadDestination, launcherVersion string, requested ...string) error {
	result := componentDownloadResult{Schema: 1, Message: "Component staging did not complete."}
	targets, err := componentTargetsForSelection(requested)
	if err != nil {
		return writeComponentDownloadResult(resultPath, result, err)
	}
	cache, err := componentStageCacheRoot()
	if err != nil {
		return writeComponentDownloadResult(resultPath, result, err)
	}
	result.Cache = cache
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()
	client := newComponentDownloadHTTPClient()
	for _, target := range targets {
		manifest, err := fetchComponentDownloadManifest(ctx, client, target)
		if err != nil {
			result.Failures = append(result.Failures, fmt.Sprintf("%s: %v", target.label, err))
			continue
		}
		if !manifest.Trusted || manifest.Release == nil || len(manifest.SignedBytes) == 0 {
			result.Failures = append(result.Failures, fmt.Sprintf("%s branch is unsigned or marked download-only", target.label))
			continue
		}
		if err := validateComponentLauncherRange(manifest.Release, launcherVersion); err != nil {
			result.Failures = append(result.Failures, fmt.Sprintf("%s: %v", target.label, err))
			continue
		}
		archive, cached, err := fetchComponentDownloadPackage(ctx, client, target, manifest.Package, cache)
		if err != nil {
			result.Failures = append(result.Failures, fmt.Sprintf("%s: %v", target.label, err))
			continue
		}
		stage, err := stageSignedComponentArchive(manifest.SignedBytes, archive, cache)
		if err != nil {
			result.Failures = append(result.Failures, fmt.Sprintf("%s: %v", target.label, err))
			continue
		}
		result.Packages = append(result.Packages, componentDownloadRecord{
			Component: target.id, Version: manifest.Version, Bytes: manifest.Package.Bytes,
			SHA256: strings.ToLower(manifest.Package.SHA256), Path: archive, StagePath: stage,
			Cached: cached, Trusted: true,
		})
	}
	if payloadDestination != "" {
		if !filepath.IsAbs(resultPath) || !filepath.IsAbs(payloadDestination) || !strings.EqualFold(filepath.Dir(filepath.Clean(resultPath)), filepath.Dir(filepath.Clean(payloadDestination))) || !strings.HasPrefix(filepath.Base(payloadDestination), "PayloadFusion-staged-") {
			result.Failures = append(result.Failures, "composed payload destination must be a unique PayloadFusion-staged-* folder beside the result file")
		} else if len(result.Failures) > 0 || len(result.Packages) != len(targets) {
			result.Failures = append(result.Failures, "the requested component set is incomplete; no installer payload was composed")
		} else {
			roots := make([]string, 0, len(result.Packages))
			coreRoot := ""
			for _, pkg := range result.Packages {
				if pkg.StagePath == "" {
					continue
				}
				roots = append(roots, pkg.StagePath)
				if pkg.Component == "OptiShade.Core" {
					coreRoot = pkg.StagePath
				}
			}
			if coreRoot == "" {
				result.Failures = append(result.Failures, "Core was not staged; no install payload can be composed")
			} else {
				composeErr := composeVerifiedComponentPayload(roots, payloadDestination)
				if composeErr != nil {
					result.Failures = append(result.Failures, "verified packages could not be assembled for the installer: "+composeErr.Error())
				} else {
					if err := saveComponentActiveSet(cache, launcherVersion, result.Packages); err != nil {
						_ = os.RemoveAll(payloadDestination)
						result.Failures = append(result.Failures, "verified packages were staged, but their active selection could not be saved: "+err.Error())
					} else {
						result.ComposedPayload = filepath.Clean(payloadDestination)
					}
				}
			}
		}
	}
	result.OK = len(result.Failures) == 0 && len(result.Packages) == len(targets)
	if result.OK {
		if result.ComposedPayload != "" {
			result.Message = "All publisher-signed component packages passed verification and were assembled as an install-ready local payload. No game files were changed."
		} else {
			result.Message = "All publisher-signed component archives and file inventories passed verification and were staged locally. No game files were changed."
		}
	} else if len(result.Packages) > 0 {
		result.Message = fmt.Sprintf("%d component package(s) staged; %d component(s) could not be staged. No game files were changed. %s", len(result.Packages), len(result.Failures), strings.Join(result.Failures, "; "))
	} else {
		result.Message = "No component packages were staged. " + strings.Join(result.Failures, "; ") + ". No game files were changed."
	}
	return writeComponentDownloadResult(resultPath, result, nil)
}

func saveComponentActiveSet(cache, launcherVersion string, packages []componentDownloadRecord) error {
	if !filepath.IsAbs(cache) || !componentVersionPattern.MatchString(launcherVersion) || len(packages) == 0 || len(packages) > len(componentDownloadTargets) {
		return errors.New("active component selection is incomplete")
	}
	state := componentActiveSet{Schema: 1, LauncherVersion: launcherVersion}
	seen := map[string]bool{}
	for _, pkg := range packages {
		if !pkg.Trusted || !componentVersionPattern.MatchString(pkg.Version) || !componentSHA256Pattern.MatchString(pkg.SHA256) || pkg.Component == "" || seen[pkg.Component] {
			return errors.New("active component selection contains an invalid or duplicate package")
		}
		seen[pkg.Component] = true
		state.Packages = append(state.Packages, componentActivePackage{Component: pkg.Component, Version: pkg.Version, SHA256: strings.ToLower(pkg.SHA256)})
	}
	if !seen["OptiShade.Core"] {
		return errors.New("active component selection must include Core")
	}
	body, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	return writeComponentActiveSetFile(filepath.Join(cache, "active-set.json"), body)
}

func writeComponentActiveSetFile(path string, body []byte) error {
	if !filepath.IsAbs(path) || len(body) == 0 || len(body) > 64<<10 {
		return errors.New("active component selection path or size is invalid")
	}
	parent := filepath.Dir(filepath.Clean(path))
	info, err := os.Lstat(parent)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("active component selection cache is not a normal directory")
	}
	temp, err := os.CreateTemp(parent, ".active-set-*.tmp")
	if err != nil {
		return err
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)
	if err := temp.Chmod(0600); err != nil {
		_ = temp.Close()
		return err
	}
	if _, err := temp.Write(body); err != nil {
		_ = temp.Close()
		return err
	}
	if err := temp.Sync(); err != nil {
		_ = temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	if _, err := os.Lstat(path); err == nil {
		info, statErr := os.Lstat(path)
		if statErr != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
			return errors.New("existing active component selection is not a regular file")
		}
		if err := os.Rename(tempPath, path); err != nil {
			return err
		}
		return nil
	} else if !os.IsNotExist(err) {
		return err
	}
	return os.Rename(tempPath, path)
}

func runComponentComposeCached(resultPath, payloadDestination, launcherVersion string) error {
	return runComponentComposeCachedWithKey(resultPath, payloadDestination, launcherVersion, optiShadeReleasePublicKey, optiShadeReleaseKeyID)
}

func runComponentComposeCachedWithKey(resultPath, payloadDestination, launcherVersion, publicKey, keyID string) error {
	result := componentDownloadResult{Schema: 1, Message: "Cached component selection could not be restored."}
	cache, err := componentStageCacheRoot()
	if err != nil {
		return writeComponentDownloadResult(resultPath, result, err)
	}
	if !componentVersionPattern.MatchString(launcherVersion) || !filepath.IsAbs(resultPath) || !filepath.IsAbs(payloadDestination) || !strings.EqualFold(filepath.Dir(filepath.Clean(resultPath)), filepath.Dir(filepath.Clean(payloadDestination))) || !strings.HasPrefix(filepath.Base(payloadDestination), "PayloadFusion-staged-") {
		return writeComponentDownloadResult(resultPath, result, errors.New("cached component composition paths or manager version are invalid"))
	}
	activePath := filepath.Join(cache, "active-set.json")
	activeInfo, err := os.Lstat(activePath)
	if err != nil || !activeInfo.Mode().IsRegular() || activeInfo.Mode()&os.ModeSymlink != 0 || activeInfo.Size() > 64<<10 {
		return writeComponentDownloadResult(resultPath, result, errors.New("no valid saved signed component selection is available"))
	}
	body, err := os.ReadFile(activePath)
	if err != nil {
		return writeComponentDownloadResult(resultPath, result, err)
	}
	var active componentActiveSet
	decoder := json.NewDecoder(strings.NewReader(string(body)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&active); err != nil || active.Schema != 1 || !componentVersionPattern.MatchString(active.LauncherVersion) || len(active.Packages) == 0 || len(active.Packages) > len(componentDownloadTargets) {
		return writeComponentDownloadResult(resultPath, result, errors.New("saved component selection is malformed or belongs to a different manager version"))
	}
	if err := ensureJSONEOF(decoder); err != nil {
		return writeComponentDownloadResult(resultPath, result, err)
	}
	targetByID := make(map[string]componentDownloadTarget, len(componentDownloadTargets))
	for _, target := range componentDownloadTargets {
		targetByID[target.id] = target
	}
	var roots []string
	seen := map[string]bool{}
	for _, item := range active.Packages {
		target, ok := targetByID[item.Component]
		if !ok || seen[item.Component] || !componentVersionPattern.MatchString(item.Version) || !componentSHA256Pattern.MatchString(item.SHA256) {
			return writeComponentDownloadResult(resultPath, result, errors.New("saved component selection has an invalid package identity"))
		}
		seen[item.Component] = true
		stage := filepath.Join(cache, item.Component, item.Version+"-"+strings.ToLower(item.SHA256))
		manifestPath := filepath.Join(stage, componentStageReleaseManifest)
		manifestInfo, statErr := os.Lstat(manifestPath)
		if statErr != nil || !manifestInfo.Mode().IsRegular() || manifestInfo.Mode()&os.ModeSymlink != 0 || manifestInfo.Size() > 256<<10 {
			return writeComponentDownloadResult(resultPath, result, fmt.Errorf("saved %s package is missing or unsafe; stage the package set again", target.label))
		}
		manifestBytes, readErr := os.ReadFile(manifestPath)
		if readErr != nil {
			return writeComponentDownloadResult(resultPath, result, readErr)
		}
		release, verifyErr := verifySignedComponentReleaseWithKey(manifestBytes, publicKey, keyID)
		if verifyErr != nil || release.ComponentID != item.Component || release.Version != item.Version || !strings.EqualFold(release.Package.SHA256, item.SHA256) {
			return writeComponentDownloadResult(resultPath, result, fmt.Errorf("saved %s package no longer matches its signed identity; stage the package set again", target.label))
		}
		if err := validateComponentLauncherRange(release, launcherVersion); err != nil {
			return writeComponentDownloadResult(resultPath, result, fmt.Errorf("saved %s package is incompatible with this manager: %w", target.label, err))
		}
		manifestHash := sha256.Sum256(manifestBytes)
		if err := verifyStagedComponentDirectory(stage, release, hex.EncodeToString(manifestHash[:]), publicKey, keyID); err != nil {
			return writeComponentDownloadResult(resultPath, result, fmt.Errorf("saved %s package failed revalidation: %w", target.label, err))
		}
		roots = append(roots, stage)
		result.Packages = append(result.Packages, componentDownloadRecord{Component: item.Component, Version: item.Version, Bytes: release.Package.Bytes, SHA256: strings.ToLower(item.SHA256), Path: filepath.Join(cache, item.Component+"-"+filepath.Base(release.Package.Path)), StagePath: stage, Cached: true, Trusted: true})
	}
	if !seen["OptiShade.Core"] {
		return writeComponentDownloadResult(resultPath, result, errors.New("saved component selection is missing its Core package"))
	}
	if err := composeVerifiedComponentPayloadWithKey(roots, payloadDestination, publicKey, keyID); err != nil {
		return writeComponentDownloadResult(resultPath, result, err)
	}
	result.OK = true
	result.Cache = cache
	result.ComposedPayload = filepath.Clean(payloadDestination)
	result.Message = "The saved signed component selection was revalidated and restored from cache. No game files were changed."
	return writeComponentDownloadResult(resultPath, result, nil)
}

func ensureJSONEOF(decoder *json.Decoder) error {
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return errors.New("saved component selection contains trailing data")
	}
	return nil
}

func componentStageCacheRoot() (string, error) {
	root, err := os.UserCacheDir()
	if err != nil || !filepath.IsAbs(root) {
		return "", errors.New("could not resolve an absolute per-user component cache")
	}
	root = filepath.Join(root, "OptiShade", "ComponentPackages")
	if err := os.MkdirAll(root, 0700); err != nil {
		return "", fmt.Errorf("create per-user component cache: %w", err)
	}
	info, err := os.Lstat(root)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return "", errors.New("per-user component cache must be a normal directory")
	}
	resolved, err := filepath.EvalSymlinks(root)
	if err != nil || !strings.EqualFold(filepath.Clean(resolved), filepath.Clean(root)) {
		return "", errors.New("per-user component cache resolves through a link")
	}
	return filepath.Clean(root), nil
}

func newComponentDownloadHTTPClient() *http.Client {
	return &http.Client{
		Timeout: 4 * time.Minute,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			host := strings.ToLower(req.URL.Hostname())
			if len(via) >= 3 || req.URL.Scheme != "https" || (host != "raw.githubusercontent.com" && host != "github.com" && host != "objects.githubusercontent.com" && host != "githubusercontent.com" && !strings.HasSuffix(host, ".githubusercontent.com")) {
				return errors.New("download redirected outside the approved GitHub hosts")
			}
			return nil
		},
	}
}

func fetchComponentDownloadManifest(ctx context.Context, client *http.Client, target componentDownloadTarget) (componentDownloadManifest, error) {
	if root, configured, err := localComponentSourceRoot(); err != nil {
		return componentDownloadManifest{}, err
	} else if configured {
		body, err := readLocalComponentSourceFile(root, target.branch, "channel.json", 256<<10)
		if err != nil {
			return componentDownloadManifest{}, fmt.Errorf("read local signed channel: %w", err)
		}
		return parseSignedComponentDownloadManifest(body, target)
	}
	url := "https://raw.githubusercontent.com/GamingWithGravy/OptiShade/" + target.branch + "/channel.json"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return componentDownloadManifest{}, err
	}
	req.Header.Set("Accept", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return componentDownloadManifest{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		body, readErr := io.ReadAll(io.LimitReader(resp.Body, 256<<10+1))
		if readErr != nil || len(body) > 256<<10 {
			return componentDownloadManifest{}, errors.New("signed channel manifest is too large or unreadable")
		}
		return parseSignedComponentDownloadManifest(body, target)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		return componentDownloadManifest{}, fmt.Errorf("signed channel request returned HTTP %d", resp.StatusCode)
	}
	// Old public branches are explicitly download-only. Preserve the bounded
	// download test while the signed branch manifests are being prepared.
	url = "https://raw.githubusercontent.com/GamingWithGravy/OptiShade/" + target.branch + "/manifest.json"
	req, err = http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return componentDownloadManifest{}, err
	}
	req.Header.Set("Accept", "application/json")
	resp, err = client.Do(req)
	if err != nil {
		return componentDownloadManifest{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return componentDownloadManifest{}, fmt.Errorf("download-only manifest request returned HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10+1))
	if err != nil {
		return componentDownloadManifest{}, err
	}
	if len(body) > 64<<10 {
		return componentDownloadManifest{}, errors.New("manifest exceeds the 64 KiB limit")
	}
	var manifest componentDownloadManifest
	if err := json.Unmarshal(body, &manifest); err != nil {
		return componentDownloadManifest{}, fmt.Errorf("invalid manifest: %w", err)
	}
	if manifest.Schema != 1 || manifest.ComponentID != target.id || manifest.Channel != "download-only" || manifest.Installable == nil || *manifest.Installable {
		return componentDownloadManifest{}, errors.New("branch is not explicitly marked as a schema-1 download-only package; no download was started")
	}
	if !componentVersionPattern.MatchString(manifest.Version) {
		return componentDownloadManifest{}, errors.New("manifest version is invalid")
	}
	if err := validateComponentDownloadArtifact(manifest.Package); err != nil {
		return componentDownloadManifest{}, err
	}
	return manifest, nil
}

func parseSignedComponentDownloadManifest(body []byte, target componentDownloadTarget) (componentDownloadManifest, error) {
	release, err := verifySignedComponentRelease(body)
	if err != nil {
		return componentDownloadManifest{}, err
	}
	if release.Channel != "stable" || release.ComponentID != target.id || release.Package.Branch != target.branch {
		return componentDownloadManifest{}, errors.New("signed channel does not match the requested component branch")
	}
	if release.Package.LFSOID != "" {
		return componentDownloadManifest{}, errors.New("first-party component archives must use regular GitHub branch files; Git LFS is reserved for oversized launcher packages")
	}
	file := filepath.Base(release.Package.Path)
	manifest := componentDownloadManifest{
		Schema: 1, ComponentID: release.ComponentID, Version: release.Version, Channel: release.Channel,
		Installable: func() *bool { v := true; return &v }(), Trusted: true,
		Release: release, SignedBytes: append([]byte(nil), body...),
		Package: componentDownloadArtifact{File: file, Path: release.Package.Path, Bytes: release.Package.Bytes, SHA256: release.Package.SHA256},
	}
	if err := validateComponentDownloadArtifact(manifest.Package); err != nil {
		return componentDownloadManifest{}, err
	}
	return manifest, nil
}

func validateComponentDownloadArtifact(artifact componentDownloadArtifact) error {
	if artifact.File == "" || filepath.Base(artifact.File) != artifact.File || strings.ContainsAny(artifact.File, `/\\:`) || !componentArchiveNamePattern.MatchString(artifact.File) {
		return errors.New("package filename is unsafe")
	}
	if artifact.Bytes < 1 || artifact.Bytes > componentDownloadMaxBytes || !componentSHA256Pattern.MatchString(artifact.SHA256) {
		return errors.New("package size or SHA-256 is invalid")
	}
	return nil
}

func fetchComponentDownloadPackage(ctx context.Context, client *http.Client, target componentDownloadTarget, artifact componentDownloadArtifact, cache string) (string, bool, error) {
	if err := validateComponentDownloadArtifact(artifact); err != nil {
		return "", false, err
	}
	destination := filepath.Join(cache, target.id+"-"+artifact.File)
	if info, err := os.Lstat(destination); err == nil {
		if !info.Mode().IsRegular() {
			return "", false, errors.New("cached package path is not a regular file")
		}
		if info.Size() == artifact.Bytes {
			if digest, hashErr := componentFileSHA256(destination); hashErr == nil && strings.EqualFold(digest, artifact.SHA256) {
				return destination, true, nil
			}
		}
	} else if !os.IsNotExist(err) {
		return "", false, err
	}
	packagePath := artifact.Path
	if packagePath == "" {
		packagePath = "packages/" + artifact.File
	}
	if !safeReleasePath(packagePath) {
		return "", false, errors.New("package path is unsafe")
	}
	if root, configured, err := localComponentSourceRoot(); err != nil {
		return "", false, err
	} else if configured {
		source, err := openLocalComponentSourceFile(root, target.branch, packagePath, artifact.Bytes)
		if err != nil {
			return "", false, fmt.Errorf("open local component package: %w", err)
		}
		defer source.Close()
		return cacheVerifiedComponentReader(source, destination, artifact)
	}
	url := "https://raw.githubusercontent.com/GamingWithGravy/OptiShade/" + target.branch + "/" + packagePath
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", false, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", false, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", false, fmt.Errorf("package download returned HTTP %d", resp.StatusCode)
	}
	return cacheVerifiedComponentReader(resp.Body, destination, artifact)
}

func cacheVerifiedComponentReader(reader io.Reader, destination string, artifact componentDownloadArtifact) (string, bool, error) {
	partial := destination + ".partial"
	file, err := os.OpenFile(partial, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		return "", false, err
	}
	hasher := sha256.New()
	written, copyErr := io.Copy(io.MultiWriter(file, hasher), io.LimitReader(reader, artifact.Bytes+1))
	syncErr := file.Sync()
	closeErr := file.Close()
	if copyErr != nil || syncErr != nil || closeErr != nil {
		_ = os.Remove(partial)
		return "", false, errors.Join(copyErr, syncErr, closeErr)
	}
	if written != artifact.Bytes || !strings.EqualFold(hex.EncodeToString(hasher.Sum(nil)), artifact.SHA256) {
		_ = os.Remove(partial)
		return "", false, errors.New("downloaded package failed its declared size or SHA-256 check")
	}
	if err := os.Rename(partial, destination); err != nil {
		_ = os.Remove(partial)
		return "", false, fmt.Errorf("could not publish verified cache file: %w", err)
	}
	return destination, false, nil
}

func localComponentSourceRoot() (string, bool, error) {
	value := strings.TrimSpace(os.Getenv(componentSourceRootEnv))
	if value == "" {
		return "", false, nil
	}
	if !filepath.IsAbs(value) {
		return "", true, errors.New("local component source root must be an absolute path")
	}
	info, err := os.Lstat(value)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return "", true, errors.New("local component source root must be an existing normal directory")
	}
	resolved, err := filepath.EvalSymlinks(value)
	if err != nil || !strings.EqualFold(filepath.Clean(resolved), filepath.Clean(value)) {
		return "", true, errors.New("local component source root resolves through a link")
	}
	return filepath.Clean(value), true, nil
}

func readLocalComponentSourceFile(root, branch, relative string, maximum int64) ([]byte, error) {
	file, err := openLocalComponentSourceFile(root, branch, relative, maximum)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	body, err := io.ReadAll(io.LimitReader(file, maximum+1))
	if err != nil {
		return nil, err
	}
	if int64(len(body)) > maximum {
		return nil, errors.New("local component source grew beyond its size limit while being read")
	}
	return body, nil
}

func openLocalComponentSourceFile(root, branch, relative string, maximum int64) (*os.File, error) {
	if !safeReleasePath(branch) || !safeReleasePath(relative) || maximum < 1 {
		return nil, errors.New("local component source path or size is invalid")
	}
	path := filepath.Join(root, filepath.FromSlash(branch))
	info, err := os.Lstat(path)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("local component branch must be a normal directory")
	}
	for _, segment := range strings.Split(relative, "/") {
		path = filepath.Join(path, segment)
		info, err = os.Lstat(path)
		if err != nil || info.Mode()&os.ModeSymlink != 0 {
			return nil, errors.New("local component source is missing or traverses a link")
		}
	}
	if !info.Mode().IsRegular() || info.Size() > maximum {
		return nil, errors.New("local component source is not a regular file or exceeds its size limit")
	}
	return os.Open(path)
}

func componentFileSHA256(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	h := sha256.New()
	if _, err := io.Copy(h, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func writeComponentDownloadResult(path string, result componentDownloadResult, failure error) error {
	executable, err := os.Executable()
	if err != nil || !filepath.IsAbs(executable) {
		return errors.New("could not resolve the manager executable for the result folder")
	}
	return writeComponentDownloadResultForExecutable(path, result, failure, executable, os.Getenv("LOCALAPPDATA"))
}

func writeComponentDownloadResultForExecutable(path string, result componentDownloadResult, failure error, executable, localAppData string) error {
	if failure != nil {
		result.OK = false
		result.Message = failure.Error()
	}
	if path == "" || !filepath.IsAbs(path) {
		return errors.New("component download test requires an absolute result path")
	}
	expectedDir, err := componentResultSessionDirectory(executable, localAppData)
	if err != nil || !filepath.IsAbs(expectedDir) {
		return errors.New("could not resolve the manager session folder for the result")
	}
	cleanPath, cleanDir := filepath.Clean(path), filepath.Clean(expectedDir)
	if !strings.EqualFold(filepath.Dir(cleanPath), cleanDir) || !regexp.MustCompile(`(?i)^component-(?:download-test|stage-test|channel-check|compose-cache)-[0-9a-f]{32}\.json$`).MatchString(filepath.Base(cleanPath)) {
		return errors.New("component download result path is outside the app's generated session-file location")
	}
	if err := os.MkdirAll(expectedDir, 0700); err != nil {
		return errors.Join(failure, err)
	}
	resolvedDir, err := filepath.EvalSymlinks(expectedDir)
	if err != nil || !strings.EqualFold(filepath.Clean(resolvedDir), cleanDir) {
		return errors.New("component download result folder resolves through a link")
	}
	data, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return errors.Join(failure, err)
	}
	temp := path + ".partial"
	if err := os.WriteFile(temp, data, 0600); err != nil {
		return errors.Join(failure, err)
	}
	if err := os.Rename(temp, path); err != nil {
		_ = os.Remove(temp)
		return errors.Join(failure, err)
	}
	return failure
}

// componentResultSessionDirectory follows the same install-mode resolution as
// the manager. Installed builds use the per-user OptiShade data folder;
// portable builds keep their result/payload session alongside the portable
// Data folder. Deriving this from the executable and portable marker avoids
// trusting a caller-supplied output root and keeps the worker and UI aligned.
func componentResultSessionDirectory(executable, localAppData string) (string, error) {
	store, _, err := managerStore(executable, localAppData)
	if err != nil {
		return "", err
	}
	return filepath.Join(store, "Sessions"), nil
}
