package proxy

import (
	"bufio"
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/Asalio123/antigravity-unlocker/internal/config"
	"github.com/Asalio123/antigravity-unlocker/internal/dns"
)

const (
	benchDuration = 30 * time.Minute
	refreshEvery  = 10 * time.Minute
)

// Endpoint — один проверенный SNI-прокси адрес для конкретного гейт-домена.
type Endpoint struct {
	IP          netip.Addr
	BindPhys    bool
	Latency     time.Duration
	Reachable   bool
	Proven      bool
	BenchedTill time.Time
	CheckedAt   time.Time
}

func (e *Endpoint) Benched(now time.Time) bool {
	return !e.BenchedTill.IsZero() && now.Before(e.BenchedTill)
}

func (e *Endpoint) Usable(now time.Time) bool {
	return e.Reachable && !e.Benched(now)
}

// EndpointView — публичный снимок маршрута для JSON-статуса и CLI.
type EndpointView struct {
	IP        string `json:"ip"`
	Via       string `json:"via"`
	LatencyMs int64  `json:"latency_ms"`
	Proven    bool   `json:"proven"`
	Benched   bool   `json:"benched"`
}

// Pool держит живые прокси-маршруты для всех гейт-доменов и обновляет их в фоне.
type Pool struct {
	mu        sync.RWMutex
	settings  config.Settings
	netInfo   dns.NetInfo
	hosts     map[string][]*Endpoint
	lastUsed  map[string]netip.Addr
	last400   time.Time
	lastOK    time.Time
	refreshed time.Time
	logf      func(string, ...any)
}

func NewPool(settings config.Settings, logf func(string, ...any)) *Pool {
	if logf == nil {
		logf = func(string, ...any) {}
	}
	return &Pool{
		settings: settings,
		hosts:    make(map[string][]*Endpoint),
		lastUsed: make(map[string]netip.Addr),
		logf:     logf,
	}
}

func (p *Pool) UpdateSettings(s config.Settings) {
	p.mu.Lock()
	p.settings = s
	p.mu.Unlock()
}

func (p *Pool) Settings() config.Settings {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.settings
}

func (p *Pool) NetInfo() dns.NetInfo {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.netInfo
}

// StartBackground запускает первичный прогрев и периодическое обновление пула.
func (p *Pool) StartBackground(ctx context.Context) {
	go func() {
		p.Refresh(ctx)
		t := time.NewTicker(refreshEvery)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				p.Refresh(ctx)
			}
		}
	}()
}

// Refresh опрашивает DNS/DoH-провайдеров и делает параллельные TLS+HTTP пробы кандидатов.
func (p *Pool) Refresh(ctx context.Context) {
	netInfo := dns.DetectNetwork()
	settings := p.Settings()

	p.mu.Lock()
	p.netInfo = netInfo
	p.mu.Unlock()

	if strings.TrimSpace(settings.UpstreamProxy) != "" {
		// При заданном upstream-прокси всё равно держим DNS-пул как резерв на случай падения upstream.
		p.logf("upstream proxy задан (%s); обновляю резервный DNS-пул", settings.UpstreamProxy)
	}

	discCtx, cancel := context.WithTimeout(ctx, 18*time.Second)
	defer cancel()

	// 1. Собираем DNS-подмены по всем гейт-доменам параллельно
	results := make(map[string][]netip.Addr)
	var rmu sync.Mutex
	var dwg sync.WaitGroup
	for _, host := range config.GateHosts {
		h := host
		dwg.Add(1)
		go func() {
			defer dwg.Done()
			r := dns.DiscoverSubstitutions(discCtx, h, settings.CustomDNS, netInfo)
			rmu.Lock()
			results[h] = r.Candidates
			rmu.Unlock()
		}()
	}
	dwg.Wait()

	// 2. Кросс-SNI: если для cloudcode-pa.googleapis.com не было прямой DNS-подмены,
	// проверяем живые SNI-прокси от daily-cloudcode-pa (geohide/eu.geohide их тоже проксируют).
	if len(results["cloudcode-pa.googleapis.com"]) == 0 && len(results["daily-cloudcode-pa.googleapis.com"]) > 0 {
		cp := append([]netip.Addr(nil), results["daily-cloudcode-pa.googleapis.com"]...)
		results["cloudcode-pa.googleapis.com"] = cp
	}

	// 3. Параллельные боевые TLS + HTTP-пробы для каждого (host, ip)
	probeCtx, pcancel := context.WithTimeout(ctx, 12*time.Second)
	defer pcancel()

	var pwg sync.WaitGroup
	for _, host := range config.GateHosts {
		h := host
		cands := results[h]
		for _, ip := range cands {
			candIP := ip
			pwg.Add(1)
			go func() {
				defer pwg.Done()
				ep := probeEndpoint(probeCtx, h, candIP, netInfo)
				p.upsertEndpoint(h, ep)
			}()
		}
	}
	pwg.Wait()

	p.mu.Lock()
	p.refreshed = time.Now()
	p.mu.Unlock()
}

func (p *Pool) upsertEndpoint(host string, probe Endpoint) {
	p.mu.Lock()
	defer p.mu.Unlock()
	list := p.hosts[host]
	for _, ex := range list {
		if ex.IP == probe.IP {
			ex.Reachable = probe.Reachable
			ex.BindPhys = probe.BindPhys
			if probe.Reachable {
				ex.Latency = probe.Latency
			}
			ex.CheckedAt = probe.CheckedAt
			return
		}
	}
	if probe.Reachable {
		ep := probe
		p.hosts[host] = append(list, &ep)
	}
}

// Candidates возвращает отсортированный список живых не-забаненных прокси для host.
func (p *Pool) Candidates(host string) []Endpoint {
	h := strings.ToLower(strings.TrimSuffix(host, "."))
	now := time.Now()
	p.mu.RLock()
	defer p.mu.RUnlock()

	list := p.hosts[h]
	if len(list) == 0 {
		// Если для конкретного хоста пусто, пробуем пул daily-cloudcode-pa
		list = p.hosts["daily-cloudcode-pa.googleapis.com"]
	}
	out := make([]Endpoint, 0, len(list))
	for _, ep := range list {
		if ep.Usable(now) {
			out = append(out, *ep)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Proven != out[j].Proven {
			return out[i].Proven
		}
		return out[i].Latency < out[j].Latency
	})
	return out
}

// InjectForTest добавляет тестовый маршрут напрямую (используется в юнит-тестах).
func (p *Pool) InjectForTest(host string, ep Endpoint) {
	p.upsertEndpoint(strings.ToLower(host), ep)
}

func (p *Pool) NoteActive(host string, ip netip.Addr) {
	h := strings.ToLower(strings.TrimSuffix(host, "."))
	p.mu.Lock()
	p.lastUsed[h] = ip
	p.mu.Unlock()
}

// MarkDialFailed помечает IP недоступным после реального сбоя TCP-соединения.
func (p *Pool) MarkDialFailed(host string, ip netip.Addr) {
	h := strings.ToLower(strings.TrimSuffix(host, "."))
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, ep := range p.hosts[h] {
		if ep.IP == ip {
			ep.Reachable = false
			ep.Proven = false
			break
		}
	}
}

// MarkRegion400 банит на 30 минут IP, через который пришёл серверный HTTP 400.
func (p *Pool) MarkRegion400(host string) (netip.Addr, bool) {
	now := time.Now()
	p.mu.Lock()
	defer p.mu.Unlock()
	p.last400 = now
	if host == "" {
		host = "daily-cloudcode-pa.googleapis.com"
	}
	h := strings.ToLower(host)
	ip, ok := p.lastUsed[h]
	if !ok {
		return netip.Addr{}, false
	}
	for _, list := range p.hosts {
		for _, ep := range list {
			if ep.IP == ip {
				ep.BenchedTill = now.Add(benchDuration)
				ep.Proven = false
			}
		}
	}
	return ip, true
}

// MarkModelOK фиксирует живой ответ модели и помечает активный IP как проверенный.
func (p *Pool) MarkModelOK(host string) {
	now := time.Now()
	p.mu.Lock()
	defer p.mu.Unlock()
	p.lastOK = now
	if host == "" {
		host = "daily-cloudcode-pa.googleapis.com"
	}
	if ip, ok := p.lastUsed[strings.ToLower(host)]; ok {
		for _, ep := range p.hosts[strings.ToLower(host)] {
			if ep.IP == ip {
				ep.Proven = true
				ep.BenchedTill = time.Time{}
				ep.Reachable = true
			}
		}
	}
}

func (p *Pool) Snapshot() (routes map[string][]EndpointView, last400, lastOK, refreshed time.Time) {
	now := time.Now()
	p.mu.RLock()
	defer p.mu.RUnlock()

	routes = make(map[string][]EndpointView, len(p.hosts))
	for host, list := range p.hosts {
		views := make([]EndpointView, 0, len(list))
		sorted := append([]*Endpoint(nil), list...)
		sort.Slice(sorted, func(i, j int) bool {
			bi, bj := sorted[i].Benched(now), sorted[j].Benched(now)
			if bi != bj {
				return !bi
			}
			if sorted[i].Proven != sorted[j].Proven {
				return sorted[i].Proven
			}
			return sorted[i].Latency < sorted[j].Latency
		})
		for _, ep := range sorted {
			if !ep.Reachable && !ep.Benched(now) {
				continue
			}
			via := "default"
			if ep.BindPhys {
				via = "phys:" + p.netInfo.PhysIface
			}
			views = append(views, EndpointView{
				IP:        ep.IP.String(),
				Via:       via,
				LatencyMs: ep.Latency.Milliseconds(),
				Proven:    ep.Proven,
				Benched:   ep.Benched(now),
			})
		}
		if len(views) > 0 {
			routes[host] = views
		}
	}
	return routes, p.last400, p.lastOK, p.refreshed
}

// probeEndpoint проверяет реальный TLS-хендшейк с сертификатом Google + HTTP-ответ.
// Сначала проверяет дефолтный маршрут (работает и без VPN, и через VPN, если ТСПУ режет en0),
// а при сбое под VPN — пробует привязку к физическому интерфейсу.
func probeEndpoint(ctx context.Context, host string, ip netip.Addr, netInfo dns.NetInfo) Endpoint {
	ep := Endpoint{IP: ip, CheckedAt: time.Now()}
	if lat, ok := probeOnce(ctx, host, ip, netInfo, false); ok {
		ep.Reachable = true
		ep.BindPhys = false
		ep.Latency = lat
		return ep
	}
	if netInfo.VPNActive && netInfo.PhysIndex > 0 {
		if lat, ok := probeOnce(ctx, host, ip, netInfo, true); ok {
			ep.Reachable = true
			ep.BindPhys = true
			ep.Latency = lat
			return ep
		}
	}
	return ep
}

func probeOnce(ctx context.Context, host string, ip netip.Addr, netInfo dns.NetInfo, bindPhys bool) (time.Duration, bool) {
	start := time.Now()
	d := &net.Dialer{Timeout: 3 * time.Second}
	if bindPhys {
		d.Control = dns.BindDialerControl(netInfo)
	}
	pCtx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()

	rawConn, err := d.DialContext(pCtx, "tcp4", net.JoinHostPort(ip.String(), "443"))
	if err != nil {
		return 0, false
	}
	tlsConn := tls.Client(rawConn, &tls.Config{
		ServerName: host,
		MinVersion: tls.VersionTLS12,
		NextProtos: []string{"http/1.1"},
	})
	defer tlsConn.Close()
	_ = tlsConn.SetDeadline(time.Now().Add(4 * time.Second))
	if err := tlsConn.HandshakeContext(pCtx); err != nil {
		return 0, false
	}

	req := fmt.Sprintf("GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n", host)
	if _, err := tlsConn.Write([]byte(req)); err != nil {
		return 0, false
	}
	resp, err := http.ReadResponse(bufio.NewReader(tlsConn), &http.Request{Method: http.MethodGet})
	if err != nil {
		return 0, false
	}
	_ = resp.Body.Close()

	// Валидный TLS-сертификат Google уже проверен; 2xx/3xx/4xx подтверждают живой прокси до ESF.
	if resp.StatusCode >= 200 && resp.StatusCode < 500 {
		return time.Since(start), true
	}
	return 0, false
}
