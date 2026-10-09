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
#    2) DNS-пин: анблок-DNS (geohide.ru / comss.one / dns-ai.ru; UDP + DoH)
#       отдают российским клиентам IP своих SNI-прокси вместо Google; живые
#       адреса пинуются в /etc/hosts (маркеры AG_UNLOCKER_HOSTS_*).
#       Ответ провайдера считается подменой, если его /16-подсеть отличается
#       от эталонной (8.8.8.8 / 1.1.1.1). DoH идёт мимо VPN-туннеля —
#       выключать VPN не нужно. Watchdog (пункт 6) авторепатчит после обновлений.
#
#  Зависимости: bash, perl, dig (dnsutils), curl, coreutils. На Linux подписи
#  не проверяются — переподписка не нужна (в отличие от macOS-версии).
#
#  Запуск:  sudo bash ag_unlocker_linux.sh
# ============================================================================

MARKER_BEGIN="# AG_UNLOCKER_HOSTS_BEGIN"
MARKER_END="# AG_UNLOCKER_HOSTS_END"

HOSTS="${AG_HOSTS:-/etc/hosts}"
DOMAINS=(
  "daily-cloudcode-pa.googleapis.com"
  "generativelanguage.googleapis.com"
  # endpoint IDE (confeden 2.11+: оверрайд эндпоинта убран, подменяющий провайдер есть в пуле).
  # Если подмены нет — домен просто не пинуется, остальные не страдают.
  "cloudcode-pa.googleapis.com"
)
# xbox-dns.ru выкинут: с 07.10.2026 сервис мёртв (РКН добился блокировки у хостера).
# Остались geohide/comss (UDP) + DoH-эндпоинты тех же сервисов и dns-ai.ru
# (DoH-only, HTTP/2; IP захардкожены — сертификат по имени защищает при протухшем IP).
PROVIDERS=(45.155.204.190 37.230.192.51 83.220.169.155 212.109.195.93 195.133.25.16)
DOH_PROVIDERS=(
  "dns.geohide.ru|37.230.192.51,45.155.204.190|h1"
  "dns.comss.one|83.220.169.155,212.109.195.93,195.133.25.16|h1"
  "dns.dns-ai.ru|192.144.59.14,186.246.49.127,185.251.90.181|h2"
)
REFERENCE=(8.8.8.8 1.1.1.1)

C_OK='\033[32m'; C_WARN='\033[33m'; C_ERR='\033[31m'; C_INFO='\033[36m'; C_N='\033[0m'
say()  { printf "%b\n" "$1"; }
ok()   { say "${C_OK}[OK]${C_N} $1"; }
warn() { say "${C_WARN}[!]${C_N} $1"; }
err()  { say "${C_ERR}[X]${C_N} $1"; }
info() { say "${C_INFO}[i]${C_N} $1"; }

# ---------------------------------------------------------------- sudo gate
# --watch: фоновый режим watchdog (из systemd --user) — без меню и без sudo
if [ "$1" = "--watch" ]; then
  AG_NO_ELEVATE=1
fi
# AG_NO_ELEVATE=1 — dev/CI-режим: не поднимать права
if [ "$(id -u)" -ne 0 ] && [ -z "$AG_NO_ELEVATE" ]; then
  info "Нужен root (патч бинарей + запись /etc/hosts). Перезапуск через sudo..."
  exec sudo bash "$0" "$@"
fi

if ! command -v dig >/dev/null 2>&1; then
  err "dig не найден (пакет dnsutils). Установи: sudo apt install -y dnsutils  (или bind-utils на rpm-системах)"
  exit 1
fi

# ---------------------------------------------------------------- app discovery
# INSTALLS — пути к resources-директориям (Desktop и IDE могут стоять одновременно).
# Порядок: пакетный менеджер -> find по стандартным корням.
find_installs() {
  INSTALLS=()
  local found="" p
  # AG_ROOT=/path/to/Antigravity/resources — ручной путь для нестандартных установок
  if [ -n "$AG_ROOT" ] && [ -d "$AG_ROOT" ]; then
    INSTALLS+=("$AG_ROOT")
    return 0
  fi
  if command -v dpkg >/dev/null 2>&1; then
    found=$(dpkg -L antigravity antigravity-ide 2>/dev/null | grep -E 'bin/language_server(_linux_x64)?$')
  fi
  if command -v rpm >/dev/null 2>&1; then
    found="$found
$(rpm -ql antigravity antigravity-ide 2>/dev/null | grep -E 'bin/language_server(_linux_x64)?$')"
  fi
  # Desktop: resources/bin/language_server; tar.gz-установки живут где угодно
  # (суффикс платформы в имени LS может дрейфовать — как и у оригинала, берём language_server*)
  found="$found
$(find /opt /usr/share /usr/lib /usr/local/share "$HOME/.antigravity" "$HOME/opt" "$HOME" \
       -maxdepth 6 -type f -path "*ntigravity*" -name "language_server*" 2>/dev/null | grep -v AppImage)"
  # IDE: language_server лежит глубже (resources/app/extensions/...), надёжнее искать
  # по out/main.js — он есть только у IDE (у Desktop JS живёт в app.asar/dist)
  found="$found
$(find /opt /usr/share /usr/lib /usr/local/share "$HOME/.local/share" "$HOME" \
       -maxdepth 6 -type f -path "*ntigravity*" -regex ".*/resources/app/out/main\.js" 2>/dev/null)"
  for p in $found; do
    local root
    case "$p" in
      */resources/app/out/main.js)                root=$(dirname "$(dirname "$(dirname "$p")")") ;;  # IDE по main.js
      */resources/app/extensions/antigravity/bin/*)
        root=$(dirname "$(dirname "$(dirname "$(dirname "$(dirname "$p")")")")") ;;                    # IDE по LS
      *) root=$(dirname "$(dirname "$p")") ;;                                                          # Desktop LS
    esac
    [ -d "$root" ] && INSTALLS+=("$root")
  done
  # дедуп (desktop может найтись и через пакетник, и через find)
  if [ ${#INSTALLS[@]} -gt 1 ]; then
    local u
    u=$(printf '%s\n' "${INSTALLS[@]}" | sort -u)
    INSTALLS=()
    while IFS= read -r p; do [ -n "$p" ] && INSTALLS+=("$p"); done <<< "$u"
  fi
}

# Патч-цели установки: language_server (+ agy из PATH, если вдруг есть).
collect_targets() {
  RES="$1"   # путь к resources
  TARGETS=()
  local candidates=(
    "$RES/bin/language_server"
    "$RES/app/extensions/antigravity/bin/language_server"*
  )
  local agy
  agy=$(command -v agy 2>/dev/null) && [ -n "$agy" ] && candidates+=("$agy")
  local f
  for f in "${candidates[@]}"; do
    [ -f "$f" ] || continue
    file "$f" | grep -q "ELF" || continue
    grep -q "ineligible\|inexigible" "$f" && TARGETS+=("$f")
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
  pkill -if "antigravity" 2>/dev/null
  pkill -if "language_server" 2>/dev/null
  pkill -if "agy" 2>/dev/null
  sleep 1
}

# ---------------------------------------------------------------- binary patch
patch_binaries() {
  local RES="$1"; local total=0
  collect_targets "$RES"
  [ ${#TARGETS[@]} -eq 0 ] && { err "Патч-цели не найдены"; return 1; }
  local f in_cnt out_cnt
  for f in "${TARGETS[@]}"; do
    in_cnt=$(perl -0777 -ne 'my $c=()=/ineligible/g; print $c' "$f")
    out_cnt=$(perl -0777 -ne 'my $c=()=/inexigible/g; print $c' "$f")
    if [ "$in_cnt" -eq 0 ] && [ "$out_cnt" -gt 0 ]; then
      ok "уже пропатчен: $f ($out_cnt вхожд.)"
      continue
    fi
    if [ "$in_cnt" -eq 0 ]; then
      warn "строка не найдена — новая сборка? Пропускаю: $f"
      continue
    fi
    perl -0777 -pi -e 's/ineligible/inexigible/g' "$f" || { err "не удалось записать: $f"; continue; }
    out_cnt=$(perl -0777 -ne 'my $c=()=/inexigible/g; print $c' "$f")
    if [ "$out_cnt" -eq "$in_cnt" ]; then
      ok "пропатчен ($out_cnt вхожд.): $f"
      total=$((total+1))
    else
      err "проверка после патча не сошлась: $f"
    fi
  done
  [ "$total" -gt 0 ] && info "Патч применён к $total файл(ам). Запусти Antigravity и войди в Google-аккаунт."
  return 0
}

unpatch_binaries() {
  local RES="$1"; local total=0
  collect_targets "$RES"
  local f out_cnt
  for f in "${TARGETS[@]}"; do
    out_cnt=$(perl -0777 -ne 'my $c=()=/inexigible/g; print $c' "$f" 2>/dev/null || echo 0)
    [ "$out_cnt" -eq 0 ] && continue
    perl -0777 -pi -e 's/inexigible/ineligible/g' "$f" || { err "не удалось откатить: $f"; continue; }
    ok "откачен ($out_cnt вхожд.): $f"
    total=$((total+1))
  done
  [ "$total" -eq 0 ] && info "Пропатченных бинарей не найдено."
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
    my (undef, undef, $qd, $an) = unpack("n4", $d);
    my $off = 12;
    for (1..$qd) {
        while (1) { my $l = unpack("C", substr($d,$off,1)); $off++;
            last if $l == 0; if ($l >= 192) { $off++; last; } $off += $l; }
        $off += 4;
    }
    for (1..$an) {
        while (1) { my $l = unpack("C", substr($d,$off,1)); $off++;
            last if $l == 0; if ($l >= 192) { $off++; last; } $off += $l; }
        my ($type, undef, undef, $rdlen) = unpack("nnNn", substr($d,$off,10)); $off += 10;
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
    open my $out, '>', $tmp or die "не записать $tmp: $!";
    print $out $content;
    close $out;
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
if ($mode eq 'bpatch') {
    # байтовый патч бинаря через temp+rename: работает по живому процессу (ETXTBSY-safe)
    my $data = slurp_bin($file);
    my $in = () = $data =~ /ineligible/g;
    my $outc = () = $data =~ /inexigible/g;
    exit 2 if $in == 0 && $outc > 0;   # уже пропатчен
    exit 4 if $in == 0;                # сигнатуры нет — новая сборка
    $data =~ s/ineligible/inexigible/g;
    my $tmp = "$file.$$.agtmp";
    open my $out, '>:raw', $tmp or exit 1;
    print $out $data;
    close $out;
    my (undef, undef, $modebits) = stat($file);
    chmod($modebits & 07777, $tmp);
    rename($tmp, $file) or do { unlink $tmp; exit 1; };
    print "$in\n";
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
# если UDP/53 наружу закрыт (VM/корпоративные сети), но TCP работает — переключаемся на DNS over TCP
detect_dns_transport() {
  if [ -z "$(dig +short +time=3 +tries=1 A google.com @8.8.8.8 2>/dev/null)" ]; then
    if [ -n "$(dig +short +tcp +time=3 +tries=1 A google.com @8.8.8.8 2>/dev/null)" ]; then
      DIG_OPT="+tcp"
      info "UDP/53 недоступен — использую DNS over TCP"
    fi
  fi
}

dig_a() {
  local out
  out=$(dig $DIG_OPT +short +time=4 +tries=1 A "$1" @"$2" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u)
  if [ -z "$out" ]; then
    out=$(dig +tcp +short +time=4 +tries=1 A "$1" @"$2" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u)
  fi
  echo "$out"
}

ref_net16() {
  local r
  for r in "${REFERENCE[@]}"; do dig_a "$1" "$r"; done | cut -d. -f1,2 | sort -u
}

# --- обход VPN для DoH-запросов: бинд на физический интерфейс (root есть)
VPN_ON=0; CURL_IF=""
phys_iface() {
  ip route show default 2>/dev/null | grep -vE 'dev (tun|wg|tap|utun)' | head -1 \
    | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}
setup_curl_bypass() {
  VPN_ON=0; CURL_IF=""
  ip route show default 2>/dev/null | grep -qE 'dev (tun|wg|tap)' || return 0
  VPN_ON=1
  local dev; dev=$(phys_iface)
  [ -n "$dev" ] && CURL_IF="--interface $dev"
  info "VPN активен — DoH-запросы пойдут мимо туннеля${dev:+ через $dev} (подмену отдают только RU-клиентам)"
}

# DoH A-запрос к одному провайдеру ("host|ip1,ip2|h1|h2") -> IPv4 построчно
doh_a_one() {
  ensure_helper
  local dom="$1" spec="$2"
  local host="${spec%%|*}" rest="${spec#*|}"
  local ips="${rest%%|*}" proto="${rest##*|}"
  local h2=""; [ "$proto" = "h2" ] && h2="--http2"
  local b64 ip out tmp="${TMPDIR:-/tmp}/.ag_doh.$$"
  b64=$(perl "$HELPER" query "$dom") || return 1
  for ip in ${ips//,/ }; do
    if curl -s $CURL_IF $h2 --max-time 6 --resolve "$host:443:$ip" \
         "https://$host/dns-query?dns=$b64" -H "accept: application/dns-message" -o "$tmp" 2>/dev/null; then
      out=$(perl "$HELPER" parse "$tmp" 2>/dev/null)
      if [ -n "$out" ]; then rm -f "$tmp"; echo "$out"; return 0; fi
    fi
  done
  rm -f "$tmp"
  return 1
}

# боевая проба: живой Google-ответ через кандидата (а не просто открытый порт)
probe_ip() { # $1=domain $2=ip -> stdout: latency; exit 0 если жив
  local out code
  out=$(curl -s --max-time 6 --resolve "$1:443:$2" "https://$1/" -o /dev/null -w '%{http_code} %{time_total}' 2>/dev/null) || return 1
  code="${out%% *}"
  case "$code" in
    2*|3*|4*) echo "${out##* }"; return 0 ;;
  esac
  return 1
}

dns_pin() {
  # PIN_MAP — "domain:ip1,ip2|..." — IP пинуются строго per-domain.
  # Кандидаты: UDP + DoH (с обходом туннеля при активном VPN). Перед пином —
  # боевая HTTPS-проба каждого; пинуются до 2 быстрейших.
  local domain ip prov spec
  detect_dns_transport
  setup_curl_bypass
  PIN_MAP=""
  local any_substituted=0
  for domain in "${DOMAINS[@]}"; do
    local ref_blocks
    ref_blocks=$(ref_net16 "$domain")
    [ -z "$ref_blocks" ] && { warn "эталон не ответил для $domain — пропуск"; continue; }
    local cand=""
    for prov in "${PROVIDERS[@]}"; do
      local ans; ans=$(dig_a "$domain" "$prov"); [ -z "$ans" ] && continue
      local sub=""
      while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        echo "$ref_blocks" | grep -qx "${ip%.*.*}" || sub="$sub $ip"
      done <<< "$ans"
      if [ -n "$sub" ]; then
        any_substituted=1
        info "$domain @ $prov -> подмена:$(echo $sub | tr ' ' ',')"
        cand="$cand $sub"
      fi
    done
    for spec in "${DOH_PROVIDERS[@]}"; do
      local ans; ans=$(doh_a_one "$domain" "$spec"); [ -z "$ans" ] && continue
      local sub=""
      while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        echo "$ref_blocks" | grep -qx "${ip%.*.*}" || sub="$sub $ip"
      done <<< "$ans"
      if [ -n "$sub" ]; then
        any_substituted=1
        info "$domain @ ${spec%%|*} (DoH) -> подмена:$(echo $sub | tr ' ' ',')"
        cand="$cand $sub"
      fi
    done
    cand=$(echo $cand | tr ' ' '\n' | sed '/^$/d' | sort -u)
    if [ -z "$cand" ]; then
      warn "$domain: подмены нет ни у одного провайдера — домен не пиную"
      continue
    fi
    local scored=""
    while IFS= read -r ip; do
      [ -z "$ip" ] && continue
      local t
      if t=$(probe_ip "$domain" "$ip"); then
        scored="$scored$t $ip\n"
      else
        warn "$ip: боевая проба не прошла — не пиную"
      fi
    done <<< "$cand"
    local top
    top=$(printf '%b' "$scored" | sort -n | head -2 | awk '{print $2}')
    [ -n "$top" ] && PIN_MAP="$PIN_MAP$domain:$(echo $top | tr ' ' ',')|"
  done

  if [ "$any_substituted" -eq 0 ] || [ -z "$(echo "$PIN_MAP" | tr -d ':|')" ]; then
    err "Ни один провайдер не отдал подменённые адреса (UDP и DoH)."
    warn "Варианты: ты не в регионе, для которого сервисы делают подмену, или все их узлы сейчас недоступны."
    warn "Режим с VPN (пункт 2) от этого не зависит — там достаточно любого VPN с не-RU выходом."
    return 1
  fi

  write_hosts_block
}

write_hosts_block() {
  local tmp="$HOSTS.ag_tmp" entry domain ips
  if grep -q "$MARKER_BEGIN" "$HOSTS" 2>/dev/null; then
    sed "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" "$HOSTS" > "$tmp" && mv "$tmp" "$HOSTS"
  fi
  {
    echo "$MARKER_BEGIN"
    IFS='|' read -r -a ENTRIES <<< "${PIN_MAP%|}"
    for entry in "${ENTRIES[@]}"; do
      domain="${entry%%:*}"; ips="${entry#*:}"
      for ip in $(echo "$ips" | tr ',' ' '); do
        [ -n "$ip" ] && echo "$ip $domain"
      done
    done
    echo "$MARKER_END"
  } >> "$HOSTS"
  # сброс кеша: systemd-resolved и/или nscd — если есть
  systemctl is-active systemd-resolved >/dev/null 2>&1 && resolvectl flush-caches 2>/dev/null
  [ -x /usr/sbin/nscd ] && nscd -i hosts 2>/dev/null
  ok "Пропинено в $HOSTS:"
  sed -n "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/p" "$HOSTS" | sed '1d;$d' | sed 's/^/    /'
}

remove_hosts_block() {
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
WATCH_UNIT="$HOME/.config/systemd/user/$WATCH_LABEL.service"
DECLINE_FLAG="$HOME/.ag_unlocker_no_watch"
WATCH_STATE="${TMPDIR:-/tmp}/.ag_watch_state.$UID"
WATCH_LOG="/tmp/ag_unlocker_watch.log"

f_sig() { stat -c '%s:%Y' "$1" 2>/dev/null || echo absent; }
state_name() { echo "$1" | md5sum | cut -d' ' -f1; }

watch_loop() {
  mkdir -p "$WATCH_STATE"
  echo "$(date '+%F %T') watchdog стартанул (pid $$)" >> "$WATCH_LOG"
  local tick=0
  while true; do
    if [ -f "$DECLINE_FLAG" ]; then
      echo "$(date '+%F %T') decline-флаг — выход" >> "$WATCH_LOG"; exit 0
    fi
    find_installs
    local targets="" RES f
    for RES in "${INSTALLS[@]}"; do
      for f in "$RES"/bin/language_server* \
               "$RES"/app/extensions/antigravity/bin/language_server* \
               "$RES/app/out/main.js" \
               "$RES/app/extensions/antigravity/dist/extension.js"; do
        [ -f "$f" ] && targets="$targets$f
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
    # рефреш hosts-пина раз в ~10 мин: пин есть, но все IP домена мертвы -> рефреш
    tick=$((tick+1))
    if [ $((tick % 300)) -eq 0 ] && grep -q "$MARKER_BEGIN" "$HOSTS" 2>/dev/null; then
      if [ -w "$HOSTS" ]; then
        local need=0 domain ip alive
        for domain in "${DOMAINS[@]}"; do
          alive=0
          for ip in $(sed -n "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/p" "$HOSTS" | awk -v d="$domain" '$2==d {print $1}'); do
            probe_ip "$domain" "$ip" >/dev/null 2>&1 && alive=1 && break
          done
          [ "$alive" = "0" ] && need=1
        done
        [ "$need" = "1" ] && { echo "$(date '+%F %T') пин протух — рефреш" >> "$WATCH_LOG"; dns_pin >> "$WATCH_LOG" 2>&1; }
      else
        echo "$(date '+%F %T') hosts недоступен на запись из watchdog — рефреш вручную (пункт 3)" >> "$WATCH_LOG"
      fi
    fi
    sleep 2
  done
}

install_watchdog() {
  command -v systemctl >/dev/null 2>&1 || { err "systemd не найден — watchdog не ставится"; return 1; }
  local self; self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  rm -f "$DECLINE_FLAG"
  mkdir -p "$HOME/.config/systemd/user"
  cat > "$WATCH_UNIT" <<EOF
[Unit]
Description=Antigravity unlocker watchdog (auto-repatch)

[Service]
ExecStart=/bin/bash $self --watch
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  if systemctl --user enable --now "$WATCH_LABEL.service" 2>/dev/null; then
    ok "Watchdog установлен (systemd --user, Restart=always). Лог: $WATCH_LOG"
    loginctl enable-linger "$USER" 2>/dev/null   # жить без активной сессии
    info "После автообновления Antigravity патч восстановится сам через ~5 секунд."
    info "Установка в /opt от root: репатч оттуда требует прав — watchdog напишет в лог."
  else
    err "systemctl --user не удался"; return 1
  fi
}

uninstall_watchdog() {
  systemctl --user disable --now "$WATCH_LABEL.service" 2>/dev/null && ok "Watchdog остановлен"
  rm -f "$WATCH_UNIT"
  systemctl --user daemon-reload 2>/dev/null
}

# ---------------------------------------------------------------- status
show_status() {
  find_installs
  [ ${#INSTALLS[@]} -eq 0 ] && { err "Antigravity не найден"; return 1; }
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
  if grep -q "$MARKER_BEGIN" "$HOSTS" 2>/dev/null; then
    ok "hosts-блок:"
    sed -n "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/p" "$HOSTS" | sed '1d;$d' | sed 's/^/    /'
  else
    info "hosts-блока нет (режим «без VPN» не настроен)"
  fi
}

# ---------------------------------------------------------------- menu / main
[ "$1" = "--watch" ] && { watch_loop; exit 0; }

trap '[ -n "$HELPER" ] && rm -f "$HELPER" 2>/dev/null' EXIT

find_installs
if [ ${#INSTALLS[@]} -gt 0 ]; then
  say "Найдено установок: ${#INSTALLS[@]}"
  printf '  - %s\n' "${INSTALLS[@]}"
else
  warn "Antigravity не найден. Установи .deb/.rpm или распакуй tar.gz с https://antigravity.google/download и перезапусти скрипт."
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
    1) [ ${#INSTALLS[@]} -eq 0 ] && { err "Antigravity не найден"; continue; }
       kill_processes
       for RES in "${INSTALLS[@]}"; do patch_install "$RES"; done
       dns_pin ;;
    2) [ ${#INSTALLS[@]} -eq 0 ] && { err "Antigravity не найден"; continue; }
       kill_processes
       for RES in "${INSTALLS[@]}"; do patch_install "$RES"; done ;;
    3) dns_pin ;;
    4) show_status ;;
    5) for RES in "${INSTALLS[@]}"; do kill_processes; unpatch_binaries "$RES"; revert_ide_js "$RES"; done
       remove_hosts_block
       uninstall_watchdog
       touch "$DECLINE_FLAG"
       ok "Полный откат завершён." ;;
    6) if [ -f "$WATCH_UNIT" ]; then
         uninstall_watchdog; touch "$DECLINE_FLAG"; ok "Watchdog выключен."
       else
         install_watchdog
       fi ;;
    0) exit 0 ;;
    *) warn "Неизвестный пункт меню" ;;
  esac
done
