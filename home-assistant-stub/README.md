# Home Assistant-заглушка (статическая имитация)

Статический сайт на nginx, который для внешнего наблюдателя (автоматические проверки, боты)
выглядит как настоящий self-hosted **Home Assistant** (онбордённый инстанс), но не является
Home Assistant и ничего не хранит. Любая попытка входа отклоняется. Бэкенда, БД и реальной
аутентификации нет — только nginx + статические файлы.

Введённые в форму данные **нигде не читаются и не сохраняются** — отдаётся только штатный
ответ сервиса.

Поведение снято со снимка эталонного Home Assistant **2026.9.4** (локальный Docker).

## Что имитируется

- **Главная** `/` → отдаёт приложение (экран входа), байт-в-байт как эталон; фронт
  (`/frontend_latest/*`, `/static/*`, service workers) грузится и рисует форму входа.
- **Служебные эндпойнты**:
  - `GET /manifest.json` → `application/manifest+json` (реальный манифест HA).
  - `GET /auth/providers` → `{"providers":[{"name":"Home Assistant Local","id":null,"type":"homeassistant"}],"preselect_remember_me":true}`.
  - `GET /auth/authorize` → страница авторизации (frontend).
  - `GET /api/*` без токена → `401` «401: Unauthorized».
- **Логин (flow)**: `POST /auth/login_flow` → форма (`flow_id` из `$request_id`);
  `POST /auth/login_flow/<id>` → форма с `"errors":{"base":"invalid_auth"}` (HTTP **200**,
  как у HA); `GET /auth/login_flow` → `405`.
- **Ошибки как у эталона**: 404 → `text/plain` «404: Not Found»; 405 → пусто.
- **Заголовки** `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`,
  `X-Frame-Options: SAMEORIGIN` на ответах (как эталон).
- `favicon.ico` в `/static/icons/` отдаётся побайтово.

## Структура

```
home-assistant-stub/
  nginx/
    home-assistant-stub.conf     # server-блок (плейсхолдеры подставляет install.sh)
    snippets/
      hastub_hdr_common.conf     # заголовки ответов
      hastub_locations.conf      # вся маршрутизация
  www/
    frontend_latest/ static/     # фронт HA (статика; es5/maps/предсжатые убраны для размера)
    index.html authorize.html    # отрендеренные страницы (снимок эталона)
    sw-*.js service_worker.js robots.txt
    _svc/                        # тела ошибок (404/пусто)
  scripts/install.sh             # установка на сервер (без cron)
  VERSION                        # имитируемая версия (2026.9.4)
```

## Установка

На сервере (Debian/Ubuntu с nginx), от root, из каталога `home-assistant-stub`:

```bash
sudo DOMAIN=ha.example.ru \
     SSL_CERT=/etc/letsencrypt/live/ha.example.ru/fullchain.pem \
     SSL_KEY=/etc/letsencrypt/live/ha.example.ru/privkey.pem \
     bash scripts/install.sh
```

Скрипт проверяет наличие nginx (ставит по `INSTALL_NGINX=1`, иначе — стоп с сообщением),
проверяет конфликт по домену/порту через `nginx -T` (чужое не трогает; обход — `FORCE=1`),
копирует статику, подставляет домен/пути, включает сайт, `nginx -t` и reload.

Переменные: `DOMAIN`, `SSL_CERT`, `SSL_KEY`, `INSTALL_DIR`, `HTTP_ONLY`, `HTTP_PORT`,
`INSTALL_NGINX`, `FORCE`, `DISABLE_DEFAULT_SITE`, `RELOAD_CMD`.

## Проверка после установки

```bash
curl -s  https://ha.example.ru/auth/providers
curl -sI https://ha.example.ru/
curl -s -X POST https://ha.example.ru/auth/login_flow -H 'Content-Type: application/json' \
     -d '{"client_id":"https://ha.example.ru/","handler":["homeassistant",null],"redirect_uri":"https://ha.example.ru/","type":"authorize"}'
```

## Локальный тест (HTTP, без сертификата)

```bash
docker run -d --name hatest -p 8087:80 -v "$PWD:/src:ro" nginx:stable
docker exec hatest rm -f /etc/nginx/conf.d/default.conf
docker exec -e DOMAIN=localhost -e HTTP_ONLY=1 -e HTTP_PORT=80 \
  -e RELOAD_CMD='nginx -s reload' hatest bash /src/scripts/install.sh
curl -s http://localhost:8087/auth/providers
```

## Ограничения

- Онбординг зафиксирован: эмулируется уже настроенный инстанс (`/` отдаёт приложение,
  `/auth/providers` — провайдера). Онбординг-флоу не воспроизводится (сканеру не нужен).
- `Server: nginx` (у эталона пустой); на `/` и `/auth/authorize` nginx добавляет
  `Accept-Ranges`/`ETag`/`Last-Modified` (у HA эти ответы динамические, без них). Точное
  совпадение этих заголовков — только модулем `headers-more` (`more_clear_headers …`,
  `more_set_headers "Server: "`); по умолчанию не ставим.
- Статика подрезана до набора, который грузит страница входа (без `frontend_es5`, source
  maps и предсжатых `.br/.gz`) — чтобы каталог был компактным.
- Версия зафиксирована снимком (2026.9.4). Для обновления — снять свежий снимок с Docker.
```
