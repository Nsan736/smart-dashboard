# 小ツールのJSON形式(format 1)

スマートダッシュボードの「小ツール」には、JSONで書いたツールを読み込めます。
計算型・リスト型・表型・チェックリスト型の4つは、プログラムを実行しない形式です。決まった「型」に、中身を当てはめるだけです。
スクリプト型(`script`、v0.9.19)だけは、JavaScript を動かします(アプリが渡した機能だけを使えます)。

- 読み込んだツールは、通信・位置情報・カメラ・ファイル・アプリのほかのデータに、一切アクセスできません(そのための項目や機能がありません。スクリプト型でも同じです)。
- 計算式は、アプリ専用の小さな評価器で処理します。できるのは数の計算だけです。
- サンプルは [examples/tools/](../examples/tools/) にあります。

## 読み込み方

小ツールの一覧の一番下の「JSONのツールを読み込む」から、次のどれかで読み込みます。

- 「ファイル」アプリから選ぶ
- クリップボードから貼り付ける
- https のURLから取得する(ボタンを押したときだけ通信します)

保存する前に、名前・型・入力欄・式を確認する画面が出ます。形式に誤りがあると、どこが違うか(`outputs[0].formula` など)を表示します。
読み込んだツールは、開いた画面の右上のメニューから、書き出し(共有)、JSONの編集、削除ができます。

## 共通の項目

| 項目 | 必須 | 内容 |
|---|---|---|
| `format` | 必須 | `1` |
| `id` | 必須 | ツールを区別する名前。半角の英数字と `.` `_` `-`、60文字まで。同じ `id` を読み込むと、上書きします |
| `name` | 必須 | 表示する名前(40文字まで) |
| `type` | 必須 | `calc` / `list` / `table` / `checklist` / `script` |
| `description` | | 説明(200文字まで)。検索の対象になります |
| `icon` | | SF Symbols の名前(例: `fuelpump`)。省略すると工具のアイコン |
| `category` | | `time`(時間)/ `calc`(計算)/ `play`(決める・遊ぶ)/ `text`(文字)/ `measure`(測る)/ `other`(その他)。省略すると `other` |
| `keywords` | | 検索用の語の配列(30個まで)。ひらがな・カタカナ・全角半角・大文字小文字の違いは、検索のときに吸収されます |

全体の大きさは200KBまでです。

## 計算型(`calc`)

入力欄と、計算式・出力の書式を定義します。

```json
{
  "format": 1,
  "id": "fuel-economy",
  "name": "燃費計算",
  "type": "calc",
  "inputs": [
    { "id": "distance", "label": "走った距離", "type": "number", "unit": "km", "default": 400 },
    { "id": "fuel", "label": "給油量", "type": "number", "unit": "L", "default": 30 }
  ],
  "outputs": [
    { "label": "燃費", "formula": "if(fuel > 0, distance / fuel, 0)", "decimals": 1, "unit": "km/L" }
  ]
}
```

### 入力欄(`inputs`、20個まで)

| 項目 | 必須 | 内容 |
|---|---|---|
| `id` | 必須 | 式の中で使う名前。半角の英字か `_` で始まり、英数字と `_` だけ。関数名や `pi` とは別の名前にします |
| `label` | 必須 | 表示する名前 |
| `type` | 必須 | `number`(数)/ `choice`(選択肢)/ `date`(日付)/ `text`(テキスト) |
| `unit` | | 単位の表示 |
| `default` | | 最初の値(数) |
| `options` | `choice` で必須 | `{ "label": "2人", "value": 2 }` の配列(1〜30個)。式には `value` が渡ります |

式に渡る値:

- `number`: 入力した数(読めないときは `default`、なければ 0)
- `choice`: 選んだ選択肢の `value`
- `date`: 1970年1月1日からの日数。2つの日付の差は `days(a, b)` で出せます
- `text`: 文字数(メモ用の欄としても使えます)

### 出力(`outputs`、1〜20個)

| 項目 | 必須 | 内容 |
|---|---|---|
| `label` | 必須 | 表示する名前 |
| `formula` | 必須 | 計算式(500文字まで) |
| `decimals` | | 小数の桁数(0〜8、四捨五入)。省略すると 0 |
| `unit` | | 単位の表示 |
| `style` | | `number`(既定)か `days`(「◯日」と表示) |

### 式の書き方

| 種類 | 書き方 |
|---|---|
| 四則演算 | `+` `-` `*` `/` `%`(余り) |
| べき乗 | `^`(右から計算。`2^3^2` は `2^9`)。`-2^2` は `-4` |
| 括弧 | `( )` |
| 比較 | `<` `<=` `>` `>=` `==` `!=`(結果は、正しければ 1、違えば 0) |
| 論理 | `&&` `||` `!` |
| 条件分岐 | `if(条件, 真のときの値, 偽のときの値)`。条件に合うほうだけを計算します(0で割る式を避けるのに使えます) |
| 数学関数 | `abs` `sqrt` `pow(a, b)` `exp` `ln` `log10` `sin` `cos` `tan`(角度は度)`min(...)` `max(...)`(8個まで)`mod(a, b)` `clamp(x, 下限, 上限)` |
| 丸め | `round(x)` `round(x, 桁数)` `floor` `ceil` `trunc` |
| 日付 | `days(a, b)`(a から b までの日数) |
| 定数 | `pi` |

制限(超えるとエラーになり、計算しません):

- 式の長さ: 500文字まで
- 括弧や関数の入れ子: 32段まで
- 計算の回数: 1つの式につき5000回まで
- 繰り返し(ループ)や、自分自身を呼ぶ仕組みはありません
- 0で割ったとき、結果が数にならないとき(大きすぎる、負の数の平方根など)は、その出力だけエラーを表示します

## リスト型(`list`)

項目の一覧を定義し、どの使い方をするかを選びます。

| 項目 | 必須 | 内容 |
|---|---|---|
| `items` | 必須 | 文字列の配列(1〜500個) |
| `mode` | | `roulette`(1つ選ぶ。履歴つき。既定)/ `lottery`(引いたものを戻さないくじ引き)/ `order`(順番決め) |

```json
{ "format": 1, "id": "lunch-roulette", "name": "ランチのルーレット", "type": "list", "mode": "roulette",
  "items": ["ラーメン", "カレー", "定食"] }
```

## 表型(`table`)

参照用の表です。画面の上の検索欄で、どの列の文字でも絞り込めます。

| 項目 | 必須 | 内容 |
|---|---|---|
| `columns` | 必須 | 見出しの配列(1〜12個) |
| `rows` | 必須 | 行の配列(1000行まで)。各行は、列の数と同じ長さの配列(文字列か数) |

```json
{ "format": 1, "id": "clothing-size", "name": "服のサイズ表", "type": "table",
  "columns": ["日本", "アメリカ"], "rows": [["S", "XS"], ["M", "S"]] }
```

## チェックリスト型(`checklist`)

| 項目 | 必須 | 内容 |
|---|---|---|
| `items` | 必須 | 文字列の配列(1〜500個) |

チェックの状態は、端末に保存されます(ツールを削除すると消えます)。

## スクリプト型(`script`)

JavaScript で、アニメーション、模様(テクスチャ)、タップへの反応、簡単なゲームなどを作れます。
実行には iOS の JavaScriptCore を使います。外部のライブラリは読み込めません。

| 項目 | 必須 | 内容 |
|---|---|---|
| `script` | 必須 | スクリプトの本体(文字列、100,000文字まで)。JSON の文字列なので、改行は `\n`、`"` は `\"` と書きます |
| `controls` | | 入力の部品の配列(20個まで。下の「入力の部品」) |
| `controlsPosition` | | 部品を置く場所。`bottom`(キャンバスの下、初期値)か `top` |
| `fps` | | 1秒あたりのコマの数。15〜60、初期値30(iPhone SE 第2世代では30を勧めます) |
| `aspect` | | キャンバスの幅÷高さ(0.25〜4)。省略すると、空いている場所いっぱい |
| `permissions` | | 読みたいアプリのデータの種類の配列(下の「アプリのデータ」)。書いていない種類は読めません |

```json
{
  "format": 1,
  "id": "bouncing-ball",
  "name": "跳ねるボール",
  "type": "script",
  "category": "play",
  "controls": [ { "id": "speed", "type": "slider", "label": "速さ", "min": 50, "max": 400, "value": 200 } ],
  "script": "var x = 50, y = 50, vx = 1, vy = 1, speed = 200;\nfunction onInput(name, value) { if (name === 'speed') speed = value; }\nfunction frame(t, dt) {\n  x += vx * speed * dt; y += vy * speed * dt;\n  if (x < 20 || x > screen.width - 20) vx = -vx;\n  if (y < 20 || y > screen.height - 20) vy = -vy;\n  ctx.fillStyle = screen.dark ? '#000' : '#fff';\n  ctx.fillRect(0, 0, screen.width, screen.height);\n  ctx.fillStyle = 'tomato';\n  ctx.beginPath(); ctx.arc(x, y, 20, 0, Math.PI * 2); ctx.fill();\n}"
}
```

### 決まった関数

スクリプトの中で、次の名前の関数を作っておくと、アプリが呼びます(どれも省略できます)。

| 関数 | 呼ばれるとき |
|---|---|
| `setup()` | 始めたときに1回 |
| `frame(t, dt)` | 毎コマ。`t` は始めてからの秒数、`dt` は前のコマからの秒数(最大0.1) |
| `onTouch(event)` | 触れた・動かした・離したとき。`event.type` は `"down"` / `"move"` / `"up"`、`event.x` `event.y` はキャンバスの左上からの位置(pt) |
| `onInput(name, value)` | 入力の部品が変わったとき。`name` は部品の `id`。始めたときにも、各部品の初期値で1回ずつ呼ばれます |
| `onStop()` | 画面を閉じるとき |
| `onData(kind)` | アプリのデータが変わったとき(下の「アプリのデータ」) |

- 描いたものは、そのコマだけ表示されます(毎コマ、全体を描き直します)。1コマの中では、`onData` → `onInput` → `onTouch` → `frame` の順に呼ばれ、描いた命令がつながって1枚になります。そのコマで何も描かなければ、前の表示が残ります。
- 画面がバックグラウンドに回ると止まり、戻ると続きから動きます(止まっていた間の時間は `t` に含みません)。
- 例外が起きると、そのツールは止まり、画面に内容が出ます(「ログ」と「最初から」)。

### 描画(`ctx`)

ブラウザの Canvas 2D に近い書き方です。座標の単位は pt(左上が原点、右と下が正)。

- 図形: `fillRect(x, y, w, h)` `strokeRect` `clearRect` `beginPath()` `moveTo(x, y)` `lineTo` `quadraticCurveTo(cx, cy, x, y)` `bezierCurveTo(c1x, c1y, c2x, c2y, x, y)` `arc(x, y, r, start, end, anticlockwise)` `ellipse(x, y, rx, ry, rotation, start, end, anticlockwise)` `rect(x, y, w, h)` `closePath()` `fill()` `stroke()` `clip()`
- 文字: `fillText(text, x, y)` `strokeText` `measureText(text).width`。`font`(例: `"bold 24px sans-serif"`、`monospace` `serif` も可)、`textAlign`(`left` `center` `right`)、`textBaseline`(`alphabetic` `top` `middle` `bottom`)
- 線と色: `fillStyle` `strokeStyle`(CSS の色: `#rgb` `#rrggbb` `#rrggbbaa` `rgb()` `rgba()` `hsl()` `hsla()` と、よく使う色の名前)、`lineWidth` `lineCap` `lineJoin` `setLineDash([長さ, ...])` `globalAlpha`
- グラデーション: `createLinearGradient(x0, y0, x1, y1)` `createRadialGradient(x0, y0, r0, x1, y1, r1)` に `addColorStop(位置, 色)` を足して、`fillStyle` か `strokeStyle` に入れます(文字には最初の色が使われます)
- 変形: `save()` `restore()` `translate(x, y)` `rotate(ラジアン)` `scale(x, y)` `transform(a, b, c, d, e, f)` `setTransform(...)` `resetTransform()`
- 画像: `drawImage(img, x, y)` `drawImage(img, x, y, w, h)` `drawImage(img, sx, sy, sw, sh, dx, dy, dw, dh)`。`imageSmoothingEnabled = false` で、ドット絵をにじませずに拡大します

描画の命令は、スクリプトの中でまとめておき、1コマに1回だけアプリに渡します。1コマの命令は約20,000個までです(超えた分は描かず、ログに出ます)。

### 画像(`image`)・書き出し(`canvas`)

- `image.create(width, height, pixels)`: ピクセルの配列(`Uint8ClampedArray`、1ピクセルが R, G, B, A の4つ、長さは 幅×高さ×4)から画像を作ります。`{ id, width, height }` を返します
- `image.update(img, pixels)`: 同じ大きさのピクセルで描き直します
- `image.release(img)`: 使わなくなった画像を消します
- `image.exportPNG(img, { scale: 4, name: "pattern" })`: 画像を PNG にして共有シートを出します(`scale` は1〜16の整数倍。補間しないで拡大)
- `canvas.exportPNG({ width: 2048, name: "art" })`: 今の表示を、指定の幅(px、4096まで)の PNG にして共有シートを出します
- 上限: 1枚の大きさは 1〜1024px、32枚まで、合計32MBまで(超えると例外)

### 画面・入力の部品・音・振動・保存・乱数・ログ

- `screen.width` `screen.height`(キャンバスの大きさ、pt)、`screen.dark`(ダークモードなら true)、`screen.scale`(1ptのピクセル数)
- 入力の部品(スクリプトから): `ui.slider(id, { label, min, max, step, value })` `ui.button(id, { label })` `ui.toggle(id, { label, value })` `ui.text(id, { label, value })` `ui.choice(id, { label, options: [...], value })` `ui.set(id, value)` `ui.remove(id)`。変わると `onInput(id, value)` が呼ばれます(ボタンは value が true)
- 音: `sound.play(名前)`(`click` `pop` `beep` `coin` `success` `failure` `jump` `hit`)、`sound.tone(周波数Hz, 長さ秒, 音量0〜1)`(20〜8000Hz、2秒まで)。1秒に20回まで。ほかのアプリの音楽を止めません
- 振動: `haptic(種類)`(`light` `medium` `heavy` `success` `warning` `error` `selection`)
- 保存(このツールだけの領域): `storage.get(key)` `storage.set(key, value)`(JSON で表せる値) `storage.remove(key)` `storage.keys()` `storage.clear()`。合計256KBまで、キーは100文字・1000個まで。端末に書くのは2秒ごとと、閉じたとき
- 乱数: `random.seed(n)` `random.next()`(0以上1未満) `random.range(a, b)` `random.int(a, b)`(a以上b以下の整数) `random.pick(配列)`。`Math.random()` も使えます
- ログ: `console.log(...)` `console.warn` `console.error`。ツールの画面の「ログ」で直近300行を見られます

### 入力の部品(`controls`)

| 項目 | 必須 | 内容 |
|---|---|---|
| `id` | 必須 | 半角の英字か `_` で始まる、英数字と `_` だけの名前(30文字まで) |
| `type` | 必須 | `slider` / `button` / `toggle` / `text` / `choice` |
| `label` | | 表示する名前(40文字まで) |
| `min` `max` `step` `value` | | スライダーの範囲・刻み・初期値 |
| `value` | | 切り替えは true / false、文字は文字列、選択肢は選んでおく文字列 |
| `options` | | 選択肢の文字列の配列(`choice` のとき、1〜30個) |

### アプリのデータ(`app`、`permissions`)

スクリプトから、アプリがすでに取得・保存しているデータの写しを読めます。読むだけで、スクリプトから新しい通信は起きません。アプリのデータを書き換える機能はありません。

使う種類を、ツールの JSON の `permissions` に書きます(必要な種類だけを書いてください)。

```json
{ "format": 1, "id": "my-weather", "name": "天気", "type": "script", "permissions": ["weather"], "script": "..." }
```

| 種類 | 読めるもの |
|---|---|
| `weather` | 天気(今・1時間ごと・7日間)、雨の要約、警報・注意報(`app.weather` `app.warnings`) |
| `quake` | 最近の地震(`app.quakes`) |
| `pressure` | 端末で記録した気圧と、予報の気圧、今後3時間の変化(`app.pressure`) |
| `exchange` | 為替のレート(`app.exchange`) |
| `trains` | 登録した路線の運行情報、登録した駅の次の電車、列車の位置(`app.trains`) |
| `places` | 登録した地点の名前と、方角・距離・高低差(`app.places`) |
| `location.coarse` | おおよその地域: 都道府県と市区町村まで(`app.location`)。天気の地点名、警報の地域、地震の「現在地の都道府県の震度」もこれで入ります |
| `location.precise` | 現在地の緯度経度・高度・精度(`app.location`)。地点・天気の緯度経度もこれで入ります |
| `sensors` | センサー: 歩数・速度・方位・気圧計・加速度(`app.sensors`)。スクリプトが使い始めたときだけ動きます |

許可の扱い:

- 初めてツールを開いたときに、`permissions` に書いた種類の一覧を出して、利用者に許可を求めます(`location.precise` と `sensors` は目立たせて表示し、初めは選んでいない状態です)。読み込むときの確認の画面にも、一覧が出ます。
- 許可しなかった種類と、`permissions` に書いていない種類は、スクリプトからは `null` に見えます(ツールは止まりません)。まだ取得していないデータも `null` です。どのデータも `null` のときの表示を用意してください。
- 許可はツールごとに保存され、ツールの画面の「その他」→「データの許可」で変えたり、取り消したりできます。変えると、ツールは最初から動き直します。
- 保存する前の「動かしてみる」と、文章から作るときの試しの実行では、実際のデータではなく、それらしい仮のデータを渡します(仮のデータには `sample: true` が入ります)。
- `app.permissions` で、種類ごとに許可されたか(`true` / `false`)が分かります。例: `app.permissions["location.coarse"]`。

読み方:

- `app.weather` などは、読むたびに、その時点の最新のデータの写し(新しいオブジェクト)を返します。読むたびに JSON を作り直すので、毎コマ読まずに、`setup` と `onData` で変数に入れて使ってください。
- `onData(kind)`: データが変わったときに呼ばれます(`kind` は `"weather"` `"warnings"` `"quakes"` `"pressure"` `"exchange"` `"trains"` `"places"` `"location"` `"sensors"` `"calendar"`)。アプリの側で5秒ごとに確かめ、変わったときだけ呼びます(センサーは最短0.1秒ごと)。1コマの中では `onData` → `onInput` → `onTouch` → `frame` の順です。`setup` の時点で、すでにあるデータは読めます。
- 時刻は、すべて1970年1月1日からのミリ秒です(`new Date(値)` で日付になります)。各データの `fetchedAt` は、アプリが取得した時刻です。
- 何も描かないコマは前の表示が残るので、データが変わったときだけ描き直すと軽くなります。

データの形(件数には上限があります):

- `app.weather`: `{ fetchedAt, place, latitude, longitude, current, hourly, daily, rain }`
  - `place` は `location.coarse`、`latitude` `longitude` は `location.precise` を許可したときだけ(それ以外は `null`)
  - `current`: `{ time, temperature(℃), apparentTemperature, humidity(%), precipitation(mm), windSpeed(m/s), pressure(hPa), weatherCode, label(例: "晴れ"), symbol }`
  - `hourly`(1時間前から、48件まで): `{ time, temperature, precipitationProbability(%), weatherCode, label, pressure }`
  - `daily`(7件まで): `{ date, temperatureMax, temperatureMin, precipitationProbability, weatherCode, label, sunrise, sunset, uvIndexMax }`
  - `rain`: `{ headline(例: "今は降っていません。40分後から弱い雨"), later, note, nowcast, model }`。`nowcast`(気象庁のナウキャスト、13件まで): `{ time, level(0〜8), label, isForecast }`。`model`(予報モデルの15分ごと、8件まで): `{ time, precipitation(mm) }`
- `app.warnings`: `{ fetchedAt, reportedAt, area, maxLevel, maxLevelLabel, items }`。`items`(30件まで): `{ code, name(例: "大雨警報"), level(20=注意報、30=警報、40=危険警報、50=特別警報), levelLabel, status }`。`area`(`location.coarse` のときだけ): `{ prefecture, name, wholeCity }`
- `app.quakes`: `{ fetchedAt, items }`。`items`(新しい順、5件まで): `{ time, place, magnitude, depth(km), latitude, longitude, maxScale, maxScaleLabel(例: "5弱"), tsunami(文), revised, prefectures, localScale, localScaleLabel }`。`maxScale` は 10=震度1、20=2、30=3、40=4、45=5弱、50=5強、55=6弱、60=6強、70=7。`prefectures`(10件まで): `{ prefecture, scale, scaleLabel }`。`localScale` は現在地の都道府県の震度(`location.coarse` のときだけ)
- `app.pressure`: `{ fetchedAt, measuredAt, latest(hPa), measured, forecast, change3h }`。`measured`(直近24時間の実測、5分ごと、288件まで): `{ time, hPa }`。`forecast`(24時間前〜48時間後の予報、1時間ごと、72件まで): `{ time, hPa }`。`change3h`: `{ hours, delta(hPa), baseIsMeasured, text(例: "今後3時間の変化：−1.2hPa") }` か `null`
- `app.exchange`: `{ fetchedAt, updatedAt, base: "JPY", rates, all }`。`rates`(設定の通貨): `{ code, name, yen(1単位が何円か) }`。`all`(200通貨まで): `{ "USD": 147.1, ... }`
- `app.trains`: `{ fetchedAt, positionsAt, dayType, dayTypeLabel, lines, departures, positions }`
  - `dayType`: 今日のダイヤ `"weekday"` / `"saturday"` / `"holiday"`(`dayTypeLabel` は 平日 / 土曜 / 休日。年末年始の設定と、その日だけの手動の切り替えを反映)
  - `lines`(登録した路線、20件まで): `{ id, name, status("normal" / "delay" / "suspended" / "other" / "unknown"), statusLabel, statusText, text }`
  - `departures`(登録した駅、20件まで): `{ station, stationID, railwayID, railway, direction, trains }`。`trains`(5件まで): `{ time, minutes(あと何分), type, destination, isLast }`。保存した駅の時刻表から作るので、遅れは入りません
  - `positions`(時刻表から計算し、遅れで補正した列車の位置、60件まで): `{ id, railwayID, railway, number, type, destination, direction, delaySeconds, delayLabel, from, to, fraction(0〜1), stopped, next, nextArrival, platform }`
- `app.places`: `{ fetchedAt, origin, count, items }`。`items`(近い順、100件まで): `{ id, name, memo, color(例: "#FF3B30"), colorName, pinned, hidden, altitude(m), bearing(度、北=0), compass(例: "南西"), distance(m), heightDifference(m), latitude, longitude }`。方角・距離は、最後に分かった現在地(`origin`)からで、分からなければ `null`。`latitude` `longitude` は `location.precise` のときだけ
- `app.location`: `{ fetchedAt, prefecture, city, latitude, longitude, altitude, accuracy(m) }`。`prefecture` `city` は `location.coarse`、ほかは `location.precise` のときだけ。新しく測位はせず、最後に分かった位置です
- `app.calendar`(許可は要りません): `{ date("2026-10-18"), weekday(0=日曜), dayType, dayTypeLabel, holiday(祝日の名前か null), dayTypeOverridden, days, holidays }`。`days`(今日から14日分): `{ date, weekday, dayType, dayTypeLabel, holiday }`。`holidays`(今日から先の祝日、20件まで): `{ date, name }`
- `app.holidayName(年, 月, 日)` か `app.holidayName(Date)`: 祝日の名前(振替休日・国民の休日を含む)か `null`(許可は要りません)

センサー(`sensors` を許可したときだけ):

- `app.sensors.start(名前)` で使い始め、`app.sensors.stop(名前)` で止めます。名前は `"steps"` `"speed"` `"heading"` `"pressure"` `"motion"`。許可がないときは `false` を返します。ツールの画面を閉じると、すべて止まります(バックグラウンドでも止まり、戻ると動き直します)
- 値は `onData("sensors")` のあとに読みます。動かしていないセンサーと、値がまだ届いていないときは `null`
  - `app.sensors.steps`: `{ today(今日の歩数), distance(m), pace(秒/m), cadence(歩/秒), time }`
  - `app.sensors.speed`: `{ metersPerSecond, kmh, course(進む方角), accuracy, time }`(位置情報を使います)
  - `app.sensors.heading`: `{ degrees(端末の上が向いている方角、北=0), accuracy, time }`
  - `app.sensors.pressure`: `{ hPa, relativeAltitude(測り始めてからの高さの変化 m), time }`
  - `app.sensors.motion`: `{ x, y, z(重力を除いた加速度 G), pitch, roll, yaw(度), time }`
- `app.sensors.active`(動かしている名前の配列)、`app.sensors.available`(この端末で使えるか)、`app.sensors.problems`(使えない理由)

### 使えないもの・上限・固まったとき

- 使えないもの: 通信(`fetch` `XMLHttpRequest` `WebSocket`)、`setTimeout` `setInterval`、`document` `window`、`require` `import`、ファイル、カメラ、アプリのデータの書き換え。アプリのデータは、`permissions` に書いて許可された種類だけを読めます。時間で動かすときは `frame(t, dt)` を使います
- スクリプトは専用のスレッドで動き、画面の操作(閉じるボタンなど)は止まりません。1回の呼び出し(`setup` `frame` など)が2秒以上戻らないと「応答なし」と出て、閉じるボタンで実行を打ち切れます。端末の JavaScriptCore で実行時間の制限が使えるときは、5秒で自動的に止めます
- 実行中にアプリが落ちたとき(固まって終了した、メモリを使いすぎた、など)は、次に起動したときに「前回このツールの実行中に止まりました」と出て、そのツールを開かずに「もう一度試す」「無効にする」「削除する」を選べます。設定の「小ツール」で、スクリプト型のツールをすべて止めることもできます
- 軽く作るこつ(iPhone SE 第2世代を基準に): 1コマの図形は数百個まで、粒子(パーティクル)は数百個まで、`measureText` や `image.create` を毎コマ呼ばない、大きな画像は `setup` で1回だけ作る

## サンプル

| ファイル | 型 | 内容 |
|---|---|---|
| [fuel-economy.json](../examples/tools/fuel-economy.json) | 計算型 | 燃費、ガソリン代、1人あたり(選択肢と `if` `ceil` の例) |
| [days-until.json](../examples/tools/days-until.json) | 計算型 | 日付の差(`date` と `days` の例) |
| [clothing-size.json](../examples/tools/clothing-size.json) | 表型 | 服のサイズ表 |
| [travel-packing.json](../examples/tools/travel-packing.json) | チェックリスト型 | 旅行の持ち物 |
| [lunch-roulette.json](../examples/tools/lunch-roulette.json) | リスト型 | ランチのルーレット |
| [analog-clock.json](../examples/tools/analog-clock.json) | スクリプト型 | アナログ時計(変形と文字) |
| [bouncing-ball.json](../examples/tools/bouncing-ball.json) | スクリプト型 | 跳ねるボール(スライダー、タップで足す) |
| [fireworks.json](../examples/tools/fireworks.json) | スクリプト型 | 花火(パーティクル、タップで打ち上げ、効果音) |
| [pixel-walker.json](../examples/tools/pixel-walker.json) | スクリプト型 | ドット絵のアニメーション(`image.create` と `imageSmoothingEnabled`) |
| [pattern-maker.json](../examples/tools/pattern-maker.json) | スクリプト型 | 模様のテクスチャを作って PNG で書き出す道具 |
| [tap-target.json](../examples/tools/tap-target.json) | スクリプト型 | 出てくる的をタップするゲーム(最高点の保存、効果音、振動) |
| [weather-board.json](../examples/tools/weather-board.json) | スクリプト型 | 自分好みの天気の表示(`weather`。データが変わったときだけ描き直す) |
| [next-train.json](../examples/tools/next-train.json) | スクリプト型 | 登録した駅の次の電車のカウントダウン(`trains`、`app.calendar`) |
| [place-compass.json](../examples/tools/place-compass.json) | スクリプト型 | 登録した地点を指すコンパス(`places` と `sensors` の方位) |
| [pressure-graph.json](../examples/tools/pressure-graph.json) | スクリプト型 | 気圧の小さなグラフ(`pressure`。実測と予報) |
