// Copyright (c) 2026 GamingWithGravy. All rights reserved.
// Stages publisher-signed component archives into an isolated per-user cache.
package main

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const componentStageMaxExpandedBytes int64 = 512 << 20

type componentStageFile struct {
	Path   string `json:"path"`
	Bytes  int64  `json:"bytes"`
	SHA256 string `json:"sha256"`
}

type componentStageReceipt struct {
	Schema         int                  `json:"schema"`
	ComponentID    string               `json:"componentId"`
	Version        string               `json:"version"`
	Branch         string               `json:"branch"`
	PackageSHA256  string               `json:"packageSha256"`
	ManifestSHA256 string               `json:"manifestSha256"`
	StagedUTC      string               `json:"stagedUtc"`
	Files          []componentStageFile `json:"files"`
}

const componentStageReleaseManifest = "release-manifest.json"

type verifiedComponentArchiveFile struct {
	install string
	bytes   int64
	digest  string
}

// stageSignedComponentArchive verifies the signed release manifest itself and
// independently verifies the archive,
// rejects links/special entries/unlisted files, hashes every extracted file,
// and promotes a complete temporary directory atomically.
func stageSignedComponentArchive(manifestBytes []byte, archivePath, cacheRoot string) (string, error) {
	return stageSignedComponentArchiveWithKey(manifestBytes, archivePath, cacheRoot, optiShadeReleasePublicKey, optiShadeReleaseKeyID)
}

func stageSignedComponentArchiveWithKey(manifestBytes []byte, archivePath, cacheRoot, publicKey, keyID string) (string, error) {
	release, err := verifySignedComponentReleaseWithKey(manifestBytes, publicKey, keyID)
	if err != nil {
		return "", fmt.Errorf("component release signature check failed: %w", err)
	}
	if !filepath.IsAbs(archivePath) || !filepath.IsAbs(cacheRoot) {
		return "", errors.New("component archive and cache paths must be absolute")
	}
	archiveInfo, err := os.Lstat(archivePath)
	if err != nil || !archiveInfo.Mode().IsRegular() || archiveInfo.Size() != release.Package.Bytes {
		return "", errors.New("component archive is missing, not a regular file, or has the wrong size")
	}
	archiveHash, err := componentFileSHA256(archivePath)
	if err != nil || !strings.EqualFold(archiveHash, release.Package.SHA256) {
		return "", errors.New("component archive failed its signed SHA-256 check")
	}
	if len(manifestBytes) == 0 || len(manifestBytes) > 256<<10 {
		return "", errors.New("signed component manifest is empty or too large")
	}
	manifestHash := sha256.Sum256(manifestBytes)

	cacheRoot = filepath.Clean(cacheRoot)
	if err := os.MkdirAll(cacheRoot, 0700); err != nil {
		return "", fmt.Errorf("create component cache: %w", err)
	}
	rootInfo, err := os.Lstat(cacheRoot)
	if err != nil || !rootInfo.IsDir() || rootInfo.Mode()&os.ModeSymlink != 0 {
		return "", errors.New("component cache root is not a normal directory")
	}
	componentRoot := filepath.Join(cacheRoot, release.ComponentID)
	if err := os.MkdirAll(componentRoot, 0700); err != nil {
		return "", fmt.Errorf("create component cache namespace: %w", err)
	}
	componentInfo, err := os.Lstat(componentRoot)
	if err != nil || !componentInfo.IsDir() || componentInfo.Mode()&os.ModeSymlink != 0 {
		return "", errors.New("component cache namespace is not a normal directory")
	}
	destination := filepath.Join(componentRoot, release.Version+"-"+strings.ToLower(archiveHash))
	if _, err := os.Lstat(destination); err == nil {
		if err := verifyStagedComponentDirectory(destination, release, hex.EncodeToString(manifestHash[:]), publicKey, keyID); err != nil {
			return "", fmt.Errorf("existing staged component is invalid: %w", err)
		}
		return destination, nil
	} else if !os.IsNotExist(err) {
		return "", err
	}
	temp, err := os.MkdirTemp(componentRoot, ".stage-")
	if err != nil {
		return "", fmt.Errorf("create temporary component stage: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = os.RemoveAll(temp)
		}
	}()

	expected := make(map[string]verifiedComponentArchiveFile, len(release.Files))
	var expanded int64
	receiptFiles := make([]componentStageFile, 0, len(release.Files))
	for _, f := range release.Files {
		if !safeReleasePath(f.PackagePath) || !safeReleasePath(f.InstallPath) || f.Bytes < 0 || f.Bytes > componentStageMaxExpandedBytes {
			return "", errors.New("signed component file inventory contains an unsafe path or size")
		}
		if strings.EqualFold(f.InstallPath, "stage-receipt.json") {
			return "", errors.New("signed component inventory uses a reserved staging receipt path")
		}
		expected[f.PackagePath] = verifiedComponentArchiveFile{f.InstallPath, f.Bytes, strings.ToLower(f.SHA256)}
		expanded += f.Bytes
		if expanded > componentStageMaxExpandedBytes {
			return "", errors.New("component expanded size exceeds the staging limit")
		}
		receiptFiles = append(receiptFiles, componentStageFile{Path: f.InstallPath, Bytes: f.Bytes, SHA256: strings.ToLower(f.SHA256)})
	}

	if err := extractVerifiedComponentTarGz(archivePath, temp, expected, componentStageMaxExpandedBytes); err != nil {
		return "", err
	}
	receipt := componentStageReceipt{
		Schema: 1, ComponentID: release.ComponentID, Version: release.Version, Branch: release.Package.Branch,
		PackageSHA256: strings.ToLower(archiveHash), ManifestSHA256: hex.EncodeToString(manifestHash[:]),
		StagedUTC: time.Now().UTC().Format(time.RFC3339Nano), Files: receiptFiles,
	}
	// Keep the publisher-signed contract beside the staged bytes. The cache
	// must remain independently verifiable when it is later composed for the
	// installer; a receipt digest alone is not publisher authentication.
	if err := os.WriteFile(filepath.Join(temp, componentStageReleaseManifest), manifestBytes, 0600); err != nil {
		return "", fmt.Errorf("write signed component manifest to stage: %w", err)
	}
	receiptPath := filepath.Join(temp, "stage-receipt.json")
	data, err := json.MarshalIndent(receipt, "", "  ")
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(receiptPath, data, 0600); err != nil {
		return "", fmt.Errorf("write component stage receipt: %w", err)
	}
	if err := verifyStagedComponentDirectory(temp, release, hex.EncodeToString(manifestHash[:]), publicKey, keyID); err != nil {
		return "", fmt.Errorf("revalidate complete component stage: %w", err)
	}
	if err := os.Rename(temp, destination); err != nil {
		return "", fmt.Errorf("promote complete component stage: %w", err)
	}
	committed = true
	return destination, nil
}

func extractVerifiedComponentTarGz(archivePath, destination string, expected map[string]verifiedComponentArchiveFile, maximum int64) error {
	archive, err := os.Open(archivePath)
	if err != nil {
		return err
	}
	defer archive.Close()
	gz, err := gzip.NewReader(archive)
	if err != nil {
		return fmt.Errorf("open component gzip archive: %w", err)
	}
	defer gz.Close()
	tr := tar.NewReader(gz)
	seen := make(map[string]bool, len(expected))
	seenMetadata := make(map[string]bool, 2)
	var total int64
	for {
		header, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("read component archive: %w", err)
		}
		name, err := normalizeComponentArchivePath(header.Name)
		if err != nil {
			return fmt.Errorf("component archive contains unsafe path %q", header.Name)
		}
		if header.Typeflag == tar.TypeDir {
			if name == "" { // Common tar root entry: ./
				continue
			}
			allowedDir := false
			for file := range expected {
				if strings.HasPrefix(file, name+"/") {
					allowedDir = true
					break
				}
			}
			if !allowedDir {
				return fmt.Errorf("component archive contains an unlisted directory %q", name)
			}
			continue
		}
		if header.Typeflag != tar.TypeReg && header.Typeflag != tar.TypeRegA {
			return fmt.Errorf("component archive contains a link or special file %q", name)
		}
		entry, ok := expected[name]
		if !ok && (name == "component-package.json" || name == "files.json") {
			// Existing component archives include local catalogue metadata. The
			// signed outer archive digest authenticates it; it is not a game file.
			if header.Size < 0 || header.Size > 1<<20 {
				return fmt.Errorf("component archive metadata is over the size limit: %q", name)
			}
			if seenMetadata[name] {
				return fmt.Errorf("component archive contains duplicate package metadata %q", name)
			}
			if _, err := io.CopyN(io.Discard, tr, header.Size); err != nil {
				return fmt.Errorf("read package metadata %q: %w", name, err)
			}
			seenMetadata[name] = true
			continue
		}
		if !ok || seen[name] {
			return fmt.Errorf("component archive contains an unlisted or duplicate file %q", name)
		}
		if header.Size != entry.bytes || header.Size < 0 {
			return fmt.Errorf("component archive file size does not match the signed inventory: %q", name)
		}
		total += header.Size
		if total > maximum {
			return errors.New("component archive exceeds the expanded size limit")
		}
		outPath := filepath.Join(destination, filepath.FromSlash(entry.install))
		if !strings.HasPrefix(strings.ToLower(filepath.Clean(outPath)), strings.ToLower(filepath.Clean(destination))+string(os.PathSeparator)) {
			return fmt.Errorf("signed install path escaped the stage root: %q", entry.install)
		}
		if err := os.MkdirAll(filepath.Dir(outPath), 0700); err != nil {
			return err
		}
		out, err := os.OpenFile(outPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if err != nil {
			return err
		}
		h := sha256.New()
		written, copyErr := io.Copy(io.MultiWriter(out, h), io.LimitReader(tr, entry.bytes+1))
		closeErr := out.Close()
		if copyErr != nil || closeErr != nil {
			return errors.Join(copyErr, closeErr)
		}
		if written != entry.bytes || !strings.EqualFold(hex.EncodeToString(h.Sum(nil)), entry.digest) {
			return fmt.Errorf("component archive file failed signed size/hash verification: %q", name)
		}
		seen[name] = true
	}
	if len(seen) != len(expected) {
		for name := range expected {
			if !seen[name] {
				return fmt.Errorf("component archive omitted signed file %q", name)
			}
		}
	}
	return nil
}

func normalizeComponentArchivePath(value string) (string, error) {
	if value == "." || value == "./" {
		return "", nil
	}
	if strings.ContainsAny(value, `\:`) || strings.HasPrefix(value, "/") {
		return "", errors.New("absolute or platform-specific path")
	}
	for strings.HasPrefix(value, "./") {
		value = strings.TrimPrefix(value, "./")
	}
	value = strings.TrimSuffix(value, "/")
	if value == "" {
		return "", nil
	}
	if !safeReleasePath(value) {
		return "", errors.New("non-canonical path")
	}
	return value, nil
}

func verifyStagedComponentDirectory(root string, release *signedComponentRelease, manifestHash, publicKey, keyID string) error {
	info, err := os.Lstat(root)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("staged component root is not a normal directory")
	}
	receiptPath := filepath.Join(root, "stage-receipt.json")
	data, err := os.ReadFile(receiptPath)
	if err != nil {
		return err
	}
	var receipt componentStageReceipt
	if err := json.Unmarshal(data, &receipt); err != nil {
		return err
	}
	if receipt.Schema != 1 || receipt.ComponentID != release.ComponentID || receipt.Version != release.Version || receipt.Branch != release.Package.Branch || !strings.EqualFold(receipt.PackageSHA256, release.Package.SHA256) || !strings.EqualFold(receipt.ManifestSHA256, manifestHash) || len(receipt.Files) != len(release.Files) {
		return errors.New("staged component receipt identity does not match the signed release")
	}
	allowed := map[string]bool{"stage-receipt.json": true, componentStageReleaseManifest: true}
	manifestData, err := os.ReadFile(filepath.Join(root, componentStageReleaseManifest))
	if err != nil || len(manifestData) == 0 {
		return errors.New("staged signed component manifest is missing")
	}
	verifiedManifest, err := verifySignedComponentReleaseWithKey(manifestData, publicKey, keyID)
	if err != nil {
		return fmt.Errorf("staged component manifest signature failed: %w", err)
	}
	manifestDigest := sha256.Sum256(manifestData)
	if verifiedManifest.ComponentID != release.ComponentID || verifiedManifest.Version != release.Version || !strings.EqualFold(hex.EncodeToString(manifestDigest[:]), manifestHash) {
		return errors.New("staged signed component manifest identity or digest does not match")
	}
	receiptByPath := make(map[string]componentStageFile, len(receipt.Files))
	for _, f := range receipt.Files {
		receiptByPath[strings.ToLower(filepath.ToSlash(f.Path))] = f
	}
	for _, f := range release.Files {
		allowed[strings.ToLower(filepath.FromSlash(f.InstallPath))] = true
		stagedReceiptFile, ok := receiptByPath[strings.ToLower(filepath.ToSlash(f.InstallPath))]
		if !ok || stagedReceiptFile.Bytes != f.Bytes || !strings.EqualFold(stagedReceiptFile.SHA256, f.SHA256) {
			return fmt.Errorf("staged receipt file identity does not match signed release: %s", f.InstallPath)
		}
		path := filepath.Join(root, filepath.FromSlash(f.InstallPath))
		if !strings.HasPrefix(strings.ToLower(filepath.Clean(path)), strings.ToLower(filepath.Clean(root))+string(os.PathSeparator)) {
			return errors.New("staged file path escaped its root")
		}
		fileInfo, err := os.Lstat(path)
		if err != nil || !fileInfo.Mode().IsRegular() || fileInfo.Mode()&os.ModeSymlink != 0 || fileInfo.Size() != f.Bytes {
			return fmt.Errorf("staged file is missing or has an invalid type/size: %s", f.InstallPath)
		}
		digest, err := componentFileSHA256(path)
		if err != nil || !strings.EqualFold(digest, f.SHA256) {
			return fmt.Errorf("staged file hash does not match signed release: %s", f.InstallPath)
		}
	}
	if err := filepath.WalkDir(root, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if path == root {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("staged component contains a reparse/symlink path: %s", path)
		}
		if !entry.IsDir() {
			rel, err := filepath.Rel(root, path)
			if err != nil {
				return err
			}
			if !allowed[strings.ToLower(filepath.Clean(rel))] {
				return fmt.Errorf("staged component contains an undeclared file: %s", rel)
			}
		}
		return nil
	}); err != nil {
		return err
	}
	return nil
}
