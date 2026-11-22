package proxy

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/Asalio123/antigravity-unlocker/internal/config"
	"github.com/Asalio123/antigravity-unlocker/internal/dns"
)

const StatusPath = "/_ag_unlocker/status"

// StatusPayload отдаётся по GET http://127.0.0.1:<port>/_ag_unlocker/status.
type StatusPayload struct {
	Service   string                    `json:"service"`
	Version   string                    `json:"version"`
	PID       int                       `json:"pid"`
	Port      int                       `json:"port"`
	UptimeSec int64                     `json:"uptime_sec"`
	VPNActive bool                      `json:"vpn_active"`
	PhysIface string                    `json:"phys_iface,omitempty"`
	Upstream  string                    `json:"upstream,omitempty"`
	CustomDNS []string                  `json:"custom_dns,omitempty"`
	Routes    map[string][]EndpointView `json:"routes"`
	Last400   string                    `json:"last_400,omitempty"`
	LastOK    string                    `json:"last_ok,omitempty"`
	Refreshed string                    `json:"refreshed,omitempty"`
}

// Server — локальный loopback HTTP CONNECT прокси без подмены TLS/CA.
type Server struct {
	pool      *Pool
	startedAt time.Time
	port      int
	ln        net.Listener
	logf      func(string, ...any)

	dialDirectOverride func(ctx context.Context, addr string) (net.Conn, error)
}

func NewServer(pool *Pool, logf func(string, ...any)) *Server {
	if logf == nil {
		logf = func(string, ...any) {}
	}
	return &Server{
		pool:      pool,
		startedAt: time.Now(),
		logf:      logf,
	}
}

// Listen привязывает 127.0.0.1 на первый свободный порт (preferred -> DefaultPort -> FallbackPorts).
func (s *Server) Listen(preferred int) (int, error) {
	ports := make([]int, 0, 2+len(config.FallbackPorts))
	if preferred > 0 && preferred < 65536 {
		ports = append(ports, preferred)
	}
	ports = append(ports, config.DefaultPort)
	ports = append(ports, config.FallbackPorts...)

	seen := make(map[int]bool)
	var lastErr error
	for _, port := range ports {
		if seen[port] {
			continue
		}
		seen[port] = true
		ln, err := net.Listen("tcp4", net.JoinHostPort(config.ListenIP, strconv.Itoa(port)))
		if err == nil {
			s.ln = ln
			s.port = port
			return port, nil
		}
		lastErr = err
	}
	return 0, fmt.Errorf("не удалось занять порт на 127.0.0.1: %w", lastErr)
}

// ListenAddr используется в тестах (например "127.0.0.1:0").
func (s *Server) ListenAddr(addr string) (string, error) {
	ln, err := net.Listen("tcp4", addr)
	if err != nil {
		return "", err
	}
	s.ln = ln
	if ta, ok := ln.Addr().(*net.TCPAddr); ok {
		s.port = ta.Port
	}
	return ln.Addr().String(), nil
}

func (s *Server) Port() int { return s.port }

func (s *Server) Serve(ctx context.Context) error {
	if s.ln == nil {
		return errors.New("listener not initialized")
	}
	go func() {
		<-ctx.Done()
		_ = s.ln.Close()
	}()
	for {
		conn, err := s.ln.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return nil
			}
			continue
		}
		go s.handleConn(ctx, conn)
	}
}

func (s *Server) Close() error {
	if s.ln != nil {
		return s.ln.Close()
	}
	return nil
}

func (s *Server) handleConn(ctx context.Context, client net.Conn) {
	defer client.Close()
	_ = client.SetReadDeadline(time.Now().Add(30 * time.Second))

	br := bufio.NewReader(client)
	req, err := http.ReadRequest(br)
	if err != nil {
		return
	}
	_ = client.SetReadDeadline(time.Time{})

	if req.Method == http.MethodGet && req.URL.Path == StatusPath {
		s.writeStatusJSON(client)
		return
	}
	if req.Method != http.MethodConnect {
		_, _ = io.WriteString(client, "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
		return
	}

	host, port, err := net.SplitHostPort(req.Host)
	if err != nil {
		host = req.Host
		port = "443"
	}

	upstreamConn, err := s.dialTarget(ctx, host, port)
	if err != nil {
		s.logf("CONNECT %s:%s -> ошибка: %v", host, port, err)
		_, _ = io.WriteString(client, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
		return
	}
	defer upstreamConn.Close()

	if _, err := io.WriteString(client, "HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
		return
	}

	// Если в буфере bufio уже остались первые байты ClientHello — досылаем их в upstream.
	if n := br.Buffered(); n > 0 {
		if peek, err := br.Peek(n); err == nil {
			if _, err := upstreamConn.Write(peek); err != nil {
				return
			}
			_, _ = br.Discard(n)
		}
	}

	splice(client, upstreamConn)
}

func (s *Server) dialTarget(ctx context.Context, host, port string) (net.Conn, error) {
	if !config.IsGateHost(host) {
		return s.dialDirect(ctx, net.JoinHostPort(host, port))
	}

	settings := s.pool.Settings()
	// 1. Пользовательский upstream-прокси (если настроен)
	if up := strings.TrimSpace(settings.UpstreamProxy); up != "" {
		conn, err := DialUpstream(ctx, up, host, port)
		if err == nil {
			return conn, nil
		}
		s.logf("upstream %s не ответил для %s: %v — пробую DNS-пул", up, host, err)
	}

	// 2. Бесплатный пул проверенных SNI-прокси с мгновенным failover до 3 кандидатов
	cands := s.pool.Candidates(host)
	netInfo := s.pool.NetInfo()
	tried := 0
	for _, ep := range cands {
		if tried >= 3 {
			break
		}
		tried++
		conn, err := s.dialEndpoint(ctx, ep, port, netInfo)
		if err == nil {
			s.pool.NoteActive(host, ep.IP)
			return conn, nil
		}
		s.pool.MarkDialFailed(host, ep.IP)
		s.logf("SNI-прокси %s для %s недоступен (%v), пробую следующий", ep.IP, host, err)
	}

	// 3. Последний fallback — прямой коннект (не ломает работу при чистом VPN или за границей)
	return s.dialDirect(ctx, net.JoinHostPort(host, port))
}

func (s *Server) dialEndpoint(ctx context.Context, ep Endpoint, port string, netInfo dns.NetInfo) (net.Conn, error) {
	addr := net.JoinHostPort(ep.IP.String(), port)
	if s.dialDirectOverride != nil {
		return s.dialDirectOverride(ctx, addr)
	}
	d := &net.Dialer{Timeout: 5 * time.Second, KeepAlive: 30 * time.Second}
	if ep.BindPhys {
		d.Control = dns.BindDialerControl(netInfo)
	}
	return d.DialContext(ctx, "tcp4", addr)
}

func (s *Server) dialDirect(ctx context.Context, addr string) (net.Conn, error) {
	if s.dialDirectOverride != nil {
		return s.dialDirectOverride(ctx, addr)
	}
	d := &net.Dialer{Timeout: 8 * time.Second, KeepAlive: 30 * time.Second}
	return d.DialContext(ctx, "tcp", addr)
}

func (s *Server) writeStatusJSON(w io.Writer) {
	routes, last400, lastOK, refreshed := s.pool.Snapshot()
	settings := s.pool.Settings()
	netInfo := s.pool.NetInfo()
	payload := StatusPayload{
		Service:   "ag-unlocker",
		Version:   config.Version,
		PID:       os.Getpid(),
		Port:      s.port,
		UptimeSec: int64(time.Since(s.startedAt).Seconds()),
		VPNActive: netInfo.VPNActive,
		PhysIface: netInfo.PhysIface,
		Upstream:  settings.UpstreamProxy,
		CustomDNS: settings.CustomDNS,
		Routes:    routes,
	}
	if !last400.IsZero() {
		payload.Last400 = last400.Format(time.RFC3339)
	}
	if !lastOK.IsZero() {
		payload.LastOK = lastOK.Format(time.RFC3339)
	}
	if !refreshed.IsZero() {
		payload.Refreshed = refreshed.Format(time.RFC3339)
	}
	body, _ := json.Marshal(payload)
	resp := fmt.Sprintf("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", len(body))
	_, _ = io.WriteString(w, resp)
	_, _ = w.Write(body)
}

type closeWriter interface {
	CloseWrite() error
}

func splice(a, b net.Conn) {
	var wg sync.WaitGroup
	wg.Add(2)
	pipe := func(dst, src net.Conn) {
		defer wg.Done()
		_, _ = io.Copy(dst, src)
		if cw, ok := dst.(closeWriter); ok {
			_ = cw.CloseWrite()
		}
	}
	go pipe(a, b)
	go pipe(b, a)
	wg.Wait()
}

// FetchStatus опрашивает локальный прокси и проверяет, что на порту именно наш ag-unlocker.
func FetchStatus(port int) (*StatusPayload, error) {
	if port <= 0 {
		return nil, errors.New("invalid port")
	}
	client := &http.Client{Timeout: 1200 * time.Millisecond}
	resp, err := client.Get(fmt.Sprintf("http://%s:%d%s", config.ListenIP, port, StatusPath))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %s", resp.Status)
	}
	var st StatusPayload
	if err := json.NewDecoder(resp.Body).Decode(&st); err != nil {
		return nil, err
	}
	if st.Service != "ag-unlocker" {
		return nil, errors.New("foreign service on port")
	}
	return &st, nil
}
