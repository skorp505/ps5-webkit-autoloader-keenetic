# Разбор проблем

Сначала три команды, они покрывают большинство случаев:

```bash
dig +short @192.168.90.1 manuals.playstation.net
curl -sk -o /dev/null -w '%{http_code}\n' --resolve manuals.playstation.net:443:192.168.90.1 https://manuals.playstation.net/
ssh -p 222 root@192.168.90.1 '/opt/etc/init.d/S50relapse-nginx status; tail -20 /storage/www/relapse-access.log'
```

Ожидаемо: `192.168.90.1`, `200`, `relapse nginx running`.

## Руководство открывается, но страница чёрная

Смотри access-лог. Если все запросы возвращают один и тот же размер около 550 байт
вместо размеров скриптов — приставка получает HTML-заглушку вместо JS.

Причина обычно в пропавших `alias` для `/document/ru/ps5/` и `/document/en/ps5/`
в `/storage/www/relapse-nginx.conf`. Проверить:

```bash
ssh -p 222 root@192.168.90.1 "grep -A2 'document/ru' /storage/www/relapse-nginx.conf"
```

Бывает и обратное: в конфиге осталась заглушка `try_files $uri $uri/ /index.html`
— она тоже ломает страницу, отдавая HTML на запросы `.js`. Её быть не должно.

## Вместо страницы ошибка про сертификат

Это нормально: сертификат самоподписанный, приставка спрашивает подтверждение.
Надо нажать **Да**.

Если после подтверждения страница не открывается вообще — скорее всего, запрос
не доходит. Проверь, что DNS отдаёт нужный IP и что 443 занят нашим nginx:

```bash
ssh -p 222 root@192.168.90.1 "netstat -ltnp | grep relapse-nginx"
```

Ожидаются три строки: `192.168.90.1:443`, `:8443`, `:8888`.

## Порт 443 занят, nginx не стартует

В `error.log` будет `bind() to ...:443 failed (98: Address in use)` — значит
HTTPS веб-интерфейса роутера не переехал. Проверить и починить:

```bash
ssh -p 222 root@192.168.90.1 "/bin/ndmc -c 'show running-config' | grep 'ip http'"
ssh -p 222 root@192.168.90.1 "/bin/ndmc -c 'ip http ssl port 8444'"
ssh -p 222 root@192.168.90.1 "/opt/etc/init.d/S50relapse-nginx restart"
```

## DNS отдаёт публичный адрес вместо роутера

Приставка могла закешировать старую запись, либо в настройках PS5 стоит чужой DNS.

```bash
# на компьютере в той же сети
dig +short @192.168.90.1 manuals.playstation.net
```

Если ответ верный, а приставка всё равно идёт по старому адресу — перезагрузи
приставку или переключи сеть Wi-Fi, чтобы сбросить кэш DNS.

## Пейлоады не отправляются

Смотри строку в логе на экране приставки:

```
[+] elfldr is listening on port 9021
[+] pldmgr.elf sent
[+] allinOne.elf sent
```

Если 9021 не поднялся — не отправятся никакие. Вебкит-стадия нестабильна по
своей природе, страницу можно просто перезагрузить и попробовать снова.

Если `elfldr` есть, а отправки нет, проверь, что файлы на роутере, список
пейлоадов непустой и хук на месте:

```bash
ssh -p 222 root@192.168.90.1 "ls -l /storage/www/relapse/payloads"
ssh -p 222 root@192.168.90.1 "cat /storage/www/relapse/payloads.json"
ssh -p 222 root@192.168.90.1 "ls -l /storage/www/relapse/src/relapse-payloads.js"
ssh -p 222 root@192.168.90.1 "grep -c relapse-payloads /storage/www/relapse/src/main.js"
```

В access-логе должен быть запрос `GET /document/ru/ps5/payloads/<файл>`. Если его
нет — приставка не дошла до отправки, смотри предыдущий пункт. Если запрос есть,
а в логе на экране ошибка —通常是 payload повреждён или не ELF.

Вернуть исходный `main.js` и поставить заново с пейлоадами:

```bash
./install.sh --host 192.168.90.1 --password <пароль> --reset-payload-patch
```

Отправить вручную с роутера:

```bash
ssh -p 222 root@192.168.90.1 \
  /storage/www/relapse/send-payload.sh /storage/www/relapse/payloads/etaHEN-2.5B.bin
```

## Приставка не отвечает на ping

Обычно это нормально: приставка может не отвечать на ICMP, и роутер, и компьютер
увидят `100% packet loss`. На работоспособность не влияет — проверяй не ping'ом,
а портом 9021 и access-логом.

## После перезагрузки роутера всё пропало

Проверь автозапуск:

```bash
ssh -p 222 root@192.168.90.1 "ls -l /opt/etc/init.d/S50relapse-nginx"
ssh -p 222 root@192.168.90.1 "/opt/etc/init.d/S50relapse-nginx status"
```

Если скрипта нет — залей его заново установщиком. Если скрипт есть, но не
запускается, проверь, что в нём есть вызов `rc.unslung` (Entware так ищет
`/opt/etc/init.d/S*`).

Также стоит убедиться, что настройки сохранились в конфиге роутера: если 443
снова занят панелью, значит `system configuration save` не отработал.

```bash
ssh -p 222 root@192.168.90.1 "/bin/ndmc -c 'show running-config' | grep -E 'ip host|ip http'"
ssh -p 222 root@192.168.90.1 "/bin/ndmc -c 'system configuration save'"
```

## Мало места на /storage

```bash
ssh -p 222 root@192.168.90.1 "df -h /storage; du -sh /storage/www/*"
```

Установщику нужно ~20 МБ. Если места нет, удалите лишнее или подключите
внешний накопитель и перенесите `/storage/www` на него, поправив `root` в
`/storage/www/relapse-nginx.conf`.

## Полный сброс

```bash
./install.sh --host 192.168.90.1 --password <пароль> --uninstall
./install.sh --host 192.168.90.1 --password <пароль>
```