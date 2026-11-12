#!/usr/bin/env python3
"""Пишет .env.production.local для сборки встроенного в приложение сайта.

Ключи берутся из секретов CI (BLINK_SUPABASE_ANON_KEY, BLINK_LASTFM_KEY), а если их нет, из живого сайта: это публичные
ключи, они и так отдаются каждому браузеру вместе со скриптами. В репозиторий их не кладём.
Запуск: site_env.py [путь к .env] [адрес сайта]. Только стандартная библиотека. Печатает, что нашлось, без самих ключей.
"""
import base64
import json
import os
import re
import sys
import urllib.request

OUT = sys.argv[1] if len(sys.argv) > 1 else ".env.production.local"
SITE = sys.argv[2] if len(sys.argv) > 2 else "https://blinkmusic.cc"
PROJECT_REF = "wjyohhvpqvfhyhrrbhgc"
SUPABASE_URL = f"https://{PROJECT_REF}.supabase.co"
JWT = re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}")
SCRIPT = re.compile(r"""(?:src|href)=["']([^"']+\.js)["']""")
IMPORT = re.compile(r"""["'](\./[\w.-]+\.js|/assets/[\w.-]+\.js|assets/[\w.-]+\.js)["']""")
HEX32 = re.compile(r"""["']([0-9a-f]{32})["']""")


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


def site_scripts():
    """index.html and every script it loads, plus the chunks those import (one level is enough for Blink)."""
    html = fetch(SITE)
    seen, texts = set(), []
    queue = list(dict.fromkeys(SCRIPT.findall(html)))
    while queue and len(seen) < 60:
        path = queue.pop(0)
        name = path.split("/")[-1]
        if name in seen:
            continue
        seen.add(name)
        url = SITE.rstrip("/") + "/assets/" + name
        try:
            text = fetch(url)
        except Exception as error:
            print(f"skip {url}: {error}", file=sys.stderr)
            continue
        texts.append(text)
        queue += [p for p in IMPORT.findall(text) if p.split("/")[-1] not in seen]
    return texts


def main() -> int:
    anon = os.environ.get("BLINK_SUPABASE_ANON_KEY", "").strip()
    lastfm = os.environ.get("BLINK_LASTFM_KEY", "").strip()
    if not anon or not lastfm:
        try:
            texts = site_scripts()
        except Exception as error:
            print(f"site unreachable: {error}", file=sys.stderr)
            texts = []
        for text in texts:
            if not anon:
                for token in JWT.findall(text):
                    data = payload(token)
                    if data and data.get("role") == "anon" and data.get("ref") == PROJECT_REF:
                        anon = token
                        break
            if not lastfm and "audioscrobbler" in text:
                at = text.find("audioscrobbler")
                found = sorted(HEX32.finditer(text), key=lambda m: abs(m.start() - at))
                if found:
                    lastfm = found[0].group(1)
    lines = [f"VITE_SUPABASE_URL={SUPABASE_URL}", "VITE_MEDIA_URL=https://blinkmusic.cc"]
    if anon:
        lines.append(f"VITE_SUPABASE_ANON_KEY={anon}")
    if lastfm:
        lines.append(f"VITE_LASTFM_KEY={lastfm}")
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    for key in (anon, lastfm):
        if key and os.environ.get("GITHUB_ACTIONS"):
            print(f"::add-mask::{key}")
    print(f"вход (Supabase): {'есть' if anon else 'НЕТ'}; Last.fm: {'есть' if lastfm else 'нет'}")
    return 0 if anon else 1


if __name__ == "__main__":
    sys.exit(main())
