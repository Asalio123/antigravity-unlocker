package main

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"runtime"
	"sort"
	"strings"
	"time"

	"github.com/Asalio123/antigravity-unlocker/internal/config"
	"github.com/Asalio123/antigravity-unlocker/internal/discover"
	"github.com/Asalio123/antigravity-unlocker/internal/dns"
	"github.com/Asalio123/antigravity-unlocker/internal/env"
	"github.com/Asalio123/antigravity-unlocker/internal/hosts"
	"github.com/Asalio123/antigravity-unlocker/internal/patcher"
	"github.com/Asalio123/antigravity-unlocker/internal/proc"
	"github.com/Asalio123/antigravity-unlocker/internal/proxy"
	"github.com/Asalio123/antigravity-unlocker/internal/service"
)

const (
	cReset = "\033[0m"
	cGreen = "\033[32m"
	cYel   = "\033[33m"
	cRed   = "\033[31m"
	cCyan  = "\033[36m"
	cBold  = "\033[1m"
)

func ok(format string, a ...any)   { fmt.Printf(cGreen+"[OK]"+cReset+" "+format+"\n", a...) }
func warn(format string, a ...any) { fmt.Printf(cYel+"[!]"+cReset+" "+format+"\n", a...) }
func errf(format string, a ...any) { fmt.Printf(cRed+"[X]"+cReset+" "+format+"\n", a...) }
func info(format string, a ...any) { fmt.Printf(cCyan+"[i]"+cReset+" "+format+"\n", a...) }

func main() {
	if len(os.Args) > 1 {
		os.Exit(runCLI(os.Args[1:]))
	}
	runInteractiveMenu()
}

func runCLI(args []string) int {
	switch args[0] {
	case "daemon", "--daemon", "--watch":
		if err := service.RunDaemon(); err != nil {
			errf("daemon: %v", err)
			return 1
		}
		return 0
	case "enable":
		if err := actionEnableAll(); err != nil {
			errf("%v", err)
			return 1
		}
		return 0
	case "patch":
		fs := flag.NewFlagSet("patch", flag.ExitOnError)
		noProxy := fs.Bool("no-proxy-var", false, "не переименовывать https_proxy (только клиентский гейт)")
		_ = fs.Parse(args[1:])
		if err := actionPatchOnly(!*noProxy); err != nil {
			errf("%v", err)
			return 1
		}
		return 0
	case "disable", "revert":
		if err := actionFullRevert(); err != nil {
			errf("%v", err)
			return 1
		}
		return 0
	case "status":
		actionStatus()
		return 0
	case "hosts-pin":
		if err := actionHostsPin(); err != nil {
			errf("%v", err)
			return 1
		}
		return 0
	case "hosts-clear":
		removed, err := hosts.ClearBlock()
		if err != nil {
			errf("очистка hosts: %v", err)
			return 1
		}
		if removed {
			ok("hosts-блок удалён")
		} else {
			info("hosts-блок не найден")
		}
		return 0
	case "config":
		return runConfigCLI(args[1:])
	case "version", "-v", "--version":
		fmt.Printf("ag-unlocker v%s (%s/%s)\n", config.Version, runtime.GOOS, runtime.GOARCH)
		return 0
	case "help", "-h", "--help":
		printUsage()
		return 0
	default:
		errf("неизвестная команда: %s", args[0])
		printUsage()
		return 1
	}
}

func printUsage() {
	fmt.Printf(`ag-unlocker v%s — разблокировка Google Antigravity без VPN и без ключей

Использование:
  ag-unlocker                  интерактивное меню
  ag-unlocker enable           включить всё (патч + локальный прокси + авто-репатч)
  ag-unlocker patch            только патч бинарей/IDE (для режима со своим VPN)
  ag-unlocker status           статус установок, прокси и живых маршрутов
  ag-unlocker disable          полный откат (снять патч, остановить прокси, почистить всё)
  ag-unlocker config [flags]   настроить --dns и --upstream (или --clear)
  ag-unlocker hosts-pin        опционально прописать прокси в hosts (fallback)
  ag-unlocker hosts-clear      удалить наш блок из hosts
  ag-unlocker daemon           запустить локальный прокси и watchdog в текущем процессе
`, config.Version)
}

func runConfigCLI(args []string) int {
	fs := flag.NewFlagSet("config", flag.ExitOnError)
	dnsList := fs.String("dns", "", "свой DNS через запятую (IPv4, https://... DoH, tls://... DoT)")
	upstream := fs.String("upstream", "", "свой upstream-прокси (http://... или socks5://...)")
	clear := fs.Bool("clear", false, "сбросить пользовательские настройки")
	_ = fs.Parse(args)

	s := config.LoadSettings()
	if *clear {
		s = config.Settings{}
		if err := config.SaveSettings(s); err != nil {
			errf("сохранение: %v", err)
			return 1
		}
		ok("Настройки сброшены (%s)", config.SettingsPath())
		return 0
	}
	changed := false
	if *dnsList != "" {
		var valid []string
		for _, item := range strings.Split(*dnsList, ",") {
			item = strings.TrimSpace(item)
			if item == "" {
				continue
			}
			if _, err := dns.ParseCustomProvider(item); err != nil {
				errf("%v", err)
				return 1
			}
			valid = append(valid, item)
		}
		s.CustomDNS = valid
		changed = true
	}
	if *upstream != "" {
		s.UpstreamProxy = strings.TrimSpace(*upstream)
		changed = true
	}
	if !changed {
		info("Файл настроек: %s", config.SettingsPath())
		fmt.Printf("  custom_dns:     %v\n", s.CustomDNS)
		fmt.Printf("  upstream_proxy: %q\n", s.UpstreamProxy)
		return 0
	}
	if err := config.SaveSettings(s); err != nil {
		errf("сохранение: %v", err)
		return 1
	}
	ok("Настройки сохранены (демон подхватит их автоматически в течение 5 сек)")
	return 0
}

func runInteractiveMenu() {
	reader := bufio.NewReader(os.Stdin)
	printBanner()

	for {
		fmt.Println()
		fmt.Printf(cBold+"===== Antigravity Unlocker v%s (%s/%s) ====="+cReset+"\n", config.Version, runtime.GOOS, runtime.GOARCH)
		fmt.Println(" 1) Включить всё (патч + локальный прокси + авто-репатч)")
		fmt.Println(" 2) Только патч (если пользуешься своим VPN)")
		fmt.Println(" 3) Статус и живая диагностика маршрутов")
		fmt.Println(" 4) Настройки (свой DNS / свой SOCKS5 или HTTP прокси)")
		fmt.Println(" 5) Обновить hosts-пин (опциональный fallback)")
		fmt.Println(" 6) Полный откат (снять патч, остановить прокси, почистить всё)")
		fmt.Println(" 0) Выход")
		fmt.Print("Выбор: ")

		line, err := reader.ReadString('\n')
		if err != nil {
			fmt.Println()
			return
		}
		switch strings.TrimSpace(line) {
		case "1":
			if err := actionEnableAll(); err != nil {
				errf("%v", err)
			}
		case "2":
			if err := actionPatchOnly(false); err != nil {
				errf("%v", err)
			}
		case "3":
			actionStatus()
		case "4":
			interactiveSettings(reader)
		case "5":
			if err := actionHostsPin(); err != nil {
				errf("%v", err)
			}
		case "6":
			if err := actionFullRevert(); err != nil {
				errf("%v", err)
			}
		case "0":
			return
		default:
			warn("Неизвестный пункт меню")
		}
	}
}

func printBanner() {
	installs := discover.FindAll()
	if len(installs) == 0 {
		warn("Установки Antigravity не найдены. Установи Desktop, IDE, CLI или расширение VS Code с https://antigravity.google/download")
	} else {
		info("Найдено установок: %d", len(installs))
		for _, inst := range installs {
			fmt.Printf("  - %s: %s\n", inst.Kind, inst.Root)
		}
	}
	if st, err := proxy.FetchStatus(config.ActivePort()); err == nil {
		ok("Локальный прокси активен: %s (PID %d, маршрутов: %d)", config.ProxyURL(st.Port), st.PID, countRoutes(st.Routes))
	} else {
		info("Локальный прокси сейчас не запущен")
	}
}

func actionEnableAll() error {
	installs := discover.FindAll()
	if len(installs) == 0 {
		return errors.New("Antigravity не найден — установи Desktop, IDE, CLI или расширение VS Code")
	}
	info("Останавливаю процессы Antigravity перед патчем...")
	proc.StopAntigravity()

	patchedAny, permErrors := patchInstalls(installs, true)
	if permErrors > 0 {
		warn("Некоторые системные файлы требуют повышенных прав (например /opt на Linux): запусти `sudo ag-unlocker patch` отдельно, а демон оставь в обычной сессии.")
	}
	if !patchedAny && permErrors > 0 {
		return errors.New("не хватило прав на запись бинарей")
	}

	info("Запускаю локальный прокси + авто-репатч (без прав администратора и без ключей)...")
	port, err := service.InstallAndStart()
	if err != nil {
		return fmt.Errorf("не удалось запустить фоновую службу: %w", err)
	}
	proxyURL := config.ProxyURL(port)
	if err := env.SetProxyEnv(proxyURL); err != nil {
		warn("не удалось записать %s: %v", config.ProxyEnvVar, err)
	} else {
		ok("Переменная %s=%s прописана в пользовательскую сессию", config.ProxyEnvVar, proxyURL)
	}
	ok("Фоновый прокси + авто-репатч работают на %s (лог: %s)", proxyURL, config.LogFilePath())

	// Ждём пару секунд первичного прогрева маршрутов, чтобы показать живой результат
	info("Прогреваю маршруты (проверка живых SNI-прокси)...")
	deadline := time.Now().Add(8 * time.Second)
	var lastSt *proxy.StatusPayload
	for time.Now().Before(deadline) {
		if st, err := proxy.FetchStatus(port); err == nil {
			lastSt = st
			if countRoutes(st.Routes) > 0 {
				break
			}
		}
		time.Sleep(500 * time.Millisecond)
	}
	if lastSt != nil && countRoutes(lastSt.Routes) > 0 {
		printRoutesSummary(lastSt.Routes)
	} else {
		info("Поиск прокси продолжается в фоне — через 10 секунд проверь статус (пункт 3).")
	}

	if globalProxy := os.Getenv("HTTPS_PROXY"); globalProxy != "" && globalProxy != proxyURL {
		warn("В системе задан глобальный HTTPS_PROXY=%s — он имеет приоритет над %s.", globalProxy, config.ProxyEnvVar)
	}
	ok("Готово! Запускай Antigravity и работай без VPN.")
	return nil
}

func actionPatchOnly(enableProxyVar bool) error {
	installs := discover.FindAll()
	if len(installs) == 0 {
		return errors.New("Antigravity не найден")
	}
	info("Останавливаю процессы Antigravity...")
	proc.StopAntigravity()

	_, permErrors := patchInstalls(installs, enableProxyVar)
	if permErrors > 0 {
		return errors.New("не хватило прав на запись части файлов (на Linux для /opt запусти `sudo ag-unlocker patch`)")
	}
	ok("Патч завершён.")
	return nil
}

func patchInstalls(installs []discover.Install, enableProxyVar bool) (patchedAny bool, permErrors int) {
	for _, inst := range installs {
		info("=== %s (%s)", inst.Kind, inst.Root)
		needResign := false

		if inst.MainJS != "" {
			st, err := patcher.PatchIDEMain(inst.MainJS)
			if err != nil {
				errf("IDE main.js: %v", err)
				if errors.Is(err, os.ErrPermission) {
					permErrors++
				}
			} else {
				switch st {
				case patcher.StatusPatched:
					ok("IDE main.js пропатчен")
					needResign = true
					patchedAny = true
				case patcher.StatusAlready:
					ok("IDE main.js уже пропатчен")
					needResign = true
					patchedAny = true
				case patcher.StatusUnknownBuild:
					warn("IDE main.js: сигнатура не найдена (новая сборка?) — файл не тронут")
				}
			}
		}
		if inst.ExtJS != "" {
			if st, err := patcher.PatchIDEExt(inst.ExtJS); err == nil {
				if st == patcher.StatusPatched {
					ok("IDE extension.js пропатчен")
					needResign = true
				} else if st == patcher.StatusAlready {
					ok("IDE extension.js уже пропатчен")
				}
			}
		}

		if len(inst.Binaries) == 0 && inst.Kind == discover.KindIDE26 {
			info("IDE 2.6+: встроенного language_server нет, бэкенд патчится в ~/.gemini/bin/agy")
		}
		for _, bin := range inst.Binaries {
			res, err := patcher.PatchBinary(bin, enableProxyVar)
			if err != nil {
				errf("%s: %v", bin, err)
				if errors.Is(err, os.ErrPermission) {
					permErrors++
				}
				continue
			}
			switch res.Status {
			case patcher.StatusPatched:
				extra := ""
				if res.ProxyHits > 0 {
					extra = fmt.Sprintf(", %s: %d", config.ProxyEnvVar, res.ProxyHits)
				}
				if res.MigratedForeign {
					extra += " (перенесено с другого анлокера)"
				}
				ok("пропатчен (inexigible: %d%s): %s", res.EligibilityHits, extra, bin)
				needResign = true
				patchedAny = true
			case patcher.StatusAlready:
				ok("уже пропатчен (inexigible: %d, %s: %d): %s", res.EligibilityHits, config.ProxyEnvVar, res.ProxyHits, bin)
				needResign = true
				patchedAny = true
			case patcher.StatusUnknownBuild:
				warn("строка не найдена — новая сборка? Файл не тронут: %s", bin)
			}
		}

		if needResign && inst.BundlePath != "" {
			if err := patcher.ResignBundle(inst.BundlePath); err != nil {
				warn("%v", err)
			} else {
				ok("Бандл переподписан ad-hoc: %s", inst.BundlePath)
			}
		}
	}
	return patchedAny, permErrors
}

func actionFullRevert() error {
	info("Останавливаю фоновый прокси и процессы Antigravity...")
	_ = service.StopAndUninstall()
	_ = env.ClearProxyEnv()
	_ = os.MkdirAll(config.DataDir(), 0o755)
	_ = os.WriteFile(config.DeclinePath(), []byte("1\n"), 0o644)
	proc.StopAntigravity()

	installs := discover.FindAll()
	for _, inst := range installs {
		info("=== Откат: %s (%s)", inst.Kind, inst.Root)
		touched := false
		for _, bin := range inst.Binaries {
			res, err := patcher.RevertBinary(bin)
			if err != nil {
				errf("откат %s: %v", bin, err)
				continue
			}
			if res.Status == patcher.StatusPatched {
				ok("откачен (ineligible: %d, https_proxy: %d): %s", res.EligibilityHits, res.ProxyHits, bin)
				touched = true
			}
		}
		if inst.MainJS != "" {
			if st, err := patcher.RevertIDEFile(inst.MainJS); err == nil && st == patcher.StatusPatched {
				ok("IDE main.js восстановлен из бэкапа")
				touched = true
			}
		}
		if inst.ExtJS != "" {
			if st, err := patcher.RevertIDEFile(inst.ExtJS); err == nil && st == patcher.StatusPatched {
				ok("IDE extension.js восстановлен из бэкапа")
				touched = true
			}
		}
		if touched && inst.BundlePath != "" {
			if err := patcher.ResignBundle(inst.BundlePath); err != nil {
				warn("%v", err)
			} else {
				ok("Бандл переподписан ad-hoc: %s", inst.BundlePath)
			}
		}
	}

	if len(hosts.ReadBlock()) > 0 {
		if removed, err := hosts.ClearBlock(); err != nil {
			warn("Не удалось убрать старый блок из %s (нужны права root/admin): %v", hosts.FilePath(), err)
		} else if removed {
			ok("Блок из %s удалён", hosts.FilePath())
		}
	}
	ok("Полный откат завершён.")
	return nil
}

func actionStatus() {
	installs := discover.FindAll()
	if len(installs) == 0 {
		errf("Antigravity не найден")
	}
	for _, inst := range installs {
		info("Установка: %s (%s)", inst.Kind, inst.Root)
		if inst.AsarPath != "" {
			if mod, leg, err := patcher.CheckAsarArchitecture(inst.AsarPath); err == nil {
				if mod && !leg {
					ok("  архитектура v2.4+: auth в Language Server")
				} else {
					warn("  legacy-архитектура (pre-2.4)")
				}
			}
		}
		if inst.MainJS != "" {
			if patcher.IsIDEMainPatched(inst.MainJS) {
				ok("  IDE main.js: пропатчен")
			} else {
				warn("  IDE main.js: НЕ пропатчен")
			}
		}
		if len(inst.Binaries) == 0 && inst.Kind == discover.KindIDE26 {
			info("  IDE 2.6+: бэкенд в ~/.gemini/bin/agy (см. ниже)")
		}
		for _, bin := range inst.Binaries {
			bi, err := patcher.InspectBinary(bin)
			if err != nil {
				errf("  %s: %v", bin, err)
				continue
			}
			switch {
			case bi.EligibilityPatched() && bi.ProxyPatched():
				ok("  пропатчен полностью (inexigible=%d, %s=%d): %s", bi.Inexigible, config.ProxyEnvVar, bi.OurProxy, bin)
			case bi.EligibilityPatched() && bi.ForeignProxy > 0:
				warn("  пропатчен другим анлокером (inexigible=%d, AG_LS_PROXY) — пункт 1 переключит на наш прокси: %s", bi.Inexigible, bin)
			case bi.EligibilityPatched():
				ok("  клиентский гейт снят (inexigible=%d, без прокси-переменной — режим VPN): %s", bi.Inexigible, bin)
			case bi.Ineligible > 0:
				warn("  НЕ пропатчен (ineligible=%d): %s", bi.Ineligible, bin)
			default:
				warn("  строка не найдена (новая сборка?): %s", bin)
			}
		}
	}

	fmt.Println()
	envVal := env.GetProxyEnv()
	if envVal != "" {
		ok("Переменная %s = %s", config.ProxyEnvVar, envVal)
	} else {
		info("Переменная %s не задана", config.ProxyEnvVar)
	}
	if globalProxy := os.Getenv("HTTPS_PROXY"); globalProxy != "" {
		warn("Глобальный HTTPS_PROXY = %s (может перекрывать %s)", globalProxy, config.ProxyEnvVar)
	}

	if st, err := proxy.FetchStatus(config.ActivePort()); err == nil {
		ok("Локальный прокси: РАБОТАЕТ на %s (v%s, PID %d, uptime %ds)", config.ProxyURL(st.Port), st.Version, st.PID, st.UptimeSec)
		if st.Upstream != "" {
			info("  Upstream-прокси: %s", st.Upstream)
		}
		if len(st.CustomDNS) > 0 {
			info("  Свой DNS: %s", strings.Join(st.CustomDNS, ", "))
		}
		if st.LastOK != "" {
			ok("  Последний ответ модели: %s", st.LastOK)
		}
		if st.Last400 != "" {
			warn("  Последний регион-400 (авто-ротация): %s", st.Last400)
		}
		if countRoutes(st.Routes) > 0 {
			printRoutesSummary(st.Routes)
		} else {
			warn("  Активных DNS-прокси маршрутов пока нет (идёт прогрев или провайдеры не отдают подмену)")
		}
	} else {
		if service.IsInstalled() {
			warn("Служба автозапуска установлена, но локальный прокси не отвечает (лог: %s)", config.LogFilePath())
		} else {
			info("Локальный прокси и авто-репатч выключены")
		}
	}

	netInfo := dns.DetectNetwork()
	if netInfo.VPNActive {
		info("Сеть: VPN активен (физический интерфейс: %s)", netInfo.PhysIface)
	} else {
		info("Сеть: VPN не обнаружен (интерфейс: %s)", netInfo.PhysIface)
	}

	if lines := hosts.ReadBlock(); len(lines) > 0 {
		info("Блок в %s (%d записей):", hosts.FilePath(), len(lines))
		for _, l := range lines {
			fmt.Printf("    %s\n", l)
		}
	}
}

func actionHostsPin() error {
	info("Собираю и проверяю живые SNI-прокси для записи в %s...", hosts.FilePath())
	s := config.LoadSettings()
	pool := proxy.NewPool(s, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 35*time.Second)
	defer cancel()
	pool.Refresh(ctx)

	routes, _, _, _ := pool.Snapshot()
	var entries []hosts.Entry
	for _, domain := range config.GateHosts {
		views := routes[domain]
		added := 0
		for _, v := range views {
			if v.Benched {
				continue
			}
			entries = append(entries, hosts.Entry{IP: v.IP, Domain: domain})
			added++
			if added >= 2 {
				break
			}
		}
	}
	if len(entries) == 0 {
		return errors.New("не найдено живых прокси для hosts-пина")
	}
	if err := hosts.WriteBlock(entries); err != nil {
		return fmt.Errorf("%w (для записи в %s нужны права администратора / sudo)", err, hosts.FilePath())
	}
	ok("Записано %d записей в %s:", len(entries), hosts.FilePath())
	for _, e := range entries {
		fmt.Printf("    %s %s\n", e.IP, e.Domain)
	}
	return nil
}

func interactiveSettings(reader *bufio.Reader) {
	s := config.LoadSettings()
	fmt.Println()
	info("Текущие настройки (%s):", config.SettingsPath())
	fmt.Printf("  1) Свой DNS:       %s\n", formatList(s.CustomDNS))
	fmt.Printf("  2) Свой upstream:  %s\n", formatOrNone(s.UpstreamProxy))
	fmt.Println("  3) Сбросить все настройки")
	fmt.Println("  0) Назад")
	fmt.Print("Выбор: ")
	line, _ := reader.ReadString('\n')
	switch strings.TrimSpace(line) {
	case "1":
		fmt.Print("Введи DNS через запятую (IPv4, https://... DoH или tls://... DoT; пусто = очистить): ")
		val, _ := reader.ReadString('\n')
		val = strings.TrimSpace(val)
		if val == "" {
			s.CustomDNS = nil
		} else {
			var parsed []string
			for _, item := range strings.Split(val, ",") {
				item = strings.TrimSpace(item)
				if item == "" {
					continue
				}
				if _, err := dns.ParseCustomProvider(item); err != nil {
					errf("%v", err)
					return
				}
				parsed = append(parsed, item)
			}
			s.CustomDNS = parsed
		}
		if err := config.SaveSettings(s); err != nil {
			errf("сохранение: %v", err)
			return
		}
		ok("DNS обновлён (демон подхватит за 5 сек)")
	case "2":
		fmt.Print("Введи upstream-прокси (например socks5://127.0.0.1:10808 или http://user:pass@host:port; пусто = отключить): ")
		val, _ := reader.ReadString('\n')
		s.UpstreamProxy = strings.TrimSpace(val)
		if err := config.SaveSettings(s); err != nil {
			errf("сохранение: %v", err)
			return
		}
		ok("Upstream-прокси обновлён (демон подхватит за 5 сек)")
	case "3":
		if err := config.SaveSettings(config.Settings{}); err != nil {
			errf("сброс: %v", err)
			return
		}
		ok("Настройки сброшены")
	}
}

func countRoutes(routes map[string][]proxy.EndpointView) int {
	n := 0
	for _, list := range routes {
		for _, v := range list {
			if !v.Benched {
				n++
			}
		}
	}
	return n
}

func printRoutesSummary(routes map[string][]proxy.EndpointView) {
	hostsList := make([]string, 0, len(routes))
	for h := range routes {
		hostsList = append(hostsList, h)
	}
	sort.Strings(hostsList)
	for _, h := range hostsList {
		views := routes[h]
		var parts []string
		for i, v := range views {
			if i >= 3 {
				break
			}
			tag := fmt.Sprintf("%s (%dms, %s)", v.IP, v.LatencyMs, v.Via)
			if v.Proven {
				tag += " ✓"
			}
			if v.Benched {
				tag += " [ban]"
			}
			parts = append(parts, tag)
		}
		info("  %-35s -> %s", h, strings.Join(parts, ", "))
	}
}

func formatList(items []string) string {
	if len(items) == 0 {
		return "(не задано — используется встроенный пул)"
	}
	return strings.Join(items, ", ")
}

func formatOrNone(s string) string {
	if s == "" {
		return "(не задан — бесплатный DNS-пул)"
	}
	return s
}
