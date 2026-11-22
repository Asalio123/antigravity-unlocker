package discover

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

type Kind string

const (
	KindDesktop Kind = "Antigravity Desktop"
	KindIDE     Kind = "Antigravity IDE"
	KindIDE26   Kind = "Antigravity IDE 2.6+"
	KindCLI     Kind = "Antigravity CLI (agy)"
	KindVSCode  Kind = "Antigravity для VS Code"
)

// Install описывает одну найденную установку Antigravity (Desktop, IDE, CLI или VS Code backend).
type Install struct {
	Kind       Kind
	Root       string   // .app на macOS, resources на Linux, корневая папка на Windows, либо каталог agy
	BundlePath string   // на macOS путь к .app (для codesign/quarantine), иначе ""
	Binaries   []string // уникальные реальные пути к бинарям (симлинки развёрнуты)
	MainJS     string   // только IDE 2.5.x: resources/app/out/main.js
	ExtJS      string   // только IDE 2.5.x: resources/app/extensions/antigravity/dist/extension.js
	AsarPath   string   // Desktop: app.asar (для проверки архитектуры v2.4+)
}

// ResolvePath безопасно разворачивает симлинк и возвращает канонический путь.
func ResolvePath(p string) string {
	if r, err := filepath.EvalSymlinks(p); err == nil && r != "" {
		if abs, err := filepath.Abs(r); err == nil {
			return abs
		}
		return r
	}
	if abs, err := filepath.Abs(p); err == nil {
		return abs
	}
	return p
}

// IsNativeBinary проверяет magic-байты файла (Mach-O / ELF / PE), отсеивая логи, скрипты и временники.
func IsNativeBinary(path string) bool {
	low := strings.ToLower(path)
	for _, skip := range []string{".log", ".txt", ".agtmp", ".ag_backup", ".js", ".json", ".map"} {
		if strings.HasSuffix(low, skip) {
			return false
		}
	}
	fi, err := os.Stat(path)
	if err != nil || !fi.Mode().IsRegular() || fi.Size() < 64 {
		return false
	}
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	var hdr [4]byte
	if _, err := f.Read(hdr[:]); err != nil {
		return false
	}
	switch runtime.GOOS {
	case "darwin":
		return isMachO(hdr)
	case "windows":
		return hdr[0] == 'M' && hdr[1] == 'Z'
	default:
		return hdr[0] == 0x7F && hdr[1] == 'E' && hdr[2] == 'L' && hdr[3] == 'F'
	}
}

func isMachO(h [4]byte) bool {
	// 32/64-bit Mach-O (LE/BE) + Universal Fat binary
	magic := uint32(h[0])<<24 | uint32(h[1])<<16 | uint32(h[2])<<8 | uint32(h[3])
	switch magic {
	case 0xFEEDFACE, 0xCEFAEDFE, 0xFEEDFACF, 0xCFFAEDFE, 0xCAFEBABE, 0xBEBAFECA:
		return true
	}
	return false
}

// VSCodeExtensionInstalled проверяет наличие расширения Antigravity в VS Code / Insiders / Cursor / Windsurf.
func VSCodeExtensionInstalled(home string) bool {
	if home == "" {
		return false
	}
	dirs := []string{".vscode", ".vscode-insiders", ".vscode-oss", ".cursor", ".windsurf"}
	for _, d := range dirs {
		entries, err := os.ReadDir(filepath.Join(home, d, "extensions"))
		if err != nil {
			continue
		}
		for _, e := range entries {
			if e.IsDir() && strings.Contains(strings.ToLower(e.Name()), "antigravity") {
				return true
			}
		}
	}
	return false
}

// FindAll ищет все установки Antigravity на текущей ОС.
func FindAll() []Install {
	return findAllOS()
}

func globLanguageServers(dir string) []string {
	matches, err := filepath.Glob(filepath.Join(dir, "language_server*"))
	if err != nil {
		return nil
	}
	var out []string
	seen := make(map[string]bool)
	for _, m := range matches {
		rp := ResolvePath(m)
		if seen[rp] || !IsNativeBinary(rp) {
			continue
		}
		seen[rp] = true
		out = append(out, rp)
	}
	return out
}
