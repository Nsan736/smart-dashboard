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

- 描いたものは、そのコマだけ表示されます(毎コマ、全体を描き直します)。1コマの中では、`onInput` → `onTouch` → `frame` の順に呼ばれ、描いた命令がつながって1枚になります。そのコマで何も描かなければ、前の表示が残ります。
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

### 使えないもの・上限・固まったとき

- 使えないもの: 通信(`fetch` `XMLHttpRequest` `WebSocket`)、`setTimeout` `setInterval`、`document` `window`、`require` `import`、ファイル、位置情報、カメラ、アプリのほかのデータ。時間で動かすときは `frame(t, dt)` を使います
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
