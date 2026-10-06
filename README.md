# service-stubs

Статические заглушки (decoy-страницы), имитирующие популярные self-hosted сервисы.

Каждая заглушка — это сайт на **nginx без бэкенда**: ни базы данных, ни PHP/приложения,
ни реальной аутентификации — только статические файлы и директивы nginx. Для внешнего
наблюдателя (сканеры, боты, автоматические проверки) она выглядит как настоящий сервис:
та же страница входа, те же служебные эндпоинты, заголовки, cookie и коды ответов. При
этом заглушка ничего не хранит и не обрабатывает — любая попытка входа заканчивается
штатным ответом «неверные данные», а введённые данные нигде не читаются и не сохраняются.

Поведение каждой заглушки снято со снимка соответствующего сервиса конкретной версии и
воспроизводит его так, чтобы совпадали ответы на типовые проверки (детект-эндпоинты,
страница входа, заголовки), вплоть до побайтовой отдачи фронтенда и favicon.

## Сервисы

| Каталог | Сервис | Версия снимка |
|---|---|---|
| [`immich-stub`](immich-stub/) | [Immich](https://immich.app) — self-hosted фото/видео | 3.2.4 |
| [`nextcloud-stub`](nextcloud-stub/) | [Nextcloud](https://nextcloud.com) — self-hosted облако/файлы | 32.0.14 |
| [`jellyfin-stub`](jellyfin-stub/) | [Jellyfin](https://jellyfin.org) — self-hosted медиа-сервер | 10.10.7 |
| [`home-assistant-stub`](home-assistant-stub/) | [Home Assistant](https://www.home-assistant.io) — платформа умного дома | 2026.9.4 |



## Установка

У каждого сервиса свой `README.md` и `scripts/install.sh`. Коротко (Debian/Ubuntu, от root,
из корня репозитория):

```bash
sudo DOMAIN=example.com \
     SSL_CERT=/etc/letsencrypt/live/example.com/fullchain.pem \
     SSL_KEY=/etc/letsencrypt/live/example.com/privkey.pem \
     bash <service>-stub/scripts/install.sh
```

Для локального теста без TLS — `HTTP_ONLY=1 HTTP_PORT=8080`.

Скрипт сам проверит/поставит nginx, проверит отсутствие конфликтов по домену и порту
(чужие конфиги не трогает), разложит статику, подставит домен и пути, включит сайт и
выполнит `nginx -t` перед перезагрузкой. Подробности и параметры — в `README.md` внутри
каталога сервиса.

## Структура заглушки

```
<service>-stub/
  nginx/
    <service>-stub.conf        # server-блок (плейсхолдеры подставляет install.sh)
    snippets/                  # заголовки, maps, вся маршрутизация
  www/                         # статика сервиса + внутренние тела служебных ответов
  scripts/install.sh           # установка на сервер
  VERSION                      # имитируемая версия
  README.md
```

## Раскатка на сервере (из релизов)

Каждая заглушка публикуется отдельным архивом `<service>-stub.tar.gz` в
[релизах](../../releases) (собираются автоматически из тега, см. ниже). На сервер нужна
одна заглушка, поэтому тянем только её — скриптом `deploy.sh`.

`deploy.sh` сам скачивает нужный архив, распаковывает и запускает `install.sh`:

```bash
# один раз скачать deploy.sh
curl -H "Authorization: Bearer <TOKEN>" -sSL \
  https://raw.githubusercontent.com/sjotik/service-stubs/main/deploy.sh -o deploy.sh

# раскатать заглушку одной командой (от root)
sudo TOKEN=<TOKEN> DOMAIN=cloud.example.ru \
     SSL_CERT=/etc/letsencrypt/live/cloud.example.ru/fullchain.pem \
     SSL_KEY=/etc/letsencrypt/live/cloud.example.ru/privkey.pem \
     bash deploy.sh immich
```

- `<service>`: `immich` | `jellyfin` | `nextcloud` | `home-assistant` (последний аргумент).
- `TOKEN` — fine-grained PAT с доступом `Contents: read` на этот (приватный) репозиторий.
- `REF` — какой релиз брать: `latest` (по умолчанию) или конкретный тег, напр.
  `REF=v2026.10.06`.
- Локальный тест без TLS: `... HTTP_ONLY=1 HTTP_PORT=8080 bash deploy.sh immich`.
- Обновление — повторить ту же команду (новый релиз подтянется; `install.sh` идемпотентен).

## Релизы и сборка архивов (CI)

Архивы собираются GitHub Actions (`.github/workflows/release.yml`) на **пуш тега** `v*`:

```bash
git tag v2026.10.06
git push origin v2026.10.06
```

Workflow пакует каждую `*-stub/` в `*-stub.tar.gz` и создаёт релиз с этими архивами.
Так у каждого релиза — своя версия снимков; `deploy.sh` по умолчанию берёт `latest`.
