//go:build windows

package env

import (
	"fmt"
	"os"
	"strings"
	"syscall"
	"unsafe"

	"github.com/Asalio123/antigravity-unlocker/internal/config"
)

const (
	hkeyCurrentUser    = uintptr(0x80000001)
	keyQueryValue      = 0x0001
	keySetValue        = 0x0002
	regSZ              = 1
	hwndBroadcast      = uintptr(0xFFFF)
	wmSettingChange    = 0x001A
	smtoAbortIfHung    = 0x0002
)

var (
	modAdvapi32          = syscall.NewLazyDLL("advapi32.dll")
	procRegCreateKeyExW  = modAdvapi32.NewProc("RegCreateKeyExW")
	procRegOpenKeyExW    = modAdvapi32.NewProc("RegOpenKeyExW")
	procRegSetValueExW   = modAdvapi32.NewProc("RegSetValueExW")
	procRegDeleteValueW  = modAdvapi32.NewProc("RegDeleteValueW")
	procRegQueryValueExW = modAdvapi32.NewProc("RegQueryValueExW")
	procRegCloseKey      = modAdvapi32.NewProc("RegCloseKey")

	modUser32               = syscall.NewLazyDLL("user32.dll")
	procSendMessageTimeoutW = modUser32.NewProc("SendMessageTimeoutW")
)

// SetProxyEnv записывает AG_UNL_PRXY в HKCU\Environment (права администратора не нужны)
// и рассылает WM_SETTINGCHANGE, чтобы Explorer и новые процессы сразу увидели переменную.
func SetProxyEnv(proxyURL string) error {
	subkey, _ := syscall.UTF16PtrFromString("Environment")
	var hKey uintptr
	r, _, _ := procRegCreateKeyExW.Call(
		hkeyCurrentUser,
		uintptr(unsafe.Pointer(subkey)),
		0, 0, 0,
		keySetValue,
		0,
		uintptr(unsafe.Pointer(&hKey)),
		0,
	)
	if r != 0 {
		return fmt.Errorf("RegCreateKeyExW HKCU\\Environment: error %d", r)
	}
	defer procRegCloseKey.Call(hKey)

	name, _ := syscall.UTF16PtrFromString(config.ProxyEnvVar)
	val, _ := syscall.UTF16FromString(proxyURL)
	r, _, _ = procRegSetValueExW.Call(
		hKey,
		uintptr(unsafe.Pointer(name)),
		0,
		regSZ,
		uintptr(unsafe.Pointer(&val[0])),
		uintptr(len(val)*2),
	)
	if r != 0 {
		return fmt.Errorf("RegSetValueExW %s: error %d", config.ProxyEnvVar, r)
	}
	_ = os.Setenv(config.ProxyEnvVar, proxyURL)
	broadcastEnvChange()
	return nil
}

// ClearProxyEnv удаляет AG_UNL_PRXY из HKCU\Environment.
func ClearProxyEnv() error {
	subkey, _ := syscall.UTF16PtrFromString("Environment")
	var hKey uintptr
	r, _, _ := procRegOpenKeyExW.Call(
		hkeyCurrentUser,
		uintptr(unsafe.Pointer(subkey)),
		0,
		keySetValue,
		uintptr(unsafe.Pointer(&hKey)),
	)
	if r != 0 {
		return nil
	}
	defer procRegCloseKey.Call(hKey)

	name, _ := syscall.UTF16PtrFromString(config.ProxyEnvVar)
	procRegDeleteValueW.Call(hKey, uintptr(unsafe.Pointer(name)))
	_ = os.Unsetenv(config.ProxyEnvVar)
	broadcastEnvChange()
	return nil
}

// GetProxyEnv читает AG_UNL_PRXY из HKCU\Environment.
func GetProxyEnv() string {
	subkey, _ := syscall.UTF16PtrFromString("Environment")
	var hKey uintptr
	r, _, _ := procRegOpenKeyExW.Call(
		hkeyCurrentUser,
		uintptr(unsafe.Pointer(subkey)),
		0,
		keyQueryValue,
		uintptr(unsafe.Pointer(&hKey)),
	)
	if r != 0 {
		return strings.TrimSpace(os.Getenv(config.ProxyEnvVar))
	}
	defer procRegCloseKey.Call(hKey)

	name, _ := syscall.UTF16PtrFromString(config.ProxyEnvVar)
	var typ uint32
	var size uint32
	r, _, _ = procRegQueryValueExW.Call(
		hKey,
		uintptr(unsafe.Pointer(name)),
		0,
		uintptr(unsafe.Pointer(&typ)),
		0,
		uintptr(unsafe.Pointer(&size)),
	)
	if r != 0 || size == 0 || size > 4096 {
		return strings.TrimSpace(os.Getenv(config.ProxyEnvVar))
	}
	buf := make([]uint16, size/2+1)
	r, _, _ = procRegQueryValueExW.Call(
		hKey,
		uintptr(unsafe.Pointer(name)),
		0,
		uintptr(unsafe.Pointer(&typ)),
		uintptr(unsafe.Pointer(&buf[0])),
		uintptr(unsafe.Pointer(&size)),
	)
	if r != 0 {
		return strings.TrimSpace(os.Getenv(config.ProxyEnvVar))
	}
	return strings.TrimSpace(syscall.UTF16ToString(buf))
}

func broadcastEnvChange() {
	envStr, _ := syscall.UTF16PtrFromString("Environment")
	var res uintptr
	procSendMessageTimeoutW.Call(
		hwndBroadcast,
		wmSettingChange,
		0,
		uintptr(unsafe.Pointer(envStr)),
		smtoAbortIfHung,
		2000,
		uintptr(unsafe.Pointer(&res)),
	)
}
