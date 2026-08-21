#!/usr/bin/env python3
"""
Оффлайн-перевод en->ru через Argos Translate — последняя ступень каскада.

Вызывается из SkLocale.psm1:
    python argos-translate.py <вход.json> <выход.json>

Оба файла — UTF-8 без BOM, JSON-массив строк. Порядок и количество строк
на выходе совпадают со входом; при любой ошибке скрипт завершается ненулевым
кодом, и PowerShell отдаёт строки следующему провайдеру (то есть никому —
argos стоит последним, и строки останутся английскими).

Модель ставится при первом запуске (~100 МБ). Каталог пакетов можно задать
переменной окружения ARGOS_PACKAGES_DIR, чтобы кэшировать его между запусками CI.
"""

import json
import os
import shutil
import sys
import tempfile
import urllib.request

FROM_CODE = "en"
TO_CODE = "ru"

# Официальное зеркало пакетов Argos. Идёт первым намеренно: штатный хост
# argos-net.com на части сетей режется до ~280 Б/с, и загрузка 187 МБ не
# доходит до конца — urllib отваливается с IncompleteRead после ~25 КБ.
MIRROR = "https://data.argosopentech.com/argospm/v1/%s.argosmodel"


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def candidate_urls(pkg):
    """Откуда пробовать качать модель, в порядке предпочтения."""
    urls = []

    override = os.environ.get("ARGOS_MODEL_URL")
    if override:
        urls.append(override)

    code = getattr(pkg, "code", None) or "translate-%s_%s" % (FROM_CODE, TO_CODE)
    version = str(getattr(pkg, "package_version", "") or "").replace(".", "_")
    if version:
        urls.append(MIRROR % ("%s-%s" % (code, version)))

    # ссылки из индекса — последними, см. комментарий к MIRROR
    urls.extend(getattr(pkg, "links", None) or [])
    return urls


def download(url):
    """Качает .argosmodel во временный файл и проверяет полноту по Content-Length."""
    log("качаю %s" % url)
    with urllib.request.urlopen(url, timeout=60) as resp:
        expected = resp.headers.get("Content-Length")
        expected = int(expected) if expected else None
        fd, path = tempfile.mkstemp(suffix=".argosmodel")
        try:
            with os.fdopen(fd, "wb") as out:
                shutil.copyfileobj(resp, out, 1024 * 256)
        except BaseException:
            os.unlink(path)
            raise

    got = os.path.getsize(path)
    if expected is not None and got != expected:
        os.unlink(path)
        raise IOError("получено %d байт из %d" % (got, expected))

    log("скачано %.1f МБ" % (got / 1048576.0))
    return path


def fetch_model(pkg):
    """Пробует зеркала по очереди; последней попыткой — штатный загрузчик Argos."""
    errors = []
    for url in candidate_urls(pkg):
        try:
            return download(url)
        except Exception as exc:  # noqa: BLE001 — важен сам факт неудачи
            log("  не вышло: %s" % exc)
            errors.append("%s -> %s" % (url, exc))

    log("пробую штатный загрузчик Argos")
    try:
        return pkg.download()
    except Exception as exc:  # noqa: BLE001
        errors.append("argostranslate -> %s" % exc)

    raise RuntimeError("модель не скачалась:\n  " + "\n  ".join(errors))


def get_translation():
    """Возвращает объект перевода en->ru, доставив модель при необходимости."""
    import argostranslate.package
    import argostranslate.translate

    def find():
        langs = argostranslate.translate.get_installed_languages()
        src = next((l for l in langs if l.code == FROM_CODE), None)
        dst = next((l for l in langs if l.code == TO_CODE), None)
        if src is None or dst is None:
            return None
        try:
            return src.get_translation(dst)
        except Exception:
            return None

    tr = find()
    if tr is not None:
        return tr

    log("модель en->ru не найдена, ставлю (это разовая операция)")
    argostranslate.package.update_package_index()
    available = argostranslate.package.get_available_packages()
    pkg = next(
        (p for p in available if p.from_code == FROM_CODE and p.to_code == TO_CODE),
        None,
    )
    if pkg is None:
        raise RuntimeError("в индексе Argos нет пакета en->ru")

    path = fetch_model(pkg)
    try:
        argostranslate.package.install_from_path(path)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass
    log("модель установлена")

    tr = find()
    if tr is None:
        raise RuntimeError("модель установлена, но перевод en->ru недоступен")
    return tr


def main():
    if len(sys.argv) != 3:
        log("использование: argos-translate.py <вход.json> <выход.json>")
        return 2

    with open(sys.argv[1], encoding="utf-8-sig") as f:
        texts = json.load(f)
    if not isinstance(texts, list):
        log("на входе ожидался JSON-массив строк")
        return 2

    tr = get_translation()

    out = []
    for t in texts:
        # Пустые строки Argos может вернуть с мусором — не трогаем их
        out.append(tr.translate(t) if t.strip() else t)

    with open(sys.argv[2], "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False)

    log("переведено строк: %d" % len(out))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 — наверх отдаём только код возврата
        log("ошибка: %s" % exc)
        sys.exit(1)
