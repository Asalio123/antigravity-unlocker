//go:build darwin

package env

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/Asalio123/antigravity-unlocker/internal/config"
)

const (
	envPlistLabel = "com.asalio123.agunlocker.env"
	rcBegin       = "# >>> ag-unlocker env >>>"
	rcEnd         = "# <<< ag-unlocker env <<<"
)

func envPlistPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "LaunchAgents", envPlistLabel+".plist")
}

// SetProxyEnv выставляет AG_UNL_PRXY в текущей GUI-сессии macOS, в LaunchAgent
// (переживает перезагрузку) и в ~/.zshrc / ~/.bash_profile (для CLI agy).
func SetProxyEnv(proxyURL string) error {
	_ = exec.Command("launchctl", "setenv", config.ProxyEnvVar, proxyURL).Run()

	plist := envPlistPath()
	if err := os.MkdirAll(filepath.Dir(plist), 0o755); err != nil {
		return err
	}
	xml := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>%s</string>
  <key>ProgramArguments</key>
  <array><string>/bin/launchctl</string><string>setenv</string><string>%s</string><string>%s</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
`, envPlistLabel, config.ProxyEnvVar, proxyURL)
	if err := os.WriteFile(plist, []byte(xml), 0o644); err != nil {
		return err
	}
	uid := fmt.Sprintf("gui/%d", os.Getuid())
	_ = exec.Command("launchctl", "bootout", uid+"/"+envPlistLabel).Run()
	_ = exec.Command("launchctl", "bootstrap", uid, plist).Run()

	home, _ := os.UserHomeDir()
	for _, rc := range []string{filepath.Join(home, ".zshrc"), filepath.Join(home, ".bash_profile")} {
		_ = upsertRCBlock(rc, fmt.Sprintf("export %s=%q", config.ProxyEnvVar, proxyURL))
	}
	return nil
}

// ClearProxyEnv полностью убирает AG_UNL_PRXY из GUI-сессии, LaunchAgent и shell-профилей.
func ClearProxyEnv() error {
	_ = exec.Command("launchctl", "unsetenv", config.ProxyEnvVar).Run()
	uid := fmt.Sprintf("gui/%d", os.Getuid())
	_ = exec.Command("launchctl", "bootout", uid+"/"+envPlistLabel).Run()
	_ = os.Remove(envPlistPath())

	home, _ := os.UserHomeDir()
	for _, rc := range []string{filepath.Join(home, ".zshrc"), filepath.Join(home, ".bash_profile")} {
		_ = upsertRCBlock(rc, "")
	}
	return nil
}

// GetProxyEnv читает текущее значение AG_UNL_PRXY из launchd GUI-сессии.
func GetProxyEnv() string {
	if out, err := exec.Command("launchctl", "getenv", config.ProxyEnvVar).Output(); err == nil {
		if v := strings.TrimSpace(string(out)); v != "" {
			return v
		}
	}
	return strings.TrimSpace(os.Getenv(config.ProxyEnvVar))
}

func upsertRCBlock(path, line string) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) && line == "" {
			return nil
		}
		raw = nil
	}
	lines := strings.Split(string(raw), "\n")
	var kept []string
	inside := false
	for _, l := range lines {
		t := strings.TrimSpace(l)
		if t == rcBegin {
			inside = true
			continue
		}
		if t == rcEnd {
			inside = false
			continue
		}
		if !inside {
			kept = append(kept, l)
		}
	}
	body := strings.TrimRight(strings.Join(kept, "\n"), "\n")
	if line != "" {
		if body != "" {
			body += "\n\n"
		}
		body += rcBegin + "\n" + line + "\n" + rcEnd + "\n"
	} else if body != "" {
		body += "\n"
	}
	return os.WriteFile(path, []byte(body), 0o644)
}
