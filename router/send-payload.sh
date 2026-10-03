#!/bin/sh
# Отправка payload на PS5 через elfldr (порт 9021).
#
# usage: send-payload.sh <файл> <ip приставки>
#   send-payload.sh /storage/www/relapse/payloads/etaHEN-2.5B.bin 192.168.1.100
#
# Работает и на роутере, и на обычном Linux (нужен только nc).

FILE="$1"
IP="$2"
PORT=9021

[ -n "$FILE" ] && [ -n "$IP" ] || {
    echo "usage: $0 <файл> <ip приставки>"
    echo "пример: $0 /storage/www/relapse/payloads/etaHEN-2.5B.bin 192.168.1.100"
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