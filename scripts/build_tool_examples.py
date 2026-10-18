#!/usr/bin/env python3
"""スクリプト型の小ツールのサンプルを作る。

  python scripts/build_tool_examples.py

examples/tools/src/*.js(スクリプトの本体)と、下の TOOLS(名前・部品など)から、
examples/tools/<名前>.json と、テストのフィクスチャ SmartDashboardTests/Fixtures/tool_script_<名前>.json を書く。
JSON の文字列にスクリプトを手で埋め込むと、改行や引用符のエスケープを誤りやすいため。
"""
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
    for key in ("description", "icon", "category", "keywords", "fps", "aspect", "controlsPosition", "controls"):
        if key in meta:
            tool[key] = meta[key]
    tool["script"] = script
    return json.dumps(tool, ensure_ascii=False, indent=2) + "\n"


def main():
    for name, meta in TOOLS.items():
        text = build(name, meta)
        for path in (os.path.join(ROOT, "examples", "tools", name + ".json"),
                     os.path.join(ROOT, "SmartDashboardTests", "Fixtures", "tool_script_" + name.replace("-", "_") + ".json")):
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write(text)
        print("書いた:", name)


if __name__ == "__main__":
    main()
