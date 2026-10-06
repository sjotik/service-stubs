#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Автообновление версии Nextcloud в файлах заглушки.

Что делает:
  1. Узнаёт последнюю стабильную версию Nextcloud с GitHub (репозиторий
     nextcloud/server): берёт список тегов, выбирает подходящий и читает
     точную 4-компонентную версию из version.php этого тега.
  2. Сравнивает с текущей версией заглушки (файл VERSION).
  3. Если появилась новее — правит версию в status.json, capabilities.xml,
     capabilities.json и в шаблонах страницы входа (инлайн-конфиг и
     base64-блоки initial-state), затем обновляет VERSION.

Зависимостей нет, только стандартная библиотека. Подходит для cron.

Политика мажора (--major-policy):
  same   (по умолчанию) — оставаться в текущей мажорной ветке (32.x -> 32.y).
  latest — переходить и на новый мажор, но не на «нулевой» релиз x.y.0:
           ждём первый патч (x.y.1+), админы редко обновляются в день выхода.

Каталоги со статикой (--www, можно несколько раз):
  По умолчанию обновляется только www/ рядом со скриптом (исходники).
  install.sh копирует статику в INSTALL_DIR (по умолчанию /var/www/nc-stub/www),
  и nginx отдаёт сайт оттуда. Поэтому cron, который ставит install.sh, передаёт
  оба каталога: --www <исходники>/www --www <INSTALL_DIR>.
  Текущая версия каждого каталога берётся из его _svc/status.json, так что
  каталоги, разошедшиеся по версии, обновляются корректно.

Примеры:
  update_version.py --check           # только показать, что доступно
  update_version.py --dry-run         # показать, что было бы изменено
  update_version.py                    # применить обновление к www/ рядом со скриптом
  update_version.py --www /root/nc-stub/www --www /var/www/nc-stub/www
"""
import argparse, json, os, re, sys, base64, urllib.request, urllib.error, datetime, random, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WWW  = os.path.join(ROOT, "www")
VERSION_FILE = os.path.join(ROOT, "VERSION")
GH_API = "https://api.github.com/repos/nextcloud/server/tags?per_page=100"
GH_RAW = "https://raw.githubusercontent.com/nextcloud/server/{tag}/version.php"
UA = "nc-stub-version-updater/1.0 (+https://github.com/nextcloud/server)"

TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")   # только стабильные vX.Y.Z


def log(msg):
    print(f"[{datetime.datetime.now():%Y-%m-%d %H:%M:%S}] {msg}", flush=True)


def http_get(url, timeout):
    req = urllib.request.Request(url, headers={"User-Agent": UA,
                                               "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8")


def read_current():
    with open(VERSION_FILE) as f:
        return tuple(int(x) for x in f.read().strip().split("."))


def read_www_version(www, fallback):
    """Версия, которая сейчас в каталоге статики (из _svc/status.json); иначе fallback."""
    try:
        d = json.load(open(os.path.join(www, "_svc", "status.json")))
        return tuple(int(x) for x in str(d["version"]).split("."))
    except Exception:
        return fallback


def fetch_tags(timeout):
    data = json.loads(http_get(GH_API, timeout))
    out = []
    for t in data:
        m = TAG_RE.match(t.get("name", ""))
        if m:
            out.append((int(m.group(1)), int(m.group(2)), int(m.group(3)), t["name"]))
    return out


def fetch_full_version(tag, timeout):
    """Читает version.php тега и возвращает (v4-tuple, versionstring)."""
    src = http_get(GH_RAW.format(tag=tag), timeout)
    m = re.search(r"\$OC_Version\s*=\s*(?:array\s*\(|\[)\s*([\d\s,]+?)\s*[\])]", src)
    s = re.search(r"\$OC_VersionString\s*=\s*'([\d.]+)'", src)
    if not m:
        raise RuntimeError(f"не удалось разобрать version.php тега {tag}")
    nums = tuple(int(x) for x in m.group(1).split(",") if x.strip() != "")
    vstr = s.group(1) if s else ".".join(str(x) for x in nums[:3])
    return nums, vstr


def pick_target(tags, current, policy, timeout):
    cur_major = current[0]
    stable = sorted(tags, reverse=True)
    if not stable:
        raise RuntimeError("GitHub не вернул подходящих тегов")
    same_major = [t for t in stable if t[0] == cur_major]
    if policy == "same":
        cand = same_major or stable
    else:  # latest: перейти и на новый мажор, но не на самый «нулевой» релиз —
           # ждём хотя бы первый патч (x.y.1+), чтобы не обновляться в день выхода
        top = stable[0]
        cand = (same_major or stable) if (top[0] > cur_major and top[2] == 0) else stable
    best = cand[0]
    v4, vstr = fetch_full_version(best[3], timeout)
    return v4, vstr, best[3]


# ------------------------- патчинг файлов -------------------------

def patch_status(path, v4, vstr):
    d = json.load(open(path))
    d["version"] = ".".join(str(x) for x in v4)
    d["versionstring"] = vstr
    json.dump(d, open(path, "w"), separators=(",", ":"))


def patch_caps_json(path, v4, vstr):
    d = json.load(open(path))
    ver = d["ocs"]["data"]["version"]
    ver["major"], ver["minor"], ver["micro"] = v4[0], v4[1], v4[2]
    ver["string"] = vstr
    json.dump(d, open(path, "w"), separators=(",", ":"))


def patch_caps_xml(path, v4, vstr):
    t = open(path, encoding="utf-8").read()
    t = re.sub(r"<major>\d+</major>",  f"<major>{v4[0]}</major>",  t, count=1)
    t = re.sub(r"<minor>\d+</minor>",  f"<minor>{v4[1]}</minor>",  t, count=1)
    t = re.sub(r"<micro>\d+</micro>",  f"<micro>{v4[2]}</micro>",  t, count=1)
    t = re.sub(r"<string>[\d.]+</string>", f"<string>{vstr}</string>", t, count=1)
    open(path, "w", encoding="utf-8").write(t)


def _sub_b64_initialstate(html, old_v4, old_vstr, v4, vstr):
    """Обновляет версию внутри base64 initial-state-* блоков логина."""
    v4s = ".".join(str(x) for x in v4)
    old_v4s = ".".join(str(x) for x in old_v4)

    def repl(m):
        whole, val = m.group(0), m.group(1)
        try:
            txt = base64.b64decode(val).decode("utf-8")
        except Exception:
            return whole
        if old_v4s not in txt and old_vstr not in txt:
            return whole
        txt2 = txt.replace(old_v4s, v4s).replace(old_vstr, vstr)
        return whole.replace(val, base64.b64encode(txt2.encode()).decode())

    return re.sub(r'id="initial-state-[^"]+" value="([^"]*)"', repl, html)


def patch_login_tpl(path, old_v4, old_vstr, v4, vstr):
    v4s = ".".join(str(x) for x in v4)
    old_v4s = ".".join(str(x) for x in old_v4)
    html = open(path, encoding="utf-8").read()
    # инлайн _oc_config
    html = html.replace(f'"version":"{old_v4s}"', f'"version":"{v4s}"')
    html = html.replace(f'"versionstring":"{old_vstr}"', f'"versionstring":"{vstr}"')
    # base64 блоки
    html = _sub_b64_initialstate(html, old_v4, old_vstr, v4, vstr)
    open(path, "w", encoding="utf-8").write(html)


def apply_update(www, old_v4, v4, vstr, dry):
    old_vstr = ".".join(str(x) for x in old_v4[:3])
    targets = []
    svc = os.path.join(www, "_svc")
    if os.path.exists(os.path.join(svc, "status.json")):       targets.append(("status", os.path.join(svc, "status.json")))
    if os.path.exists(os.path.join(svc, "capabilities.json")): targets.append(("caps_json", os.path.join(svc, "capabilities.json")))
    if os.path.exists(os.path.join(svc, "capabilities.xml")):  targets.append(("caps_xml", os.path.join(svc, "capabilities.xml")))
    tpl = os.path.join(www, "_tpl")
    if os.path.isdir(tpl):
        for fn in sorted(os.listdir(tpl)):
            if fn.startswith("login.") and fn.endswith(".html"):
                targets.append(("login", os.path.join(tpl, fn)))
    for kind, path in targets:
        if dry:
            log(f"  [dry-run] обновил бы {kind}: {path}")
            continue
        if kind == "status":     patch_status(path, v4, vstr)
        elif kind == "caps_json":patch_caps_json(path, v4, vstr)
        elif kind == "caps_xml": patch_caps_xml(path, v4, vstr)
        elif kind == "login":    patch_login_tpl(path, old_v4, old_vstr, v4, vstr)
        log(f"  обновлён {kind}: {path}")


def main():
    ap = argparse.ArgumentParser(description="Автообновление версии Nextcloud в заглушке")
    ap.add_argument("--check", action="store_true", help="только показать доступную версию")
    ap.add_argument("--dry-run", action="store_true", help="показать, что было бы изменено")
    ap.add_argument("--major-policy", choices=["same", "latest"], default="same")
    ap.add_argument("--timeout", type=int, default=20)
    ap.add_argument("--jitter", type=int, default=0, help="случайная задержка старта до N секунд (для cron)")
    ap.add_argument("--reload-cmd", default="", help="команда перезагрузки nginx после обновления, напр. 'systemctl reload nginx'")
    ap.add_argument("--www", action="append", default=[],
                    help="каталог статики для обновления; можно несколько раз (по умолчанию www/ рядом со скриптом)")
    args = ap.parse_args()
    dirs = []
    for d in (args.www or [WWW]):
        d = os.path.abspath(d)
        if d not in dirs:
            dirs.append(d)

    if args.jitter > 0:
        time.sleep(random.uniform(0, args.jitter))

    try:
        current = read_current()
    except Exception as e:
        log(f"ОШИБКА чтения VERSION: {e}"); sys.exit(2)

    try:
        tags = fetch_tags(args.timeout)
        v4, vstr, tag = pick_target(tags, current, args.major_policy, args.timeout)
    except (urllib.error.URLError, RuntimeError, TimeoutError) as e:
        log(f"ОШИБКА получения версии с GitHub: {e}"); sys.exit(1)

    fmt = lambda v: ".".join(map(str, v))
    log(f"доступная: {fmt(v4)} (тег {tag})")
    missing = [d for d in dirs if not os.path.isdir(os.path.join(d, "_svc"))]
    for d in missing:
        log(f"ОШИБКА: {d} не похож на каталог статики заглушки (нет _svc/), пропускаю")
    dirs = [d for d in dirs if d not in missing]
    todo = []
    for d in dirs:
        cur = read_www_version(d, current)
        state = "обновление не требуется" if v4 <= cur else "нужно обновить"
        log(f"  {d}: {fmt(cur)} — {state}")
        if v4 > cur:
            todo.append((d, cur))

    if not todo:
        if v4 > current and not args.check and not args.dry_run:
            open(VERSION_FILE, "w").write(fmt(v4) + "\n")
        log("обновление не требуется."); return

    if args.check:
        log("доступно обновление (режим --check, изменений не вношу)."); return

    for d, cur in todo:
        log(f"обновляю {d}: {fmt(cur)} -> {fmt(v4)}")
        apply_update(d, cur, v4, vstr, args.dry_run)
    if not args.dry_run and v4 > current:
        open(VERSION_FILE, "w").write(fmt(v4) + "\n")
    if missing:
        log("ВНИМАНИЕ: часть каталогов пропущена, см. ошибки выше.")
    if not args.dry_run and args.reload_cmd:
        rc = os.system(args.reload_cmd)
        log(f"перезагрузка nginx: '{args.reload_cmd}' -> код {rc}")
    log("готово.")


if __name__ == "__main__":
    main()
