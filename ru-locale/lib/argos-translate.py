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
import sys

FROM_CODE = "en"
TO_CODE = "ru"


def log(msg):
    print(msg, file=sys.stderr, flush=True)


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

    argostranslate.package.install_from_path(pkg.download())
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
