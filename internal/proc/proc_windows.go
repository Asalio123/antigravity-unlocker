//go:build windows

package proc

import (
	"os"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

const (
	th32csSnapProcess = 0x00000002
	processTerminate  = 0x0001
	maxPath           = 260
)

type processEntry32W struct {
	Size            uint32
	Usage           uint32
	ProcessID       uint32
	DefaultHeapID   uintptr
	ModuleID        uint32
	Threads         uint32
	ParentProcessID uint32
	PriClassBase    int32
	Flags           uint32
	ExeFile         [maxPath]uint16
}

var (
	modKernel32                  = syscall.NewLazyDLL("kernel32.dll")
	procCreateToolhelp32Snapshot = modKernel32.NewProc("CreateToolhelp32Snapshot")
	procProcess32FirstW          = modKernel32.NewProc("Process32FirstW")
	procProcess32NextW           = modKernel32.NewProc("Process32NextW")
	procOpenProcess              = modKernel32.NewProc("OpenProcess")
	procTerminateProcess         = modKernel32.NewProc("TerminateProcess")
	procCloseHandle              = modKernel32.NewProc("CloseHandle")
)

// StopAntigravity завершает процессы Antigravity, language_server*.exe и agy.exe на Windows.
func StopAntigravity() {
	self := uint32(os.Getpid())
	snap, _, _ := procCreateToolhelp32Snapshot.Call(th32csSnapProcess, 0)
	if snap == uintptr(syscall.InvalidHandle) || snap == 0 {
		return
	}
	defer procCloseHandle.Call(snap)

	var pe processEntry32W
	pe.Size = uint32(unsafe.Sizeof(pe))
	r, _, _ := procProcess32FirstW.Call(snap, uintptr(unsafe.Pointer(&pe)))
	for r != 0 {
		if pe.ProcessID != self {
			name := strings.ToLower(syscall.UTF16ToString(pe.ExeFile[:]))
			if shouldStopWindowsExe(name) {
				if h, _, _ := procOpenProcess.Call(processTerminate, 0, uintptr(pe.ProcessID)); h != 0 {
					procTerminateProcess.Call(h, 0)
					procCloseHandle.Call(h)
				}
			}
		}
		pe.Size = uint32(unsafe.Sizeof(pe))
		r, _, _ = procProcess32NextW.Call(snap, uintptr(unsafe.Pointer(&pe)))
	}
	time.Sleep(600 * time.Millisecond)
}

func shouldStopWindowsExe(lower string) bool {
	if lower == "antigravity.exe" || lower == "antigravity ide.exe" || lower == "antigravity cli.exe" || lower == "agy.exe" {
		return true
	}
	return strings.HasPrefix(lower, "language_server") && strings.HasSuffix(lower, ".exe")
}
