#!/bin/sh
# Отправка payload на PS5 через elfldr (порт 9021).
#
# usage: send-payload.sh <файл> [ip]
#   send-payload.sh /storage/www/relapse/payloads/etaHEN-2.5B.bin
#   send-payload.sh /storage/www/relapse/payloads/etaHEN-2.5B.bin 192.168.90.68
#
# Работает и на роутере, и на обычном Linux (нужен только nc).

FILE="$1"
IP="${2:-192.168.90.1}"
PORT=9021

[ -n "$FILE" ] || {
    echo "usage: $0 <файл> [ip]"
    echo "пример: $0 /storage/www/relapse/payloads/etaHEN-2.5B.bin 192.168.90.68"
    exit 1
}
[ -f "$FILE" ] || { echo "нет файла: $FILE"; exit 1; }

echo "Отправляю $FILE -> $IP:$PORT"
if nc "$IP" "$PORT" < "$FILE"; then
    echo "OK: отправлено, $(wc -c < "$FILE") байт"
else
    echo "Не получилось. Проверь, что на PS5 в логе есть 'elfldr is listening on port $PORT'"
    exit 1
fi