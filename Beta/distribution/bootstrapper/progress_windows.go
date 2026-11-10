//go:build windows

package main

import (
	"fmt"
	"runtime"
	"sync"
	"syscall"
	"unsafe"
)

const (
	progressWMUser        = 0x0400
	progressPBMSetPos     = progressWMUser + 2
	progressPBMSetMarquee = progressWMUser + 10
	progressPBMSetRange32 = progressWMUser + 6
	progressWSOverlapped  = 0x00000000
	progressWSCaption     = 0x00C00000
	progressWSVisible     = 0x10000000
	progressWSChild       = 0x40000000
	progressICCProgress   = 0x00000020
	progressPBSMarquee    = 0x00000008
)

type progressICC struct {
	Size uint32
	ICC  uint32
}

type progressPOINT struct{ X, Y int32 }
type progressMSG struct {
	Hwnd    uintptr
	Message uint32
	Pad     uint32
	WParam  uintptr
	LParam  uintptr
	Time    uint32
	Pad2    uint32
	Pt      progressPOINT
}

type installerProgress struct {
	mu       sync.Mutex
	threadID uint32
	window   uintptr
	label    uintptr
	bar      uintptr
	closed   bool
	ready    chan error
	done     chan struct{}
}

var progressUser32 = syscall.NewLazyDLL("user32.dll")
var progressComctl32 = syscall.NewLazyDLL("comctl32.dll")
var progressKernel32 = syscall.NewLazyDLL("kernel32.dll")

func startInstallerProgress() *installerProgress {
	p := &installerProgress{ready: make(chan error, 1), done: make(chan struct{})}
	go p.run()
	if err := <-p.ready; err != nil {
		return nil
	}
	return p
}

func (p *installerProgress) run() {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	defer close(p.done)
	threadID, _, _ := progressKernel32.NewProc("GetCurrentThreadId").Call()
	p.threadID = uint32(threadID)
	init := progressICC{Size: uint32(unsafe.Sizeof(progressICC{})), ICC: progressICCProgress}
	if ok, _, _ := progressComctl32.NewProc("InitCommonControlsEx").Call(uintptr(unsafe.Pointer(&init))); ok == 0 {
		p.ready <- fmt.Errorf("could not initialize the progress control")
		return
	}
	class, _ := syscall.UTF16PtrFromString("STATIC")
	title, _ := syscall.UTF16PtrFromString("OptiShade installer")
	p.window, _, _ = progressUser32.NewProc("CreateWindowExW").Call(
		0, uintptr(unsafe.Pointer(class)), uintptr(unsafe.Pointer(title)),
		progressWSOverlapped|progressWSCaption|progressWSVisible,
		0x80000000, 0x80000000, 520, 158, 0, 0, 0, 0,
	)
	if p.window == 0 {
		p.ready <- fmt.Errorf("could not create the installer progress window")
		return
	}
	labelClass, _ := syscall.UTF16PtrFromString("STATIC")
	labelText, _ := syscall.UTF16PtrFromString("Checking the signed OptiShade launcher channel…")
	p.label, _, _ = progressUser32.NewProc("CreateWindowExW").Call(
		0, uintptr(unsafe.Pointer(labelClass)), uintptr(unsafe.Pointer(labelText)),
		progressWSChild|progressWSVisible, 22, 24, 468, 28, p.window, 0, 0, 0,
	)
	barClass, _ := syscall.UTF16PtrFromString("msctls_progress32")
	p.bar, _, _ = progressUser32.NewProc("CreateWindowExW").Call(
		0, uintptr(unsafe.Pointer(barClass)), 0, progressWSChild|progressWSVisible|progressPBSMarquee,
		22, 65, 468, 24, p.window, 0, 0, 0,
	)
	if p.label == 0 || p.bar == 0 {
		progressUser32.NewProc("DestroyWindow").Call(p.window)
		p.ready <- fmt.Errorf("could not create installer progress controls")
		return
	}
	progressUser32.NewProc("ShowWindow").Call(p.window, 5)
	progressUser32.NewProc("UpdateWindow").Call(p.window)
	p.ready <- nil
	var msg progressMSG
	getMessage := progressUser32.NewProc("GetMessageW")
	for {
		result, _, _ := getMessage.Call(uintptr(unsafe.Pointer(&msg)), 0, 0, 0)
		if int32(result) <= 0 {
			break
		}
		progressUser32.NewProc("TranslateMessage").Call(uintptr(unsafe.Pointer(&msg)))
		progressUser32.NewProc("DispatchMessageW").Call(uintptr(unsafe.Pointer(&msg)))
	}
	progressUser32.NewProc("DestroyWindow").Call(p.window)
}

func (p *installerProgress) Update(message string, current, total int64) {
	if p == nil {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed || p.label == 0 || p.bar == 0 {
		return
	}
	text, err := syscall.UTF16PtrFromString(message)
	if err == nil {
		progressUser32.NewProc("SetWindowTextW").Call(p.label, uintptr(unsafe.Pointer(text)))
	}
	if total > 0 {
		progressUser32.NewProc("SendMessageW").Call(p.bar, progressPBMSetMarquee, 0, 0)
		progressUser32.NewProc("SendMessageW").Call(p.bar, progressPBMSetRange32, 0, 100)
		percent := current * 100 / total
		if percent > 100 {
			percent = 100
		}
		progressUser32.NewProc("SendMessageW").Call(p.bar, progressPBMSetPos, uintptr(percent), 0)
	} else {
		progressUser32.NewProc("SendMessageW").Call(p.bar, progressPBMSetMarquee, 1, 25)
	}
}

func (p *installerProgress) Close() {
	if p == nil {
		return
	}
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return
	}
	p.closed = true
	threadID := p.threadID
	p.mu.Unlock()
	progressUser32.NewProc("PostThreadMessageW").Call(uintptr(threadID), 0x0012, 0, 0) // WM_QUIT
	<-p.done
}
