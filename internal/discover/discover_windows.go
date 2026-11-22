//go:build windows

package discover

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func findAllOS() []Install {
	home, _ := os.UserHomeDir()
	localApp := os.Getenv("LOCALAPPDATA")
	progFiles := os.Getenv("ProgramFiles")
	progFilesX86 := os.Getenv("ProgramFiles(x86)")

	var roots []string
	if custom := strings.TrimSpace(os.Getenv("AG_ROOT")); custom != "" {
		roots = []string{custom}
	} else {
		roots = []string{
			filepath.Join(localApp, "Programs", "Antigravity"),
			filepath.Join(localApp, "Programs", "Antigravity IDE"),
			filepath.Join(localApp, "Antigravity"),
			filepath.Join(progFiles, "Antigravity"),
			filepath.Join(progFiles, "Antigravity IDE"),
			filepath.Join(progFilesX86, "Antigravity"),
		}
	}

	var installs []Install
	seenRoot := make(map[string]bool)
	seenBin := make(map[string]bool)

	for _, root := range roots {
		if root == "" {
			continue
		}
		res := root
		if fi, err := os.Stat(filepath.Join(root, "resources")); err == nil && fi.IsDir() {
			res = filepath.Join(root, "resources")
		} else if fi, err := os.Stat(root); err != nil || !fi.IsDir() {
			continue
		}
		rp := ResolvePath(res)
		if seenRoot[rp] {
			continue
		}
		seenRoot[rp] = true

		mainJS := filepath.Join(rp, "app", "out", "main.js")
		extJS := filepath.Join(rp, "app", "extensions", "antigravity", "dist", "extension.js")
		asar := filepath.Join(rp, "app.asar")

		var bins []string
		for _, b := range append(
			globLanguageServers(filepath.Join(rp, "bin")),
			globLanguageServers(filepath.Join(rp, "app", "extensions", "antigravity", "bin"))...,
		) {
			if !seenBin[b] {
				seenBin[b] = true
				bins = append(bins, b)
			}
		}

		inst := Install{
			Kind:     KindDesktop,
			Root:     rp,
			Binaries: bins,
		}
		if _, err := os.Stat(mainJS); err == nil {
			inst.MainJS = mainJS
			if _, err := os.Stat(extJS); err == nil {
				inst.ExtJS = extJS
			}
			if _, err := os.Stat(filepath.Join(rp, "app", "extensions", "agy")); err == nil && len(bins) == 0 {
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

	// agy.exe: %USERPROFILE%\.gemini\bin\agy.exe (IDE 2.6+ и VS Code) + PATH
	agyCandidates := []string{
		filepath.Join(home, ".gemini", "bin", "agy.exe"),
		filepath.Join(localApp, "Programs", "Antigravity CLI", "agy.exe"),
		filepath.Join(localApp, "Antigravity", "agy.exe"),
	}
	if p, err := exec.LookPath("agy.exe"); err == nil && p != "" {
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
		if strings.HasPrefix(strings.ToLower(rp), strings.ToLower(ResolvePath(geminiBin))) && vsCodeExt {
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
