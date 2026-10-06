# Nextcloud-заглушка (статическая имитация)

Статический сайт на nginx, который ведёт себя как настоящий Nextcloud для
внешнего наблюдателя (сканеры, боты, автоматические проверки), но не является
Nextcloud и ничего не хранит. Любая попытка входа заканчивается сообщением
«Неверное имя пользователя или пароль». PHP, база данных и реальная
аутентификация отсутствуют.

Поведение снято со снимка эталонного Nextcloud **32.0.14** (страница входа,
служебные эндпойнты, заголовки, cookie, коды ответов).

## Что имитируется

- **Страница входа** `/login` — реальная вёрстка Nextcloud с рабочей Vue-формой
  (логотип, поля, «Запомнить меня», «Войти с устройства», «Забыли пароль?»),
  фон, темизация, локализация en/ru по `Accept-Language`.
- **Неудачный вход**: POST `/login` → 303 на `/login?direct=1`, экран с
  подсвеченным полем и ошибкой «Неверное имя пользователя или пароль»,
  заголовок `X-Nextcloud-Bruteforce-Throttled`.
- **Сброс пароля**: POST `/lostpassword/email` → 200 `{"status":"success"}`,
  зелёное сообщение «если аккаунт существует, письмо отправлено» (как у оригинала).
- **Служебные эндпойнты**, по которым распознают Nextcloud:
  - `GET /status.php` → JSON с версией, `Access-Control-Allow-Origin: *`
  - `GET /ocs/v{1,2}.php/cloud/capabilities` → 412 без заголовка `OCS-APIRequest`,
    200 (xml или json) с ним
  - `GET /ocs/v{1,2}.php/cloud/user` → 401 (statuscode 997)
  - `/remote.php/dav`, `/remote.php/webdav`, `/public.php` → 401 +
    `WWW-Authenticate: Basic realm="Nextcloud"` + sabre-XML
  - `/.well-known/caldav|carddav` → 301 на `/remote.php/dav/`
  - `/.well-known/webfinger|nodeinfo|host-meta` → 404 + `X-NEXTCLOUD-WELL-KNOWN`
  - `/ocs-provider/`, `/ocm-provider/` (+ `X-NEXTCLOUD-OCM-PROVIDERS`)
  - `/index.php/204`, `/heartbeat`, `/cron.php`, `/csrftoken`, `/robots.txt`
  - маршруты `/apps/*`, `/settings/*` → 401 `{"message":"Current user is not logged in"}`
  - всё остальное → фирменная страница **404** Nextcloud
- **Заголовки и cookie** как у оригинала: CSP с `nonce`, генерируемым на каждый
  запрос, `X-Powered-By: PHP/8.3.33`, `X-Content-Type-Options`, `X-Frame-Options`,
  `Referrer-Policy`, сессионная cookie `ocXXXX`, `oc_sessionPassphrase`,
  `__Host-nc_sameSiteCookie{lax,strict}`.

Ресурсы, обращённые к реальному эталону, обезврежены: имя хоста заменяется на ваш
домен при установке, федеративный публичный ключ в `ocm-provider` заменён
плейсхолдером.

## Структура

```
nc-stub/
  nginx/
    nextcloud-stub.conf          # server-блок (плейсхолдеры подставляет install.sh)
    snippets/
      ncstub_hdr_common.conf     # общие заголовки (на все ответы, вкл. статику)
      ncstub_hdr_php.conf        # заголовки и cookie «динамических» ответов
  www/                           # статика + внутренние шаблоны/тела
    core/ dist/ apps/ ...        # css, js, шрифты, изображения Nextcloud
    _tpl/                        # HTML-шаблоны входа (en/ru, обычный/ошибка)
    _svc/                        # тела служебных ответов (status, capabilities, ...)
  scripts/
    install.sh                   # установка на сервер
    update_version.py            # автообновление версии (для cron)
  VERSION                        # текущая имитируемая версия
  README.md
```

## Установка

На сервере (Debian/Ubuntu с nginx), от root, из каталога `nc-stub`:

```bash
sudo DOMAIN=cloud.example.ru \
     SSL_CERT=/etc/letsencrypt/live/cloud.example.ru/fullchain.pem \
     SSL_KEY=/etc/letsencrypt/live/cloud.example.ru/privkey.pem \
     bash scripts/install.sh
```

Скрипт:
1. копирует статику в `/var/www/nc-stub/www` (меняется `INSTALL_DIR`);
2. подставляет домен в текстовые файлы;
3. ставит сниппеты в `/etc/nginx/snippets/` и конфиг в `sites-available`
   (или `conf.d`, если каталога нет), включает сайт;
4. генерирует случайное имя сессионной cookie;
5. `nginx -t` и перезагрузка;
6. ставит cron автообновления версии (`ENABLE_CRON=0` чтобы отключить).

Переменные: `DOMAIN`, `SSL_CERT`, `SSL_KEY`, `INSTALL_DIR`, `ENABLE_CRON`,
`MAJOR_POLICY` (`same`|`latest`), `RELOAD_CMD`.

Проверка после установки:

```bash
curl -sI https://cloud.example.ru/status.php
curl -s  https://cloud.example.ru/status.php
```

## Автообновление версии

`scripts/update_version.py` узнаёт последнюю стабильную версию Nextcloud с GitHub
(`nextcloud/server`), читает точную 4-компонентную версию из `version.php` тега и,
если она новее, правит версию в `status.json`, `capabilities.{xml,json}` и в
шаблонах входа (инлайн-конфиг и base64-блоки `initial-state`). Зависимостей нет.

```bash
python3 scripts/update_version.py --check      # только показать
python3 scripts/update_version.py --dry-run    # показать, что изменится
python3 scripts/update_version.py              # применить к www/ рядом со скриптом
```

**Какие каталоги обновляются.** nginx отдаёт сайт не из `www/` рядом со скриптом, а из
копии, которую сделал install.sh (`INSTALL_DIR`, по умолчанию `/var/www/nc-stub/www`).
Поэтому каталоги передаются явно через `--www` (можно несколько раз), и cron от install.sh
обновляет оба — исходники и то, что отдаёт сайт:

```bash
python3 scripts/update_version.py --www /root/nc-stub/www --www /var/www/nc-stub/www
```

Текущая версия каждого каталога берётся из его `_svc/status.json`, поэтому разошедшиеся
по версии каталоги обновляются корректно. Без `--www` обновляется только `www/` рядом со
скриптом, как раньше.

Политика мажора: `--major-policy same` (по умолчанию, оставаться в текущей ветке)
или `latest` (переходить на новый мажор, но не на релиз `x.y.0` — ждём первый патч).
Для cron install.sh ставит запуск раз в неделю со случайной задержкой `--jitter`
(меняется через `CRON_SCHEDULE`, напр. раз в месяц `"17 4 1 * *"`).

## Ограничения

- Глубокую проверку WebDAV с реальной авторизацией пройти нельзя: заглушка всегда
  отвечает 401. Пассивные и активные сканеры до этого не доходят — они смотрят
  статус, capabilities, заголовки и страницу входа.
- Cache-buster статики (`?v=25944b14`) и хэш темизации (`e6c86420`) фиксированы по
  снимку и версией не управляются (версию не выдают).
- Нет живой сессии. Введённый логин при неудачном входе не подставляется обратно
  (редирект на `/login?direct=1`, поле пустое) — сознательно, чтобы не показывать
  подозрительный константный логин. Значения `session`-cookie, `oc_sessionPassphrase`
  и `X-Request-Id` выводятся из `$request_id`/счётчиков nginx и связаны между собой;
  реальную независимую случайность и эхо логина дал бы модуль njs (не подключён,
  чтобы не плодить зависимости на слабом сервере).
- Набор `capabilities` соответствует снимку эталона; он может быть уже, чем у
  Nextcloud с полным набором приложений.

## Тестирование локально

Проще всего — по обычному HTTP, без сертификата (`HTTP_ONLY=1`):

```bash
docker run -d --name nctest -p 8080:80 -v "$PWD/nc-stub:/src:ro" nginx:stable
# у образа свой дефолтный сайт на :80 — убираем, чтобы не перехватывал
docker exec nctest rm -f /etc/nginx/conf.d/default.conf
docker exec -e DOMAIN=localhost -e HTTP_ONLY=1 -e HTTP_PORT=80 \
  -e RELOAD_CMD='nginx -s reload' -e ENABLE_CRON=0 \
  nctest bash /src/scripts/install.sh
curl -s http://localhost:8080/status.php
# открыть в браузере: http://localhost:8080/
```

С TLS (самоподписанный сертификат) — так же, но с `-p 8443:443`, `SSL_CERT`/`SSL_KEY`
вместо `HTTP_ONLY`.

Про дефолтный сайт nginx: на доменной TLS-раскатке он не мешает — наш `server_name`
перекрывает `default_server` для запросов к домену. Отключать его нужно, только если
хочешь, чтобы заглушка отвечала и на «голый» IP или чужой Host; тогда запусти
установку с `DISABLE_DEFAULT_SITE=1`. В локальном docker-тесте дефолт убираем вручную,
потому что там оба сервера слушают один порт с одинаковым `server_name`.
