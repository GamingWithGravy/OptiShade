package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPortableStore(t *testing.T) {
	root := t.TempDir()
	local := filepath.Join(root, "LocalAppData")
	path, portable, err := managerStore(filepath.Join(root, "OptiShade.exe"), local)
	if err != nil || portable || path != filepath.Join(local, "OptiShade") {
		t.Fatal("regular data location changed")
	}
	for _, missing := range []string{"", filepath.Join("relative", "LocalAppData")} {
		t.Setenv("LOCALAPPDATA", missing)
		path, portable, err = managerStore(filepath.Join(root, "OptiShade.exe"), missing)
		if err != nil || portable || !filepath.IsAbs(path) {
			t.Fatalf("missing/relative LOCALAPPDATA produced invalid data location: path=%q portable=%t err=%v", path, portable, err)
		}
	}
	marker := filepath.Join(root, "portable.txt")
	if err := os.WriteFile(marker, []byte("portable"), 0600); err != nil {
		t.Fatal(err)
	}
	path, portable, err = managerStore(filepath.Join(root, "OptiShade.exe"), local)
	if err != nil || !portable || path != filepath.Join(root, "Data") {
		t.Fatal("portable data is not beside EXE")
	}
	moved := filepath.Join(root, "Moved folder")
	if err := os.Mkdir(moved, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(marker, filepath.Join(moved, "portable.txt")); err != nil {
		t.Fatal(err)
	}
	path, portable, err = managerStore(filepath.Join(moved, "OptiShade.exe"), local)
	if err != nil || !portable || path != filepath.Join(moved, "Data") {
		t.Fatal("moved portable location is stale")
	}
}
