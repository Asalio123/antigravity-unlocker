//go:build windows

package patcher

import (
	"errors"
	"os"
	"syscall"
	"time"

	"github.com/Asalio123/antigravity-unlocker/internal/proc"
)

const (
	errSharingViolation = syscall.Errno(32)
	errLockViolation    = syscall.Errno(33)
)

func writeBinaryAtomic(path string, data []byte) error {
	err := writeFileTempRename(path, data)
	if err == nil {
		return nil
	}
	// На Windows запущенный .exe заблокирован — останавливаем Antigravity и повторяем запись.
	var errno syscall.Errno
	if errors.As(err, &errno) && (errno == errSharingViolation || errno == errLockViolation) {
		proc.StopAntigravity()
		time.Sleep(400 * time.Millisecond)
		return writeFileTempRename(path, data)
	}
	return err
}

func preserveOwnerOS(_ os.FileInfo, _ string) {}
func postPatchBinaryOS(_ string) error        { return nil }
func ResignBundle(_ string) error             { return nil }
