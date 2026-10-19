#!/usr/bin/env python3
"""スクリプト型の小ツールのサンプルを作る。

  python scripts/build_tool_examples.py

examples/tools/src/*.js(スクリプトの本体)と、下の TOOLS(名前・部品など)から、
examples/tools/<名前>.json と、テストのフィクスチャ SmartDashboardTests/Fixtures/tool_script_<名前>.json を書く。
JSON の文字列にスクリプトを手で埋め込むと、改行や引用符のエスケープを誤りやすいため。
あわせて、examples/tools のサンプル全部を1つにまとめた SmartDashboard/Resources/tool_samples.json(アプリに同梱し、
小ツールの「サンプル」の一覧から追加できるようにする)を書く。

組み込みのツールの JavaScript 版(v0.9.32): examples/tools/src/builtin/*.js の先頭に、共通の部品 _kit.js を付けて、
下の BUILTIN(名前・部品など)から examples/tools/builtin/<名前>.json と、アプリに同梱する
SmartDashboard/Resources/builtin_script_tools.json(小ツールの一覧に内蔵ツールとして並ぶ)を書く。
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


KIT_NOTE = "// ---- 共通の部品(_kit.js) ----\n"
TOOL_NOTE = "// ---- ここからツールの本体 ----\n"


def kit_text():
    return open(os.path.join(ROOT, "examples", "tools", "src", "builtin", "_kit.js"), encoding="utf-8").read()


def build_builtin(name, meta):
    script = KIT_NOTE + kit_text() + TOOL_NOTE + open(os.path.join(ROOT, "examples", "tools", "src", "builtin", name + ".js"), encoding="utf-8").read()
    tool = {"format": 1, "id": "builtin-js." + name, "name": meta["name"], "type": "script"}
    for key in ("description", "icon", "category", "keywords", "fps", "aspect", "controlsPosition", "controls"):
        if key in meta:
            tool[key] = meta[key]
    tool["script"] = script
    return json.dumps(tool, ensure_ascii=False, indent=2) + "\n"


BUILTIN_BUNDLE = os.path.join(ROOT, "SmartDashboard", "Resources", "builtin_script_tools.json")


def builtin_bundle_text():
    """組み込みのツールの JavaScript 版を、BUILTIN の順に1つの JSON にまとめる(legacy は以前の Swift の版の名前)"""
    tools = [{"file": name, "legacy": meta["legacy"], "json": build_builtin(name, meta)} for name, meta in BUILTIN.items()]
    return json.dumps({"tools": tools}, ensure_ascii=False, indent=1) + "\n"


# 組み込みのツールの JavaScript 版。legacy は以前の Swift の版の名前(一覧の ID "builtin.◯◯" と、保存データの移行に使う)。
BUILTIN = {
    "timer": {
        "legacy": "timer", "name": "タイマー", "icon": "timer", "category": "time", "fps": 15,
        "description": "複数のタイマー。閉じても進み、終わったら通知と音",
        "keywords": ["timer", "カウントダウン", "アラーム"],
        "controlsPosition": "top",
        "controls": [
            {"id": "duration", "type": "text", "label": "時間(例 5分、90秒、1時間30分、1:30:00)", "value": "5分"},
            {"id": "label", "type": "text", "label": "名前(省略可)", "value": ""},
            {"id": "add", "type": "button", "label": "追加して開始"},
            {"id": "notify", "type": "toggle", "label": "終わったら通知する", "value": True},
            {"id": "awake", "type": "toggle", "label": "画面を消さない", "value": False},
        ],
    },
    "stopwatch": {
        "legacy": "stopwatch", "name": "ストップウォッチ", "icon": "stopwatch", "category": "time", "fps": 30,
        "description": "経過時間とラップ。閉じても進む",
        "keywords": ["stopwatch", "ラップ", "計測"],
        "controls": [{"id": "awake", "type": "toggle", "label": "画面を消さない", "value": False}],
    },
    "time-calc": {
        "legacy": "timeCalc", "name": "時間計算", "icon": "clock.arrow.2.circlepath", "category": "time", "fps": 15,
        "description": "時間の合計、時刻に足す・引く、2つの時刻の間",
        "keywords": ["time", "じかん", "勤務時間", "合計", "何時間", "足し算"],
        "controlsPosition": "top",
        "controls": [{"id": "mode", "type": "choice", "label": "計算", "options": ["合計", "時刻に足す", "2つの時刻の間"], "value": "合計"}],
    },
    "date-calc": {
        "legacy": "dateCalc", "name": "日付計算", "icon": "calendar", "category": "time", "fps": 15,
        "description": "日数の差、◯日後、曜日と祝日",
        "keywords": ["date", "日数", "何日後", "曜日", "カレンダー"],
        "controlsPosition": "top",
        "controls": [{"id": "mode", "type": "choice", "label": "計算", "options": ["日数の差", "◯日後", "曜日"], "value": "日数の差"}],
    },
    "wareki": {
        "legacy": "wareki", "name": "和暦・西暦・年齢", "icon": "calendar.badge.clock", "category": "time", "fps": 15,
        "description": "令和・平成・昭和と西暦、年齢の変換",
        "keywords": ["wareki", "元号", "令和", "平成", "昭和", "年齢", "干支"],
        "controlsPosition": "top",
        "controls": [{"id": "mode", "type": "choice", "label": "変換", "options": ["西暦→和暦", "和暦→西暦", "年齢"], "value": "西暦→和暦"}],
    },
    "split-bill": {
        "legacy": "splitBill", "name": "割り勘", "icon": "person.2", "category": "calc", "fps": 15,
        "description": "人数で割り、端数の扱いを選べる",
        "keywords": ["warikan", "わりかん", "会計", "飲み会", "split"],
        "controlsPosition": "top",
        "controls": [
            {"id": "total", "type": "text", "label": "合計の金額(円)", "value": "12800", "keyboard": "number"},
            {"id": "people", "type": "slider", "label": "人数", "min": 2, "max": 30, "step": 1, "value": 4},
            {"id": "rounding", "type": "choice", "label": "1人あたりの単位(切り上げ)", "options": ["1円単位", "10円単位", "100円単位", "500円単位", "1000円単位"], "value": "100円単位"},
        ],
    },
    "percent": {
        "legacy": "percent", "name": "パーセント・割引・消費税", "icon": "percent", "category": "calc", "fps": 15,
        "description": "◯%引き、税込・税抜、何%か",
        "keywords": ["percent", "割引", "消費税", "税込", "税抜", "セール", "ぜい"],
        "controlsPosition": "top",
        "controls": [
            {"id": "price", "type": "text", "label": "値段(円)", "value": "1980", "keyboard": "decimal"},
            {"id": "off", "type": "slider", "label": "割引(%)", "min": 0, "max": 90, "step": 5, "value": 20},
            {"id": "tax", "type": "choice", "label": "消費税", "options": ["10%", "8%"], "value": "10%"},
            {"id": "a", "type": "text", "label": "何%か: この数は", "value": "30", "keyboard": "decimal"},
            {"id": "b", "type": "text", "label": "この数の", "value": "120", "keyboard": "decimal"},
        ],
    },
    "unit-convert": {
        "legacy": "unitConvert", "name": "単位換算", "icon": "arrow.left.arrow.right", "category": "calc", "fps": 15,
        "description": "長さ・重さ・温度・面積・体積・速度",
        "keywords": ["unit", "換算", "インチ", "ポンド", "マイル", "華氏", "坪"],
        "controlsPosition": "top",
        "controls": [
            {"id": "kind", "type": "choice", "label": "種類", "options": ["長さ", "重さ", "温度", "面積", "体積", "速度"], "value": "長さ"},
            {"id": "value", "type": "text", "label": "値", "value": "1", "keyboard": "number"},
        ],
    },
    "base-convert": {
        "legacy": "baseConvert", "name": "進数変換", "icon": "number", "category": "calc", "fps": 15,
        "description": "2進・8進・10進・16進と、2〜36進",
        "keywords": ["binary", "hex", "2進数", "16進数", "ビット"],
        "controlsPosition": "top",
        "controls": [
            {"id": "value", "type": "text", "label": "数", "value": "FF"},
            {"id": "base", "type": "choice", "label": "入れた数の進数", "options": ["2", "8", "10", "16", "その他"], "value": "16"},
            {"id": "custom", "type": "slider", "label": "その他の進数", "min": 2, "max": 36, "step": 1, "value": 36},
        ],
    },
    "roulette": {
        "legacy": "roulette", "name": "ルーレット", "icon": "arrow.triangle.2.circlepath.circle", "category": "play", "fps": 30,
        "description": "登録した項目から1つ選ぶ。くじ引きと履歴つき",
        "keywords": ["roulette", "抽選", "くじ", "ランダム", "選ぶ"],
    },
    "dice": {
        "legacy": "dice", "name": "サイコロ", "icon": "dice", "category": "play", "fps": 30,
        "description": "個数と面の数を指定",
        "keywords": ["dice", "さいころ", "ダイス", "乱数"],
    },
    "coin": {
        "legacy": "coin", "name": "コイントス", "icon": "circle.lefthalf.filled", "category": "play", "fps": 30,
        "description": "表か裏か。回数を数える",
        "keywords": ["coin", "こいん", "表裏", "おもてうら"],
    },
    "teams": {
        "legacy": "teams", "name": "チーム分け", "icon": "person.3", "category": "play", "fps": 15,
        "description": "メンバーをランダムにチームに分ける",
        "keywords": ["team", "グループ分け", "班分け"],
    },
    "order": {
        "legacy": "order", "name": "順番決め", "icon": "list.number", "category": "play", "fps": 15,
        "description": "メンバーをランダムな順に並べる",
        "keywords": ["order", "シャッフル", "じゅんばん", "発表順"],
    },
    "tournament": {
        "legacy": "tournament", "name": "トーナメント表", "icon": "trophy", "category": "play", "fps": 15,
        "description": "組み合わせを作り、勝者をタップで進める",
        "keywords": ["tournament", "とーなめんと", "対戦表", "シード", "勝ち抜き"],
    },
    "counter": {
        "legacy": "counter", "name": "カウンター", "icon": "plusminus.circle", "category": "play", "fps": 15,
        "description": "複数の数を数える",
        "keywords": ["counter", "かうんたー", "数取り", "カウント"],
        "controls": [
            {"id": "name", "type": "text", "label": "新しいカウンターの名前", "value": ""},
            {"id": "add", "type": "button", "label": "カウンターを足す"},
        ],
    },
    "amida": {
        "legacy": "amida", "name": "あみだくじ", "icon": "square.grid.3x3.middle.filled", "category": "play", "fps": 30,
        "description": "名前をタップして道をたどる",
        "keywords": ["amida", "アミダ", "くじ", "抽選", "当たり"],
    },
    "scoreboard": {
        "legacy": "scoreboard", "name": "スコアボード", "icon": "sportscourt", "category": "play", "fps": 15,
        "description": "2〜4チームの点とセット数",
        "keywords": ["score", "すこあ", "得点", "点数", "試合", "セット"],
    },
    "text-count": {
        "legacy": "textCount", "name": "文字数カウント", "icon": "textformat.123", "category": "text", "fps": 15,
        "description": "文字数、空白を除く、半角換算、行数、バイト数",
        "keywords": ["count", "もじすう", "文字数", "字数"],
        "controlsPosition": "top",
    },
    "kana-convert": {
        "legacy": "kanaConvert", "name": "文字の変換", "icon": "textformat.alt", "category": "text", "fps": 15,
        "description": "全角・半角・ひらがな・カタカナ。結果をコピー",
        "keywords": ["kana", "ぜんかく", "はんかく", "ひらがな", "カタカナ", "変換"],
        "controlsPosition": "top",
        "controls": [
            {"id": "mode", "type": "choice", "label": "変換", "options": ["ひらがな→カタカナ", "カタカナ→ひらがな", "全角→半角", "半角→全角"], "value": "ひらがな→カタカナ"},
            {"id": "alnum", "type": "toggle", "label": "全角・半角: 英数字と記号", "value": True},
            {"id": "kana", "type": "toggle", "label": "全角・半角: カタカナ", "value": True},
        ],
    },
    "password": {
        "legacy": "password", "name": "パスワード・乱数", "icon": "key", "category": "text", "fps": 15,
        "description": "文字の種類と長さを選んで作る。暗号に使える乱数",
        "keywords": ["password", "ぱすわーど", "乱数", "ランダム", "random"],
        "controlsPosition": "top",
        "controls": [
            {"id": "mode", "type": "choice", "label": "作るもの", "options": ["パスワード", "乱数"], "value": "パスワード"},
            {"id": "make", "type": "button", "label": "作り直す"},
        ],
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
    os.makedirs(os.path.join(ROOT, "examples", "tools", "builtin"), exist_ok=True)
    for name, meta in BUILTIN.items():
        with open(os.path.join(ROOT, "examples", "tools", "builtin", name + ".json"), "w", encoding="utf-8", newline="\n") as f:
            f.write(build_builtin(name, meta))
    with open(BUILTIN_BUNDLE, "w", encoding="utf-8", newline="\n") as f:
        f.write(builtin_bundle_text())
    print("書いた: builtin_script_tools.json(" + str(len(BUILTIN)) + "個)")


if __name__ == "__main__":
    main()
