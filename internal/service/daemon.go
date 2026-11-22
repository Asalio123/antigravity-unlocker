package service

import (
	"context"
	"io"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"syscall"
	"time"

	"github.com/Asalio123/antigravity-unlocker/internal/config"
	"github.com/Asalio123/antigravity-unlocker/internal/discover"
	"github.com/Asalio123/antigravity-unlocker/internal/env"
	"github.com/Asalio123/antigravity-unlocker/internal/patcher"
	"github.com/Asalio123/antigravity-unlocker/internal/proxy"
)

// InstalledBinaryPath возвращает стабильный путь к копии бинаря в пользовательском DataDir,
// чтобы автозапуск не ломался после очистки папки Загрузки.
func InstalledBinaryPath() string {
	name := "ag-unlocker"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	return filepath.Join(config.DataDir(), "bin", name)
}

// EnsureInstalledBinary копирует текущий исполняемый файл в DataDir/bin (если запущен не оттуда).
func EnsureInstalledBinary() (string, error) {
	dst := InstalledBinaryPath()
	self, err := os.Executable()
	if err != nil {
		return "", err
	}
	selfReal := discover.ResolvePath(self)
	dstReal := discover.ResolvePath(dst)
	if selfReal == dstReal {
		return dst, nil
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return "", err
	}
	if err := copyFileAtomic(selfReal, dst); err != nil {
		return "", err
	}
	return dst, nil
}

func copyFileAtomic(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	tmp, err := os.CreateTemp(filepath.Dir(dst), ".ag-bin.*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	if _, err := io.Copy(tmp, in); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpName)
		return err
	}
	if err := tmp.Chmod(0o755); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpName)
		return err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpName)
		return err
	}
	if err := os.Rename(tmpName, dst); err != nil {
		// На Windows старый демон может держать файл — пробуем переписать поверх только если не занят.
		_ = os.Remove(tmpName)
		return err
	}
	return nil
}

// WaitForRunning ждёт поднятия нашего локального прокси и возвращает его порт.
func WaitForRunning(timeout time.Duration) (*proxy.StatusPayload, bool) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		p := config.ActivePort()
		if st, err := proxy.FetchStatus(p); err == nil {
			return st, true
		}
		time.Sleep(200 * time.Millisecond)
	}
	return nil, false
}

// RunDaemon запускает основной фоновый цикл: локальный прокси + лог-вотчер + авто-репатч watchdog.
func RunDaemon() error {
	if err := os.MkdirAll(config.DataDir(), 0o755); err != nil {
		return err
	}
	logFile := openDaemonLog()
	defer func() {
		if logFile != nil {
			_ = logFile.Close()
		}
	}()
	logger := log.New(io.MultiWriter(os.Stderr, logFile), "", log.LstdFlags)
	logf := func(format string, args ...any) {
		logger.Printf(format, args...)
	}

	_ = os.WriteFile(config.PIDFilePath(), []byte(strconv.Itoa(os.Getpid())+"\n"), 0o644)
	defer os.Remove(config.PIDFilePath())

	settings := config.LoadSettings()
	pool := proxy.NewPool(settings, logf)
	srv := proxy.NewServer(pool, logf)

	port, err := srv.Listen(settings.PreferredPort)
	if err != nil {
		logf("ошибка запуска прокси: %v", err)
		return err
	}
	_ = config.WriteActivePort(port)
	proxyURL := config.ProxyURL(port)
	if os.Getenv("AG_NO_ENV") == "" && env.GetProxyEnv() != proxyURL {
		_ = env.SetProxyEnv(proxyURL)
	}

	logf("ag-unlocker v%s daemon запущен (pid=%d, listen=%s:%d)", config.Version, os.Getpid(), config.ListenIP, port)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	pool.StartBackground(ctx)
	proxy.WatchLanguageServerLogs(ctx, pool, logf)
	go watchSettingsLoop(ctx, pool, logf)
	go watchRepatchLoop(ctx, logf)

	err = srv.Serve(ctx)
	logf("ag-unlocker daemon остановлен")
	return err
}

func openDaemonLog() *os.File {
	p := config.LogFilePath()
	// Простая ротация: если лог разросся больше 2 МБ — обрезаем.
	if fi, err := os.Stat(p); err == nil && fi.Size() > 2*1024*1024 {
		_ = os.Truncate(p, 0)
	}
	f, err := os.OpenFile(p, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return nil
	}
	return f
}

func watchSettingsLoop(ctx context.Context, pool *proxy.Pool, logf func(string, ...any)) {
	var lastMod time.Time
	if fi, err := os.Stat(config.SettingsPath()); err == nil {
		lastMod = fi.ModTime()
	}
	t := time.NewTicker(5 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			fi, err := os.Stat(config.SettingsPath())
			if err != nil {
				continue
			}
			if !fi.ModTime().Equal(lastMod) {
				lastMod = fi.ModTime()
				pool.UpdateSettings(config.LoadSettings())
				logf("settings.json обновлён — пересобираю маршруты")
				go pool.Refresh(ctx)
			}
		}
	}
}

type fileSig struct {
	size int64
	mod  int64
}

type watchEntry struct {
	sig     fileSig
	pending bool
}

// watchRepatchLoop следит за файлами Antigravity и авто-репатчит их через ~6 сек
// после автообновления (settle = 2 одинаковых тика подряд).
func watchRepatchLoop(ctx context.Context, logf func(string, ...any)) {
	state := make(map[string]watchEntry)
	t := time.NewTicker(3 * time.Second)
	defer t.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if _, err := os.Stat(config.DeclinePath()); err == nil {
				continue
			}
			installs := discover.FindAll()
			for _, inst := range installs {
				bundleTouched := false
				for _, bin := range inst.Binaries {
					if checkSettle(state, bin) {
						res, err := patcher.PatchBinary(bin, true)
						if err != nil {
							logf("watchdog: не удалось пропатчить %s: %v", bin, err)
						} else if res.Status == patcher.StatusPatched {
							logf("watchdog: авто-репатч %s (ineligible=%d, proxy=%d)", bin, res.EligibilityHits, res.ProxyHits)
							bundleTouched = true
						} else if res.Status == patcher.StatusUnknownBuild {
							logf("watchdog: %s — неизвестная сборка, не трогаю до смены файла", bin)
						}
						markDone(state, bin)
					}
				}
				if inst.MainJS != "" && checkSettle(state, inst.MainJS) {
					st, err := patcher.PatchIDEMain(inst.MainJS)
					if err != nil {
						logf("watchdog: IDE main.js ошибка: %v", err)
					} else if st == patcher.StatusPatched {
						logf("watchdog: авто-репатч IDE main.js: %s", inst.MainJS)
						bundleTouched = true
					}
					markDone(state, inst.MainJS)
				}
				if inst.ExtJS != "" && checkSettle(state, inst.ExtJS) {
					if st, err := patcher.PatchIDEExt(inst.ExtJS); err == nil && st == patcher.StatusPatched {
						logf("watchdog: авто-репатч IDE extension.js: %s", inst.ExtJS)
						bundleTouched = true
					}
					markDone(state, inst.ExtJS)
				}
				if bundleTouched && inst.BundlePath != "" {
					if err := patcher.ResignBundle(inst.BundlePath); err != nil {
						logf("watchdog: переподпись %s: %v", inst.BundlePath, err)
					} else {
						logf("watchdog: бандл переподписан: %s", inst.BundlePath)
					}
				}
			}
		}
	}
}

func currentSig(path string) (fileSig, bool) {
	fi, err := os.Stat(path)
	if err != nil {
		return fileSig{}, false
	}
	return fileSig{size: fi.Size(), mod: fi.ModTime().UnixNano()}, true
}

func checkSettle(state map[string]watchEntry, path string) bool {
	cur, ok := currentSig(path)
	if !ok {
		return false
	}
	prev, exists := state[path]
	if !exists || prev.sig != cur {
		state[path] = watchEntry{sig: cur, pending: true}
		return false
	}
	return prev.pending
}

func markDone(state map[string]watchEntry, path string) {
	if cur, ok := currentSig(path); ok {
		state[path] = watchEntry{sig: cur, pending: false}
	}
}
