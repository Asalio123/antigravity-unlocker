#!/bin/bash
# ============================================================================
#  AG Unlocker for macOS  —  порт confeden/Antigravity (Windows) на macOS
#  https://github.com/confeden/Antigravity
#
#  Цель: Google Antigravity (Desktop-приложение с antigravity.google/download).
#  Standalone "Antigravity IDE" с той же страницы не тестировался.
#
#  Повторяет методы оригинала 1-в-1:
#    1) Байтовый патч: строка "ineligible" -> "inexigible" (обе по 10 байт,
#       размер файла не меняется, обратимо) в Language Server / agy.
#       В архитектуре v2.4+ вся проверка eligibility (auth/tier) живёт в
#       Language Server, поэтому JS-патчи не нужны — как и в оригинале.
#    2) DNS-пин: подмена ответов для
#          daily-cloudcode-pa.googleapis.com
#          generativelanguage.googleapis.com
#       через "анблок"-DNS (xbox-dns.ru / comss.one / geohide.ru), которые
#       для российских клиентов отдают IP своих SNI-прокси вместо Google.
#       Провайдер считается подменяющим, если его ответ лежит ВНЕ /16-сетей,
#       которые отдаёт эталонный резолвер (8.8.8.8 / 1.1.1.1) — та же логика
#       classify, что в resolvers.rs оригинала. Живые прокси пиннятся в
#       /etc/hosts (аналог hosts_pin.rs, маркеры AG_UNLOCKER_HOSTS_*).
#
#  ВАЖНО (как и в оригинале): анблок-DNS подменяют ответы ТОЛЬКО клиентам,
#  которых они геолоцируют в блокируемом регионе. Запускайте DNS-пин с
#  ВЫКЛЮЧЕННЫМ VPN — иначе провайдеры вернут честные адреса Google и пин
#  не будет применён.
#
#  НЕ портировано из оригинала (намеренно):
#    - "fast route" через HTTPS_PROXY-релей (адреса и relay-ключ автор
#      вырезал из публичного репозитория);
#    - локальный DNS-релей с watchdog'ом (заменён пином в /etc/hosts);
#    - IPv6 prefixpolicy-хак (на macOS /etc/hosts перекрывает DNS для
#      обеих адресных семей);
#    - Gemini CLI патчер (в оригинале помечен deprecated).
#
#  Только штатные инструменты macOS: bash, perl, dig, nc, openssl, codesign.
#  Запуск:  sudo bash ag_unlocker_mac.sh
# ============================================================================

MARKER_BEGIN="# AG_UNLOCKER_HOSTS_BEGIN"
MARKER_END="# AG_UNLOCKER_HOSTS_END"

HOSTS="${AG_HOSTS:-/etc/hosts}"   # AG_HOSTS=/tmp/hosts_test — для теста без правки системы
DOMAINS=(
  "daily-cloudcode-pa.googleapis.com"
  "generativelanguage.googleapis.com"
)
# DNS-провайдеры оригинала (resolvers.rs) + эталонные резолверы
PROVIDERS=(45.155.204.190 37.230.192.51 111.88.96.50 111.88.96.51 83.220.169.155 212.109.195.93 195.133.25.16)
REFERENCE=(8.8.8.8 1.1.1.1)

APP_CANDIDATES=(
  "/Applications/Antigravity.app"
  "$HOME/Applications/Antigravity.app"
)
AGY_CANDIDATES=("/usr/local/bin/agy" "$HOME/.local/bin/agy" "$HOME/bin/agy")

C_OK='\033[32m'; C_WARN='\033[33m'; C_ERR='\033[31m'; C_INFO='\033[36m'; C_N='\033[0m'
say()  { printf "%b\n" "$1"; }
ok()   { say "${C_OK}[OK]${C_N} $1"; }
warn() { say "${C_WARN}[!]${C_N} $1"; }
err()  { say "${C_ERR}[X]${C_N} $1"; }
info() { say "${C_INFO}[i]${C_N} $1"; }

# ---------------------------------------------------------------- sudo gate
# AG_NO_ELEVATE=1 — dev/CI-режим: не поднимать права (таргеты должны быть доступны на запись)
if [ "$(id -u)" -ne 0 ] && [ -z "$AG_NO_ELEVATE" ]; then
  info "Нужны права администратора (патч бинарей в /Applications + запись /etc/hosts). Перезапуск через sudo..."
  exec sudo bash "$0" "$@"
fi

# ---------------------------------------------------------------- app discovery
find_app() {
  for c in "${APP_CANDIDATES[@]}"; do
    [ -d "$c" ] && { echo "$c"; return 0; }
  done
  return 1
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
  pkill -f "Antigravity" 2>/dev/null
  pkill -f "language_server" 2>/dev/null
  pkill -f "agy" 2>/dev/null
  sleep 1
}

# ---------------------------------------------------------------- binary patch
patch_binaries() {
  local APP="$1"; local total=0
  collect_targets "$APP"
  [ ${#TARGETS[@]} -eq 0 ] && { err "Патч-цели не найдены (Antigravity установлен?)"; return 1; }
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
  # патч ломает seal бандла → GUI-запуск даёт «повреждено»; лечится ad-hoc переподписью бандла
  local f0="${TARGETS[0]}"
  case "$f0" in
    *.app/*)
      local bundle="${f0%%.app/*}.app"
      xattr -dr com.apple.quarantine "$bundle" 2>/dev/null
      if codesign --force --deep --sign - "$bundle" 2>/dev/null; then
        ok "Бандл переподписан ad-hoc — запуск из Finder/Launchpad работает"
      else
        warn "Не удалось переподписать $bundle"
        warn "Системные настройки → Конфиденциальность и безопасность → Управление приложениями → включи свой терминал, затем повтори патч"
      fi
      ;;
  esac
  return 0
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
}

# ---------------------------------------------------------------- DNS pin
dig_a() { # $1 = domain, $2 = server -> stdout: IPv4 построчно
  dig +short +time=5 +tries=2 A "$1" @"$2" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u
}

ref_net16() { # $1 = domain -> stdout: "/16-сети эталона"
  local r
  for r in "${REFERENCE[@]}"; do dig_a "$1" "$r"; done | cut -d. -f1,2 | sort -u
}

dns_pin() {
  # bash 3.2-совместимо: без ассоциативных массивов, дедуп через sort -u
  # PIN_MAP — "domain:ip1,ip2|domain:ip1,..." — IP пинуются строго per-domain
  local domain ip prov all_substituted=1
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
        local b16="${ip%.*.*}"   # первые два октета
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
    # liveness-проба живых прокси на 443 (аналог tls-SNI пробы resolvers.rs)
    local dom_live=""
    for ip in $dom_ips; do
      if nc -z -G 3 "$ip" 443 2>/dev/null; then
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

# ---------------------------------------------------------------- status
show_status() {
  local APP
  APP=$(find_app) || { err "Antigravity не найден"; return 1; }
  info "Установка: $APP"
  check_arch "$APP"
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
  if grep -q "$MARKER_BEGIN" "$HOSTS" 2>/dev/null; then
    ok "hosts-блок:"
    sed -n "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/p" "$HOSTS" | sed '1d;$d' | sed 's/^/    /'
  else
    info "hosts-блока нет (режим «без VPN» не настроен)"
  fi
}

# ---------------------------------------------------------------- menu / main
APP=$(find_app) || APP=""
if [ -n "$APP" ]; then
  say "Найдено: $APP"
else
  warn "Antigravity.app не найден. Установи с https://antigravity.google/download (macOS Apple Silicon/Intel) и перезапусти скрипт."
fi

while true; do
  say ""
  say "===== Antigravity анлокер для macOS ====="
  say " 1) Разблокировать (патч бинарей + DNS-пин)"
  say " 2) Только патч бинарей (для режима с VPN)"
  say " 3) Обновить DNS-пин (без VPN!)"
  say " 4) Статус / диагностика"
  say " 5) Полный откат (снять патч и вернуть всё как было)"
  say " 0) Выход"
  printf "Выбор: "
  read -r choice || { say ""; exit 0; }
  case "$choice" in
    1) [ -z "$APP" ] && { err "Antigravity не найден"; continue; }
       kill_processes; patch_binaries "$APP"; dns_pin ;;
    2) [ -z "$APP" ] && { err "Antigravity не найден"; continue; }
       kill_processes; patch_binaries "$APP" ;;
    3) dns_pin ;;
    4) show_status ;;
    5) [ -n "$APP" ] && { kill_processes; unpatch_binaries "$APP"; }
       remove_hosts_block
       ok "Полный откат завершён." ;;
    0) exit 0 ;;
    *) warn "Неизвестный пункт меню" ;;
  esac
done
