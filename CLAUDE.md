# スマートダッシュボード

iOS向けの個人用「手元ダッシュボード」アプリ。SwiftUI製。AltStore経由でLiveContainerに入れて使う。有料の開発者アカウントは使わない。

- リポジトリ: https://github.com/Nsan736/smart-dashboard (公開)
- Bundle ID: `com.nsan.smartdashboard` / 表示名: スマートダッシュボード
- iOS 17以上。Swift、SwiftUI、Swift Concurrency、Observation
- 外部SDK・ライブラリは使わない(Swift標準とApple純正フレームワークのみ)
- プロジェクトはXcodeGen(`project.yml`)で生成する。`.xcodeproj` はコミットしない

## 最重要方針: 通信量を最小にする

- 起動時とフォアグラウンド復帰時に、キャッシュが古いものだけを取得する。定期ポーリングはしない
- 最短の更新間隔: 天気30分、為替1日1回、運行情報5分、路線・駅の一覧は長期間キャッシュ、時刻表は手動更新のみ
- 取得結果はタイムスタンプ付きでディスクにキャッシュする。オフライン時は「◯分前の情報」と明示する
- APIリクエストは必要な項目・路線だけに絞る(クエリパラメータで絞れるものは必ず絞る)
- 画像・Webフォント・リモートのアイコンは取得しない。アイコンはSF Symbolsのみ
- 自動更新の方針(`RefreshPolicy`): モバイル通信(isExpensive)でも、最短の更新間隔を守ったうえで自動更新する。止めるのは次のときだけで、手動更新は常に使える
  - iOSの省データモード(isConstrained)のとき
  - 設定「Wi-Fi時のみ自動更新」(初期値オフ)がオンで、モバイル通信のとき
  - 設定「今月のモバイル通信量の上限」(初期値オフ)を超えていて、モバイル通信のとき(Wi-Fi時の自動更新はそのまま)
  - テザリングのようにWi-Fiでも従量制の回線は、モバイル通信として扱う。回線の状態が分かるまでは自動更新しない
  - 雨の要約(ナウキャスト、最短10分)も同じルールで自動更新する。地図タイルの自動保存だけは、従量制でない回線(Wi-Fiなど)のときに限る
- 設定画面に受信バイト数の累計(今日・今月)を表示する(URLSessionTaskMetricsで計測)
- 通信は必ず `HTTPClient` プロトコル(本番は `MeteredHTTPClient`)を経由する。`URLSession.shared` を直接使わない

## LiveContainerでの制約

- ウィジェット、Live Activity、App Extension、プッシュ通知(APNs)、バックグラウンド更新は使わない
- 位置・モーション・マイクなどの権限が取れなくてもクラッシュさせず、「利用不可」と表示し、他の機能は使えるようにする
- Info.plistに NSLocationWhenInUseUsageDescription、NSMotionUsageDescription、NSMicrophoneUsageDescription を入れておく

## 画面構成(TabView)

ホーム(まとめ) / 天気(Open-Meteo) / 為替(open.er-api.com、JPY基準、1日1回) / 電車(ODPT API v4) / センサー(すべて通信なし、表示中のみ動作) / タイマー / 設定

詳細:
- 天気: current / minutely_15 / hourly / daily は使う変数だけを指定し、リクエストは1回(15分値は2時間分、1時間値は24時間分、日別は7日分で日の出・日の入り・UV指数を含む)。位置は現在地(100m程度の精度で1回だけ取得して止める)か登録地点。天気コードはSF Symbolsと日本語ラベルに変換
  - 現在地の地名は CLGeocoder で求め、座標ごとにキャッシュして500m以上移動したときだけ再取得する
  - 雨の要約: 0〜60分は気象庁の高解像度降水ナウキャストで判定する(`RainNowcastStore`)。現在地を含む z10 のタイルを実況1枚と予測(5分刻み、60分先まで)の分だけ取得し、現在地とその周囲1ピクセルの色を降水の段階に変換する(`RainLevel`。配色は実タイルのPNGパレット、強度の区切り 1/5/10/20/30/50/80 mm/h は気象庁の凡例 https://www.jma.go.jp/bosai/nowc/images/legend_jp_normal_hrpns.svg で確認済み。表にない色は読めない扱いにする)。タイルのキャッシュはレーダー画面と共有し、自動更新は最短10分
  - 60分より先は Open-Meteo の値を使い「予報モデル」と明記する。ナウキャストが取れないときは Open-Meteo だけで表示し、その旨を小さく出す
  - Open-Meteo に models=jma_seamless は指定しない(2026-09-19に確認: 指定すると降水確率とUV指数がnullになる。日本では未指定でも降水量は同じ値)。15分値は1時間値からの補間なので、直近の判定には使わない
- 雨雲レーダー: 天気タブの中から開く(タブは増やさない)。気象庁の高解像度降水ナウキャストのタイルを地図に半透明で重ねる
  - 公式のAPIではない。取得に失敗したら「レーダーを取得できませんでした（気象庁側の仕様変更の可能性）」と表示し、他の機能に影響させない
  - タイルがあるのは偶数ズームの 4, 6, 8, 10 だけ(2026-09-19に実データで確認。奇数や11以上は空のタイルがHTTP 200で返る)。間のズームは1つ下の偶数ズームを拡大して描く
  - 専用画面を開いたときと手動更新のときだけ通信し、自動更新はしない。初期表示は最新の実況1枚だけ。予測はスライダーか再生で、表示範囲のタイルだけを読み込む
  - 同じ basetime のタイルはディスクにキャッシュし、basetime が変わったら古いものを削除する。1回の表示での受信量を画面に出す
  - 出典「気象庁」とリンク、凡例を表示する
- 地図: 回線の状態で自動的に切り替える(`MapMode.decide`)
  - 従量制でも省データでもない回線(Wi-Fiなど): Apple Maps(MapKit)
  - モバイル通信・省データモード・オフライン: Apple Mapsのタイルは読み込まず、端末に保存した地理院タイル(淡色地図、ズーム5〜18)だけで表示する(MKTileOverlay、canReplaceMapContent = true)。未保存の範囲はグレーの空白と「未ダウンロードの範囲」。通信しない
  - 切り替えても表示位置と縮尺を維持する。地図の隅に「Apple Maps」/「保存済み地図」を表示し、保存済み地図では出典「地理院タイル」をリンク付きで表示する
  - 設定「モバイル通信時も Apple Maps を使う」(初期値オフ)
  - 地理院タイルの保存は、アプリがフォアグラウンドにあり、従量制でも省データでもない回線のときだけ。同時接続は2本まで、保存済みはスキップ、回線が変わったら即停止。対象は日本全国の広域(ズーム5〜8)と登録エリア(中心と半径、ズーム9〜最大14〜16)、Apple Mapsで表示した範囲。保存容量の上限(初期値200MB)を超えたら止める
  - タイルは Application Support 以下に z/x/y.png で保存する。キャッシュ削除では消さない
- 為替: 「1外貨=◯円」で表示。初期ペアは USD、EUR、GBP、CNY、KRW。オフラインで動く換算機能。日次レートである旨と出典(ExchangeRate-API)を表示
- 電車の地図: 電車タブの上部に、登録路線を線で、登録駅をピンで描く。線は odpt:Railway の駅の順に odpt:Station の geo:lat / geo:long を結んで作り(`RailwayShape`)、端末に保存して毎回は取得しない(駅データのキャッシュは30日)。線の色は運行状況(平常=緑、遅延=黄、見合わせ・運休=赤、不明=グレー)、縁取りは odpt:color。遅延・見合わせは太くして点滅。路線や駅をタップすると本文や次の電車を表示する。一覧は状況が悪い順に並べ、一番上に全体の要約を1行で出す
- 電車: トークン不要の `api-public.odpt.org` と、トークン必要の `api.odpt.org`(`acl:consumerKey`)の両方に対応。事業者の定義はコード内の1か所(`OperatorCatalog`)にまとめる。路線・駅はコードに固定で書かず、設定画面で事業者→路線→駅→方面の順に選んで登録する。時刻表は手動で一度だけダウンロードして以後は通信なしで次発を表示。平日/土休日は自動切替(祝日は内蔵の簡易テーブル。12/30〜1/3 は設定で休日ダイヤ扱い、初期値オン)。電車画面の「今日のダイヤ」で手動切り替えでき、その日だけ有効(`DayTypeResolver`)。出典の表示を入れる
- ODPTの動作確認とフィクスチャには都営の公開エンドポイントを使う。トークンが必要な事業者のサンプルJSONはユーザーが用意する
- 不明な点(APIのレスポンス形式など)は推測で埋めない。公式ドキュメントを確認するか、ユーザーにサンプルJSONを求める
- タイマー: 終了時刻はDateで保持。ローカル通知 + アプリ内の音とバイブ。画面を消さないオプション。プリセット機能はない
  - 削除は各行のゴミ箱ボタンと確認ダイアログで行う(スワイプ削除と編集モードは使わない)。削除時は登録済みのローカル通知も取り消す
  - 行全体をTimelineViewで再描画しない(操作を妨げる)。再描画するのは残り時間の文字だけ
- センサー: バッテリーは表示しない(iOSのステータスバーで見られるため)
  - 速度: センサー画面とホームが表示されている間は、常にリアルタイムで表示する(開始・停止ボタンはない)。画面を離れたら測位を止める。`LocationSensors` は天気用の `LocationProvider` とは別のインスタンスで、desiredAccuracy = BestForNavigation、distanceFilter = None、activityType = .otherNavigation、pausesLocationUpdatesAutomatically = false
  - 速度の計算は `SpeedEstimator`(CoreLocationに依存しない純粋なロジック)。speedAccuracy が十分なら CLLocation.speed、無効なら直近の位置の差分から求め、3点で平滑化する。horizontalAccuracy の悪い点は除外する。屋内や地下などGPSで動きを検出できないときは、CMPedometer の currentPace から歩行速度を推定する。優先順位は (1) GPSの速度 (2) 位置の差分 (3) 歩行ペース (4) 停止中(0)または「測位中…」(`SpeedEstimator.reading`)。どの方法で出した値かを必ず表示し、位置の差分で停止と判定したときは理由(精度±◯mのため検出できない)も表示する。歩行ペースは最高・平均・距離にも使うが、GPSで動きが取れている区間では足さない(二重に数えない)。無効な速度を0と表示しない。最高・平均・距離は「画面を開いてからの値」でリセットできる
  - 位置の精度が「おおよそ」(reducedAccuracy)のときは、速度が測れない理由と設定の案内を表示する。GPSの状態(水平精度、最後の測位からの秒数)も小さく表示する
  - 歩数: CMPedometer.startUpdates(from: 今日の0時)で継続的に受け取る(最初の値だけは queryPedometerData で補う)。ペースと歩調も表示する。更新は数秒おきにまとめて届く旨を注記する
  - CLLocationManager のデリゲートはメインスレッドで呼ばれるので `MainActor.assumeIsolated` で同期的に状態を更新する。CMPedometer のコールバックは任意のスレッドなので、Sendable な値に詰め替えてから `Task { @MainActor in }` で更新する
  - センサー画面の表示中は画面を消さない(設定でオフにできる)。画面を消さない指定は `ScreenAwake` で理由ごとに管理し、タイマーと打ち消し合わないようにする。ホームで速度を表示するかどうかも設定で選べる(高精度のGPSは電池を多く使うため)
- 開発者向け: 運行情報の直近の応答(生のJSON)を1件だけ保存し、設定画面で表示・コピーできる(遅延時のサンプル収集用。追加の通信はしない)
- 設定: APIトークン、登録した地点・路線・駅・通貨ペア、地図(表示の切り替え、保存エリア、最大ズーム、容量の上限、進捗、削除、再ダウンロード)、自動更新ポリシー、受信バイト数、キャッシュ削除、各データの最終更新時刻

## 入力とレイアウト

- 入力欄のある画面には `.keyboardDismissable()` を付ける(キーボード上の「完了」、スクロールで閉じる)。入力欄の外のタップで閉じる処理は `KeyboardTapDismissInstaller` がアプリ全体で1つ受け持つ。改行キーのない数字キーボードの欄には `KeyboardCloseButton` も置く
- キーボードが結果を隠さないよう、入力欄とその結果は同じ行に置く
- 基準は最小の画面幅(幅320〜375pt)と、文字サイズを1〜2段階大きくした場合。固定幅や、1行に多くの要素を並べる作りは避ける。数値は lineLimit(1) と minimumScaleFactor、文章は省略せず折り返す。入りきらないときは `ViewThatFits` で2段にする
- ホームのカードの最小幅は280pt

## データ使用量の記録

- `MeteredHTTPClient` が URLSessionTaskMetrics の transactionMetrics(isCellular / isExpensive)で通信1回ごとに回線を判定し、通信先のホストから機能(天気、為替、電車、レーダー、地図タイル)を判定して `DataUsageStore` に記録する。従量制の回線はモバイル通信に含める
- 回線別に分ける前の記録は「回線不明」として残す
- 地名(CLGeocoder)と Apple Maps の通信はiOSが行うため計測できない。地名は取得回数だけを記録する
- 任意の設定で、今月のモバイル通信量が上限を超えたら自動更新を止める(初期値オフ)

## 永続化

- 設定: UserDefaults / AppStorage
- キャッシュと時刻表: Application Support以下にJSON
- トークン: Keychain。コードやリポジトリには絶対に書かない

## 秘密情報

トークンなどの秘密情報は絶対にコミットしない。フィクスチャにも含めない。`.gitignore` を維持する。

## テスト

- APIクライアントはプロトコルで抽象化する
- JSONデコードのユニットテストを用意する。フィクスチャは実際のレスポンスを小さく切り詰めたもの
- `@MainActor` なクラスの静的メンバーをテストから呼ぶときは、`nonisolated static` にするか、テスト側を `@MainActor` にする
- View に準拠した型は全体が `@MainActor` になる。テストしたいロジックは View の外(enum など)に置く
- ci のテスト先は画面の小さい iPhone SE を優先する
- テストに使うスレッド・並列数は10まで

## ビルドと検証(GitHub Actions)

開発機はWindowsでXcodeがないため、ビルドとテストの検証はGitHub Actionsで行う。
ただし Actions は「macOSでしかできないこと」だけに使い、回数を最小にする。

### ワークフロー

- `.github/workflows/ci.yml`: ビルドとテスト。トリガーは手動実行(workflow_dispatch)と pull_request だけ。mainへのpushでは動かさない
  - 1つのジョブで、シミュレーターでのテスト(起動は1回)と、実機向けの署名なしコンパイル確認を行う
  - paths-ignore で、ドキュメント(*.md)、apps.json、scripts などだけの変更では動かさない
- `.github/workflows/release.yml`: タグ `v*` のpushだけで動く。`xcodebuild -sdk iphoneos CODE_SIGNING_ALLOWED=NO` → `Payload/SmartDashboard.app` をzipして `SmartDashboard.ipa` → GitHub Releases → `apps.json` を更新してmainに直接コミット。テストはしないので、ci が成功したコミットにだけタグを付ける
- 共通: macos-15、Xcodeは明示的に選ぶ(現在 16.4)。XcodeGenは `HOMEBREW_NO_AUTO_UPDATE=1` でbrewから入れる(入っていれば入れない)。concurrency の cancel-in-progress: true、timeout-minutes: 20。ツール情報の表示や使わない成果物のアップロードなど不要なステップは置かない
- ipaのファイル名は固定(`SmartDashboard.ipa`)。`releases/latest/download/SmartDashboard.ipa` でも取得できる
- release.yml には `permissions: contents: write` を付ける(ci.yml は read)

### 実行の回数

- コミットは細かく分けてよいが、push と ci の実行は「段階の区切り」ごとに1回だけにする(指示があれば、全項目を実装してから最後に1回だけ)
- 実行は手動: `gh workflow run ci.yml --ref main`
- 実行する前に、Swiftの文法や型の誤り、Info.plist・project.yml の整合性を、コードを読んで自分で確認する
- 実行する前に `python scripts/check_local.py` を通す(フィクスチャのJSON、YAML、ワークフローのトリガー、apps.json生成、括弧の対応、@MainActor の静的メンバーをテストから呼ぶ誤り)。macOSが不要な確認をActionsで回さない
- 失敗したときは `gh run view --log-failed` でログから原因をまとめて特定し、関連する修正を1回で直してから再実行する。1行ずつ直して何度も回さない
- 段階の報告には、その段階で Actions を何回実行したかを書く

## 進め方

段階的に進める。各段階の区切りで1回だけ ci を実行し、ビルドとテストが通ることを確認する。

1. 骨組み(XcodeGen、TabView、設定、キャッシュ層、通信量の計測、ネットワーク状態の監視)とGitHub Actions
2. 天気と為替
3. タイマー
4. センサー
5. 電車(運行情報のあとに時刻表)
6. ホームのまとめ表示と仕上げ

## コミットメッセージ

- Conventional Commits 形式、本文は日本語。例: `feat: 天気画面を追加` / `fix: 為替キャッシュの期限判定を修正` / `ci: ipaのリリース処理を追加`
- 種類: feat / fix / refactor / test / ci / docs / chore
- 1コミットには1つのまとまった変更だけを入れる(1つの段階を複数のコミットに分けてよい)
- ワークフローによる apps.json の自動更新コミットは `chore: apps.json を v1.2.3 に更新 [skip ci]` の形にする

## コードの書き方

- コメントは日本語。絵文字は使わない
- 表示は日本語。ダークモード対応。主要な数値は大きく表示する
