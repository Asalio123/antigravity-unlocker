#!/bin/bash
# ============================================================================
#  AG Unlocker for macOS  —  порт confeden/Antigravity (Windows) на macOS
#  https://github.com/confeden/Antigravity
#
#  Цель: Google Antigravity (Desktop) и Antigravity IDE с antigravity.google/download.
#
#  Повторяет методы оригинала 1-в-1:
#    1) Байтовый патч: строка "ineligible" -> "inexigible" (обе по 10 байт,
#       размер файла не меняется, обратимо) в Language Server / agy.
#       В архитектуре Desktop v2.4+ вся проверка eligibility (auth/tier) живёт
#       в Language Server, поэтому Desktop ограничивается этим патчем.
#    1б) IDE дополнительно: перезапись auth-функции в
#       Contents/Resources/app/out/main.js (regex по минифицированному телу,
#       порт patch_ide.rs оригинала) + fallback имени в
#       app/extensions/antigravity/dist/extension.js. Бэкап <файл>.ag_backup
#       создаётся до первой правки; откат = restore из него. После правок
#       бандл переподписывается ad-hoc (codesign --force --deep --sign -).
#    2) DNS-пин: подмена ответов для
#          daily-cloudcode-pa.googleapis.com
#          generativelanguage.googleapis.com
#          cloudcode-pa.googleapis.com (endpoint IDE; если провайдеры его
#          не подменяют — домен просто не пинуется)
#       через "анблок"-DNS (eu.geohide.ru / dns.geohide.ru / dns.dns-ai.ru), которые
#       для российских клиентов отдают IP своих SNI-прокси вместо Google.
#       Провайдер считается подменяющим, если его ответ лежит ВНЕ /16-сетей
#       эталона (8.8.8.8 / 1.1.1.1) и вне известных клиентских диапазонов Google.
#       Живые прокси пинятся в /etc/hosts (маркеры AG_UNLOCKER_HOSTS_*).
#
#  Анблок-DNS подменяют ответы ТОЛЬКО клиентам, которых они геолоцируют
#  в блокируемом регионе. Состояние VPN не важно: DoH-запросы сначала идут
#  мимо туннеля через физический интерфейс (scoped routing macOS), а боевая
#  проба проверяет оба пути (через дефолт и мимо туннеля).
#
#  НЕ портировано из оригинала (намеренно):
#    - "fast route" через HTTPS_PROXY-релей (адреса и relay-ключ автор
#      вырезал из публичного репозитория);
#    - локальный DNS-релей (заменён пином в /etc/hosts + watchdog);
#    - IPv6 prefixpolicy-хак (на macOS /etc/hosts перекрывает DNS для
#      обеих адресных семей);
#    - Gemini CLI патчер (в оригинале помечен deprecated).
#
#  Только штатные инструменты macOS: bash, perl, dig, curl, codesign, plutil.
#  Запуск:  bash ag_unlocker_mac.sh  (sudo запросится только где нужны права)
# ============================================================================

MARKER_BEGIN="# AG_UNLOCKER_HOSTS_BEGIN"
MARKER_END="# AG_UNLOCKER_HOSTS_END"

HOSTS="${AG_HOSTS:-/etc/hosts}"   # AG_HOSTS=/tmp/hosts_test — для теста без правки системы
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
# "host|ip1,ip2,...|h1|h2" — h2 = только HTTP/2 (dns-ai на h1 отвечает 505)
DOH_PROVIDERS=(
  "dns.dns-ai.ru|194.87.196.13,45.151.102.219,185.251.90.181|h2"
  "dns.geohide.ru|37.230.192.51,45.155.204.190|h1"
)
REFERENCE=(8.8.8.8 1.1.1.1)

# Контекст реального пользователя: сохраняем даже при запуске через sudo,
# чтобы поиск в ~/, PATH и установка LaunchAgent работали в его GUI-сессии.
SELF_SCRIPT="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
REAL_USER="${AG_REAL_USER:-${SUDO_USER:-$(id -un)}}"
REAL_UID="${AG_REAL_UID:-${SUDO_UID:-$(id -u)}}"
if [ -n "${AG_REAL_HOME:-}" ]; then
  REAL_HOME="$AG_REAL_HOME"
elif [ -n "${SUDO_USER:-}" ]; then
  REAL_HOME=$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
fi
[ -z "$REAL_HOME" ] && REAL_HOME="$HOME"
USER_PATH="${AG_USER_PATH:-$PATH}"

APP_CANDIDATES=(
  "/Applications/Antigravity.app"
  "$REAL_HOME/Applications/Antigravity.app"
  "/Applications/Antigravity IDE.app"
  "$REAL_HOME/Applications/Antigravity IDE.app"
)
# ~/.gemini/bin/agy — бэкенд Antigravity IDE 2.6.0+ и расширения VS Code / Cursor / Windsurf
AGY_CANDIDATES=(
  "$REAL_HOME/.gemini/bin/agy"
  "/opt/homebrew/bin/agy"
  "/usr/local/bin/agy"
  "$REAL_HOME/.local/bin/agy"
  "$REAL_HOME/bin/agy"
)

C_OK='\033[32m'; C_WARN='\033[33m'; C_ERR='\033[31m'; C_INFO='\033[36m'; C_N='\033[0m'
say()  { printf "%b\n" "$1"; }
ok()   { say "${C_OK}[OK]${C_N} $1"; }
warn() { say "${C_WARN}[!]${C_N} $1"; }
err()  { say "${C_ERR}[X]${C_N} $1"; }
info() { say "${C_INFO}[i]${C_N} $1"; }

# Привилегированные операции (патч в /Applications, запись /etc/hosts, маршруты)
# запускаются через sudo точечно; меню и watchdog живут в контексте пользователя.
run_privileged() {
  local action="$1"
  if [ "$(id -u)" -eq 0 ] || [ -n "$AG_NO_ELEVATE" ]; then
    dispatch_privileged "$action"
    return $?
  fi
  info "Нужны права администратора — запрашиваю sudo..."
  sudo \
    AG_REAL_USER="$REAL_USER" \
    AG_REAL_UID="$REAL_UID" \
    AG_REAL_HOME="$REAL_HOME" \
    AG_USER_PATH="$USER_PATH" \
    AG_HOSTS="$HOSTS" \
    AG_APP="${AG_APP:-}" \
    AG_CUSTOM_DNS="${AG_CUSTOM_DNS:-}" \
    /bin/bash "$SELF_SCRIPT" --privileged "$action"
}

# ---------------------------------------------------------------- app discovery
# Резолв симлинка без GNU readlink -f (работает одинаково на любой macOS).
resolve_path() {
  perl -MCwd=abs_path -e 'my $r = abs_path($ARGV[0]); print(defined $r ? $r : $ARGV[0])' "$1" 2>/dev/null || echo "$1"
}

is_macho_target() {
  local f="$1"
  [ -f "$f" ] || return 1
  case "$f" in *.agtmp|*.ag_backup|*.log|*.txt) return 1 ;; esac
  file "$f" 2>/dev/null | grep -q "Mach-O"
}

# Desktop и IDE могут стоять одновременно (+ копии в /Applications и ~/Applications) —
# собираем ВСЕ найденные бандлы.
find_apps() {
  APPS=()
  local c
  if [ -n "$AG_APP" ] && [ -d "$AG_APP" ]; then
    APPS=("$AG_APP")
  else
    for c in "${APP_CANDIDATES[@]}"; do
      [ -d "$c" ] && APPS+=("$c")
    done
  fi
  collect_agy_bins
  [ ${#APPS[@]} -gt 0 ] || [ ${#AGY_BINS[@]} -gt 0 ]
}

# Все уникальные бинари agy: CLI из PATH + ~/.gemini/bin/agy (IDE 2.6+ и VS Code).
# Симлинки разворачиваются, чтобы atomic rename патчил реальный файл, а не рвал ссылку.
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
    is_macho_target "$rp" || continue
    case "$seen" in *"|$rp|"*) continue ;; esac
    seen="$seen|$rp|"
    AGY_BINS+=("$rp")
  done
}

# Патч-цели внутри одного .app: только Mach-O language_server* с целевой строкой.
# agy собирается отдельно (collect_agy_bins), чтобы не патчить его дважды.
collect_targets() {
  APP="$1"
  TARGETS=()
  local candidates=(
    "$APP"/Contents/Resources/bin/language_server*
    "$APP"/Contents/Resources/app/extensions/antigravity/bin/language_server*
  )
  local f rp seen=""
  for f in "${candidates[@]}"; do
    [ -e "$f" ] || continue
    rp=$(resolve_path "$f")
    is_macho_target "$rp" || continue
    case "$seen" in *"|$rp|"*) continue ;; esac
    if grep -q "ineligible\|inexigible" "$rp" 2>/dev/null; then
      seen="$seen|$rp|"
      TARGETS+=("$rp")
    fi
  done
}

check_arch() {
  # v2.4+: dist/main.js внутри app.asar содержит ./languageServer + ./ipcHandlers
  # и НЕ содержит legacy-auth маркеров (patch_ide.rs: is_new_desktop_architecture)
  local asar="$1/Contents/Resources/app.asar"
  [ -f "$asar" ] || { info "app.asar не найден (возможно, standalone IDE) — пропускаю проверку архитектуры"; return 0; }
  # grep -c при 0 совпадений даёт exit 1 — поэтому без "|| echo 0"
  local modular legacy
  modular=$(grep -ac "./languageServer" "$asar" 2>/dev/null); [ -z "$modular" ] && modular=0
  legacy=$(grep -acE "_handleAuthErrorResponse|getUserStatus|SET_INELIGIBLE" "$asar" 2>/dev/null); [ -z "$legacy" ] && legacy=0
  if [ "$modular" -gt 0 ] && [ "$legacy" -eq 0 ]; then
    ok "Архитектура v2.4+: auth в Language Server — JS-патч не требуется"
  else
    warn "Обнаружен legacy-шелл (pre-2.4). Этот скрипт поддерживает v2.4+; JS-патчи из оригинала не применены."
  fi
}

kill_processes() {
  [ -n "$AG_NO_ELEVATE" ] && return 0   # dev/CI-режим: чужие процессы не трогаем
  # Точечный kill: не цепляем сам скрипт (путь часто содержит "antigravity") и чужие процессы.
  pkill -f "/Antigravity\.app/" 2>/dev/null || true
  pkill -f "/Antigravity IDE\.app/" 2>/dev/null || true
  pkill -f "language_server" 2>/dev/null || true
  pkill -x "agy" 2>/dev/null || true
  sleep 1
}

# ---------------------------------------------------------------- binary patch
patch_binaries() {
  local APP="$1"; local total=0 already=0
  collect_targets "$APP"
  if [ ${#TARGETS[@]} -eq 0 ]; then
    # IDE 2.6.0+ не носит language_server внутри бандла — бэкенд лежит в ~/.gemini/bin/agy
    if [ -d "$APP/Contents/Resources/app/extensions/agy" ]; then
      info "IDE 2.6+: встроенного language_server нет, бэкенд патчится в ~/.gemini/bin/agy"
      return 0
    fi
    err "Патч-цели не найдены (Antigravity установлен?)"
    return 1
  fi
  ensure_helper
  local f n rc
  for f in "${TARGETS[@]}"; do
    n=$(perl "$HELPER" bpatch "$f" 2>/dev/null); rc=$?
    case $rc in
      0)
        codesign --force --sign - "$f" 2>/dev/null
        ok "пропатчен ($n вхожд.): $f"
        total=$((total+1))
        ;;
      2)
        ok "уже пропатчен: $f"
        already=$((already+1))
        ;;
      4) warn "строка не найдена — новая сборка? Пропускаю: $f" ;;
      *) err "не удалось записать: $f" ;;
    esac
  done
  [ "$total" -gt 0 ] && info "Бинарный патч применён к $total файл(ам). Запусти Antigravity и войди в Google-аккаунт."
  # seal бандла битый, если мы патчили сейчас ИЛИ он уже был пропатчен — только тогда переподписываем
  [ "$total" -gt 0 ] || [ "$already" -gt 0 ] && NEED_RESIGN=1
  return 0
}

# CLI / VS Code / IDE 2.6+ бэкенд: тот же ineligible->inexigible через atomic bpatch + ad-hoc подпись
patch_cli() {
  collect_agy_bins
  [ ${#AGY_BINS[@]} -eq 0 ] && return 0
  ensure_helper
  local f n rc
  for f in "${AGY_BINS[@]}"; do
    n=$(perl "$HELPER" bpatch "$f" 2>/dev/null); rc=$?
    case $rc in
      0) codesign --force --sign - "$f" 2>/dev/null
         ok "agy пропатчен ($n вхожд.): $f" ;;
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
      0) codesign --force --sign - "$f" 2>/dev/null
         ok "agy откачен ($n вхожд.): $f" ;;
      2) : ;;
      *) err "не удалось откатить $f" ;;
    esac
  done
}

# патч (и откат) ломают seal бандла → GUI-запуск даёт «повреждено»;
# лечится ad-hoc переподписью всего .app
resign_bundle() {
  local bundle="$1"
  case "$bundle" in
    *.app) ;;
    *) return 0 ;;
  esac
  xattr -dr com.apple.quarantine "$bundle" 2>/dev/null
  if codesign --force --deep --sign - "$bundle" 2>/dev/null; then
    ok "Бандл переподписан ad-hoc: $bundle"
  else
    warn "Не удалось переподписать $bundle"
    warn "Системные настройки → Конфиденциальность и безопасность → Управление приложениями → включи свой терминал, затем повтори патч"
  fi
}

unpatch_binaries() {
  local APP="$1"; local total=0
  collect_targets "$APP"
  ensure_helper
  local f n rc
  for f in "${TARGETS[@]}"; do
    n=$(perl "$HELPER" bunpatch "$f" 2>/dev/null); rc=$?
    case $rc in
      0)
        codesign --force --sign - "$f" 2>/dev/null
        ok "откачен ($n вхожд.): $f"
        total=$((total+1))
        ;;
      2) : ;;
      *) err "не удалось откатить: $f" ;;
    esac
  done
  [ "$total" -eq 0 ] && info "Пропатченных бинарей не найдено."
  [ "$total" -gt 0 ] && UNPATCH_TOUCHED=1
}

# ---------------------------------------------------------------- IDE JS patch
# Порт patch_ide.rs оригинала 1-в-1. Только у IDE auth частично живёт в JS:
# перезаписывается тело auth-функции в Contents/Resources/app/out/main.js (regex
# по минифицированному коду, имена переменных параметризованы) и fallback имени в
# app/extensions/antigravity/dist/extension.js. Бэкап <файл>.ag_backup создаётся
# один раз ДО первой правки — откат возможен только из него.
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

# JS-патчи IDE (если это IDE). Не IDE -> молча return 1.
patch_ide_js() {
  local APP="$1"
  local main_js="$APP/Contents/Resources/app/out/main.js"
  local ext_js="$APP/Contents/Resources/app/extensions/antigravity/dist/extension.js"
  [ -f "$main_js" ] || return 1
  ensure_helper
  local out rc
  out=$(perl "$HELPER" main "$main_js" 2>&1); rc=$?
  case $rc in
    0)
      if command -v node >/dev/null 2>&1 && ! node --check "$main_js" 2>/dev/null; then
        perl "$HELPER" revert "$main_js" >/dev/null 2>&1
        err "main.js после патча не парсится — откачен из бэкапа. Сообщи автору скрипта."
        return 1
      fi
      ok "IDE: main.js пропатчен (auth-функция перезаписана)"
      NEED_RESIGN=1
      ;;
    2) ok "IDE: main.js уже пропатчен"; NEED_RESIGN=1 ;;
    3) err "IDE: обнаружена старая версия патча в main.js — переустанови IDE чисто и повтори"; return 1 ;;
    4) err "IDE: сигнатура main.js не найдена — новая версия IDE? JS не тронут"; return 1 ;;
    *) err "IDE main.js: $out"; return 1 ;;
  esac
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

revert_ide_js() {
  local APP="$1"
  local main_js="$APP/Contents/Resources/app/out/main.js"
  local ext_js="$APP/Contents/Resources/app/extensions/antigravity/dist/extension.js"
  ensure_helper
  local f out rc
  for f in "$main_js" "$ext_js"; do
    [ -e "$f" ] || [ -e "$f.ag_backup" ] || continue
    out=$(perl "$HELPER" revert "$f" 2>&1); rc=$?
    case $rc in
      0) ok "JS восстановлен из бэкапа: $f"; UNPATCH_TOUCHED=1 ;;
      2) : ;;
      *) warn "JS revert $f: $out" ;;
    esac
  done
}

# Полный патч одного бандла: (для IDE сначала JS,) бинари, затем переподпись.
# JS идёт первым — финальный deep re-sign в конце покрывает и его правки.
# Переподписываем только если что-то реально пропатчено: ad-hoc подпись на
# нетронутом бандле заменяет оригинальную без нужды.
patch_install() {
  local APP="$1"; local rc=0 NEED_RESIGN=0
  info "=== $APP"
  if [ -f "$APP/Contents/Resources/app/out/main.js" ]; then
    patch_ide_js "$APP" || rc=1
  fi
  patch_binaries "$APP" || rc=1
  [ "$NEED_RESIGN" -eq 1 ] && resign_bundle "$APP"
  return $rc
}

# Полный откат одного бандла + переподпись, если что-то меняли.
revert_install() {
  local APP="$1"; local UNPATCH_TOUCHED=0
  info "=== $APP"
  unpatch_binaries "$APP"
  revert_ide_js "$APP"
  [ "$UNPATCH_TOUCHED" -eq 1 ] && resign_bundle "$APP"
}

# ---------------------------------------------------------------- DNS pin
DIG_OPT=""
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
  if [ -z "$(dig +short +time=2 +tries=1 A google.com @8.8.8.8 2>/dev/null)" ]; then
    if [ -n "$(dig +short +tcp +time=2 +tries=1 A google.com @8.8.8.8 2>/dev/null)" ]; then
      DIG_OPT="+tcp"
      info "UDP/53 недоступен — использую DNS over TCP"
    fi
  fi
}

dig_a() { # $1 = domain, $2 = server -> RESOLVE_OUT: IPv4 построчно
  RESOLVE_OUT=""
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

ref_net16() { # $1 = domain -> stdout: "/16-сети эталона"
  local r out=""
  for r in "${REFERENCE[@]}"; do
    out="$out
$(dig $DIG_OPT +short +time=3 +tries=1 A "$1" @"$r" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$')"
  done
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

# --- обход VPN для DoH-запросов: scoped routing macOS отпускает сокет,
# привязанный к физическому интерфейсу, мимо туннеля.
VPN_ON=0; CURL_IF=""
vpn_active() {
  route -n get -inet default 2>/dev/null | grep -qE "interface: (utun|ipsec|ppp|tun|tap)"
}
phys_iface() {
  local dev
  dev=$(printf 'show State:/Network/Global/IPv4\n' | scutil 2>/dev/null | awk '/PrimaryInterface/ {print $3; exit}')
  case "$dev" in utun*|ipsec*|ppp*|tun*|tap*) dev="" ;; esac   # PrimaryInterface под VPN = сам туннель
  if [ -z "$dev" ]; then
    dev=$(netstat -rn -f inet 2>/dev/null | awk '$1=="default" {print $NF}' | grep -vE '^(utun|ipsec|ppp|tun|tap)' | head -1)
  fi
  [ -n "$dev" ] && echo "$dev"
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

# Пользовательский DoH URL (AG_CUSTOM_DNS="https://dns.example.com/dns-query")
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

# Боевая проба: реальный HTTPS-ответ с валидным сертификатом Google через кандидата.
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
  # Проба сначала проверяет дефолтный маршрут (не трогая таблицу маршрутизации);
  # если под VPN дефолт не достучался (например, VPN режет RU-прокси), пробуем
  # мимо туннеля ($CURL_IF) — и только для таких IP ставим /32 host-route.
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
  dscacheutil -flushcache 2>/dev/null; killall -HUP mDNSResponder 2>/dev/null
  ok "Пропинено в $HOSTS:"
  sed -n "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/p" "$HOSTS" | sed '1d;$d' | sed 's/^/    /'
  ensure_pin_routes
}

# --- host-routes мимо VPN-туннеля: ставятся ТОЛЬКО для прокси с пометкой # ag-bypass
# (которые не открываются через VPN, но прошли пробу через физический интерфейс).
# Прокси, работающие поверх VPN, маршрут не трогают — это не ломает TUN/ТСПУ.
phys_gw() {
  netstat -rn -f inet 2>/dev/null | awk '$1=="default" && $NF !~ /^(utun|ipsec|ppp|tun|tap)/ {print $2; exit}'
}

ensure_pin_routes() {
  [ "$(id -u)" -eq 0 ] || return 0
  if ! vpn_active; then
    drop_pin_routes   # VPN выключен — /32 не нужны, а протухшие могут чёрнодырить
    return 0
  fi
  local gw; gw=$(phys_gw); [ -z "$gw" ] && return 0
  local ip n=0
  for ip in $(sed -n "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/p" "$HOSTS" 2>/dev/null | awk '/# ag-bypass/ {print $1}' | sort -u); do
    route -n delete -host "$ip" >/dev/null 2>&1
    route -n add -host "$ip" "$gw" >/dev/null 2>&1 && n=$((n+1))
  done
  [ "$n" -gt 0 ] && info "VPN активен: $n маршрут(ов) на прокси-IP прописаны мимо туннеля (via $gw)"
}

drop_pin_routes() {
  [ "$(id -u)" -eq 0 ] || return 0
  local ip
  for ip in $(sed -n "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/p" "$HOSTS" 2>/dev/null | awk 'NF>=2 && $1 !~ /^#/ {print $1}' | sort -u); do
    route -n delete -host "$ip" >/dev/null 2>&1
  done
}

remove_hosts_block() {
  drop_pin_routes
  if grep -q "$MARKER_BEGIN" "$HOSTS" 2>/dev/null; then
    sed "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" "$HOSTS" > "$HOSTS.ag_tmp" && mv "$HOSTS.ag_tmp" "$HOSTS"
    dscacheutil -flushcache 2>/dev/null; killall -HUP mDNSResponder 2>/dev/null
    ok "hosts-блок удалён"
  else
    info "hosts-блок не найден"
  fi
}

# ---------------------------------------------------------------- watchdog
# Авто-репатч после обновлений (порт watchdog.rs оригинала): settle-правило
# (файл патчится только когда size:mtime стабильны два тика), сигнатура не
# найдена -> файл не трогаем до следующей его смены, полный откат (пункт 5)
# выключает watchdog флагом-отказом — явное «не надо» уважается.
WATCH_LABEL="com.asalio123.agunlocker.watch"
WATCH_PLIST="$REAL_HOME/Library/LaunchAgents/$WATCH_LABEL.plist"
DECLINE_FLAG="$REAL_HOME/.ag_unlocker_no_watch"
WATCH_STATE="${TMPDIR:-/tmp}/.ag_watch_state.$REAL_UID"
WATCH_LOG="/tmp/ag_unlocker_watch.$REAL_UID.log"

f_sig() { stat -f '%z:%m' "$1" 2>/dev/null || echo absent; }
state_name() { printf '%s' "$1" | md5 -q; }
xml_escape() {
  printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

watch_loop() {
  mkdir -p "$WATCH_STATE"
  echo "$(date '+%F %T') watchdog стартанул (pid $$, uid $(id -u))" >> "$WATCH_LOG"
  local tick=0
  while true; do
    if [ -f "$DECLINE_FLAG" ]; then
      echo "$(date '+%F %T') decline-флаг — выход" >> "$WATCH_LOG"; exit 0
    fi
    find_apps 2>/dev/null || true
    local targets="" APP f rp
    for f in "${AGY_BINS[@]}"; do
      [ -f "$f" ] && targets="$targets$f
"
    done
    for APP in "${APPS[@]}"; do
      for f in "$APP"/Contents/Resources/bin/language_server* \
               "$APP"/Contents/Resources/app/extensions/antigravity/bin/language_server* \
               "$APP/Contents/Resources/app/out/main.js" \
               "$APP/Contents/Resources/app/extensions/antigravity/dist/extension.js"; do
        [ -e "$f" ] || continue
        case "$f" in *.agtmp|*.ag_backup|*.log|*.txt) continue ;; esac
        rp=$(resolve_path "$f")
        [ -f "$rp" ] && targets="$targets$rp
"
      done
    done
    local repatched=0
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
            0) echo "$(date '+%F %T') repatch JS: $f" >> "$WATCH_LOG"; repatched=1 ;;
            2) : ;;
            *) echo "$(date '+%F %T') JS $f: rc=$rc $out (жду смены файла)" >> "$WATCH_LOG" ;;
          esac
          ;;
        *)
          is_macho_target "$f" || { printf '%s\n0\n' "$cur" > "$st"; continue; }
          local n rc
          n=$(perl "$HELPER" bpatch "$f" 2>/dev/null); rc=$?
          case $rc in
            0) codesign --force --sign - "$f" 2>/dev/null
               echo "$(date '+%F %T') repatch bin ($n вхожд.): $f" >> "$WATCH_LOG"; repatched=1 ;;
            2) : ;;
            *) echo "$(date '+%F %T') bin $f: нет сигнатуры/ошибка rc=$rc (жду смены файла)" >> "$WATCH_LOG" ;;
          esac
          ;;
      esac
      printf '%s\n0\n' "$cur" > "$st"
    done <<< "$targets"
    if [ "$repatched" = "1" ]; then
      for APP in "${APPS[@]}"; do
        xattr -dr com.apple.quarantine "$APP" 2>/dev/null
        codesign --force --deep --sign - "$APP" 2>/dev/null
      done
      echo "$(date '+%F %T') бандлы переподписаны" >> "$WATCH_LOG"
    fi
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

run_launchctl_user() {
  if [ "$(id -u)" -eq 0 ]; then
    if [ -z "${SUDO_USER:-}" ]; then
      echo "скрипт запущен от root без пользовательской GUI-сессии — запусти без sudo: bash ag_unlocker_mac.sh"
      return 1
    fi
    sudo -u "$REAL_USER" launchctl "$@"
  else
    launchctl "$@"
  fi
}

install_watchdog() {
  if [ "$(id -u)" -eq 0 ] && [ -z "${SUDO_USER:-}" ]; then
    err "Watchdog (LaunchAgent) должен ставиться в пользовательскую GUI-сессию. Запусти без sudo: bash $SELF_SCRIPT"
    return 1
  fi
  rm -f "$DECLINE_FLAG"
  mkdir -p "$REAL_HOME/Library/LaunchAgents"
  local esc_self esc_log
  esc_self=$(xml_escape "$SELF_SCRIPT")
  esc_log=$(xml_escape "$WATCH_LOG")
  cat > "$WATCH_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$WATCH_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$esc_self</string><string>--watch</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$esc_log</string>
  <key>StandardErrorPath</key><string>$esc_log</string>
</dict></plist>
EOF
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    chown "$REAL_USER" "$REAL_HOME/Library/LaunchAgents" "$WATCH_PLIST" 2>/dev/null || true
  fi
  local lint_err
  if ! lint_err=$(plutil -lint "$WATCH_PLIST" 2>&1); then
    err "Ошибка в plist watchdog: $lint_err"
    rm -f "$WATCH_PLIST"
    return 1
  fi
  run_launchctl_user bootout "gui/$REAL_UID/$WATCH_LABEL" >/dev/null 2>&1 || true
  local launch_err
  if launch_err=$(run_launchctl_user bootstrap "gui/$REAL_UID" "$WATCH_PLIST" 2>&1); then
    ok "Watchdog установлен (LaunchAgent gui/$REAL_UID, KeepAlive). Лог: $WATCH_LOG"
    info "После автообновления Antigravity патч восстановится сам через ~5 секунд."
    info "Если файлы в /Applications принадлежат root — watchdog напишет в лог, что нужен ручной запуск."
  else
    err "launchctl bootstrap не удался: ${launch_err:-неизвестная ошибка}"
    rm -f "$WATCH_PLIST"
    return 1
  fi
}

uninstall_watchdog() {
  if [ -f "$WATCH_PLIST" ]; then
    run_launchctl_user bootout "gui/$REAL_UID/$WATCH_LABEL" >/dev/null 2>&1 && ok "Watchdog остановлен"
    rm -f "$WATCH_PLIST"
  else
    run_launchctl_user bootout "gui/$REAL_UID/$WATCH_LABEL" >/dev/null 2>&1 || true
  fi
}

# ---------------------------------------------------------------- status
show_status() {
  find_apps || { err "Antigravity не найден"; return 1; }
  local APP
  for APP in "${APPS[@]}"; do
    info "Установка: $APP"
    if [ -f "$APP/Contents/Resources/app/out/main.js" ]; then
      say "    продукт: Antigravity IDE"
      if tail -c 200 "$APP/Contents/Resources/app/out/main.js" | grep -q "^// UNLOCKED"; then
        ok "IDE main.js: пропатчен"
      else
        warn "IDE main.js: НЕ пропатчен"
      fi
    else
      say "    продукт: Antigravity Desktop"
      check_arch "$APP"
    fi
    collect_targets "$APP"
    local f in_cnt out_cnt
    if [ ${#TARGETS[@]} -eq 0 ] && [ -d "$APP/Contents/Resources/app/extensions/agy" ]; then
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
  if [ -f "$WATCH_PLIST" ]; then
    if run_launchctl_user print "gui/$REAL_UID/$WATCH_LABEL" >/dev/null 2>&1; then
      ok "Watchdog: установлен и запущен ($WATCH_PLIST)"
    else
      warn "Watchdog: plist есть, но сервис не загружен ($WATCH_PLIST)"
    fi
  else
    info "Watchdog: выключен"
  fi
}

# ---------------------------------------------------------------- privileged dispatch & main
dispatch_privileged() {
  local action="$1"
  find_apps || true
  case "$action" in
    unlock)
      [ ${#APPS[@]} -eq 0 ] && [ ${#AGY_BINS[@]} -eq 0 ] && { err "Antigravity не найден"; return 1; }
      kill_processes
      local APP
      for APP in "${APPS[@]}"; do patch_install "$APP"; done
      patch_cli
      dns_pin
      ;;
    patch)
      [ ${#APPS[@]} -eq 0 ] && [ ${#AGY_BINS[@]} -eq 0 ] && { err "Antigravity не найден"; return 1; }
      kill_processes
      local APP
      for APP in "${APPS[@]}"; do patch_install "$APP"; done
      patch_cli
      ;;
    dns_pin)
      dns_pin
      ;;
    revert)
      kill_processes
      local APP
      for APP in "${APPS[@]}"; do revert_install "$APP"; done
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

find_apps || true
if [ ${#APPS[@]} -gt 0 ] || [ ${#AGY_BINS[@]} -gt 0 ]; then
  [ ${#APPS[@]} -gt 0 ] && { say "Найдено бандлов: ${#APPS[@]}"; printf '  - %s\n' "${APPS[@]}"; }
  [ ${#AGY_BINS[@]} -gt 0 ] && { say "Найдено agy (CLI / IDE 2.6+ / VS Code): ${#AGY_BINS[@]}"; printf '  - %s\n' "${AGY_BINS[@]}"; }
else
  warn "Antigravity не найден. Установи Desktop, IDE, CLI или расширение VS Code и перезапусти скрипт."
fi

while true; do
  say ""
  say "===== Antigravity анлокер для macOS ====="
  say " 1) Разблокировать (патч + DNS-пин, все найденные установки)"
  say " 2) Только патч (для режима с VPN)"
  say " 3) Обновить DNS-пин (работает и при включённом VPN)"
  say " 4) Статус / диагностика"
  say " 5) Полный откат (снять патч и вернуть всё как было)"
  if [ -f "$WATCH_PLIST" ]; then
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
    6) if [ -f "$WATCH_PLIST" ]; then
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
