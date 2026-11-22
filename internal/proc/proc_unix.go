//go:build !windows

package proc

import (
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// StopAntigravity аккуратно завершает процессы Antigravity, language_server и agy,
// гарантированно не трогая текущий процесс ag-unlocker и его родителя.
func StopAntigravity() {
	self := os.Getpid()
	ppid := os.Getppid()

	if runtime.GOOS == "darwin" {
		killMatchingPS(self, ppid, func(cmd string) bool {
			if strings.Contains(cmd, "ag-unlocker") || strings.Contains(cmd, "ag_unlocker") {
				return false
			}
			return strings.Contains(cmd, "/Antigravity.app/") ||
				strings.Contains(cmd, "/Antigravity IDE.app/") ||
				strings.Contains(cmd, "language_server") ||
				isAgyCommand(cmd)
		})
	} else {
		killMatchingPS(self, ppid, func(cmd string) bool {
			low := strings.ToLower(cmd)
			if strings.Contains(low, "ag-unlocker") || strings.Contains(low, "ag_unlocker") {
				return false
			}
			return strings.Contains(low, "language_server") ||
				strings.Contains(low, "/antigravity") ||
				isAgyCommand(cmd)
		})
	}
	time.Sleep(600 * time.Millisecond)
}

func isAgyCommand(cmd string) bool {
	fields := strings.Fields(cmd)
	if len(fields) == 0 {
		return false
	}
	bin := fields[0]
	return bin == "agy" || strings.HasSuffix(bin, "/agy")
}

func killMatchingPS(self, ppid int, match func(string) bool) {
	out, err := exec.Command("ps", "-eo", "pid=,command=").Output()
	if err != nil {
		return
	}
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		sp := strings.IndexAny(line, " \t")
		if sp <= 0 {
			continue
		}
		pid, err := strconv.Atoi(strings.TrimSpace(line[:sp]))
		if err != nil || pid <= 1 || pid == self || pid == ppid {
			continue
		}
		cmd := strings.TrimSpace(line[sp:])
		if match(cmd) {
			_ = syscall.Kill(pid, syscall.SIGTERM)
		}
	}
}
