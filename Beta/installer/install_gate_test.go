package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func writeGateFixture(t *testing.T, local, app string, record map[string]any, agreement bool) {
	t.Helper()
	store := filepath.Join(local, "OptiShade")
	if err := os.MkdirAll(filepath.Join(store, "Sessions"), 0700); err != nil {
		t.Fatal(err)
	}
	if record != nil {
		data, _ := json.Marshal(record)
		if err := os.WriteFile(filepath.Join(store, installSetupRecordName), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	if agreement {
		if err := os.WriteFile(filepath.Join(store, "user-agreement-acceptance.json"), []byte(`{"Schema":1,"Accepted":true,"AgreementVersion":1}`), 0600); err != nil {
			t.Fatal(err)
		}
	}
}

func goodRecord(app string) map[string]any {
	return map[string]any{"Schema": 1, "App": app, "Version": "1.0.78", "Folders": []string{"OptiShade", "OptiShade/Sessions"}}
}

func TestInstallerSetupGate(t *testing.T) {
	app := filepath.Join(t.TempDir(), "Programs", "OptiShade", "OptiShade.exe")
	cases := []struct {
		name  string
		setup func(local string)
		ok    bool
	}{
		{"set up by the installer", func(local string) { writeGateFixture(t, local, app, goodRecord(app), true) }, true},
		{"empty AppData", func(string) {}, false},
		{"folders but no record", func(local string) { writeGateFixture(t, local, app, nil, true) }, false},
		{"agreement not accepted", func(local string) { writeGateFixture(t, local, app, goodRecord(app), false) }, false},
		{"another copy of the launcher", func(local string) {
			writeGateFixture(t, local, app, goodRecord(filepath.Join(local, "Downloads", "OptiShade.exe")), true)
		}, false},
		{"required folder removed", func(local string) {
			writeGateFixture(t, local, app, goodRecord(app), true)
			os.RemoveAll(filepath.Join(local, "OptiShade", "Sessions"))
		}, false},
		{"record escapes AppData", func(local string) {
			record := goodRecord(app)
			record["Folders"] = []string{"../outside"}
			writeGateFixture(t, local, app, record, true)
		}, false},
		{"wrong schema", func(local string) {
			record := goodRecord(app)
			record["Schema"] = 2
			writeGateFixture(t, local, app, record, true)
		}, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			local := t.TempDir()
			c.setup(local)
			before := listTree(t, local)
			err := checkInstallerSetup(app, local)
			if c.ok && err != nil {
				t.Fatalf("expected the launcher to start, got %v", err)
			}
			if !c.ok && (err == nil || !errors.Is(err, errInstallerSetupMissing)) {
				t.Fatalf("expected the set-up gate to refuse, got %v", err)
			}
			if after := listTree(t, local); after != before {
				t.Fatalf("the gate changed AppData:\nbefore %s\nafter  %s", before, after)
			}
		})
	}
}

func listTree(t *testing.T, root string) string {
	t.Helper()
	out := ""
	filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err == nil {
			out += path + ";"
		}
		return nil
	})
	return out
}

func TestSetupRequiredNoticeIsEmbedded(t *testing.T) {
	for _, name := range []string{"setup-required.ps1", "FusionSetup.exe", "OptiShade-icon.png"} {
		if _, err := bundle.ReadFile(name); err != nil {
			t.Fatalf("%s is not embedded: %v", name, err)
		}
	}
}
