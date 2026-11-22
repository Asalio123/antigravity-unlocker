package dns

import (
	"net/netip"
	"testing"
)

func TestWireBuildAndParse(t *testing.T) {
	q, err := BuildAQuery("daily-cloudcode-pa.googleapis.com", 0x1234)
	if err != nil {
		t.Fatalf("BuildAQuery failed: %v", err)
	}
	// Собираем валидный DNS-ответ с compression pointer 0xC00C и двумя A-записями
	resp := append([]byte(nil), q...)
	resp[2] = 0x81 // QR=1, RD=1
	resp[3] = 0x80 // RA=1
	resp[7] = 0x02 // ANCOUNT=2
	// Answer 1: pointer to 12, A, IN, TTL=60, 31.25.239.132
	resp = append(resp,
		0xC0, 0x0C,
		0x00, 0x01, 0x00, 0x01,
		0x00, 0x00, 0x00, 0x3C,
		0x00, 0x04,
		31, 25, 239, 132,
	)
	// Answer 2: pointer to 12, A, IN, TTL=60, 143.20.64.192
	resp = append(resp,
		0xC0, 0x0C,
		0x00, 0x01, 0x00, 0x01,
		0x00, 0x00, 0x00, 0x3C,
		0x00, 0x04,
		143, 20, 64, 192,
	)

	got := ParseARecords(resp)
	if len(got) != 2 || got[0].String() != "31.25.239.132" || got[1].String() != "143.20.64.192" {
		t.Fatalf("unexpected parsed records: %v", got)
	}

	// Обрезанный пакет не должен паниковать
	if bad := ParseARecords(resp[:15]); len(bad) != 0 {
		t.Fatalf("expected empty on truncated packet, got %v", bad)
	}
}

func TestIsNonProxyIP(t *testing.T) {
	ref := map[uint16]bool{172<<8 | 217: true}
	reject := []string{
		"172.217.116.4", "142.251.150.2", "142.250.74.10", "74.125.131.1",
		"198.18.0.1", "198.19.255.1", "127.0.0.1", "10.0.0.5", "192.168.1.1",
		"100.64.0.1", "172.16.0.1", "0.0.0.0", "224.0.0.1",
	}
	for _, s := range reject {
		if !IsNonProxyIP(netip.MustParseAddr(s), ref) {
			t.Errorf("expected %s to be rejected as non-proxy", s)
		}
	}
	accept := []string{
		"31.25.239.132", "143.20.64.192", "5.175.161.3", "37.221.93.141",
		"193.233.112.68", "159.194.200.33", "194.87.196.13",
	}
	for _, s := range accept {
		if IsNonProxyIP(netip.MustParseAddr(s), ref) {
			t.Errorf("expected %s to be accepted as proxy", s)
		}
	}
}

func TestParseCustomProvider(t *testing.T) {
	p1, err := ParseCustomProvider("1.2.3.4")
	if err != nil || p1.Kind != "udp" {
		t.Fatalf("udp parse failed: %+v %v", p1, err)
	}
	p2, err := ParseCustomProvider("https://dns.example.com/dns-query")
	if err != nil || p2.Kind != "doh" || p2.Host != "dns.example.com" {
		t.Fatalf("doh parse failed: %+v %v", p2, err)
	}
	p3, err := ParseCustomProvider("tls://dns.example.com:853")
	if err != nil || p3.Kind != "dot" || p3.Port != "853" {
		t.Fatalf("dot parse failed: %+v %v", p3, err)
	}
	if _, err := ParseCustomProvider("not a dns"); err == nil {
		t.Fatalf("expected error on invalid custom DNS")
	}
}
