#!/usr/bin/env bash
# =====================================================================
#  Раскатка одной заглушки из релизов репозитория sjotik/service-stubs.
#  Скрипт сам скачивает нужный архив, распаковывает и запускает install.sh.
#
#  Использование (на сервере, от root):
#    sudo TOKEN=<pat> DOMAIN=cloud.example.ru \
#         SSL_CERT=/etc/letsencrypt/live/cloud.example.ru/fullchain.pem \
#         SSL_KEY=/etc/letsencrypt/live/cloud.example.ru/privkey.pem \
#         bash deploy.sh immich
#
#    <сервис>: immich | jellyfin | nextcloud | home-assistant
#    TOKEN  — fine-grained PAT с доступом Contents: read на приватный репозиторий.
#    REF    — какой релиз брать: latest (по умолчанию) или тег, напр. v2026.10.06.
#
#  Локальный тест без TLS:
#    sudo TOKEN=<pat> DOMAIN=localhost HTTP_ONLY=1 HTTP_PORT=8080 bash deploy.sh immich
# =====================================================================
set -euo pipefail

REPO="${REPO:-sjotik/service-stubs}"
REF="${REF:-latest}"
SVC="${1:-}"

case "$SVC" in
    immich|jellyfin|nextcloud|home-assistant) ;;
    *) echo "ОШИБКА: укажите сервис: immich | jellyfin | nextcloud | home-assistant" >&2; exit 1 ;;
esac
[ -n "${TOKEN:-}" ] || { echo "ОШИБКА: не задан TOKEN (fine-grained PAT, Contents: read на $REPO)" >&2; exit 1; }
command -v curl    >/dev/null || { echo "ОШИБКА: нет curl" >&2; exit 1; }
command -v python3 >/dev/null || { echo "ОШИБКА: нет python3 (нужен для разбора ответа GitHub API)" >&2; exit 1; }

NAME="${SVC}-stub"
ASSET="${NAME}.tar.gz"
API="https://api.github.com/repos/$REPO/releases"
REL_URL="$API/latest"; [ "$REF" != "latest" ] && REL_URL="$API/tags/$REF"

echo ">>> ищу релиз ($REF) и ассет $ASSET"
ASSET_API_URL="$(
    curl -fsSL -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" "$REL_URL" \
    | python3 -c "import json,sys
d=json.load(sys.stdin)
u=[a['url'] for a in d.get('assets',[]) if a['name']=='$ASSET']
print(u[0] if u else '')"
)"
[ -n "$ASSET_API_URL" ] || { echo "ОШИБКА: в релизе $REF нет ассета $ASSET" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo ">>> скачиваю $ASSET"
curl -fL -H "Authorization: Bearer $TOKEN" -H "Accept: application/octet-stream" "$ASSET_API_URL" -o "$TMP/$ASSET"
echo ">>> распаковываю"
tar xzf "$TMP/$ASSET" -C "$TMP"
[ -f "$TMP/$NAME/scripts/install.sh" ] || { echo "ОШИБКА: в архиве нет $NAME/scripts/install.sh" >&2; exit 1; }
echo ">>> запускаю $NAME/scripts/install.sh"
bash "$TMP/$NAME/scripts/install.sh"
