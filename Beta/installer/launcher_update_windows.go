//go:build windows

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

func execCommand(name string, args ...string) *exec.Cmd { return exec.Command(name, args...) }

func waitForLauncherProcesses(pids ...int) error {
	seen := map[int]bool{}
	deadline := time.Now().Add(3 * time.Minute)
	openProcess := syscall.NewLazyDLL("kernel32.dll").NewProc("OpenProcess")
	wait := syscall.NewLazyDLL("kernel32.dll").NewProc("WaitForSingleObject")
	closeHandle := syscall.NewLazyDLL("kernel32.dll").NewProc("CloseHandle")
	for _, pid := range pids {
		if pid <= 0 || seen[pid] {
			continue
		}
		seen[pid] = true
		handle, _, callErr := openProcess.Call(0x00100000, 0, uintptr(uint32(pid)))
		if handle == 0 {
			if callErr == syscall.Errno(87) {
				continue
			} // The process already exited.
			return fmt.Errorf("could not wait for OptiShade process %d: %w", pid, callErr)
		}
		for {
			if time.Now().After(deadline) {
				closeHandle.Call(handle)
				return errors.New("timed out waiting for OptiShade to close; no update files were changed")
			}
			result, _, waitErr := wait.Call(handle, 250)
			if result == 0 {
				break
			} // WAIT_OBJECT_0
			if result == 0x102 {
				continue
			} // WAIT_TIMEOUT
			closeHandle.Call(handle)
			return fmt.Errorf("could not wait for OptiShade to close: %w", waitErr)
		}
		closeHandle.Call(handle)
	}
	return nil
}

func rejectLauncherReparsePath(name string) error {
	abs, err := filepath.Abs(name)
	if err != nil {
		return err
	}
	volume := filepath.VolumeName(abs)
	current := volume + string(os.PathSeparator)
	remainder := strings.TrimLeft(strings.TrimPrefix(abs, volume), `\/`)
	for _, part := range strings.Split(remainder, string(os.PathSeparator)) {
		if part == "" {
			continue
		}
		current = filepath.Join(current, part)
		p, convErr := syscall.UTF16PtrFromString(current)
		if convErr != nil {
			return convErr
		}
		attributes, _, callErr := syscall.NewLazyDLL("kernel32.dll").NewProc("GetFileAttributesW").Call(uintptr(unsafe.Pointer(p)))
		if uint32(attributes) == 0xffffffff {
			if callErr == syscall.Errno(2) || callErr == syscall.Errno(3) {
				return os.ErrNotExist
			}
			return callErr
		}
		if attributes&0x400 != 0 {
			return fmt.Errorf("path contains a reparse point: %s", current)
		}
	}
	return nil
}

func writeLauncherReceipt(path string, data []byte) error {
	tmp := path + ".new"
	_ = os.Remove(tmp)
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	if _, err = f.Write(data); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		_ = os.Remove(tmp)
		return err
	}
	from, err := syscall.UTF16PtrFromString(tmp)
	if err != nil {
		_ = os.Remove(tmp)
		return err
	}
	to, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		_ = os.Remove(tmp)
		return err
	}
	ok, _, callErr := syscall.NewLazyDLL("kernel32.dll").NewProc("MoveFileExW").Call(uintptr(unsafe.Pointer(from)), uintptr(unsafe.Pointer(to)), 0x1|0x8)
	if ok == 0 {
		_ = os.Remove(tmp)
		return callErr
	}
	return nil
}

func startLauncherUpdateCleanup(stageDir string) {
	command := "Start-Sleep -Milliseconds 1500; $p=$env:OPTISHADE_UPDATE_CLEANUP; if ($p -and (Test-Path -LiteralPath $p)) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }"
	cmd := exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-Command", command)
	cmd.Env = append(os.Environ(), "OPTISHADE_UPDATE_CLEANUP="+stageDir)
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: 0x08000000}
	_ = cmd.Start()
}
