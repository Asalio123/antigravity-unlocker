//go:build linux

package service

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/Asalio123/antigravity-unlocker/internal/config"
)

const systemdUnitName = "ag-unlocker.service"

func systemdUnitPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "systemd", "user", systemdUnitName)
}

func hasSystemdUser() bool {
	if _, err := exec.LookPath("systemctl"); err != nil {
		return false
	}
	return exec.Command("systemctl", "--user", "show-environment").Run() == nil
}

// InstallAndStart запускает демон через systemd --user (без root) или detached-процесс на non-systemd.
func InstallAndStart() (int, error) {
	_ = os.Remove(config.DeclinePath())
	_ = stopPIDDaemon()

	bin, err := EnsureInstalledBinary()
	if err != nil {
		return 0, fmt.Errorf("копирование бинаря: %w", err)
	}

	if hasSystemdUser() {
		unitPath := systemdUnitPath()
		if err := os.MkdirAll(filepath.Dir(unitPath), 0o755); err != nil {
			return 0, err
		}
		unit := fmt.Sprintf(`[Unit]
Description=Antigravity Unlocker local proxy & watchdog
After=network-online.target

[Service]
ExecStart="%s" daemon
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
`, bin)
		if err := os.WriteFile(unitPath, []byte(unit), 0o644); err != nil {
			return 0, err
		}
		if out, err := exec.Command("systemctl", "--user", "daemon-reload").CombinedOutput(); err != nil {
			_ = os.Remove(unitPath)
			return 0, fmt.Errorf("systemctl --user daemon-reload: %s", strings.TrimSpace(string(out)))
		}
		if out, err := exec.Command("systemctl", "--user", "enable", "--now", systemdUnitName).CombinedOutput(); err != nil {
			_ = os.Remove(unitPath)
			return 0, fmt.Errorf("systemctl --user enable --now: %s", strings.TrimSpace(string(out)))
		}
		if user := os.Getenv("USER"); user != "" {
			_ = exec.Command("loginctl", "enable-linger", user).Run()
		}
	} else {
		// Fallback для WSL / контейнеров / систем без systemd --user
		cmd := exec.Command(bin, "daemon")
		cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		if err := cmd.Start(); err != nil {
			return 0, fmt.Errorf("запуск фонового демона: %w", err)
		}
		_ = cmd.Process.Release()
	}

	if st, ok := WaitForRunning(6 * time.Second); ok {
		return st.Port, nil
	}
	return config.ActivePort(), nil
}

func StopAndUninstall() error {
	if hasSystemdUser() {
		_ = exec.Command("systemctl", "--user", "disable", "--now", systemdUnitName).Run()
		_ = exec.Command("systemctl", "--user", "disable", "--now", "ag-unlocker-watch.service").Run()
	}
	_ = os.Remove(systemdUnitPath())
	home, _ := os.UserHomeDir()
	_ = os.Remove(filepath.Join(home, ".config", "systemd", "user", "ag-unlocker-watch.service"))
	if hasSystemdUser() {
		_ = exec.Command("systemctl", "--user", "daemon-reload").Run()
	}
	_ = stopPIDDaemon()
	return nil
}

func stopPIDDaemon() error {
	raw, err := os.ReadFile(config.PIDFilePath())
	if err != nil {
		return nil
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil || pid <= 1 || pid == os.Getpid() {
		return nil
	}
	_ = syscall.Kill(pid, syscall.SIGTERM)
	time.Sleep(300 * time.Millisecond)
	_ = os.Remove(config.PIDFilePath())
	return nil
}

func IsInstalled() bool {
	if _, err := os.Stat(systemdUnitPath()); err == nil {
		return true
	}
	_, err := os.Stat(config.PIDFilePath())
	return err == nil
}
