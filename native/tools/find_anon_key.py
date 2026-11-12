#!/usr/bin/env python3
"""Достаёт публичный ключ входа (Supabase anon) из собранного сайта и печатает его в stdout.

Ключ публичный по задумке: он и так отдаётся каждому браузеру вместе со скриптами сайта. В репозиторий его не кладём,
а в сборку приложений он попадает на этапе CI. Берём только то, что подходит под проект Blink: JWT с role=anon и нужным ref.
Если ничего не нашли, молчим и выходим с кодом 1: сборка тогда идёт без входа.

Запуск: find_anon_key.py [адрес сайта]. Только стандартная библиотека.
"""
import base64
import json
import re
import sys
import urllib.request

SITE = sys.argv[1] if len(sys.argv) > 1 else "https://blinkmusic.cc"
PROJECT_REF = "wjyohhvpqvfhyhrrbhgc"
JWT = re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}")
SCRIPT = re.compile(r"""(?:src|href)=["']([^"']+\.js)["']""")


def fetch(url: str) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": "blink-ci/1.0"})
    with urllib.request.urlopen(request, timeout=25) as response:
        return response.read().decode("utf-8", "replace")


def payload(token: str):
    part = token.split(".")[1]
    part += "=" * (-len(part) % 4)
    try:
        return json.loads(base64.urlsafe_b64decode(part))
    except Exception:
        return None


def main() -> int:
    try:
        html = fetch(SITE)
    except Exception as error:
        print(f"site unreachable: {error}", file=sys.stderr)
        return 1
    pages = [html]
    for path in dict.fromkeys(SCRIPT.findall(html)):
        url = path if path.startswith("http") else SITE.rstrip("/") + "/" + path.lstrip("/")
        try:
            pages.append(fetch(url))
        except Exception as error:
            print(f"skip {url}: {error}", file=sys.stderr)
    for text in pages:
        for token in JWT.findall(text):
            data = payload(token)
            if data and data.get("role") == "anon" and data.get("ref") == PROJECT_REF:
                print(token)
                return 0
    print("anon key not found", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
