package main

import (
	"os/exec"
	"runtime"
	"strings"
	"testing"
)

func TestRendererMethodSetupRegression(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("renderer method XAML and PowerShell integration is Windows-specific")
	}
	powershell, err := exec.LookPath("powershell.exe")
	if err != nil {
		t.Fatal("Windows PowerShell is required by the installer build:", err)
	}
	cmd := exec.Command(powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "renderer-method.test.ps1")
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("renderer method regression failed: %v\n%s", err, strings.TrimSpace(string(output)))
	}
	t.Log(strings.TrimSpace(string(output)))
}
