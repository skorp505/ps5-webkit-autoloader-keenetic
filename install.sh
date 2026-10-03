#!/usr/bin/env bash
#
# Установщик Relapse-эксплоита на роутер Keenetic.
# Всё ставится и раздаётся самим роутером: компьютер нужен только на время установки.
#
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# ---------------------------------------------------------------- параметры --
ROUTER_HOST="${ROUTER_HOST:-192.168.1.1}"
ROUTER_USER="root"
ROUTER_PORT="222"
ROUTER_PASSWORD="${KEENETIC_PASSWORD:-}"
LAN_IP=""
ADMIN_SSL_PORT="8444"
DOC_ROOT="/storage/www/relapse"
CONF="/storage/www/relapse-nginx.conf"
CERT_DIR="/storage/www/cert"
HOSTNAME_SSL="manuals.playstation.net"
UPSTREAM="https://codeload.github.com/ntfargo/Relapse-Exploit/tar.gz/refs/heads/main"
LOCAL_SOURCE=""
ASSUME_YES=0
UNINSTALL=0
RESET_PAYLOAD_PATCH=0

EXTRA_PORTS=(8443 8888)

usage() {
    cat <<'EOF'
install.sh — установка Relapse-эксплоита на роутер Keenetic

Использование:
  ./install.sh [опции]

Опции:
  --host ADDR           адрес роутера в локальной сети (по умолчанию 192.168.1.1)
  --port PORT           порт SSH Entware (по умолчанию 222)
  --user USER           пользователь SSH (по умолчанию root)
  --password PASS       пароль роутера; можно вместо этого задать KEENETIC_PASSWORD
  --ip ADR              адрес LAN-интерфейса роутера (по умолчанию определяется автоматически)
  --source PATH         локальная копия Relapse-Exploit вместо загрузки с GitHub
  --upstream URL        другой источник Relapse (tar.gz)
  --admin-ssl-port N    порт HTTPS веб-интерфейса роутера (по умолчанию 8444, 443 освобождается под эксплоит)
  --no-port-change      не менять порт HTTPS веб-интерфейса (тогда эксплоит не встанет на 443)
  --reset-payload-patch вернуть оригинальный src/main.js без автоотправки пейлоадов
  --uninstall           снести установку
  -y, --yes             отвечать да на все вопросы
  -h, --help            эта справка

Примеры:
  ./install.sh --password keenetic
  KEENETIC_PASSWORD=keenetic ./install.sh
  ./install.sh --host 192.168.1.1 --password keenetic --source ./Relapse-Exploit
EOF
}

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mВНИМАНИЕ:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mОШИБКА:\033[0m %s\n' "$*" >&2; exit 1; }

ask() {
    if [ "$ASSUME_YES" = "1" ]; then
        return 0
    fi
    printf '%s [y/N] ' "$1"
    read -r answer
    case "$answer" in
        y|Y|yes|YES|Да|да) return 0 ;;
        *) return 1 ;;
    esac
}

while [ $# -gt 0 ]; do
    case "$1" in
        --host) ROUTER_HOST="$2"; shift 2 ;;
        --port) ROUTER_PORT="$2"; shift 2 ;;
        --user) ROUTER_USER="$2"; shift 2 ;;
        --password) ROUTER_PASSWORD="$2"; shift 2 ;;
        --ip) LAN_IP="$2"; shift 2 ;;
        --source) LOCAL_SOURCE="$2"; shift 2 ;;
        --upstream) UPSTREAM="$2"; shift 2 ;;
        --admin-ssl-port) ADMIN_SSL_PORT="$2"; shift 2 ;;
        --no-port-change) ADMIN_SSL_PORT=""; shift ;;
        --reset-payload-patch) RESET_PAYLOAD_PATCH=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "неизвестный аргумент: $1 (см. --help)" ;;
    esac
done

# --------------------------------------------------------------- окружение --
WORKDIR=""
cleanup() { [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

need() {
    command -v "$1" >/dev/null 2>&1 || die "не найдена утилита: $1"
}

if [ "$UNINSTALL" = "1" ]; then
    [ -n "$ROUTER_HOST" ] || die "укажите --host"
    need ssh
    need scp
else
    need ssh
    need scp
    need curl
    need tar
    need openssl
fi

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=10"

# ------------------------------------------------------------------ SSH ------
if [ -n "$ROUTER_PASSWORD" ]; then
    if command -v sshpass >/dev/null 2>&1; then
        RUN_SSH() { sshpass -p "$ROUTER_PASSWORD" ssh $SSH_OPTS -p "$ROUTER_PORT" "$ROUTER_USER@$ROUTER_HOST" "$@"; }
        RUN_SCP() { sshpass -p "$ROUTER_PASSWORD" scp $SSH_OPTS -O -P "$ROUTER_PORT" "$@"; }
    else
        warn "sshpass не установлен, пробую вход без пароля (ключ/агент)"
        RUN_SSH() { ssh $SSH_OPTS -p "$ROUTER_PORT" "$ROUTER_USER@$ROUTER_HOST" "$@"; }
        RUN_SCP() { scp $SSH_OPTS -O -P "$ROUTER_PORT" "$@"; }
    fi
else
    RUN_SSH() { ssh $SSH_OPTS -p "$ROUTER_PORT" "$ROUTER_USER@$ROUTER_HOST" "$@"; }
    RUN_SCP() { scp $SSH_OPTS -O -P "$ROUTER_PORT" "$@"; }
fi

router_cmd() { RUN_SSH "$*"; }

# ------------------------------------------------------------- предиагностика
detect_router() {
    log "проверяю роутер $ROUTER_HOST:$ROUTER_PORT"
    local model
    model=$(router_cmd "cat /proc/device-tree/model 2>/dev/null || uname -m" 2>/dev/null | tr -d '\r\000' | tail -1) \
        || die "не удалось подключиться по SSH. Проверь адрес, порт и пароль."
    log "модель: $model"

    if ! router_cmd "test -x /bin/ndmc" 2>/dev/null; then
        die "нет Entware (/bin/ndmc). На Keenetic включи: Веб-интерфейс → Общие настройки → Компоненты → Entware"
    fi
    if ! router_cmd "test -x /usr/sbin/nginx" 2>/dev/null; then
        die "на роутере нет /usr/sbin/nginx — неподдерживаемая прошивка"
    fi
    local free
    free=$(router_cmd "df -k /storage | tail -1 | awk '{print \$4}'" | tr -d '\r')
    log "свободно на /storage: $((free / 1024)) МБ"
    # ~0.6 МБ на сайт и сертификат, до ~14 МБ если кладутся пейлоады
    if [ "${free:-0}" -lt 12288 ]; then
        warn "мало места на /storage: нужно ~14 МБ с пейлоадами или ~1 МБ без них"
    fi
}

detect_lan_ip() {
    if [ -n "$LAN_IP" ]; then
        log "адрес LAN задан: $LAN_IP"
        return 0
    fi
    log "определяю адрес LAN-интерфейса роутера"
    local ip
    ip=$(router_cmd "/bin/ndmc -c 'show running-config' 2>/dev/null | tr -d '\r' | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | awk '/^interface Bridge0\$/ {f=1} f && /^ *ip address/ {print \$3; exit}'" | tr -d '\r' | tail -1)
    if [ -z "$ip" ]; then
        ip=$(router_cmd "/bin/ndmc -c 'show running-config' 2>/dev/null | tr -d '\r' | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | grep -oE 'ip address [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 | awk '{print \$3}'" | tr -d '\r' | tail -1)
    fi
    [ -n "$ip" ] || die "не удалось определить адрес LAN, укажи его через --ip"
    LAN_IP="$ip"
    log "адрес LAN: $LAN_IP"
}

# ---------------------------------------------------------------- источник --
fetch_relapse() {
    if [ -n "$LOCAL_SOURCE" ]; then
        log "использую локальную копию: $LOCAL_SOURCE"
        [ -f "$LOCAL_SOURCE/index.html" ] || die "в $LOCAL_SOURCE нет index.html — это не копия Relapse-Exploit"
        cp -R "$LOCAL_SOURCE"/index.html "$LOCAL_SOURCE"/src "$LOCAL_SOURCE"/offsets "$WORKDIR/site/" 2>/dev/null \
            || cp -R "$LOCAL_SOURCE"/* "$WORKDIR/site/"
        return 0
    fi
    log "скачиваю Relapse-Exploit"
    mkdir -p "$WORKDIR/dl"
    if ! curl -fsSL "$UPSTREAM" -o "$WORKDIR/dl/relapse.tar.gz"; then
        die "не скачался $UPSTREAM. Проверь интернет или укажи --source"
    fi
    tar xzf "$WORKDIR/dl/relapse.tar.gz" -C "$WORKDIR/dl"
    local root
    root=$(find "$WORKDIR/dl" -maxdepth 1 -mindepth 1 -type d | head -1)
    [ -n "$root" ] || die "пустой архив"
    [ -f "$root/index.html" ] || die "в архиве нет index.html — это не Relapse-Exploit"
    mkdir -p "$WORKDIR/site"
    cp -R "$root/index.html" "$root/src" "$root/offsets" "$WORKDIR/site/"
    log "скачано: $(du -sh "$WORKDIR/site" | cut -f1)"
}

# ------------------------------------------------- автоотправка пейлоадов ----
# Relapse сам пейлоады больше не шлёт (функцию loadOptionalPayloads убрали из
# kexp.js), поэтому подключаем свой модуль: он берёт список из payloads.json и
# после строки про "elfldr is listening on port 9021" отправляет их с приставки.
HOOK_MARKER="relapse-payloads"
ANCHOR="elfldr is listening on port 9021"

patch_payloads() {
    local mainjs="$WORKDIR/site/src/main.js"

    [ -f "$mainjs" ] || die "нет $mainjs — структура Relapse изменилась"

    # всегда кладём модуль, даже если список пуст: страница сможет отдать его сам
    cp "$SCRIPT_DIR/router/relapse-payloads.js" "$WORKDIR/site/src/relapse-payloads.js"

    if [ "$RESET_PAYLOAD_PATCH" = "1" ]; then
        log "возвращаю main.js без автоотправки пейлоадов"
        rm -f "$WORKDIR/site/payloads.json" "$WORKDIR/site/src/relapse-payloads.js"
        strip_hook "$mainjs"
        return 0
    fi

    if [ "${#PAYLOAD_ORDER[@]}" -eq 0 ]; then
        log "своих пейлоадов нет — payloads.json будет пустым"
    else
        log "список пейлоадов: ${PAYLOAD_ORDER[*]}"
    fi
    {
        printf '['
        local first=1 name
        for name in "${PAYLOAD_ORDER[@]:-}"; do
            [ -n "$name" ] || continue
            if [ "$first" = "1" ]; then first=0; else printf ','; fi
            printf '"%s"' "$name"
        done
        printf ']\n'
    } > "$WORKDIR/site/payloads.json"
    log "payloads.json: $(cat "$WORKDIR/site/payloads.json")"

    add_hook "$mainjs"
}

strip_hook() {
    local file="$1"
    grep -v "$HOOK_MARKER" "$file" > "$file.new" || return 0
    mv "$file.new" "$file"
}

add_hook() {
    local file="$1"
    local anchor_lines
    anchor_lines=$(grep -n "$ANCHOR" "$file" || true)
    if [ -z "$anchor_lines" ]; then
        warn "в main.js нет строки \"$ANCHOR\" — автоотправка пейлоадов не подключена"
        warn "отправляй вручную: send-payload.sh на роутере"
        return 0
    fi
    if grep -q "$HOOK_MARKER" "$file"; then
        log "хук автоотправки уже есть, обновляю"
        strip_hook "$file"
    fi

    log "подключаю автоотправку пейлоадов в main.js"
    awk -v anchor="$ANCHOR" '
        index($0, anchor) && !done {
            print
            print "    try {"
            print "      const mod = await import(\"./relapse-payloads.js\");"
            print "      await mod.sendPayloads(p, chain, log);"
            print "    } catch (error) {"
            print "      log(\"payloads: \" + (error && error.message ? error.message : error), \"error\");"
            print "    }"
            done = 1
            next
        }
        { print }
    ' "$file" > "$file.new"

    if ! grep -q "$HOOK_MARKER" "$file.new"; then
        rm -f "$file.new"
        die "хук не вставился, main.js не тронут"
    fi
    mv "$file.new" "$file"
}

collect_payloads() {
    PAYLOAD_ORDER=()
    [ -d "$SCRIPT_DIR/payloads" ] || return 0
    local f base found g
    # порядок важен: менеджер пейлоадов, потом «всё сразу», потом ядро, потом HEN
    for base in pldmgr.elf allinOne.elf kstuff.elf; do
        f="$SCRIPT_DIR/payloads/$base"
        if [ -f "$f" ]; then
            PAYLOAD_ORDER+=("$base")
        fi
    done
    for f in "$SCRIPT_DIR/payloads"/etaHEN*.bin; do
        if [ -f "$f" ]; then
            PAYLOAD_ORDER+=("$(basename "$f")")
        fi
    done
    for f in "$SCRIPT_DIR/payloads"/*.elf "$SCRIPT_DIR/payloads"/*.bin; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        found=0
        for g in "${PAYLOAD_ORDER[@]:-}"; do
            [ "$g" = "$base" ] && found=1
        done
        if [ "$found" = "0" ]; then
            PAYLOAD_ORDER+=("$base")
        fi
    done
}

# --------------------------------------------------------------- nginx -------
render_conf() {
    log "готовлю конфиг nginx"
    local template="$SCRIPT_DIR/router/relapse-nginx.conf.tmpl"
    [ -f "$template" ] || die "нет шаблона $template"
    sed -e "s|@LAN_IP@|$LAN_IP|g" \
        -e "s|@DOC_ROOT@|$DOC_ROOT|g" \
        -e "s|@CONF@|$CONF|g" \
        -e "s|@CERT@|$CERT_DIR/cert.pem|g" \
        -e "s|@CERT_KEY@|$CERT_DIR/key.pem|g" \
        -e "s|@EXTRA_PORT@|${EXTRA_PORTS[0]}|g" \
        -e "s|@HTTP_PORT@|${EXTRA_PORTS[1]}|g" \
        -e "s|@HOSTNAME@|$HOSTNAME_SSL|g" \
        "$template" > "$WORKDIR/relapse-nginx.conf"
}

gen_cert() {
    log "генерирую самоподписанный сертификат для $HOSTNAME_SSL"
    mkdir -p "$WORKDIR/cert"
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
        -keyout "$WORKDIR/cert/key.pem" -out "$WORKDIR/cert/cert.pem" \
        -subj "/CN=$HOSTNAME_SSL" \
        -addext "subjectAltName=DNS:$HOSTNAME_SSL" 2>/dev/null
}

# ------------------------------------------------------------- установка -----
upload_tree() {
    log "загружаю файлы на роутер (это может занять минуту)"
    RUN_SSH "mkdir -p $DOC_ROOT $CERT_DIR /storage/www"
    tar czf - -C "$WORKDIR/site" . | RUN_SSH "tar xzf - -C $DOC_ROOT"
    if [ "${#PAYLOAD_ORDER[@]}" -gt 0 ]; then
        log "загружаю пейлоады: ${PAYLOAD_ORDER[*]}"
        RUN_SSH "mkdir -p $DOC_ROOT/payloads"
        for f in "${PAYLOAD_ORDER[@]}"; do
            if [ -f "$SCRIPT_DIR/payloads/$f" ]; then
                log "  $f ($(du -h "$SCRIPT_DIR/payloads/$f" | cut -f1))"
                RUN_SCP "$SCRIPT_DIR/payloads/$f" "$ROUTER_USER@$ROUTER_HOST:$DOC_ROOT/payloads/$f"
            fi
        done
    fi
}

configure_router() {
    log "настраиваю DNS и порты роутера"
    router_cmd "/bin/ndmc -c 'ip host $HOSTNAME_SSL $LAN_IP'" >/dev/null
    if [ -n "$ADMIN_SSL_PORT" ]; then
        log "переношу HTTPS веб-интерфейса роутера на $ADMIN_SSL_PORT, освобождая 443"
        warn "веб-интерфейс будет доступен на http://$LAN_IP/ и https://$LAN_IP:$ADMIN_SSL_PORT/"
        router_cmd "/bin/ndmc -c 'ip http ssl port $ADMIN_SSL_PORT'" | tr -d '\r' | tail -1
    else
        warn "порт 443 не освобождается, эксплоит на нём не запустится"
    fi
    router_cmd "/bin/ndmc -c 'system configuration save'" | tr -d '\r' | tail -1
    log "сохраняю init-скрипт и включаю автозапуск"
    RUN_SCP "$SCRIPT_DIR/router/S50relapse-nginx" "$ROUTER_USER@$ROUTER_HOST:/opt/etc/init.d/S50relapse-nginx"
    router_cmd "chmod +x /opt/etc/init.d/S50relapse-nginx"
}

start_service() {
    log "перезапускаю nginx"
    router_cmd "/opt/etc/init.d/S50relapse-nginx restart" | tr -d '\r' | tail -2
    sleep 1
    router_cmd "/opt/etc/init.d/S50relapse-nginx status" | tr -d '\r' | tail -1
    router_cmd "grep -q 'rc.unslung' /opt/etc/init.d/S50relapse-nginx 2>/dev/null || true"
}

verify() {
    log "проверяю доступность"
    local code admin dns_ip
    code=$(curl -sk -o /dev/null -w '%{http_code}' \
        --resolve "$HOSTNAME_SSL:443:$LAN_IP" "https://$HOSTNAME_SSL/" || true)
    admin=$(curl -s -o /dev/null -w '%{http_code}' "http://$LAN_IP/" || true)
    dns_ip=$(dig +short "@$LAN_IP" "$HOSTNAME_SSL" 2>/dev/null | head -1 || true)
    [ -n "$dns_ip" ] || dns_ip="не найдено"
    echo
    printf '  DNS   %s -> %s\n' "$HOSTNAME_SSL" "$dns_ip"
    printf '  443   %s на https: HTTP %s\n' "$HOSTNAME_SSL" "${code:-000}"
    printf '  панель роутера на http://%s/: HTTP %s\n' "$LAN_IP" "${admin:-000}"
    if [ -n "$ADMIN_SSL_PORT" ]; then
        printf '  HTTPS панели перенесён на %s (обычно не поднимается, это норма)\n' "$ADMIN_SSL_PORT"
    fi
    echo
    if [ "$code" != "200" ]; then
        warn "эксплоит на 443 не отвечает. Смотри логи:"
        warn "  ssh -p $ROUTER_PORT $ROUTER_USER@$ROUTER_HOST 'tail -20 /tmp/relapse-nginx/error.log'"
        exit 1
    fi
    cat <<EOF

Готово. Дальше на PS5:
  1. Настройки → Сеть → Настройки → DNS вручную → $LAN_IP
  2. Настройки → Руководство пользователя → Да → выбрать PS5 → пункт с браузером
  3. На предупреждение о сертификате нажать «Да»
  4. Дождаться в логе на экране:
       [+] elfldr is listening on port 9021
$( [ "${#PAYLOAD_ORDER[@]}" -gt 0 ] && printf '       [+] %s sent\n' "${PAYLOAD_ORDER[@]}" )
EOF
    if [ "${#PAYLOAD_ORDER[@]}" -gt 0 ]; then
        cat <<EOF
  Пейлоады отправятся сами с приставки — компьютер больше не нужен.
  Если понадобится отправить что-то ещё вручную:
    ssh -p $ROUTER_PORT $ROUTER_USER@$ROUTER_HOST "$DOC_ROOT/send-payload.sh $DOC_ROOT/payloads/<файл> <ip приставки>"
EOF
    fi
}

uninstall() {
    warn "буду сносить установку на $ROUTER_HOST"
    ask "продолжить?" || { log "отменено"; exit 0; }
    log "останавливаю nginx"
    router_cmd "/opt/etc/init.d/S50relapse-nginx stop" >/dev/null 2>&1 || true
    log "удаляю файлы"
    router_cmd "rm -rf $DOC_ROOT $CERT_DIR $CONF /opt/etc/init.d/S50relapse-nginx"
    log "возвращаю HTTPS веб-интерфейса на 443"
    router_cmd "/bin/ndmc -c 'ip http ssl port 443'" >/dev/null 2>&1 || true
    log "удаляю DNS-запись"
    router_cmd "/bin/ndmc -c 'no ip host $HOSTNAME_SSL'" >/dev/null 2>&1 || true
    router_cmd "/bin/ndmc -c 'system configuration save'" >/dev/null 2>&1 || true
    log "готово"
}

# ------------------------------------------------------------------ main -----
main() {
    if [ "$UNINSTALL" = "1" ]; then
        detect_router
        uninstall
        return 0
    fi

    [ -n "$ROUTER_HOST" ] || { usage; die "укажите --host"; }

    detect_router
    detect_lan_ip

    echo
    warn "будет изменено на роутере $ROUTER_HOST:"
    printf '  * DNS-запись %s -> %s\n' "$HOSTNAME_SSL" "$LAN_IP"
    if [ -n "$ADMIN_SSL_PORT" ]; then
        printf '  * HTTPS веб-интерфейса переносится с 443 на %s\n' "$ADMIN_SSL_PORT"
    fi
    printf '  * файлы в %s и /storage/www/cert\n' "$DOC_ROOT"
    printf '  * автозапуск /opt/etc/init.d/S50relapse-nginx\n'
    printf '  * настройки сохраняются в конфиг роутера\n'
    echo
    ask "установить?" || { log "отменено"; exit 0; }

    WORKDIR=$(mktemp -d)
    mkdir -p "$WORKDIR/site"

    fetch_relapse
    collect_payloads
    patch_payloads
    gen_cert
    render_conf

    upload_tree
    RUN_SCP "$WORKDIR/relapse-nginx.conf" "$ROUTER_USER@$ROUTER_HOST:$CONF"
    RUN_SCP "$WORKDIR/cert/cert.pem" "$ROUTER_USER@$ROUTER_HOST:$CERT_DIR/cert.pem"
    RUN_SCP "$WORKDIR/cert/key.pem" "$ROUTER_USER@$ROUTER_HOST:$CERT_DIR/key.pem"
    router_cmd "chmod 600 $CERT_DIR/key.pem"
    RUN_SCP "$SCRIPT_DIR/router/send-payload.sh" "$ROUTER_USER@$ROUTER_HOST:$DOC_ROOT/send-payload.sh"
    router_cmd "chmod +x $DOC_ROOT/send-payload.sh"

    configure_router
    start_service
    verify
}

# Скрипт можно подключить (source), не выполняя установку — удобно для тестов
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi