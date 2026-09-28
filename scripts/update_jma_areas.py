"""気象庁の地域の一覧(area.json)から、警報・注意報の地域の表をアプリに同梱するファイルを作り直す。

使い方(リポジトリの直下で):
    python scripts/update_jma_areas.py

- 取得元: https://www.jma.go.jp/bosai/common/const/area.json
  (気象庁のページが内部で使っているファイル。公式に配布されているデータセットではないので、場所や形式が変わることがある)
- 市区町村(class20s)ごとに、コード・名前・府県予報区(class20 → class15 → class10 → offices とたどる)だけを抜き出し、
  SmartDashboard/Resources/jma_areas.json に書く(形式: {"source": ..., "class20": [[コード, 名前, 府県予報区], ...]})
- 取得日を source に記録する
- 市町村合併などがあったときに、手元で実行してコミットする(アプリは area.json を通信で取得しない)
"""
import datetime
import json
import sys
import urllib.request

SOURCE = "https://www.jma.go.jp/bosai/common/const/area.json"
OUTPUT = "SmartDashboard/Resources/jma_areas.json"


def main():
    request = urllib.request.Request(SOURCE, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(request, timeout=30) as response:
        area = json.loads(response.read().decode("utf-8"))
    rows = []
    try:
        for code, item in area["class20s"].items():
            class15 = item["parent"]
            class10 = area["class15s"][class15]["parent"]
            office = area["class10s"][class10]["parent"]
            rows.append([code, item["name"], office])
    except (KeyError, TypeError) as error:
        print(f"area.json の形式が変わった可能性があります: {error}", file=sys.stderr)
        return 1
    if len(rows) < 1500:
        print(f"市区町村が少なすぎます({len(rows)}件)。形式が変わった可能性があります。", file=sys.stderr)
        return 1
    data = {
        "source": f"気象庁 {SOURCE} ({datetime.date.today().isoformat()}取得)",
        "class20": rows,
    }
    with open(OUTPUT, "w", encoding="utf-8", newline="\n") as file:
        json.dump(data, file, ensure_ascii=False, separators=(",", ":"))
    print(f"{len(rows)}件を {OUTPUT} に書きました")
    return 0


if __name__ == "__main__":
    sys.exit(main())
