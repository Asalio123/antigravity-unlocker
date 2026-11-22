//go:build darwin

package discover

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func findAllOS() []Install {
	home, _ := os.UserHomeDir()
	var installs []Install
	seenBin := make(map[string]bool)

	var appCandidates []string
	if custom := strings.TrimSpace(os.Getenv("AG_APP")); custom != "" {
		appCandidates = []string{custom}
	} else {
		appCandidates = []string{
			"/Applications/Antigravity.app",
			filepath.Join(home, "Applications", "Antigravity.app"),
			"/Applications/Antigravity IDE.app",
			filepath.Join(home, "Applications", "Antigravity IDE.app"),
		}
	}

	seenRoot := make(map[string]bool)
	for _, app := range appCandidates {
		fi, err := os.Stat(app)
		if err != nil || !fi.IsDir() {
			continue
		}
		rp := ResolvePath(app)
		if seenRoot[rp] {
			continue
		}
		seenRoot[rp] = true

		res := filepath.Join(rp, "Contents", "Resources")
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
			Kind:       KindDesktop,
			Root:       rp,
			BundlePath: rp,
			Binaries:   bins,
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
		installs = append(installs, inst)
	}

	// agy: ~/.gemini/bin/agy (бэкенд IDE 2.6+ и расширения VS Code/Cursor/Windsurf) + CLI из PATH
	agyCandidates := []string{
		filepath.Join(home, ".gemini", "bin", "agy"),
		"/opt/homebrew/bin/agy",
		"/usr/local/bin/agy",
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
