#!/usr/bin/env python3
"""Ставит APK в эмулятор, открывает разделы приложения ссылками blink://view/… и снимает экраны в shots/android.

Проверяет и главное для «как сайт, но без интернета»: приложение открывается в режиме полёта.
Запуск: android_tour.py <apk>. Нужны adb и запущенный эмулятор.
"""
import subprocess
import sys
import time
from pathlib import Path

PKG = "app.blink.player.alpha"
ACT = f"{PKG}/app.blink.player.MainActivity"
OUT = Path("shots/android")
OUT.mkdir(parents=True, exist_ok=True)
report = []


def adb(*args, check=False, capture=False, timeout=60):
    try:
        r = subprocess.run(["adb", *args], capture_output=True, text=not capture, timeout=timeout)
    except subprocess.TimeoutExpired:
        print(f"adb {' '.join(args)}: нет ответа за {timeout} с", flush=True)
        r = subprocess.CompletedProcess(args, 124, b"" if capture else "", b"" if capture else "")
    if check and r.returncode != 0:
        print(r.stdout, r.stderr)
        sys.exit(f"adb {' '.join(args)} failed")
    return r


def shot(name):
    png = adb("exec-out", "screencap", "-p", capture=True).stdout
    if png:
        (OUT / f"{name}.png").write_bytes(png)
    alive = bool(adb("shell", "pidof", PKG).stdout.strip())
    # Журнал после каждого шага: если приложение или эмулятор упадут, причина останется.
    log = adb("logcat", "-d", "-v", "time", "Capacitor:V", "Capacitor/Console:V", "chromium:V", "AndroidRuntime:E", "ActivityManager:I", "lowmemorykiller:V", "*:F", "*:S").stdout
    (OUT / "logcat.txt").write_text(log or "")
    report.append(f"{name}: {'ok' if alive else 'ПРИЛОЖЕНИЯ НЕТ'}")
    print(report[-1], flush=True)
    return alive


def link(url, wait):
    adb("shell", "am", "start", "-W", "-a", "android.intent.action.VIEW", "-d", f"'{url}'", PKG)
    time.sleep(wait)


def main():
    apk = sys.argv[1]
    adb("wait-for-device", check=True)
    adb("install", "-r", "-g", apk, check=True)
    adb("logcat", "-c")
    adb("shell", "am", "start", "-W", "-n", ACT, check=True)
    time.sleep(1.2)
    shot("00-intro")
    time.sleep(11)
    shot("01-home")
    tour = [
        ("02-search", "blink://view/search?q=%D0%A1%D0%BA%D1%80%D0%B8%D0%BF%D1%82%D0%BE%D0%BD%D0%B8%D1%82", 9),
        ("03-charts", "blink://view/charts", 8),
        ("04-me", "blink://view/me", 5),
        ("05-plus", "blink://view/plus", 5),
        ("06-settings", "blink://view/settings", 4),
        ("07-params", "blink://view/params", 4),
        ("08-account", "blink://view/account", 4),
    ]
    for name, url, wait in tour:
        link(url, wait)
        shot(name)
    # «Назад» закрывает вход, потом возвращает на прошлый раздел.
    adb("shell", "input", "keyevent", "KEYCODE_BACK")
    time.sleep(1.5)
    shot("09-back-closes-sheet")
    adb("shell", "input", "keyevent", "KEYCODE_BACK")
    time.sleep(1.5)
    shot("10-back-previous")
    # Без интернета: режим полёта, приложение закрыто и открыто заново.
    adb("shell", "cmd", "connectivity", "airplane-mode", "enable")
    adb("shell", "svc", "wifi", "disable")
    adb("shell", "svc", "data", "disable")
    time.sleep(2)
    adb("shell", "am", "force-stop", PKG)
    adb("shell", "am", "start", "-W", "-n", ACT)
    time.sleep(12)
    offline_ok = shot("11-offline-start")
    link("blink://view/me", 4)
    shot("12-offline-me")
    adb("shell", "cmd", "connectivity", "airplane-mode", "disable")
    adb("shell", "svc", "wifi", "enable")
    adb("shell", "svc", "data", "enable")
    log = adb("logcat", "-d", "-v", "time", "Capacitor:V", "Capacitor/Console:V", "chromium:V", "AndroidRuntime:E", "*:S").stdout
    (OUT / "logcat.txt").write_text(log)
    (OUT / "report.txt").write_text("\n".join(report) + "\n")
    failed = [r for r in report if not r.endswith("ok")]
    if failed or not offline_ok:
        sys.exit("приложение закрылось: " + ", ".join(failed))


if __name__ == "__main__":
    main()
