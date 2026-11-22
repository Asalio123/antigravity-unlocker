package proxy

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

// WatchLanguageServerLogs читает хвост лога Antigravity и в реальном времени:
//   - при "User location is not supported" банит активный прокси-IP (авто-ротация);
//   - при успешном streamGenerateContent/ResponseID помечает текущий IP проверенным.
func WatchLanguageServerLogs(ctx context.Context, pool *Pool, logf func(string, ...any)) {
	if logf == nil {
		logf = func(string, ...any) {}
	}
	go func() {
		offsets := make(map[string]int64)
		ticker := time.NewTicker(3 * time.Second)
		defer ticker.Stop()

		// Инициализируем смещения в конец существующих логов, чтобы не срабатывать на старых 400.
		for _, p := range candidateLSLogs() {
			if fi, err := os.Stat(p); err == nil {
				offsets[p] = fi.Size()
			}
		}

		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				for _, p := range candidateLSLogs() {
					fi, err := os.Stat(p)
					if err != nil || fi.IsDir() {
						continue
					}
					off, known := offsets[p]
					if !known || fi.Size() < off {
						off = 0
					}
					if fi.Size() == off {
						continue
					}
					chunk := readTailChunk(p, off, 64*1024)
					offsets[p] = fi.Size()
					if chunk == "" {
						continue
					}
					if strings.Contains(chunk, "User location is not supported") {
						if ip, ok := pool.MarkRegion400("daily-cloudcode-pa.googleapis.com"); ok {
							logf("обнаружен HTTP 400 region gate — прокси %s отправлен в бан на 30м, переключаюсь на следующий", ip)
						}
					} else if strings.Contains(chunk, "streamGenerateContent") && strings.Contains(chunk, "ResponseID:") {
						pool.MarkModelOK("daily-cloudcode-pa.googleapis.com")
					}
				}
			}
		}
	}()
}

func readTailChunk(path string, offset int64, maxBytes int64) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	if _, err := f.Seek(offset, io.SeekStart); err != nil {
		return ""
	}
	data, err := io.ReadAll(io.LimitReader(f, maxBytes))
	if err != nil {
		return ""
	}
	return string(data)
}

func candidateLSLogs() []string {
	home, _ := os.UserHomeDir()
	var out []string
	switch runtime.GOOS {
	case "darwin":
		out = append(out, filepath.Join(home, "Library", "Logs", "Antigravity", "language_server.log"))
	case "windows":
		if appdata := os.Getenv("APPDATA"); appdata != "" {
			out = append(out, filepath.Join(appdata, "Antigravity", "logs", "language_server.log"))
		}
		if local := os.Getenv("LOCALAPPDATA"); local != "" {
			out = append(out, filepath.Join(local, "Antigravity", "logs", "language_server.log"))
		}
	default:
		out = append(out,
			filepath.Join(home, ".config", "Antigravity", "logs", "language_server.log"),
			filepath.Join(home, ".local", "state", "Antigravity", "language_server.log"),
		)
	}
	return out
}
