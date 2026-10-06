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
#    2) DNS-пин: анблок-DNS (xbox-dns.ru / comss.one / geohide.ru) отдают
#       российским клиентам IP своих SNI-прокси вместо Google; рабочие
#       адреса пинуются в /etc/hosts (маркеры AG_UNLOCKER_HOSTS_*).
#       Ответ провайдера считается подменой, если его /16-подсеть отличается
#       от эталонной (8.8.8.8 / 1.1.1.1). Пиновать ТОЛЬКО с выключенным VPN.
#
#  Зависимости: bash, perl, dig (dnsutils), coreutils. На Linux подписи
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
PROVIDERS=(45.155.204.190 37.230.192.51 111.88.96.50 111.88.96.51 83.220.169.155 212.109.195.93 195.133.25.16)
REFERENCE=(8.8.8.8 1.1.1.1)

C_OK='\033[32m'; C_WARN='\033[33m'; C_ERR='\033[31m'; C_INFO='\033[36m'; C_N='\033[0m'
say()  { printf "%b\n" "$1"; }
ok()   { say "${C_OK}[OK]${C_N} $1"; }
warn() { say "${C_WARN}[!]${C_N} $1"; }
err()  { say "${C_ERR}[X]${C_N} $1"; }
info() { say "${C_INFO}[i]${C_N} $1"; }

# ---------------------------------------------------------------- sudo gate
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
JS_PATCHER=""
ensure_js_patcher() {
  [ -n "$JS_PATCHER" ] && return 0
  JS_PATCHER="${TMPDIR:-/tmp}/.ag_ide_js.$$.pl"
  cat > "$JS_PATCHER" <<'PERLEOF'
#!/usr/bin/perl
# режимы: main|ext|revert <file>
# exit: 0 patched/restored, 2 already/nothing, 3 old patch (нужна переустановка),
#       4 signature not found, 1 io error
use strict;
use warnings;
my ($mode, $file) = @ARGV;
die "usage: $0 main|ext|revert <file>\n" unless $mode && $file;
sub slurp {
    my ($f) = @_;
    open my $fh, '<', $f or die "не прочитать $f: $!";
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
  ensure_js_patcher
  local out rc
  out=$(perl "$JS_PATCHER" main "$main_js" 2>&1); rc=$?
  case $rc in
    0)
      # если есть node — верифицируем синтаксис; при поломке откатываем из бэкапа
      if command -v node >/dev/null 2>&1 && ! node --check "$main_js" 2>/dev/null; then
        perl "$JS_PATCHER" revert "$main_js" >/dev/null 2>&1
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
    out=$(perl "$JS_PATCHER" ext "$ext_js" 2>&1)
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
  ensure_js_patcher
  local f out rc
  for f in "$main_js" "$ext_js"; do
    [ -e "$f" ] || [ -e "$f.ag_backup" ] || continue
    out=$(perl "$JS_PATCHER" revert "$f" 2>&1); rc=$?
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

# liveness: nc если есть, иначе bash /dev/tcp (есть на любом дистрибутиве)
tcp_alive() {
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 3 "$1" 443 >/dev/null 2>&1 && return 0
  else
    (timeout 3 bash -c "exec 3<>/dev/tcp/$1/443") 2>/dev/null && return 0
  fi
  return 1
}

dns_pin() {
  local domain ip prov all_substituted=1
  detect_dns_transport
  PIN_MAP=""
  for domain in "${DOMAINS[@]}"; do
    local ref_blocks
    ref_blocks=$(ref_net16 "$domain")
    [ -z "$ref_blocks" ] && { warn "эталон не ответил для $domain — пропуск"; continue; }
    local dom_ips=""
    for prov in "${PROVIDERS[@]}"; do
      local ans is_sub=0 sub_list=""
      ans=$(dig_a "$domain" "$prov") || continue
      [ -z "$ans" ] && continue
      while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        local b16="${ip%.*.*}"
        if echo "$ref_blocks" | grep -qx "$b16"; then continue; fi
        is_sub=1
        sub_list=$(echo "$sub_list"$'\n'"$ip" | sort -u | sed '/^$/d')
      done <<< "$ans"
      if [ "$is_sub" -eq 1 ]; then
        all_substituted=0
        info "$domain @ $prov -> подмена: $(echo $sub_list)"
        dom_ips=$(echo "$dom_ips"$'\n'"$sub_list" | sort -u | sed '/^$/d')
      else
        info "$domain @ $prov -> честный Google (passthrough)"
      fi
    done
    local dom_live=""
    for ip in $dom_ips; do
      if tcp_alive "$ip"; then
        dom_live=$(echo "$dom_live"$'\n'"$ip" | sort -u | sed '/^$/d')
      else
        warn "$ip:443 не отвечает — не пиную"
      fi
    done
    PIN_MAP="$PIN_MAP$domain:$(echo $dom_live | tr ' ' ',')|"
  done

  if [ "$all_substituted" -eq 1 ] || [ -z "$(echo "$PIN_MAP" | tr -d ':|')" ]; then
    err "Ни один провайдер не отдал подменённые адреса."
    warn "Чаще всего это значит: VPN включён, и провайдеры видят зарубежного клиента."
    warn "Выключи свой VPN-клиент и повтори пункт 3."
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
trap '[ -n "$JS_PATCHER" ] && rm -f "$JS_PATCHER" 2>/dev/null' EXIT

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
  say " 3) Обновить DNS-пин (без VPN!)"
  say " 4) Статус / диагностика"
  say " 5) Полный откат (снять патч и вернуть всё как было)"
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
       ok "Полный откат завершён." ;;
    0) exit 0 ;;
    *) warn "Неизвестный пункт меню" ;;
  esac
done
