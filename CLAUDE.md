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
- NWPathMonitorで isExpensive / isConstrained を検知し、その間は自動更新を止めて手動更新だけにする。「Wi-Fi時のみ自動更新」のトグルもある
- 設定画面に受信バイト数の累計(今日・今月)を表示する(URLSessionTaskMetricsで計測)
- 通信は必ず `HTTPClient` プロトコル(本番は `MeteredHTTPClient`)を経由する。`URLSession.shared` を直接使わない

## LiveContainerでの制約

- ウィジェット、Live Activity、App Extension、プッシュ通知(APNs)、バックグラウンド更新は使わない
- 位置・モーション・マイクなどの権限が取れなくてもクラッシュさせず、「利用不可」と表示し、他の機能は使えるようにする
- Info.plistに NSLocationWhenInUseUsageDescription、NSMotionUsageDescription、NSMicrophoneUsageDescription を入れておく

## 画面構成(TabView)

ホーム(まとめ) / 天気(Open-Meteo) / 為替(open.er-api.com、JPY基準、1日1回) / 電車(ODPT API v4) / センサー(すべて通信なし、表示中のみ動作) / タイマー / 設定

詳細:
- 天気: current / hourly / daily は使う変数だけを指定。位置は現在地(低精度・省電力)か登録地点。天気コードはSF Symbolsと日本語ラベルに変換
- 為替: 「1外貨=◯円」で表示。初期ペアは USD、EUR、GBP、CNY、KRW。オフラインで動く換算機能。日次レートである旨と出典(ExchangeRate-API)を表示
- 電車: トークン不要の `api-public.odpt.org` と、トークン必要の `api.odpt.org`(`acl:consumerKey`)の両方に対応。事業者の定義はコード内の1か所(`OperatorCatalog`)にまとめる。路線・駅はコードに固定で書かず、設定画面で事業者→路線→駅→方面の順に選んで登録する。時刻表は手動で一度だけダウンロードして以後は通信なしで次発を表示。平日/土休日は自動切替(祝日は内蔵の簡易テーブル)。出典の表示を入れる
- ODPTの動作確認とフィクスチャには都営の公開エンドポイントを使う。トークンが必要な事業者のサンプルJSONはユーザーが用意する
- 不明な点(APIのレスポンス形式など)は推測で埋めない。公式ドキュメントを確認するか、ユーザーにサンプルJSONを求める
- タイマー: 終了時刻はDateで保持。ローカル通知 + アプリ内の音とバイブ。画面を消さないオプション
- 設定: APIトークン、登録した地点・路線・駅・通貨ペア、自動更新ポリシー、受信バイト数、キャッシュ削除、各データの最終更新時刻

## 永続化

- 設定: UserDefaults / AppStorage
- キャッシュと時刻表: Application Support以下にJSON
- トークン: Keychain。コードやリポジトリには絶対に書かない

## 秘密情報

トークンなどの秘密情報は絶対にコミットしない。フィクスチャにも含めない。`.gitignore` を維持する。

## テスト

- APIクライアントはプロトコルで抽象化する
- JSONデコードのユニットテストを用意する。フィクスチャは実際のレスポンスを小さく切り詰めたもの
- テストに使うスレッド・並列数は10まで

## ビルドと検証(GitHub Actions)

開発機はWindowsでXcodeがないため、ビルドとテストの検証はGitHub Actionsの結果で行う。

- ランナーは macos-15、Xcodeは明示的に選ぶ(現在 16.4)。XcodeGenはbrewでインストールする
- テストはiOSシミュレーターで実行する(`-destination 'platform=iOS Simulator,...'`)
- mainへのpush: ビルドとテストのみ
- タグ `v*` のpush: `xcodebuild -sdk iphoneos CODE_SIGNING_ALLOWED=NO` で署名なしビルド → `Payload/SmartDashboard.app` をzipして `SmartDashboard.ipa` を作成 → GitHub Releasesへアップロード → `apps.json`(AltStoreソース)を更新してmainに直接コミット
- ipaのファイル名は固定(`SmartDashboard.ipa`)。`releases/latest/download/SmartDashboard.ipa` でも取得できるようにする
- ワークフローには `permissions: contents: write` を付ける
- ビルドが失敗したら `gh run view --log-failed` でログを確認して修正し、通るまで繰り返す

## 進め方

段階的に進める。各段階でビルドとテストが通ることを確認してからコミットを確定させる。

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
