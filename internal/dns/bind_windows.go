//go:build windows

package dns

import (
	"encoding/binary"
	"net"
	"strings"
	"syscall"
	"unsafe"
)

const ipUnicastIF = 31 // IP_UNICAST_IF on Windows

var (
	modWs2_32      = syscall.NewLazyDLL("ws2_32.dll")
	procSetsockopt = modWs2_32.NewProc("setsockopt")
)

type NetInfo struct {
	VPNActive bool
	PhysIface string
	PhysIndex int
}

// DetectNetwork ищет активный VPN-адаптер и физический сетевой интерфейс на Windows.
func DetectNetwork() NetInfo {
	var info NetInfo
	ifaces, err := net.Interfaces()
	if err != nil {
		return info
	}
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil || len(addrs) == 0 {
			continue
		}
		hasGlobalV4 := false
		for _, a := range addrs {
			ipNet, ok := a.(*net.IPNet)
			if !ok {
				continue
			}
			v4 := ipNet.IP.To4()
			if v4 == nil || v4.IsLoopback() || v4.IsLinkLocalUnicast() {
				continue
			}
			hasGlobalV4 = true
			break
		}
		if !hasGlobalV4 {
			continue
		}
		if isTunnelName(iface.Name) {
			info.VPNActive = true
		} else if info.PhysIndex == 0 {
			info.PhysIface = iface.Name
			info.PhysIndex = iface.Index
		}
	}
	return info
}

func isTunnelName(name string) bool {
	n := strings.ToLower(name)
	for _, kw := range []string{
		"wintun", "wireguard", "tun", "tap", "vpn", "nekobox", "sing-box",
		"clash", "v2ray", "xray", "amnezia", "outline", "tailscale", "zerotier",
		"nordlynx", "proton", "warp", "cloudflare", "openvpn", "ppp",
	} {
		if strings.Contains(n, kw) {
			return true
		}
	}
	return false
}

// BindDialerControl привязывает исходящий сокет к физическому интерфейсу (IP_UNICAST_IF).
func BindDialerControl(info NetInfo) func(network, address string, c syscall.RawConn) error {
	if info.PhysIndex <= 0 {
		return nil
	}
	var idxNet [4]byte
	binary.BigEndian.PutUint32(idxNet[:], uint32(info.PhysIndex))
	return func(network, address string, c syscall.RawConn) error {
		var sockErr error
		if err := c.Control(func(fd uintptr) {
			r, _, e := procSetsockopt.Call(
				fd,
				uintptr(syscall.IPPROTO_IP),
				uintptr(ipUnicastIF),
				uintptr(unsafe.Pointer(&idxNet[0])),
				uintptr(len(idxNet)),
			)
			if r != 0 {
				sockErr = e
			}
		}); err != nil {
			return err
		}
		return sockErr
	}
}
