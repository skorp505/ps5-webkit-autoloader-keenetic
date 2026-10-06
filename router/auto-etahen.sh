#!/bin/sh
# Сторож etaHEN: как только на приставке поднялся allinOne (порт 8080), а etaHEN
# ещё не запущен (порт 1337 закрыт), отправляем etaHEN через elfldr на 9021.
#
# Смысл в том, чтобы не тянуть etaHEN через вебкит: рендерер на приставке
# нестабилен и уже ронял страницу на длинной отправке. Роутер отправляет сам,
# по TCP, и не зависит от того, что происходит в браузере.
#
# usage: auto-etahen.sh <ip приставки> [интервал_сек]

IP="$1"
INTERVAL="${2:-5}"
PORT_ELF=9021        # elfldr: принимает payload
PORT_HOME=8080       # allinOne: поднимается после R2
PORT_ETAHEN=1337     # etaHEN: FTP, работает только если etaHEN загружен

ETAHEN_BIN="${ETAHEN_BIN:-/storage/www/relapse/payloads/etaHEN-2.5B.bin}"
LOG="${LOG:-/tmp/relapse-etahen.log}"
SEND="${SEND:-/storage/www/relapse/send-payload.sh}"

[ -n "$IP" ] || { echo "usage: $0 <ip приставки> [интервал_сек]"; exit 1; }
[ -f "$ETAHEN_BIN" ] || { echo "нет файла etaHEN: $ETAHEN_BIN"; exit 1; }

# Порт открыт, если connect успешен.
#
# Именно без -w: на busybox Entware флаг -w ломает проверку и возвращает код 1
# даже для открытых портов (проверено на 9021/8080). Обычный nc с пустым вводом
# даёт 0 на открытом порту и 1 на закрытом. Флага -z в busybox нет.
port_open() {
    nc "$1" "$2" </dev/null >/dev/null 2>&1
}

log() {
    echo "$(date '+%H:%M:%S') $*" >>"$LOG"
    # лог в tmpfs: держим его маленьким, чтобы не съесть /storage
    if [ -f "$LOG" ] && [ "$(wc -l <"$LOG")" -gt 200 ]; then
        tail -100 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    fi
}

log "сторож запущен для $IP, интервал ${INTERVAL}s"

while :; do
    if ! port_open "$IP" "$PORT_ELF"; then
        # приставка выключена или эксплоит ещё не поднял elfldr
        sleep "$INTERVAL"
        continue
    fi

    if port_open "$IP" "$PORT_ETAHEN"; then
        # etaHEN уже на месте: ждём, пока приставку перезапустят
        sleep "$INTERVAL"
        continue
    fi

    if ! port_open "$IP" "$PORT_HOME"; then
        # elfldr поднялся, но allinOne ещё нет: значит R2 не нажат. etaHEN без
        # allinOne не запустится, ждём.
        sleep "$INTERVAL"
        continue
    fi

    log "allinOne поднят, etaHEN не запущен — отправляю"
    if "$SEND" "$ETAHEN_BIN" "$IP" >>"$LOG" 2>&1; then
        # отправка прошла; проверяем, поднялся ли FTP etaHEN
        n=0
        while [ "$n" -lt 10 ]; do
            if port_open "$IP" "$PORT_ETAHEN"; then
                log "готово: etaHEN загружен (порт $PORT_ETAHEN открыт)"
                break
            fi
            n=$((n + 1))
            sleep 1
        done
        [ "$n" -ge 10 ] && log "отправка прошла, но порт $PORT_ETAHEN не открылся"
    else
        log "отправка не удалась"
    fi

    sleep "$INTERVAL"
done