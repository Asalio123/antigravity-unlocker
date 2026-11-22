//go:build linux

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
	rcBegin = "# >>> ag-unlocker env >>>"
	rcEnd   = "# <<< ag-unlocker env <<<"
)

func envDPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "environment.d", "90-ag-unlocker.conf")
}

// SetProxyEnv прописывает AG_UNL_PRXY в systemd --user, environment.d и ~/.bashrc / ~/.zshrc.
func SetProxyEnv(proxyURL string) error {
	conf := envDPath()
	if err := os.MkdirAll(filepath.Dir(conf), 0o755); err != nil {
		return err
	}
	content := fmt.Sprintf("%s=%s\n", config.ProxyEnvVar, proxyURL)
	if err := os.WriteFile(conf, []byte(content), 0o644); err != nil {
		return err
	}
	_ = exec.Command("systemctl", "--user", "set-environment", config.ProxyEnvVar+"="+proxyURL).Run()

	home, _ := os.UserHomeDir()
	for _, rc := range []string{filepath.Join(home, ".bashrc"), filepath.Join(home, ".zshrc"), filepath.Join(home, ".profile")} {
		_ = upsertRCBlock(rc, fmt.Sprintf("export %s=%q", config.ProxyEnvVar, proxyURL))
	}
	return nil
}

// ClearProxyEnv убирает AG_UNL_PRXY из systemd --user, environment.d и shell-профилей.
func ClearProxyEnv() error {
	_ = os.Remove(envDPath())
	_ = exec.Command("systemctl", "--user", "unset-environment", config.ProxyEnvVar).Run()

	home, _ := os.UserHomeDir()
	for _, rc := range []string{filepath.Join(home, ".bashrc"), filepath.Join(home, ".zshrc"), filepath.Join(home, ".profile")} {
		_ = upsertRCBlock(rc, "")
	}
	return nil
}

func GetProxyEnv() string {
	if out, err := exec.Command("systemctl", "--user", "show-environment").Output(); err == nil {
		prefix := config.ProxyEnvVar + "="
		for _, line := range strings.Split(string(out), "\n") {
			if strings.HasPrefix(line, prefix) {
				return strings.TrimSpace(strings.TrimPrefix(line, prefix))
			}
		}
	}
	if raw, err := os.ReadFile(envDPath()); err == nil {
		prefix := config.ProxyEnvVar + "="
		for _, line := range strings.Split(string(raw), "\n") {
			if strings.HasPrefix(line, prefix) {
				return strings.TrimSpace(strings.TrimPrefix(line, prefix))
			}
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
