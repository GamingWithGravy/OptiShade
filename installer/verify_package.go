package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"
)

type payloadEntry struct{ Path, Hash string }

func privatePackagePath(name string) bool {
	lower := strings.ToLower(strings.ReplaceAll(name, "\\", "/"))
	for _, marker := range []string{"fusionnr", "fusion_nr_engine", "codex_", "codex-", "prompt", "diagnostics-", "private", "handoff", "test-results", "test-notes", ".git/", ".research/"} {
		if strings.Contains(lower, marker) {
			return true
		}
	}
	for _, suffix := range []string{".dmp", ".log", ".zip", ".safetensors", ".onnx", ".pt", ".pdb"} {
		if strings.HasSuffix(lower, suffix) {
			return true
		}
	}
	return false
}

// Verify exactly the bytes embedded in the final EXE. This path never starts the
// setup helper, reads installed-game state, writes update preferences or installs.
func verifyPackageFiles(source fs.FS) (map[string]string, error) {
	data, err := fs.ReadFile(source, "PayloadFusion/files.json")
	if err != nil {
		return nil, err
	}
	var entries []payloadEntry
	if err = json.Unmarshal([]byte(strings.TrimPrefix(string(data), "\ufeff")), &entries); err != nil {
		return nil, err
	}
	if len(entries) == 0 {
		return nil, fmt.Errorf("empty payload manifest")
	}
	expected := make(map[string]string)
	for _, entry := range entries {
		relative := strings.ReplaceAll(entry.Path, "\\", "/")
		if !fs.ValidPath(relative) || strings.Contains(relative, ":") {
			return nil, fmt.Errorf("invalid payload path: %s", relative)
		}
		name := "PayloadFusion/" + relative
		if _, exists := expected[strings.ToLower(name)]; exists {
			return nil, fmt.Errorf("duplicate payload path: %s", name)
		}
		bytes, e := fs.ReadFile(source, name)
		if e != nil {
			return nil, e
		}
		hash := fmt.Sprintf("%x", sha256.Sum256(bytes))
		if !strings.EqualFold(hash, entry.Hash) {
			return nil, fmt.Errorf("payload hash mismatch: %s", name)
		}
		expected[strings.ToLower(name)] = hash
	}
	err = fs.WalkDir(source, ".", func(name string, entry fs.DirEntry, e error) error {
		if e != nil {
			return e
		}
		if entry.IsDir() {
			return nil
		}
		if !fs.ValidPath(name) || privatePackagePath(name) {
			return fmt.Errorf("private or invalid package path: %s", name)
		}
		if strings.HasPrefix(name, "PayloadFusion/") && name != "PayloadFusion/files.json" {
			if _, ok := expected[strings.ToLower(name)]; !ok {
				return fmt.Errorf("unmanifested payload file: %s", name)
			}
		}
		return nil
	})
	return expected, err
}

func extractVerifiedPackage(parent string) error {
	hashes, err := verifyPackageFiles(bundle)
	if err != nil {
		return err
	}
	info, err := os.Lstat(parent)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("verification parent must be a real directory")
	}
	dir, err := os.MkdirTemp(parent, "OptiShade-package-check-")
	if err != nil {
		return err
	}
	err = fs.WalkDir(bundle, ".", func(name string, entry fs.DirEntry, e error) error {
		if e != nil {
			return e
		}
		if name == "." {
			return nil
		}
		dest := filepath.Join(dir, filepath.FromSlash(name))
		if entry.IsDir() {
			return os.MkdirAll(dest, 0700)
		}
		bytes, e := bundle.ReadFile(name)
		if e != nil {
			return e
		}
		return os.WriteFile(dest, bytes, 0600)
	})
	if err != nil {
		return err
	}
	// Re-read fresh disk bytes rather than trusting the completed extraction loop.
	if err = comparePackageInventories(bundle, os.DirFS(dir)); err != nil {
		return err
	}
	diskHashes, err := verifyPackageFiles(os.DirFS(dir))
	if err != nil {
		return err
	}
	identity, err := os.ReadFile(filepath.Join(dir, "PayloadFusion", "OptiShadeData", "BuildIdentity.json"))
	if err != nil {
		return err
	}
	var build map[string]interface{}
	if err = json.Unmarshal([]byte(strings.TrimPrefix(string(identity), "\ufeff")), &build); err != nil {
		return err
	}
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	bytes, err := os.ReadFile(executable)
	if err != nil {
		return err
	}
	report := map[string]interface{}{"Passed": true, "Executable": path.Base(filepath.ToSlash(executable)),
		"ExecutableSHA256": fmt.Sprintf("%x", sha256.Sum256(bytes)), "PayloadCount": len(hashes), "Build": build,
		"WinmmSHA256": diskHashes["payloadfusion/winmm.dll"], "Extraction": dir}
	encoded, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, "Package-verification.json"), encoded, 0600)
}

// The manifest covers game payload files, but the launcher also embeds setup
// helpers and scripts. Verify that the fresh extraction contains every one of
// those bytes too, and no unexpected files, before claiming package integrity.
func packageInventory(source fs.FS) (map[string]string, error) {
	inventory := make(map[string]string)
	err := fs.WalkDir(source, ".", func(name string, entry fs.DirEntry, e error) error {
		if e != nil {
			return e
		}
		if entry.Type()&fs.ModeSymlink != 0 {
			return fmt.Errorf("linked package path: %s", name)
		}
		if entry.IsDir() {
			return nil
		}
		if !fs.ValidPath(name) || privatePackagePath(name) {
			return fmt.Errorf("private or invalid package path: %s", name)
		}
		body, e := fs.ReadFile(source, name)
		if e != nil {
			return e
		}
		inventory[name] = fmt.Sprintf("%x", sha256.Sum256(body))
		return nil
	})
	return inventory, err
}

func comparePackageInventories(expected, extracted fs.FS) error {
	source, err := packageInventory(expected)
	if err != nil {
		return err
	}
	disk, err := packageInventory(extracted)
	if err != nil {
		return err
	}
	if len(source) != len(disk) {
		return fmt.Errorf("extracted package inventory mismatch: expected %d files, found %d", len(source), len(disk))
	}
	for name, hash := range source {
		if disk[name] != hash {
			return fmt.Errorf("extracted package file missing or changed: %s", name)
		}
	}
	return nil
}
