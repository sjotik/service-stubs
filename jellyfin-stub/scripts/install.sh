#!/usr/bin/env bash
# =====================================================================
#  Установка Jellyfin-заглушки на сервер с nginx (Debian/Ubuntu layout).
#  Запускать от root на целевом сервере из каталога jellyfin-stub.
#  Поведение снято со снимка эталонного Jellyfin 10.10.7.
#
#  Настройка через переменные окружения:
#    DOMAIN       — имя сайта (server_name), напр. media.example.ru   [обязательно]
#    SSL_CERT     — путь к fullchain сертификату   (не нужен при HTTP_ONLY=1)
#    SSL_KEY      — путь к приватному ключу         (не нужен при HTTP_ONLY=1)
#    INSTALL_DIR  — куда положить статику   (по умолчанию /var/www/jellyfin-stub/www)
#    HTTP_ONLY    — 1: обслуживать по обычному HTTP без TLS (для локальных проверок)
#    HTTP_PORT    — порт для HTTP_ONLY (по умолчанию 80)
#    INSTALL_NGINX— 1: если nginx не установлен, поставить его через apt (иначе — стоп)
#    FORCE        — 1: игнорировать обнаруженный конфликт по домену/порту (на свой риск)
#    DISABLE_DEFAULT_SITE — 1: отключить дефолтный сайт nginx (по умолчанию 0)
#    RELOAD_CMD   — команда перезагрузки (по умолчанию systemctl reload nginx)
#
#  Прод (TLS):
#    sudo DOMAIN=media.example.ru \
#         SSL_CERT=/etc/letsencrypt/live/media.example.ru/fullchain.pem \
#         SSL_KEY=/etc/letsencrypt/live/media.example.ru/privkey.pem \
#         bash scripts/install.sh
#  Локально по HTTP:
#    sudo DOMAIN=localhost HTTP_ONLY=1 HTTP_PORT=8080 bash scripts/install.sh
# =====================================================================
set -euo pipefail

usage() { cat <<'USAGE'
Установка Jellyfin-заглушки на nginx. Параметры передаются переменными окружения.

ОБЯЗАТЕЛЬНЫЕ:
  DOMAIN       имя сайта (server_name), напр. example.ru
  SSL_CERT     путь к fullchain-сертификату   (обязателен, кроме HTTP_ONLY=1)
  SSL_KEY      путь к приватному ключу         (обязателен, кроме HTTP_ONLY=1)

НЕОБЯЗАТЕЛЬНЫЕ:
  LISTEN_ADDR  адрес прослушивания, напр. 127.0.0.1 (loopback под фронт-прокси).
               Пусто = все интерфейсы (v4+v6).
  PORT         порт прослушивания. По умолчанию 443 (TLS) или 80 (HTTP_ONLY).
  HTTP_ONLY=1  plain HTTP без TLS (SSL_CERT/SSL_KEY не нужны).
  HTTP_PORT    старый алиас PORT для HTTP_ONLY (по умолчанию 80).
  INSTALL_DIR  куда положить статику (по умолчанию /var/www/jellyfin-stub/www).
  INSTALL_NGINX=1        поставить nginx через apt, если его нет (иначе — стоп).
  FORCE=1               игнорировать конфликт по домену/порту.
  DISABLE_DEFAULT_SITE=1  отключить дефолтный сайт nginx.
  RELOAD_CMD   команда перезагрузки (по умолчанию: systemctl reload nginx).

ПРИМЕРЫ:
  # standalone TLS на :443 (+ редирект с :80)
  sudo DOMAIN=cloud.example.ru SSL_CERT=/…/fullchain.pem SSL_KEY=/…/privkey.pem bash scripts/install.sh
  # за xray (SNI-passthrough): свой серт на loopback-порту
  sudo DOMAIN=cloud.example.ru SSL_CERT=/…/fullchain.pem SSL_KEY=/…/privkey.pem \
       LISTEN_ADDR=127.0.0.1 PORT=8443 bash scripts/install.sh
  # локальный тест без TLS
  sudo DOMAIN=localhost HTTP_ONLY=1 PORT=8080 bash scripts/install.sh
USAGE
}
case "${1:-}" in -h|--help|help) usage; exit 0;; esac

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # каталог jellyfin-stub

DOMAIN="${DOMAIN:-}"
SSL_CERT="${SSL_CERT:-}"
SSL_KEY="${SSL_KEY:-}"
INSTALL_DIR="${INSTALL_DIR:-/var/www/jellyfin-stub/www}"
NGINX_ETC="${NGINX_ETC:-/etc/nginx}"
HTTP_ONLY="${HTTP_ONLY:-0}"
HTTP_PORT="${HTTP_PORT:-80}"
LISTEN_ADDR="${LISTEN_ADDR:-}"   # адрес прослушивания в HTTP_ONLY: напр. 127.0.0.1 (loopback); пусто=все интерфейсы
INSTALL_NGINX="${INSTALL_NGINX:-0}"
FORCE="${FORCE:-0}"
DISABLE_DEFAULT_SITE="${DISABLE_DEFAULT_SITE:-0}"
RELOAD_CMD="${RELOAD_CMD:-systemctl reload nginx}"
CONF_NAME="jellyfin-stub.conf"

die(){ echo "ОШИБКА: $*" >&2; exit 1; }
info(){ echo ">>> $*"; }
esc(){ printf '%s' "$1" | sed 's/[&/\]/\\&/g'; }   # экранирование для sed-замены

# ---------- preflight ----------
[ "$(id -u)" = "0" ] || die "запустите от root (sudo)"
[ -n "$DOMAIN" ] || die "не задан DOMAIN (напр. DOMAIN=media.example.ru)"
[ -d "$SRC/www" ] && [ -f "$SRC/nginx/$CONF_NAME" ] \
    || die "каталог jellyfin-stub повреждён: нет www/ или nginx/$CONF_NAME"

# ---------- nginx: наличие / установка ----------
if ! command -v nginx >/dev/null 2>&1; then
    if [ "$INSTALL_NGINX" = "1" ]; then
        info "nginx не найден — устанавливаю (apt)"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y && apt-get install -y nginx
        else
            die "apt-get не найден — установите nginx вручную и повторите"
        fi
    else
        die "nginx не установлен. Установите его (apt install nginx) и повторите, либо запустите с INSTALL_NGINX=1"
    fi
fi
command -v nginx >/dev/null 2>&1 || die "nginx так и не доступен после установки"

# утилиты
MISSING=""
for c in sed find xargs cp ln; do command -v "$c" >/dev/null 2>&1 || MISSING="$MISSING $c"; done
[ -z "$MISSING" ] || die "не хватает утилит:$MISSING"

# текущий конфиг рабочий?
nginx -t >/dev/null 2>&1 || echo "ВНИМАНИЕ: текущий 'nginx -t' уже возвращает ошибку — проверьте существующий конфиг"

# TLS: сертификат и ключ
if [ "$HTTP_ONLY" != "1" ]; then
    [ -n "$SSL_CERT" ] || die "не задан SSL_CERT (путь к fullchain), либо HTTP_ONLY=1 для локального теста"
    [ -n "$SSL_KEY" ]  || die "не задан SSL_KEY (путь к приватному ключу)"
    { [ -f "$SSL_CERT" ] && [ -f "$SSL_KEY" ]; } || die "сертификат/ключ не найдены: SSL_CERT=$SSL_CERT SSL_KEY=$SSL_KEY"
fi

# режим/порт/ssl: TLS -> :443 ssl (дефолт); HTTP_ONLY -> :80 без ssl.
# PORT задаёт порт прослушивания; HTTP_PORT — старый алиас (только HTTP_ONLY).
# LISTEN_ADDR (напр. 127.0.0.1) -> слушать только этот адрес (loopback под фронт-прокси/xray),
# пусто -> все интерфейсы (v4+v6).
LOC_SNIPPET="jfstub_locations.conf"
MAPS_SNIPPET="jfstub_maps.conf"
if [ "$HTTP_ONLY" = "1" ]; then
    LISTEN_PORT="${PORT:-${HTTP_PORT:-80}}"; SSL_SFX=""
else
    LISTEN_PORT="${PORT:-443}"; SSL_SFX=" ssl"
fi
if [ -n "$LISTEN_ADDR" ]; then
    LISTEN_DIRECTIVES="    listen ${LISTEN_ADDR}:${LISTEN_PORT}${SSL_SFX};"
else
    LISTEN_DIRECTIVES="    listen ${LISTEN_PORT}${SSL_SFX};
    listen [::]:${LISTEN_PORT}${SSL_SFX};"
fi

# ---------- проверка конфликтов по домену/порту (до записи конфига) ----------
# Ищем server_name == DOMAIN в чужих активных конфигах (свой — по имени файла — пропускаем).
CONFLICTS="$(nginx -T 2>/dev/null | awk -v d="$DOMAIN" -v self="$CONF_NAME" '
    /^# configuration file / { f=$4; sub(/:$/,"",f); next }
    /^[[:space:]]*server_name[[:space:]]/ {
        line=$0; gsub(/;/,"",line);
        for (i=2;i<=NF;i++) if ($i==d && f !~ self) { print f; break }
    }' | sort -u || true)"
if [ -n "$CONFLICTS" ]; then
    echo "ВНИМАНИЕ: домен '$DOMAIN' уже используется как server_name в:"
    echo "$CONFLICTS" | sed 's/^/    /'
    [ "$FORCE" = "1" ] || die "конфликт конфигурации. Смените DOMAIN/порт, уберите чужой server-блок, или запустите с FORCE=1 (на свой риск). Чужие конфиги не трогаю."
    echo "    FORCE=1 — продолжаю, несмотря на конфликт."
fi

# ---------- 1. статика ----------
info "копирую статику в $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp -a "$SRC/www/." "$INSTALL_DIR/"

# ---------- 2. сниппеты ----------
info "устанавливаю сниппеты в $NGINX_ETC/snippets"
mkdir -p "$NGINX_ETC/snippets"
cp "$SRC"/nginx/snippets/*.conf "$NGINX_ETC/snippets/"
sed -i "s/JFSTUB_ROOT/$(esc "$INSTALL_DIR")/g" "$NGINX_ETC/snippets/jfstub_locations.conf"

# ---------- 3. конфиг сайта ----------
CONF_OUT="$NGINX_ETC/sites-available/$CONF_NAME"
if [ ! -d "$NGINX_ETC/sites-available" ]; then
    CONF_OUT="$NGINX_ETC/conf.d/$CONF_NAME"
    mkdir -p "$NGINX_ETC/conf.d"
fi
info "пишу конфиг сайта: $CONF_OUT (listen ${LISTEN_ADDR:+$LISTEN_ADDR:}${LISTEN_PORT}${SSL_SFX})"
: > "$CONF_OUT"
[ -n "$MAPS_SNIPPET" ] && echo "include snippets/$MAPS_SNIPPET;" >> "$CONF_OUT"
# HTTP->HTTPS редирект на :80 — только для standalone TLS (дефолт 443, все интерфейсы).
if [ "$HTTP_ONLY" != "1" ] && [ -z "$LISTEN_ADDR" ] && [ "$LISTEN_PORT" = "443" ]; then
    cat >> "$CONF_OUT" <<'REDIR'
server {
    listen 80;
    listen [::]:80;
    server_name __REDIR_DOMAIN__;
    server_tokens off;
    return 301 https://$host$request_uri;
}
REDIR
fi
{
    echo "server {"
    printf '%s
' "$LISTEN_DIRECTIVES"
    echo "    server_name $DOMAIN;"
    if [ "$HTTP_ONLY" != "1" ]; then
        echo "    ssl_certificate     $SSL_CERT;"
        echo "    ssl_certificate_key $SSL_KEY;"
        echo "    ssl_protocols TLSv1.2 TLSv1.3;"
    fi
    echo "    include snippets/$LOC_SNIPPET;"
    echo "}"
} >> "$CONF_OUT"
sed -i "s/__REDIR_DOMAIN__/$(esc "$DOMAIN")/" "$CONF_OUT"

# симлинк в sites-enabled (Debian), идемпотентно
if [ -d "$NGINX_ETC/sites-enabled" ]; then
    ln -sf "$CONF_OUT" "$NGINX_ETC/sites-enabled/$CONF_NAME"
fi

# опционально отключить дефолтный сайт
if [ "$DISABLE_DEFAULT_SITE" = "1" ]; then
    for d in "$NGINX_ETC/sites-enabled/default" "$NGINX_ETC/conf.d/default.conf"; do
        [ -e "$d" ] && { rm -f "$d"; info "отключён дефолтный сайт: $d"; }
    done
fi

# ---------- 4. права ----------
if id www-data >/dev/null 2>&1; then chown -R www-data:www-data "$INSTALL_DIR" || true; fi

# ---------- 5. проверка и перезагрузка ----------
info "проверяю конфиг (nginx -t)"
if ! nginx -t; then
    # не оставляем битый сайт включённым
    [ -L "$NGINX_ETC/sites-enabled/$CONF_NAME" ] && rm -f "$NGINX_ETC/sites-enabled/$CONF_NAME"
    # conf.d-layout: файл подключается автоматически — отодвигаем, чтобы nginx снова стал валидным
    BAD="$CONF_OUT"
    case "$CONF_OUT" in */conf.d/*) mv -f "$CONF_OUT" "$CONF_OUT.bad" && BAD="$CONF_OUT.bad";; esac
    die "nginx -t не прошёл — сайт не включён, конфиг сохранён в $BAD для разбора"
fi
info "перезагружаю nginx"
$RELOAD_CMD

SCHEME="https"; [ "$HTTP_ONLY" = "1" ] && SCHEME="http"
PORTSFX=""; { [ "$HTTP_ONLY" = "1" ] && [ "$HTTP_PORT" != "80" ]; } && PORTSFX=":$HTTP_PORT"
echo
info "готово."
echo "    Адрес:    $SCHEME://$DOMAIN$PORTSFX/"
echo "    Статика:  $INSTALL_DIR"
echo "    Конфиг:   $CONF_OUT"
echo "    Проверка: curl -s $SCHEME://$DOMAIN$PORTSFX/System/Info/Public"
