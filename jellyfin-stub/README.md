# Jellyfin-заглушка (статическая имитация)

Статический сайт на nginx, который для внешнего наблюдателя (автоматические проверки, боты)
выглядит как настоящий self-hosted **Jellyfin**, но не является Jellyfin и ничего не хранит.
Любая попытка входа отклоняется. Бэкенда, БД и реальной аутентификации нет — только nginx +
статические файлы.

Введённые в форму данные **нигде не читаются и не сохраняются** — отдаётся только штатный
ответ сервиса.

Поведение снято со снимка эталонного Jellyfin **10.10.7** (локальный Docker).

## Что имитируется

- **Веб-клиент** `/web/` — реальный SPA Jellyfin (страница входа, бандлы, шрифты, favicon,
  manifest). `/` → `302 web/`, `/web` → `301 /web/`.
- **Служебные эндпойнты**:
  - `GET /System/Info/Public` → JSON с версией, `ProductName:"Jellyfin Server"`, `Id`,
    `StartupWizardCompleted:true`.
  - `GET|POST /System/Ping` → `"Jellyfin Server"`.
  - `GET /Users/Public` → `[]`.
  - `GET /System/Info` (без `/Public`) → `401`.
- **Провал логина**: `POST /Users/AuthenticateByName` с MediaBrowser-заголовком →
  `401 text/plain` «Error processing request.»; без заголовка → `400`. Никогда не `200` с токеном.
- **Заголовок** `X-Response-Time-ms` на ответах (характерный признак Jellyfin/Kestrel),
  со случайным правдоподобным значением (через `map $request_id`).
- `favicon.ico` отдаётся побайтово — хэш совпадает с реальным Jellyfin выбранной сборки.

## Структура

```
jellyfin-stub/
  nginx/
    jellyfin-stub.conf           # server-блок (плейсхолдеры подставляет install.sh)
    snippets/
      jfstub_maps.conf           # X-Response-Time-ms + наличие auth-заголовка
      jfstub_hdr_common.conf     # X-Response-Time-ms на ответах
      jfstub_locations.conf      # вся маршрутизация
  www/
    web/                         # веб-клиент Jellyfin (статика, отдаётся под /web/)
    _svc/                        # тела служебных ответов
  scripts/install.sh             # установка на сервер (без cron)
  VERSION                        # имитируемая версия (10.10.7)
```

## Установка

На сервере (Debian/Ubuntu с nginx), от root, из каталога `jellyfin-stub`:

```bash
sudo DOMAIN=media.example.ru \
     SSL_CERT=/etc/letsencrypt/live/media.example.ru/fullchain.pem \
     SSL_KEY=/etc/letsencrypt/live/media.example.ru/privkey.pem \
     bash scripts/install.sh
```

Скрипт проверяет наличие nginx (ставит по `INSTALL_NGINX=1`, иначе — стоп с сообщением),
проверяет конфликт по домену/порту через `nginx -T` (чужое не трогает; обход — `FORCE=1`),
копирует статику, подставляет домен/пути, включает сайт, `nginx -t` и reload.

Переменные: `DOMAIN`, `SSL_CERT`, `SSL_KEY`, `INSTALL_DIR`, `HTTP_ONLY`, `HTTP_PORT`,
`INSTALL_NGINX`, `FORCE`, `DISABLE_DEFAULT_SITE`, `RELOAD_CMD`.

## Проверка после установки

```bash
curl -s  https://media.example.ru/System/Info/Public
curl -sI https://media.example.ru/web/
curl -s -X POST https://media.example.ru/Users/AuthenticateByName \
     -H 'Authorization: MediaBrowser Client="Jellyfin Web", Device="Browser", DeviceId="x", Version="10.10.7", Token=""' \
     -H 'Content-Type: application/json' -d '{"Username":"admin","Pw":"x"}'
```

## Локальный тест (HTTP, без сертификата)

```bash
docker run -d --name jftest -p 8086:80 -v "$PWD:/src:ro" nginx:stable
docker exec jftest rm -f /etc/nginx/conf.d/default.conf
docker exec -e DOMAIN=localhost -e HTTP_ONLY=1 -e HTTP_PORT=80 \
  -e RELOAD_CMD='nginx -s reload' jftest bash /src/scripts/install.sh
curl -s http://localhost:8086/System/Info/Public
```

## Ограничения

- Логин — клиентский SPA; заглушка реализует только провал `POST /Users/AuthenticateByName`.
- `Server: nginx` (за реверс-прокси так и выглядит). Точный `Server: Kestrel`,
  `Transfer-Encoding: chunked` на динамике, формат `ETag` (у nginx свой — `mtime-size`,
  у Kestrel другой; сам заголовок присутствует) и отсутствие `Content-Type` на пустых
  ответах (302/301/401/404 — у эталона content-type нет, у заглушки `octet-stream`) —
  убираются/подменяются только модулем `headers-more`; по умолчанию не ставим.
- «Напомнить пароль» с пустым телом `{}` у эталона → 400 (валидация), у заглушки → 200;
  реальная форма всегда шлёт `EnteredUsername` → 200 (совпадает). Разбор тела запроса
  в статике nginx невозможен — это осознанный edge.
- Пути API регистронезависимы (как у эталона) — реализовано через `~*`-локации.
- Версия зафиксирована снимком (10.10.7). Для обновления — снять свежий снимок с Docker
  и заменить `www/web/` + `www/_svc/*`.
