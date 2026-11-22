# Antigravity Unlocker — macOS, Linux и Windows

Открытый анлокер для **Google Antigravity** (Desktop, standalone IDE `2.5.x`/`2.6+`, CLI `agy` и расширение для **VS Code / Cursor / Windsurf**) из России — **без VPN, без ключей, без паролей и без смены региона Google-аккаунта**.

| Платформа | Архитектуры | Установка | Права администратора |
|---|---|---|---|
| **macOS** 12+ | Apple Silicon (`arm64`), Intel (`amd64`) | 1 команда / готовый бинарь / `go build` | Не нужны (если `.app` в пользовательской зоне / перенесён из `.dmg`) |
| **Linux** | `x86_64`, `arm64` | 1 команда / готовый бинарь / `go build` | Не нужны для прокси и `~/.gemini/bin`; `sudo` только для патча `/opt` |
| **Windows** 10/11 | `x86_64` | 1 команда PowerShell / `.exe` / `go build` | Не нужны (пользовательский реестр `HKCU`, без UAC) |

> Написан на чистом **Go (только стандартная библиотека, 0 сторонних зависимостей)** — собирается в один статический бинарь без Python/Perl/dig/curl. Лицензия — [MIT](LICENSE).
>
> Предыдущие bash-скрипты (v2.1) оставлены в [`macos/ag_unlocker_mac.sh`](macos/ag_unlocker_mac.sh) и [`linux/ag_unlocker_linux.sh`](linux/ag_unlocker_linux.sh) как запасной вариант.

---

## Быстрый старт

### 1. Установи Antigravity
Скачай Desktop, IDE, CLI или расширение VS Code с [antigravity.google/download](https://antigravity.google/download).
Если ставишь расширение VS Code / Cursor / Windsurf или IDE `2.6.0+` — открой его один раз, чтобы оно скачало бэкенд в `~/.gemini/bin/agy`.

### 2. Запусти анлокер

**macOS и Linux:**
```bash
curl -fsSL https://raw.githubusercontent.com/Asalio123/antigravity-unlocker/main/scripts/install.sh | bash
```

**Windows (PowerShell, права администратора не нужны):**
```powershell
irm https://raw.githubusercontent.com/Asalio123/antigravity-unlocker/main/scripts/install.ps1 | iex
```

**Или собери сам из исходников (нужен только Go 1.24+, без внешних пакетов):**
```bash
git clone https://github.com/Asalio123/antigravity-unlocker.git
cd antigravity-unlocker
go build -o ag-unlocker ./cmd/ag-unlocker
./ag-unlocker
```

### 3. Нажми `1` (Включить всё)
Анлокер сам:
1. Найдёт все установленные продукты Antigravity (Desktop, IDE, CLI, VS Code).
2. Пропатчит бинари и (для IDE `2.5.x`) JS-шелл.
3. Поднимет лёгкий локальный `CONNECT`-прокси на `127.0.0.1:53189` + фоновый авто-репатч после обновлений.
4. Пропишет выделенную переменную `AG_UNL_PRXY` только для Antigravity (остальные программы в системе вообще не затрагиваются).

Перезапусти Antigravity — вход и модели заработают сразу, без ключей и без VPN.

---

## Как это работает (v3.0)

### 1. Побайтовый патч бинаря (обратим 1-в-1)
В каждом найденном `language_server` и `agy` делаются две замены одинаковой длины — структура Mach-O / ELF / PE не меняется:
- `ineligible` → `inexigible` (10 байт): снимает клиентскую проверку региона в ответе сервера.
- `https_proxy` → `AG_UNL_PRXY` (11 байт): переключает чтение прокси внутри Go-клиента Language Server на нашу приватную переменную, чтобы трафик Antigravity шёл в локальный прокси, а браузеры, git, VPN и вся остальная система оставались нетронутыми.

На macOS бинари и `.app` переподписываются ad-hoc (`codesign --force --deep --sign -`), снимается карантин.
У standalone IDE `2.5.x` дополнительно патчится `resources/app/out/main.js` (с бэкапом `.ag_backup`).

### 2. Локальный `CONNECT`-прокси (без MITM и без Root CA)
Прокси слушает строго `127.0.0.1` (`53189`, с авто-резервом `43189–48189`):
- **Весь обычный трафик** (`accounts.google.com`, `oauth2`, загрузка обновлений и т.д.) пробрасывается напрямую сырым TCP-туннелем — TLS остаётся end-to-end с Google.
- **Только 4 гейт-домена** (`daily-cloudcode-pa.googleapis.com`, `cloudcode-pa.googleapis.com`, `generativelanguage.googleapis.com`, `aicode.googleapis.com`) идут через живой пул бесплатных SNI-прокси:
  - Опрашивает актуальный пул (`eu.geohide.ru` по UDP+TCP/53, `dns.geohide.ru` по DoH+UDP/TCP, `dns.dns-ai.ru` по DoH HTTP/2) и любые пользовательские DNS (`IPv4`, `https://...` DoH, `tls://...` DoT).
  - При включённом VPN умеет слать DNS-запросы мимо туннеля через физический интерфейс (`IP_BOUND_IF` / `SO_BINDTODEVICE` / `IP_UNICAST_IF`) с авто-fallback.
  - Отсекает клиентские подсети Google (`142.250/15`, `172.217/16` и др.), локальные и FakeIP (`198.18/15`) — прямой Google IP больше не попадёт в пул.
  - Проводит живую проверку TLS (валидный сертификат Google) + HTTP для каждого кандидата, включая кросс-SNI проверку `cloudcode-pa.googleapis.com`.
  - **Авто-ротация и самолечение:** если соединение с прокси отвалилось — в рамках того же запроса переключается на следующий; фоновый парсер `language_server.log` видит серверный `400 User location is not supported` и мгновенно отправляет проблемный IP в бан на 30 минут.
  - **Свой upstream (опционально):** можно указать свой `socks5://...` или `http://...` (пункт 4 меню) — через него пойдут только 4 гейт-домена Antigravity, без проксирования всей системы.

### 3. Фоновый авто-репатч (Watchdog)
Встроен в тот же фоновый процесс (`LaunchAgent` на macOS, `systemd --user` / detached на Linux, `HKCU\...\Run` на Windows). После автообновления Antigravity ждёт стабилизации файла (2 тика) и автоматически восстанавливает патч (и переподпись `.app` на macOS) примерно за 6 секунд. Неизвестную новую сборку не трогает.

---

## Команды и меню

Запуск без аргументов открывает интерактивное меню:
```text
===== Antigravity Unlocker v3.0.0 =====
 1) Включить всё (патч + локальный прокси + авто-репатч)
 2) Только патч (если пользуешься своим VPN)
 3) Статус и живая диагностика маршрутов
 4) Настройки (свой DNS / свой SOCKS5 или HTTP прокси)
 5) Обновить hosts-пин (опциональный fallback)
 6) Полный откат (снять патч, остановить прокси, почистить всё)
 0) Выход
```

То же самое доступно без интерактива из CLI:
```bash
ag-unlocker enable                                        # включить всё
ag-unlocker patch                                         # только патч (для /opt на Linux: sudo ag-unlocker patch)
ag-unlocker status                                        # статус установок, прокси и активных маршрутов
ag-unlocker config --dns 1.2.3.4,https://dns.site/dns-query
ag-unlocker config --upstream socks5://127.0.0.1:10808    # свой SOCKS5/HTTP только для Antigravity
ag-unlocker config --clear                                # сбросить кастомные настройки
ag-unlocker hosts-pin                                     # опциональный hosts-пин (требует root/admin)
ag-unlocker disable                                       # полный откат всего
```

---

## Если что-то не работает

<details>
<summary><b>macOS: «Приложение Antigravity.app повреждено и его не удается открыть»</b></summary>

1. Нажми **«Отменить»** (не «Переместить в Корзину»).
2. Открой **Системные настройки → Конфиденциальность и безопасность → Управление приложениями** и включи свой терминал.
3. Запусти `ag-unlocker enable` ещё раз — скрипт снимет карантин и переподпишет `.app` ad-hoc.
</details>

<details>
<summary><b>Linux: Antigravity стоит в `/opt` от root, пункт 1 пишет `permission denied`</b></summary>

Патч системных файлов в `/opt` или `/usr` требует root, а локальный прокси и переменная среды должны жить в твоей пользовательской сессии:
```bash
sudo ag-unlocker patch   # пропатчить /opt от root
ag-unlocker enable       # запустить прокси и прописать AG_UNL_PRXY в своей сессии
```
</details>

<details>
<summary><b>HTTP 400 «User location is not supported»</b></summary>

1. Проверь `ag-unlocker status`: локальный прокси должен работать, `AG_UNL_PRXY` должна быть выставлена, а бинарь — пропатчен с `AG_UNL_PRXY=1`.
2. Если в терминале/системе выставлен глобальный `HTTPS_PROXY` — он перекрывает `AG_UNL_PRXY` (статус покажет предупреждение).
3. Если провайдер режет бесплатные SNI-прокси, в пункте 4 можно задать свой `socks5://` или `http://` прокси или свой DoH/DoT DNS.
</details>

<details>
<summary><b>VS Code / Cursor / Windsurf или IDE 2.6.0+ не находится</b></summary>

Бэкенд `agy` скачивается отдельно в `~/.gemini/bin/agy` (`%USERPROFILE%\.gemini\bin\agy.exe` на Windows). Открой расширение или IDE один раз, чтобы файл скачался, затем повтори `ag-unlocker enable`.
</details>

---

## Безопасность и открытость

- **0 сторонних зависимостей** — только стандартная библиотека Go (`go.mod` пуст от внешних пакетов), весь исходный код в `cmd/` и `internal/`.
- **Без ключей и закрытых релеев** — никаких подписок, лицензий, телеметрии, сбора токенов или установки корневых сертификатов (CA).
- **Полный откат** — `ag-unlocker disable` (пункт 6) останавливает фоновый процесс, удаляет автозапуск и `AG_UNL_PRXY`, возвращает бинари и IDE JS в исходное состояние побайтово и чистит hosts-блок.

---

## Проверенные версии

| Продукт | Версия | Платформа | Статус |
|---|---|---|---|
| Antigravity Desktop | 2.10.0–2.34.0 | macOS arm64 | ✅ полная проверка |
| Antigravity Desktop | 2.11.0 / 2.19.1+ | Linux x86_64 | ✅ патч + откат |
| Antigravity IDE | 2.5.5 / 2.6.0+ | macOS + Linux + Windows | ✅ JS / `~/.gemini/bin/agy` |
| Antigravity CLI / VS Code | актуальные | macOS + Linux + Windows | ✅ байтовый патч + локальный прокси |

## Лицензия и дисклеймер

Самостоятельная open-source реализация с нуля под лицензией [MIT](LICENSE).
Инструмент для личного доступа к публично бесплатному инструменту разработки из региона гео-ограничений. Использование — на собственный риск пользователя.
