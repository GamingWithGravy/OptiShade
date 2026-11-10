package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// The launcher refuses to start until this installer has created its AppData
// folders and written install-setup.json (Beta/installer/install_gate.go keeps
// the matching reader). Keep the name, schema and folder list in step with it.
const installSetupRecordName = "install-setup.json"

// launcherDataFolders are relative to %LOCALAPPDATA%. Sessions is where the
// launcher unpacks its scripts each time it starts.
var launcherDataFolders = []string{"OptiShade", "OptiShade/Sessions"}

// prepareLauncherSetup runs after the launcher is installed and verified. It
// creates the launcher's folders and then the record the launcher checks. The
// User Agreement acceptance must already be saved.
func prepareLauncherSetup(app, version string) error {
	local := os.Getenv("LOCALAPPDATA")
	if !filepath.IsAbs(local) {
		return errors.New("Windows did not provide a valid per-user Local AppData directory")
	}
	for _, folder := range launcherDataFolders {
		path := filepath.Join(local, filepath.FromSlash(folder))
		if err := os.MkdirAll(path, 0700); err != nil {
			return fmt.Errorf("could not create %s: %w", path, err)
		}
		if err := rejectReparsePath(path); err != nil {
			return fmt.Errorf("unsafe OptiShade data folder: %w", err)
		}
	}
	store := filepath.Join(local, "OptiShade")
	if info, err := os.Stat(filepath.Join(store, "user-agreement-acceptance.json")); err != nil || !info.Mode().IsRegular() {
		return errors.New("your acceptance of the User Agreement was not saved, so OptiShade was not set up. Run the installer again")
	}
	record := map[string]any{
		"Schema":   1,
		"App":      app,
		"Version":  version,
		"SetupUtc": time.Now().UTC().Format(time.RFC3339),
		"Folders":  launcherDataFolders,
	}
	data, err := json.MarshalIndent(record, "", "  ")
	if err != nil {
		return err
	}
	return atomicWrite(filepath.Join(store, installSetupRecordName), data)
}
