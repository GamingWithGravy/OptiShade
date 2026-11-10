package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestChooseExtractionRootFallsBackWhenPrimaryLacksSpace(t *testing.T) {
	base := t.TempDir()
	primary := filepath.Join(base, "primary")
	alternate := filepath.Join(base, "alternate")
	probed := []string{}
	space := func(root string) (uint64, error) {
		probed = append(probed, root)
		if root == primary {
			return 49, nil
		}
		return 50, nil
	}

	root, err := chooseExtractionRootWithSpace(primary, alternate, 50, space)
	if err != nil {
		t.Fatal(err)
	}
	if root != alternate {
		t.Fatalf("expected fallback root %q, got %q", alternate, root)
	}
	if len(probed) != 2 || probed[0] != primary || probed[1] != alternate {
		t.Fatalf("unexpected probe order: %#v", probed)
	}
	entries, err := os.ReadDir(alternate)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("write-check files should be removed, found %#v", entries)
	}
}

func TestChooseExtractionRootPrefersPrimaryWhenItHasSpace(t *testing.T) {
	base := t.TempDir()
	primary := filepath.Join(base, "primary")
	alternate := filepath.Join(base, "alternate")
	probedAlternate := false
	space := func(root string) (uint64, error) {
		if root == alternate {
			probedAlternate = true
		}
		return 50, nil
	}

	root, err := chooseExtractionRootWithSpace(primary, alternate, 50, space)
	if err != nil {
		t.Fatal(err)
	}
	if root != primary || probedAlternate {
		t.Fatalf("expected primary root %q without probing alternate, got %q (alternate probed: %v)", primary, root, probedAlternate)
	}
}

func TestChooseExtractionRootRejectsWhenBothLocationsLackSpace(t *testing.T) {
	base := t.TempDir()
	primary := filepath.Join(base, "primary")
	alternate := filepath.Join(base, "alternate")
	root, err := chooseExtractionRootWithSpace(primary, alternate, 51, func(string) (uint64, error) { return 50, nil })
	if err == nil {
		t.Fatalf("expected insufficient-space error, got root %q", root)
	}
	if root != "" {
		t.Fatalf("expected no extraction root, got %q", root)
	}
}

func TestActualStartupDriveFallback(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("requires Windows C: and D: drives")
	}
	localAppData := os.Getenv("LOCALAPPDATA")
	if !strings.EqualFold(filepath.VolumeName(localAppData), `C:`) {
		t.Skip("requires LOCALAPPDATA on C:")
	}
	primary, err := os.MkdirTemp(localAppData, "OptiShade-private-startup-test-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(primary)
	alternate, err := os.MkdirTemp(`D:\`, "OptiShade-private-startup-test-")
	if err != nil {
		t.Skipf("D: is not writable: %v", err)
	}
	defer os.RemoveAll(alternate)
	primaryFree, err := diskFreeSpace(primary)
	if err != nil {
		t.Skipf("cannot inspect C: free space: %v", err)
	}
	alternateFree, err := diskFreeSpace(alternate)
	if err != nil {
		t.Skipf("cannot inspect D: free space: %v", err)
	}
	// Set the requirement just above C:'s free space and below D:'s. This
	// exercises the production fallback and its real write probe without
	// reserving a large file or filling either drive.
	const margin uint64 = 1024 * 1024 * 1024
	if primaryFree > ^uint64(0)-margin || alternateFree <= primaryFree+margin {
		t.Skipf("requires D: to have at least 1 GiB more free space than C: (C: %d, D: %d)", primaryFree, alternateFree)
	}
	required := primaryFree + margin
	root, err := chooseExtractionRoot(primary, alternate, required)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.EqualFold(filepath.Clean(root), filepath.Clean(alternate)) {
		t.Fatalf("expected D: fallback, got %s", root)
	}
	if _, err := chooseExtractionRoot(primary, alternate, ^uint64(0)); err == nil {
		t.Fatal("insufficient space must fail")
	}
	if !strings.EqualFold(filepath.VolumeName(root), `D:`) {
		t.Fatalf("wrong fallback volume %s", filepath.VolumeName(root))
	}
}
