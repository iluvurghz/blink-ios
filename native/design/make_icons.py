#!/usr/bin/env python3
"""Иконка Blink для нативных приложений из public/icon.png сайта: вынимает знак «b.» и собирает
 - Android: передний слой адаптивной иконки (432x432, прозрачный) в res/drawable-nodpi,
 - iOS: AppIcon 1024x1024 без прозрачности и без скруглений (углы рисует система).
Запуск: python3 make_icons.py <public/icon.png> [папка design]
Нужны pillow и numpy.
"""
import os
import sys

import numpy as np
from PIL import Image

BONE = np.array([238, 233, 226], dtype=np.float64)
CORAL = np.array([255, 123, 69], dtype=np.float64)


def extract_glyph(src):
    im = np.asarray(Image.open(src).convert("RGB"), dtype=np.float64)
    h, w, _ = im.shape
    bg = np.repeat(im[:, 70:71, :], w, axis=1)  # цвет плашки по строкам (градиент сверху вниз)
    rgba = np.zeros((h, w, 4), dtype=np.float64)
    for y in range(110, 380):
        for x in range(100, 440):
            p = im[y, x]
            b = bg[y, x]
            for col in (BONE, CORAL):
                d = col - b
                a = float(np.clip(np.dot(p - b, d) / np.dot(d, d), 0.0, 1.0))
                # пиксель принадлежит цвету, если он близко лежит на отрезке плашка→цвет
                res = np.linalg.norm((b + a * d) - p)
                if a > 0.02 and res < 14.0 and a > rgba[y, x, 3] / 255.0:
                    rgba[y, x, :3] = col
                    rgba[y, x, 3] = a * 255.0
    ys, xs = np.nonzero(rgba[:, :, 3] > 8)
    box = (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1)
    glyph = Image.fromarray(rgba.astype(np.uint8), "RGBA").crop(box)
    top = tuple(int(v) for v in im[40, 70])
    bottom = tuple(int(v) for v in im[470, 70])
    return glyph, top, bottom


def fit(glyph, width):
    k = width / glyph.width
    return glyph.resize((width, max(1, round(glyph.height * k))), Image.LANCZOS)


def main():
    src = sys.argv[1]
    root = sys.argv[2] if len(sys.argv) > 2 else os.path.dirname(os.path.abspath(__file__))
    glyph, top, bottom = extract_glyph(src)
    print("glyph", glyph.size, "plate", top, bottom)

    # Android: передний слой 108dp * 4 = 432, знак в безопасной зоне (центральные 66%)
    fg = Image.new("RGBA", (432, 432), (0, 0, 0, 0))
    g = fit(glyph, 196)
    fg.alpha_composite(g, ((432 - g.width) // 2, (432 - g.height) // 2))
    os.makedirs(os.path.join(root, "res", "drawable-nodpi"), exist_ok=True)
    fg.save(os.path.join(root, "res", "drawable-nodpi", "ic_launcher_foreground.png"))

    # iOS: 1024, градиент плашки и знак по центру
    size = 1024
    col = np.zeros((size, size, 3), dtype=np.float64)
    for y in range(size):
        t = y / (size - 1)
        col[y, :, :] = np.array(top) * (1 - t) + np.array(bottom) * t
    base = Image.fromarray(col.astype(np.uint8), "RGB").convert("RGBA")
    g2 = fit(glyph, 560)
    base.alpha_composite(g2, ((size - g2.width) // 2, (size - g2.height) // 2))
    os.makedirs(os.path.join(root, "ios"), exist_ok=True)
    base.convert("RGB").save(os.path.join(root, "ios", "AppIcon-1024.png"))
    print("bg hex", "#%02x%02x%02x" % tuple(int(v) for v in ((np.array(top) + np.array(bottom)) / 2)))


if __name__ == "__main__":
    main()
