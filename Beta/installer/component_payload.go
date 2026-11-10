package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

type componentPayloadSource struct {
	root    string
	release *signedComponentRelease
}

type componentPayloadFile struct {
	source      string
	installPath string
	bytes       int64
	digest      string
}

// composeVerifiedComponentPayload assembles already-staged signed packages
// into the PayloadFusion shape expected by the existing transactional
// installer. It is deliberately an explicit-input operation: no package is
// selected from cache by directory order, and the destination must not exist.
func composeVerifiedComponentPayload(stageRoots []string, destination string) error {
	return composeVerifiedComponentPayloadWithKey(stageRoots, destination, optiShadeReleasePublicKey, optiShadeReleaseKeyID)
}

func composeVerifiedComponentPayloadWithKey(stageRoots []string, destination, publicKey, keyID string) error {
	if !filepath.IsAbs(destination) || len(stageRoots) == 0 || len(stageRoots) > 16 {
		return errors.New("component payload composition requires an absolute destination and 1–16 staged packages")
	}
	destination = filepath.Clean(destination)
	if _, err := os.Lstat(destination); err == nil {
		return errors.New("component payload destination already exists; refusing to overwrite it")
	} else if !os.IsNotExist(err) {
		return err
	}

	byID := make(map[string]componentPayloadSource, len(stageRoots))
	contracts := map[string]string{}
	for _, root := range stageRoots {
		if !filepath.IsAbs(root) {
			return errors.New("staged component paths must be absolute")
		}
		root = filepath.Clean(root)
		manifestBytes, err := os.ReadFile(filepath.Join(root, componentStageReleaseManifest))
		if err != nil {
			return fmt.Errorf("read staged release manifest: %w", err)
		}
		release, err := verifySignedComponentReleaseWithKey(manifestBytes, publicKey, keyID)
		if err != nil {
			return fmt.Errorf("staged component publisher verification failed: %w", err)
		}
		manifestHash := sha256.Sum256(manifestBytes)
		if err := verifyStagedComponentDirectory(root, release, hex.EncodeToString(manifestHash[:]), publicKey, keyID); err != nil {
			return fmt.Errorf("staged component failed revalidation: %w", err)
		}
		if _, duplicate := byID[release.ComponentID]; duplicate {
			return fmt.Errorf("multiple staged versions selected for %s", release.ComponentID)
		}
		byID[release.ComponentID] = componentPayloadSource{root: root, release: release}
		for name, value := range release.Contracts {
			if prior, exists := contracts[name]; exists && prior != value {
				return fmt.Errorf("component compatibility contract %q conflicts (%q vs %q)", name, prior, value)
			}
			contracts[name] = value
		}
	}
	if _, ok := byID["OptiShade.Core"]; !ok {
		return errors.New("a signed OptiShade.Core package is required to compose an installable payload")
	}

	// Require every declared dependency to be in this explicit package set and
	// meet its minimum semantic version. The current release schema does not
	// define optional dependencies, so a missing dependency fails closed.
	for id, source := range byID {
		for _, dependency := range source.release.Dependencies {
			required, ok := byID[dependency.ComponentID]
			if !ok || compareComponentVersions(required.release.Version, dependency.MinimumVersion) < 0 {
				return fmt.Errorf("%s requires %s >= %s in this staged set", id, dependency.ComponentID, dependency.MinimumVersion)
			}
		}
	}

	files := map[string]componentPayloadFile{}
	for _, source := range byID {
		for _, entry := range source.release.Files {
			key := strings.ToLower(filepath.FromSlash(entry.InstallPath))
			stagedPath := filepath.Join(source.root, filepath.FromSlash(entry.InstallPath))
			if previous, collision := files[key]; collision {
				if previous.bytes != entry.Bytes || !strings.EqualFold(previous.digest, entry.SHA256) {
					return fmt.Errorf("selected components contain conflicting bytes for %s", entry.InstallPath)
				}
				continue // Identical shared notices/catalogue data are safe to coalesce.
			}
			files[key] = componentPayloadFile{source: stagedPath, installPath: filepath.FromSlash(entry.InstallPath), bytes: entry.Bytes, digest: strings.ToLower(entry.SHA256)}
		}
	}
	core := byID["OptiShade.Core"]
	for _, required := range []string{"files.json", "OptiShadeData/BuildIdentity.json"} {
		found := false
		for _, entry := range core.release.Files {
			if strings.EqualFold(filepath.FromSlash(entry.InstallPath), filepath.FromSlash(required)) {
				found = true
				break
			}
		}
		if !found {
			return fmt.Errorf("Core release does not declare required payload metadata %s", required)
		}
	}

	parent := filepath.Dir(destination)
	parentInfo, err := os.Lstat(parent)
	if err != nil || !parentInfo.IsDir() || parentInfo.Mode()&os.ModeSymlink != 0 {
		return errors.New("payload composition parent must be an existing real directory")
	}
	temp, err := os.MkdirTemp(parent, ".payload-assemble-")
	if err != nil {
		return err
	}
	committed := false
	defer func() {
		if !committed {
			_ = os.RemoveAll(temp)
		}
	}()
	keys := make([]string, 0, len(files))
	for key := range files {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		entry := files[key]
		out := filepath.Join(temp, entry.installPath)
		if !strings.HasPrefix(strings.ToLower(filepath.Clean(out)), strings.ToLower(filepath.Clean(temp))+string(os.PathSeparator)) {
			return fmt.Errorf("composed payload path escaped destination: %s", entry.installPath)
		}
		if err := os.MkdirAll(filepath.Dir(out), 0700); err != nil {
			return err
		}
		in, err := os.Open(entry.source)
		if err != nil {
			return err
		}
		f, err := os.OpenFile(out, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if err != nil {
			in.Close()
			return err
		}
		h := sha256.New()
		written, copyErr := io.Copy(io.MultiWriter(f, h), io.LimitReader(in, entry.bytes+1))
		closeInErr := in.Close()
		closeOutErr := f.Close()
		if err := errors.Join(copyErr, closeInErr, closeOutErr); err != nil {
			return err
		}
		if written != entry.bytes || !strings.EqualFold(hex.EncodeToString(h.Sum(nil)), entry.digest) {
			return fmt.Errorf("composed component failed post-copy verification: %s", entry.installPath)
		}
	}
	if err := mergeComposedFilesIntoCoreCatalogue(temp, files); err != nil {
		return err
	}
	if err := validateComposedCoreMetadata(temp); err != nil {
		return err
	}
	if err := os.Rename(temp, destination); err != nil {
		return fmt.Errorf("promote composed payload atomically: %w", err)
	}
	committed = true
	return nil
}

func mergeComposedFilesIntoCoreCatalogue(payloadRoot string, payloadFiles map[string]componentPayloadFile) error {
	catalogPath := filepath.Join(payloadRoot, "files.json")
	catalogBytes, err := os.ReadFile(catalogPath)
	if err != nil {
		return fmt.Errorf("read composed Core catalogue for component merge: %w", err)
	}
	var catalog []struct {
		Path string `json:"Path"`
		Hash string `json:"Hash"`
	}
	if err := json.Unmarshal(catalogBytes, &catalog); err != nil || len(catalog) == 0 || len(catalog) > 10000 {
		return errors.New("composed Core catalogue is invalid or empty")
	}
	byPath := make(map[string]int, len(catalog)+len(payloadFiles))
	for i, entry := range catalog {
		if !safeReleasePath(strings.ReplaceAll(entry.Path, `\`, "/")) || !releaseDigestPattern.MatchString(entry.Hash) {
			return errors.New("composed Core catalogue contains an invalid path or hash")
		}
		key := strings.ToLower(strings.ReplaceAll(entry.Path, `\`, "/"))
		if _, duplicate := byPath[key]; duplicate {
			return fmt.Errorf("composed Core catalogue contains duplicate path %s", entry.Path)
		}
		byPath[key] = i
	}
	fileKeys := make([]string, 0, len(payloadFiles))
	for key := range payloadFiles {
		fileKeys = append(fileKeys, key)
	}
	sort.Strings(fileKeys)
	for _, key := range fileKeys {
		file := payloadFiles[key]
		path := filepath.ToSlash(file.installPath)
		if strings.EqualFold(path, "files.json") {
			continue // Catalogue cannot hash itself.
		}
		key := strings.ToLower(path)
		if index, exists := byPath[key]; exists {
			if !strings.EqualFold(catalog[index].Hash, file.digest) {
				return fmt.Errorf("selected component conflicts with the Core catalogue at %s", path)
			}
			continue
		}
		byPath[key] = len(catalog)
		catalog = append(catalog, struct {
			Path string `json:"Path"`
			Hash string `json:"Hash"`
		}{Path: path, Hash: strings.ToLower(file.digest)})
		if len(catalog) > 10000 {
			return errors.New("merged Core catalogue exceeds the entry limit")
		}
	}
	merged, err := json.MarshalIndent(catalog, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(catalogPath, merged, 0600); err != nil {
		return fmt.Errorf("write component-merged Core catalogue: %w", err)
	}
	return nil
}

func validateComposedCoreMetadata(payloadRoot string) error {
	catalogPath := filepath.Join(payloadRoot, "files.json")
	identityPath := filepath.Join(payloadRoot, "OptiShadeData", "BuildIdentity.json")
	catalogBytes, err := os.ReadFile(catalogPath)
	if err != nil {
		return fmt.Errorf("read composed Core catalogue: %w", err)
	}
	var catalog []struct {
		Path string `json:"Path"`
		Hash string `json:"Hash"`
	}
	if err := json.Unmarshal(catalogBytes, &catalog); err != nil || len(catalog) == 0 || len(catalog) > 10000 {
		return errors.New("composed Core catalogue is invalid or empty")
	}
	seen := map[string]struct {
		path string
		hash string
	}{}
	for _, entry := range catalog {
		if !safeReleasePath(strings.ReplaceAll(entry.Path, `\`, "/")) || len(entry.Hash) != 64 {
			return errors.New("composed Core catalogue contains an invalid path or hash")
		}
		key := strings.ToLower(strings.ReplaceAll(entry.Path, `\`, "/"))
		if _, duplicate := seen[key]; duplicate {
			return fmt.Errorf("composed Core catalogue contains duplicate path %s", entry.Path)
		}
		seen[key] = struct {
			path string
			hash string
		}{path: filepath.FromSlash(strings.ReplaceAll(entry.Path, `\`, "/")), hash: strings.ToLower(entry.Hash)}
	}
	identityBytes, err := os.ReadFile(identityPath)
	if err != nil {
		return fmt.Errorf("read composed Core build identity: %w", err)
	}
	var identity map[string]any
	if err := json.Unmarshal(identityBytes, &identity); err != nil || len(identity) == 0 {
		return errors.New("composed Core build identity is invalid or empty")
	}
	// The signed component inventory authenticates downloaded bytes, while
	// files.json is the installer's own payload catalogue. Require both layers
	// to agree for every payload file present in this composition. A partial
	// package set may intentionally omit optional catalogue entries, so absence
	// alone is not an error here.
	return filepath.WalkDir(payloadRoot, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if path == payloadRoot || entry.IsDir() {
			return nil
		}
		info, err := entry.Info()
		if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("composed payload contains a non-regular file: %s", path)
		}
		rel, err := filepath.Rel(payloadRoot, path)
		if err != nil {
			return err
		}
		if strings.EqualFold(filepath.ToSlash(rel), "files.json") {
			return nil // Catalogue cannot hash itself.
		}
		key := strings.ToLower(filepath.ToSlash(rel))
		catalogEntry, ok := seen[key]
		if !ok {
			return fmt.Errorf("composed payload file is absent from Core catalogue: %s", filepath.ToSlash(rel))
		}
		digest, err := componentFileSHA256(path)
		if err != nil {
			return err
		}
		if !strings.EqualFold(digest, catalogEntry.hash) {
			return fmt.Errorf("composed payload file does not match Core catalogue hash: %s", catalogEntry.path)
		}
		return nil
	})
}

func compareComponentVersions(left, right string) int {
	// Inputs are validated against releaseVersionPattern before use. Compare
	// numeric core versions and then SemVer prerelease identifiers.
	parse := func(value string) ([3]uint64, []string) {
		var numbers [3]uint64
		parts := strings.SplitN(value, "-", 2)
		core := strings.Split(parts[0], ".")
		for i := range numbers {
			numbers[i], _ = strconv.ParseUint(core[i], 10, 64)
		}
		var pre []string
		if len(parts) == 2 {
			pre = strings.Split(parts[1], ".")
		}
		return numbers, pre
	}
	a, apre := parse(left)
	b, bpre := parse(right)
	for i := range a {
		if a[i] < b[i] {
			return -1
		}
		if a[i] > b[i] {
			return 1
		}
	}
	if len(apre) == 0 && len(bpre) == 0 {
		return 0
	}
	if len(apre) == 0 {
		return 1
	}
	if len(bpre) == 0 {
		return -1
	}
	for i := 0; i < len(apre) && i < len(bpre); i++ {
		an, aErr := strconv.ParseUint(apre[i], 10, 64)
		bn, bErr := strconv.ParseUint(bpre[i], 10, 64)
		aNumeric, bNumeric := aErr == nil, bErr == nil
		if aNumeric && bNumeric {
			if an < bn {
				return -1
			}
			if an > bn {
				return 1
			}
			continue
		}
		if aNumeric != bNumeric {
			if aNumeric {
				return -1
			}
			return 1
		}
		if cmp := strings.Compare(apre[i], bpre[i]); cmp != 0 {
			return cmp
		}
	}
	if len(apre) < len(bpre) {
		return -1
	}
	if len(apre) > len(bpre) {
		return 1
	}
	return 0
}
