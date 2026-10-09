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
#       через "анблок"-DNS (xbox-dns.ru / comss.one / geohide.ru), которые
#       для российских клиентов отдают IP своих SNI-прокси вместо Google.
#       Провайдер считается подменяющим, если его ответ лежит ВНЕ /16-сетей,
#       которые отдаёт эталонный резолвер (8.8.8.8 / 1.1.1.1) — та же логика
#       classify, что в resolvers.rs оригинала. Живые прокси пиннятся в
#       /etc/hosts (аналог hosts_pin.rs, маркеры AG_UNLOCKER_HOSTS_*).
#
#  Анблок-DNS подменяют ответы ТОЛЬКО клиентам, которых они геолоцируют
#  в блокируемом регионе. Состояние VPN больше не важно: DoH-запросы идут
#  мимо туннеля через физический интерфейс (scoped routing macOS).
#
#  НЕ портировано из оригинала (намеренно):
#    - "fast route" через HTTPS_PROXY-релей (адреса и relay-ключ автор
#      вырезал из публичного репозитория);
#    - локальный DNS-релей с watchdog'ом (заменён пином в /etc/hosts);
#    - IPv6 prefixpolicy-хак (на macOS /etc/hosts перекрывает DNS для
#      обеих адресных семей);
#    - Gemini CLI патчер (в оригинале помечен deprecated).
#
#  Только штатные инструменты macOS: bash, perl, dig, curl, openssl, codesign.
#  Запуск:  sudo bash ag_unlocker_mac.sh
# ============================================================================

MARKER_BEGIN="# AG_UNLOCKER_HOSTS_BEGIN"
MARKER_END="# AG_UNLOCKER_HOSTS_END"

HOSTS="${AG_HOSTS:-/etc/hosts}"   # AG_HOSTS=/tmp/hosts_test — для теста без правки системы
DOMAINS=(
  "daily-cloudcode-pa.googleapis.com"
  "generativelanguage.googleapis.com"
  "cloudcode-pa.googleapis.com"
)
# DNS-провайдеры оригинала (resolvers.rs), актуализировано 2026-10-09:
# xbox-dns.ru выкинут — с 07.10.2026 сервис мёртв (хостер заблокировал аккаунт
# после обращения РКН). Остались geohide/comss (UDP) + DoH-эндпоинты тех же
# сервисов и dns-ai.ru (DoH-only, HTTP/2; IP захардкожены — сертификат по имени
# защищает от подмены при протухшем IP).
PROVIDERS=(45.155.204.190 37.230.192.51 83.220.169.155 212.109.195.93 195.133.25.16)
# "host|ip1,ip2,...|h1|h2" — h2 = только HTTP/2 (dns-ai на h1 отвечает 505)
DOH_PROVIDERS=(
  "dns.geohide.ru|37.230.192.51,45.155.204.190|h1"
  "dns.comss.one|83.220.169.155,212.109.195.93,195.133.25.16|h1"
  "dns.dns-ai.ru|192.144.59.14,186.246.49.127,185.251.90.181|h2"
)
REFERENCE=(8.8.8.8 1.1.1.1)

APP_CANDIDATES=(
  "/Applications/Antigravity.app"
  "$HOME/Applications/Antigravity.app"
  "/Applications/Antigravity IDE.app"
  "$HOME/Applications/Antigravity IDE.app"
)
AGY_CANDIDATES=("/usr/local/bin/agy" "$HOME/.local/bin/agy" "$HOME/bin/agy")

C_OK='\033[32m'; C_WARN='\033[33m'; C_ERR='\033[31m'; C_INFO='\033[36m'; C_N='\033[0m'
say()  { printf "%b\n" "$1"; }
ok()   { say "${C_OK}[OK]${C_N} $1"; }
warn() { say "${C_WARN}[!]${C_N} $1"; }
err()  { say "${C_ERR}[X]${C_N} $1"; }
info() { say "${C_INFO}[i]${C_N} $1"; }

# ---------------------------------------------------------------- sudo gate
# --watch: фоновый режим watchdog (из LaunchAgent) — без меню и без sudo
if [ "$1" = "--watch" ]; then
  AG_NO_ELEVATE=1
fi
# AG_NO_ELEVATE=1 — dev/CI-режим: не поднимать права (таргеты должны быть доступны на запись)
if [ "$(id -u)" -ne 0 ] && [ -z "$AG_NO_ELEVATE" ]; then
  info "Нужны права администратора (патч бинарей в /Applications + запись /etc/hosts). Перезапуск через sudo..."
  exec sudo bash "$0" "$@"
fi

# ---------------------------------------------------------------- app discovery
# Desktop и IDE могут стоять одновременно (+ копии в /Applications и ~/Applications) —
# собираем ВСЕ найденные бандлы.
find_apps() {
  APPS=()
  local c
  for c in "${APP_CANDIDATES[@]}"; do
    [ -d "$c" ] && APPS+=("$c")
  done
  # AG_APP=/path/to/Some.app — ручной путь для нестандартного расположения
  if [ -n "$AG_APP" ] && [ -d "$AG_APP" ]; then
    APPS=("$AG_APP")
  fi
  [ ${#APPS[@]} -gt 0 ]
}

# Патч-цели: Language Server внутри бандла (+ extensions-путь старых сборок) и agy CLI.
# Только Mach-O, содержащие целевую строку. Electron Framework сознательно не
# трогаем — оригинал патчит только language_server/agy.
collect_targets() {
  APP="$1"
  TARGETS=()
  local candidates=(
    "$APP/Contents/Resources/bin/language_server"
    "$APP"/Contents/Resources/app/extensions/antigravity/bin/language_server*
  )
  local agy
  for agy in "${AGY_CANDIDATES[@]}" "$(command -v agy 2>/dev/null)"; do
    [ -x "$agy" ] && candidates+=("$agy")
  done
  local f
  for f in "${candidates[@]}"; do
    [ -f "$f" ] || continue
    file "$f" | grep -q "Mach-O" || continue
    grep -q "ineligible\|inexigible" "$f" && TARGETS+=("$f")
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
  pkill -f "Antigravity" 2>/dev/null
  pkill -f "language_server" 2>/dev/null
  pkill -f "agy" 2>/dev/null
  sleep 1
}

# ---------------------------------------------------------------- binary patch
patch_binaries() {
  local APP="$1"; local total=0 already=0
  collect_targets "$APP"
  [ ${#TARGETS[@]} -eq 0 ] && { err "Патч-цели не найдены (Antigravity установлен?)"; return 1; }
  local f in_cnt out_cnt
  for f in "${TARGETS[@]}"; do
    in_cnt=$(perl -0777 -ne 'my $c=()=/ineligible/g; print $c' "$f")
    out_cnt=$(perl -0777 -ne 'my $c=()=/inexigible/g; print $c' "$f")
    if [ "$in_cnt" -eq 0 ] && [ "$out_cnt" -gt 0 ]; then
      ok "уже пропатчен: $f ($out_cnt вхожд.)"
      already=$((already+1))
      continue
    fi
    if [ "$in_cnt" -eq 0 ]; then
      warn "строка не найдена — новая сборка? Пропускаю: $f"
      continue
    fi
    perl -0777 -pi -e 's/ineligible/inexigible/g' "$f" || { err "не удалось записать: $f"; continue; }
    # подпись Mach-O после правки невалидна — ad-hoc re-sign (аналог «структура PE не тронута»)
    codesign --force --sign - "$f" 2>/dev/null
    out_cnt=$(perl -0777 -ne 'my $c=()=/inexigible/g; print $c' "$f")
    if [ "$out_cnt" -eq "$in_cnt" ]; then
      ok "пропатчен ($out_cnt вхожд.): $f"
      total=$((total+1))
    else
      err "проверка после патча не сошлась: $f (было $in_cnt, стало $out_cnt)"
    fi
  done
  [ "$total" -gt 0 ] && info "Бинарный патч применён к $total файл(ам). Запусти Antigravity и войди в Google-аккаунт."
  # seal бандла битый, если мы патчили сейчас ИЛИ он уже был пропатчен — только тогда переподписываем
  [ "$total" -gt 0 ] || [ "$already" -gt 0 ] && NEED_RESIGN=1
  return 0
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
  local f out_cnt
  for f in "${TARGETS[@]}"; do
    out_cnt=$(perl -0777 -ne 'my $c=()=/inexigible/g; print $c' "$f" 2>/dev/null || echo 0)
    [ "$out_cnt" -eq 0 ] && continue
    perl -0777 -pi -e 's/inexigible/ineligible/g' "$f" || { err "не удалось откатить: $f"; continue; }
    codesign --force --sign - "$f" 2>/dev/null
    ok "откачен ($out_cnt вхожд.): $f"
    total=$((total+1))
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
# если UDP/53 наружу закрыт (VM/корпоративные сети), но TCP работает — переключаемся на DNS over TCP
detect_dns_transport() {
  if [ -z "$(dig +short +time=3 +tries=1 A google.com @8.8.8.8 2>/dev/null)" ]; then
    if [ -n "$(dig +short +tcp +time=3 +tries=1 A google.com @8.8.8.8 2>/dev/null)" ]; then
      DIG_OPT="+tcp"
      info "UDP/53 недоступен — использую DNS over TCP"
    fi
  fi
}

dig_a() { # $1 = domain, $2 = server -> stdout: IPv4 построчно
  local out
  out=$(dig $DIG_OPT +short +time=4 +tries=1 A "$1" @"$2" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u)
  if [ -z "$out" ]; then
    out=$(dig +tcp +short +time=4 +tries=1 A "$1" @"$2" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u)
  fi
  echo "$out"
}

ref_net16() { # $1 = domain -> stdout: "/16-сети эталона"
  local r
  for r in "${REFERENCE[@]}"; do dig_a "$1" "$r"; done | cut -d. -f1,2 | sort -u
}

# --- обход VPN для DoH-запросов: scoped routing macOS отпускает сокет,
# привязанный к физическому интерфейсу, мимо туннеля (проверено живьём)
VPN_ON=0; CURL_IF=""
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
  route -n get -inet default 2>/dev/null | grep -q "interface: utun" || return 0
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
  # Кандидаты: UDP-провайдеры + DoH-провайдеры (с обходом туннеля при активном VPN).
  # Перед пином каждый кандидат проходит боевую HTTPS-пробу; пинуются до 2 быстрейших.
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
  # удалить старый блок, если есть
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
  dscacheutil -flushcache 2>/dev/null; killall -HUP mDNSResponder 2>/dev/null
  ok "Пропинено в $HOSTS:"
  sed -n "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/p" "$HOSTS" | sed '1d;$d' | sed 's/^/    /'
}

remove_hosts_block() {
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
WATCH_PLIST="$HOME/Library/LaunchAgents/$WATCH_LABEL.plist"
DECLINE_FLAG="$HOME/.ag_unlocker_no_watch"
WATCH_STATE="${TMPDIR:-/tmp}/.ag_watch_state"
WATCH_LOG="/tmp/ag_unlocker_watch.log"

f_sig() { stat -f '%z:%m' "$1" 2>/dev/null || echo absent; }
state_name() { echo "$1" | md5 -q; }

watch_loop() {
  mkdir -p "$WATCH_STATE"
  find_apps 2>/dev/null || true
  echo "$(date '+%F %T') watchdog стартанул (pid $$)" >> "$WATCH_LOG"
  local tick=0
  while true; do
    if [ -f "$DECLINE_FLAG" ]; then
      echo "$(date '+%F %T') decline-флаг — выход" >> "$WATCH_LOG"; exit 0
    fi
    local targets="" APP f
    for APP in "${APPS[@]}"; do
      for f in "$APP"/Contents/Resources/bin/language_server* \
               "$APP"/Contents/Resources/app/extensions/antigravity/bin/language_server* \
               "$APP/Contents/Resources/app/out/main.js" \
               "$APP/Contents/Resources/app/extensions/antigravity/dist/extension.js"; do
        [ -f "$f" ] && targets="$targets$f
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
    # рефреш hosts-пина раз в ~10 мин: пин есть, но все IP домена мертвы -> полный рефреш
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
  local self; self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  rm -f "$DECLINE_FLAG"
  cat > "$WATCH_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$WATCH_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$self</string><string>--watch</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$WATCH_LOG</string>
  <key>StandardErrorPath</key><string>$WATCH_LOG</string>
</dict></plist>
EOF
  launchctl bootout "gui/$(id -u)/$WATCH_LABEL" 2>/dev/null
  if launchctl bootstrap "gui/$(id -u)" "$WATCH_PLIST" 2>/dev/null; then
    ok "Watchdog установлен (LaunchAgent, KeepAlive). Лог: $WATCH_LOG"
    info "После автообновления Antigravity патч восстановится сам через ~5 секунд."
    info "Если файлы приложения принадлежат root — watchdog напишет в лог, что нужен ручной запуск."
  else
    err "launchctl bootstrap не удался"; return 1
  fi
}

uninstall_watchdog() {
  launchctl bootout "gui/$(id -u)/$WATCH_LABEL" 2>/dev/null && ok "Watchdog остановлен"
  rm -f "$WATCH_PLIST"
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

find_apps || true
if [ ${#APPS[@]} -gt 0 ]; then
  say "Найдено бандлов: ${#APPS[@]}"
  printf '  - %s\n' "${APPS[@]}"
else
  warn "Antigravity не найден. Установи Desktop или IDE с https://antigravity.google/download (macOS Apple Silicon/Intel) и перезапусти скрипт."
fi

while true; do
  say ""
  say "===== Antigravity анлокер для macOS ====="
  say " 1) Разблокировать (патч + DNS-пин, все найденные бандлы)"
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
    1) [ ${#APPS[@]} -eq 0 ] && { err "Antigravity не найден"; continue; }
       kill_processes
       for APP in "${APPS[@]}"; do patch_install "$APP"; done
       dns_pin ;;
    2) [ ${#APPS[@]} -eq 0 ] && { err "Antigravity не найден"; continue; }
       kill_processes
       for APP in "${APPS[@]}"; do patch_install "$APP"; done ;;
    3) dns_pin ;;
    4) show_status ;;
    5) for APP in "${APPS[@]}"; do kill_processes; revert_install "$APP"; done
       remove_hosts_block
       uninstall_watchdog
       touch "$DECLINE_FLAG"
       ok "Полный откат завершён." ;;
    6) if [ -f "$WATCH_PLIST" ]; then
         uninstall_watchdog; touch "$DECLINE_FLAG"; ok "Watchdog выключен."
       else
         install_watchdog
       fi ;;
    0) exit 0 ;;
    *) warn "Неизвестный пункт меню" ;;
  esac
done
