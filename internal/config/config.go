package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
)

const (
	Version     = "3.0.0"
	ProxyEnvVar = "AG_UNL_PRXY" // 11 bytes == len("https_proxy")
	DefaultPort = 53189
	ListenIP    = "127.0.0.1"
)

var FallbackPorts = []int{43189, 44189, 45189, 46189, 47189, 48189}

// GateHosts — домены Google, на которых стоит региональная проверка (HTTP 400).
// Остальной трафик (accounts.google.com, oauth2, storage и т.д.) идёт напрямую.
var GateHosts = []string{
	"daily-cloudcode-pa.googleapis.com",
	"cloudcode-pa.googleapis.com",
	"generativelanguage.googleapis.com",
	"aicode.googleapis.com",
}

func IsGateHost(host string) bool {
	h := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(host), "."))
	for _, g := range GateHosts {
		if h == g {
			return true
		}
	}
	return false
}

// Settings хранит пользовательские настройки между запусками.
type Settings struct {
	CustomDNS     []string `json:"custom_dns,omitempty"`
	UpstreamProxy string   `json:"upstream_proxy,omitempty"`
	PreferredPort int      `json:"preferred_port,omitempty"`
}

// DataDir возвращает пользовательский каталог данных без требования прав root/admin.
func DataDir() string {
	if custom := strings.TrimSpace(os.Getenv("AG_DATA_DIR")); custom != "" {
		return custom
	}
	home, _ := os.UserHomeDir()
	switch runtime.GOOS {
	case "darwin":
		return filepath.Join(home, "Library", "Application Support", "ag-unlocker")
	case "windows":
		if local := os.Getenv("LOCALAPPDATA"); local != "" {
			return filepath.Join(local, "ag-unlocker")
		}
		return filepath.Join(home, "AppData", "Local", "ag-unlocker")
	default:
		if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
			return filepath.Join(xdg, "ag-unlocker")
		}
		return filepath.Join(home, ".config", "ag-unlocker")
	}
}

func SettingsPath() string { return filepath.Join(DataDir(), "settings.json") }
func PortFilePath() string { return filepath.Join(DataDir(), "proxy_port") }
func PIDFilePath() string  { return filepath.Join(DataDir(), "daemon.pid") }
func LogFilePath() string  { return filepath.Join(DataDir(), "daemon.log") }
func DeclinePath() string  { return filepath.Join(DataDir(), "no_watch") }

func LoadSettings() Settings {
	var s Settings
	raw, err := os.ReadFile(SettingsPath())
	if err != nil {
		return s
	}
	_ = json.Unmarshal(raw, &s)
	return s
}

func SaveSettings(s Settings) error {
	if err := os.MkdirAll(DataDir(), 0o755); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(SettingsPath(), append(raw, '\n'), 0o600)
}

func ActivePort() int {
	if raw, err := os.ReadFile(PortFilePath()); err == nil {
		if p, err := strconv.Atoi(strings.TrimSpace(string(raw))); err == nil && p > 0 && p < 65536 {
			return p
		}
	}
	if s := LoadSettings(); s.PreferredPort > 0 && s.PreferredPort < 65536 {
		return s.PreferredPort
	}
	return DefaultPort
}

func WriteActivePort(port int) error {
	if err := os.MkdirAll(DataDir(), 0o755); err != nil {
		return err
	}
	return os.WriteFile(PortFilePath(), []byte(strconv.Itoa(port)+"\n"), 0o644)
}

func ProxyURL(port int) string {
	return "http://" + ListenIP + ":" + strconv.Itoa(port)
}
