# スマートダッシュボード

iOS向けの個人用「手元ダッシュボード」アプリ。SwiftUI製。AltStore経由でLiveContainerに入れて使う。有料の開発者アカウントは使わない。

- リポジトリ: https://github.com/Nsan736/smart-dashboard (公開)
- Bundle ID: `com.nsan.smartdashboard` / 表示名: スマートダッシュボード
- iOS 17以上。Swift、SwiftUI、Swift Concurrency、Observation
- 外部SDK・ライブラリは使わない(Swift標準とApple純正フレームワークのみ)
- プロジェクトはXcodeGen(`project.yml`)で生成する。`.xcodeproj` はコミットしない

## 現在の状況と引き継ぎ

- 最新のリリースは **v0.9.31**(2026-10-19)。**v1.0.0 は、利用者が判断したときに付ける。それまでは 0.9.x で進める**(次は v0.9.32)。勝手に 1.0.0 にしない
- 新しい会話で作業を続けるときは、まず [docs/handoff.md](docs/handoff.md) を読む。次の内容をまとめてある
  - 実装済みの機能の一覧
  - 実機(iPhone SE 第2世代、LiveContainer)で確認済みの点と、まだ未確認の点。開発機は Windows で実機がないので、画面・センサー・MapKit・カメラの動作は、利用者の報告に頼っている。未確認のものを「動く」と書かない
  - 未着手の予定(ODPTのトークンは利用者が持っていて、開発側には渡さない。利用者の調べた結果は private/odpt/。トークンでの確認用のスクリプトは private/odpt_survey.py と private/odpt_survey_detect.py)
  - コードを読んだだけでは分からない設計判断と、その理由
  - 外部データの注意点(気象庁の非公式データ、ODPTの上限、同梱データの更新など)
- それ以外のアイデアと、見送った案の調査結果は、private/ideas.md を参照(Git の管理外で、このPCの中だけにある。中身をこのファイルや docs に書き写さない)
- 小ツールのJSONの形式は [docs/tools-format.md](docs/tools-format.md)。スコープのオブジェクトの JSON の形式は [docs/objects-format.md](docs/objects-format.md)
- 路線ごとの両数の表(出典つき)は [docs/railway-cars.md](docs/railway-cars.md)。同梱の `Resources/railway_cars.json` と同じ内容にしておく
- 機能を足したり、実機の報告を受けたりしたら、docs/handoff.md も更新する

## 最重要方針: 通信量を最小にする

- 起動時とフォアグラウンド復帰時に、キャッシュが古いものだけを取得する。定期ポーリングはしない
- 最短の更新間隔: 天気30分、為替1日1回、運行情報5分、警報・注意報10分、地震5分、路線・駅の一覧は長期間キャッシュ、時刻表は手動更新のみ
- キャッシュが古い形式で、今のアプリに必要な項目が欠けているとき(例: 天気の1時間値に気圧がない)は、更新間隔に関係なく取り直す(`WeatherSnapshot.hasRequiredFields`)
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
- バックグラウンドでの位置情報(UIBackgroundModes の location、allowsBackgroundLocationUpdates)は使わない。LiveContainer ではアプリの Info.plist が効かないことがあり、その状態で allowsBackgroundLocationUpdates を true にすると例外で落ちるため。移動の記録は移動タブの表示中だけ
- 例外として、気圧の記録のためのオプション(初期値オフ)でだけ、UIBackgroundModes の audio を使う。LiveContainer ではアプリの Info.plist が効かない可能性があるので、実際に記録が続いたかを記録の時刻から判定して表示する
- 位置・モーション・マイク・カメラなどの権限が取れなくてもクラッシュさせず、「利用不可」と表示し、他の機能は使えるようにする
- Info.plistに NSLocationWhenInUseUsageDescription、NSMotionUsageDescription、NSMicrophoneUsageDescription、NSCameraUsageDescription を入れておく

## 画面構成(TabView)

ホーム(まとめ) / 天気(Open-Meteo) / スコープ(地点・周辺・経路・電車・景色・オブジェクトの一覧と、カメラ表示) / 移動(以前の電車。ODPT API v4、乗車中の判定) / 為替(open.er-api.com、JPY基準、1日1回) / センサー(すべて通信なし、表示中のみ動作) / 小ツール(タイマーとストップウォッチを含む) / 設定

- タブの種類と初期の並びは `AppTab`。先頭の4つがタブバーに並び、残りはiOSの「その他」に入る(`TabOrder.barTabs` / `moreTabs`)。並びは設定の「タブの並び順」で変えられ、`AppSettings.tabOrder` に保存する。保存がなければ初期の並び。タブを増やすときは `AppTab` に足す(保存済みの並びには末尾に追加される)

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
- ホームのカード: 並び順と表示・非表示を `HomeLayout`(`AppSettings.homeLayout`)で持ち、ホームの「編集」から並べ替える(ドラッグ)。「初期状態に戻す」がある。新しいカードは `HomeCardKind` の末尾に足す(保存済みの並びには末尾に追加される)
  - 非表示にしたカードのデータは、起動時・復帰時・ホームの手動更新で取得しない(`HomeLayout.needs…`)。各タブを開いたときは、そのタブが自分で取得する。センサーも、非表示のカードの分は動かさない(速度のカードを隠したらホームでは高精度のGPSを動かさない)
  - 警報・注意報は天気を取得した地点の座標を使うので、警報のカードを出している間は天気も取得する
- 警報・注意報(`WarningStore`): 気象庁の https://www.jma.go.jp/bosai/warning/data/r8/{府県予報区}.json を使う。公式のAPIではない
  - 以前の https://www.jma.go.jp/bosai/warning/data/warning/{コード}.json は 2026-05-28 で更新が止まっている(2026-09-20に確認)。使わない
  - 応答は種類ごとの報(大雨、土砂災害、風、波、雷など)の配列。市区町村は warning.class20Items、コードと名称・段階(レベル2注意報=20、レベル3警報=30、レベル4危険警報=40、レベル5特別警報=50)の表は気象庁の警報ページのスクリプトから写した(`WarningCatalog`)。表にないコードは「不明」として出す。河川の氾濫(別ファイル)は扱わない
  - 色は気象庁に合わせる: 注意報=黄、警報=赤、危険警報=紫、特別警報=黒
  - 市区町村のコードは、逆ジオコーディング(既存の `PlaceNameResolver`、500mごとのキャッシュ)で得た都道府県名と市区町村名を、アプリに同梱した表(`Resources/jma_areas.json`、気象庁の area.json から市区町村と府県予報区だけを抜いたもの)と照合して決める(`WarningAreaResolver`)。area.json(転送時約51KB)は通信で取得しない
  - 気象庁が1つの市を複数の区域に分けている場合(横浜市北部・南部など、全国で約40市町)は、名前だけでは区域を決められないので、全区域を対象にして、その旨を表示する。決められない地点では推測せず、その旨を表示する
  - 自動更新は最短10分。取得に失敗したら「取得できませんでした」と表示し、ほかの機能に影響させない。出典「気象庁」を表示する
- 地震情報(`QuakeStore`): P2P地震情報 JSON API v2 の /history?codes=551&limit=10 を使う(転送時約3KB。気象庁の list.json は約20KBで件数を絞れない)。レート制限は60リクエスト/分で、自動更新は最短5分
  - 同じ地震に複数の報(震度速報、震源、各地の震度)が出るので、発生時刻でまとめて最大5件を表示する(`QuakeList`)。都道府県ごとの最大震度は points から作り、現在地の都道府県の震度を表示する
  - 取得した一覧は前回分と合わせ、直近24時間の分は残す(小さな地震が続いても、ホームの「震度◯以上」の対象が押し出されないようにする)
  - 同じ地震の報は、一番詳しく新しい報(各地の震度 > 震源・震度 > 震源 > 震度速報。同じ種類なら新しいほう)の内容を使い、その報にない項目だけをほかの報で補う(`QuakeList.combine`)。報の間や前回の取得から、震源地・マグニチュード・深さが変わったときと、訂正の報のときは「更新あり」と表示する
  - 詳細画面(`QuakeDetailView`): 天気タブの「最近の地震」とホームの地震カードの各行から開く。取得済みのデータだけを使い、追加の通信はしない(地図の表示を除く)。発生時刻・震源地・M・深さ・最大震度、津波(P2P地震情報の値を日本語にする。`QuakeTsunami`)、現在地との関係(天気を取得した地点から震源までの方角と距離。新しく測位はしない)、地図(既存の `MapContainerView`。震源=赤い×印、現在地=青い点、両方が入る範囲)、各地の震度(震度 → 都道府県 → 観測点の階層で折りたたみ。現在地の都道府県を先頭にして強調。`QuakeIntensityGroup`)、出典
  - 震度の色は気象庁の配色(`SeismicScaleStyle`)で、一覧・ホームのカード・詳細画面で同じ `QuakeScaleBadge` を使う
  - 気象庁のこの地震のページへの直接のリンクは作れない(ページの番号に発生時刻の秒までが必要で、P2P地震情報のデータには分までしかない)。気象庁の地震情報の一覧へのリンクを置く
  - 観測点ごとの震度の地図: 気象庁の震度観測点の一覧 https://www.data.jma.go.jp/eqev/data/intens-st/stations.json から、名前・緯度・経度・都道府県番号だけを抜き出して同梱する(`Resources/jma_intensity_stations.json`、4,368点、約175KB、取得日を fetched に記録)。通信では取得しない。作り直すときは手元で `python scripts/update_jma_stations.py` を実行してコミットする(気象庁のページが内部で使っているファイルで、公式の配布物ではないので、場所や形式が変わることがある)。出典と、加工していることを、アプリ内(詳細画面の地図の下)と README に書く
    - 観測点名で位置を対応付ける(`QuakeMapDots.make`。観測点名は全国で重複がなく、P2P地震情報の観測点名と約99%が一致。2026-09-20に確認)。対応しない観測点は地図に出さず、一覧だけに出して、その数を表示する
    - 描画はピンではなく、1枚の重ね描き(`IntensityDotsOverlay` / `IntensityDotsRenderer`。地図のタイルごとに、そのタイルに入る点だけを円で描く。点の大きさは縮尺に関係なく一定)。震度の小さい順に並べて描き、震度の大きい点が上に重なる。色は一覧と同じ `SeismicScaleStyle`(SwiftUI の色と UIKit の色を同じ値から作る)。地図の下に凡例を出す
  - ホームのカードは、直近24時間で、設定した震度以上(初期値は震度3)のものだけ。出典「P2P地震情報(気象庁の地震情報)」を表示する
- 気圧の変化: 実測(CMAltimeter)と予報(Open-Meteo の hourly surface_pressure。天気のリクエストに past_hours=24 と一緒に足してあり、リクエストは1回のまま)を1本の線でつなぐ(`PressureSeries`)
  - 実測は `PressureRecorder` がアプリの起動中に5分に1回記録し、7日分を Application Support に保存する(キャッシュ削除では消さない)。1日(UTC)ごとのファイルに分け、記録のたびに書くのは当日の分だけ(`PressureSampleCodec`、1件約25バイト)
  - 予報モデルの値(`PressureHistoryStore`、過去7日〜16日先、1時間ごと、1地点の分だけ)も端末に保存する。7日より古いものは削除する(以前の版で保存した100日分も、読み込んだときに7日分を残して削除する)
    - 詳細画面で主に見るのは予報。過去は直近4日分だけを表示する。以前の、過去100日分をまとめて取る仕組み(Historical Forecast API)は使わない
    - 過去の分は、天気の更新(past_hours=24 を含む)のたびに追記する。通信は増えない
    - 16日先までの予報(forecast_hours=384 が Open-Meteo の上限。2026-09-20に確認。末尾の約11時間は null で返るので捨てる)と、足りない過去の分は、詳細画面を開いたときだけ取る(最短3時間間隔、約2〜2.5KB)。過去の分は、表示する4日分の中の一番古い空白から現在までで、past_hours=24〜168(`PressureHistory.neededPastHours`)。途中の空白も埋められる
    - 50km以上離れた地点に変わったら、保存した分を捨てて、その地点で取り直す(気圧は標高で大きく変わり、別の地点の値とはつなげないため。実測の記録は消さない)
    - timeformat は unixtime のまま。gzip後の転送量はISO形式のほうが約6%小さいが(2026-09-20に計測)、時刻の解釈を天気と同じにしておくほうを選んだ
  - 詳細画面(`PressureDetailView`): 天気タブの気圧の節と、ホームの気圧カードから開く。横スクロールで、4日前の0時〜16日後の24時(21日間)。表示の幅は 1日/1週間/全体(初期値1週間)。開いたときと幅を切り替えたときは、「今」が左から25%の位置(右にスクロールすると先の予報)。日付の区切り(土曜=青、日曜・祝日=赤)、5hPaごとの横線、1013hPaの線、急な低下(3時間で設定値以上)の時間帯の色分け、未来は点線。下に表示中の期間の最高・最低・平均と、1日ごとの最高・最低
    - 描画は Swift Charts を使わず、Canvas の自前描画(iPhone SE2 でスクロールのフレームレートが落ちたため。Swift Charts は点・区切り線・目盛りが1つずつ部品になり、スクロールのたびに配置し直される)。1日ごとの区画(`PressureTile`、全体表示は1区画)を1枚の Canvas(`PressureTileView`、Equatable)で描き、LazyHStack を ScrollView で横スクロールさせる。スクロール中は描いた結果が動くだけで、描き直さない
    - 描画に使うデータ(1時間ごとの点、区画、急な低下の区間、縦軸の範囲)は、データか表示の幅が変わったときだけ作る(`rebuild` / `rebuildTiles`)。スクロール位置は View の状態に入れず(`PressureScrollTracker`)、止まって0.25秒たってから、集計の対象の期間だけを更新する。スクロール中に body を再評価させない
    - 点は1時間ごとが基本(21日で約500点)。1日表示のときだけ、その日の区画に細かい点(実測は5分ごと)を入れる。区画は画面に入るものだけが作られるので、細かく描くのは表示中の付近だけ。線は過去(実線)と未来(点線)の2本。縦軸の目盛りは、左端に固定した別の Canvas
    - 日付のラベルは1日ぶんの幅に収める(区画の外にはみ出すと切れるため。1週間表示は「20(土)」、全体表示は月曜と木曜だけ「9/21」)
    - 値の表示はタップだけ(SpatialTapGesture)。指を動かしたときは ScrollView の横スクロールになり、タップは成立しないので、スクロールの途中では値を表示しない。選んだ位置の印は Canvas とは別の小さな部品で、区画は描き直さない。別の場所をタップすると切り替わり、グラフの外(値の行や下の一覧)をタップするか、幅を切り替えると消える
  - 実測のある時間帯(±30分)は実測、それ以外は予報。予報の全体に「直近の実測 − 同じ時刻の予報」を足して、境目の段差をなくす。補正していることは、タップしたときの表示に書く
  - 「今後3時間の変化」の起点は、30分以内の実測(なければ予報)。設定した値以上(初期値は3時間で−4hPa)に下がるときは、ホームのカードを目立たせる
  - バックグラウンドでの記録(オプション、`BackgroundKeeper`): 無音のバッファを AVAudioEngine でループ再生する(.playback + .mixWithOthers)。中断・出力先の変更のあとは自動で再開する。電池残量20%未満、低電力モード、トグルのオフで止め、理由を表示する。騒音計(playAndRecord)が動いている間はカテゴリーを変えない
  - 閉じていた間(15分以上)に記録が続いていたかを `BackgroundRecordingCheck` で判定し、続いていなければ「この環境ではバックグラウンドで記録できないようです」と表示する
  - 歩数は CMPedometer に今日の0時からの分を問い合わせるので、閉じていた間の分も含まれる。バックグラウンドの処理は要らない
- 為替: 「1外貨=◯円」で表示。初期ペアは USD、EUR、GBP、CNY、KRW。オフラインで動く換算機能。日次レートである旨と出典(ExchangeRate-API)を表示
- 地図のピンの見た目は `MapMarkerStyle`(駅、登録した地点、震源、点)で選ぶ
- 移動タブ(v0.9.9 で電車タブから作り直した。タブの値 `AppTab.train`、表示の状態 `TrainDisplayState` の保存キーなどは以前のまま)。`TrainView`、`MovementViews.swift`
  - 画面の構成(v0.9.11): 切り替えのボタンを上端に固定し(List の外に置くので、スクロールしても残る)、その下を1つの縦スクロール(List)にする。List の最初の行が地図、その下が情報と設定。下へスクロールすると地図も一緒に上へ流れて隠れる
  - 地図の高さは、スクロールの見える高さの55%で220〜420pt(`TrainView.mapHeight`。iPhone SE では約260ptで画面の約4割、その下に情報の最初の数行が見える)
  - 地図の上をなぞったときは地図の操作、地図の外は画面のスクロール: 地図に指が触れている間だけ、外側の List のスクロールを止める(`ParentScrollLockRecognizer`、`MapContainerView(locksParentScroll:)`。自分では何も認識せず、ほかのジェスチャーの邪魔をしない)。地図は北が上のまま(回転はしない。列車の矢印の向きを地図の回転に合わせていないため)
  - List の行は画面の外に出ると作り直されることがあるので、地図の表示範囲を覚えておき、同じ範囲で開き直す(`MapRegionMemory`、`memoryKey`)
  - 地図の行が隠れたら、右下に「地図へ」のボタンを出して、上端へスクロールで戻る(`MovementScroll.map`)
  - 最上部: 「地図/路線図/記録」の切り替え、「すべて/登録駅/自分の近く」、路線の選択(`MovementControlBar`)
  - 地図: 路線の線・列車・駅に、乗車中の判定の結果とデバッグの表示を重ねる(`RideMapOverlay`)。路線図を選ぶと路線図(地図の行の高さに収めるため1路線ずつ)、記録を選ぶとその日の移動の線
  - 情報と設定: 選んでいる表示に合わせた情報と設定(`MovementLiveSections` / `MovementRecordSections`)。乗車中の情報、運行情報、登録した駅の次の電車、列車の位置と遅れの状態、設定(判定のオン・オフ、保存期間、登録の管理)、デバッグ
  - 駅をタップすると下部の段に駅の情報(`StationInfoSections`)、列車をタップすると列車の詳細(`TrainSelectionCard`。停車駅と到着予定、番線)を出し、そこまで自動でスクロールする(`MovementScroll.selection`)
- 駅に重ねる電車(v0.9.10): 地図を拡大したとき(ズーム14以上、`MapStationRule.stationTrainZoom`)、駅の点の左に、停車中と3分以内に着く電車の小さなアイコンを並べる
  - 選び方と並べ方は純粋なロジックの `StationTrainPlacement`: 行は番線の順(その駅の電車すべてで番線が分かるとき)か方面の順、行の中は停車中が先で、あとは着く順。1行3つまで(残りは「+n」)。始発駅で発車を待つ電車は出さない
  - アイコンは、形=種別(各停は丸み、ほかは四角)、文字=種別の短い文字+行先の頭文字(例: 急西)、色=遅れ(`TrainColors`)、塗りつぶし=停車中、枠だけ=まもなく着く
  - 描画は1枚の重ね描き(`StationTrainsOverlay` / `StationTrainsRenderer`。観測点の地図と同じ作り)。並びが変わったときだけ描き直す(毎秒の位置の変化では描き直さない)。タップは部品を使わず、アイコンの位置を計算して判定する(`Coordinator.stationTrainHit`)
- 駅の時刻表(v0.9.10、`StationDepartures`): 保存した列車ごとの時刻表(`LineSchedule`)から、どの駅でも作る(登録していない駅も)。前日の運行日の深夜の分・今日・翌日の運行日。方面ごとに今の時刻の付近から6本と、今の運行日(3時まで前の日)の始発・終電。遅れ(列車番号→秒)は、今の前後3時間の電車にだけ反映する(列車番号は毎日同じなので)。番線は `odpt:platformNumber`(`LineSchedule.Stop.platform`)
  - 「間に合う」(`CatchEstimator`): 駅までの時間 = 直線距離×係数(初期値1.3)÷歩く速さ(初期値 時速4.8km)+駅の中の移動(初期値2分)。「急げば」は速さを1.5倍。3段階(間に合う/急げば間に合う/間に合わない)。方面ごとに、次に間に合う電車までの残り時間を大きく出す。係数・速さ・駅の中の移動は設定(`AppSettings.walkRouteFactor` など、「徒歩と乗り換えの時間」)
  - 現在地は `MovementStore.currentPoint`(移動タブの表示中のGPS。仮想の移動の間は仮想の位置)。分からないときは「間に合う」を出さない
- 行きたい駅までの経路(v0.9.10、`JourneyStore` / `JourneyPlanner`)。保存した時刻表だけで、通信せずに計算する
  - 方式は Connection Scan Algorithm: 時刻表の接続(列車が、ある駅から次の駅へ行くこと)を出発の早い順に1回だけ調べる。乗った列車の数ごとに「その駅に一番早く着く時刻」を持つので、「早く着く」と「乗り換えが少ない」が1回で求まる。乗り換えは最大3回、調べる範囲は6時間。日をまたぐ場合のため、前日の運行日(24時以降)と翌日の運行日の列車も含める
  - 見つけた経路は、着く時刻を変えずに、途中の列車をできるだけ遅い列車に置き換える(`JourneyPlanner.tightened`。乗り換えの待ちを減らし、出発を遅らせる)
  - 結果は「早く着く」「乗り換えが少ない」の順、足りなければ「次の電車」で探し直して、最大3件。出発・到着、所要時間、乗り換えの回数、乗る列車(種別・行先・番線)、乗り換えの駅と待ち時間。最初の電車にも「間に合う」を付ける(出発の駅が現在地から3km以内のとき。検索の出発時刻は、急いで駅に着ける時刻)
  - 出発の駅は、開いている駅か、現在地の最寄り駅(`JourneyStore.OriginMode`)。行きたい駅は、駅と路線の検索(v0.9.14、下の「駅と路線の検索」)で選ぶ(`StationSearchSheet`。同じ名前の駅のまとまりを1つの行きたい駅にする)
  - 乗り換えの時間は設定(初期値5分、`AppSettings.transferMinutes`)。150mより離れた駅どうし(蔵前・三田・西巣鴨と新庚申塚など)は、その分の歩く時間を足す(`TransitDirectory.transferSeconds`)
  - 駅の一覧と乗り換えの関係(`TransitDirectory`、`TrainStore.ensureDirectory`): 事業者ごとの odpt:Station をまとめて取得し(都営で約13KB)、30日キャッシュする。乗り換えは odpt:connectingStation(駅IDまで分かる。片方にだけ書かれていても両方向に使う)。書かれていない同じ名前の駅は500m以内なら乗り換えとみなす
  - 足りない路線: 路線どうしのつながり(`railwaysOnShortestPaths`)から、経路に出てくる路線のうち時刻表のないものを出し、取得のボタンを出す。Wi-Fiなど従量制でない回線なら自動で取得する。足した路線は `TrainStore.routeRailways`(登録した路線とは別。地図の線と列車ごとの時刻表だけを保存し、遅れは取らない。設定の「経路の検索用の路線」で消せる)
  - 選んだ経路(`JourneyStore.selected`): 地図に区間ごとの線(藍色)を重ねる。乗車中の判定の列車が経路の列車(`JourneyLeg.tripID` と `TrainPosition.id` が同じ形)なら「予定どおり」。降りる駅の1駅前(次に止まる駅が降りる駅になったとき)に、区間ごとに1回、バイブと画面で知らせる(`JourneyTracking.alightAlert`。移動タブの表示中だけ)
  - デバッグ: 経路の結果の「この経路で仮想の移動」で、経路の列車に時刻表どおりに乗って動く(`JourneyMotion`、`MovementDebugSession.Kind.journey`。仮想の時刻は最初の電車の2分前から)。家の中で、判定・「予定どおり」・降りる駅の通知・駅の時刻表の「間に合う」を試せる
- 移動の記録と乗車中の判定(`MovementStore`)。位置の提供元は `MovementLocationSource` で抽象化し、実際のGPS(`GPSMovementSource`)とデバッグの仮想の移動(`VirtualMovementSource`)を差し替える
  - 位置は移動タブを表示している間だけ、高精度のGPS(BestForNavigation、distanceFilter なし)で取得し、直近10分をメモリに持つ。バックグラウンドでは取得しない(LiveContainer の制約を参照)
  - 判定(`RideDetector`。CoreLocation にも画面にも依存しない): 位置を路線の線(駅を結んだ線、`RideLine` / `GeoPath`)に投影し、線まで100m以内を、線に沿って時速15km以上で動く状態が30秒続いたら「乗車中の可能性あり」。進んだ向きで方面を決め、時刻表から計算して遅れで補正した列車の位置(`RideTrainCandidate`)のうち、同じ向きで一番近いもの(1500m以内)を照合する
    - 線路と並行する道路の対策: 駅以外(駅から250mより遠い所)で25秒以上止まったら判定をやり直し、その後10分は駅での停止を見るまで判定を出さない。駅での停止は判定を続け、確からしさを上げる
    - 確からしさ(高・中・低): 線までの平均の距離、照合した列車との距離、駅での停止、続いた時間、駅以外での停止から点数を付ける。手動で列車を選び直せる(`selectTrain`)
    - GPSが20秒途切れたら、照合した列車の時刻表の位置で推定を続け「推定中(GPSなし)」(最長30分)。位置が戻ったら推定との差を出し(答え合わせ)、1500mより離れていれば照合をやり直す。列車を照合していなければ判定を終える
    - 精度が80mより悪い位置は使わない
  - 表示(`RideInfo`): 種別・行先、進行方向、次の停車駅と到着予定(遅れを反映)、その次の数駅、登録した駅までの残りの駅数と時刻、今の速度と次の駅までの距離
  - 設定「乗車中の判定」(初期値オン、`AppSettings.rideDetectionEnabled`)
  - 記録(`MovementDay`、Application Support の movement/日付.json。端末の中だけで、外部には送らない): 点は5秒か25mごと。乗車と判定した区間(`MovementRide`)を残し、地図で色分けする(青=移動、オレンジ=乗車)。保存期間は 今日だけ/7日/保存しない(初期値は今日だけ、`AppSettings.movementRetention`)。GPX で書き出せる(共有シート)。デバッグの仮想の移動は記録しない
  - GPX(`GPXCodec`): GPX 1.1。精度と速さはアプリの拡張の要素(sd:acc、sd:spd)に入れる。読み込みは trkpt、なければ rtept、wpt。時刻のない点は1秒間隔
- 位置のデバッグ(設定の開発者向け「位置のデバッグ」、初期値オフ、`AppSettings.movementDebugEnabled`)。オンにすると、移動タブの下部にデバッグの操作、地図に途中の値が出る
  - 線を引く: 地図のタップで点を置く(番号の印をタップして選ぶと、次のタップで移す)、点ごとの停車、点の削除、全部消す。「路線に沿わせる」で2駅の間を駅を結んだ線にし、途中の駅に停車(`VirtualPlan.stationPlan`)。経路は UserDefaults に保存
  - 設定: 速さ、時間の倍率(1秒 = 1〜60秒)、位置のばらつき(±m)、GPSなしの区間(点の番号で指定)、仮想の時刻の開始(例: 平日の8時)。速さと倍率は動かしながら変えられる
  - 動かし方(`VirtualMover`、`VirtualClock`): 実時間に倍率を掛けた仮想の秒で進み、停車時間も仮想の秒で数える。列車の位置の計算と判定には仮想の時刻を使う(`MovementStore.currentTime`)
  - GPXの再生(`GPXReplay`): 記録の時刻の間隔のまま、倍率で早送りする。今日の記録もそのまま再生できる
  - 表示: 生の位置(精度の円つき)、線路に投影した位置、判定の途中の値(線までの距離、線に沿った速さ、継続時間、駅での停止、候補の列車と照合の距離)。仮想の移動の間は、実際の現在地を地図に出さず、画面の上部に赤い帯で「デバッグ中(仮想の位置)」と仮想の時刻を出す
- 線路の形(v0.9.11、`RailwayTrackCatalog`、`Resources/railway_shapes.json`): 国土数値情報の鉄道データ(N02、2025年度版、CC BY 4.0)から、使う事業者の路線だけを抜き出して同梱する。通信では取得しない
  - 作り方(`python scripts/update_railway_shapes.py Toei`。事業者を指定して抜き出せる。`--all` ですべて): ODPT の路線と N02 は、運営会社と路線名で対応付ける(`scripts/railway_shape_sources.json`。都営は「東京都」「1号線浅草線」など。横浜のブルーラインは「1号線」+「3号線」、副都心線は「13号線副都心線」+「8号線有楽町線」で両端の駅を指定)。N02 の線をつないだ網の上で、ODPT の駅の順に隣り合う駅の間の最短の道をつなぎ、1本の線にする(大江戸線のように同じ駅を2回通る路線も駅の順のまま)。線からのずれ5m以内で点を間引く。取得日(fetched)と元の版(source)を記録する。N02 の新しい版が出たら、手元で実行してコミットする
  - トークンが必要な事業者で環境変数 ODPT_TOKEN がないとき(または `--n02-stations`)は、N02 の駅(Station)で作る: 網の上で一番遠い2つの駅(対応表に terminals があればその2駅)の間の最短の道。線の向きが ODPT の駅の順と逆のことがあるので、アプリ(`RideLine.oriented`)が最初と最後の駅の位置で向きをそろえる。環状の区間がある路線には使えない
  - v0.9.12 の同梱: 都営6路線(ODPT の駅で作成)、東京メトロ10路線・横浜市営地下鉄2路線・つくばエクスプレス・りんかい線・多摩モノレール・ゆりかもめ(N02 の駅で作成)。22路線で約45KB(v0.9.11 の約13KBから +32KB、ipa の圧縮後で約+9KB)
  - 路線の線(`RideLine`)は、線路の形があればそれを使い、駅を線路の上の最も近い点に合わせる(`GeoPath.snap`)。駅は順に合わせ、前の駅より先の区間の「谷」(線に沿って近づいて離れる所)のうち、一番近い谷から100m以内の一番手前のものを選ぶ(環状の区間で先へ飛ばない)。線路の形がない路線は、今までどおり駅を結んだ直線
  - 路線の線は `TrainStore.rideLines()` / `rideLine(for:)` で1か所で作り置きし、地図の線・駅の点・駅に重ねる電車・列車の位置(`BoardLine.ride`。駅の間を線路の形に沿わせ、向きも線路の向き)・乗車中の判定・デバッグの「路線に沿わせる」(`VirtualPlan.stationPlan`。駅と、その間の線路の点)・「この経路で仮想の移動」・経路の線のすべてが使う
  - 出典と加工していることは、移動タブの下の出典(`ODPTAttributionView`)と README に書く
  - 線路の高さ(v0.9.17、`TrackProfile` / `TrackHeightModel`、`scripts/railway_heights.py`): 線路の形の各路線に `profile`(25mごとの地面の標高(0.1m単位の整数、データなしは null)と、区間の種類の切り替わり `kinds` [[始まりの番号, "g"|"e"|"u"|"?"]])を足してある。作り方は `python scripts/update_railway_shapes.py --all --heights-only`(線路の形は作り直さず、高さだけ付け直す。`--heights` は形と一緒に作る)。地理院のタイルは一時フォルダにキャッシュする
    - 地面の標高: 地理院タイルの標高タイル(PNG)。DEM5A(航空レーザー、z15)→ DEM5B(写真測量)→ DEM10B(z14)の順に、最初に値のあるもの。値は x = 2^16·R + 2^8·G + B、x < 2^23 なら x × 0.01m、x = 2^23 はデータなし、それより大きければ (x − 2^24) × 0.01m。レーザーの DEM は地面の点から作るので、高架の上ではなく下の地面の高さになる
    - 区間の種類: 国土地理院ベクトルタイル提供実験(experimental_bvmap、ズーム14、MVT)の鉄道中心線 railway の railState(0 通常部=地上、1 橋・高架=高架、2 トンネル・3 地下=地下、4 雪覆い=地上、ほか=不明)。線路の点から25m以内、向きの差35°以内で、路線の種類(rtCode の上5桁。地下鉄 40203、JR以外 40202/40205、路面 40204)が合う線を選ぶ。短い切り替わりは均す
    - 同梱の大きさ: railway_shapes.json が 45,333 → 118,017 バイト(圧縮後 13KB → 37KB、+24KB)。データなし(海の上の区間など)は、アプリで前後の点(250mまで)の値を使う
    - OSM(bridge/tunnel/layer)は使わない(ODbL の継承の条件が、同梱するデータ全体にかかるため)。深さや高架の高さのデータはないので、区間ごとの値は設定(`scopeElevatedHeight` 初期値8m、`scopeUndergroundDepth` 初期値15m)
    - 線路の高さ = 地面の標高 + 区間ごとの値(高架 +8m、地下 −15m、地上 0、不明は地面で「目安」)。地面の標高がなければ高さは出さない(`TrackHeightModel.height`)
    - `RideLine.profile` と `isReversed`(線路の形を駅の順に合わせて逆向きにしたとき、距離を逆にして引く)。`RideLine.trackHeight(atAlong:elevated:underground:)`、`BoardLine.trackHeight(of:)`
    - 出典(地理院タイル、ベクトルタイル提供実験、加工していること)は `ODPTAttributionView.heightAttribution`(移動タブとスコープの電車の画面)と README
- 電車の地図: 移動タブの地図に、登録路線を線で、登録駅をピンで描く。線は同梱した線路の形(なければ odpt:Railway の駅の順に odpt:Station の geo:lat / geo:long を結んだ線。`RailwayShape`)で、駅の形は端末に保存して毎回は取得しない(駅データのキャッシュは30日)。線の色は運行状況(平常=緑、遅延=黄、見合わせ・運休=赤、不明=グレー)、縁取りは odpt:color。遅延・見合わせは太くして点滅。路線や駅をタップすると本文や次の電車を表示する。一覧は状況が悪い順に並べ、一番上に全体の要約を1行で出す
- 電車の位置と遅れ(事業者に依存しない作り。事業者は自動で検出する。下の「ODPTの事業者の自動検出」)
  - 位置は時刻表から計算する。リアルタイムの在線位置(odpt:Train の fromStation / toStation)は使わず、読み込みもしない。リアルタイムのデータから使うのは遅れ(odpt:delay、秒)だけで、時刻表から計算した位置と到着予定を遅れの分だけ補正する(`TrainPositionCalculator`)
  - 列車ごとの時刻表(odpt:TrainTimetable)は、登録した路線の分だけ端末に保存する(`LineSchedule`、30日で取り直し、キャッシュ削除では消さない)。ダウンロードはWi-Fiなど従量制でない回線のときだけ自動、モバイル通信では手動だけ
  - odpt:TrainTimetable は1回の応答が1000件で打ち切られる(2026-09-19に確認)。カレンダー(Weekday / SaturdayHoliday / Saturday / Holiday)ごとに取得し、それでも1000件に達したら方面で分ける
  - 0時またぎ、祝日・年末年始・手動切り替えは、駅の時刻表と同じ仕組み(運行日基準の分、`DayTypeResolver`)
  - 遅れの取得は、電車タブとホームの電車カードを表示している間だけ(`TrainLiveStore.setVisible`)。最短の間隔はWi-Fiで2分、モバイル通信で5分。登録した路線だけに絞り、事業者ごとに1リクエスト。省データモードと、月のモバイル通信量の上限を超えたときは手動更新だけ
  - 列車の対応付けは列車番号(odpt:trainNumber)で行う。遅れの項目がない路線や odpt:Train がない路線(都営では荒川線、日暮里・舎人ライナー)では、運行情報で路線全体の状況を出し、列車は時刻表どおりの位置で「路線で遅延あり(列車ごとの遅れは不明)」と注記する。遅れの出どころ(リアルタイム / 時刻表どおり / 路線で遅延あり)を必ず表示する
  - 表示は「地図」と「路線図」を切り替えられる。電車は進行方向の分かるアイコン(色=遅れ、形とラベル=種別)で、1秒ごとになめらかに動かす。駅は点で描き、駅名は広域では主要駅と登録駅だけ。凡例は折りたためる
  - 表示の状態(地図/路線図、絞り込み、選んだ路線)は `TrainDisplayState` の1か所で持ち、地図と路線図で共有して保存する。切り替えの部品は、1秒ごとに描き直す TimelineView の外に置き、どちらの表示でも同じ位置に出す。地図では選んだ路線を強調してほかを薄くし、「すべての路線」も選べる。選んでいた路線が削除されたら「すべての路線」に戻す
  - 表示の絞り込み: すべて / 登録した駅に近い電車 / 自分の近くの電車(方面ごとに3本、「あと◯分で到着・◯駅前」)。最寄り駅は、電車タブを開いたときに現在地を1回だけ取得し、500m以上動いたときだけ判定し直す。選んだ表示は保存する
- 電車: トークン不要の `api-public.odpt.org` と、トークン必要の `api.odpt.org`(`acl:consumerKey`)の両方に対応。事業者は自動で検出し(`OperatorDiscoveryStore`)、`OperatorCatalog` は予備・上書き・除外だけ。路線・駅はコードに固定で書かず、設定画面で事業者→路線→駅→方面の順に選んで登録する。時刻表は手動で一度だけダウンロードして以後は通信なしで次発を表示。平日/土休日は自動切替(祝日は内蔵の簡易テーブル。12/30〜1/3 は設定で休日ダイヤ扱い、初期値オン)。電車画面の「今日のダイヤ」で手動切り替えでき、その日だけ有効(`DayTypeResolver`)。出典の表示を入れる
- ODPTの動作確認とフィクスチャには都営の公開エンドポイントを使う。トークンが必要な事業者のサンプルJSONはユーザーが用意する(private/odpt/samples。フィクスチャ `odpt_discovery.json` はそこから切り詰めて作った)
- ODPTの事業者の自動検出(v0.9.12、`OperatorDiscovery.swift`)
  - トークンを保存したとき(`AppEnvironment.setODPTToken`)と、「再検出」のボタンで調べる。結果は30日間使い、Application Support の odpt-discovery に保存する(キャッシュ削除では消さない。登録した路線の事業者を引くのに使うため)。期限切れの自動の検出は、起動時・登録の画面を開いたときに、従量制でない回線のときだけ(モバイル通信では「Wi-Fi接続時に検出します」)。手動はモバイル通信でも行う(1回あたり数十KB)
  - 手順(`OperatorDetection`、10リクエスト前後): odpt:Operator → odpt:Railway(絞り込まずに全件を1回で取り、対象の事業者の路線だけを使う) → odpt:TrainInformation と odpt:Train(路線のある事業者で絞る) → 各路線の最初の駅だけの odpt:Station(owl:sameAs。駅の位置と、odpt:stationTimetable の有無) → 走っている列車がない事業者だけ、駅時刻表を1つ(owl:sameAs、平日を優先) → 事業者ごとに2本までの odpt:TrainTimetable(odpt:train)。未対応の絞り込みは HTTP 400 になり、全件は返らない(2026-09-28に公開エンドポイントで確認)
  - カンマ区切りの絞り込み(OR)は1回に10件まで。11件以上は HTTP 400「too many OR condition in ...」(トークンありのエンドポイントで事業者34件を並べて発生、公開エンドポイントで10件と11件の境目を確認)。すべての問い合わせは `ODPTQuery.chunks` で10件ずつに分ける(検出、運行情報、遅れ、駅名の引き当て)。絞り込みの値が空だと 200 で空の配列が返り、失敗に気づけないので、値がなければ問い合わせない
  - どれかの段階が失敗したら、そこで中止し(あとの段階を0件として扱わない)、「◯◯が取れなかったため、検出を中止しました」と、失敗したリクエストのURL(トークンを除く)・応答の本文を表示する。前回の結果はそのまま使う。無効なトークンは HTTP 403「Invalid acl:consumerKey.」
  - 使えるデータ(`ODPTCapabilities`、路線ごと): 運行情報=その路線(または路線のない事業者全体)の odpt:TrainInformation がある。列車ごとの時刻表=その事業者の odpt:TrainTimetable が返った。駅の時刻表=最初の駅に odpt:stationTimetable がある。地図=最初の駅に geo:lat/long がある。遅れ=その路線の odpt:Train に odpt:delay がある(列車はあるが項目がなければ「なし」。その事業者の列車が1本もないときは、ほかの事業者の列車が走っていて日本時間7〜22時なら「なし」、それ以外は未確認で、遅れの取得を試す)
  - 除外: 「公共交通オープンデータチャレンジ」限定ライセンスの事業者(`OperatorCatalog.challengeOnly`: JR東日本、京王、小田急、京急、相鉄、東武、西武、東急。2026-09-28に ckan.odpt.org のデータセットのライセンスで確認)は、最初に外す。運行情報・時刻表のどちらもない事業者(駅名だけが返る事業者)も外し、理由を登録の画面に出す。路線のない事業者(バス・航空)は出さない
  - `OperatorCatalog` は、検出できなかったときの予備(都営=公開エンドポイント、東京メトロ)と、表示名・並び順・エンドポイントの上書き(都営は公開エンドポイントのまま。トークンが無効でも使える)だけ。事業者の引き当ては `TrainStore.operatorInfo` / `OperatorDirectory.resolve`(一覧にないIDも、トークンが必要な事業者として返す)
  - トークンが無効・期限切れ(HTTP 401/403)のときは、その旨を表示し、公開エンドポイントで検出し直して都営を使えるようにする。トークンがないときも公開エンドポイントで検出する
  - 使えないデータは、機能を出さずに理由を出す: 運行情報がない路線は運行情報の登録を出さない。時刻表がない路線は駅の選択を出さず「運行情報のみ登録」。列車ごとの時刻表がない路線(ゆりかもめ)は、列車の時刻表のダウンロード・列車の位置・経路の検索をしない。遅れがない路線は odpt:Train を取らず、荒川線と同じく運行情報で路線全体の状況(`TrainLiveStore.markUnsupportedDelays`)。駅の位置がない路線は路線の形を取らない
  - 事業者をまたぐ経路: 駅の一覧(`TrainStore.ensureDirectory`)に、使っている事業者と、検出した事業者のうち列車ごとの時刻表があるものの駅を入れる(使っていない事業者の駅は、行きたい駅の検索を開いたときか、従量制でない回線のとき。30日キャッシュ)。乗り換えは従来どおり odpt:connectingStation と同じ名前で500m以内。経路の路線のつながりは、列車ごとの時刻表がある路線だけで作る(`railwaysOnShortestPaths(allowed:)`)
  - 登録の画面(`TrainRegistrationView.swift`): 事業者の一覧(使えるデータのラベル: 運行情報/時刻表/遅れ/地図、使わない事業者と理由)→ 路線の一覧(odpt:color の色、名前で検索)→ 駅と方面。路線の一覧は検出のときの応答を使い、取り直さない。設定の「使える事業者(自動検出)」に、路線ごとの結果。事業者の一覧の上に、駅と路線の検索欄(v0.9.14)
- 駅と路線の検索(v0.9.14、`StationSearch.swift` / `StationSearchViews.swift`)
  - 対象: 検出した事業者すべての駅と路線(登録していない路線も)。照合は索引(`StationSearchIndex`)だけで行い、通信しない。索引は駅の一覧を読み込んだときに1回だけ作る(バックグラウンドのスレッド)。入力のたびに行うのは、作り置きした文字列との比較だけ
  - 探せるもの: 駅名・路線名(部分一致)、英語名(stationTitle / railwayTitle の en)、読み仮名(ja-Hrkt。2026-09-28の時点では東京メトロの駅だけにある。同じ名前の駅をまとめるので、都営の同じ名前の駅も読み仮名で出る)、駅ナンバリング(odpt:stationCode)、ODPT の ID(一部分でも。「odpt.Station:」なしでも)
  - 正規化は小ツールと同じ `ToolSearch.normalize`(小文字、全角→半角、カタカナ→ひらがな、空白・長音・中点を除く)。そのうえで英数字と文字だけを残した形でも比べる(「E27」で「E-27」、「nishimagome」で「Nishi-magome」)
  - 結果: 同じ名前の駅を1行にまとめ(名前を正規化して同じなら同じ行。乗り換えの関係は見ない)、その下に路線ごとの駅(路線の色・路線名・事業者名・駅ナンバリング)。並びは 完全一致 → 前方一致 → 部分一致、同じなら登録済みの路線(`TrainStore.registeredRailways`)の駅を含むもの、あとは名前の順。行の中も登録済みの路線の駅が先
  - 駅の一覧(`TrainStore.ensureStationCatalog`): 事業者ごとの odpt:Station を、エンドポイントごとに事業者10件ずつまとめて取得し(`api.stations(operatorIDs:)`)、事業者ごとに30日保存する(キー `operatorStations2.<事業者>`。経路の検索の駅の一覧 `ensureDirectory` と共有。v0.9.14 で駅ナンバリングと読み仮名を読むようにしたので、キーを変えて取り直す)。キャッシュの削除で消える(次に Wi-Fi で取り直す)。自動の取得は、検出のあと(`OperatorDiscoveryStore.onDetected`)と検索の画面を開いたときに、従量制でない回線のときだけ。モバイル通信では検索の画面に「駅の一覧を取得」のボタン
  - 使う場所: 路線の登録(事業者の一覧の上の検索欄。駅を選ぶと、路線ごとに方面を選んで登録。時刻表のない路線は「運行情報のみ登録」の画面へ。路線を選ぶと駅の一覧へ)、行きたい駅の選択、移動タブ(切り替えの段の虫めがねのボタン。選んだ駅へ地図を動かし(`TrainDisplayState.focusRequest` → `MapContainerView(focus:)`)、地図に点のない駅には印を出して、地図の下に駅の情報)。最近検索して選んだ駅(5件、`TrainStore.recentStationSearches`)を、入力が空のときに出す
  - 地図を動かす依頼(`MapFocus`)は key が変わったときだけ効く。List の中の地図が作り直されたときは、覚えていた範囲を優先して、もう一度は動かさない
- 不明な点(APIのレスポンス形式など)は推測で埋めない。公式ドキュメントを確認するか、ユーザーにサンプルJSONを求める
- 小ツール(`Features/Tools`。初期の並びでは「その他」の中。軽さの基準は iPhone SE 第2世代。内蔵ツールは通信しない)
  - 一覧(`ToolsView`): 上部に検索欄。お気に入り → 最近使った → カテゴリ別(時間、計算、決める・遊ぶ、文字、測る、その他)の順。長押し(と、ツールの画面の星)でお気に入り。お気に入りは、ホームの「小ツール」カード(`HomeCardKind.tools`。お気に入りがなければ何も出さない)にも並ぶ
  - ツールは、内蔵でもJSONでも `ToolDescriptor`(ID、名前、説明、アイコン、カテゴリ、キーワード)で同じように扱う。内蔵ツールを増やすときは、`BuiltinTool` に足し、`BuiltinTools.all` に登録し、`ToolScreen` に画面を1行足す。計算などのロジックは View の外(`BuiltinToolLogic.swift`)に置いてテストする
  - 検索(`ToolSearch`): 名前・説明・カテゴリ・キーワードが対象。小文字化、全角→半角、カタカナ→ひらがな、空白・長音・中点の除去で、表記ゆれを吸収する。複数の語は、すべて含むものだけ
  - タイマーとストップウォッチは、小ツールの中に移した(`TimerTabView(initialMode:)`)。保存済みのタイマー(`TimerStore`)と、ホームのタイマーのカードは、そのまま。以前の「タイマー」のタブの位置は、保存済みの並びの中で「小ツール」に置き換える(`TabOrder.decode`)
  - JSONで読み込むツール(`CustomTool`、形式の説明は docs/tools-format.md、サンプルは examples/tools/。サンプルと同じものをテストのフィクスチャ tool_*.json にも置いてある)
    - 計算型 calc / リスト型 list / 表型 table / チェックリスト型 checklist は、プログラムを実行しない。決まった型に中身を当てはめるだけ。通信・位置情報・カメラ・ファイル・アプリのほかのデータに触れる項目は、形式に存在しない。スクリプト型 script(v0.9.19)だけは JavaScript を動かす(下の「スクリプト型」)
    - 計算式は、アプリ専用の評価器(`ToolExpression`。再帰下降の構文解析 → 木を評価)。四則演算、べき乗、括弧、比較、論理、`if`、数学関数、丸め、`days`。NSExpression と JavaScript は使わない。上限は、式の長さ500文字、入れ子32段、計算5000回。ループも再帰もない。`if` と `&&` `||` は、必要な側だけを計算する
    - 検証(`CustomToolParser`): JSONSerialization で読み、項目ごとに確かめて、誤りを場所つき(`outputs[1].formula` など)で返す。全体200KB、入力欄20、出力20、項目500、行1000、列12まで。真偽値を数として受け取らない。式は、読み込みの時点で構文・変数・関数・引数の数を確かめる
    - 読み込みは、「ファイル」アプリ、クリップボード、https のURL(ボタンを押したときだけ。`HTTPClient` 経由で、受信量の記録は「その他」)。保存する前に、内容(名前・型・入力欄・式)を確認する画面を出す。保存は、もとのJSONのまま Application Support の custom-tools.json に入れる(キャッシュ削除では消さない)。書き出し(共有)、JSONの編集、削除ができる
  - スクリプト型(v0.9.19、`Features/Tools/Script`)。JavaScriptCore(JSContext)で動かす。外部のライブラリは使わない。形式と API の説明は docs/tools-format.md の「スクリプト型」(Claude の system prompt にもそのまま入る)
    - 形式(`ScriptToolContent`): script(100,000文字まで)、controls(入力の部品、20個まで、`ScriptControlSpec`)、controlsPosition(top/bottom)、fps(15〜60、初期値30)、aspect(幅÷高さ)、permissions(読みたいアプリのデータの種類、v0.9.21)。決まった関数 setup / frame(t, dt) / onTouch(event) / onInput(name, value) / onStop / onData(kind) をアプリが呼ぶ。1コマの中は onData → onInput → onTouch → frame の順で、描いた命令がつながって1枚になる(毎コマ描き直す。何も描かなければ前の表示のまま)
    - スクリプトが使えるのは、アプリが渡した関数(`ScriptRuntime.installNatives` の __native。土台の JavaScript `ScriptPrelude` が読み込み時に global から消す)と、ScriptPrelude の中のもの(ctx、image、canvas、ui、sound、haptic、storage、random、screen、console、app)だけ。JSContext には fetch・XMLHttpRequest・setTimeout などが元からなく、渡してもいない(テストで確かめている)
    - アプリのデータ(v0.9.21、`app.*`)。アプリがすでに取得・保存しているデータの写しを読むだけ。スクリプトから新しい通信は起きず、書き換える関数もない
      - 種類(`ScriptPermission`): weather(天気・雨の要約・警報)、quake、pressure、exchange、trains(運行情報・登録した駅の次の電車・列車の位置)、places(地点と方角・距離・高低差)、location.coarse(都道府県と市区町村まで)、location.precise(緯度経度・高度)、sensors(歩数・速度・方位・気圧計・加速度)。JSON の permissions に書いた種類だけを、ツールごとに許可する。書いていない種類は、許可を求めずに常に null
      - 許可(`ScriptPermissionGrants`、`AppSettings.scriptPermissions`。ツールの ID → 種類 → 許可したか): 初めて開いたときに、まだ聞いていない種類の一覧を出して許可を求める(`ScriptPermissionRequestView`。location.precise と sensors は「注意」を付けて目立たせ、初めは選んでいない)。許可しなかった種類は null に見え、ツールは止めない。ツールの画面の「その他」→「データの許可」(`ScriptPermissionSettingsView`)で変更・取り消し(変えたら最初から動かし直す)。ツールを削除すると許可の記録も消す(`ToolLibrary.onDeleteCustom`)。読み込みの確認の画面とサンプルの一覧にも、使うデータの一覧(`ScriptPermissionSummarySection`)
      - 渡し方: 画面の側(`ScriptDataSource`。本物は `ScriptLiveData`、プレビューと試しの実行は仮のデータ `ScriptMockDataSource` / `ScriptMockData`)が、種類ごとの写しを JSON の文字列で作り(`ScriptAppData`。件数の上限は `ScriptDataLimit`: 1時間ごと48、日別7、地震5、警報30、実測288、予報72、列車60、地点100 など。1種類256KBまで)、`ScriptRunner.update(data:)` で次のコマの前に渡す。`ScriptRuntime` は許可していない種類と知らない種類を捨て(`ScriptRuntime.accepts`)、`__setData` で入れてから onData(kind) を呼ぶ。app.weather などは読むたびに JSON.parse した新しいオブジェクト(写し)を返す。app は Object.freeze
      - `ScriptLiveData`: 5秒ごとに作り直して、変わった種類だけを渡す。ディスクのキャッシュの読み込み(loadCacheIfNeeded / loadIfNeeded)だけを呼び、取得の関数は呼ばない。位置は、新しく測位せず、iOS が覚えている位置(`LocationProvider.lastKnown`)・地点の一覧の位置(`WaypointStore.origin`)・天気の現在地のうち一番新しいもの。地名は保存済みの逆ジオコーディングの結果だけ(`PlaceNameResolver.cachedPlace`。なければ警報の地域)。天気の地点名・警報の地域・地震の現在地の震度は location.coarse、天気と地点の緯度経度は location.precise のときだけ入れる
      - センサー(`ScriptSensorHub`): app.sensors.start(名前) の依頼(`ScriptOutput.sensorRequests`、sensors を許可したときだけ受け付ける)で、その種類だけを動かす(CMPedometer、CLLocationManager の位置と方位、CMAltimeter、CMMotionManager)。値は0.1秒ごとにまとめて渡す。バックグラウンドで止め、戻ったら動かし直す。画面を閉じたら `ScriptSession.close` → `stopAll` で必ず止める
      - 計算で分かる情報(許可は要らない): app.calendar(今日・14日分のダイヤの種類と祝日、この先の祝日20件。`AppSettings.dayTypeResolver` を反映)、app.holidayName(年, 月, 日)(`JapaneseHolidays.holidayName`。振替休日・国民の休日を含む)
    - 描画: ctx は Canvas 2D に近い API。命令は JavaScript の側で Float64Array に数として貯め(文字は番号の表で送る)、1コマの終わりに1回だけアプリが読む(`ScriptRuntime.finish`、JSObjectGetTypedArrayBytesPtr でまとめて写す)。`ScriptDrawDecoder` が描画の命令 `ScriptDrawOp` に変え(色・書体の読み取りはキャッシュ、1コマ20,000命令まで、知らない命令で止める)、`ScriptRenderer` が SwiftUI の Canvas(GraphicsContext)1枚に描く。PNG の書き出しも同じ描き方(ImageRenderer)
    - 画像: image.create(w, h, Uint8ClampedArray) で RGBA の CGImage(`ScriptImageStore`)。1枚1〜1024px、32枚まで、合計32MBまで。image.exportPNG(補間なしで整数倍、16倍まで)、canvas.exportPNG(幅4096pxまで)で共有シート
    - 音(`ScriptSoundPlayer`、`ScriptSynth`): 効果音のプリセット8種と単音(20〜8000Hz、2秒まで)、1秒に20回まで。メトロノームと同じ .playback + .mixWithOthers、セッションが .playback か .playAndRecord ならカテゴリーを変えず、止めるときもセッションを非アクティブにしない。振動は `ScriptHaptics`
    - 保存領域(`ScriptStorage`): ツールごとに Application Support/script-storage/ツールのID.json。キーと JSON の文字列、合計256KB、キー100文字・1000個まで。書くのは2秒ごとと閉じたとき、一時ファイルに書いてから置き換える(.atomic)。プレビューと試しの実行は端末に書かない。ツールを削除すると消す
    - スレッド(`ScriptRunner`): 専用の Thread(スタック8MB)で、JSContext を作るのも呼ぶのもそのスレッドだけ。fps に合わせて frame を呼び、結果(`ScriptOutput`: 描画の命令、画像、ログ、部品の変更、音、振動、書き出し、エラー)をメインスレッドに渡す(`ScriptSession.apply`)。触れたこと・部品の変更は次のコマの前に渡す(動かしたことはまとめる)。バックグラウンドでは止める
    - 固まったとき: 呼び出しの間は `ScriptRunner.busySince` に時刻を入れ、画面の側が0.5秒ごとに見て、2秒以上なら「応答なし」と閉じるボタン(閉じると実行を打ち切る。スレッドは戻ったところで終わる)。実行時間の制限 JSContextGroupSetExecutionTimeLimit は公開のヘッダーにない関数なので、利用者の判断で、実行時に dlsym で探して使う(`ScriptTimeLimit`。見つからなければ使わない)。1回の呼び出しが5秒を超えたら JavaScriptCore が打ち切り、ツールを止めて「無限ループの可能性」と出す
    - 落ちたとき(`ScriptRunGuard`、`ToolLibrary.crashedScript`): 実行を始める前に Application Support/script-running.json に「実行中のツール」を書き(.atomic)、閉じたとき・バックグラウンドに回ったとき・エラーで止まったときに消す。起動したときに残っていれば、そのツールを開かずに「前回このツールの実行中に止まりました」(`ScriptCrashRecoveryView`、「もう一度試す」「無効にする」「削除する」)。メモリの使いすぎで落ちた場合も同じ。無効にしたツールは `AppSettings.disabledScriptTools`、設定の「小ツール」に「スクリプト型のツールをすべて止める」(`scriptToolsStopped`)
    - データを壊さない: ツールの一覧(custom-tools.json)・保存領域・実行中の記録はどれも .atomic で書く。設定は UserDefaults。スクリプトの実行中に書くのは、そのツールの保存領域と実行中の記録だけ
    - 読み込みの確認(`ScriptPreviewSection`): 「スクリプトを含みます」、コード(20,000文字まで表示)、使うアプリのデータの一覧、「保存する前に動かしてみる」(プレビュー。保存領域を使わず、アプリのデータの代わりに仮のデータを渡す)。書き出し・読み込み(ファイル、クリップボード、URL)は既存のまま
    - Claude での作成(`ToolGenerator`): system prompt に script 型の使い分けと注意を足した(v0.9.21 で、permissions には必要な種類だけを書くこと、location.precise と sensors は必要なときだけ、null のときの表示、onData で受け取ることも)。形式の検証を通ったスクリプト型は、構文(JSCheckScriptSyntax)と、試しの実行(`ScriptTrial`: 専用のスレッドで setup・2秒分のコマ・触れる・部品・onStop を早回し、1回の呼び出し2秒・全体8秒まで、音などは出さない。アプリのデータは仮のデータを渡し、途中で onData を呼び、センサーの開始にも仮の値で応える)で確かめ、エラーがあれば添えて1回だけ作り直しを頼む。出力の上限は32,000トークン、待つ時間は360秒(`ClaudeRequest.timeout`)
    - サンプル: examples/tools/src/*.js を `python scripts/build_tool_examples.py` で JSON(examples/tools と、テストのフィクスチャ tool_script_*.json)にする。check_local.py が一致を確かめ、テストが10個とも試しの実行でエラーがないことを確かめる。アプリのデータを使うサンプル(v0.9.21): 自分好みの天気(weather)、次の電車のカウントダウン(trains)、地点を指すコンパス(places と sensors)、気圧の小さなグラフ(pressure)。どれもデータが変わったときだけ描き直す(コンパスと秒のカウントダウンを除く)
  - サンプル(v0.9.20、`ToolSampleCatalog`、`ToolSamplesView`): examples/tools のサンプル全部を `Resources/tool_samples.json` に同梱し(`python scripts/build_tool_examples.py` で作り、check_local.py が一致を確かめる)、小ツールの一覧の「サンプルから追加」でワンタップで追加する。追加済みは「追加済み」
  - 内蔵ツール(第1弾、v0.9.7): タイマー、ストップウォッチ、日付計算、和暦・西暦・年齢、割り勘、パーセント・割引・消費税、単位換算、進数変換、ルーレット(くじ引きを含む)、サイコロ、コイントス、チーム分け、順番決め、トーナメント表(シードと不戦勝)、カウンター、文字数カウント、文字の変換、パスワード・乱数、懐中電灯
  - 内蔵ツール(第2弾、v0.9.8): 時間計算、世界時計、あみだくじ、スコアボード、メトロノーム。ロジックは `MoreToolLogic.swift`、画面は `MoreToolViews.swift` と `PlayToolViews.swift`
    - 世界時計の時差と夏時間は、iOS のタイムゾーンのデータ(TimeZone)から求める。通信しない。都市の表は `WorldClock.cities`
    - メトロノーム(`MetronomePlayer`): 1小節ぶんの波形(`MetronomeLogic.barSamples`)を AVAudioEngine でループ再生する(拍の間隔はサンプル単位)。気圧の無音再生と同じ .playback + .mixWithOthers を使い、セッションがすでに .playback か、騒音計の .playAndRecord のときは、カテゴリーを変えない。止めるときは自分のエンジンだけを止め、セッションを非アクティブにしない(無音再生を巻き込まないため)。中断や出力先の変更で音が止まったら、表示も停止にそろえる(自動では再開しない)。画面を離れたときとバックグラウンドでは止める
  - 「決める・遊ぶ」の見た目(v0.9.8)。アニメーションは、iOS の「視差効果を減らす」(accessibilityReduceMotion)がオンなら省略して、結果だけを出す
    - トーナメント表: 山型の表(1回戦が左端、決勝が右端、右端に優勝者)。配置は純粋なロジックの `TournamentLayout.make`(各試合の枠、折れ線、シードの印、優勝者の枠、表の大きさ)。枠・名前・線を1枚の Canvas(`TournamentChartCanvas`、Equatable)でまとめて描き、部品を試合の数だけ作らない(64人で63試合)。タップは `TournamentLayout.hit` で判定する
      - 1回戦の不戦勝の試合は、枠も線も描かない。2回戦の枠に「シード」の印を付ける
      - 長い名前は全角7文字ぶんで省略する(`TournamentLayout.shortName`)。タップした試合の、省略していない名前を表の下に出す。勝者のタップ、もう一度のタップでの取り消し、その先の取り消しは、以前のまま(`Tournament.setWinner`)
      - ScrollView(縦横)の中で、Canvas の大きさと描画の縮尺を変えて拡大・縮小する(MagnifyGesture)。開いたときは全体が入る縮尺(`TournamentLayout.fitScale`)。右下のボタンで全体表示に戻る
    - ルーレット: 色分けした円盤(`RouletteWheelView`、Equatable。描くのは項目が変わったときだけ)を rotationEffect で回す。止まる角度は、先に決めた結果の扇形の中(`RouletteWheel.stopRotation`。針は真上)。JSONのリスト型のルーレットも同じ円盤
    - サイコロ: 6面は点(`DicePips`)、ほかは数字の面を Canvas で描く。振ると、約0.5秒だけ目を切り替えながら傾ける
    - コイントス: 表(金)と裏(銀)の絵。横軸の回転で、角度から手前の面を決める(`CoinFlip`)
    - あみだくじ: 横線は、同じ段で隣り合わず、どの間にも1本以上(`Amida`)。名前をタップすると、道を trim で少しずつ描く
- タイマー: 終了時刻はDateで保持。ローカル通知 + アプリ内の音とバイブ。画面を消さないオプション。プリセット機能はない
  - 削除は各行のゴミ箱ボタンと確認ダイアログで行う(スワイプ削除と編集モードは使わない)。削除時は登録済みのローカル通知も取り消す
  - 行全体をTimelineViewで再描画しない(操作を妨げる)。再描画するのは残り時間の文字だけ
- センサー: バッテリーは表示しない(iOSのステータスバーで見られるため)
  - 速度: センサー画面とホームが表示されている間は、常にリアルタイムで表示する(開始・停止ボタンはない)。画面を離れたら測位を止める。`LocationSensors` は天気用の `LocationProvider` とは別のインスタンスで、desiredAccuracy = BestForNavigation、distanceFilter = None、activityType = .otherNavigation、pausesLocationUpdatesAutomatically = false
  - 速度の計算は `SpeedEstimator`(CoreLocationに依存しない純粋なロジック)。speedAccuracy が十分なら CLLocation.speed、無効なら直近の位置の差分から求め、3点で平滑化する。horizontalAccuracy の悪い点は除外する。屋内や地下などGPSで動きを検出できないときは、CMPedometer の currentPace から歩行速度を推定する。優先順位は (1) GPSの速度 (2) 位置の差分 (3) 歩行ペース (4) 停止中(0)または「測位中…」(`SpeedEstimator.reading`)。どの方法で出した値かを必ず表示し、位置の差分で停止と判定したときは理由(精度±◯mのため検出できない)も表示する。歩行ペースは最高・平均・距離にも使うが、GPSで動きが取れている区間では足さない(二重に数えない)。無効な速度を0と表示しない。最高・平均・距離は「画面を開いてからの値」でリセットできる
  - 位置の精度が「おおよそ」(reducedAccuracy)のときは、速度が測れない理由と設定の案内を表示する。GPSの状態(水平精度、最後の測位からの秒数)も小さく表示する
  - 歩数: CMPedometer.startUpdates(from: 今日の0時)で継続的に受け取る(最初の値だけは queryPedometerData で補う)。ペースと歩調も表示する。更新は数秒おきにまとめて届く旨を注記する
  - CLLocationManager のデリゲートはメインスレッドで呼ばれるので `MainActor.assumeIsolated` で同期的に状態を更新する。CMPedometer のコールバックは任意のスレッドなので、Sendable な値に詰め替えてから `Task { @MainActor in }` で更新する
  - センサー画面の表示中は画面を消さない(設定でオフにできる)。画面を消さない指定は `ScreenAwake` で理由ごとに管理し、タイマーと打ち消し合わないようにする。ホームの速度のカードは、ホームの「編集」で非表示にできる(高精度のGPSは電池を多く使うため)
- スコープ(以前の名前はウェイポイント。軽さの基準は iPhone SE 第2世代)。画面の上部で「地点/周辺/経路」を切り替える(`ScopeView`)。カメラ表示とコンパス表示は3つで共通(`ScopeSightView`。表示するものは `ScopeSightSource` で選び、どれも `ScopeMark` → `ScopeTarget` にそろえて同じ Canvas で描く)
  - 名前を変えても保存データは引き継ぐ: タブの値 `AppTab.waypoint`、ホームのカードの値 `HomeCardKind.waypoint`、設定のキー `waypoint.showsHeading`、ファイル waypoints.json、型 `Waypoint` は、以前のまま(表示名とアイコンだけを「スコープ」「地点」に変えた)
  - 周辺(`NearbyStore`): MapKit の MKLocalSearch で、現在地(1回だけの測位)の周辺の施設を探す。APIキーは使わない。カテゴリ(`NearbyCategory`: コンビニ、駅、トイレ、カフェ、飲食店、ATM、薬局、駐車場、公園)ごとに検索語と色を持ち、並び順は設定に保存する。探す範囲は初期値500m、最大2km(`NearbyRadius`)。結果は範囲の中だけに絞り、同じ場所の重複を除いて、近い順に並べる(`NearbyPlace.arranged`)。同じカテゴリ・同じ範囲の結果は5分使い回し、100m以上動いたときだけ探し直す(`NearbyCachePolicy`)。施設の詳細(名前・住所・電話・Webサイト)から「地点に保存」「ここへの経路」ができる
  - 経路(`RouteStore`、第1段階): MKDirections で徒歩の経路を取得し、地図に線を描いて、所要時間と距離を出す。曲がり角は MKRoute.steps(位置は、その区間の最初の点)。案内の状態は純粋なロジックの `RouteNavigator`: 曲がり角の15m以内に入ったら次へ切り替え、経路の線から50mより離れたら「経路から外れています」、目的地の15m以内で到着。取り直しはボタンで行い、最短20秒の間隔を空ける(自動では取り直さない)。カメラ表示では、次の曲がり角(黄)と目的地(赤)の印を同時に出し、下に「次：あと40mで 右折する」を大きく出す
  - 経路の案内は、地図の画面(`RouteGuidanceView`)が中心。カメラ表示は、地図の画面のボタンから開く補助。ARで道路に帯を描く案は見送った(調査の記録は、Gitの管理外の private/ideas.md)
    - 地図は既存の `MapContainerView`。現在地に追従し、進行方向を上にして回転する(`MapTracking.followHeading`。MKMapView の userTrackingMode)。北を上にする表示にも切り替えられ、選んだほうを保存する。指で地図を動かすと MapKit が追従を外すので、それを受けて「現在地に戻る」ボタンを出す
    - 現在地は、進行方向の分かる矢印(`DirectionArrowView`)。向きは進行方向(course)、止まっていて無効なら端末の向きで、地図の回転の分を引く(`MapDirection.arrowRotation`)。追従を使う地図でだけ矢印にし、ほかの地図は標準の青い点のまま
    - 経路の線は、現在地に一番近い線上の点で2つに分け(`RouteProgress`)、通り過ぎた部分を薄いグレー、これからの部分を濃い青で描く。次の曲がり角には黄色の印(`MapMarkerStyle.turn`)
    - 上部に「次：あと40mで 右折する」を大きく、その次の曲がり角を小さく出す。下部に、残りの距離・残りの時間・到着予定の時刻(`RouteRemaining`。時間は、経路全体の所要時間を、残りの距離の割合で案分する)
    - 曲がり角の切り替え(15m)、経路から外れた判定(50m)と取り直し(ボタン、最短20秒)は `RouteNavigator` / `RouteStore` のまま
  - 周辺の検索と経路の取得は iOS(MapKit)が通信するので、受信量は計測できない。通信量の画面に注記してある
  - 案内中(地図の案内の画面と、そこから開くカメラ表示を表示している間)だけ、高精度のGPSを使い、画面を消さない。画面を離れたら止める
  - 以下は「地点」と、共通のカメラ表示・コンパス表示の仕組み
  - 地点(`Waypoint`: 名前、色、メモ、緯度経度、ピン留め)は `WaypointStore` が Application Support の waypoints.json に保存する。登録は、現在地(1回だけの測位)、地図の長押し(既存の `MapContainerView` の onLongPress)、緯度経度の入力(`WaypointCoordinateParser`。「35.68, 139.76」の形、かっこ・全角・空白区切りも可)。削除は各行のゴミ箱ボタンと確認ダイアログ
  - 一覧とホームのカードの距離・方角は、最後に分かった現在地(`WaypointStore.origin`)から計算する。一覧を開いたときに1回だけ測位し、ホームでは測位しない
  - カメラ越しの表示は ARKit を使わない。CMMotionManager の deviceMotion(参照フレーム .xTrueNorthZVertical、30fps)の回転行列から、画面の右・画面の上・背面カメラの向きを基準の座標系(x=北、y=西、z=上)で求め(`CameraAttitude`。行列の各行が端末の各軸、カメラは −Z)、地点の方向(仰角0度)をカメラの座標に直して画面上の位置にする(`WaypointProjection.point`)。端末の傾きと回転もそのまま反映される。カメラの後ろと、画面の外の地点は描かない(端の矢印も出さない)
  - 写る範囲は AVCaptureDevice の activeFormat.videoFieldOfView(映像の長辺の画角)と、映像と画面の縦横比から求める(`WaypointProjection.tangents`、映像は aspectFill)。縦向きだけに対応し、横向きでは案内を出す。映像は 1280x720
  - センサーの値は、向きのベクトルのまま軽く平滑化する(重み0.25。角度で混ぜないので 0度/360度 の境目の問題がない)。v0.9.26 から、混ぜたあとに背面の向きを基準に右と上を直交させ直し(上 = 右 × 背面)、1回で45°より大きく変わったとき(再開の直後など)は混ぜずに新しい値を使う(`CameraAttitude.smoothed`)
  - 方角はいつもカメラの向き(端末の −Z、行列の3行目の逆)から出す(`CameraAttitude.azimuth`)。端末を立てた・寝かせた・傾けたで軸や計算を切り替える分岐はない(テストで、仰角 −85°〜85°・傾き ±40° で連続して正しいことを確かめている)。行列は「行が端末の軸」と読む(縦に持ったときの重力 (0, −1, 0) と一致することをテストで確かめている)。画面が横向きのときの補正もない(横向きでは「縦向きで使ってください」を出すだけ)。映像のプレビューの接続は、縦向き(videoRotationAngle 90)に固定する
  - CMMotionManager は、スコープの画面どうしで1つを使い回す(`WaypointTracker.sharedMotion`。アプリで1つにするよう Apple が求めている。v0.9.25 までは画面の構造体が作られるたびに作っていた)。止めるのは、始めた画面(`motionOwner`)だけ。始め直したら、平滑化と診断を捨てる
  - 方角のデバッグ(v0.9.26、設定の開発者向け「方角のデバッグ表示」`AppSettings.headingDebugEnabled`、初期値オフ。`ScopeHeadingDebugView`): カメラ表示の左上に、計算した方角・仰角・傾き、CoreMotion の生の値、基準(頼んだもの・実際の `attitudeReferenceFrame`)、開始した回数・基準が変わった回数、情報源、磁気の較正の状態・CMDeviceMotion.heading、コンパス(CLHeading)の真北・磁北・精度、比べる軸(カメラが水平に近いときは背面、平らに近いときは上端)とコンパスとの差(30°以上で赤)、ジャイロで説明できない回転の累計と跳びの回数、行列と重力の差、画面・シーンの向き・持ち方(重力から)
    - ジャイロで説明できない回転(`HeadingDiagnostics`): 前の姿勢から今の姿勢への鉛直まわりの回転(基準の座標系の回転 R = Σ e_k(今)・e_k(前)ᵀ の (R21 − R12)/2)と、角速度の鉛直の成分(行列の3列目との内積、台形で積分)の差を足していく。端末が回っていないのに方角だけが回った分(磁気による補正、基準の取り直し)が分かる。1回で5°より大きい差は「跳び」。0.5秒より間が空いたら比べない
    - 方角の手動補正(v0.9.28、`HeadingCorrection`、設定の「方角の補正」`AppSettings.headingOffset`、−180〜180°、UserDefaults の scope.headingOffset): iPhone の磁気センサーがずれて、iPhone のコンパスアプリも含めて方角が約90°ずれたことがあった(8の字の補正と再起動でほぼ直った。v0.9.26〜v0.9.27 で調べたとおり、アプリのコードの問題ではなかった)ときの短期的な対策。補正した方角 = 端末の方角 + 補正(時計回りが+)。`HeadingCorrection.current`(AppSettings が読み込み・変更のときに入れる)を、端末の方角を使う所すべてに足す: `WaypointTracker`(CoreMotion の姿勢を鉛直のまわりに回す `rotatedClockwise` → スコープのカメラ表示の地点・周辺・経路・電車・景色・オブジェクト・東西南北の印・撮って聞くの方角、コンパス表示の CLHeading、経路の案内のカメラ表示)、`LocationSensors`(センサー画面の方位)、`ScriptSensors`(スクリプト型の app.sensors の方位)、`DashboardMapView` の現在地の矢印(端末の向きを使うときだけ。GPS の進行方向には足さない)。地図を進行方向に回す表示(MKMapView の userTrackingMode)は MapKit が自分で方角を求めるので補正できない(矢印は補正した方角を、回った地図の上で指す)。方角のデバッグ表示のコンパスとの比較は、補正を戻して比べる
      - 操作(`HeadingCorrectionControls`): スライダー(1°刻み)、−10°・−1°・+1°・+10°、0°に戻す。設定(`HeadingCorrectionSettingsSection`)と、スコープのカメラ表示・コンパス表示のメニュー「方角を補正」で出すパネル(`ScopeHeadingCorrectionPanel`)
      - 目印に合わせる: パネルを出すと画面の中央に十字。表示している印・景色の山・置いたオブジェクトのうち、中央から左右25°以内で一番近いもの(`HeadingCorrection.nearest`)を出し、「この印に合わせる」で 補正 = 今の補正 + (目印の方角 − 今のカメラの方角)(`aligned`)
      - 補正が0でないときは、カメラ表示の右上とコンパス表示に「補正 +12°」(`HeadingCorrectionBadge`)
    - 東西南北の印(v0.9.27、`ScopeCompassRose`、`ScopeCompassRoseOverlay`): デバッグ表示のとき、方角0°〜315°(45°ごと)の印と水平線を、地点と同じ投影(`WaypointProjection.point`、仰角0)でそのまま描き、画面の中央に十字と「中央 123° → 南東(135°)の印が右に12°」を出す。実際の北に「北」が重なれば、方角と投影は正しい
    - 現在地の確かめ(v0.9.27、`ScopeLocationCheck`): 方角と投影が正しくても、現在地がずれていると近いものの方向がずれる(誤差 a m・距離 d m で ±asin(a/d))。デバッグ表示に現在地の精度・何秒前か・おおよその位置か、近い印3つの方角・中央からの角度・距離・位置の誤差でのずれを出す。カメラ表示の下には、「おおよその位置」のとき(正確な位置情報がオフ)と、一番近い印が誤差で20°以上ずれうるときに注意を出す
    - 「方角をジャイロで保つ(試験)」(`headingGyroHold`、初期値オフ): 表示に使う姿勢を、その累計の分だけ戻す(磁気による補正を打ち消す)。積分の誤差で少しずつずれるので、デバッグ表示の「ジャイロの累計を0に戻す」で合わせ直す
  - 印は、一定の大きさのリング(直径44pt、黒い線+細い白い縁)と、地点の色の内側の円。内側の円の大きさは距離の対数で決め、10m以下で95%、15km以上で10%(`WaypointMarkStyle.innerFraction` の1か所で調整する)。距離の上限はない。印の下に名前と距離。1枚の Canvas に、遠い地点から描く(近い地点が手前)
  - 表示する地点は「すべて/選んだ1つ」で切り替える。向いている方角(例: 北東 45°)の表示は初期値オフ(設定 `waypointShowsHeading`、画面のメニューからも切り替えられる)
  - カメラの許可がない、またはカメラが使えない環境では、コンパス表示(方位の目盛りと地点の方向の矢印、「右へ◯°」)に自動で切り替える。コンパス表示の方位は CLHeading の trueHeading(端末を水平に持っても使える)。カメラ表示からも切り替えられる
  - 方位の精度(CLHeading.headingAccuracy)と位置の精度を画面の下に表示し、±20°より悪いときは「iPhoneを8の字に動かすと方位の精度が上がります」と案内する
  - カメラの起動を待たせない: AVCaptureSession の設定、startRunning()、stopRunning() は専用のキューで行い(`CameraWorker`)、メインスレッドでは呼ばない。セッションと設定(デバイス、入力、プリセット、画角)はアプリ全体で1つを使い回す(`AppEnvironment.camera`)ので、2回目以降は startRunning() だけになる。画面(印、精度の表示)は先に出し、映像が出るまでは黒い背景に「カメラを起動中…」と表示する。位置とモーションは、カメラの準備を待たずに始める。起動時間の内訳(許可の確認、設定、映像の開始)は、設定の開発者向けに表示する
  - カメラ・GPS・モーションは、カメラ表示とコンパス表示の画面を表示している間だけ動かし(`WaypointTracker`、`CameraController`)、画面を離れたときとバックグラウンドでは止める。表示中は画面を消さない(`ScreenAwake`)
  - ホームの「スコープ」カード(初期値は非表示。`HomeLayout.defaultHidden`): ピン留めした地点(なければ表示中で一番近い地点)の名前・方角・距離。タップでコンパス表示を開く。ピン留めした地点を非表示にしても、ピン留めは外さず「非表示中」と出す
  - 地点の表示・非表示(v0.9.15、`Waypoint.isHidden`): 削除せずに非表示にできる。一覧の各行の目のボタン、上部の「すべて表示」「すべて非表示」と「表示中だけ/すべて」の絞り込み(`WaypointListFilter`、選んだ絞り込みは保存。「表示中だけ」のときは並べ替えできない)。非表示の地点は一覧で薄く出し、カメラ表示・コンパス表示(「すべて」のとき)・地図(地図から登録の画面の印)・ホームの「一番近い地点」から外す(`WaypointStore.visibleWaypoints`)。「選んだ1つ」は非表示の地点も選べる(選んだ地点は出す)。経路の目的地の一覧には、非表示の地点も出す
  - 地点の高さ(v0.9.15): 地点ごとに標高(`groundElevation`、未設定は nil)と地面からの高さ(`heightAboveGround`)を持ち、地点の高さ = 標高 + 地面からの高さ(`Waypoint.altitude`)。標高の状態 `WaypointElevationState`(未設定/取得/手入力/データなし)
    - 標高は国土地理院の標高API(`GSIElevationAPI`、`ElevationStore`)で取る。`?lon=経度&lat=緯度&outtype=JSON` で `{"elevation":18.5,"hsrc":"1m（レーザ）"}`(gzip で約70B)。海上・国外は HTTP 200 で `{"elevation":"-----","hsrc":"-----"}`(「データなし」にして、自動では取り直さない)。2026-10-17に確認。受信量は「スコープ」(`UsageCategory.scope`。ホストは地図タイルと同じ gsi.go.jp なので、パス /general/dem/ で分ける)
    - 登録したときと座標を変えたとき(`WaypointStore.onNeedsElevation`)に取る。オフラインなら未設定のまま。未設定の地点(v0.9.14 以前に保存した地点を含む)は、起動時・復帰時と一覧を開いたときに、従量制でない回線なら自動で取る(`ElevationStore.fillMissing`、0.3秒間隔)。編集画面で手入力・再取得・地面からの高さ。座標を変えたら、同じ編集で標高を手で入れ直していなければ取り直す(`WaypointStore.updating`)
    - Waypoint は独自の init(from:) で読む(ない項目は初期値)。保存済みの地点は「表示」・標高「未設定」として引き継ぐ
  - 自分の高さ(`ObserverHeight`、設定「自分の高さ」`AppSettings.scopeHeightSource`): 「地面の標高+手の高さ」(初期値。手の高さは初期値1.5m、`scopeHandHeight`)か「GPSの高度」(CLLocation.altitude、verticalAccuracy が有効なときだけ)。地面の標高は現在地で国土地理院の標高APIから取り、前回の位置から100m以上動いたときだけ取り直す(`ElevationStore.updateGround`。最後の値は UserDefaults に保存。自動の通信なので RefreshPolicy に従う)。取れないときはGPSの高度。使っている方法と高さを、カメラ表示・コンパス表示の精度の表示の下に出す
  - カメラ表示への反映: 仰角 = atan((地点の高さ − 自分の高さ − 見かけの低下) / 水平距離)、見かけの低下 = 距離² ÷ (2 × 地球の半径) × (1 − 0.13)(大気の屈折で、丸みによる低下が13%ほど小さく見える。`WaypointElevation`)。仰角は `WaypointProjection.point(bearing:elevation:...)` で画面の上下の位置になる。標高が未設定の地点と、自分の高さが分からないときは地平線の高さ(仰角0)。設定「地点の高さを反映する」(初期値オン、`scopeUsesHeight`。カメラ表示のメニューからも切り替え)をオフにすると、すべて地平線の高さ(高低差の表示は残す)
  - 高低差の表示「2.3km ↑120m」(`WaypointMath.distanceText(_:heightDifference:)`): カメラ表示の印の下、コンパス表示の行、地点の一覧(一覧は、最後に分かった現在地と、そのときの自分の高さ `WaypointOrigin.height` から)
  - 電車(v0.9.16、`ScopeTrains.swift` / `ScopeTrainViews.swift`。上部の切り替えの4つめ `ScopeSection.trains`、`ScopeSightSource.trains`)
    - 列車の位置は移動タブと同じ計算(`TrainLiveStore.positions`。保存した時刻表から計算し、遅れで補正)。新しい通信はない。遅れの取得は移動タブと同じ規則(`TrainLiveStore.setVisible`。理由の名前は一覧が scope.list、カメラ表示が scope.sight)
    - 対象の路線(`AppSettings.scopeTrainTarget`): 登録した路線(初期値)か、現在地から一定の距離(初期値3km、`scopeTrainRadiusKm`)以内を通る路線(路線の線までの距離。時刻表を保存している路線だけ)。列車は近い順に上限まで(初期値20本、`scopeTrainMaxCount`)。選び方は `ScopeTrainSelection`
    - 1秒ごとに計算し(`ScopeTrainFeed`)、前の計算との差から線に沿った速さを出して、描く時刻の分だけ先へ進める(`ScopeTrain.headAlong(at:)`、1.5秒まで)。描画は今の仕組み(端末の向きの更新)のまま
    - 接近中: 走っていて、進行方向と、列車から現在地への方向の差が90度より小さい(`ScopeTrainSelection.isApproaching`)
    - カメラ表示: 近い列車(8本まで、600m以内)は電車の形。先頭から線路の形に沿って後ろへ、20m×両数の車両の箱(幅2.8m・高さ3.5m)を並べ、車両ごとに線路の向きにする(`ScopeTrainGeometry`)。8つの角を投影し(`ScopeTrainRenderer.project`)、見えている面(側面・前後・屋根)を塗って輪郭線。色は路線の色、遅れがあれば輪郭を遅れの色、先頭の車両の側面を明るく。車両ごとに、その位置の線路の高さ − 自分の目の高さに箱の下を置く(v0.9.17、`ScopeTrainRenderer.Heights`)。線路の高さか自分の高さが分からなければ、地面(目の高さから手の高さだけ下)。遠い車両は地球の丸みの分だけ下げる。地下の区間の車両は、赤の半透明の塗り(不透明度0.3、カメラの映像が透けて見える濃さ)と赤の破線の輪郭(v0.9.18。`drawsAsOutline`、`ScopeUndergroundStyle`。リングの印も薄くして内側を赤)。どれかの角がカメラの後ろ(奥行き1m未満)に回る車両は描かない。画面の外の部分は Canvas が切り取る
    - 遠い列車(600mより遠い、先頭の車両が画面で5pt未満、9本目以降)は、進行方向の矢印が入ったリングの印(地点の印と同じ大きさの規則)。1枚の Canvas に、遠い列車(車両)から描く。印の近くに「種別・行先・距離・高低差」と「高さは目安」「接近中」「地下鉄」(`ScopeTrain.caption`。例「急 西馬込行 350m ↑8m 接近中」「各停 渋谷行 1.2km 地下 ↓15m」。高低差は線路の高さ − 自分の目の高さ。区間の種類か地面の標高か自分の高さが分からなければ「高さは目安」。「地下鉄」は、地下かどうかが分からない地下鉄の路線の列車だけ)
    - タップは、描くときと同じ配置で位置を計算して判定し(`ScopeTrainRenderer.hit`)、移動タブと同じ列車の詳細(`TrainSelectionCard`)をシートで出す
    - 両数(v0.9.17、`TrainCarResolver` / `TrainCarCatalog`、`Resources/railway_cars.json`): 時刻表の odpt:carComposition(`LineSchedule.Train.cars`。2026-10-18の時点では、どの事業者のデータにもない)→ 設定の路線ごとの上書き(`scopeCarOverrides`、設定の「路線ごとの両数」`TrainCarSettingsView`。初期値は表の値)→ 表の規則(停車駅・列車番号の末尾・種別・行先)→ 表の両数 → 路線の種類ごとの目安(`scopeCarCounts`。表にない路線)
      - 表は各社の公式サイトで調べた値(推測で埋めない)。出典のURLと確認日を持つ。混在して見分けられない路線(三田線、南北線、副都心線、有楽町線、グリーンライン)は多いほうの両数で `mixed`、公式で確かめられない路線(荒川線)は `verified: false`。どちらも列車の詳細とスコープに「両数は目安」。千代田線の綾瀬〜北綾瀬だけの列車は3両(規則)
      - 列車番号の末尾の文字(三田線の T・K・G など)は、意味を公式で確かめられないので、規則に使っていない
      - 移動タブの列車の詳細(`TrainSelectionCard.trackText`)に、今の区間(高架・地上・地下・不明)と両数
    - コンパス表示: 形ではなく、方向の位置に進行方向の矢印の入った印(`ScopeMark.travelHeading`)。行に高低差と「接近中」など(`heightCaption` + `notes`)。行のタップで列車の詳細
    - 地図: 移動タブの地図(`TrainLiveMapView`)をそのまま使い、スコープの列車だけを出す(`TrainLiveBoard.restricted(to:)`。表示範囲は別に覚える `memoryKey: "scope.trains"`)
    - 自分の高さ: 地点と同じ決め方(`ElevationStore.observerHeight`。「地点の高さを反映する」がオフなら使わず、電車も地面に置く)。一覧の画面は1回だけの測位の値。仮想の移動の間は、近くの線路(300m以内)の地面の標高 + 手の高さ(`ScopeTrainFeed.trackGroundAltitude`。通信しない)
    - 位置のデバッグ: 仮想の移動の間は、仮想の位置と時刻で計算する。移動タブを離れても仮想の移動が進むように、スコープの電車の画面の表示中は `MovementStore.setVisible(true)` にする(仮想の移動の間だけ)
  - 画面の構成(v0.9.31。v0.9.29〜v0.9.30 はタブを開くとカメラ表示だったが、利用者の報告で v0.9.28 までの一覧の形に戻した): スコープのタブの最初の画面は、上部の6つの切り替え(地点・周辺・経路・電車・景色・オブジェクト、`ScopeSection`。横にスクロールできるカプセルのボタン)で一覧を出す(`ScopeView`)。一覧の「カメラで見る」でカメラ表示(`ScopeSightView(mode:source:)`)。太陽と月は、7つめの切り替えにせず、景色の画面の「太陽と月」の節(カメラ表示に重ねるか、日の出入り `SkyDetailView`、ダイヤモンド富士の予報 `SummitForecastView`)にまとめた
    - 重ねる表示(`ScopeLayer`: 印=地点・周辺・オブジェクト、移動=経路・電車、空と景色=景色・太陽と月。`ScopeLayerGroup`)をいくつでも同時にオンにでき、設定 `AppSettings.scopeLayers`(UserDefaults の scope.layers)に保存する。一覧の「カメラで見る」で開いたときは、その画面の表示を scopeLayers に入れる(`primaryLayer`。題名もその表示)
    - カメラ表示の右上: 「表示」(`ScopeLayerPickerView`: グループごとのオンとオフ、景色の中の層、おすすめ `ScopeLayerPreset`: 歩く=地点・経路、電車=電車・地点、景色=山・稜線、周辺の施設=周辺・地点、空=景色・太陽と月)、カメラ/コンパスの切り替え、「…」。カメラ表示の左上に、オンの表示の小さなアイコン(`ScopeActiveLayerIcons`。タップでその表示だけをオフ)
    - 「…」のメニュー: 表示する地点(選んだ1つ)、向いている方角、高さを反映、景色の層・隠れた山・山の高さの強調、太陽と月の日時を変える、方角を補正、最近聞いたこと(撮って聞く)、最近作ったもの(オブジェクト)。v0.9.29〜v0.9.30 の「管理」の画面は消した(一覧は上部の切り替えに戻した)
    - 一覧の画面の「スコープのカメラ表示に重ねる」(景色・オブジェクト・太陽と月)= scopeLayers に入れる
    - 引き継ぎ(`ScopeLayerMigration`): scope.layers がなければ、以前の上部の切り替え(scope.section)の表示と、「ほかの表示にも重ねる」(景色 scope.sceneryOverlaysOthers・オブジェクト scope.objectsOverlayOthers)から決める
    - 電車がオンのときは、電車の重ね描き(`ScopeTrainOverlay`、景色・オブジェクトも同じ Canvas)を下に、印(`ScopeOverlay`)を上に重ねる。カメラ表示の印には電車を入れない(車両の箱で描く)。コンパス表示では電車も印にし、行のタップで列車の詳細
  - オブジェクト(v0.9.23、`Features/Scope/Objects`。6つめ `ScopeSection.objects`、`ScopeSightSource.objects`)
    - 形(`ObjectShape`): 箱・円柱・円錐・球・角錐・板(縦の板)。大きさ(幅・奥行き・高さ m)、位置(形の底面の中心。x=右、y=前、z=上)、回転(形の中心のまわりに、ロール(右が下がる)→ ピッチ(前が上がる)→ ヨー(上から見て時計回り))、色(#RRGGBB)、不透明度。新しい形の初期値は赤・不透明度0.4(最後の形の色を引き継ぐ)。オブジェクト(`ScopeObject`)は形300個まで(v0.9.24 で64個から増やした)
    - 軸と正面(v0.9.25 で docs/objects-format.md に明記): +y が正面(前)、+x がオブジェクトの右(正面から見ると見る人の左)、+z が上。置いたときの「向き」は正面の方角で、北=0°・時計回り(`ObjectGeometry.placed`: 東 = x cos h + y sin h、北 = −x sin h + y cos h)。カメラ表示の基準の座標系(x=北、y=西)へは `ObjectRenderer.vector`、地図の輪郭は `GeoMath.offset(east:north:)`、プレビューは `ObjectPreviewView.scenePoint`(SceneKit の x=右、y=上、z=後ろ)。この4つがそろうことを、正面にだけ板の付いた箱で確かめるテストがある(`ObjectOrientationTests`。プレビューの部品の頂点、輪郭、カメラの各段階)
      - v0.9.25 で「約90°時計回りにずれる」と報告があったが、v0.9.23〜v0.9.24 で向きの計算は変わっておらず、4つの経路もそろっていた。正面を +x に作った JSON(Claude が軸を取り違えた)だと、向き0°で正面が東を向き、90°時計回りに見える。system prompt に軸と正面の決まりを書き、編集の画面に「全体を左に90°/右に90°」(`ObjectShapeEditing.rotateAll`。位置を回して yaw に足す)を足した。保存済みのオブジェクトは自動では変えない(どれが取り違えたものか分からないため)
      - プレビューのカメラは、はじめは正面の右斜め前(v0.9.24 までは右斜め後ろ)。青い印は正面の一番前の先に、オブジェクトの大きさに合わせて置く
    - 保存(`ObjectStore`): Application Support/SmartDashboard/objects.json に、作ったものと置いたもの(`ObjectPlacement`: 位置、向き=正面の方角、地面からの高さ、倍率、地面の標高、表示・非表示)を .atomic で。キャッシュの削除では消さない。オブジェクトを消すと置いたものも消す。名前を変えると、名前を変えていない置いたものも合わせる
    - JSON(`ObjectCodec`、docs/objects-format.md): 書き出し(共有)・読み込み(貼り付け、「ファイル」)。項目ごとに確かめて、誤りを場所つきで返す(`ToolIssue`)。省略した項目は初期値
    - 編集の画面(`ObjectEditorView`): 上に SceneKit のプレビュー(`ObjectPreviewView`、allowsCameraControl で指で回す・拡大、地面の板と正面の向きの青い印、選んだ形を明るく)。形の一覧(追加・複製・削除・上へ・下へ。`ObjectShapeEditing`)、選んだ形の設定(数値の入力と、名前を左右にドラッグして変える `NumberScrubField`)、全体の色と不透明度。元に戻す・やり直し(`ObjectEditHistory`、50回まで。ドラッグは始めたときに1回記録)。SceneKit の向きは、カメラ表示の計算(`ObjectGeometry.rotate`)と同じ回転を四元数で作る(`ObjectPreviewView.orientation`)
    - 地図に置く(`ObjectListView`): 地図の長押しで置くオブジェクトを選び、置いたものの編集(`ObjectPlacementEditor`: 地図のタップで移す、向き、地面からの高さ、倍率、表示)。地面の標高は、地点と同じ国土地理院の標高API(`ElevationStore.lookup`)で、置いたとき・移したときに取る(取れなければ未取得のまま、一覧を開いたときにまた試す)。地図には足元の輪郭(全部の頂点の凸包 `ObjectGeometry.footprint` を閉じた線 `MapLine` で)
    - 簡略化(v0.9.24、`ObjectLOD`): 画面での半径(オブジェクトの一番遠い点までの距離 × 倍率)で段階を決める。80pt以上=すべての形、25pt以上=丸い形を粗く(円柱・円錐は6角形、球は経度6×緯度3)して、画面で一番長い辺が2pt未満の形を省く、10pt以上=全体を囲む1つの箱(色は一番大きい形の色)、それ未満=リングの印。1コマ2,000面の中で、画面で大きく見えるもの(近いもの・大きいもの)から割り当て、入らなければ1段ずつ粗くする(`ObjectLOD.plan`)。面の明るさを段階に丸め、描く順で続く同じ塗りの面を1つの Path にまとめて塗る(`ObjectRenderer.batches`)。縁の線は、すべての形を描くときだけ。形の面は、粗い版・箱もオブジェクトを変えたときだけ作る
    - 編集の画面のプレビュー(v0.9.24): 形が60個より多いときは、形の種類ごとの立体の部品と色ごとの材質を使い回し、丸い形の分割を減らし(12)、透明の描き方を1回(.aOne)にし、アンチエイリアスを切る。1秒30コマ、動かしたときだけ描く
    - カメラ表示(`ObjectRenderer`): 今の Canvas で面を塗る方法を選んだ(SceneKit を重ねる方法と比べた。理由は docs/handoff.md)。形を面に分け(丸い形は円柱・円錐が12角形、球が経度10×緯度6)、置いた向き・倍率・高さを反映し(`ObjectGeometry.placed`)、電車の車両の箱と同じ投影(`ScopeTrainRenderer.project`、奥行き1m未満の面は描かない)と、地面との高低差・地球の丸み(`WaypointElevation.curvatureDrop`)で画面に置く。全部の面を遠い順に塗る(画家のアルゴリズム。半透明の面は裏側も描くので、奥が透けて見える)。面の明るさは向きで変える(0.62〜1)。1コマ2,000面まで。画面での半径が10pt未満なら、地点と同じリングの印(`ScopeOverlay.drawMark`)。形の面はオブジェクトを変えたときだけ作る(`ObjectStore.drawItems`)。タップで名前・距離・方角・大きさ(`ObjectPlacementInfoSheet`)
    - 重ねる: 景色と同じく `ScopeExtras`(景色 → オブジェクト → 地点・電車の印の順に、同じ Canvas で描く。タップはオブジェクト → 山)。設定 `objectsOverlayOthers`(初期値オン)で、ほかの表示にも重ねる。コンパス表示では印
    - 文章から作る(`ObjectGenerator`、`ObjectComposeView`。Claude API を設定しているときだけ): system prompt に形式、軸と正面の決まり、外から見える形だけを作ること(v0.9.25: 内装・部屋・床・階段・中の設備は作らない、ほかの形に完全に隠れる形は作らない、形の数はまず全体の輪郭(高さ・幅・くびれ・段の位置)に割り当てて飾りは余りで、「とても細かい」では特に外形の正確さに使う)と、細かく作るコツ(実物の比率、段ごとに幅を変えて輪郭をなめらかに、くり返す部分は少しずつ変えて並べる、部分ごとの色、細い部材は細長い箱・円柱、値が初期値の項目は書かない)を書き(プロンプトキャッシュ。検索あり・なしの2通り)、`ObjectCodec`(形の数は細かさの上限)で検証し、誤りがあれば1回だけ検索なしで作り直し(長すぎて切れたときは形を減らすように頼む)。保存する前にプレビュー(`ObjectConfirmSection`)と、形の数・面の数・料金・検索の回数・参考にしたページ(タップで SFSafariViewController)
      - 細かさ(v0.9.24、`ObjectDetail`、選んだものは AppStorage objects.composeDetail2): ふつう=30形・出力8,000トークン、細かい=100形・24,000、とても細かい(v0.9.25 から初期値)=300形・56,000(形1つは省略した書き方で約40〜60トークン。思考と検索の後の文章の分を足した)。上限は依頼の文に書く(system prompt を同じにしてキャッシュを効かせる)
      - Web 検索(v0.9.24、v0.9.25 から初期値オフ、objects.composeSearch2。初期値を変えたので、v0.9.24 までの選択(objects.composeDetail / objects.composeSearch)は引き継がない): 実機で、検索ありは内装に形を使って見た目が悪くなり、とても細かい・検索なしが一番よかった(利用者の報告)。検索は、全体の高さ・各部の高さ・幅や直径・断面の形・色を調べるためだけに使い、館内の案内や歴史は使わないよう指示する。調べたあと、JSON の前に寸法の一覧を `<dimensions>` と `</dimensions>` の間に1行1つ「項目: 値」で書かせ(20行まで)、それに合わせて作らせる。一覧は `ObjectDimensions.parse` で読み(行の頭の「-」「・」を除き、最初の「:」(全角も)で分ける。閉じる印がなければ最初の「{」の前まで。1項目80文字まで)、JSON を取り出す前に除き(`removing`)、確認の画面の「調べた寸法」に出す。作り直したときも1回目の一覧を使う。「撮って聞く」と同じ web_search_20250305 を max_uses 2 で。送るのは入力した文だけ(位置は送らない)。HTTP 400(このモデル・組織で使えない)なら、検索なしで1回だけ呼び直して、確認の画面に出す。pause_turn の続きと検索なしへの切り替えは、「撮って聞く」と共通の `ClaudeSearchCall` に切り出した
      - 写真から作る(v0.9.30、`ObjectComposeView(photos:)` の「写真から」、`ObjectPhotoInputSections`): 1〜3枚の写真、写真ごとに指で囲んで切り取る(`PhotoCropView`)、分かっている寸法(高さ・幅・奥行き、任意)と説明(任意)。写真は向きを直して読み(`ObjectPhotoImage.load`、CGImageSourceCreateThumbnailAtIndex)、送るときは長い辺1024pxの JPEG を CGImageDestination で一から作るので、位置情報(Exif の GPS)や撮影日時は含まない(テストで確かめている)。今いる場所は送らない。写真は端末に保存しない(作る画面を閉じても、アプリの中で `ObjectComposeJob.photos` に残る)
        - 指示(`ObjectGenerator.photoSystemPrompt`): 文章から作るときの指示 + 写真から作るときの注意(写っていない側は推測、寸法がなければ人・車・ドアなどから見積もる、JSON の前に使った寸法の一覧 `<dimensions>`(見積もりには「(見積もり)」)、一番よく写っている面か入口の面を正面、個人が分かるものは形にしない)。Web 検索は使わない
        - 料金の目安(`estimatedPhotoCost`): 文章から作るときの目安 + 画像のトークン(`ScopeAskImage.estimatedTokens`、28px ごとのます目の数)
        - 最近作ったもの・作成中の帯は文章から作るときと同じ(`ObjectComposeRecord.photoCount`・`inputDimensions`。作り直しは、今選んでいる写真で)
      - 隠れた形(v0.9.25、`ObjectGeometry.hiddenShapeIndices`): ほかの1つの形の中に完全に入っている形。形を囲む同じ向きの箱の8つの角が、すべて入れ物の形の内側(面から1cm以上内側、`hiddenMargin`)にあれば隠れている(入れ物は凸なので、角が内側なら全体が内側)。入れ物は箱・円柱・円錐・角錐・球(板は入れ物にしない)。丸い形はカメラ表示の多角形の内側で判定する(円柱・円錐は12角形の内接の楕円、球は0.8倍の楕円体)。少しでもはみ出す形、面に貼った板、面がちょうど重なる形、同じ形の重なりは対象にしない。先に軸にそろえた箱で外して計算を減らす。確認の画面の「隠れた形を除く(n個)」(初期値オン、`removingShapes`。すべて除くことになるときは除かない)。半透明の入れ物の中の形は透けて見えるが、利用者の指定で初期値は除く
      - 進み具合(v0.9.24): ストリーミング(stream: true)で受け取る(`HTTPClaudeClient.stream`、`HTTPClient.stream` は URLSession.bytes で1行ずつ、通信量の記録はそのまま)。SSE の data の行を `ClaudeStreamAccumulator` が読み、作り始めた・考えている・検索中(検索の言葉)・結果を読んでいる・形を受け取り中(文章の中の "kind" の数)を出す。受け取り終わったら、今までと同じ ClaudeResponse にまとめる(pause_turn で送り返すブロックも、思考の署名・検索の入力を入れて組み立て直す)。待つ時間は「何も届かない時間」600秒
    - 位置のデバッグ: 仮想の移動の間は、仮想の位置から見る(自分の高さは、オブジェクトの地面 + 手の高さ)
  - 景色(v0.9.22、`Features/Scope/Scenery`。上部の切り替えの5つめ `ScopeSection.scenery`、`ScopeSightSource.scenery`)。山・稜線・海と湖と川・地名の層(`SceneryLayer`、`AppSettings.sceneryLayers`。初期値は地名以外オン)。選んだ層は、景色のカメラ表示のほか、地点・周辺・経路・電車のカメラ表示にも重ねる(`sceneryOverlaysOthers`、初期値オン)。範囲は 30/50/100/150/200/300/350km(`sceneryRadiusKm`、初期値100km。利用者の判断: 50kmだと東京の中心から富士山などが入らないため。v0.9.23 で150km以上を足した。150km以上に広げるときは、今いる場所で保存するデータ量の目安 `SceneryTileStore.estimatedBytes` を出して確かめる。範囲の選択肢にも目安と、いま保存してある量を出す)
    - 山(`MountainCatalog`、`Resources/mountains.json`): 国土地理院「日本の主な山岳標高」(1003山、山頂ごとに1,059件、2026-03-31版)の CSV から、山名・山頂名・標高・緯度経度・都道府県だけを同梱(約64KB、圧縮後約22KB)。作り直すときは `python scripts/update_mountains.py`(www.gsi.go.jp は古い TLS の再ネゴシエーションを使うので、そのサーバーへの接続だけ OP_LEGACY_SERVER_CONNECT を付ける)。ベクトルタイルの山名の注記(annoCtg 312〜316)は、位置が文字の置き場所で山頂から0.7〜4kmずれ、標高もないので使わない(利用者の判断)
    - 山の選び方(`MountainSelection`): 範囲の中の山の方角・距離・仰角(`WaypointElevation.angle`、地点と同じ)と、稜線から見えるか(`Skyline.visibility`)。優先 = (標高+300) ÷ √(距離km)、見えない山は0.1倍。カメラ表示では山の形の印(三角、頂点が山頂。見えない山は点線で薄く、設定 `sceneryShowsHiddenMountains` で隠せる)、名前は印の上に3段まで、優先の高い順に重ならない段へ(`SceneryLabelLayout`。文字の幅は見積もり)、1コマ30山まで。タップで詳細(`SceneryMountainSheet`)と「地点に登録」(標高は山岳標高の値を手入力として入れ、標高APIは呼ばない)。コンパス表示では、優先の高い12山を印にする
    - 稜線(`SkylineCalculator`、`Skyline`): 現在地から方角0.5°ごと(720本)に、25mから距離の1.2%ずつ(半径100kmで約400点)標高を引き、地点と同じ仰角の式で、見える高さが上がった所を記録する(0.02°未満の上がり方は最後の記録を更新するだけ)。最後が地平線。隠れているか: 目標の手前(2%か300m)までで一番高い仰角より低ければ隠れている(隣の方角も見て、どれかで見えていれば見える)。手前のデータがなければ「分からない」。描く線(`RidgeExtractor`): 次に見える所まで距離が開いている点(奥が谷)と地平線を、隣の方角で距離の比が1.25以内の点とつなぐ。濃さと太さは距離で決める(1kmで0.95、100kmで0.25)
    - 山が平たく見える対策(v0.9.29): (1) 画角は activeFormat.videoFieldOfView(長辺、歪みの補正の前)ではなく、歪みの補正が効いていれば geometricDistortionCorrectedVideoFieldOfView、ズームしていればその分を狭くした値(`WaypointProjection.effectiveFieldOfView`)。縦の画角は、長辺の正接 ÷ 縦横比 と、画面いっぱいに広げたときの切り取り(`tangents`。縦も横も1°の長さは同じ)で、これは以前から正しかった。(2) 粗い標高タイル(ズーム10以下)では、周り3×3のセルの最大値を使う(`TerrainGrid.maxPoolZoom`。粗いタイルはならした値なので尾根や頂が低く出る。保存量は変わらない。細かいタイルを広げる案は、東京で範囲100kmのとき ズーム12を10kmまで +1.1MB、ズーム11を30kmまで +1.0MB で見送った)。(3) 設定「山の高さの強調」(1倍・1.5倍・2倍、初期値1倍、`sceneryHeightScale`。景色の仰角だけに掛ける、`SceneryDrawOptions.heightScale`)。地点・電車・オブジェクトは同じ投影を使うので、画角の直しは全部に効く
    - 太陽と月(v0.9.30、`Features/Scope/Sky`。重ねる表示の「空と景色」の `ScopeLayer.sunMoon`)。計算は端末の中だけ(通信しない)
      - 位置(`Astronomy`): 太陽は NOAA の式(Meeus 25章の低い精度の式)、月は Meeus 47章の主な項(経度・距離32項、緯度30項)と地平の視差の補正。恒星時は平均恒星時、章動は主な4項。大気の屈折は Bennett の式(−1.5°より下は0)
      - 出入り(`SkyEvents.riseSet`): 国立天文台の暦計算室と同じ決め方(地平線での屈折 35′08″、日の出入りは太陽の上の縁、月の出入りは月の中心)。10分ごとに調べて二分法で1秒まで。東京(緯度35.6581° 経度139.7414°)の2026年6月・12月の日の出入り、6月の月の出入りが、暦計算室の表と1分以内(Python で試した差は30秒以内)、方位は0.2°以内(テスト `SkyTests`)。表示の時刻は分に四捨五入(`SkyText.time`)
      - 本当の日の出入り(`SkyEvents.terrainRiseSet`): 景色の稜線(`Skyline.horizonAngle`、方角ごとの見える高さ)に、太陽の上の縁(見かけの高さ+半径)が一致する時刻。2分ごとに調べて、出は最初、入りは最後。稜線は景色を計算していれば使い(管理の画面では、景色を計算した場所から1km以内のとき)、なければ地平線での時刻だけ
      - カメラ表示(`SkyRenderer`、`ScopeExtras.sky`。景色より先に描く): 今日(選んだ日)の太陽と月の通り道(10分ごと、地平線より下は点線で薄く)、1時間ごとの時刻の印、日の出・日の入り・月の出・月の入り・山から出る・山に沈むの方角(地平線の上の三角と時刻)、今(選んだ時刻)の太陽と月(月は満ち欠けの形。輝く側は、画面の上で太陽の向き。`moonLitPath`)。1日分(`SkyScene`)は、日付・約1kmの場所・稜線が変わったときだけ、メインスレッドの外で作る
      - 日時(`SkyTimePanel`、「…」の「太陽と月の日時を変える」): 今・今日・明日・夏至・冬至(`SkyEvents.solstice`、太陽の黄経が90°・270°)・日付を選ぶ、時刻のスライダー(5分刻み)。今以外のときは右上に「◯◯ の空」
      - 撮る流れ(v0.9.31): 「撮って聞く」と同じ形にした。スコープのカメラ表示の「撮って聞く」で撮って指で囲み、聞く画面(`ScopeAskView`)で「聞く」か「オブジェクトを作る」を選ぶ(`useChoices`)。「オブジェクトを作る」で、その写真と囲みを `ObjectComposeJob.addCapturedPhoto` に入れ(`isCollectingPhotos`・`opensPhotoComposer`)、聞く画面を閉じると、カメラ表示が写真から作る画面(`ObjectComposeView(photos: true)`)をシートで出す。作る画面の「カメラ表示で撮り足す」で閉じてカメラ表示に戻り、撮って囲む操作をくり返す(3枚まで。撮り足している間は、カメラ表示に帯 `ObjectPhotoCollectingBanner`「作る画面へ」)。オブジェクトの一覧から開いた作る画面の「カメラ表示で撮る」は、作る画面を閉じたあとにカメラ表示(`ScopeSightView(mode: .camera, source: .objects)`)を開く。ライブラリから選ぶ(`PhotosPicker`)は残した。作り始めたら撮り足すのは終わり。v0.9.30 の別のカメラの画面(UIImagePickerController)は消した
        - v0.9.30 の「撮る」でカメラがすぐ閉じた原因の見立て(実機で確かめていない): カメラの全画面表示(fullScreenCover)を、作る画面(シート)のフォームの中の Section に付けていた。カメラが出ると作る画面が隠れて onDisappear が呼ばれ、`isShowing` が変わってフォームが描き直され、表示を持っている Section が作り直されて閉じられた、という流れが一番ありそう。ほかの候補は、LiveContainer で UIImagePickerController のカメラが使えないこと、スコープの AVCaptureSession(入力を持ったまま止めている)との取り合い
      - 景色の画面の「太陽と月」の日の出入り(`SkyDetailView`): その日の出入り(地平線と稜線)、月の満ち欠け。ダイヤモンド富士・パール富士の予報(`SummitForecastView`、`SummitAlignmentSearch`): 山(初期値は富士山、`MountainPickerView` で山の一覧から)と見る場所(現在地か地点)を選び、これから365日、太陽・月の見かけの高さが山頂の見かけの仰角(`WaypointElevation.angle`、地球の丸みと地上の屈折)を横切る時刻を探し、方角が1.5°以内なら前後20分で中心と山頂の角度が一番小さい時刻を求め、±0.25°以内を候補にする。メインスレッドの外で、進み具合と中止(`SkyCancelFlag`)。新宿から富士山で、11/9〜10 と 2/1 の夕方(テスト)
    - 方角のデバッグ表示(v0.9.29): 仰角 −2°〜+10° の1°ごとの横線と数値(`ScopeCompassRose.drawRuler`)、画角の内訳(形式・歪み補正後・ズーム・計算に使う値)、縦横の1°の長さ(`pointsPerDegree`)、富士山(なければ一番目立つ山)の頂の仰角と、画面で地平線から何 pt 上か
    - 地形(`TerrainGrid`、`GSIElevationTile`): 地理院の標高タイル(dem_png、DEM10B)を、5kmまでズーム12(約30m)、30kmまでズーム10(約125m)、100kmまでズーム9(約250m)、200kmまでズーム8(約500m)、それより遠くはズーム7(約1km)で使う(なければ粗いほうへ)。粗いタイルでは山頂が低く出るので、30kmより遠い山の一覧の山頂を、半径3km・傾き0.25の円すいとして高さに足し、山頂の距離でも必ず調べる(`SkylinePeak`、`SkylineCalculator.rayPeaks`)。地球の丸みと屈折の式(距離²÷2R')は、球の上の厳密な式と比べて100〜400kmで0.002°以内(差は高い山の近い距離で最大約0.0011°)(テストで確かめている)。海の上は「データなし」なので海(0m)、タイルがない所は分からない。PNG は CGImage のビットの並びをそのまま読む(色の変換をしない)。404 は空のファイルで覚え、海として扱う。自分の高さが分からないときは、標高タイルの地面 + 手の高さ
    - 水面(`WaterMap`、`WaterBands`、`SceneryLabelReader`、`VectorTile`): 100kmまで(`SceneryRadius.vectorLimit`。範囲が広くても、格子とデータ量を増やさない)。ベクトルタイル提供実験のズーム8(128km四方)の waterarea(ftCode 5000。海も湖も面で入っている)を、1タイル512×512のます目に偶奇の規則で塗り、隣り合う水面を1つの区域にまとめる(タイルの境目もつなぐ)。名前は注記の 321(湖)・344/345(海・湾・水道)を、区域の中(5ますまで)に付ける。小さいズームの注記は1文字ずつに分かれているが、annoChar に名前全体があるので、同じ名前で30km以内の文字をまとめる。稜線の計算と同じ道のりで、方角ごとに一番手前の見える水面を記録し、同じ名前が続く方角を帯にする(1°未満は出さない。名前がなければ、標高タイルで海なら「海」、ほかは「湖・川」)。川の名前(322、30kmまで)と地名(記号の name、範囲まで)は、地面の高さで見えるものだけ点と文字で出す。protobuf の読み取りは自前(外部のライブラリは使わない)
    - 計算(`SceneryEngine`、actor): メインスレッドの外。読み込んだ標高タイルとベクトルタイルは覚えておき、使わなくなったタイルは捨てる。計算し直すのは、200m以上動いたとき、自分の高さが20m以上変わったとき、範囲や層を変えたとき、タイルを保存し終えたときだけ(`SceneryStore.update`)。計算中の依頼は、終わってから最後の1つだけ
    - 保存(`SceneryStore`、`SceneryTileStore`): Application Support/SmartDashboard/tiles/terrain/(dem|vector)/z/x/y。景色の画面かカメラ表示を開いている間(`setActive`)で、従量制でも省データでもない回線(`MapMode.canDownloadTiles`)のときだけ、2本ずつ取得する。地図タイルと合わせて、地図の設定の保存の上限まで(`TileDownloader.otherStoredBytes`)。モバイル通信では保存済みの範囲だけで計算し、その旨を出す。受信量は「スコープ」(`UsageCategory`。パスが /xyz/dem_png/ か /xyz/experimental_bvmap/)。景色の画面から削除できる。1か所あたりの量(実測): 30kmで約1.3〜2.2MB、50kmで約2.5〜3.4MB、100kmで約2.6〜4.6MB、150kmで約3.3〜5.7MB、200kmで約3.6〜5.9MB、300・350kmで約4.0〜6.5MB
    - 描画(`SceneryRenderer`): 地点・電車の印と同じ Canvas の中で、印より先に描く(`ScopeOverlay` / `ScopeTrainOverlay` に scenery を渡す)。毎コマ、画面の中心の方角から(画角+12°)より離れた点は投影しない。順に、稜線(遠い線から、暗い縁取り+白い線)、水面の帯(青、文字「東京湾 8km」)、川と地名、山(優先の低い順に描き、優先の高い山が上)
    - 位置のデバッグ: 仮想の移動の間は、景色を仮想の位置で計算する(カメラ表示は2秒ごとに見て、200m以上動いたら計算し直す。`MovementStore.setVisible(true)` で仮想の位置を進める)。自分の高さは標高タイルの地面 + 手の高さ
    - 出典(`SceneryAttribution`): 景色の画面と山の詳細、README
- Claude API(v0.9.18、`Features/Claude`)。小ツールを文章から作る・直す機能と、スコープのカメラの「撮って聞く」に使う。使う操作をしたときだけ通信する(自動では呼ばない)
  - 仕様の確認(2026-10-18、platform.claude.com のドキュメント): Claude Haiku 5.5 の ID は `claude-haiku-5-5`(別名も同じ)。画像の入力に対応。料金は100万トークンあたり 入力0.10ドル・出力0.50ドル・キャッシュの書き込み(5分)0.125ドル・(1時間)0.20ドル・読み込み0.01ドル(プロンプトが10万トークン以下のとき。超えると5倍の料金)。コンテキスト100万、最大出力12.8万。思考は適応的思考で、何も指定しなければオン。`thinking: {"type": "disabled"}` で切れる(effort が high 以下のとき)。`"enabled"`(budget_tokens)は 400 エラー。思考のトークンは出力として課金され、`usage.output_tokens` に含まれ、内訳が `usage.output_tokens_details.thinking_tokens`。思考の文章は初期値で返らない(display: omitted)
  - 呼び出し(`HTTPClaudeClient`): POST https://api.anthropic.com/v1/messages、ヘッダー x-api-key・anthropic-version: 2023-06-01・content-type: application/json。待つ時間は180秒(思考で時間がかかるため)。`HTTPClient.send(_:)`(v0.9.18 で追加した POST)を通すので、通信量の記録に入る(機能別の「Claude(送信を含む)」。Claude だけは送信量も数える `UsageCategory.countsSentBytes`)。呼び出しは `ClaudeClient` プロトコルで、テストでは決まった応答に差し替える
  - 依頼(`ClaudeRequest`): 思考は機能ごとの設定で `adaptive` か `disabled`(display は指定しない)。画像は base64 の JPEG。プロンプトキャッシュは cache_control(ephemeral、5分)で、小ツールは system prompt(形式の説明。約3,000トークン、最小の512トークンを超える)、カメラは最初のメッセージの「撮影の状況」の文まで(画像を含む)。思考のブロックは送り返さない(ツールを使わない会話では不要。送り返すと、会話の途中を変えたときに 400 になることがある)
  - 応答(`ClaudeResponse`): text のブロックをつなげる。usage の input・output・cache_creation_input_tokens・cache_read_input_tokens・output_tokens_details.thinking_tokens を `ClaudeUsage` に入れる。stop_reason が refusal なら拒否として扱う。エラーは本文の error.message を添えて、状態コードで分ける(401 無効なキー、402 支払い、403 権限、429 上限、529 混雑など。`ClaudeError`)
  - 共通の仕組み(`ClaudeService`、`AppEnvironment.claude`): APIキーは Keychain(`KeychainAccount.claudeAPIKey`)だけに保存し、画面・ログ・リポジトリに出さない。呼ぶ前に、キー・今月の使用額と上限・回線を確かめる(`ClaudeGate`。上限に達したら止めて理由を出す)。使用量は日本時間の月ごとに、呼び出したときの料金で計算した金額と一緒に記録する(`ClaudeLedger`、UserDefaults の claude.ledger、12か月)。金額 = 入力×入力の料金 + 出力(思考を含む)×出力の料金 + キャッシュの書き込み×書き込みの料金 + 読み込み×読み込みの料金(`ClaudePricing.cost`)。10万トークンを超えるプロンプトの高い料金は計算に入れていない(この2機能では超えない)
  - 設定(`AppSettings.claude` = `ClaudeSettings`、JSON で保存。設定の「AI」→「Claude API」、`ClaudeSettingsView`): APIキー、モデル(初期値 claude-haiku-5-5)、料金(初期値 0.10 / 0.50 / 0.125 / 0.01)、今月の使用量(トークン数と金額)、月の上限額(初期値5ドル)、機能ごとの思考(初期値はどちらもオン)、カメラの質問で送る情報(方角と上下の向き=初期値オン。地名・緯度経度・撮った方向にあるもの=居場所が推測できるので初期値オフ。v0.9.19 までの設定は、読み込むときに `privacyVersion` で送らない設定に合わせる)、Web 検索(初期値オン、1回の質問で3回まで)、画像の長い辺(初期値1024px、モバイル通信のときは768px)
  - 小ツールを文章から作る・直す(`ToolGenerator`、`ToolComposeView`): 一覧の「文章から作る(Claude)」と、JSONのツールの画面のメニューの「文章で直す(Claude)」(今の JSON と依頼文を送る)。形式の説明は docs/tools-format.md と同じものを `Resources/tools-format.md` に同梱し(check_local.py で一致を確かめる)、system prompt に入れる。応答から JSON を取り出し(コードブロックの記号や前後の文章を除く `extractJSON`)、`CustomToolParser` で検証する。誤りがあれば、1回目の答えと誤りの一覧を添えて、もう1回だけ頼む。それでも誤りがあれば誤りを表示し、手で直せるように JSON を開ける。検証を通ったら、既存の確認の画面(`ToolImportView`)を出し、保存は利用者が押す。1回の作成の呼び出し回数・トークン数・金額を出す
  - カメラで見えているものを聞く(`ScopeAsk`、`ScopeAskImage`、`ScopeAskView`): カメラ表示の右下の「撮って聞く」。映像の1コマを `AVCaptureVideoDataOutput` から取る(`FrameGrabber`。写真の撮影ではないのでシャッター音は鳴らない。頼んだときだけ画像にし、ふだんのコマはすぐ捨てる。縦向き videoRotationAngle 90)。画面に見えていた範囲(aspectFill)で切り出し、印などの重ね描きは含めない。全画面の質問の画面を出し、その間はカメラ・GPS・モーションを止める
    - 指で描いた形(1つ)を囲む四角で切り出し、形の外側を黒の80%で暗くし、長い辺を設定の大きさに縮めて JPEG(品質0.8)にする(`ScopeAskImage.render` / `prepare`)。描かなければ画像全体。取り消し(1つ前の囲みに戻す)と描き直し(囲みを消す)。囲みを変えたら、前のやり取りは捨てて新しい画像として聞く
    - 質問は入力か、よく使う質問のボタン(これは何？、何の建物？、何という山？、文字を読んで)。空なら「これは何ですか？」。一緒に送る情報は `ScopeAsk.contextText`(設定で選んだものだけ。撮った方向にあるものは、スコープで計算している印のうち画面に写る範囲のもの、近い順に15件まで)。地名は `PlaceNameResolver`(天気と共有、500m以内はキャッシュ)
    - system prompt で、「画像から分かること」と「推測」を分けて答え、分からないときは「分からない」と答えるよう指示する。人物がだれかは答えない
    - 続けて質問するときは、同じ画像と直近3回のやり取りだけを送る(`ScopeAsk.messages`。失敗したやり取りは送らない)。待っている間は「考え中…」と取り消しのボタン(Task の取り消し → URLSession の取り消し)。1回ごとにトークン数と金額を出す
    - 撮った画像そのものは端末に保存しない。v0.9.28 から、会話を「最近聞いたこと」に残すため、長い辺480pxに縮めた JPEG だけを保存する(下の「閉じても戻れる」)。カメラの許可の説明文(project.yml の NSCameraUsageDescription)に、「撮って聞く」のときだけ送ること・縮めた画像を保存することを書いた
    - 送る情報(v0.9.20): カメラに写っているものから見つけることを基本にし、初期値で送るのは画像・質問・方角と向きだけ。送った JPEG は CGImageDestination で一から作るので、位置などのメタデータ(EXIF・GPS)を含まない(テストで確かめている)。答えの下に「画像・質問・方角と向きを送信」(`ScopeAsk.sentItems`)
    - Web 検索(v0.9.20): Claude API のサーバー側の検索 `web_search_20250305`(基本の版。直接呼ぶ、コード実行を使わない)を tools に付ける(`ClaudeRequest.webSearchMaxUses`、max_uses は設定、初期値3)。system prompt で、検索の言葉に現在地・地名・住所・緯度経度を入れず、写っているものの特徴で検索するよう指示する。応答の text の citations(web_search_result_location の title・url)を出典として答えの下に出し、タップで SFSafariViewController(`ScopeAskSafariView`)。検索の回数は usage.server_tool_use.web_search_requests で、1,000回あたり10ドル(`ClaudePricing.webSearchPer1000`)を使用量と月の上限に含める。stop_reason が pause_turn なら、受け取った内容のブロックをそのまま(`ClaudeContent.raw`)assistant として足して続きを頼む(3回まで、`ScopeAsk.ask`)。Web 検索を付けた依頼が HTTP 400 なら(このモデル・組織で使えない)、検索なしで1回だけ聞き直して、その旨を出す。DuckDuckGo の Instant Answer API は使わない(api.duckduckgo.com の robots.txt がすべて禁止、利用条件のページがなくなっている、日本語では結果が出ない。利用者の判断)
    - 場所の特定(v0.9.20、`ScopeAskPlace`): system prompt で、答えの最後に `<place>{"identified": true, "name", "latitude", "longitude", "confidence": "high|medium|low", "reason"}</place>` か、特定できないときは `<place>{"identified": false, "reason"}</place>` を書かせ、表示からは消す。座標がない・範囲の外・0,0・名前がないものは特定できないとして扱う
    - 方角の照合(`ScopeAskPlaceCheck`。自分の位置は外に送らず、端末の中だけで計算): 撮ったときの位置からその座標への方角と距離を出し、撮ったときのカメラの向きと写る範囲(左右の半分 `halfFieldOfView`、分からなければ±30°)と比べる。範囲の中/少し外/30°以上外れたら「撮った方向と合いません」。10m未満・250km超は目安の注意
    - 地点に登録(`ScopeAskPlaceSheet`): 既存の地図(`MapContainerView`。回線で Apple Maps と保存済みの地理院タイルを切り替える)で位置を見て、タップでピンを動かす。名前を直して登録すると、標高は既存の仕組み(`WaypointStore.onNeedsElevation`)で自動で取る。メモに確からしさ・根拠・出典の URL(`ScopeAskPlaceMemo`)
- Claude で作る画面を閉じても戻れる(v0.9.28): オブジェクトを文章から作る(`ObjectComposeJob`)、小ツールを文章から作る・直す(`ToolComposeJob`)、撮って聞く(`ScopeAskJob`)。どれも AppEnvironment が1つ持ち、作る作業(Task)は画面ではなくこの入れ物が持つので、画面を閉じても作るのは続く(アプリの中で。バックグラウンドの処理はしない)
  - 帯(`ClaudeWorkBanner`): 作っている間は「作成中…」、できたら「できました(確認する)」。オブジェクトの一覧(`ObjectListView`)、小ツールの一覧(`ToolsView`)、スコープのカメラ表示(撮って聞く)の上に出し、タップで作る画面に戻る。作る画面を開いている間にできたものは、すぐ見たことにする(`isShowing`)
  - 最近作ったもの(`ClaudeRecents`、`ClaudeRecentList`): 機能ごとに最新10件、新しい順。Application Support/SmartDashboard/claude-recents/(objects.json・tools.json・scope-ask.json)に .atomic で保存(キャッシュの削除では消さない)。作り終わったときに入れ、捨てるのは利用者が「捨てる」を押したときか、一覧から消したときだけ。一覧に作った日時・入力した文・料金(概算)・保存済みか。タップで確認の画面を開き直して、保存・作り直し(同じ文で作り直す)ができる。オブジェクトの結果は返ってきた JSON などを保存し、開くときに読み直す(`ObjectComposeRecord.outcome`)。小ツールは JSON と、直したときのもとのツールの ID・JSON
  - 入力の文・細かさ・検索のオンとオフは残す(オブジェクト: objects.composeDraft / composeDetail2 / composeSearch2、小ツール: tools.composeDrafts に作る / 直すツールごと)
  - 進み具合の画面に「中止」(Task の取り消し → URLSession の取り消し)
  - 撮って聞く: 撮ったら会話を始め(`begin`)、質問を送ったときに記録する。画面を閉じても答えを待ち、届いたら帯に出す。メニューの「最近聞いたこと」(`ScopeAskRecentsView`)から開き直すと、縮めた画像と会話を出し、続けて質問するとその縮めた画像を送る。囲みを変えたら別の会話にする(前の会話は残る)。画面の「捨てる」で会話を消す
- 開発者向け: 運行情報の直近の応答(生のJSON)を1件だけ保存し、設定画面で表示・コピーできる(遅延時のサンプル収集用。追加の通信はしない)
- 設定: APIトークン、登録した地点・路線・駅・通貨ペア、地図(表示の切り替え、保存エリア、最大ズーム、容量の上限、進捗、削除、再ダウンロード)、自動更新ポリシー、受信バイト数、キャッシュ削除、各データの最終更新時刻

## 入力とレイアウト

- 入力欄のある画面には `.keyboardDismissable()` を付ける(キーボード上の「完了」、スクロールで閉じる)。入力欄の外のタップで閉じる処理は `KeyboardTapDismissInstaller` がアプリ全体で1つ受け持つ。改行キーのない数字キーボードの欄には `KeyboardCloseButton` も置く
- キーボードが結果を隠さないよう、入力欄とその結果は同じ行に置く
- 基準は最小の画面幅(幅320〜375pt)と、文字サイズを1〜2段階大きくした場合。固定幅や、1行に多くの要素を並べる作りは避ける。数値は lineLimit(1) と minimumScaleFactor、文章は省略せず折り返す。入りきらないときは `ViewThatFits` で2段にする
- ホームのカードの最小幅は280pt

## データ使用量の記録

- `MeteredHTTPClient` が URLSessionTaskMetrics の transactionMetrics(isCellular / isExpensive)で通信1回ごとに回線を判定し、通信先のホストとパスから機能(天気、為替、電車、レーダー、地図タイル、警報・地震、スコープ(標高API・景色のタイル)、Claude)を判定して `DataUsageStore` に記録する。従量制の回線はモバイル通信に含める。Claude API だけは、送る画像のほうが大きいので送信量も数える
- 回線別に分ける前の記録は「回線不明」として残す
- 地名(CLGeocoder)と Apple Maps の通信はiOSが行うため計測できない。地名は取得回数だけを記録する
- 任意の設定で、今月のモバイル通信量が上限を超えたら自動更新を止める(初期値オフ)

## 永続化

- 設定: UserDefaults / AppStorage
- キャッシュと時刻表: Application Support以下にJSON
- トークン: Keychain。コードやリポジトリには絶対に書かない

## 秘密情報

トークンなどの秘密情報は絶対にコミットしない。フィクスチャにも含めない。`.gitignore` を維持する。Claude の APIキーは利用者が持っていて、開発側には渡さない(動作の確認は、API を呼ばない仮の応答で行う)。check_local.py が sk-ant- で始まる文字列を探す。

## テスト

- APIクライアントはプロトコルで抽象化する
- JSONデコードのユニットテストを用意する。フィクスチャは実際のレスポンスを小さく切り詰めたもの
- `@MainActor` なクラスの静的メンバーをテストから呼ぶときは、`nonisolated static` にするか、テスト側を `@MainActor` にする
- ファイルを書くとき、文字列補間 `\\(` のバックスラッシュを二重にしない(check_local.py が検出する)
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
- 同梱データの更新(警報の地域の表 `scripts/update_jma_areas.py`、震度観測点の一覧 `scripts/update_jma_stations.py`、線路の形 `scripts/update_railway_shapes.py`、山の一覧 `scripts/update_mountains.py`)は手元のスクリプトで行う。Actions では実行しない
- 実行する前に `python scripts/check_local.py` を通す(フィクスチャのJSON、YAML、ワークフローのトリガー、apps.json生成、括弧の対応、@MainActor の静的メンバーをテストから呼ぶ誤り、文字列が行の途中で切れていないか、同梱した形式の説明が docs と同じか、Claude の APIキーらしき文字列)。macOSが不要な確認をActionsで回さない
- 失敗したときは `gh run view --log-failed` でログから原因をまとめて特定し、関連する修正を1回で直してから再実行する。1行ずつ直して何度も回さない
- 段階の報告には、その段階で Actions を何回実行したかを書く

## 進め方

段階的に進める。各段階の区切りで1回だけ ci を実行し、ビルドとテストが通ることを確認する。

- 最初の6段階(骨組み、天気と為替、タイマー、センサー、電車、ホームと仕上げ)は完了している。以後は、依頼ごとに1つの区切りとして進めている
- 1回の区切りの流れ: 調査(必要なら実データで確認)→ 実装 → ユニットテスト → `python scripts/check_local.py` → CLAUDE.md・README・docs/handoff.md の更新 → 項目ごとにコミット → push → ci を1回 → 成功したコミットにタグ → release と apps.json の反映を確認 → 報告(実機で見てほしい点と、Actions の回数を含める)
- 依頼の内容と実際のデータが食い違うとき(URLが古い、指定が矛盾している、など)は、採った扱いと理由を報告に書く

## コミットメッセージ

- Conventional Commits 形式、本文は日本語。例: `feat: 天気画面を追加` / `fix: 為替キャッシュの期限判定を修正` / `ci: ipaのリリース処理を追加`
- 種類: feat / fix / refactor / test / ci / docs / chore
- 1コミットには1つのまとまった変更だけを入れる(1つの段階を複数のコミットに分けてよい)
- ワークフローによる apps.json の自動更新コミットは `chore: apps.json を v1.2.3 に更新 [skip ci]` の形にする

## コードの書き方

- コメントは日本語。絵文字は使わない
- 表示は日本語。ダークモード対応。主要な数値は大きく表示する
