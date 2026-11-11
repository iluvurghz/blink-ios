#!/usr/bin/env python3
"""Выбирает iPhone-симулятор на macOS-раннере: самая новая iOS, из моделей предпочитаем «Pro» без «Max».

Печатает одну строку: UDID, табуляция, имя. Нужен только в CI (`xcrun` есть лишь на macOS).
"""
import json
import subprocess
import sys


def main() -> int:
    raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"])
    runtimes = json.loads(raw)["devices"]
    best = None
    for runtime, devices in runtimes.items():
        if "iOS-" not in runtime:
            continue
        version = tuple(int(part) for part in runtime.split("iOS-")[1].split("-") if part.isdigit())
        for device in devices:
            name = device["name"]
            if not name.startswith("iPhone"):
                continue
            score = (version, "Pro" in name and "Max" not in name, name)
            if best is None or score > best[0]:
                best = (score, device["udid"], name)
    if best is None:
        print("нет доступных iPhone-симуляторов", file=sys.stderr)
        return 1
    print(best[1] + "\t" + best[2])
    return 0


if __name__ == "__main__":
    sys.exit(main())
