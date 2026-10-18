#!/usr/bin/env python3
"""国土地理院の「日本の主な山岳標高(1003山)」から、アプリに同梱する山の一覧を作る。

  python scripts/update_mountains.py

https://www.gsi.go.jp/kihonjohochousa/kihonjohochousa41139.html の CSV(Shift_JIS)を取得し、
山名・山頂名・標高・緯度・経度・都道府県だけを SmartDashboard/Resources/mountains.json に書く。
出典: 国土地理院「日本の主な山岳標高」(国土地理院コンテンツ利用規約に従い、加工して利用)。
新しい版が出たら、下の CSV_URL と VERSION を変えて実行し、コミットする。
"""
import csv
import datetime
import io
import json
import os
import re
import ssl
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "SmartDashboard", "Resources", "mountains.json")
VERSION = "2026-03-31"
CSV_URL = "https://www.gsi.go.jp/KOKUJYOHO/MOUNTAIN/1003zan20260331.csv"
PAGE_URL = "https://www.gsi.go.jp/kihonjohochousa/kihonjohochousa41139.html"


def split_name(text):
    """「箱根山＜神山＞」→ ("箱根山", "神山")。「（」の別名は名前に残さない"""
    text = text.strip()
    peak = ""
    m = re.search(r"＜(.+?)＞", text)
    if m:
        peak = m.group(1)
        text = text[:m.start()] + text[m.end():]
    text = re.sub(r"（.*?）", "", text).strip()
    return text, peak


def main():
    req = urllib.request.Request(CSV_URL, headers={"User-Agent": "smart-dashboard (update_mountains.py)"})
    # www.gsi.go.jp は古い TLS の再ネゴシエーションを使うため、このサーバーへの接続だけ許可する
    context = ssl.create_default_context()
    context.options |= getattr(ssl, "OP_LEGACY_SERVER_CONNECT", 0x4)
    with urllib.request.urlopen(req, timeout=60, context=context) as r:
        raw = r.read()
    rows = list(csv.reader(io.StringIO(raw.decode("cp932"))))
    header, rows = rows[0], rows[1:]
    assert header[2].startswith("山名") and header[7] == "緯度" and header[8] == "経度", header
    mountains = []
    for row in rows:
        if len(row) < 9 or not row[7] or not row[8]:
            continue
        name, peak = split_name(row[2])
        mountains.append([
            name, peak,
            round(float(row[4]), 1),
            round(float(row[7]), 6), round(float(row[8]), 6),
            row[6].strip(),
        ])
    data = {
        "source": "国土地理院「日本の主な山岳標高」",
        "url": PAGE_URL,
        "version": VERSION,
        "fetched": datetime.date.today().isoformat(),
        "fields": ["name", "peak", "elevation", "latitude", "longitude", "prefecture"],
        "mountains": mountains,
    }
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
        f.write("\n")
    print(f"{len(mountains)}件、{os.path.getsize(OUT)}バイト -> {OUT}")


if __name__ == "__main__":
    main()
