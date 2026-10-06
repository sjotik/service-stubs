#!/usr/bin/env bash
# =====================================================================
#  Установка Nextcloud-заглушки на сервер с nginx (Debian/Ubuntu layout).
#  Запускать от root на целевом сервере из каталога nc-stub.
#
#  Настройка через переменные окружения:
#    DOMAIN      — имя сайта (server_name), напр. cloud.example.ru   [обязательно]
#    SSL_CERT    — путь к fullchain сертификату   (не нужен при HTTP_ONLY=1)
#    SSL_KEY     — путь к приватному ключу         (не нужен при HTTP_ONLY=1)
#    INSTALL_DIR — куда положить статику   (по умолчанию /var/www/nc-stub/www)
#    HTTP_ONLY   — 1: обслуживать по обычному HTTP без TLS (для локальных проверок)
#    HTTP_PORT   — порт для HTTP_ONLY (по умолчанию 80)
#    ENABLE_CRON — 1, чтобы поставить cron автообновления версии (по умолчанию 1)
#    MAJOR_POLICY— same | latest для автообновления (по умолчанию same)
#    CRON_SCHEDULE — расписание cron (по умолчанию "17 4 * * 1" — раз в неделю)
#    DISABLE_DEFAULT_SITE — 1: отключить дефолтный сайт nginx (по умолчанию 0)
#
#  Прод (TLS):
#    sudo DOMAIN=cloud.example.ru \
#         SSL_CERT=/etc/letsencrypt/live/cloud.example.ru/fullchain.pem \
#         SSL_KEY=/etc/letsencrypt/live/cloud.example.ru/privkey.pem \
#         bash scripts/install.sh
#  Локально по HTTP:
#    sudo DOMAIN=localhost HTTP_ONLY=1 HTTP_PORT=8080 ENABLE_CRON=0 bash scripts/install.sh
# =====================================================================
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # каталог nc-stub

DOMAIN="${DOMAIN:-}"
SSL_CERT="${SSL_CERT:-}"
SSL_KEY="${SSL_KEY:-}"
INSTALL_DIR="${INSTALL_DIR:-/var/www/nc-stub/www}"
NGINX_ETC="${NGINX_ETC:-/etc/nginx}"
HTTP_ONLY="${HTTP_ONLY:-0}"
HTTP_PORT="${HTTP_PORT:-80}"
ENABLE_CRON="${ENABLE_CRON:-1}"
MAJOR_POLICY="${MAJOR_POLICY:-same}"
CRON_SCHEDULE="${CRON_SCHEDULE:-17 4 * * 1}"   # раз в неделю (пн 04:17); напр. месяц: "17 4 1 * *"
DISABLE_DEFAULT_SITE="${DISABLE_DEFAULT_SITE:-0}"  # 1 — отключить дефолтный сайт nginx
RELOAD_CMD="${RELOAD_CMD:-systemctl reload nginx}"

die(){ echo "ОШИБКА: $*" >&2; exit 1; }
info(){ echo ">>> $*"; }
esc(){ printf '%s' "$1" | sed 's/[&/\]/\\&/g'; }   # экранирование для sed-замены

# ---------- preflight: окружение ----------
[ "$(id -u)" = "0" ] || die "запустите от root (sudo)"
[ -n "$DOMAIN" ] || die "не задан DOMAIN (напр. DOMAIN=cloud.example.ru)"

# обязательные утилиты
MISSING=""
for c in nginx sed find xargs cp ln head tr; do
    command -v "$c" >/dev/null 2>&1 || MISSING="$MISSING $c"
done
[ -z "$MISSING" ] || die "не хватает утилит:$MISSING — установите их и повторите"

# каталог с исходниками заглушки цел?
[ -d "$SRC/www" ] && [ -f "$SRC/nginx/nextcloud-stub.conf" ] \
    || die "каталог nc-stub повреждён: нет www/ или nginx/nextcloud-stub.conf"

# nginx рабочий?
nginx -t >/dev/null 2>&1 || echo "ВНИМАНИЕ: текущий 'nginx -t' уже возвращает ошибку — проверьте существующий конфиг"

# TLS: сертификат и ключ
if [ "$HTTP_ONLY" != "1" ]; then
    [ -n "$SSL_CERT" ] || die "не задан SSL_CERT (путь к fullchain), либо HTTP_ONLY=1 для локального теста"
    [ -n "$SSL_KEY" ]  || die "не задан SSL_KEY (путь к приватному ключу)"
    if [ ! -f "$SSL_CERT" ] || [ ! -f "$SSL_KEY" ]; then
        echo "Сертификат/ключ не найдены:"
        echo "    SSL_CERT=$SSL_CERT"
        echo "    SSL_KEY=$SSL_KEY"
        if command -v certbot >/dev/null 2>&1; then
            die "получите сертификат, напр.: certbot certonly --nginx -d $DOMAIN"
        else
            die "нет и certbot. Установите (apt install certbot python3-certbot-nginx) и выпустите сертификат, либо укажите существующие пути"
        fi
    fi
fi

# cron автообновления требует python3 (мягкая проверка — не блокирует)
if [ "$ENABLE_CRON" = "1" ] && ! command -v python3 >/dev/null 2>&1; then
    echo "ВНИМАНИЕ: python3 не найден — cron автообновления версии будет пропущен"
fi

# случайное имя сессионной cookie в стиле Nextcloud (oc + 11 символов)
SESSNAME="oc$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'a-z0-9' | head -c 11)"

# ---------- 1. статика ----------
info "копирую статику в $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp -a "$SRC/www/." "$INSTALL_DIR/"

info "подставляю домен ($DOMAIN) в текстовые файлы (NCSTUB_HOST)"
find "$INSTALL_DIR" -type f \( -name '*.html' -o -name '*.json' -o -name '*.css' \
     -o -name '*.js' -o -name '*.svg' -o -name '*.txt' -o -name '*.xml' \) -print0 \
  | xargs -0 sed -i "s/NCSTUB_HOST/$(esc "$DOMAIN")/g"

# ---------- 2. сниппеты (заголовки, maps, CSP, локации) ----------
info "устанавливаю сниппеты в $NGINX_ETC/snippets"
mkdir -p "$NGINX_ETC/snippets"
cp "$SRC"/nginx/snippets/*.conf "$NGINX_ETC/snippets/"
sed -i "s/NCSTUB_SESSNAME/$(esc "$SESSNAME")/g" "$NGINX_ETC/snippets/ncstub_hdr_php.conf"
sed -i "s/NCSTUB_ROOT/$(esc "$INSTALL_DIR")/g"   "$NGINX_ETC/snippets/ncstub_locations.conf"

# ---------- 3. конфиг сайта ----------
CONF_OUT="$NGINX_ETC/sites-available/nextcloud-stub.conf"
if [ ! -d "$NGINX_ETC/sites-available" ]; then
    CONF_OUT="$NGINX_ETC/conf.d/nextcloud-stub.conf"   # не-Debian layout
    mkdir -p "$NGINX_ETC/conf.d"
fi
info "пишу конфиг сайта: $CONF_OUT"
if [ "$HTTP_ONLY" = "1" ]; then
    cat > "$CONF_OUT" <<EOF
# Nextcloud-заглушка (локальный режим HTTP, без TLS).
include snippets/ncstub_maps.conf;
server {
    listen $HTTP_PORT;
    listen [::]:$HTTP_PORT;
    server_name $DOMAIN;
    include snippets/ncstub_locations.conf;
}
EOF
else
    sed -e "s/NCSTUB_DOMAIN/$(esc "$DOMAIN")/g" \
        -e "s/NCSTUB_SSL_CERT/$(esc "$SSL_CERT")/g" \
        -e "s/NCSTUB_SSL_KEY/$(esc "$SSL_KEY")/g" \
        "$SRC/nginx/nextcloud-stub.conf" > "$CONF_OUT"
fi

# симлинк в sites-enabled (Debian)
if [ -d "$NGINX_ETC/sites-enabled" ]; then
    ln -sf "$CONF_OUT" "$NGINX_ETC/sites-enabled/nextcloud-stub.conf"
fi

# опционально: отключить дефолтный сайт nginx (по умолчанию не трогаем).
# На доменной TLS-раскатке он не мешает: наш server_name перекрывает default_server.
# Отключать имеет смысл, если хочешь, чтобы заглушка отвечала и на «голый» IP/чужой Host.
if [ "$DISABLE_DEFAULT_SITE" = "1" ]; then
    for d in "$NGINX_ETC/sites-enabled/default" "$NGINX_ETC/conf.d/default.conf"; do
        [ -e "$d" ] && { rm -f "$d"; info "отключён дефолтный сайт: $d"; }
    done
fi

# ---------- 4. права ----------
if id www-data >/dev/null 2>&1; then
    chown -R www-data:www-data "$INSTALL_DIR" || true
fi

# ---------- 5. проверка и перезагрузка ----------
info "проверяю конфиг (nginx -t)"
nginx -t
info "перезагружаю nginx"
$RELOAD_CMD

# ---------- 6. cron автообновления версии ----------
PY=$(command -v python3 || true)
if [ "$ENABLE_CRON" = "1" ] && [ -z "$PY" ]; then
    echo "ВНИМАНИЕ: python3 не найден — пропускаю установку cron автообновления."
    ENABLE_CRON=0
fi
if [ "$ENABLE_CRON" = "1" ]; then
    CRON_FILE="/etc/cron.d/nc-stub-version"
    info "ставлю cron автообновления версии ($CRON_SCHEDULE): $CRON_FILE"
    cat > "$CRON_FILE" <<CRON
# Автообновление версии Nextcloud-заглушки, со случайной задержкой запуска.
# Расписание можно поменять здесь (по умолчанию раз в неделю).
MAILTO=""
$CRON_SCHEDULE root $PY $SRC/scripts/update_version.py --www $SRC/www --www $INSTALL_DIR --major-policy $MAJOR_POLICY --jitter 1800 --reload-cmd "$RELOAD_CMD" >> /var/log/nc-stub-version.log 2>&1
CRON
    chmod 644 "$CRON_FILE"
fi

SCHEME="https"; [ "$HTTP_ONLY" = "1" ] && SCHEME="http"
echo
info "готово."
echo "    Адрес:        $SCHEME://$DOMAIN/"
echo "    Статика:      $INSTALL_DIR"
echo "    Конфиг:       $CONF_OUT"
echo "    Cookie сессии: $SESSNAME"
