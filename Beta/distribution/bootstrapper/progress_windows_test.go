//go:build windows

package main

import (
	"os"
	"testing"
	"time"
)

// Run with OPTISHADE_RUN_UI_SMOKE=1 to exercise the real native window.
// It is gated so ordinary headless builds and CI do not open desktop UI.
func TestInstallerProgressWindowSmoke(t *testing.T) {
	if os.Getenv("OPTISHADE_RUN_UI_SMOKE") != "1" {
		t.Skip("set OPTISHADE_RUN_UI_SMOKE=1 to open the native installer progress window")
	}
	p := startInstallerProgress()
	if p == nil {
		t.Fatal("native progress window could not start")
	}
	p.Update("Checking the signed launcher channel…", 0, 0)
	time.Sleep(250 * time.Millisecond)
	p.Update("Downloading the verified launcher… 50%", 50, 100)
	time.Sleep(250 * time.Millisecond)
	p.Update("Installing the verified launcher…", 0, 0)
	p.Close()
	select {
	case <-p.done:
	case <-time.After(2 * time.Second):
		t.Fatal("progress window thread did not close")
	}
}
