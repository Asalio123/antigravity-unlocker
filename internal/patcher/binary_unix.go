//go:build !windows

package patcher

import (
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"syscall"
)

func writeBinaryAtomic(path string, data []byte) error {
	return writeFileTempRename(path, data)
}

func preserveOwnerOS(fi os.FileInfo, tmpName string) {
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		_ = os.Chown(tmpName, int(st.Uid), int(st.Gid))
	}
}

func postPatchBinaryOS(path string) error {
	if runtime.GOOS != "darwin" {
		return nil
	}
	// После изменения Mach-O подпись невалидна — переподписываем бинарь ad-hoc.
	_ = exec.Command("codesign", "--force", "--sign", "-", path).Run()
	return nil
}

// ResignBundle снимает карантин и переподписывает весь .app на macOS (на других ОС — no-op).
func ResignBundle(bundlePath string) error {
	if runtime.GOOS != "darwin" || bundlePath == "" || !strings.HasSuffix(bundlePath, ".app") {
		return nil
	}
	_ = exec.Command("xattr", "-dr", "com.apple.quarantine", bundlePath).Run()
	out, err := exec.Command("codesign", "--force", "--deep", "--sign", "-", bundlePath).CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if msg == "" {
			msg = err.Error()
		}
		return fmt.Errorf("codesign %s: %s (включи терминал в Системных настройках -> Конфиденциальность и безопасность -> Управление приложениями)", bundlePath, msg)
	}
	return nil
}
