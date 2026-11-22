package patcher

import (
	"fmt"
	"os"
	"regexp"
	"strings"
)

const (
	jsBackupSuffix = ".ag_backup"
	jsEndMarker    = "// UNLOCKED"
	jsExtMarker    = "/*[AG_EXT_PATCHED]*/"
)

var (
	reIDEMain = regexp.MustCompile(`async\s+([A-Za-z_$0-9]+)\(([A-Za-z_$0-9]+)\)\s*\{\s*if\(this\.([A-Za-z_$0-9]+)\.send\(\{type:[A-Za-z_$0-9]+\.isGcpTos\?"GCP_SIGN_IN":"SIGN_IN"\}\),this\.([A-Za-z_$0-9]+)\.resetIsTierGCPTos\(\),this\.[A-Za-z_$0-9]+\.isGoogleInternal\)\{try\{await this\.([A-Za-z_$0-9]+)\.loadCodeAssist\([A-Za-z_$0-9]+\);const\{settings:([A-Za-z_$0-9]+),userTier:([A-Za-z_$0-9]+)\}=await this\.refreshUserStatus\([A-Za-z_$0-9]+\),([A-Za-z_$0-9]+)=([A-Za-z_$0-9]+)\([A-Za-z_$0-9]+\);this\.([A-Za-z_$0-9]+)\.pushUpdate\([A-Za-z_$0-9]+\),this\.[A-Za-z_$0-9]+\.send\(\{type:"AUTH_SUCCESS",tokenInfo:[A-Za-z_$0-9]+\}\),this\.([A-Za-z_$0-9]+)\.fire\(\{settings:[A-Za-z_$0-9]+,userTier:[A-Za-z_$0-9]+\}\)\}catch\(([A-Za-z_$0-9]+)\)\{.*?(?:return\}|return;\s*\})`)
	reIDEExt  = regexp.MustCompile(`const t=await ([A-Za-z_$][A-Za-z_$0-9.]*)\.UserStatus\.getUserStatus\(\);if\(!t\)return\[\];const n=\(0,([A-Za-z_$][A-Za-z_$0-9.]*)\)\(t,([A-Za-z_$][A-Za-z_$0-9.]*)\),\{email:([A-Za-z_$][A-Za-z_$0-9]*),name:([A-Za-z_$][A-Za-z_$0-9]*)\}=n;return""===([A-Za-z_$][A-Za-z_$0-9]*)\?\[\]:`)
)

func hasUnlockedMarker(content string) bool {
	trimmed := strings.TrimRight(content, " \t\r\n")
	idx := strings.LastIndexByte(trimmed, '\n')
	last := trimmed
	if idx >= 0 {
		last = trimmed[idx+1:]
	}
	return strings.HasPrefix(strings.TrimSpace(last), jsEndMarker)
}

func IsIDEMainPatched(path string) bool {
	raw, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	return hasUnlockedMarker(string(raw))
}

func backupOnce(path string, raw []byte) {
	bak := path + jsBackupSuffix
	if _, err := os.Stat(bak); err == nil {
		return
	}
	_ = os.WriteFile(bak, raw, 0o644)
}

// PatchIDEMain перезаписывает auth-функцию в IDE main.js с предварительным бэкапом .ag_backup.
func PatchIDEMain(path string) (PatchStatus, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return StatusNoChange, err
	}
	content := string(raw)
	if strings.Contains(content, "/*[AG_PATCHED]*/") || strings.Contains(content, "[AG_PROXY_HOOK]") {
		return StatusNoChange, fmt.Errorf("обнаружена старая несовместимая версия патча в main.js — переустанови IDE чисто")
	}
	if hasUnlockedMarker(content) {
		return StatusAlready, nil
	}
	loc := reIDEMain.FindStringSubmatchIndex(content)
	if loc == nil {
		return StatusUnknownBuild, nil
	}
	sub := func(g int) string { return content[loc[2*g]:loc[2*g+1]] }
	fname, t, send, y, iVar, fn, fField, hField := sub(1), sub(2), sub(3), sub(4), sub(8), sub(9), sub(10), sub(11)

	payload := fmt.Sprintf(`async %s(%s){
    this.%s.send({type:%s.isGcpTos?"GCP_SIGN_IN":"SIGN_IN"});
    this.%s.resetIsTierGCPTos();
    try {
        try { await this.%s.loadCodeAssist(%s); } catch(_) {}
        try { await this.%s.onboardUser("standard-tier", %s); } catch(_) {
            try { await this.%s.onboardUser("free-tier", %s); } catch(__) {}
        }
        let __res = { settings: {}, userTier: { id: "pro", description: "Pro" } };
        try { __res = await this.refreshUserStatus(%s); } catch(_) {}
        const %s = %s(%s);
        try { this.%s.pushUpdate(%s); } catch(_) {}
        this.%s.send({type:"AUTH_SUCCESS",tokenInfo:%s});
        this.%s.fire({settings:__res.settings, userTier:__res.userTier});
    } catch(e) {}
    return;
`, fname, t, send, t, y, y, t, y, t, y, t, t, iVar, fn, t, fField, iVar, send, t, hField)

	updated := content[:loc[0]] + payload + content[loc[1]:] + "\n" + jsEndMarker + "\n"
	backupOnce(path, raw)
	if err := writeFileTempRename(path, []byte(updated)); err != nil {
		return StatusNoChange, err
	}
	return StatusPatched, nil
}

// PatchIDEExt добавляет fallback имени пользователя в IDE extension.js (косметика, не критично).
func PatchIDEExt(path string) (PatchStatus, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return StatusNoChange, err
	}
	content := string(raw)
	if strings.Contains(content, jsExtMarker) {
		return StatusAlready, nil
	}
	loc := reIDEExt.FindStringSubmatchIndex(content)
	if loc == nil {
		return StatusUnknownBuild, nil
	}
	sub := func(g int) string { return content[loc[2*g]:loc[2*g+1]] }
	ns, p2, dz7, email, name := sub(1), sub(2), sub(3), sub(4), sub(5)

	rep := fmt.Sprintf(`const t=await %s.UserStatus.getUserStatus();let %s="",%s="";try{if(t){const n=(0,%s)(t,%s);%s=n.email||"";%s=n.name||"";}}catch(_){}if(%s===""){%s="antigravity-user";%s="User";}return false?[]:`,
		ns, email, name, p2, dz7, email, name, email, email, name)
	updated := jsExtMarker + "\n" + content[:loc[0]] + rep + content[loc[1]:] + "\n" + jsEndMarker + "\n"
	backupOnce(path, raw)
	if err := writeFileTempRename(path, []byte(updated)); err != nil {
		return StatusNoChange, err
	}
	return StatusPatched, nil
}

// RevertIDEFile восстанавливает JS-файл побайтово из .ag_backup (или снимает маркер, если бэкапа нет).
func RevertIDEFile(path string) (PatchStatus, error) {
	bak := path + jsBackupSuffix
	if raw, err := os.ReadFile(bak); err == nil {
		if err := writeFileTempRename(path, raw); err != nil {
			return StatusNoChange, err
		}
		_ = os.Remove(bak)
		return StatusPatched, nil
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return StatusNoChange, nil
	}
	content := string(raw)
	if !hasUnlockedMarker(content) && !strings.Contains(content, jsExtMarker) {
		return StatusNoChange, nil
	}
	cleaned := strings.TrimRight(content, " \t\r\n")
	if idx := strings.LastIndexByte(cleaned, '\n'); idx >= 0 && strings.HasPrefix(strings.TrimSpace(cleaned[idx+1:]), jsEndMarker) {
		cleaned = cleaned[:idx]
	}
	cleaned = strings.TrimPrefix(cleaned, jsExtMarker+"\n")
	if err := writeFileTempRename(path, []byte(cleaned+"\n")); err != nil {
		return StatusNoChange, err
	}
	return StatusPatched, nil
}
