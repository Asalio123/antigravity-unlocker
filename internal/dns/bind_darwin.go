//go:build darwin

package dns

import (
	"net"
	"os/exec"
	"strings"
	"syscall"
)

const ipBoundIF = 25 // IP_BOUND_IF on macOS

type NetInfo struct {
	VPNActive bool
	PhysIface string
	PhysIndex int
}

// DetectNetwork определяет, активен ли VPN-туннель, и находит физический интерфейс.
func DetectNetwork() NetInfo {
	var info NetInfo
	if out, err := exec.Command("route", "-n", "get", "-inet", "default").Output(); err == nil {
		for _, line := range strings.Split(string(out), "\n") {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "interface:") {
				dev := strings.TrimSpace(strings.TrimPrefix(line, "interface:"))
				if isTunnelName(dev) {
					info.VPNActive = true
				}
			}
		}
	}

	if out, err := exec.Command("netstat", "-rn", "-f", "inet").Output(); err == nil {
		for _, line := range strings.Split(string(out), "\n") {
			fields := strings.Fields(line)
			if len(fields) >= 4 && fields[0] == "default" {
				dev := fields[len(fields)-1]
				if !isTunnelName(dev) {
					if iface, err := net.InterfaceByName(dev); err == nil {
						info.PhysIface = dev
						info.PhysIndex = iface.Index
						break
					}
				}
			}
		}
	}
	return info
}

func isTunnelName(dev string) bool {
	d := strings.ToLower(dev)
	for _, p := range []string{"utun", "ipsec", "ppp", "tun", "tap"} {
		if strings.HasPrefix(d, p) {
			return true
		}
	}
	return false
}

// BindDialerControl возвращает Dialer.Control, привязывающий сокет к физическому интерфейсу.
func BindDialerControl(info NetInfo) func(network, address string, c syscall.RawConn) error {
	if info.PhysIndex <= 0 {
		return nil
	}
	idx := info.PhysIndex
	return func(network, address string, c syscall.RawConn) error {
		var sockErr error
		if err := c.Control(func(fd uintptr) {
			sockErr = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IP, ipBoundIF, idx)
		}); err != nil {
			return err
		}
		return sockErr
	}
}
