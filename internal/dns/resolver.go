package dns

import (
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Provider описывает один встроенный или пользовательский резолвер.
type Provider struct {
	Name   string
	Kind   string // "udp", "doh", "dot"
	Host   string // SNI / Host для DoH/DoT
	Path   string // путь для DoH (по умолчанию /dns-query)
	Addrs  []string
	HTTP2  bool
	Port   string // для DoT (по умолчанию 853)
}

// DefaultProviders — актуальный на 2026-11-22 живой пул (без мёртвых xbox-dns и comss.one).
var DefaultProviders = []Provider{
	{
		Name:  "eu.geohide.ru",
		Kind:  "udp",
		Addrs: []string{"31.25.239.132", "143.20.64.192", "5.175.161.3", "37.221.93.141"},
	},
	{
		Name:  "dns.geohide.ru",
		Kind:  "doh",
		Host:  "dns.geohide.ru",
		Path:  "/dns-query",
		Addrs: []string{"37.230.192.51", "45.155.204.190"},
	},
	{
		Name:  "dns.geohide.ru-udp",
		Kind:  "udp",
		Addrs: []string{"37.230.192.51"},
	},
	{
		Name:  "dns.dns-ai.ru",
		Kind:  "doh",
		Host:  "dns.dns-ai.ru",
		Path:  "/dns-query",
		Addrs: []string{"194.87.196.13", "45.151.102.219", "185.251.90.181"},
		HTTP2: true,
	},
}

var referenceServers = []string{"8.8.8.8", "1.1.1.1"}

var txSeq atomic.Uint32

func nextTxID() uint16 {
	return uint16(txSeq.Add(1)&0xFFFF) ^ 0x4A71
}

// ParseCustomProvider разбирает пользовательскую запись DNS:
//   - "1.2.3.4" -> UDP/TCP на 53 порт
//   - "https://dns.example.com/dns-query" -> DoH
//   - "tls://dns.example.com[:853]" -> DoT
func ParseCustomProvider(raw string) (Provider, error) {
	s := strings.TrimSpace(raw)
	if s == "" {
		return Provider{}, fmt.Errorf("пустой адрес DNS")
	}
	if strings.HasPrefix(s, "https://") {
		u, err := url.Parse(s)
		if err != nil || u.Hostname() == "" {
			return Provider{}, fmt.Errorf("некорректный DoH URL: %s", s)
		}
		path := u.RequestURI()
		if path == "" || path == "/" {
			path = "/dns-query"
		}
		return Provider{
			Name:  "custom:" + u.Hostname(),
			Kind:  "doh",
			Host:  u.Hostname(),
			Path:  path,
			Addrs: []string{u.Hostname()},
		}, nil
	}
	if strings.HasPrefix(s, "tls://") {
		rest := strings.TrimPrefix(s, "tls://")
		host, port, err := net.SplitHostPort(rest)
		if err != nil {
			host = rest
			port = "853"
		}
		if host == "" {
			return Provider{}, fmt.Errorf("некорректный DoT адрес: %s", s)
		}
		return Provider{
			Name:  "custom:" + host,
			Kind:  "dot",
			Host:  host,
			Port:  port,
			Addrs: []string{host},
		}, nil
	}
	if addr, err := netip.ParseAddr(s); err == nil && addr.Is4() {
		return Provider{
			Name:  "custom:" + s,
			Kind:  "udp",
			Addrs: []string{s},
		}, nil
	}
	return Provider{}, fmt.Errorf("ожидается IPv4, https://... (DoH) или tls://... (DoT): %s", s)
}

// IsNonProxyIP отсекает адреса, которые точно не могут быть анблок-прокси:
// эталонные /16, клиентские диапазоны Google AS15169, приватные, loopback, CGNAT, FakeIP 198.18/15.
func IsNonProxyIP(addr netip.Addr, refBlocks map[uint16]bool) bool {
	if !addr.Is4() {
		return true
	}
	b := addr.As4()
	net16 := uint16(b[0])<<8 | uint16(b[1])
	if refBlocks[net16] {
		return true
	}
	// Не-глобальные / служебные / FakeIP VPN
	if b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224 {
		return true
	}
	if b[0] == 169 && b[1] == 254 {
		return true
	}
	if b[0] == 192 && b[1] == 168 {
		return true
	}
	if b[0] == 172 && b[1] >= 16 && b[1] <= 31 {
		return true
	}
	if b[0] == 100 && b[1] >= 64 && b[1] <= 127 {
		return true
	}
	if b[0] == 198 && (b[1] == 18 || b[1] == 19) {
		return true
	}
	// Известные клиентские блоки Google (googleapis.com) — чтобы соседняя /16 не
	// притворялась прокси (например 142.251.* при эталоне 172.217.*).
	switch net16 {
	case 142<<8 | 250, 142<<8 | 251,
		172<<8 | 217, 172<<8 | 253,
		74<<8 | 125, 64<<8 | 233,
		108<<8 | 177, 209<<8 | 85,
		216<<8 | 58, 216<<8 | 239:
		return true
	}
	return false
}

// DiscoveryResult хранит найденные подменённые IP для одного домена.
type DiscoveryResult struct {
	Domain     string
	Candidates []netip.Addr
	Sources    map[string][]string // provider -> ips
}

// DiscoverSubstitutions опрашивает встроенные и пользовательские резолверы параллельно,
// сравнивает с эталоном (8.8.8.8 / 1.1.1.1) и возвращает чистый список прокси-кандидатов.
func DiscoverSubstitutions(ctx context.Context, domain string, custom []string, netInfo NetInfo) DiscoveryResult {
	res := DiscoveryResult{
		Domain:  domain,
		Sources: make(map[string][]string),
	}

	refBlocks := fetchRefNet16(ctx, domain)

	providers := make([]Provider, 0, len(DefaultProviders)+len(custom))
	providers = append(providers, DefaultProviders...)
	for _, raw := range custom {
		if p, err := ParseCustomProvider(raw); err == nil {
			providers = append(providers, p)
		}
	}

	var mu sync.Mutex
	seen := make(map[netip.Addr]bool)
	var wg sync.WaitGroup

	for _, prov := range providers {
		p := prov
		wg.Add(1)
		go func() {
			defer wg.Done()
			addrs := queryProvider(ctx, domain, p, netInfo)
			if len(addrs) == 0 {
				return
			}
			var sub []string
			mu.Lock()
			for _, a := range addrs {
				if IsNonProxyIP(a, refBlocks) {
					continue
				}
				sub = append(sub, a.String())
				if !seen[a] {
					seen[a] = true
					res.Candidates = append(res.Candidates, a)
				}
			}
			if len(sub) > 0 {
				sort.Strings(sub)
				res.Sources[p.Name] = sub
			}
			mu.Unlock()
		}()
	}
	wg.Wait()

	sort.Slice(res.Candidates, func(i, j int) bool {
		return res.Candidates[i].Less(res.Candidates[j])
	})
	return res
}

func fetchRefNet16(ctx context.Context, domain string) map[uint16]bool {
	blocks := make(map[uint16]bool)
	var mu sync.Mutex
	var wg sync.WaitGroup
	for _, srv := range referenceServers {
		s := srv
		wg.Add(1)
		go func() {
			defer wg.Done()
			addrs := queryUDPThenTCP(ctx, domain, s, NetInfo{}, false)
			if len(addrs) == 0 {
				// Fallback на DoH 1.1.1.1 / 8.8.8.8, если 53 порт закрыт полностью.
				addrs = queryDoHOne(ctx, domain, s, s, "/dns-query", false, NetInfo{}, false)
			}
			mu.Lock()
			for _, a := range addrs {
				if a.Is4() {
					b := a.As4()
					blocks[uint16(b[0])<<8|uint16(b[1])] = true
				}
			}
			mu.Unlock()
		}()
	}
	wg.Wait()
	return blocks
}

func queryProvider(ctx context.Context, domain string, p Provider, netInfo NetInfo) []netip.Addr {
	switch p.Kind {
	case "udp":
		for _, ip := range p.Addrs {
			// При активном VPN сначала пробуем мимо туннеля (чтобы сервис видел RU IP),
			// при сбое — через дефолтный маршрут (если физический интерфейс заблокирован).
			if netInfo.VPNActive && netInfo.PhysIndex > 0 {
				if addrs := queryUDPThenTCP(ctx, domain, ip, netInfo, true); len(addrs) > 0 {
					return addrs
				}
			}
			if addrs := queryUDPThenTCP(ctx, domain, ip, netInfo, false); len(addrs) > 0 {
				return addrs
			}
		}
	case "doh":
		for _, ip := range p.Addrs {
			if netInfo.VPNActive && netInfo.PhysIndex > 0 {
				if addrs := queryDoHOne(ctx, domain, p.Host, ip, p.Path, p.HTTP2, netInfo, true); len(addrs) > 0 {
					return addrs
				}
			}
			if addrs := queryDoHOne(ctx, domain, p.Host, ip, p.Path, p.HTTP2, netInfo, false); len(addrs) > 0 {
				return addrs
			}
		}
	case "dot":
		port := p.Port
		if port == "" {
			port = "853"
		}
		for _, ip := range p.Addrs {
			if netInfo.VPNActive && netInfo.PhysIndex > 0 {
				if addrs := queryDoTOne(ctx, domain, p.Host, ip, port, netInfo, true); len(addrs) > 0 {
					return addrs
				}
			}
			if addrs := queryDoTOne(ctx, domain, p.Host, ip, port, netInfo, false); len(addrs) > 0 {
				return addrs
			}
		}
	}
	return nil
}

func newDialer(timeout time.Duration, netInfo NetInfo, bindPhys bool) *net.Dialer {
	d := &net.Dialer{Timeout: timeout}
	if bindPhys {
		d.Control = BindDialerControl(netInfo)
	}
	return d
}

// queryUDPThenTCP шлёт DNS A-запрос по UDP/53 и мгновенно переключается на TCP/53 при таймауте
// (критично для VPN/корпоративных сетей, где UDP/53 режется, а TCP/53 отвечает).
func queryUDPThenTCP(ctx context.Context, domain, server string, netInfo NetInfo, bindPhys bool) []netip.Addr {
	wire, err := BuildAQuery(domain, nextTxID())
	if err != nil {
		return nil
	}
	target := net.JoinHostPort(server, "53")

	// 1. UDP/53
	uCtx, uCancel := context.WithTimeout(ctx, 1800*time.Millisecond)
	d := newDialer(1800*time.Millisecond, netInfo, bindPhys)
	conn, err := d.DialContext(uCtx, "udp4", target)
	uCancel()
	if err == nil {
		_ = conn.SetDeadline(time.Now().Add(1800 * time.Millisecond))
		if _, err = conn.Write(wire); err == nil {
			buf := make([]byte, 2048)
			if n, err := conn.Read(buf); err == nil && n >= 12 {
				_ = conn.Close()
				if addrs := ParseARecords(buf[:n]); len(addrs) > 0 {
					return addrs
				}
			}
		}
		_ = conn.Close()
	}

	// 2. TCP/53 fallback (2-byte length prefix по RFC 1035 §4.2.2)
	tCtx, tCancel := context.WithTimeout(ctx, 2500*time.Millisecond)
	defer tCancel()
	td := newDialer(2500*time.Millisecond, netInfo, bindPhys)
	tconn, err := td.DialContext(tCtx, "tcp4", target)
	if err != nil {
		return nil
	}
	defer tconn.Close()
	_ = tconn.SetDeadline(time.Now().Add(2500 * time.Millisecond))
	framed := make([]byte, 2+len(wire))
	binary.BigEndian.PutUint16(framed[0:2], uint16(len(wire)))
	copy(framed[2:], wire)
	if _, err := tconn.Write(framed); err != nil {
		return nil
	}
	var lenBuf [2]byte
	if _, err := io.ReadFull(tconn, lenBuf[:]); err != nil {
		return nil
	}
	respLen := int(binary.BigEndian.Uint16(lenBuf[:]))
	if respLen < 12 || respLen > 8192 {
		return nil
	}
	resp := make([]byte, respLen)
	if _, err := io.ReadFull(tconn, resp); err != nil {
		return nil
	}
	return ParseARecords(resp)
}

func queryDoHOne(ctx context.Context, domain, host, addr, path string, forceH2 bool, netInfo NetInfo, bindPhys bool) []netip.Addr {
	wire, err := BuildAQuery(domain, nextTxID())
	if err != nil {
		return nil
	}
	b64 := base64.RawURLEncoding.EncodeToString(wire)
	sep := "?"
	if strings.Contains(path, "?") {
		sep = "&"
	}
	reqURL := fmt.Sprintf("https://%s%s%sdns=%s", host, path, sep, b64)

	d := newDialer(2500*time.Millisecond, netInfo, bindPhys)
	tr := &http.Transport{
		ForceAttemptHTTP2:   true,
		TLSHandshakeTimeout: 2500 * time.Millisecond,
		TLSClientConfig: &tls.Config{
			ServerName: host,
			MinVersion: tls.VersionTLS12,
		},
		DialContext: func(c context.Context, network, _ string) (net.Conn, error) {
			return d.DialContext(c, "tcp4", net.JoinHostPort(addr, "443"))
		},
	}
	if !forceH2 {
		// Позволяем и h2, и http/1.1 через стандартный ALPN
		tr.ForceAttemptHTTP2 = true
	}
	defer tr.CloseIdleConnections()

	client := &http.Client{Transport: tr, Timeout: 3500 * time.Millisecond}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, reqURL, nil)
	if err != nil {
		return nil
	}
	req.Header.Set("Accept", "application/dns-message")

	resp, err := client.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 16384))
	if err != nil {
		return nil
	}
	return ParseARecords(body)
}

func queryDoTOne(ctx context.Context, domain, host, addr, port string, netInfo NetInfo, bindPhys bool) []netip.Addr {
	wire, err := BuildAQuery(domain, nextTxID())
	if err != nil {
		return nil
	}
	d := newDialer(2500*time.Millisecond, netInfo, bindPhys)
	tlsDialer := &tls.Dialer{
		NetDialer: d,
		Config: &tls.Config{
			ServerName: host,
			MinVersion: tls.VersionTLS12,
		},
	}
	tCtx, cancel := context.WithTimeout(ctx, 3500*time.Millisecond)
	defer cancel()
	conn, err := tlsDialer.DialContext(tCtx, "tcp4", net.JoinHostPort(addr, port))
	if err != nil {
		return nil
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(3 * time.Second))

	framed := make([]byte, 2+len(wire))
	binary.BigEndian.PutUint16(framed[0:2], uint16(len(wire)))
	copy(framed[2:], wire)
	if _, err := conn.Write(framed); err != nil {
		return nil
	}
	var lenBuf [2]byte
	if _, err := io.ReadFull(conn, lenBuf[:]); err != nil {
		return nil
	}
	respLen := int(binary.BigEndian.Uint16(lenBuf[:]))
	if respLen < 12 || respLen > 8192 {
		return nil
	}
	resp := make([]byte, respLen)
	if _, err := io.ReadFull(conn, resp); err != nil {
		return nil
	}
	return ParseARecords(resp)
}
