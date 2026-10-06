# Пейлоады сюда не кладутся

Здесь лежат **ваши** бинарники — репозиторий их не содержит и не должен:
это чужие проекты со своими лицензиями.

Установщик подхватывает всё, что найдёт в этой папке, и дальше ведёт себя
по-разному в зависимости от исходника:

- Если в `kexp.js` есть `loadOptionalPayloads()`, а в `main.js` — `watchR2()`
  (сборка вроде архива Akela-1979, 2.95 МБ), патч **не ставится вообще**.
  Приставка по R2 сама грузит `allinOne.elf` и `pldmgr.elf`.

- Если `loadOptionalPayloads()` нет (ветка `main` на GitHub), установщик пишет
  список в `payloads.json` и подключает `src/relapse-payloads.js` в
  `src/main.js`. После того как на приставке поднимется `elfldr` на порту 9021,
  она сама отправит эти файлы по порядку.

Отправка в любом случае идёт с приставки в `127.0.0.1:9021` — снаружи пейлоад
отправить нельзя, браузеру доступен только примитив эксплоита.

## etaHEN

`etaHEN-2.5B.bin` в обоих случаях остаётся за бортом: `mapElf()` требует
ELF-заголовок (`0x464c457f`), а etaHEN — сырой бинарник, так что функция
отсеивает его на входе. Пробовали обойти это патчем `kexp.js`, но рендерер на
приставке не переживает такую длинную отправку и роняет страницу.

Рабочий путь — отправка с роутера, автоматически. Сторож `S60relapse-etahen`
ждёт, пока приставка поднимет `allinOne` (8080), и скармливает etaHEN в elfldr
на 9021, если тот ещё не запущен (1337 закрыт). Через ~10 секунд после R2
etaHEN поднимается сам. Адрес приставки лежит в `/storage/www/relapse/ps5.conf`.

Отключить сторож при установке — `--no-etahen-watch`. Тогда вручную:

```bash
ssh -p 222 root@192.168.1.1 \
  '/storage/www/relapse/send-payload.sh /storage/www/relapse/payloads/etaHEN-2.5B.bin <IP-PS5>'
```

Лог сторожа на роутере: `/tmp/relapse-etahen.log`.

## Что положить

| Файл | Зачем | Порядок |
| --- | --- | --- |
| `pldmgr.elf` | Payload Manager | 1 |
| `allinOne.elf` | всё-в-одном от Akela-1979 | 2 |
| `kstuff.elf` | ядерный эксплоит kstuff (sleirsgoevy, Echo Stretch) | 3 |
| `etaHEN-*.bin` | сам HEN (LightningMods) | 4 |

Обязательны только `pldmgr.elf` и `allinOne.elf` — без них эксплоит работает,
но дополнительных полезностей не будет. `etaHEN` нужен, если хочешь нормальный
homebrew, а не голый доступ к ядру.

## Как положить

```bash
# на своей машине
cp ~/Загрузки/etaHEN-2.5B.bin ~/Загрузки/allinOne.elf payloads/

# проверить, что установщик их увидит
./install.sh --host 192.168.1.1 --password ... --source ...
```

Файлы `*.bin`, `*.elf` и всё прочее добавлены в `.gitignore`, случайно
закоммитить их не получится.

## Если пейлоад лежит уже на роутере

Установщик всё равно может отправить его вручную, компьютер для этого не нужен:

```bash
ssh -p 222 root@192.168.1.1 \
  /storage/www/relapse/send-payload.sh /storage/www/relapse/payloads/etaHEN-2.5B.bin <ip приставки>
```

Вернуть исходный `src/main.js` без автоотправки:

```bash
./install.sh --host 192.168.1.1 --password ... --reset-payload-patch
```

Проверить, что на роутере, и — что важнее — что в `main.js` **нет** хука,
из-за которого пропадает R2:

```bash
ssh -p 222 root@192.168.1.1 "grep -c relapse-payloads /storage/www/relapse/src/main.js"  # 0 = хука нет
ssh -p 222 root@192.168.1.1 "grep -c watchR2 /storage/www/relapse/src/main.js"           # >=1 = R2 есть
ssh -p 222 root@192.168.1.1 "grep -c loadOptionalPayloads /storage/www/relapse/src/kexp.js"
```

Если первый счётчик не ноль, а второй ноль — стоит прогнать установщик с
`--reset-payload-patch`: собственный хук вставляется прямо перед `watchR2()`
и не даёт R2 появиться.

Если `allinOne` поднялся, а порт 1337 закрыт — etaHEN не отправился. Смотри
сторож на роутере:

```bash
ssh -p 222 root@192.168.1.1 "/opt/etc/init.d/S60relapse-etahen status"
ssh -p 222 root@192.168.1.1 "tail -20 /tmp/relapse-etahen.log"
```

Запустить сторож вручную: `/opt/etc/init.d/S60relapse-etahen restart`.
