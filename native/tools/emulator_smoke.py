#!/usr/bin/env python3
"""Запускает собранный APK в эмуляторе и проверяет, что приложение живо.

Что делает: ставит APK, открывает его, ждёт первый экран, листает вкладки, вводит запрос в поиск,
снимает экран на каждом шаге и ловит падения. Снимки и отчёт кладёт в папку shots/ (SHOTS_DIR).
Падение приложения или не открывшийся первый экран делают прогон красным; остальное пишется в отчёт.
"""

import glob
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

PKG = os.environ.get("BLINK_PKG", "app.blink.player.alpha")
ACTIVITY = "app.blink.player.MainActivity"
OUT = os.environ.get("SHOTS_DIR", "shots")
BOUNDS = re.compile(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]")

os.makedirs(OUT, exist_ok=True)
report = []
problems = []


def log(msg):
    print(msg, flush=True)
    report.append(msg)


def adb(*args, check=True, timeout=120):
    r = subprocess.run(["adb", *args], capture_output=True, text=True, timeout=timeout)
    if check and r.returncode != 0:
        raise RuntimeError(f"adb {' '.join(args)} -> {r.returncode}: {r.stderr.strip() or r.stdout.strip()}")
    return r.stdout


def shot(name):
    r = subprocess.run(["adb", "exec-out", "screencap", "-p"], capture_output=True, timeout=60)
    if r.returncode == 0 and len(r.stdout) > 1000:
        with open(os.path.join(OUT, name + ".png"), "wb") as f:
            f.write(r.stdout)
    else:
        log(f"! снимок {name} не получился")


class Node:
    def __init__(self, el):
        self.text = el.get("text") or ""
        self.desc = el.get("content-desc") or ""
        self.cls = el.get("class") or ""
        self.clickable = el.get("clickable") == "true"
        m = BOUNDS.search(el.get("bounds") or "")
        self.box = tuple(int(v) for v in m.groups()) if m else (0, 0, 0, 0)

    @property
    def center(self):
        x1, y1, x2, y2 = self.box
        return (x1 + x2) // 2, (y1 + y2) // 2

    @property
    def height(self):
        return self.box[3] - self.box[1]


def dump():
    for _ in range(3):
        adb("shell", "uiautomator", "dump", "/sdcard/ui.xml", check=False, timeout=60)
        xml = adb("shell", "cat", "/sdcard/ui.xml", check=False)
        i = xml.find("<")
        if i >= 0:
            try:
                return [Node(e) for e in ET.fromstring(xml[i:]).iter("node")]
            except ET.ParseError:
                pass
        time.sleep(1)
    return []


def find(nodes, label):
    for n in nodes:
        if n.text == label or n.desc == label:
            return n
    for n in nodes:
        if label.lower() in n.text.lower() or label.lower() in n.desc.lower():
            return n
    return None


def wait_for(label, seconds=60):
    end = time.time() + seconds
    while time.time() < end:
        nodes = dump()
        n = find(nodes, label)
        if n:
            return nodes, n
        time.sleep(2)
    return [], None


def tap(x, y):
    adb("shell", "input", "tap", str(x), str(y))


def alive():
    return bool(adb("shell", "pidof", PKG, check=False).strip())


def crashes():
    out = adb("logcat", "-d", "-b", "crash", check=False)
    return out.strip()


def screen_texts(nodes):
    seen = []
    for n in nodes:
        for t in (n.text, n.desc):
            if t and t not in seen:
                seen.append(t)
    return seen


def step(name, nodes):
    shot(name)
    log(f"[{name}] на экране: " + " | ".join(screen_texts(nodes)[:40]))
    if not alive():
        problems.append(f"приложение упало на шаге {name}")
        log(f"! приложение не работает после шага {name}")
    c = crashes()
    if c:
        problems.append(f"в журнале падение на шаге {name}")
        log("! журнал падений:\n" + c[-3000:])


def screen_size():
    out = adb("shell", "wm", "size", check=False)
    m = re.search(r"(\d+)x(\d+)", out)
    return (int(m.group(1)), int(m.group(2))) if m else (1080, 2400)


def main():
    apks = sorted(glob.glob("apk/*.apk"))
    if not apks:
        print("нет APK в папке apk/")
        return 2
    log(f"APK: {apks[0]}")
    adb("install", "-r", "-g", apks[0], timeout=300)
    adb("logcat", "-c")
    w, h = screen_size()
    log(f"экран {w}x{h}")

    out = adb("shell", "am", "start", "-W", "-n", f"{PKG}/{ACTIVITY}", check=False)
    log("запуск: " + " ".join(out.split())[:200])

    nodes, home = wait_for("Поиск", 90)
    if not home:
        shot("00-first-screen-timeout")
        problems.append("первый экран не появился за 90 секунд")
        step("00-first-screen-timeout", dump())
    else:
        time.sleep(4)  # даём списку «Свежее» догрузиться
        step("01-search", dump())

        # вкладки внизу: по подписи, а если не нашли, по долям ширины
        for name, label, ratio in (("02-downloads", "Скачанное", 0.5), ("03-account", "Профиль", 0.85)):
            n = find(dump(), label)
            x, y = n.center if n else (int(w * ratio), h - 150)
            tap(x, y)
            time.sleep(3)
            step(name, dump())

        n = find(dump(), "Поиск")
        x, y = n.center if n else (int(w * 0.15), h - 150)
        tap(x, y)
        time.sleep(2)

        field = next((n for n in dump() if n.cls.endswith("EditText")), None)
        if field:
            tap(*field.center)
            time.sleep(1)
            adb("shell", "input", "text", "queen")
            time.sleep(7)  # дебаунс и ответ поиска
            adb("shell", "input", "keyevent", "KEYCODE_BACK")  # убрать клавиатуру
            time.sleep(1)
            nodes = dump()
            step("04-results", nodes)
            rows = [n for n in nodes if n.clickable and 120 <= n.height <= 320 and n.box[1] > h * 0.2 and n.box[3] < h * 0.88]
            if rows:
                tap(*rows[0].center)
                time.sleep(8)  # старт воспроизведения онлайн
                step("05-after-tap-on-track", dump())
            else:
                log("строки результатов не нашли, пропускаю шаг с воспроизведением")
        else:
            log("поле поиска не нашли")

    with open(os.path.join(OUT, "logcat.txt"), "w", encoding="utf-8") as f:
        f.write(adb("logcat", "-d", "-t", "1500", check=False))
    log("итог: " + ("ПАДЕНИЯ: " + "; ".join(problems) if problems else "приложение живо на всех шагах"))
    with open(os.path.join(OUT, "report.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(report) + "\n")
    return 1 if problems else 0


if __name__ == "__main__":
    try:
        code = main()
    except Exception as e:  # noqa: BLE001
        print("сбой скрипта:", e, file=sys.stderr)
        with open(os.path.join(OUT, "report.txt"), "a", encoding="utf-8") as f:
            f.write(f"сбой скрипта: {e}\n")
        code = 3
    sys.exit(code)
