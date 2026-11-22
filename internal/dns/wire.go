package dns

import (
	"encoding/binary"
	"errors"
	"net/netip"
	"strings"
)

// BuildAQuery собирает RFC 1035 DNS-запрос типа A (IN) с флагом RD=1.
func BuildAQuery(domain string, txID uint16) ([]byte, error) {
	domain = strings.TrimSuffix(strings.TrimSpace(domain), ".")
	if domain == "" || len(domain) > 253 {
		return nil, errors.New("invalid domain name")
	}
	buf := make([]byte, 12, 64)
	binary.BigEndian.PutUint16(buf[0:2], txID)
	binary.BigEndian.PutUint16(buf[2:4], 0x0100) // standard query, RD=1
	binary.BigEndian.PutUint16(buf[4:6], 1)      // QDCOUNT=1

	for _, label := range strings.Split(domain, ".") {
		if len(label) == 0 || len(label) > 63 {
			return nil, errors.New("invalid domain label")
		}
		buf = append(buf, byte(len(label)))
		buf = append(buf, label...)
	}
	buf = append(buf, 0x00)
	buf = append(buf, 0x00, 0x01, 0x00, 0x01) // QTYPE=A, QCLASS=IN
	return buf, nil
}

// ParseARecords извлекает IPv4-адреса из Answer-секции DNS wire-пакета.
func ParseARecords(msg []byte) []netip.Addr {
	if len(msg) < 12 {
		return nil
	}
	qdCount := int(binary.BigEndian.Uint16(msg[4:6]))
	anCount := int(binary.BigEndian.Uint16(msg[6:8]))
	off := 12

	for i := 0; i < qdCount; i++ {
		next, ok := skipName(msg, off)
		if !ok || next+4 > len(msg) {
			return nil
		}
		off = next + 4
	}

	var out []netip.Addr
	for i := 0; i < anCount; i++ {
		next, ok := skipName(msg, off)
		if !ok || next+10 > len(msg) {
			break
		}
		off = next
		rrType := binary.BigEndian.Uint16(msg[off : off+2])
		rrClass := binary.BigEndian.Uint16(msg[off+2 : off+4])
		rdLen := int(binary.BigEndian.Uint16(msg[off+8 : off+10]))
		off += 10
		if off+rdLen > len(msg) {
			break
		}
		if rrType == 1 && rrClass == 1 && rdLen == 4 {
			addr := netip.AddrFrom4([4]byte{msg[off], msg[off+1], msg[off+2], msg[off+3]})
			out = append(out, addr)
		}
		off += rdLen
	}
	return out
}

func skipName(msg []byte, off int) (int, bool) {
	steps := 0
	for off < len(msg) {
		steps++
		if steps > 128 {
			return 0, false
		}
		l := int(msg[off])
		if l == 0 {
			return off + 1, true
		}
		if l&0xC0 == 0xC0 {
			if off+2 > len(msg) {
				return 0, false
			}
			return off + 2, true
		}
		if l&0xC0 != 0 {
			return 0, false
		}
		off += 1 + l
		if off > len(msg) {
			return 0, false
		}
	}
	return 0, false
}
