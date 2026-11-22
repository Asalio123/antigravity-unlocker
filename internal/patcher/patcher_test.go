package patcher

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/Asalio123/antigravity-unlocker/internal/config"
)

func TestPatchAndRevertBinaryByteExact(t *testing.T) {
	dir := t.TempDir()
	bin := filepath.Join(dir, "language_server")
	orig := []byte("hdr\x00ineligible\x00mid\x00HTTPS_PROXYhttps_proxy\x00ineligible_tiers\x00end")
	if err := os.WriteFile(bin, orig, 0o755); err != nil {
		t.Fatal(err)
	}

	res, err := PatchBinary(bin, true)
	if err != nil {
		t.Fatalf("PatchBinary: %v", err)
	}
	if res.Status != StatusPatched || res.EligibilityHits != 2 || res.ProxyHits != 1 {
		t.Fatalf("unexpected patch result: %+v", res)
	}
	patched, _ := os.ReadFile(bin)
	if len(patched) != len(orig) {
		t.Fatalf("binary length changed: %d vs %d", len(patched), len(orig))
	}
	if !bytes.Contains(patched, []byte("HTTPS_PROXY"+config.ProxyEnvVar)) {
		t.Fatalf("expected renamed proxy var in binary: %q", patched)
	}
	if bytes.Contains(patched, []byte("ineligible")) {
		t.Fatalf("expected zero ineligible strings after patch")
	}

	// Повторный патч — идемпотентный
	res2, err := PatchBinary(bin, true)
	if err != nil || res2.Status != StatusAlready {
		t.Fatalf("expected StatusAlready on 2nd patch, got %+v err=%v", res2, err)
	}

	// Полный откат — побайтовое совпадение с оригиналом
	rev, err := RevertBinary(bin)
	if err != nil || rev.Status != StatusPatched {
		t.Fatalf("RevertBinary failed: %+v err=%v", rev, err)
	}
	after, _ := os.ReadFile(bin)
	if !bytes.Equal(after, orig) {
		t.Fatalf("reverted bytes differ:\n got: %q\nwant: %q", after, orig)
	}
}

func TestMigrateForeignProxyVar(t *testing.T) {
	dir := t.TempDir()
	bin := filepath.Join(dir, "language_server")
	// Имитация бинаря, уже пропатченного другим анлокером (inexigible + AG_LS_PROXY)
	foreign := []byte("xx\x00inexigible\x00HTTPS_PROXYAG_LS_PROXY\x00yy")
	if err := os.WriteFile(bin, foreign, 0o755); err != nil {
		t.Fatal(err)
	}

	res, err := PatchBinary(bin, true)
	if err != nil {
		t.Fatalf("PatchBinary migrate: %v", err)
	}
	if res.Status != StatusPatched || !res.MigratedForeign {
		t.Fatalf("expected migration from foreign proxy var, got %+v", res)
	}
	got, _ := os.ReadFile(bin)
	if !bytes.Contains(got, []byte("HTTPS_PROXY"+config.ProxyEnvVar)) {
		t.Fatalf("expected AG_UNL_PRXY after migration, got %q", got)
	}
}

func TestUnknownBuildNotTouched(t *testing.T) {
	dir := t.TempDir()
	bin := filepath.Join(dir, "unknown")
	orig := []byte("nothing matching here at all")
	if err := os.WriteFile(bin, orig, 0o755); err != nil {
		t.Fatal(err)
	}
	res, err := PatchBinary(bin, true)
	if err != nil || res.Status != StatusUnknownBuild {
		t.Fatalf("expected StatusUnknownBuild, got %+v err=%v", res, err)
	}
	after, _ := os.ReadFile(bin)
	if !bytes.Equal(after, orig) {
		t.Fatalf("unknown build was modified!")
	}
}

func TestIDEJSPatchAndByteExactRevert(t *testing.T) {
	dir := t.TempDir()
	mainJS := filepath.Join(dir, "main.js")
	orig := `class Auth{async handleLogin(t){if(this.a.send({type:t.isGcpTos?"GCP_SIGN_IN":"SIGN_IN"}),this.b.resetIsTierGCPTos(),this.c.isGoogleInternal){try{await this.b.loadCodeAssist(t);const{settings:s,userTier:u}=await this.refreshUserStatus(t),i=fn(t);this.f.pushUpdate(i),this.a.send({type:"AUTH_SUCCESS",tokenInfo:t}),this.h.fire({settings:s,userTier:u})}catch(e){return}}console.log("rest")}}`
	if err := os.WriteFile(mainJS, []byte(orig), 0o644); err != nil {
		t.Fatal(err)
	}

	st, err := PatchIDEMain(mainJS)
	if err != nil || st != StatusPatched {
		t.Fatalf("PatchIDEMain: st=%v err=%v", st, err)
	}
	if !IsIDEMainPatched(mainJS) {
		t.Fatalf("expected IsIDEMainPatched=true")
	}
	if _, err := os.Stat(mainJS + jsBackupSuffix); err != nil {
		t.Fatalf("backup not created: %v", err)
	}

	rev, err := RevertIDEFile(mainJS)
	if err != nil || rev != StatusPatched {
		t.Fatalf("RevertIDEFile: st=%v err=%v", rev, err)
	}
	after, _ := os.ReadFile(mainJS)
	if string(after) != orig {
		t.Fatalf("IDE main.js revert not byte-exact")
	}
}
