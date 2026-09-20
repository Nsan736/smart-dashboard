"""気象庁の震度観測点の一覧から、アプリに同梱するファイルを作り直す。

使い方(リポジトリの直下で):
    python scripts/update_jma_stations.py

- 取得元: https://www.data.jma.go.jp/eqev/data/intens-st/stations.json
  (気象庁のページが内部で使っているファイル。公式に配布されているデータセットではないので、場所や形式が変わることがある)
- 名前・緯度・経度・都道府県番号(1〜47)だけを抜き出し、SmartDashboard/Resources/jma_intensity_stations.json に書く
- 取得日を fetched に記録する
- 数か月に一度、手元で実行してコミットする(アプリは通信で取得しない)
"""
import datetime
import json
import sys
import urllib.request

SOURCE = "https://www.data.jma.go.jp/eqev/data/intens-st/stations.json"
OUTPUT = "SmartDashboard/Resources/jma_intensity_stations.json"


def main():
    request = urllib.request.Request(SOURCE, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(request, timeout=30) as response:
        stations = json.loads(response.read().decode("utf-8"))
    rows = []
    for station in stations:
        try:
            rows.append([station["name"], round(float(station["lat"]), 3), round(float(station["lon"]), 3), int(station["pref"])])
        except (KeyError, ValueError):
            continue
    if len(rows) < 3000:
        print(f"観測点が少なすぎます({len(rows)}件)。形式が変わった可能性があります。", file=sys.stderr)
        return 1
    rows.sort(key=lambda row: (row[3], row[0]))
    data = {
        "source": "気象庁 震度観測点の一覧 " + SOURCE + " から、名前・緯度・経度・都道府県番号だけを抜き出して加工",
        "fetched": datetime.date.today().isoformat(),
        "stations": rows,
    }
    with open(OUTPUT, "w", encoding="utf-8", newline="\n") as file:
        json.dump(data, file, ensure_ascii=False, separators=(",", ":"))
    print(f"{len(rows)}件を {OUTPUT} に書きました")
    return 0


if __name__ == "__main__":
    sys.exit(main())
