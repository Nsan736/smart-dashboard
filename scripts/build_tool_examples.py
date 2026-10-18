#!/usr/bin/env python3
"""スクリプト型の小ツールのサンプルを作る。

  python scripts/build_tool_examples.py

examples/tools/src/*.js(スクリプトの本体)と、下の TOOLS(名前・部品など)から、
examples/tools/<名前>.json と、テストのフィクスチャ SmartDashboardTests/Fixtures/tool_script_<名前>.json を書く。
JSON の文字列にスクリプトを手で埋め込むと、改行や引用符のエスケープを誤りやすいため。
あわせて、examples/tools のサンプル全部を1つにまとめた SmartDashboard/Resources/tool_samples.json(アプリに同梱し、
小ツールの「サンプル」の一覧から追加できるようにする)を書く。
"""
import glob
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

TOOLS = {
    "analog-clock": {
        "name": "アナログ時計", "icon": "clock", "category": "time", "fps": 15, "aspect": 1,
        "description": "端末の時刻で動くアナログ時計(スクリプト型のサンプル)",
        "keywords": ["とけい", "時計", "clock"],
    },
    "bouncing-ball": {
        "name": "跳ねるボール", "icon": "circle.circle", "category": "play",
        "description": "壁で跳ね返るボール。タップで足せます(スクリプト型のサンプル)",
        "keywords": ["ぼーる", "アニメーション"],
        "controls": [
            {"id": "speed", "type": "slider", "label": "速さ", "min": 50, "max": 400, "step": 10, "value": 200},
            {"id": "clear", "type": "button", "label": "すべて消す"},
        ],
    },
    "fireworks": {
        "name": "花火", "icon": "sparkles", "category": "play",
        "description": "パーティクルの花火。タップした所に打ち上げます(スクリプト型のサンプル)",
        "keywords": ["はなび", "パーティクル"],
    },
    "pixel-walker": {
        "name": "ドット絵のアニメーション", "icon": "figure.walk", "category": "play", "fps": 20,
        "description": "ピクセルの配列から作ったドット絵が歩きます(スクリプト型のサンプル)",
        "keywords": ["どっとえ", "ドット", "ピクセル"],
        "controls": [{"id": "size", "type": "slider", "label": "大きさ", "min": 2, "max": 10, "step": 1, "value": 6}],
    },
    "pattern-maker": {
        "name": "模様のテクスチャ", "icon": "square.grid.3x3", "category": "other", "fps": 15,
        "description": "模様の画像を作って、PNG で書き出します(スクリプト型のサンプル)",
        "keywords": ["もよう", "テクスチャ", "パターン", "png"],
        "controlsPosition": "top",
        "controls": [
            {"id": "kind", "type": "choice", "label": "模様", "options": ["チェック", "しま", "水玉", "ノイズ"], "value": "チェック"},
            {"id": "hue", "type": "slider", "label": "色合い", "min": 0, "max": 359, "step": 1, "value": 200},
            {"id": "export", "type": "button", "label": "PNGで書き出す(512×512)"},
        ],
    },
    "weather-board": {
        "name": "自分好みの天気", "icon": "cloud.sun", "category": "other", "fps": 15,
        "description": "アプリが取得した天気と警報を、自分好みの形で表示します(アプリのデータを読むサンプル)",
        "keywords": ["てんき", "天気", "気温", "警報"],
        "permissions": ["weather"],
        "controls": [{"id": "hours", "type": "choice", "label": "表示する時間", "options": ["12", "24", "48"], "value": "24"}],
    },
    "next-train": {
        "name": "次の電車のカウントダウン", "icon": "tram", "category": "time", "fps": 15,
        "description": "登録した駅の次の電車までの時間を、秒まで数えます(アプリのデータを読むサンプル)",
        "keywords": ["でんしゃ", "電車", "発車", "時刻表", "カウントダウン"],
        "permissions": ["trains"],
    },
    "place-compass": {
        "name": "地点を指すコンパス", "icon": "location.north.circle", "category": "measure",
        "description": "登録した地点の方向を、端末の方位に合わせて矢印で指します(アプリのデータとセンサーを使うサンプル)",
        "keywords": ["こんぱす", "方位", "方角", "地点"],
        "permissions": ["places", "sensors"],
    },
    "pressure-graph": {
        "name": "気圧の小さなグラフ", "icon": "barometer", "category": "measure", "fps": 15,
        "description": "記録した気圧と予報を、前後24時間の小さなグラフにします(アプリのデータを読むサンプル)",
        "keywords": ["きあつ", "気圧", "グラフ", "頭痛"],
        "permissions": ["pressure"],
        "aspect": 1.6,
    },
    "tap-target": {
        "name": "的あてゲーム", "icon": "target", "category": "play",
        "description": "30秒で、出てくる的をタップします。最高点を保存します(スクリプト型のサンプル)",
        "keywords": ["まと", "ゲーム", "タップ"],
        "controls": [{"id": "start", "type": "button", "label": "はじめから"}],
    },
}


def build(name, meta):
    script = open(os.path.join(ROOT, "examples", "tools", "src", name + ".js"), encoding="utf-8").read()
    tool = {"format": 1, "id": name, "name": meta["name"], "type": "script"}
    for key in ("description", "icon", "category", "keywords", "permissions", "fps", "aspect", "controlsPosition", "controls"):
        if key in meta:
            tool[key] = meta[key]
    tool["script"] = script
    return json.dumps(tool, ensure_ascii=False, indent=2) + "\n"


BUNDLE = os.path.join(ROOT, "SmartDashboard", "Resources", "tool_samples.json")


def bundle_text():
    """examples/tools/*.json を、ファイル名の順に1つの JSON にまとめる(中身は文字列のまま)"""
    samples = []
    for path in sorted(glob.glob(os.path.join(ROOT, "examples", "tools", "*.json"))):
        name = os.path.splitext(os.path.basename(path))[0]
        samples.append({"file": name, "json": open(path, encoding="utf-8").read()})
    return json.dumps({"samples": samples}, ensure_ascii=False, indent=1) + "\n"


def main():
    for name, meta in TOOLS.items():
        text = build(name, meta)
        for path in (os.path.join(ROOT, "examples", "tools", name + ".json"),
                     os.path.join(ROOT, "SmartDashboardTests", "Fixtures", "tool_script_" + name.replace("-", "_") + ".json")):
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write(text)
        print("書いた:", name)
    with open(BUNDLE, "w", encoding="utf-8", newline="\n") as f:
        f.write(bundle_text())
    print("書いた: tool_samples.json")


if __name__ == "__main__":
    main()
