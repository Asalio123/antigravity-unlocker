//go:build windows

package service

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"github.com/Asalio123/antigravity-unlocker/internal/config"
)

const (
	hkeyCurrentUser  = uintptr(0x80000001)
	keyQueryValue    = 0x0001
	keySetValue      = 0x0002
	regSZ            = 1
	runSubkey        = `Software\Microsoft\Windows\CurrentVersion\Run`
	runValueName     = "AGUnlocker"
	createNoWindow   = 0x08000000
	detachedProcess  = 0x00000008
	processTerminate = 0x0001
)

var (
	modAdvapi32          = syscall.NewLazyDLL("advapi32.dll")
	procRegCreateKeyExW  = modAdvapi32.NewProc("RegCreateKeyExW")
	procRegOpenKeyExW    = modAdvapi32.NewProc("RegOpenKeyExW")
	procRegSetValueExW   = modAdvapi32.NewProc("RegSetValueExW")
	procRegDeleteValueW  = modAdvapi32.NewProc("RegDeleteValueW")
	procRegQueryValueExW = modAdvapi32.NewProc("RegQueryValueExW")
	procRegCloseKey      = modAdvapi32.NewProc("RegCloseKey")

	modKernel32          = syscall.NewLazyDLL("kernel32.dll")
	procOpenProcess      = modKernel32.NewProc("OpenProcess")
	procTerminateProcess = modKernel32.NewProc("TerminateProcess")
	procCloseHandle      = modKernel32.NewProc("CloseHandle")
)

// InstallAndStart прописывает автозапуск в HKCU\...\Run (без прав администратора)
// и стартует скрытый фоновый процесс прокси + watchdog.
func InstallAndStart() (int, error) {
	_ = os.Remove(config.DeclinePath())
	stopPIDDaemon()

	bin, err := EnsureInstalledBinary()
	if err != nil {
		return 0, fmt.Errorf("копирование бинаря: %w", err)
	}
	if err := setRunKey(fmt.Sprintf(`"%s" daemon`, bin)); err != nil {
		return 0, err
	}

	cmd := exec.Command(bin, "daemon")
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: createNoWindow | detachedProcess,
	}
	if err := cmd.Start(); err != nil {
		return 0, fmt.Errorf("запуск фонового процесса: %w", err)
	}
	_ = cmd.Process.Release()

	if st, ok := WaitForRunning(6 * time.Second); ok {
		return st.Port, nil
	}
	return config.ActivePort(), nil
}

func StopAndUninstall() error {
	deleteRunKey()
	stopPIDDaemon()
	return nil
}

func IsInstalled() bool {
	subkey, _ := syscall.UTF16PtrFromString(runSubkey)
	var hKey uintptr
	r, _, _ := procRegOpenKeyExW.Call(hkeyCurrentUser, uintptr(unsafe.Pointer(subkey)), 0, keyQueryValue, uintptr(unsafe.Pointer(&hKey)))
	if r != 0 {
		return false
	}
	defer procRegCloseKey.Call(hKey)
	name, _ := syscall.UTF16PtrFromString(runValueName)
	var typ, size uint32
	r, _, _ = procRegQueryValueExW.Call(hKey, uintptr(unsafe.Pointer(name)), 0, uintptr(unsafe.Pointer(&typ)), 0, uintptr(unsafe.Pointer(&size)))
	return r == 0 && size > 0
}

func setRunKey(cmdLine string) error {
	subkey, _ := syscall.UTF16PtrFromString(runSubkey)
	var hKey uintptr
	r, _, _ := procRegCreateKeyExW.Call(hkeyCurrentUser, uintptr(unsafe.Pointer(subkey)), 0, 0, 0, keySetValue, 0, uintptr(unsafe.Pointer(&hKey)), 0)
	if r != 0 {
		return fmt.Errorf("RegCreateKeyExW HKCU\\%s: error %d", runSubkey, r)
	}
	defer procRegCloseKey.Call(hKey)
	name, _ := syscall.UTF16PtrFromString(runValueName)
	val, _ := syscall.UTF16FromString(cmdLine)
	r, _, _ = procRegSetValueExW.Call(hKey, uintptr(unsafe.Pointer(name)), 0, regSZ, uintptr(unsafe.Pointer(&val[0])), uintptr(len(val)*2))
	if r != 0 {
		return fmt.Errorf("RegSetValueExW %s: error %d", runValueName, r)
	}
	return nil
}

func deleteRunKey() {
	subkey, _ := syscall.UTF16PtrFromString(runSubkey)
	var hKey uintptr
	r, _, _ := procRegOpenKeyExW.Call(hkeyCurrentUser, uintptr(unsafe.Pointer(subkey)), 0, keySetValue, uintptr(unsafe.Pointer(&hKey)))
	if r != 0 {
		return
	}
	defer procRegCloseKey.Call(hKey)
	name, _ := syscall.UTF16PtrFromString(runValueName)
	procRegDeleteValueW.Call(hKey, uintptr(unsafe.Pointer(name)))
}

func stopPIDDaemon() {
	raw, err := os.ReadFile(config.PIDFilePath())
	if err != nil {
		return
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil || pid <= 0 || pid == os.Getpid() {
		return
	}
	if h, _, _ := procOpenProcess.Call(processTerminate, 0, uintptr(pid)); h != 0 {
		procTerminateProcess.Call(h, 0)
		procCloseHandle.Call(h)
		time.Sleep(300 * time.Millisecond)
	}
	_ = os.Remove(config.PIDFilePath())
}
