# Immich-заглушка (статическая имитация)

Статический сайт на nginx, который для внешнего наблюдателя (сканеры, боты,
автоматические проверки) выглядит как настоящий self-hosted **Immich**, но не является
Immich и ничего не хранит. Любая попытка входа заканчивается ответом
«Incorrect email or password». Бэкенда, БД и реальной аутентификации нет —
только nginx + статические файлы.

Введённые в форму данные **нигде не читаются и не сохраняются** — отдаётся только
штатный ответ сервиса.

Поведение снято со снимка эталонного Immich **v3.2.4** (локальный Docker).

## Что имитируется

- **Страница входа** `/auth/login` и `/` — реальный SPA-шелл Immich (SvelteKit),
  со всеми ассетами `/_app/immutable/*`, favicon-набором, `manifest.json`,
  `service-worker.js`, `/custom.css`.
- **Неудачный вход**: `POST /api/auth/login` → `401 {"message":"Incorrect email or password"}`.
- **Служебные эндпойнты**, по которым распознают Immich:
  - `GET /api/server/version` → `{"major":3,"minor":2,"patch":4,"prerelease":null}`
  - `GET /api/server/ping` → `{"res":"pong"}`
  - `GET /api/server/config`, `/features`, `/version-history`, `/media-types`
  - `GET /.well-known/immich` → `{"api":{"endpoint":"/api"}}` (сильный маркер)
  - старое дерево `/api/server-info/*` и неизвестные `/api/*` → `404 {"message":"Cannot <METHOD> <path>"}`
- **Заголовки** как у эталона: `X-Powered-By: Express` на всём; на API-JSON ещё
  `X-Correlation-ID` (8 симв., из `$request_id`) и `Vary: Accept-Encoding`;
  на `/` — `Cache-Control: no-store`; на `/_app/immutable/*` — `immutable`-кэш.
  CORS не шлётся (как у реального v3.2.4).
- `favicon.ico` отдаётся побайтово — Shodan-favicon-hash совпадает с реальным Immich.

## Структура

```
immich-stub/
  nginx/
    immich-stub.conf             # server-блок (плейсхолдеры подставляет install.sh)
    snippets/
      imstub_maps.conf           # map для X-Correlation-ID
      imstub_hdr_common.conf     # X-Powered-By на все ответы (вкл. статику)
      imstub_hdr_api.conf        # заголовки API/JSON-ответов
      imstub_locations.conf      # вся маршрутизация
  www/                           # статика Immich (snapshot web-root) + _svc/ (тела)
  scripts/install.sh             # установка на сервер (без cron)
  VERSION                        # имитируемая версия (3.2.4)
```

## Установка

На сервере (Debian/Ubuntu с nginx), от root, из каталога `immich-stub`:

```bash
sudo DOMAIN=photos.example.ru \
     SSL_CERT=/etc/letsencrypt/live/photos.example.ru/fullchain.pem \
     SSL_KEY=/etc/letsencrypt/live/photos.example.ru/privkey.pem \
     bash scripts/install.sh
```

Скрипт: проверяет наличие nginx (ставит по `INSTALL_NGINX=1`, иначе — стоп с
сообщением), проверяет конфликт по домену/порту через `nginx -T` (чужое не трогает;
обход — `FORCE=1`), копирует статику, подставляет домен/пути, включает сайт,
`nginx -t` и reload. Автообновления версии/cron нет — версия зафиксирована в `www/_svc`.

Переменные: `DOMAIN`, `SSL_CERT`, `SSL_KEY`, `INSTALL_DIR`, `HTTP_ONLY`, `HTTP_PORT`,
`INSTALL_NGINX`, `FORCE`, `DISABLE_DEFAULT_SITE`, `RELOAD_CMD`.

## Проверка после установки

```bash
curl -s  https://photos.example.ru/api/server/version
curl -s  https://photos.example.ru/.well-known/immich
curl -sI https://photos.example.ru/
curl -s -X POST https://photos.example.ru/api/auth/login \
     -H 'Content-Type: application/json' -d '{"email":"x@x.io","password":"x"}'
```

## Локальный тест (HTTP, без сертификата)

```bash
docker run -d --name imtest -p 8080:80 -v "$PWD:/src:ro" nginx:stable
docker exec imtest rm -f /etc/nginx/conf.d/default.conf
docker exec -e DOMAIN=localhost -e HTTP_ONLY=1 -e HTTP_PORT=80 \
  -e RELOAD_CMD='nginx -s reload' imtest bash /src/scripts/install.sh
curl -s http://localhost:8080/api/server/version
```

## Ограничения

- Логин — клиентский SPA; заглушка реализует только провал `POST /api/auth/login`.
  Полноценный вход невозможен (бэкенда нет) — это и требуется.
- Версия зафиксирована снимком (3.2.4). Чтобы обновить — снять свежий снимок с
  Docker-эталона и заменить `www/` + `www/_svc/*.json`.
- Глубокие аутентифицированные вызовы API не проходят (их и не делает сканер —
  он смотрит version/ping/config, `.well-known`, заголовки, страницу входа, favicon).
