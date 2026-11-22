package hosts

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

const (
	MarkerBegin = "# AG_UNLOCKER_HOSTS_BEGIN"
	MarkerEnd   = "# AG_UNLOCKER_HOSTS_END"
)

func FilePath() string {
	if p := strings.TrimSpace(os.Getenv("AG_HOSTS")); p != "" {
		return p
	}
	if runtime.GOOS == "windows" {
		root := os.Getenv("SystemRoot")
		if root == "" {
			root = `C:\Windows`
		}
		return filepath.Join(root, "System32", "drivers", "etc", "hosts")
	}
	return "/etc/hosts"
}

type Entry struct {
	IP     string
	Domain string
}

// ReadBlock возвращает текущие строки внутри блока AG_UNLOCKER_HOSTS_*.
func ReadBlock() []string {
	raw, err := os.ReadFile(FilePath())
	if err != nil {
		return nil
	}
	var out []string
	inside := false
	for _, line := range strings.Split(strings.ReplaceAll(string(raw), "\r\n", "\n"), "\n") {
		t := strings.TrimSpace(line)
		if t == MarkerBegin {
			inside = true
			continue
		}
		if t == MarkerEnd {
			inside = false
			continue
		}
		if inside && t != "" {
			out = append(out, t)
		}
	}
	return out
}

// WriteBlock атомарно (или напрямую на Windows) заменяет блок AG_UNLOCKER_HOSTS_*.
func WriteBlock(entries []Entry) error {
	path := FilePath()
	raw, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	eol := "\n"
	if runtime.GOOS == "windows" {
		eol = "\r\n"
	}
	cleaned := stripBlock(string(raw), eol)
	var b strings.Builder
	b.WriteString(cleaned)
	if len(entries) > 0 {
		if cleaned != "" && !strings.HasSuffix(cleaned, eol) {
			b.WriteString(eol)
		}
		b.WriteString(MarkerBegin + eol)
		for _, e := range entries {
			b.WriteString(fmt.Sprintf("%s %s%s", e.IP, e.Domain, eol))
		}
		b.WriteString(MarkerEnd + eol)
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		return fmt.Errorf("нет прав на запись %s: %w", path, err)
	}
	FlushDNS()
	return nil
}

// ClearBlock удаляет наш блок из hosts.
func ClearBlock() (bool, error) {
	if len(ReadBlock()) == 0 {
		return false, nil
	}
	return true, WriteBlock(nil)
}

func stripBlock(content, eol string) string {
	lines := strings.Split(strings.ReplaceAll(content, "\r\n", "\n"), "\n")
	var kept []string
	inside := false
	for _, line := range lines {
		t := strings.TrimSpace(line)
		if t == MarkerBegin {
			inside = true
			continue
		}
		if t == MarkerEnd {
			inside = false
			continue
		}
		if !inside {
			kept = append(kept, line)
		}
	}
	return strings.TrimRight(strings.Join(kept, eol), "\r\n") + eol
}

func FlushDNS() {
	switch runtime.GOOS {
	case "darwin":
		_ = exec.Command("dscacheutil", "-flushcache").Run()
		_ = exec.Command("killall", "-HUP", "mDNSResponder").Run()
	case "windows":
		_ = exec.Command("ipconfig", "/flushdns").Run()
	default:
		_ = exec.Command("resolvectl", "flush-caches").Run()
		_ = exec.Command("nscd", "-i", "hosts").Run()
	}
}
