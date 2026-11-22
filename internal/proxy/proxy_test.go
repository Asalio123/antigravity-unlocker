package proxy

import (
	"bufio"
	"context"
	"io"
	"net"
	"net/netip"
	"strings"
	"testing"
	"time"

	"github.com/Asalio123/antigravity-unlocker/internal/config"
)

func TestConnectProxyGateFailoverAndStatus(t *testing.T) {
	// Поднимаем локальный echo-бэкенд (имитирует живой SNI-прокси)
	backend, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer backend.Close()
	go func() {
		for {
			c, err := backend.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				_, _ = io.Copy(conn, conn)
			}(c)
		}
	}()
	backendAddr := backend.Addr().String()

	pool := NewPool(config.Settings{}, nil)
	// Первый кандидат — "мёртвый" (с меньшей латентностью), второй — "живой"
	deadIP := netip.MustParseAddr("198.51.100.1")
	liveIP := netip.MustParseAddr("198.51.100.2")
	pool.InjectForTest("daily-cloudcode-pa.googleapis.com", Endpoint{
		IP: deadIP, Reachable: true, Latency: 10 * time.Millisecond, CheckedAt: time.Now(),
	})
	pool.InjectForTest("daily-cloudcode-pa.googleapis.com", Endpoint{
		IP: liveIP, Reachable: true, Latency: 50 * time.Millisecond, CheckedAt: time.Now(),
	})

	srv := NewServer(pool, nil)
	srv.dialDirectOverride = func(ctx context.Context, addr string) (net.Conn, error) {
		if strings.HasPrefix(addr, deadIP.String()+":") {
			return nil, net.ErrClosed
		}
		return net.DialTimeout("tcp4", backendAddr, 2*time.Second)
	}

	listenAddr, err := srv.ListenAddr("127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = srv.Serve(ctx) }()

	// 1. Проверяем /_ag_unlocker/status
	st, err := FetchStatus(srv.Port())
	if err != nil {
		t.Fatalf("FetchStatus failed: %v", err)
	}
	if st.Service != "ag-unlocker" || len(st.Routes["daily-cloudcode-pa.googleapis.com"]) != 2 {
		t.Fatalf("unexpected status payload: %+v", st)
	}

	// 2. CONNECT к gate-хосту: мёртвый deadIP должен автоматически переключиться на liveIP
	conn, err := net.DialTimeout("tcp4", listenAddr, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_, _ = io.WriteString(conn, "CONNECT daily-cloudcode-pa.googleapis.com:443 HTTP/1.1\r\nHost: daily-cloudcode-pa.googleapis.com:443\r\n\r\n")
	br := bufio.NewReader(conn)
	statusLine, err := br.ReadString('\n')
	if err != nil || !strings.Contains(statusLine, "200 Connection Established") {
		t.Fatalf("unexpected CONNECT response: %q err=%v", statusLine, err)
	}
	_, _ = br.ReadString('\n') // пустая строка конца заголовков

	// Прогоняем данные через туннель
	msg := "hello-antigravity-tunnel"
	_, _ = io.WriteString(conn, msg)
	buf := make([]byte, len(msg))
	if _, err := io.ReadFull(br, buf); err != nil || string(buf) != msg {
		t.Fatalf("tunnel echo mismatch: got %q err=%v", string(buf), err)
	}

	// 3. Проверяем circuit breaker при 400: liveIP должен уйти в бан
	benchedIP, ok := pool.MarkRegion400("daily-cloudcode-pa.googleapis.com")
	if !ok || benchedIP != liveIP {
		t.Fatalf("expected liveIP to be benched on 400, got %v ok=%v", benchedIP, ok)
	}
	if cands := pool.Candidates("daily-cloudcode-pa.googleapis.com"); len(cands) != 0 {
		t.Fatalf("expected 0 usable candidates after dead+400, got %+v", cands)
	}
}
