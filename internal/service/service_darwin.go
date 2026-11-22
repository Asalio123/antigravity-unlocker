//go:build darwin

package service

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/Asalio123/antigravity-unlocker/internal/config"
)

const daemonLabel = "com.asalio123.agunlocker.daemon"

func daemonPlistPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "LaunchAgents", daemonLabel+".plist")
}

func xmlEsc(s string) string {
	r := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;")
	return r.Replace(s)
}

// InstallAndStart ставит пользовательский LaunchAgent (gui/<uid>, БЕЗ sudo) и ждёт подъёма прокси.
func InstallAndStart() (int, error) {
	if os.Geteuid() == 0 {
		return 0, fmt.Errorf("запусти без sudo: LaunchAgent должен ставиться в пользовательскую GUI-сессию")
	}
	_ = os.Remove(config.DeclinePath())
	uid := fmt.Sprintf("gui/%d", os.Getuid())
	_ = exec.Command("launchctl", "bootout", uid+"/"+daemonLabel).Run()

	bin, err := EnsureInstalledBinary()
	if err != nil {
		return 0, fmt.Errorf("копирование бинаря в %s: %w", InstalledBinaryPath(), err)
	}
	plist := daemonPlistPath()
	if err := os.MkdirAll(filepath.Dir(plist), 0o755); err != nil {
		return 0, err
	}
	xml := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>%s</string>
  <key>ProgramArguments</key>
  <array><string>%s</string><string>daemon</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>%s</string>
  <key>StandardErrorPath</key><string>%s</string>
</dict></plist>
`, daemonLabel, xmlEsc(bin), xmlEsc(config.LogFilePath()), xmlEsc(config.LogFilePath()))
	if err := os.WriteFile(plist, []byte(xml), 0o644); err != nil {
		return 0, err
	}
	if out, err := exec.Command("plutil", "-lint", plist).CombinedOutput(); err != nil {
		_ = os.Remove(plist)
		return 0, fmt.Errorf("ошибка plist: %s", strings.TrimSpace(string(out)))
	}
	if out, err := exec.Command("launchctl", "bootstrap", uid, plist).CombinedOutput(); err != nil {
		_ = os.Remove(plist)
		return 0, fmt.Errorf("launchctl bootstrap: %s", strings.TrimSpace(string(out)))
	}
	if st, ok := WaitForRunning(6 * time.Second); ok {
		return st.Port, nil
	}
	return config.ActivePort(), nil
}

// StopAndUninstall останавливает LaunchAgent и удаляет plist.
func StopAndUninstall() error {
	uid := fmt.Sprintf("gui/%d", os.Getuid())
	_ = exec.Command("launchctl", "bootout", uid+"/"+daemonLabel).Run()
	_ = os.Remove(daemonPlistPath())
	// Убираем старый v2 LaunchAgent, если он остался
	home, _ := os.UserHomeDir()
	oldLabel := "com.asalio123.agunlocker.watch"
	_ = exec.Command("launchctl", "bootout", uid+"/"+oldLabel).Run()
	_ = os.Remove(filepath.Join(home, "Library", "LaunchAgents", oldLabel+".plist"))
	return nil
}

func IsInstalled() bool {
	_, err := os.Stat(daemonPlistPath())
	return err == nil
}
