#!/usr/bin/env python3
"""Собирает шрифты Blink для нативных приложений из woff2 сайта (латиница + кириллица в один TTF).

Запуск: python3 make_fonts.py <папка assets сборки сайта> [куда писать]
Нужны fonttools и brotli. Manrope и Unbounded под лицензией OFL, их можно раздавать с приложением.
Один и тот же набор берут Android (res/font) и iOS (UIAppFonts), поэтому имена файлов в стиле ресурсов Android.
"""
import glob
import os
import sys

from fontTools.merge import Merger
from fontTools.ttLib import TTFont

WEIGHTS = {
    "manrope": {"Manrope": [(400, "Regular", "regular"), (500, "Medium", "medium"), (600, "SemiBold", "semibold"), (700, "Bold", "bold"), (800, "ExtraBold", "extrabold")]},
    "unbounded": {"Unbounded": [(300, "Light", "light"), (500, "Medium", "medium"), (600, "SemiBold", "semibold"), (700, "Bold", "bold")]},
}


def find(assets, family, subset, weight):
    hits = sorted(glob.glob(os.path.join(assets, f"{family}-{subset}-{weight}-normal-*.woff2")))
    if not hits:
        raise SystemExit(f"нет {family}-{subset}-{weight} в {assets}")
    return hits[0]


def load_ttf(path, tmp):
    f = TTFont(path)
    f.flavor = None
    out = os.path.join(tmp, os.path.basename(path) + ".ttf")
    f.save(out)
    return out


def rename(font, family, style, weight):
    name = font["name"]
    ps = f"{family}-{style}"
    full = f"{family} {style}"
    for rec in list(name.names):
        if rec.nameID in (1, 2, 3, 4, 6, 16, 17, 21, 22, 25):
            name.removeNames(nameID=rec.nameID)
    for pid, eid, lid in ((3, 1, 0x409), (1, 0, 0)):
        name.setName(full if style not in ("Regular", "Bold") else family, 1, pid, eid, lid)
        name.setName("Regular" if style != "Bold" else "Bold", 2, pid, eid, lid)
        name.setName(f"{ps};blink", 3, pid, eid, lid)
        name.setName(full, 4, pid, eid, lid)
        name.setName(ps, 6, pid, eid, lid)
        name.setName(family, 16, pid, eid, lid)
        name.setName(style, 17, pid, eid, lid)
    font["OS/2"].usWeightClass = weight


def main():
    assets = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "res", "font")
    os.makedirs(out, exist_ok=True)
    tmp = os.path.join(out, ".tmp")
    os.makedirs(tmp, exist_ok=True)
    for key, families in WEIGHTS.items():
        for family, rows in families.items():
            for weight, style, slug in rows:
                parts = [load_ttf(find(assets, key, s, weight), tmp) for s in ("latin", "cyrillic")]
                merged = Merger().merge(parts)
                rename(merged, family, style, weight)
                dst = os.path.join(out, f"{key}_{slug}.ttf")
                merged.save(dst)
                cmap = merged.getBestCmap()
                assert ord("a") in cmap and ord("я") in cmap and ord("7") in cmap, dst
                print(dst, os.path.getsize(dst) // 1024, "KB", f"{family}-{style}")
    for f in glob.glob(os.path.join(tmp, "*")):
        os.remove(f)
    os.rmdir(tmp)


if __name__ == "__main__":
    main()
