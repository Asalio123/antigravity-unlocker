package patcher

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/Asalio123/antigravity-unlocker/internal/config"
)

var (
	patIneligible  = []byte("ineligible")
	patInexigible  = []byte("inexigible")
	patHTTPSProxy  = []byte("https_proxy")
	patOurProxy    = []byte(config.ProxyEnvVar) // "AG_UNL_PRXY" (11 bytes)
	patForeignPair = []byte("HTTPS_PROXYAG_LS_PROXY")
	patOurPair     = []byte("HTTPS_PROXY" + config.ProxyEnvVar)
)

type BinaryInfo struct {
	Ineligible   int
	Inexigible   int
	HTTPSProxy   int
	OurProxy     int
	ForeignProxy int
}

func (b BinaryInfo) EligibilityPatched() bool {
	return b.Ineligible == 0 && b.Inexigible > 0
}

func (b BinaryInfo) ProxyPatched() bool {
	return b.OurProxy > 0
}

func (b BinaryInfo) UnknownBuild() bool {
	return b.Ineligible == 0 && b.Inexigible == 0
}

type PatchStatus int

const (
	StatusPatched PatchStatus = iota
	StatusAlready
	StatusUnknownBuild
	StatusNoChange
)

type BinaryResult struct {
	Status          PatchStatus
	EligibilityHits int
	ProxyHits       int
	MigratedForeign bool
}

// InspectBinary стримит файл блоками по 1 MiB (без загрузки 200 MB в память).
func InspectBinary(path string) (BinaryInfo, error) {
	f, err := os.Open(path)
	if err != nil {
		return BinaryInfo{}, err
	}
	defer f.Close()

	const chunkSize = 1024 * 1024
	const overlap = 32
	buf := make([]byte, chunkSize+overlap)
	var carry int
	var info BinaryInfo

	for {
		n, rerr := f.Read(buf[carry : carry+chunkSize])
		total := carry + n
		if total == 0 {
			break
		}
		window := buf[:total]
		// Считаем только вхождения, стартующие до границы overlap (кроме финального блока),
		// чтобы не задублировать совпадение на стыке двух чанков.
		limit := total
		if rerr == nil && total > overlap {
			limit = total - overlap
		}
		info.Ineligible += countBefore(window, patIneligible, limit)
		info.Inexigible += countBefore(window, patInexigible, limit)
		info.HTTPSProxy += countBefore(window, patHTTPSProxy, limit)
		info.OurProxy += countBefore(window, patOurProxy, limit)
		info.ForeignProxy += countBefore(window, patForeignPair, limit)

		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return BinaryInfo{}, rerr
		}
		if total > overlap {
			copy(buf[:overlap], buf[total-overlap:total])
			carry = overlap
		} else {
			carry = total
		}
	}
	return info, nil
}

func countBefore(data, needle []byte, limit int) int {
	if len(data) < len(needle) {
		return 0
	}
	count := 0
	off := 0
	for off < limit && off+len(needle) <= len(data) {
		idx := bytes.Index(data[off:], needle)
		if idx < 0 {
			break
		}
		pos := off + idx
		if pos >= limit {
			break
		}
		count++
		off = pos + len(needle)
	}
	return count
}

func replaceInPlace(data, from, to []byte) int {
	if len(from) != len(to) || len(data) < len(from) {
		return 0
	}
	count := 0
	off := 0
	for off+len(from) <= len(data) {
		idx := bytes.Index(data[off:], from)
		if idx < 0 {
			break
		}
		pos := off + idx
		copy(data[pos:pos+len(to)], to)
		count++
		off = pos + len(to)
	}
	return count
}

// PatchBinary атомарно применяет same-length патч к бинарю:
//   - ineligible -> inexigible (снятие клиентского гейта)
//   - https_proxy -> AG_UNL_PRXY (выделенный локальный прокси только для Antigravity)
func PatchBinary(path string, enableProxyVar bool) (BinaryResult, error) {
	info, err := InspectBinary(path)
	if err != nil {
		return BinaryResult{}, err
	}
	if info.UnknownBuild() {
		return BinaryResult{Status: StatusUnknownBuild}, nil
	}
	needElig := info.Ineligible > 0
	needProxy := enableProxyVar && (info.HTTPSProxy > 0 || info.ForeignProxy > 0)
	if !needElig && !needProxy {
		return BinaryResult{
			Status:          StatusAlready,
			EligibilityHits: info.Inexigible,
			ProxyHits:       info.OurProxy,
		}, nil
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return BinaryResult{}, err
	}
	res := BinaryResult{Status: StatusPatched}
	if needElig {
		res.EligibilityHits = replaceInPlace(data, patIneligible, patInexigible)
	} else {
		res.EligibilityHits = info.Inexigible
	}
	if needProxy {
		if info.HTTPSProxy > 0 {
			res.ProxyHits += replaceInPlace(data, patHTTPSProxy, patOurProxy)
		}
		if info.ForeignProxy > 0 {
			m := replaceInPlace(data, patForeignPair, patOurPair)
			res.ProxyHits += m
			res.MigratedForeign = m > 0
		}
	} else {
		res.ProxyHits = info.OurProxy
	}

	if err := writeBinaryAtomic(path, data); err != nil {
		return BinaryResult{}, err
	}
	if err := postPatchBinaryOS(path); err != nil {
		return res, err
	}
	return res, nil
}

// RevertBinary возвращает бинарь побайтово в исходное состояние (inexigible -> ineligible, AG_UNL_PRXY -> https_proxy).
func RevertBinary(path string) (BinaryResult, error) {
	info, err := InspectBinary(path)
	if err != nil {
		return BinaryResult{}, err
	}
	if info.Inexigible == 0 && info.OurProxy == 0 {
		return BinaryResult{Status: StatusNoChange}, nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return BinaryResult{}, err
	}
	res := BinaryResult{
		Status:          StatusPatched,
		EligibilityHits: replaceInPlace(data, patInexigible, patIneligible),
		ProxyHits:       replaceInPlace(data, patOurProxy, patHTTPSProxy),
	}
	if err := writeBinaryAtomic(path, data); err != nil {
		return BinaryResult{}, err
	}
	if err := postPatchBinaryOS(path); err != nil {
		return res, err
	}
	return res, nil
}

func writeFileTempRename(path string, data []byte) error {
	fi, err := os.Stat(path)
	if err != nil {
		return err
	}
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(path)+".*.agtmp")
	if err != nil {
		return fmt.Errorf("не удалось создать временный файл в %s: %w", dir, err)
	}
	tmpName := tmp.Name()
	cleanup := func() {
		_ = tmp.Close()
		_ = os.Remove(tmpName)
	}

	if _, err := tmp.Write(data); err != nil {
		cleanup()
		return err
	}
	if err := tmp.Chmod(fi.Mode().Perm()); err != nil {
		cleanup()
		return err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpName)
		return err
	}
	preserveOwnerOS(fi, tmpName)

	if err := os.Rename(tmpName, path); err != nil {
		_ = os.Remove(tmpName)
		return err
	}
	return nil
}

// CheckAsarArchitecture проверяет app.asar Desktop-приложения на модульную архитектуру v2.4+.
func CheckAsarArchitecture(asarPath string) (modular bool, legacy bool, err error) {
	if asarPath == "" {
		return false, false, errors.New("empty asar path")
	}
	f, err := os.Open(asarPath)
	if err != nil {
		return false, false, err
	}
	defer f.Close()

	const chunkSize = 1024 * 1024
	const overlap = 64
	buf := make([]byte, chunkSize+overlap)
	carry := 0
	for {
		n, rerr := f.Read(buf[carry : carry+chunkSize])
		total := carry + n
		if total == 0 {
			break
		}
		w := buf[:total]
		if bytes.Contains(w, []byte("./languageServer")) {
			modular = true
		}
		if bytes.Contains(w, []byte("_handleAuthErrorResponse")) || bytes.Contains(w, []byte("SET_INELIGIBLE")) {
			legacy = true
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return false, false, rerr
		}
		if total > overlap {
			copy(buf[:overlap], buf[total-overlap:total])
			carry = overlap
		} else {
			carry = total
		}
	}
	return modular, legacy, nil
}
