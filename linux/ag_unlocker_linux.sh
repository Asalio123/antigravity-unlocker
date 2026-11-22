#!/bin/bash
# ============================================================================
#  AG Unlocker for Linux  —  порт confeden/Antigravity (Windows) на Linux
#  https://github.com/confeden/Antigravity
#  Собрат скрипта antigravity-unlocker-mac: те же методы, та же DNS-часть.
#
#  Цель: Google Antigravity (Desktop) и Antigravity IDE с antigravity.google/download.
#  В AppImage-версии патч бессмысленный (файл временный) — не поддерживается.
#
#  Как работает (коротко):
#    1) Байтовый патч: "ineligible" -> "inexigible" (по 10 байт, обратимо)
#       в Language Server — клиент перестаёт распознавать отказ eligibility.
#       Desktop v2.4+ этим и ограничивается (auth целиком в Language Server).
#    1б) IDE дополнительно: перезапись auth-функции в resources/app/out/main.js
#       (regex по минифицированному телу, порт patch_ide.rs оригинала 1-в-1)
#       + fallback имени в extensions/antigravity/dist/extension.js.
#       Перед первой правкой делается бэкап <файл>.ag_backup, откат = restore из него.
#    2) DNS-пин: анблок-DNS (eu.geohide.ru / dns.geohide.ru / dns.dns-ai.ru; UDP + DoH)
#       отдают российским клиентам IP своих SNI-прокси вместо Google; живые
#       адреса пинуются в /etc/hosts (маркеры AG_UNLOCKER_HOSTS_*).
#       Ответ считается подменой, если он вне /16 эталона (8.8.8.8 / 1.1.1.1)
#       и вне известных диапазонов Google. DoH идёт мимо VPN-туннеля (с fallback),
#       а боевая проба проверяет оба пути — /32 маршруты ставятся точечно.
#       Watchdog (пункт 6) авторепатчит после обновлений.
#
#  Зависимости: bash, perl, curl, coreutils (+ dig из dnsutils/bind-utils для UDP).
#  На Linux подписи не проверяются — переподписка не нужна (в отличие от macOS).
#
#  Запуск:  bash ag_unlocker_linux.sh  (sudo запросится только где нужны права)
# ============================================================================

MARKER_BEGIN="# AG_UNLOCKER_HOSTS_BEGIN"
MARKER_END="# AG_UNLOCKER_HOSTS_END"

HOSTS="${AG_HOSTS:-/etc/hosts}"
DOMAINS=(
  "daily-cloudcode-pa.googleapis.com"
  "cloudcode-pa.googleapis.com"
  "generativelanguage.googleapis.com"
  "aicode.googleapis.com"
)
# DNS-пул (актуализировано 2026-11-22 живыми пробами):
# - xbox-dns.ru мёртв с окт 2026;
# - comss.one выкинут: отдаёт прямые IP Google (172.217 / 142.251), гейт не снимает;
# - eu.geohide.ru (4 живых UDP-узла) + dns.geohide.ru (UDP + DoH) подменяют
#   daily-cloudcode-pa, generativelanguage и aicode;
# - dns.dns-ai.ru (DoH HTTP/2, обновлённые IP) дополнительно покрывает cloudcode-pa.
# Дополнительно можно передать свой DNS: AG_CUSTOM_DNS="1.2.3.4" (или несколько через запятую).
PROVIDERS=(31.25.239.132 143.20.64.192 5.175.161.3 37.221.93.141 37.230.192.51)
DOH_PROVIDERS=(
  "dns.dns-ai.ru|194.87.196.13,45.151.102.219,185.251.90.181|h2"
  "dns.geohide.ru|37.230.192.51,45.155.204.190|h1"
)
REFERENCE=(8.8.8.8 1.1.1.1)

# Контекст реального пользователя сохраняем даже при запуске через sudo:
# иначе HOME=/root и обрезанный PATH ломают поиск в ~/, ~/.gemini/bin и systemd --user.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF_SCRIPT="$SCRIPT_DIR/$(basename "$0")"
CALLER_PWD="${AG_CALLER_PWD:-$(pwd)}"
REAL_USER="${AG_REAL_USER:-${SUDO_USER:-$(id -un)}}"
REAL_UID="${AG_REAL_UID:-${SUDO_UID:-$(id -u)}}"
if [ -n "${AG_REAL_HOME:-}" ]; then
  REAL_HOME="$AG_REAL_HOME"
elif [ -n "${SUDO_USER:-}" ]; then
  REAL_HOME=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
fi
[ -z "$REAL_HOME" ] && REAL_HOME="$HOME"
USER_PATH="${AG_USER_PATH:-$PATH}"

# ~/.gemini/bin/agy — бэкенд Antigravity IDE 2.6.0+ и расширения VS Code / Cursor / Windsurf
AGY_CANDIDATES=(
  "$REAL_HOME/.gemini/bin/agy"
  "/usr/local/bin/agy"
  "/usr/bin/agy"
  "$REAL_HOME/.local/bin/agy"
  "$REAL_HOME/bin/agy"
)

C_OK='\033[32m'; C_WARN='\033[33m'; C_ERR='\033[31m'; C_INFO='\033[36m'; C_N='\033[0m'
say()  { printf "%b\n" "$1"; }
ok()   { say "${C_OK}[OK]${C_N} $1"; }
warn() { say "${C_WARN}[!]${C_N} $1"; }
err()  { say "${C_ERR}[X]${C_N} $1"; }
info() { say "${C_INFO}[i]${C_N} $1"; }

# Привилегированные операции (патч системных файлов, /etc/hosts, маршруты)
# повышают права точечно; меню, статус и watchdog живут в пользовательской сессии.
run_privileged() {
  local action="$1"
  if [ "$(id -u)" -eq 0 ] || [ -n "$AG_NO_ELEVATE" ]; then
    dispatch_privileged "$action"
    return $?
  fi
  info "Нужен root — запрашиваю sudo..."
  sudo \
    AG_REAL_USER="$REAL_USER" \
    AG_REAL_UID="$REAL_UID" \
    AG_REAL_HOME="$REAL_HOME" \
    AG_USER_PATH="$USER_PATH" \
    AG_CALLER_PWD="$CALLER_PWD" \
    AG_HOSTS="$HOSTS" \
    AG_ROOT="${AG_ROOT:-}" \
    AG_CUSTOM_DNS="${AG_CUSTOM_DNS:-}" \
    /bin/bash "$SELF_SCRIPT" --privileged "$action"
}

# ---------------------------------------------------------------- app discovery
resolve_path() {
  perl -MCwd=abs_path -e 'my $r = abs_path($ARGV[0]); print(defined $r ? $r : $ARGV[0])' "$1" 2>/dev/null || echo "$1"
}

is_elf_target() {
  local f="$1"
  [ -f "$f" ] || return 1
  case "$f" in *.agtmp|*.ag_backup|*.log|*.txt) return 1 ;; esac
  file "$f" 2>/dev/null | grep -q "ELF"
}

# Все уникальные бинари agy: CLI из PATH + ~/.gemini/bin/agy (IDE 2.6+ и VS Code).
AGY_BINS=()
collect_agy_bins() {
  AGY_BINS=()
  local raw=() a rp seen=""
  local from_path
  from_path=$(PATH="$USER_PATH" command -v agy 2>/dev/null)
  [ -n "$from_path" ] && raw+=("$from_path")
  for a in "${AGY_CANDIDATES[@]}"; do raw+=("$a"); done
  for a in "${raw[@]}"; do
    [ -n "$a" ] && [ -e "$a" ] || continue
    rp=$(resolve_path "$a")
    is_elf_target "$rp" || continue
    case "$seen" in *"|$rp|"*) continue ;; esac
    seen="$seen|$rp|"
    AGY_BINS+=("$rp")
  done
}

# INSTALLS — пути к resources-директориям (Desktop и IDE могут стоять одновременно).
# Порядок: AG_ROOT -> пакетный менеджер -> find по стандартным корням, CWD и папке скрипта.
find_installs() {
  INSTALLS=()
  collect_agy_bins
  if [ -n "$AG_ROOT" ] && [ -d "$AG_ROOT" ]; then
    INSTALLS+=("$AG_ROOT")
    return 0
  fi
  local found="" p rp root seen=""
  if command -v dpkg >/dev/null 2>&1; then
    found=$(dpkg -L antigravity antigravity-ide 2>/dev/null | grep -E 'bin/language_server(_linux_x64)?$')
  fi
  if command -v rpm >/dev/null 2>&1; then
    found="$found
$(rpm -ql antigravity antigravity-ide 2>/dev/null | grep -E 'bin/language_server(_linux_x64)?$')"
  fi
  local search_roots=(/opt /usr/share /usr/lib /usr/local/share "$REAL_HOME/.antigravity" "$REAL_HOME/opt" "$REAL_HOME/.local/share" "$REAL_HOME" "$CALLER_PWD" "$SCRIPT_DIR")
  local existing_roots=() r rseen=""
  for r in "${search_roots[@]}"; do
    [ -d "$r" ] || continue
    case "$rseen" in *"|$r|"*) continue ;; esac
    rseen="$rseen|$r|"
    existing_roots+=("$r")
  done
  if [ ${#existing_roots[@]} -gt 0 ]; then
    # Desktop/IDE: language_server* (отсеиваем логи, бэкапы, временники и AppImage)
    found="$found
$(find "${existing_roots[@]}" -maxdepth 6 -type f \
       \( -iname "*antigravity*" -o -path "*/resources/bin/*" -o -path "*/extensions/antigravity/*" \) \
       -name "language_server*" ! -name "*.log" ! -name "*.txt" ! -name "*.agtmp" ! -name "*.ag_backup" \
       2>/dev/null | grep -v AppImage)"
    # IDE: resources/app/out/main.js (у IDE 2.6+ language_server вынесен в ~/.gemini/bin/agy)
    found="$found
$(find "${existing_roots[@]}" -maxdepth 6 -type f \
       -iname "*antigravity*" -regex ".*/resources/app/out/main\.js" 2>/dev/null)"
  fi
  while IFS= read -r p; do
    [ -n "$p" ] && [ -e "$p" ] || continue
    case "$p" in
      */resources/app/out/main.js)
        root=$(dirname "$(dirname "$(dirname "$p")")")
        ;;
      */resources/app/extensions/antigravity/bin/*)
        rp=$(resolve_path "$p")
        is_elf_target "$rp" || continue
        root=$(dirname "$(dirname "$(dirname "$(dirname "$(dirname "$p")")")")")
        ;;
      *)
        rp=$(resolve_path "$p")
        is_elf_target "$rp" || continue
        root=$(dirname "$(dirname "$p")")
        ;;
    esac
    [ -d "$root" ] || continue
    root=$(resolve_path "$root")
    case "$seen" in *"|$root|"*) continue ;; esac
    seen="$seen|$root|"
    INSTALLS+=("$root")
  done <<< "$found"
  [ ${#INSTALLS[@]} -gt 0 ] || [ ${#AGY_BINS[@]} -gt 0 ]
}

# Патч-цели внутри одной установки: только ELF language_server* с целевой строкой.
collect_targets() {
  RES="$1"   # путь к resources
  TARGETS=()
  local candidates=(
    "$RES"/bin/language_server*
    "$RES"/app/extensions/antigravity/bin/language_server*
  )
  local f rp seen=""
  for f in "${candidates[@]}"; do
    [ -e "$f" ] || continue
    rp=$(resolve_path "$f")
    is_elf_target "$rp" || continue
    case "$seen" in *"|$rp|"*) continue ;; esac
    if grep -q "ineligible\|inexigible" "$rp" 2>/dev/null; then
      seen="$seen|$rp|"
      TARGETS+=("$rp")
    fi
  done
}

check_arch() {
  local asar="$1/app.asar"
  [ -f "$asar" ] || { info "app.asar не найден — пропускаю проверку архитектуры"; return 0; }
  local modular legacy
  modular=$(grep -ac "./languageServer" "$asar" 2>/dev/null); [ -z "$modular" ] && modular=0
  legacy=$(grep -acE "_handleAuthErrorResponse|getUserStatus|SET_INELIGIBLE" "$asar" 2>/dev/null); [ -z "$legacy" ] && legacy=0
  if [ "$modular" -gt 0 ] && [ "$legacy" -eq 0 ]; then
    ok "Архитектура v2.4+: auth в Language Server — JS-патч не требуется"
  else
    warn "Обнаружен legacy-шелл (pre-2.4). Этот скрипт поддерживает v2.4+; JS-патчи не применены."
  fi
}

kill_processes() {
  [ -n "$AG_NO_ELEVATE" ] && return 0   # dev/CI-режим: чужие процессы не трогаем
  # Точечный kill: не убиваем сам скрипт, даже если он запущен из папки antigravity-unlocker.
  local pid cmd
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ] && continue
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
    case "$cmd" in *ag_unlocker*) continue ;; esac
    kill "$pid" 2>/dev/null || true
  done <<< "$(pgrep -if 'antigravity|language_server' 2>/dev/null || true)"
  pkill -x "agy" 2>/dev/null || true
  sleep 1
}

# ---------------------------------------------------------------- binary patch
patch_binaries() {
  local RES="$1"; local total=0
  collect_targets "$RES"
  if [ ${#TARGETS[@]} -eq 0 ]; then
    if [ -d "$RES/app/extensions/agy" ]; then
      info "IDE 2.6+: встроенного language_server нет, бэкенд патчится в ~/.gemini/bin/agy"
      return 0
    fi
    err "Патч-цели не найдены"
    return 1
  fi
  ensure_helper
  local f n rc
  for f in "${TARGETS[@]}"; do
    n=$(perl "$HELPER" bpatch "$f" 2>/dev/null); rc=$?
    case $rc in
      0) ok "пропатчен ($n вхожд.): $f"; total=$((total+1)) ;;
      2) ok "уже пропатчен: $f" ;;
      4) warn "строка не найдена — новая сборка? Пропускаю: $f" ;;
      *) err "не удалось записать: $f" ;;
    esac
  done
  [ "$total" -gt 0 ] && info "Патч применён к $total файл(ам). Запусти Antigravity и войди в Google-аккаунт."
  return 0
}

unpatch_binaries() {
  local RES="$1"; local total=0
  collect_targets "$RES"
  ensure_helper
  local f n rc
  for f in "${TARGETS[@]}"; do
    n=$(perl "$HELPER" bunpatch "$f" 2>/dev/null); rc=$?
    case $rc in
      0) ok "откачен ($n вхожд.): $f"; total=$((total+1)) ;;
      2) : ;;
      *) err "не удалось откатить: $f" ;;
    esac
  done
  [ "$total" -eq 0 ] && info "Пропатченных бинарей не найдено."
}

patch_cli() {
  collect_agy_bins
  [ ${#AGY_BINS[@]} -eq 0 ] && return 0
  ensure_helper
  local f n rc
  for f in "${AGY_BINS[@]}"; do
    n=$(perl "$HELPER" bpatch "$f" 2>/dev/null); rc=$?
    case $rc in
      0) ok "agy пропатчен ($n вхожд.): $f" ;;
      2) ok "agy уже пропатчен: $f" ;;
      4) warn "строка в agy не найдена — новая сборка? Не тронут: $f" ;;
      *) err "не удалось пропатчить $f" ;;
    esac
  done
}

revert_cli() {
  collect_agy_bins
  [ ${#AGY_BINS[@]} -eq 0 ] && return 0
  ensure_helper
  local f n rc
  for f in "${AGY_BINS[@]}"; do
    n=$(perl "$HELPER" bunpatch "$f" 2>/dev/null); rc=$?
    case $rc in
      0) ok "agy откачен ($n вхожд.): $f" ;;
      2) : ;;
      *) err "не удалось откатить $f" ;;
    esac
  done
}

# ---------------------------------------------------------------- IDE JS patch
# Порт patch_ide.rs оригинала 1-в-1. Только у IDE auth частично живёт в JS:
# перезаписывается тело auth-функции в resources/app/out/main.js (regex по
# минифицированному коду, имена переменных параметризованы) и fallback имени в
# extensions/antigravity/dist/extension.js. Бэкап <файл>.ag_backup создаётся
# один раз ДО первой правки — откат возможен только из него (тело перезаписано,
# из пропатченных байт оригинал не восстановить).
HELPER=""
ensure_helper() {
  [ -n "$HELPER" ] && return 0
  HELPER="${TMPDIR:-/tmp}/.ag_ide_js.$$.pl"
  cat > "$HELPER" <<'PERLEOF'
#!/usr/bin/perl
# режимы: main|ext|revert <file>
# exit: 0 patched/restored, 2 already/nothing, 3 old patch (нужна переустановка),
#       4 signature not found, 1 io error
use strict;
use warnings;
my ($mode, $file) = @ARGV;
die "usage: $0 main|ext|revert|query|parse <file>\n" unless $mode && $file;
if ($mode eq 'query') {
    # base64url DNS wire query (A-запись) для DoH ?dns=
    require MIME::Base64;
    my $q = pack("n6", 0x1234, 0x0100, 1, 0, 0, 0);
    $q .= join("", map { pack("C", length($_)) . $_ } split(/\./, $file)) . "\0";
    $q .= pack("n2", 1, 1);
    (my $b = MIME::Base64::encode_base64($q, '')) =~ tr{+/}{-_};
    $b =~ s/=+$//;
    print $b;
    exit 0;
}
if ($mode eq 'parse') {
    # A-записи из DNS wire ответа, по одной на строку
    open my $fh, '<:raw', $file or exit 1;
    local $/; my $d = <$fh>; close $fh;
    exit 0 if !defined($d) || length($d) < 12;
    my (undef, undef, $qd, $an) = unpack("n4", $d);
    my ($off, $len) = (12, length($d));
    for (1..$qd) {
        while ($off < $len) { my $l = unpack("C", substr($d,$off,1)); $off++;
            last if $l == 0; if ($l >= 192) { $off++; last; } $off += $l; }
        $off += 4;
        exit 0 if $off > $len;
    }
    for (1..$an) {
        while ($off < $len) { my $l = unpack("C", substr($d,$off,1)); $off++;
            last if $l == 0; if ($l >= 192) { $off++; last; } $off += $l; }
        last if $off + 10 > $len;
        my ($type, undef, undef, $rdlen) = unpack("nnNn", substr($d,$off,10)); $off += 10;
        last if $off + $rdlen > $len;
        print join(".", unpack("C4", substr($d,$off,4))), "\n" if $type == 1 && $rdlen == 4;
        $off += $rdlen;
    }
    exit 0;
}
sub slurp {
    my ($f) = @_;
    open my $fh, '<', $f or die "не прочитать $f: $!";
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}
sub slurp_bin {
    my ($f) = @_;
    open my $fh, '<:raw', $f or die "не прочитать $f: $!";
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}
sub backup_once {
    my ($f) = @_;
    my $bak = "$f.ag_backup";
    return if -e $bak;
    require File::Copy;
    File::Copy::copy($f, $bak) or warn "бэкап $bak не создан: $!";
}
sub write_atomic {
    my ($f, $content) = @_;
    my $tmp = "$f.$$.agtmp";
    my (undef, undef, $modebits, undef, $uid, $gid) = stat($f);
    open my $out, '>', $tmp or die "не записать $tmp: $!";
    print $out $content;
    close $out;
    if (defined $modebits) {
        chmod($modebits & 07777, $tmp);
        chown($uid, $gid, $tmp);
    }
    rename($tmp, $f) or do { unlink $tmp; die "rename $tmp -> $f: $!"; };
}
sub has_marker {
    my ($c) = @_;
    $c =~ s/\s+$//;
    my ($last) = $c =~ /([^\n]*)$/;
    return $last =~ /^\s*\/\/ UNLOCKED/;
}
if ($mode eq 'revert') {
    my $bak = "$file.ag_backup";
    if (-e $bak) {
        my $c = slurp($bak);
        write_atomic($file, $c);
        unlink $bak;
        print "RESTORED\n";
        exit 0;
    }
    exit 2 unless -r $file;
    my $c = slurp($file);
    if (has_marker($c)) {
        $c =~ s/\s+$//;
        $c =~ s/\n?[ \t]*\/\/ UNLOCKED[^\n]*$//;
        $c =~ s/^\/\*\[AG_EXT_PATCHED\]\*\/\n//;
        write_atomic($file, "$c\n");
        warn "бэкап отсутствует — снят только маркер, тело патча осталось\n";
        print "STRIPPED\n";
        exit 0;
    }
    exit 2;
}
if ($mode eq 'bpatch' || $mode eq 'bunpatch') {
    # атомарный байтовый патч/откат через temp+rename (ETXTBSY-safe, сохраняет права и владельца)
    my $data = slurp_bin($file);
    my $in = () = $data =~ /ineligible/g;
    my $outc = () = $data =~ /inexigible/g;
    if ($mode eq 'bpatch') {
        exit 2 if $in == 0 && $outc > 0;   # уже пропатчен
        exit 4 if $in == 0;                # сигнатуры нет — новая сборка
        $data =~ s/ineligible/inexigible/g;
    } else {
        exit 2 if $outc == 0;              # не пропатчен
        $data =~ s/inexigible/ineligible/g;
    }
    my $tmp = "$file.$$.agtmp";
    my (undef, undef, $modebits, undef, $uid, $gid) = stat($file);
    open my $out, '>:raw', $tmp or exit 1;
    print $out $data;
    close $out;
    if (defined $modebits) {
        chmod($modebits & 07777, $tmp);
        chown($uid, $gid, $tmp);
    }
    rename($tmp, $file) or do { unlink $tmp; exit 1; };
    print(($mode eq 'bpatch' ? $in : $outc), "\n");
    exit 0;
}
my $content = slurp($file);
if ($mode eq 'main') {
    if (index($content, '/*[AG_PATCHED]*/') >= 0 || index($content, '[AG_PROXY_HOOK]') >= 0) {
        print STDERR "старая версия патча — нужна чистая переустановка IDE\n";
        exit 3;
    }
    exit 2 if has_marker($content);
    my $re = qr/async\s+([A-Za-z_\$0-9]+)\(([A-Za-z_\$0-9]+)\)\s*\{\s*if\(this\.([A-Za-z_\$0-9]+)\.send\(\{type:[A-Za-z_\$0-9]+\.isGcpTos\?"GCP_SIGN_IN":"SIGN_IN"\}\),this\.([A-Za-z_\$0-9]+)\.resetIsTierGCPTos\(\),this\.[A-Za-z_\$0-9]+\.isGoogleInternal\)\{try\{await this\.([A-Za-z_\$0-9]+)\.loadCodeAssist\([A-Za-z_\$0-9]+\);const\{settings:([A-Za-z_\$0-9]+),userTier:([A-Za-z_\$0-9]+)\}=await this\.refreshUserStatus\([A-Za-z_\$0-9]+\),([A-Za-z_\$0-9]+)=([A-Za-z_\$0-9]+)\([A-Za-z_\$0-9]+\);this\.([A-Za-z_\$0-9]+)\.pushUpdate\([A-Za-z_\$0-9]+\),this\.[A-Za-z_\$0-9]+\.send\(\{type:"AUTH_SUCCESS",tokenInfo:[A-Za-z_\$0-9]+\}\),this\.([A-Za-z_\$0-9]+)\.fire\(\{settings:[A-Za-z_\$0-9]+,userTier:[A-Za-z_\$0-9]+\}\)\}catch\(([A-Za-z_\$0-9]+)\)\{.*?(?:return\}|return;\s*\})/;
    unless ($content =~ /$re/) {
        print STDERR "сигнатура не найдена\n";
        exit 4;
    }
    my ($fname, $t, $send, $y, $i, $func, $f, $h) = ($1, $2, $3, $4, $8, $9, $10, $11);
    my $payload = <<"EOP";
async $fname($t){
    this.$send.send({type:$t.isGcpTos?"GCP_SIGN_IN":"SIGN_IN"});
    this.$y.resetIsTierGCPTos();
    try {
        try { await this.$y.loadCodeAssist($t); } catch(_) {}
        try { await this.$y.onboardUser("standard-tier", $t); } catch(_) {
            try { await this.$y.onboardUser("free-tier", $t); } catch(__) {}
        }
        let __res = { settings: {}, userTier: { id: "pro", description: "Pro" } };
        try { __res = await this.refreshUserStatus($t); } catch(_) {}
        const $i = $func($t);
        try { this.$f.pushUpdate($i); } catch(_) {}
        this.$send.send({type:"AUTH_SUCCESS",tokenInfo:$t});
        this.$h.fire({settings:__res.settings, userTier:__res.userTier});
    } catch(e) {}
    return;
EOP
    my $new = substr($content, 0, $-[0]) . $payload . substr($content, $+[0]);
    $new .= "// UNLOCKED\n";
    backup_once($file);
    write_atomic($file, $new);
    print "PATCHED\n";
    exit 0;
}
if ($mode eq 'ext') {
    exit 2 if index($content, '/*[AG_EXT_PATCHED]*/') >= 0;
    my $re = qr/const t=await ([A-Za-z_\$][A-Za-z_\$0-9.]*)\.UserStatus\.getUserStatus\(\);if\(!t\)return\[\];const n=\(0,([A-Za-z_\$][A-Za-z_\$0-9.]*)\)\(t,([A-Za-z_\$][A-Za-z_\$0-9.]*)\),\{email:([A-Za-z_\$][A-Za-z_\$0-9]*),name:([A-Za-z_\$][A-Za-z_\$0-9]*)\}=n;return""===([A-Za-z_\$][A-Za-z_\$0-9]*)\?\[\]:/;
    unless ($content =~ /$re/) {
        print STDERR "сигнатура extension.js не найдена\n";
        exit 4;
    }
    my ($ns, $p2, $dz7, $email, $name) = ($1, $2, $3, $4, $5);
    my $rep = "const t=await $ns.UserStatus.getUserStatus();let $email=\"\",$name=\"\";try{if(t){const n=(0,$p2)(t,$dz7);$email=n.email||\"\";$name=n.name||\"\";}}catch(_){}if($email===\"\"){$email=\"antigravity-user\";$name=\"User\";}return false?[]:";
    $content = substr($content, 0, $-[0]) . $rep . substr($content, $+[0]);
    $content = "/*[AG_EXT_PATCHED]*/\n$content\n// UNLOCKED\n";
    backup_once($file);
    write_atomic($file, $content);
    print "PATCHED\n";
    exit 0;
}
die "неизвестный режим: $mode\n";
PERLEOF
}

# Применить JS-патчи IDE (если эта установка — IDE). Не IDE -> молча return 1.
patch_ide_js() {
  local RES="$1"
  local main_js="$RES/app/out/main.js"
  local ext_js="$RES/app/extensions/antigravity/dist/extension.js"
  [ -f "$main_js" ] || return 1
  ensure_helper
  local out rc
  out=$(perl "$HELPER" main "$main_js" 2>&1); rc=$?
  case $rc in
    0)
      # если есть node — верифицируем синтаксис; при поломке откатываем из бэкапа
      if command -v node >/dev/null 2>&1 && ! node --check "$main_js" 2>/dev/null; then
        perl "$HELPER" revert "$main_js" >/dev/null 2>&1
        err "main.js после патча не парсится — откачен из бэкапа. Сообщи автору скрипта."
        return 1
      fi
      ok "IDE: main.js пропатчен (auth-функция перезаписана)"
      ;;
    2) ok "IDE: main.js уже пропатчен" ;;
    3) err "IDE: обнаружена старая версия патча в main.js — переустанови IDE чисто и повтори"; return 1 ;;
    4) err "IDE: сигнатура main.js не найдена — новая версия IDE? JS не тронут"; return 1 ;;
    *) err "IDE main.js: $out"; return 1 ;;
  esac
  # extension.js — косметика (fallback имени юзера), ошибка не фатальна (как у оригинала)
  if [ -f "$ext_js" ]; then
    out=$(perl "$HELPER" ext "$ext_js" 2>&1)
    case $? in
      0) ok "IDE: extension.js пропатчен" ;;
      2) ok "IDE: extension.js уже пропатчен" ;;
      *) info "IDE: extension.js пропущен ($out) — не критично" ;;
    esac
  fi
  return 0
}

# Откат JS-правок IDE из .ag_backup (byte-exact).
revert_ide_js() {
  local RES="$1"
  local main_js="$RES/app/out/main.js"
  local ext_js="$RES/app/extensions/antigravity/dist/extension.js"
  ensure_helper
  local f out rc
  for f in "$main_js" "$ext_js"; do
    [ -e "$f" ] || [ -e "$f.ag_backup" ] || continue
    out=$(perl "$HELPER" revert "$f" 2>&1); rc=$?
    case $rc in
      0) ok "JS восстановлен из бэкапа: $f" ;;
      2) : ;;  # нечего откатывать
      *) warn "JS revert $f: $out" ;;
    esac
  done
}

# Полный патч одной установки: бинари + (для IDE) JS.
patch_install() {
  local RES="$1"; local rc=0
  info "=== Установка: $RES"
  patch_binaries "$RES" || rc=1
  if [ -f "$RES/app/out/main.js" ]; then
    patch_ide_js "$RES" || rc=1
  fi
  return $rc
}

# ---------------------------------------------------------------- DNS pin
DIG_OPT=""
HAS_DIG=0
DEAD_RESOLVERS=""
LIVE_RESOLVERS=""
RESOLVE_OUT=""

is_dead_resolver() {
  case "$DEAD_RESOLVERS" in *"|$1|"*) return 0 ;; esac
  return 1
}
mark_live_resolver() {
  case "$LIVE_RESOLVERS" in *"|$1|"*) return 0 ;; esac
  LIVE_RESOLVERS="$LIVE_RESOLVERS|$1|"
}
mark_dead_resolver() {
  # Баним до конца прогона только тех, кто не ответил ни разу (мертвые ноды)
  case "$LIVE_RESOLVERS" in *"|$1|"*) return 0 ;; esac
  is_dead_resolver "$1" || DEAD_RESOLVERS="$DEAD_RESOLVERS|$1|"
}

# если UDP/53 наружу закрыт (VM/корпоративные сети), но TCP работает — переключаемся на DNS over TCP
detect_dns_transport() {
  HAS_DIG=0
  if ! command -v dig >/dev/null 2>&1; then
    warn "dig не найден (пакет dnsutils / bind-utils) — UDP-провайдеры пропущены, работаю через DoH"
    return 0
  fi
  HAS_DIG=1
  if [ -z "$(dig +short +time=2 +tries=1 A google.com @8.8.8.8 2>/dev/null)" ]; then
    if [ -n "$(dig +short +tcp +time=2 +tries=1 A google.com @8.8.8.8 2>/dev/null)" ]; then
      DIG_OPT="+tcp"
      info "UDP/53 недоступен — использую DNS over TCP"
    fi
  fi
}

dig_a() { # $1 = domain, $2 = server -> RESOLVE_OUT
  RESOLVE_OUT=""
  [ "$HAS_DIG" -eq 1 ] || return 1
  is_dead_resolver "udp:$2" && return 1
  local out
  out=$(dig $DIG_OPT +short +time=2 +tries=1 A "$1" @"$2" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u)
  if [ -z "$out" ] && [ -z "$DIG_OPT" ]; then
    out=$(dig +tcp +short +time=2 +tries=1 A "$1" @"$2" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u)
  fi
  if [ -z "$out" ]; then
    mark_dead_resolver "udp:$2"
    return 1
  fi
  mark_live_resolver "udp:$2"
  RESOLVE_OUT="$out"
  return 0
}

ref_net16() {
  local r out=""
  if [ "$HAS_DIG" -eq 1 ]; then
    for r in "${REFERENCE[@]}"; do
      out="$out
$(dig $DIG_OPT +short +time=3 +tries=1 A "$1" @"$r" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$')"
    done
  else
    ensure_helper
    local b64 tmp="${TMPDIR:-/tmp}/.ag_ref.$$"
    b64=$(perl "$HELPER" query "$1") || true
    for r in "https://1.1.1.1/dns-query" "https://8.8.8.8/dns-query"; do
      if curl -s --connect-timeout 3 --max-time 4 "${r}?dns=$b64" -H "accept: application/dns-message" -o "$tmp" 2>/dev/null; then
        out="$out
$(perl "$HELPER" parse "$tmp" 2>/dev/null)"
      fi
    done
    rm -f "$tmp"
  fi
  printf '%s\n' "$out" | sed '/^$/d' | cut -d. -f1,2 | sort -u
}

# Отсекаем локальные/служебные адреса (вкл. VPN FakeIP 198.18/15) и известные
# клиентские диапазоны Google (AS15169): иначе честный Google IP из соседней /16
# (например 142.251.* при эталоне 172.217.*) ошибочно примется за прокси.
is_non_proxy_ip() {
  local ip="$1" ref_blocks="$2"
  local o1 o2 net16
  IFS='.' read -r o1 o2 _ _ <<< "$ip"
  net16="$o1.$o2"
  echo "$ref_blocks" | grep -qx "$net16" && return 0
  case "$o1" in
    0|10|127) return 0 ;;
  esac
  [ "$o1" -ge 224 ] 2>/dev/null && return 0
  case "$net16" in
    169.254|192.168|198.18|198.19) return 0 ;;
    142.250|142.251|172.217|172.253|74.125|64.233|108.177|209.85|216.58|216.239) return 0 ;;
  esac
  [ "$o1" -eq 172 ] && [ "$o2" -ge 16 ] && [ "$o2" -le 31 ] && return 0
  [ "$o1" -eq 100 ] && [ "$o2" -ge 64 ] && [ "$o2" -le 127 ] && return 0
  return 1
}

# --- обход VPN для DoH-запросов: бинд на физический интерфейс (root есть)
VPN_ON=0; CURL_IF=""
vpn_active() {
  ip -4 route show default 2>/dev/null | grep -qE 'dev (tun|wg|tap|utun|ppp|nordlynx|tailscale)'
}
phys_iface() {
  ip -4 route show default 2>/dev/null | grep -vE 'dev (tun|wg|tap|utun|ppp|nordlynx|tailscale)' | head -1 \
    | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}
setup_curl_bypass() {
  VPN_ON=0; CURL_IF=""
  vpn_active || return 0
  VPN_ON=1
  local dev; dev=$(phys_iface)
  [ -n "$dev" ] && CURL_IF="--interface $dev"
  info "VPN активен — DoH-запросы пойдут мимо туннеля${dev:+ через $dev} (с авто-fallback, если физический интерфейс заблокирован)"
}

# DoH A-запрос к одному провайдеру ("host|ip1,ip2|h1|h2") -> RESOLVE_OUT: IPv4 построчно
doh_a_one() {
  ensure_helper
  RESOLVE_OUT=""
  local dom="$1" spec="$2"
  local host="${spec%%|*}" rest="${spec#*|}"
  local ips="${rest%%|*}" proto="${rest##*|}"
  local h2=""; [ "$proto" = "h2" ] && h2="--http2"
  local b64 ip out tmp="${TMPDIR:-/tmp}/.ag_doh.$$"
  b64=$(perl "$HELPER" query "$dom") || return 1
  for ip in ${ips//,/ }; do
    is_dead_resolver "doh:$host:$ip" && continue
    local got=0
    if [ -n "$CURL_IF" ]; then
      if curl -s $CURL_IF $h2 --connect-timeout 2 --max-time 3 --resolve "$host:443:$ip" \
           "https://$host/dns-query?dns=$b64" -H "accept: application/dns-message" -o "$tmp" 2>/dev/null; then
        out=$(perl "$HELPER" parse "$tmp" 2>/dev/null)
        [ -n "$out" ] && got=1
      fi
    fi
    if [ "$got" -eq 0 ]; then
      if curl -s $h2 --connect-timeout 2 --max-time 3 --resolve "$host:443:$ip" \
           "https://$host/dns-query?dns=$b64" -H "accept: application/dns-message" -o "$tmp" 2>/dev/null; then
        out=$(perl "$HELPER" parse "$tmp" 2>/dev/null)
        [ -n "$out" ] && got=1
      fi
    fi
    if [ "$got" -eq 1 ]; then
      rm -f "$tmp"
      mark_live_resolver "doh:$host:$ip"
      RESOLVE_OUT="$out"
      return 0
    fi
    mark_dead_resolver "doh:$host:$ip"
  done
  rm -f "$tmp"
  return 1
}

doh_custom_url() {
  ensure_helper
  RESOLVE_OUT=""
  local dom="$1" url="$2"
  is_dead_resolver "cdoh:$url" && return 1
  local b64 out tmp="${TMPDIR:-/tmp}/.ag_doh.$$" sep="?"
  case "$url" in *\?*) sep="&" ;; esac
  b64=$(perl "$HELPER" query "$dom") || return 1
  if curl -s $CURL_IF --connect-timeout 3 --max-time 4 \
       "${url}${sep}dns=$b64" -H "accept: application/dns-message" -o "$tmp" 2>/dev/null; then
    out=$(perl "$HELPER" parse "$tmp" 2>/dev/null)
    if [ -n "$out" ]; then rm -f "$tmp"; RESOLVE_OUT="$out"; return 0; fi
  fi
  if [ -n "$CURL_IF" ] && curl -s --connect-timeout 3 --max-time 4 \
       "${url}${sep}dns=$b64" -H "accept: application/dns-message" -o "$tmp" 2>/dev/null; then
    out=$(perl "$HELPER" parse "$tmp" 2>/dev/null)
    if [ -n "$out" ]; then rm -f "$tmp"; RESOLVE_OUT="$out"; return 0; fi
  fi
  rm -f "$tmp"
  mark_dead_resolver "cdoh:$url"
  return 1
}

# Боевая проба: живой Google-ответ с валидным TLS-сертификатом через кандидата.
# $3 = "bypass" -> проба мимо VPN-туннеля ($CURL_IF).
probe_ip() { # $1=domain $2=ip [$3=bypass] -> stdout: latency; exit 0 если жив
  local iface_opt=""
  [ "$3" = "bypass" ] && iface_opt="$CURL_IF"
  local out code
  out=$(curl -s $iface_opt --connect-timeout 3 --max-time 5 --resolve "$1:443:$2" \
    "https://$1/" -o /dev/null -w '%{http_code} %{time_total}' 2>/dev/null) || return 1
  code="${out%% *}"
  case "$code" in
    2*|3*|4*) echo "${out##* }"; return 0 ;;
  esac
  return 1
}

dns_pin() {
  # PIN_LINES — строки для блока /etc/hosts ("<ip> <domain>" или "<ip> <domain> # ag-bypass").
  # Проба проверяет сначала дефолтный маршрут; если под VPN дефолт не достучался,
  # пробуем мимо туннеля ($CURL_IF) и ставим /32 маршрут только для таких IP.
  local domain ip prov spec
  DEAD_RESOLVERS=""; LIVE_RESOLVERS=""
  detect_dns_transport
  setup_curl_bypass
  PIN_LINES=""
  local any_substituted=0 daily_pinned=0
  local all_udp=("${PROVIDERS[@]}")
  local custom_doh=()
  if [ -n "${AG_CUSTOM_DNS:-}" ]; then
    local citem
    for citem in ${AG_CUSTOM_DNS//,/ }; do
      case "$citem" in
        https://*) custom_doh+=("$citem") ;;
        *) echo "$citem" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' && all_udp+=("$citem") ;;
      esac
    done
  fi

  for domain in "${DOMAINS[@]}"; do
    local ref_blocks
    ref_blocks=$(ref_net16 "$domain")
    [ -z "$ref_blocks" ] && { warn "эталон не ответил для $domain — пропуск"; continue; }
    local cand=""
    for prov in "${all_udp[@]}"; do
      dig_a "$domain" "$prov" || continue
      local sub=""
      while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        is_non_proxy_ip "$ip" "$ref_blocks" || sub="$sub $ip"
      done <<< "$RESOLVE_OUT"
      if [ -n "$sub" ]; then
        any_substituted=1
        info "$domain @ $prov -> подмена:$(echo $sub | tr ' ' ',')"
        cand="$cand $sub"
      fi
    done
    for spec in "${DOH_PROVIDERS[@]}"; do
      doh_a_one "$domain" "$spec" || continue
      local sub=""
      while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        is_non_proxy_ip "$ip" "$ref_blocks" || sub="$sub $ip"
      done <<< "$RESOLVE_OUT"
      if [ -n "$sub" ]; then
        any_substituted=1
        info "$domain @ ${spec%%|*} (DoH) -> подмена:$(echo $sub | tr ' ' ',')"
        cand="$cand $sub"
      fi
    done
    for spec in "${custom_doh[@]}"; do
      doh_custom_url "$domain" "$spec" || continue
      local sub=""
      while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        is_non_proxy_ip "$ip" "$ref_blocks" || sub="$sub $ip"
      done <<< "$RESOLVE_OUT"
      if [ -n "$sub" ]; then
        any_substituted=1
        info "$domain @ custom DoH -> подмена:$(echo $sub | tr ' ' ',')"
        cand="$cand $sub"
      fi
    done
    cand=$(echo $cand | tr ' ' '\n' | sed '/^$/d' | sort -u)
    if [ -z "$cand" ]; then
      warn "$domain: подмены нет ни у одного провайдера — домен не пиную"
      continue
    fi
    # Параллельные боевые пробы всех кандидатов домена (быстрее в 5-10x)
    local ptmp="${TMPDIR:-/tmp}/.ag_probe.$$"
    : > "$ptmp"
    while IFS= read -r ip; do
      [ -z "$ip" ] && continue
      (
        local t
        if t=$(probe_ip "$domain" "$ip"); then
          printf '%s %s default\n' "$t" "$ip" >> "$ptmp"
        elif [ "$VPN_ON" -eq 1 ] && [ -n "$CURL_IF" ] && t=$(probe_ip "$domain" "$ip" bypass); then
          printf '%s %s bypass\n' "$t" "$ip" >> "$ptmp"
        else
          warn "$ip: боевая проба не прошла — не пиную"
        fi
      ) &
    done <<< "$cand"
    wait
    local scored
    scored=$(sort -n "$ptmp" 2>/dev/null | head -2)
    rm -f "$ptmp"
    local line
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      local sip mode
      sip=$(echo "$line" | awk '{print $2}')
      mode=$(echo "$line" | awk '{print $3}')
      if [ "$mode" = "bypass" ]; then
        PIN_LINES="${PIN_LINES}${sip} ${domain} # ag-bypass
"
      else
        PIN_LINES="${PIN_LINES}${sip} ${domain}
"
      fi
      [ "$domain" = "daily-cloudcode-pa.googleapis.com" ] && daily_pinned=1
    done <<< "$scored"
  done

  if [ "$any_substituted" -eq 0 ] || [ -z "$(printf '%s' "$PIN_LINES" | tr -d ' \n')" ]; then
    err "Ни один провайдер не отдал рабочих прокси-адресов (UDP и DoH)."
    warn "Варианты: ты не в регионе подмены, провайдер режет прокси или узлы сейчас недоступны."
    warn "Режим с VPN (пункт 2) от этого не зависит — достаточно VPN с не-датацентровым выходом."
    return 1
  fi

  write_hosts_block
  if [ "$daily_pinned" -eq 0 ]; then
    warn "Внимание: для основного домена daily-cloudcode-pa.googleapis.com рабочих прокси не нашлось — Desktop/CLI могут получать HTTP 400."
  fi
}

write_hosts_block() {
  drop_pin_routes
  local tmp="$HOSTS.ag_tmp"
  if grep -q "$MARKER_BEGIN" "$HOSTS" 2>/dev/null; then
    sed "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" "$HOSTS" > "$tmp" && mv "$tmp" "$HOSTS"
  fi
  {
    echo "$MARKER_BEGIN"
    printf '%s' "$PIN_LINES" | sed '/^$/d'
    echo "$MARKER_END"
  } >> "$HOSTS"
  # сброс кеша: systemd-resolved и/или nscd — если есть
  systemctl is-active systemd-resolved >/dev/null 2>&1 && resolvectl flush-caches 2>/dev/null
  [ -x /usr/sbin/nscd ] && nscd -i hosts 2>/dev/null
  ok "Пропинено в $HOSTS:"
  sed -n "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/p" "$HOSTS" | sed '1d;$d' | sed 's/^/    /'
  ensure_pin_routes
}

# --- host-routes мимо VPN-туннеля: ставятся ТОЛЬКО для прокси с пометкой # ag-bypass
phys_gw() {
  ip -4 route show default 2>/dev/null | grep -vE 'dev (tun|wg|tap|utun|ppp|nordlynx|tailscale)' | head -1 \
    | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}'
}

ensure_pin_routes() {
  [ "$(id -u)" -eq 0 ] || return 0
  if ! vpn_active; then
    drop_pin_routes   # VPN выключен — /32 не нужны, а протухшие могут чёрнодырить
    return 0
  fi
  local gw dev; gw=$(phys_gw); dev=$(phys_iface); [ -z "$gw" ] || [ -z "$dev" ] && return 0
  local ip n=0
  for ip in $(sed -n "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/p" "$HOSTS" 2>/dev/null | awk '/# ag-bypass/ {print $1}' | sort -u); do
    ip route replace "$ip/32" via "$gw" dev "$dev" 2>/dev/null && n=$((n+1))
  done
  [ "$n" -gt 0 ] && info "VPN активен: $n маршрут(ов) на прокси-IP прописаны мимо туннеля (via $gw)"
}

drop_pin_routes() {
  [ "$(id -u)" -eq 0 ] || return 0
  local ip
  for ip in $(sed -n "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/p" "$HOSTS" 2>/dev/null | awk 'NF>=2 && $1 !~ /^#/ {print $1}' | sort -u); do
    ip route del "$ip/32" 2>/dev/null
  done
}

remove_hosts_block() {
  drop_pin_routes
  if grep -q "$MARKER_BEGIN" "$HOSTS" 2>/dev/null; then
    sed "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" "$HOSTS" > "$HOSTS.ag_tmp" && mv "$HOSTS.ag_tmp" "$HOSTS"
    systemctl is-active systemd-resolved >/dev/null 2>&1 && resolvectl flush-caches 2>/dev/null
    [ -x /usr/sbin/nscd ] && nscd -i hosts 2>/dev/null
    ok "hosts-блок удалён"
  else
    info "hosts-блок не найден"
  fi
}

# ---------------------------------------------------------------- watchdog
# Авто-репатч после обновлений (порт watchdog.rs оригинала): settle-правило
# (size:mtime стабильны два тика), сигнатуры нет -> не трогаем до смены файла,
# полный откат (пункт 5) выключает watchdog флагом-отказом.
WATCH_LABEL="ag-unlocker-watch"
WATCH_UNIT="$REAL_HOME/.config/systemd/user/$WATCH_LABEL.service"
DECLINE_FLAG="$REAL_HOME/.ag_unlocker_no_watch"
WATCH_STATE="${TMPDIR:-/tmp}/.ag_watch_state.$REAL_UID"
WATCH_LOG="/tmp/ag_unlocker_watch.$REAL_UID.log"

f_sig() { stat -c '%s:%Y' "$1" 2>/dev/null || echo absent; }
state_name() { printf '%s' "$1" | md5sum | cut -d' ' -f1; }

watch_loop() {
  mkdir -p "$WATCH_STATE"
  echo "$(date '+%F %T') watchdog стартанул (pid $$, uid $(id -u))" >> "$WATCH_LOG"
  local tick=0
  while true; do
    if [ -f "$DECLINE_FLAG" ]; then
      echo "$(date '+%F %T') decline-флаг — выход" >> "$WATCH_LOG"; exit 0
    fi
    find_installs 2>/dev/null || true
    local targets="" RES f rp
    for f in "${AGY_BINS[@]}"; do
      [ -f "$f" ] && targets="$targets$f
"
    done
    for RES in "${INSTALLS[@]}"; do
      for f in "$RES"/bin/language_server* \
               "$RES"/app/extensions/antigravity/bin/language_server* \
               "$RES/app/out/main.js" \
               "$RES/app/extensions/antigravity/dist/extension.js"; do
        [ -e "$f" ] || continue
        case "$f" in *.agtmp|*.ag_backup|*.log|*.txt) continue ;; esac
        rp=$(resolve_path "$f")
        [ -f "$rp" ] && targets="$targets$rp
"
      done
    done
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      local cur st last pending
      cur=$(f_sig "$f"); [ "$cur" = "absent" ] && continue
      st="$WATCH_STATE/$(state_name "$f")"
      last=""; pending=0
      [ -f "$st" ] && { last=$(sed -n 1p "$st"); pending=$(sed -n 2p "$st"); }
      if [ "$cur" != "$last" ]; then
        printf '%s\n1\n' "$cur" > "$st"   # сменился — ждём второй тик (settle)
        continue
      fi
      [ "$pending" = "1" ] || continue
      ensure_helper
      case "$f" in
        *.js)
          local mode="main"
          case "$f" in *extension.js) mode="ext" ;; esac
          local out rc
          out=$(perl "$HELPER" "$mode" "$f" 2>&1); rc=$?
          case $rc in
            0) echo "$(date '+%F %T') repatch JS: $f" >> "$WATCH_LOG" ;;
            2) : ;;
            *) echo "$(date '+%F %T') JS $f: rc=$rc $out (жду смены файла)" >> "$WATCH_LOG" ;;
          esac
          ;;
        *)
          is_elf_target "$f" || { printf '%s\n0\n' "$cur" > "$st"; continue; }
          local n rc
          n=$(perl "$HELPER" bpatch "$f" 2>/dev/null); rc=$?
          case $rc in
            0) echo "$(date '+%F %T') repatch bin ($n вхожд.): $f" >> "$WATCH_LOG" ;;
            2) : ;;
            *) echo "$(date '+%F %T') bin $f: нет сигнатуры/ошибка rc=$rc (жду смены файла)" >> "$WATCH_LOG" ;;
          esac
          ;;
      esac
      printf '%s\n0\n' "$cur" > "$st"
    done <<< "$targets"
    # рефреш hosts-пина раз в ~10 мин: проверяем только реально запиненные домены
    tick=$((tick+1))
    if [ $((tick % 300)) -eq 0 ] && grep -q "$MARKER_BEGIN" "$HOSTS" 2>/dev/null; then
      if [ -w "$HOSTS" ]; then
        setup_curl_bypass >/dev/null 2>&1
        local need=0 domain line ip mode seen alive
        for domain in "${DOMAINS[@]}"; do
          seen=0; alive=0
          while IFS= read -r line; do
            [ -z "$line" ] && continue
            seen=1
            ip=$(echo "$line" | awk '{print $1}')
            mode=""
            case "$line" in *"# ag-bypass"*) mode="bypass" ;; esac
            probe_ip "$domain" "$ip" "$mode" >/dev/null 2>&1 && alive=1 && break
          done <<< "$(sed -n "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/p" "$HOSTS" | awk -v d="$domain" '$2==d {print}')"
          [ "$seen" = "1" ] && [ "$alive" = "0" ] && need=1
        done
        [ "$need" = "1" ] && { echo "$(date '+%F %T') пин протух — рефреш" >> "$WATCH_LOG"; dns_pin >> "$WATCH_LOG" 2>&1; }
        ensure_pin_routes 2>/dev/null
      else
        echo "$(date '+%F %T') hosts недоступен на запись из watchdog — рефреш вручную (пункт 3)" >> "$WATCH_LOG"
      fi
    fi
    sleep 2
  done
}

run_systemctl_user() {
  if [ "$(id -u)" -eq 0 ]; then
    if [ -z "${SUDO_USER:-}" ] || [ ! -S "/run/user/$REAL_UID/bus" ]; then
      echo "скрипт запущен от root без user-сессии systemd — запусти без sudo: bash ag_unlocker_linux.sh"
      return 1
    fi
    sudo -u "$REAL_USER" \
      XDG_RUNTIME_DIR="/run/user/$REAL_UID" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$REAL_UID/bus" \
      systemctl --user "$@"
  else
    systemctl --user "$@"
  fi
}

install_watchdog() {
  command -v systemctl >/dev/null 2>&1 || { err "systemd не найден — watchdog не ставится"; return 1; }
  if [ "$(id -u)" -eq 0 ] && [ -z "${SUDO_USER:-}" ]; then
    err "Watchdog (systemd --user) должен ставиться в пользовательскую сессию. Запусти без sudo: bash $SELF_SCRIPT"
    return 1
  fi
  rm -f "$DECLINE_FLAG"
  mkdir -p "$REAL_HOME/.config/systemd/user"
  cat > "$WATCH_UNIT" <<EOF
[Unit]
Description=Antigravity unlocker watchdog (auto-repatch)

[Service]
ExecStart=/bin/bash "$SELF_SCRIPT" --watch
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    chown -R "$REAL_USER" "$REAL_HOME/.config/systemd/user" 2>/dev/null || true
  fi
  local sc_err
  if ! sc_err=$(run_systemctl_user daemon-reload 2>&1); then
    err "systemctl --user daemon-reload не удался: ${sc_err:-неизвестная ошибка}"
    rm -f "$WATCH_UNIT"
    return 1
  fi
  if sc_err=$(run_systemctl_user enable --now "$WATCH_LABEL.service" 2>&1); then
    ok "Watchdog установлен (systemd --user, Restart=always). Лог: $WATCH_LOG"
    loginctl enable-linger "$REAL_USER" 2>/dev/null || true
    info "После автообновления Antigravity патч восстановится сам через ~5 секунд."
    info "Установка в /opt от root: репатч оттуда требует прав — watchdog напишет в лог."
  else
    err "systemctl --user не удался: ${sc_err:-неизвестная ошибка}"
    rm -f "$WATCH_UNIT"
    return 1
  fi
}

uninstall_watchdog() {
  if [ -f "$WATCH_UNIT" ]; then
    run_systemctl_user disable --now "$WATCH_LABEL.service" >/dev/null 2>&1 && ok "Watchdog остановлен"
    rm -f "$WATCH_UNIT"
    run_systemctl_user daemon-reload >/dev/null 2>&1 || true
  fi
}

# ---------------------------------------------------------------- status
show_status() {
  find_installs || { err "Antigravity не найден"; return 1; }
  local RES
  for RES in "${INSTALLS[@]}"; do
    info "Установка: $RES"
    if [ -f "$RES/app/out/main.js" ]; then
      say "    продукт: Antigravity IDE"
      if tail -c 200 "$RES/app/out/main.js" | grep -q "^// UNLOCKED"; then
        ok "IDE main.js: пропатчен"
      else
        warn "IDE main.js: НЕ пропатчен"
      fi
    else
      say "    продукт: Antigravity Desktop"
      check_arch "$RES"
    fi
    collect_targets "$RES"
    local f in_cnt out_cnt
    if [ ${#TARGETS[@]} -eq 0 ] && [ -d "$RES/app/extensions/agy" ]; then
      info "IDE 2.6+: бэкенд вынесен в ~/.gemini/bin/agy (см. ниже)"
    fi
    for f in "${TARGETS[@]}"; do
      in_cnt=$(perl -0777 -ne 'my $c=()=/ineligible/g; print $c' "$f" 2>/dev/null || echo 0)
      out_cnt=$(perl -0777 -ne 'my $c=()=/inexigible/g; print $c' "$f" 2>/dev/null || echo 0)
      if [ "$out_cnt" -gt 0 ]; then
        ok "пропатчен: $f (inexigible: $out_cnt)"
      elif [ "$in_cnt" -gt 0 ]; then
        warn "НЕ пропатчен: $f (ineligible: $in_cnt)"
      else
        warn "строки нет — новая сборка?: $f"
      fi
    done
  done
  local agy
  for agy in "${AGY_BINS[@]}"; do
    local i o
    i=$(perl -0777 -ne 'my $c=()=/ineligible/g; print $c' "$agy" 2>/dev/null || echo 0)
    o=$(perl -0777 -ne 'my $c=()=/inexigible/g; print $c' "$agy" 2>/dev/null || echo 0)
    if [ "$o" -gt 0 ]; then
      ok "agy пропатчен ($o вхожд.): $agy"
    elif [ "$i" -gt 0 ]; then
      warn "agy НЕ пропатчен ($i вхожд.): $agy"
    else
      warn "agy: строка не найдена — новая сборка?: $agy"
    fi
  done
  if grep -q "$MARKER_BEGIN" "$HOSTS" 2>/dev/null; then
    ok "hosts-блок:"
    sed -n "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/p" "$HOSTS" | sed '1d;$d' | sed 's/^/    /'
    if ! sed -n "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/p" "$HOSTS" | grep -q "daily-cloudcode-pa.googleapis.com"; then
      warn "В hosts-блоке нет daily-cloudcode-pa.googleapis.com — обнови DNS-пин (пункт 3)"
    fi
  else
    info "hosts-блока нет (режим «без VPN» не настроен)"
  fi
  if vpn_active; then
    local dev; dev=$(phys_iface)
    info "Сеть: VPN активен (физический интерфейс: ${dev:-не определён})"
  else
    info "Сеть: VPN не обнаружен"
  fi
  if [ -f "$WATCH_UNIT" ]; then
    if run_systemctl_user is-active "$WATCH_LABEL.service" >/dev/null 2>&1; then
      ok "Watchdog: установлен и активен ($WATCH_UNIT)"
    else
      warn "Watchdog: юнит есть, но сервис не активен ($WATCH_UNIT)"
    fi
  else
    info "Watchdog: выключен"
  fi
}

# ---------------------------------------------------------------- privileged dispatch & main
dispatch_privileged() {
  local action="$1"
  find_installs || true
  case "$action" in
    unlock)
      [ ${#INSTALLS[@]} -eq 0 ] && [ ${#AGY_BINS[@]} -eq 0 ] && { err "Antigravity не найден"; return 1; }
      kill_processes
      local RES
      for RES in "${INSTALLS[@]}"; do patch_install "$RES"; done
      patch_cli
      dns_pin
      ;;
    patch)
      [ ${#INSTALLS[@]} -eq 0 ] && [ ${#AGY_BINS[@]} -eq 0 ] && { err "Antigravity не найден"; return 1; }
      kill_processes
      local RES
      for RES in "${INSTALLS[@]}"; do patch_install "$RES"; done
      patch_cli
      ;;
    dns_pin)
      dns_pin
      ;;
    revert)
      kill_processes
      local RES
      for RES in "${INSTALLS[@]}"; do unpatch_binaries "$RES"; revert_ide_js "$RES"; done
      revert_cli
      remove_hosts_block
      ;;
    *) err "Неизвестное действие: $action"; return 1 ;;
  esac
}

trap '[ -n "$HELPER" ] && rm -f "$HELPER" 2>/dev/null' EXIT

case "$1" in
  --watch)      AG_NO_ELEVATE=1; watch_loop; exit 0 ;;
  --privileged) dispatch_privileged "$2"; exit $? ;;
esac

find_installs || true
if [ ${#INSTALLS[@]} -gt 0 ] || [ ${#AGY_BINS[@]} -gt 0 ]; then
  [ ${#INSTALLS[@]} -gt 0 ] && { say "Найдено установок: ${#INSTALLS[@]}"; printf '  - %s\n' "${INSTALLS[@]}"; }
  [ ${#AGY_BINS[@]} -gt 0 ] && { say "Найдено agy (CLI / IDE 2.6+ / VS Code): ${#AGY_BINS[@]}"; printf '  - %s\n' "${AGY_BINS[@]}"; }
else
  warn "Antigravity не найден. Установи .deb/.rpm, распакуй tar.gz, поставь CLI (agy) или расширение VS Code и перезапусти скрипт."
  warn "В AppImage-версии патч невозможен (файл временный) — используй .deb/.rpm/tar.gz."
fi

while true; do
  say ""
  say "===== Antigravity анлокер для Linux ====="
  say " 1) Разблокировать (патч + DNS-пин, все найденные установки)"
  say " 2) Только патч (для режима с VPN)"
  say " 3) Обновить DNS-пин (работает и при включённом VPN)"
  say " 4) Статус / диагностика"
  say " 5) Полный откат (снять патч и вернуть всё как было)"
  if [ -f "$WATCH_UNIT" ]; then
    say " 6) Watchdog: ВКЛЮЧЁН (авто-репатч после обновлений) — выключить"
  else
    say " 6) Watchdog: выключен — включить авто-репатч после обновлений"
  fi
  say " 0) Выход"
  printf "Выбор: "
  read -r choice || { say ""; exit 0; }
  case "$choice" in
    1) run_privileged unlock ;;
    2) run_privileged patch ;;
    3) run_privileged dns_pin ;;
    4) show_status ;;
    5) run_privileged revert
       uninstall_watchdog
       touch "$DECLINE_FLAG"
       [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && chown "$REAL_USER" "$DECLINE_FLAG" 2>/dev/null || true
       ok "Полный откат завершён." ;;
    6) if [ -f "$WATCH_UNIT" ]; then
         uninstall_watchdog
         touch "$DECLINE_FLAG"
         [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && chown "$REAL_USER" "$DECLINE_FLAG" 2>/dev/null || true
         ok "Watchdog выключен."
       else
         install_watchdog
       fi ;;
    0) exit 0 ;;
    *) warn "Неизвестный пункт меню" ;;
  esac
done
