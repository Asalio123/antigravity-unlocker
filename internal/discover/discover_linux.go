//go:build linux

package discover

import (
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func findAllOS() []Install {
	home, _ := os.UserHomeDir()
	cwd, _ := os.Getwd()
	exe, _ := os.Executable()
	exeDir := filepath.Dir(exe)

	var resRoots []string
	seenRoot := make(map[string]bool)
	addRoot := func(r string) {
		if r == "" {
			return
		}
		fi, err := os.Stat(r)
		if err != nil || !fi.IsDir() {
			return
		}
		rp := ResolvePath(r)
		if !seenRoot[rp] {
			seenRoot[rp] = true
			resRoots = append(resRoots, rp)
		}
	}

	if custom := strings.TrimSpace(os.Getenv("AG_ROOT")); custom != "" {
		addRoot(custom)
	} else {
		// 1. Пакетные менеджеры (.deb / .rpm)
		for _, cmd := range [][]string{
			{"dpkg", "-L", "antigravity", "antigravity-ide"},
			{"rpm", "-ql", "antigravity", "antigravity-ide"},
		} {
			if out, err := exec.Command(cmd[0], cmd[1:]...).Output(); err == nil {
				for _, line := range strings.Split(string(out), "\n") {
					line = strings.TrimSpace(line)
					if strings.Contains(line, "/bin/language_server") && IsNativeBinary(line) {
						addRoot(rootFromBinary(line))
					}
				}
			}
		}

		// 2. Стандартные пути, распакованные tar.gz в CWD и рядом с бинарём
		searchRoots := []string{
			"/opt", "/usr/share", "/usr/lib", "/usr/local/share",
			filepath.Join(home, ".antigravity"),
			filepath.Join(home, "opt"),
			filepath.Join(home, ".local", "share"),
			home, cwd, exeDir,
		}
		visited := make(map[string]bool)
		for _, base := range searchRoots {
			if base == "" {
				continue
			}
			rb := ResolvePath(base)
			if visited[rb] {
				continue
			}
			visited[rb] = true
			walkForInstalls(rb, 6, addRoot)
		}
	}

	var installs []Install
	seenBin := make(map[string]bool)
	for _, res := range resRoots {
		mainJS := filepath.Join(res, "app", "out", "main.js")
		extJS := filepath.Join(res, "app", "extensions", "antigravity", "dist", "extension.js")
		asar := filepath.Join(res, "app.asar")

		var bins []string
		for _, b := range append(
			globLanguageServers(filepath.Join(res, "bin")),
			globLanguageServers(filepath.Join(res, "app", "extensions", "antigravity", "bin"))...,
		) {
			if !seenBin[b] {
				seenBin[b] = true
				bins = append(bins, b)
			}
		}

		inst := Install{
			Kind:     KindDesktop,
			Root:     res,
			Binaries: bins,
		}
		if _, err := os.Stat(mainJS); err == nil {
			inst.MainJS = mainJS
			if _, err := os.Stat(extJS); err == nil {
				inst.ExtJS = extJS
			}
			if _, err := os.Stat(filepath.Join(res, "app", "extensions", "agy")); err == nil && len(bins) == 0 {
				inst.Kind = KindIDE26
			} else {
				inst.Kind = KindIDE
			}
		} else if _, err := os.Stat(asar); err == nil {
			inst.AsarPath = asar
		}
		if len(inst.Binaries) > 0 || inst.MainJS != "" {
			installs = append(installs, inst)
		}
	}

	// agy CLI / ~/.gemini/bin/agy (IDE 2.6+ и расширение VS Code)
	agyCandidates := []string{
		filepath.Join(home, ".gemini", "bin", "agy"),
		"/usr/local/bin/agy",
		"/usr/bin/agy",
		filepath.Join(home, ".local", "bin", "agy"),
		filepath.Join(home, "bin", "agy"),
	}
	if p, err := exec.LookPath("agy"); err == nil && p != "" {
		agyCandidates = append([]string{p}, agyCandidates...)
	}

	vsCodeExt := VSCodeExtensionInstalled(home)
	geminiBin := filepath.Join(home, ".gemini", "bin")
	for _, c := range agyCandidates {
		if _, err := os.Stat(c); err != nil {
			continue
		}
		rp := ResolvePath(c)
		if seenBin[rp] || !IsNativeBinary(rp) {
			continue
		}
		seenBin[rp] = true
		kind := KindCLI
		if strings.HasPrefix(rp, ResolvePath(geminiBin)) && vsCodeExt {
			kind = KindVSCode
		}
		installs = append(installs, Install{
			Kind:     kind,
			Root:     filepath.Dir(rp),
			Binaries: []string{rp},
		})
	}
	return installs
}

func rootFromBinary(p string) string {
	norm := filepath.ToSlash(p)
	if strings.Contains(norm, "/resources/app/extensions/antigravity/bin/") {
		return filepath.Dir(filepath.Dir(filepath.Dir(filepath.Dir(filepath.Dir(p)))))
	}
	return filepath.Dir(filepath.Dir(p))
}

func walkForInstalls(root string, maxDepth int, addRoot func(string)) {
	baseDepth := strings.Count(filepath.Clean(root), string(os.PathSeparator))
	_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return fs.SkipDir
		}
		if d.IsDir() {
			name := d.Name()
			if name == ".git" || name == "node_modules" || name == ".cache" || name == "proc" || name == "sys" {
				return fs.SkipDir
			}
			depth := strings.Count(filepath.Clean(p), string(os.PathSeparator)) - baseDepth
			if depth > maxDepth {
				return fs.SkipDir
			}
			return nil
		}
		norm := filepath.ToSlash(p)
		if strings.Contains(norm, "AppImage") {
			return nil
		}
		base := d.Name()
		if base == "main.js" && strings.HasSuffix(norm, "/resources/app/out/main.js") &&
			strings.Contains(strings.ToLower(norm), "antigravity") {
			addRoot(filepath.Dir(filepath.Dir(filepath.Dir(p))))
			return nil
		}
		if strings.HasPrefix(base, "language_server") &&
			(strings.Contains(strings.ToLower(norm), "antigravity") || strings.Contains(norm, "/resources/bin/")) &&
			IsNativeBinary(p) {
			addRoot(rootFromBinary(p))
		}
		return nil
	})
}
