# ps5-webkit-autoloader-keenetic

Установщик, который поднимает [Relapse](https://github.com/ntfargo/Relapse-Exploit)
на роутере **Keenetic**: файлы лежат на самом роутере, DNS и веб-сервер тоже на
роутере. После установки компьютер, телефон и роутер провайдера не участвуют —
работают только роутер и приставка.

```text
PS5 ──DNS──> Keenetic 192.168.1.1  (manuals.playstation.net = 192.168.1.1)
PS5 ──HTTPS:443──> Keenetic (встроенный nginx) ──> /storage/www/relapse
```

## Почему именно так

Браузер руководства пользователя в PS5 **не имеет адресной строки** и сам
запрашивает `https://manuals.playstation.net/` — на стандартный порт 443. Отсюда
три требования, без которых схема не работает:

1. **Порт 443.** На Keenetic его занимает веб-интерфейс. Установщик переносит
   HTTPS панели на 8444 и отдаёт 443 эксплоиту. Панель остаётся доступна по
   `http://<ip>/`.
2. **Сертификат на `manuals.playstation.net`.** Самоподписанный — приставка его
   принимает, ровно как публичный сервер `45.56.67.85` из инструкции Relapse.
3. **Правильные пути.** PS5 открывает `/document/ru/ps5/`, поэтому в nginx есть
   `alias` на корень эксплоита. Без него приставка получает вместо JS HTML и
   страница остаётся чёрной.

## Требования

| Параметр | Требование |
| --- | --- |
| Роутер | Keenetic с Entware (включить: веб-интерфейс → Общие настройки → Компоненты → Entware) и встроенным `/usr/sbin/nginx` |
| Проверено на | Keenetic Hopper SE KN-3812, KeeneticOS 5.01.C.2.0-2, aarch64 |
| Свободно на `/storage` | ~14 МБ с пейлоадами, ~1 МБ без них |
| Компьютер | любой Linux/macOS с `ssh`, `scp`, `curl`, `tar`, `openssl` (только на время установки) |
| Приставка | PS5 с прошивкой **7.00 … 13.60** |

## Быстрый старт

```bash
git clone https://github.com/skorp505/ps5-webkit-autoloader-keenetic.git
cd ps5-webkit-autoloader-keenetic
./install.sh --password <пароль роутера>
```

Роутер по умолчанию доступен на `192.168.1.1`. Если адрес другой — укажи его:
`./install.sh --host 192.168.1.1`.

Пароль можно не светить в истории команд:

```bash
KEENETIC_PASSWORD=<пароль> ./install.sh
```

Установщик спросит подтверждение, покажет что изменит, всё загрузит, настроит
DNS, перезапустит nginx и проверит результат. Потом на приставке:

1. **Настройки → Сеть → Настройки → DNS вручную** → `192.168.1.1`
2. **Настройки → Руководство пользователя → Да** → выбрать PS5 → пункт с браузером
3. На предупреждение о сертификате нажать **Да**
4. Дождаться на экране:

   ```text
   [+] ARW ready
   [+] elfldr is listening on port 9021
   [+] pldmgr.elf sent
   [+] allinOne.elf sent
   ```

## Что делает установщик

1. Проверяет, что это Keenetic, есть Entware, `/usr/sbin/nginx` и место на `/storage`
2. Определяет адрес LAN-интерфейса (`Bridge0`)
3. Скачивает Relapse с GitHub (или берёт локальную копию через `--source`)
4. Генерирует самоподписанный сертификат для `manuals.playstation.net`
5. Кладёт файлы в `/storage/www/relapse`, конфиг — в `/storage/www/relapse-nginx.conf`,
   сертификат — в `/storage/www/cert`, init-скрипт — в `/opt/etc/init.d/S50relapse-nginx`
6. Прописывает в KeeneticOS DNS-запись `manuals.playstation.net` и переносит HTTPS
   панели на 8444, затем сохраняет конфигурацию
7. Поднимает nginx и проверяет `https://manuals.playstation.net/` с 200

Файлы пейлоадов из `payloads/` (если есть) тоже загружаются. Дальше установщик
смотрит, какой исходник скачался:

- **Есть `loadOptionalPayloads()` в `kexp.js` и `watchR2()` в `main.js`** — это
  сборка вроде архива Akela-1979 (2.95 МБ). Патч не ставится: штатный R2 сам
  грузит `allinOne.elf` и `pldmgr.elf`. Патчить здесь нельзя: хук вставлялся
  прямо перед `watchR2()`, из-за чего R2 не появлялся, а своя отправка
  `allinOne` роняла рендерер.
- **Функции нет** (ветка `main` на GitHub) — установщик добавляет своё:
  `src/relapse-payloads.js`, список `payloads.json` и хук в `src/main.js` сразу
  после строки `elfldr is listening on port 9021`.

Патч идемпотентный: повторный прогон не дублирует хук. Вернуть исходный `main.js`
можно флагом `--reset-payload-patch`. Подробности в
[payloads/README.md](payloads/README.md).

### etaHEN

`loadOptionalPayloads()` грузит только `pldmgr.elf` и `allinOne.elf`, а
`etaHEN-2.5B.bin` в `mapElf()` отсеивается по требованию ELF-заголовка: это сырой
бинарник, а не ELF. Поэтому etaHEN шлёт роутер — автоматически, отдельным
сторожем `S60relapse-etahen`.

Логика сторожа: ждёт, пока приставка поднимет `allinOne` (порт 8080), и если
etaHEN ещё не запущен (порт 1337 закрыт), отправляет `etaHEN-2.5B.bin` в elfldr
на 9021. От вебкита не зависит совсем, поэтому работает даже если страница
руководства уже закрыта. Лог — `/tmp/relapse-etahen.log` на роутере.

После R2 etaHEN появляется через ~10 секунд. Адрес приставки обязателен —
без `--ps5-ip` установщик встанет и попросит указать его. Сохраняется он в
`/storage/www/relapse/ps5.conf`, рядом — `--no-etahen-watch`, если сторож не нужен
и отправлять вручную:

```bash
ssh -p 222 root@192.168.1.1 \
  '/storage/www/relapse/send-payload.sh /storage/www/relapse/payloads/etaHEN-2.5B.bin <IP-PS5>'
```

## Что меняется на роутере

| Что | Значение |
| --- | --- |
| DNS-запись | `ip host manuals.playstation.net 192.168.1.1` |
| HTTPS панели | `ip http ssl port 8444` (было 443) |
| Файлы | `/storage/www/relapse`, `/storage/www/cert`, `/storage/www/relapse-nginx.conf` |
| Автозапуск | `/opt/etc/init.d/S50relapse-nginx` через `rc.unslung` |
| Логи | `/storage/www/relapse-access.log`, `/tmp/relapse-nginx/error.log` |

Всё это откатывается одной командой (см. ниже). Панель роутера по HTTPS на 8444
не поднимается — это не нужно, HTTP на 80 работает. Удалённый доступ KeenDNS
для этого не использовался; если он у вас есть и нужен, установку 443 делайте
осознанно.

## Порты

| Порт | Кто слушает | Зачем |
| --- | --- | --- |
| 80 | веб-интерфейс роутера | админка |
| 443 | nginx из этого проекта | то, что бьёт PS5 |
| 8443 | nginx из этого проекта | запасной HTTPS |
| 8444 | веб-интерфейс роутера | бывший 443 |
| 8888 | nginx из этого проекта | запасной HTTP |
| 9021 | **приставка** | elfldr, туда шлются пейлоады |

С WAN и других сегментов всё закрыто: nginx слушает только адрес LAN.

## Управление

```bash
R="ssh -p 222 root@192.168.1.1"

$R /opt/etc/init.d/S50relapse-nginx status
$R /opt/etc/init.d/S50relapse-nginx restart
$R tail -20 /tmp/relapse-nginx/error.log      # ошибки
$R tail -40 /storage/www/relapse-access.log  # кто что запрашивал
```

Отправить пейлоад вручную, если нужно:

```bash
$R /storage/www/relapse/send-payload.sh /storage/www/relapse/payloads/etaHEN-2.5B.bin <ip приставки>
```

## Обновление Relapse

```bash
./install.sh --host 192.168.1.1 --password <пароль>
```

Установщик идемпотентный: перезальёт файлы, перезапустит nginx, а патч применит
только если в исходнике нет `loadOptionalPayloads()`. Данные на `/storage`
не трогает.

## Удаление

```bash
./install.sh --host 192.168.1.1 --password <пароль> --uninstall
```

Останавливает nginx, удаляет файлы и сертификаты, возвращает HTTPS панели на 443,
убирает DNS-запись и сохраняет конфигурацию.

## Если не заработало

Частые причины и разбор — в [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).
Быстрая проверка:

```bash
dig +short @192.168.1.1 manuals.playstation.net     # должен быть 192.168.1.1
curl -sk --resolve manuals.playstation.net:443:192.168.1.1 https://manuals.playstation.net/
```

## Структура репозитория

```text
install.sh                              установщик (запускается с компьютера)
router/relapse-nginx.conf.tmpl          шаблон конфига nginx
router/S50relapse-nginx                 автозапуск сервиса на роутере
router/S60relapse-etahen                автозапуск сторожа etaHEN
router/auto-etahen.sh                   сам сторож: шлёт etaHEN после allinOne
router/relapse-payloads.js              модуль автоотправки пейлоадов (кладётся в src/)
router/send-payload.sh                  ручная отправка пейлоада на приставку
payloads/                               сюда кладут свои пейлоады (в git не попадают)
docs/TROUBLESHOOTING.md                 разбор проблем
```

## Правовое

Скрипты в этом репозитории — MIT, см. [LICENSE](LICENSE). Они только раздают
файлы и настраивают роутер.

Сам Relapse — отдельный проект, MIT, авторы: ntfargo, ufm42, Sonic-Iso, Jordy,
Dr. Yenyen, TheFlow, SlidyBat, Flatz, cow, nhk, bollarz, Sleirsgoevy,
EchoStretch, EarthOnion — берётся с GitHub и в это репозиторий не входит.

Пейлоады (`etaHEN`, `allinOne`, `pldmgr`, `kstuff`) — сторонние проекты, здесь их
нет, приносите свои. Используйте только на устройствах, которыми владеете или
которые вам разрешено тестировать.

## English summary

One-shot installer that serves the Relapse PS5 exploit from a Keenetic router.
The PS5 manual browser has no address bar and requests
`https://manuals.playstation.net/` on port 443, so the installer moves the
router's own HTTPS UI to 8444, generates a self-signed certificate for that host,
points Keenetic DNS at itself and starts the built-in nginx on 443.

```bash
./install.sh --host 192.168.1.1 --password <router-password>
```

Nothing but the router and the console is needed afterwards.

## Credits

- Relapse: [ntfargo/Relapse-Exploit](https://github.com/ntfargo/Relapse-Exploit)
- KeeneticOS / Entware: Keenetic Ltd, сообщество Entware
- Пейлоады: [LightningMods/etaHEN](https://github.com/etaHEN/etaHEN),
  kstuff (sleirsgoevy, EchoStretch), AllInOne (Akela-1979),
  Payload Manager (mrbatek88)
