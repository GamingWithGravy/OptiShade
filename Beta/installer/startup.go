package main

import (
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

func showStartupError(err error) {
	text, _ := syscall.UTF16PtrFromString("OptiShade could not open: " + err.Error())
	title, _ := syscall.UTF16PtrFromString("OptiShade setup")
	syscall.NewLazyDLL("user32.dll").NewProc("MessageBoxW").Call(0, uintptr(unsafe.Pointer(text)), uintptr(unsafe.Pointer(title)), 0x10)
}

// Extraction can use the EXE drive without moving the manager's saved data.
func chooseExtractionRoot(primary, alternate string, required uint64) (string, error) {
	return chooseExtractionRootWithSpace(primary, alternate, required, diskFreeSpace)
}

func diskFreeSpace(root string) (uint64, error) {
	ptr, err := syscall.UTF16PtrFromString(root)
	if err != nil {
		return 0, err
	}
	var available uint64
	ok, _, spaceErr := syscall.NewLazyDLL("kernel32.dll").NewProc("GetDiskFreeSpaceExW").Call(uintptr(unsafe.Pointer(ptr)), uintptr(unsafe.Pointer(&available)), 0, 0)
	if ok == 0 {
		return 0, fmt.Errorf("cannot check extraction space in %s: %v", root, spaceErr)
	}
	return available, nil
}

// chooseExtractionRootWithSpace keeps the real directory creation and write
// probe in the production path while allowing tests to supply deterministic
// disk-space observations without filling a drive.
func chooseExtractionRootWithSpace(primary, alternate string, required uint64, space func(string) (uint64, error)) (string, error) {
	var last error
	for _, root := range []string{primary, alternate} {
		if err := os.MkdirAll(root, 0700); err != nil {
			last = err
			continue
		}
		available, err := space(root)
		if err != nil {
			last = err
			continue
		}
		if available < required {
			last = fmt.Errorf("Not enough space in %s: need %d MB, available %d MB", root, required/1048576, available/1048576)
			continue
		}
		probe, err := os.CreateTemp(root, "write-check-")
		if err != nil {
			last = err
			continue
		}
		name := probe.Name()
		probe.Close()
		os.Remove(name)
		return root, nil
	}
	return "", fmt.Errorf("%v. Free disk space and retry; game files were not changed.", last)
}
