package proxy

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// DialUpstream открывает туннель к targetHost:targetPort через пользовательский
// HTTP CONNECT или SOCKS5 (socks5 / socks5h) прокси.
func DialUpstream(ctx context.Context, proxyRaw, targetHost, targetPort string) (net.Conn, error) {
	u, err := url.Parse(strings.TrimSpace(proxyRaw))
	if err != nil {
		return nil, fmt.Errorf("некорректный upstream URL: %w", err)
	}
	scheme := strings.ToLower(u.Scheme)
	proxyAddr := u.Host
	if _, _, err := net.SplitHostPort(proxyAddr); err != nil {
		switch scheme {
		case "socks5", "socks5h":
			proxyAddr = net.JoinHostPort(u.Hostname(), "1080")
		default:
			proxyAddr = net.JoinHostPort(u.Hostname(), "8080")
		}
	}

	d := &net.Dialer{Timeout: 8 * time.Second}
	conn, err := d.DialContext(ctx, "tcp", proxyAddr)
	if err != nil {
		return nil, err
	}

	deadline := time.Now().Add(10 * time.Second)
	if dl, ok := ctx.Deadline(); ok && dl.Before(deadline) {
		deadline = dl
	}
	_ = conn.SetDeadline(deadline)

	switch scheme {
	case "http", "https":
		err = handshakeHTTPConnect(conn, u, targetHost, targetPort)
	case "socks5", "socks5h":
		err = handshakeSOCKS5(conn, u, targetHost, targetPort)
	default:
		_ = conn.Close()
		return nil, fmt.Errorf("неподдерживаемая схема upstream: %s (нужно http:// или socks5://)", scheme)
	}
	if err != nil {
		_ = conn.Close()
		return nil, err
	}
	_ = conn.SetDeadline(time.Time{})
	return conn, nil
}

func handshakeHTTPConnect(conn net.Conn, u *url.URL, host, port string) error {
	target := net.JoinHostPort(host, port)
	var b strings.Builder
	b.WriteString("CONNECT ")
	b.WriteString(target)
	b.WriteString(" HTTP/1.1\r\nHost: ")
	b.WriteString(target)
	b.WriteString("\r\n")
	if u.User != nil {
		user := u.User.Username()
		pass, _ := u.User.Password()
		cred := base64.StdEncoding.EncodeToString([]byte(user + ":" + pass))
		b.WriteString("Proxy-Authorization: Basic ")
		b.WriteString(cred)
		b.WriteString("\r\n")
	}
	b.WriteString("\r\n")
	if _, err := io.WriteString(conn, b.String()); err != nil {
		return err
	}
	br := bufio.NewReader(conn)
	resp, err := http.ReadResponse(br, &http.Request{Method: http.MethodConnect})
	if err != nil {
		return err
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("upstream HTTP CONNECT вернул %s", resp.Status)
	}
	return nil
}

// handshakeSOCKS5 реализует RFC 1928 + RFC 1929 (user/pass) с резолвом имени на стороне прокси (ATYP=0x03).
func handshakeSOCKS5(conn net.Conn, u *url.URL, host, portStr string) error {
	portNum, err := strconv.Atoi(portStr)
	if err != nil || portNum <= 0 || portNum > 65535 {
		return fmt.Errorf("некорректный порт: %s", portStr)
	}
	if len(host) > 255 {
		return errors.New("имя хоста длиннее 255 байт")
	}

	hasAuth := u.User != nil
	if hasAuth {
		if _, err := conn.Write([]byte{0x05, 0x02, 0x00, 0x02}); err != nil {
			return err
		}
	} else {
		if _, err := conn.Write([]byte{0x05, 0x01, 0x00}); err != nil {
			return err
		}
	}

	var methodResp [2]byte
	if _, err := io.ReadFull(conn, methodResp[:]); err != nil {
		return err
	}
	if methodResp[0] != 0x05 {
		return fmt.Errorf("SOCKS5: неверная версия ответа %d", methodResp[0])
	}
	switch methodResp[1] {
	case 0x00:
		// no auth
	case 0x02:
		if !hasAuth {
			return errors.New("SOCKS5 требует логин/пароль")
		}
		user := u.User.Username()
		pass, _ := u.User.Password()
		if len(user) > 255 || len(pass) > 255 {
			return errors.New("SOCKS5: слишком длинный логин или пароль")
		}
		auth := make([]byte, 0, 3+len(user)+len(pass))
		auth = append(auth, 0x01, byte(len(user)))
		auth = append(auth, user...)
		auth = append(auth, byte(len(pass)))
		auth = append(auth, pass...)
		if _, err := conn.Write(auth); err != nil {
			return err
		}
		var authResp [2]byte
		if _, err := io.ReadFull(conn, authResp[:]); err != nil {
			return err
		}
		if authResp[1] != 0x00 {
			return errors.New("SOCKS5: авторизация отклонена")
		}
	default:
		return fmt.Errorf("SOCKS5: неподдерживаемый метод аутентификации 0x%02x", methodResp[1])
	}

	// CONNECT request (ATYP=0x03 domain name)
	req := make([]byte, 0, 7+len(host))
	req = append(req, 0x05, 0x01, 0x00, 0x03, byte(len(host)))
	req = append(req, host...)
	var pb [2]byte
	binary.BigEndian.PutUint16(pb[:], uint16(portNum))
	req = append(req, pb[:]...)
	if _, err := conn.Write(req); err != nil {
		return err
	}

	var hdr [4]byte
	if _, err := io.ReadFull(conn, hdr[:]); err != nil {
		return err
	}
	if hdr[0] != 0x05 || hdr[1] != 0x00 {
		return fmt.Errorf("SOCKS5 CONNECT ошибка: код 0x%02x", hdr[1])
	}
	switch hdr[3] {
	case 0x01:
		var skip [6]byte
		_, err = io.ReadFull(conn, skip[:])
	case 0x04:
		var skip [18]byte
		_, err = io.ReadFull(conn, skip[:])
	case 0x03:
		var lb [1]byte
		if _, err = io.ReadFull(conn, lb[:]); err == nil {
			skip := make([]byte, int(lb[0])+2)
			_, err = io.ReadFull(conn, skip)
		}
	default:
		return fmt.Errorf("SOCKS5: неизвестный ATYP 0x%02x", hdr[3])
	}
	return err
}
