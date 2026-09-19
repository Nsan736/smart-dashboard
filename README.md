# スマートダッシュボード

天気、為替、電車、センサー、タイマーを1つにまとめた、iOS向けの個人用ダッシュボードです。
AltStore / LiveContainer で使うことを前提に、通信量を最小にする設計にしています。

## インストール

- ipaを直接入れる: https://github.com/Nsan736/smart-dashboard/releases/latest/download/SmartDashboard.ipa
- AltStoreのソース: https://raw.githubusercontent.com/Nsan736/smart-dashboard/main/apps.json

## 通信の方針

- 起動時と復帰時に、古くなったデータだけを取得します(天気30分、為替1日1回、運行情報5分)。定期ポーリングはしません
- 従量制の回線や省データモードの間は自動更新を止め、手動更新だけにします
- 時刻表は手動で一度だけダウンロードし、以後は通信なしで次の電車を表示します
- 受信したデータ量(今日・今月)は設定画面で確認できます

## 開発

Xcodeプロジェクトは XcodeGen で生成します。

```bash
brew install xcodegen
```

```bash
xcodegen generate
```

ビルドとテストはGitHub Actionsで実行します。`v*` のタグをpushすると、署名なしのipaをReleasesに公開し、`apps.json` を更新します。

事業者を増やすときは `SmartDashboard/Features/Train/OperatorCatalog.swift` に1行追加します。
ODPTのアクセストークンはアプリの設定画面で入力し、Keychainだけに保存します。リポジトリには含めません。

## データの出典

- 気象データ: [Open-Meteo](https://open-meteo.com/) (CC BY 4.0)
- 為替レート: [Rates By Exchange Rate API](https://www.exchangerate-api.com)
- 公共交通データ: 公共交通オープンデータセンター。都営のデータは東京都交通局・公共交通オープンデータ協議会 (CC BY 4.0)

本アプリケーション等が利用する公共交通データは、公共交通オープンデータセンターにおいて提供されるものです。
公共交通事業者により提供されたデータを元にしていますが、必ずしも正確・完全なものとは限りません。
本アプリケーションの表示内容について、公共交通事業者への直接の問合せは行わないでください。
