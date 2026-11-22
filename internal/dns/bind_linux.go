//go:build linux

package dns

import (
	"net"
	"os/exec"
	"strings"
	"syscall"
)

type NetInfo struct {
	VPNActive bool
	PhysIface string
	PhysIndex int
}

// DetectNetwork определяет активный VPN-туннель и физический интерфейс по таблице маршрутов Linux.
func DetectNetwork() NetInfo {
	var info NetInfo
	out, err := exec.Command("ip", "-4", "route", "show", "default").Output()
	if err != nil {
		return info
	}
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		var dev string
		for i := 0; i+1 < len(fields); i++ {
			if fields[i] == "dev" {
				dev = fields[i+1]
				break
			}
		}
		if dev == "" {
			continue
		}
		if isTunnelName(dev) {
			info.VPNActive = true
		} else if info.PhysIface == "" {
			if iface, err := net.InterfaceByName(dev); err == nil {
				info.PhysIface = dev
				info.PhysIndex = iface.Index
			}
		}
	}
	return info
}

func isTunnelName(dev string) bool {
	d := strings.ToLower(dev)
	for _, p := range []string{"tun", "wg", "tap", "utun", "ppp", "nordlynx", "tailscale"} {
		if strings.HasPrefix(d, p) {
			return true
		}
	}
	return false
}

// BindDialerControl привязывает сокет к физическому интерфейсу (SO_BINDTODEVICE).
// На ядрах Linux 5.7+ работает без root; при EPERM вызов откатится на дефолтный маршрут.
func BindDialerControl(info NetInfo) func(network, address string, c syscall.RawConn) error {
	if info.PhysIface == "" {
		return nil
	}
	dev := info.PhysIface
	return func(network, address string, c syscall.RawConn) error {
		var sockErr error
		if err := c.Control(func(fd uintptr) {
			sockErr = syscall.SetsockoptString(int(fd), syscall.SOL_SOCKET, syscall.SO_BINDTODEVICE, dev)
		}); err != nil {
			return err
		}
		return sockErr
	}
}
