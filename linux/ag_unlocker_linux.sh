#!/bin/bash
# ============================================================================
#  AG Unlocker for Linux  —  порт confeden/Antigravity (Windows) на Linux
#  https://github.com/confeden/Antigravity
#  Собрат скрипта antigravity-unlocker-mac: те же методы, та же DNS-часть.
#
#  Цель: Google Antigravity (Desktop), установленный из .deb/.rpm.
#  В AppImage-версии патч бессмысленный (файл временный) — не поддерживается.
#
#  Как работает (коротко):
#    1) Байтовый патч: "ineligible" -> "inexigible" (по 10 байт, обратимо)
#       в Language Server — клиент перестаёт распознавать отказ eligibility.
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
    found=$(dpkg -L antigravity 2>/dev/null | grep -E 'bin/language_server$')
  fi
  if [ -z "$found" ] && command -v rpm >/dev/null 2>&1; then
    found=$(rpm -ql antigravity 2>/dev/null | grep -E 'bin/language_server$')
  fi
  if [ -z "$found" ]; then
    found=$(find /opt /usr/share /usr/lib "$HOME/.antigravity" "$HOME/opt" \
             -maxdepth 5 -type f -path "*ntigravity*" -name "language_server" 2>/dev/null | grep -v AppImage)
  fi
  for p in $found; do
    local root
    root=$(dirname "$(dirname "$p")")   # .../resources
    INSTALLS+=("$root")
  done
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

# ---------------------------------------------------------------- DNS pin
dig_a() {
  dig +short +time=5 +tries=2 A "$1" @"$2" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u
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
    check_arch "$RES"
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
find_installs
if [ ${#INSTALLS[@]} -gt 0 ]; then
  say "Найдено установок: ${#INSTALLS[@]} (${INSTALLS[0]}...)"
else
  warn "Antigravity не найден. Установи .deb/.rpm с https://antigravity.google/download и перезапусти скрипт."
  warn "В AppImage-версии патч невозможен (файл временный) — используй .deb/.rpm."
fi

while true; do
  say ""
  say "===== Antigravity анлокер для Linux ====="
  say " 1) Разблокировать (патч бинарей + DNS-пин)"
  say " 2) Только патч бинарей (для режима с VPN)"
  say " 3) Обновить DNS-пин (без VPN!)"
  say " 4) Статус / диагностика"
  say " 5) Полный откат (снять патч и вернуть всё как было)"
  say " 0) Выход"
  printf "Выбор: "
  read -r choice || { say ""; exit 0; }
  case "$choice" in
    1) [ ${#INSTALLS[@]} -eq 0 ] && { err "Antigravity не найден"; continue; }
       kill_processes; patch_binaries "${INSTALLS[0]}"; dns_pin ;;
    2) [ ${#INSTALLS[@]} -eq 0 ] && { err "Antigravity не найден"; continue; }
       kill_processes; patch_binaries "${INSTALLS[0]}" ;;
    3) dns_pin ;;
    4) show_status ;;
    5) for RES in "${INSTALLS[@]}"; do kill_processes; unpatch_binaries "$RES"; done
       remove_hosts_block
       ok "Полный откат завершён." ;;
    0) exit 0 ;;
    *) warn "Неизвестный пункт меню" ;;
  esac
done
