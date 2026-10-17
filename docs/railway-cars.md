# 路線ごとの両数の表

スコープの電車(カメラ表示の電車の形)で使う両数です。アプリに同梱している `SmartDashboard/Resources/railway_cars.json` と同じ内容です。確認日: 2026-10-18。

- 各社の公式サイト(車両の紹介、事業の概要・統計、ニュースリリース)で確かめた値だけを書いています。推測や記憶では埋めていません
- ODPT のデータ(odpt:TrainTimetable、odpt:Train、odpt:StationTimetable)には両数(odpt:carComposition)がありません(2026-10-18に、公開エンドポイントの三田線の全758本と、利用者が用意したサンプルで確認)。列車番号の末尾には文字(三田線では T・K・G、浅草線では K・T・H・N・a・b など)がありますが、意味を公式の資料で確かめられないので、見分けには使っていません
- 両数の違う列車が混在し、データから見分けられない路線は、多いほうの両数を使い、列車の詳細とスコープに「両数は目安」と出します。公式の資料で1列車の両数を確かめられなかった路線も同じです
- 決め方の順: データの両数(あれば) → 設定の「路線ごとの両数」の上書き → 表の規則 → 表の両数 → 路線の種類ごとの目安(表にない路線)
- 調べ直したら、JSON とこのファイルの両方を直します

| 路線 | 両数 | 混在・見分け | 内容 |
|---|---|---|---|
| 東京メトロ 銀座線<br>`TokyoMetro.Ginza` | 6 | なし | 1000系 6両(40編成240両)。他社の乗り入れなし |
| 東京メトロ 丸ノ内線<br>`TokyoMetro.Marunouchi` | 6 | なし | 2000系 6両(52編成312両)。他社の乗り入れなし |
| 東京メトロ 丸ノ内線(分岐線)<br>`TokyoMetro.MarunouchiBranch` | 6 | なし | 3両の運転は2022年8月27日のダイヤ改正で終わり、分岐線もすべて6両 |
| 東京メトロ 日比谷線<br>`TokyoMetro.Hibiya` | 7 | なし | 13000系 7両。乗り入れる東武70000系も7両 |
| 東京メトロ 東西線<br>`TokyoMetro.Tozai` | 10 | なし | 15000系・07系・05系 10両。東葉高速2000系は10両(1号車・10号車の記載から)。JR E231系800番台はJRの公式で未確認 |
| 東京メトロ 千代田線<br>`TokyoMetro.Chiyoda` | 10 | なし<br>規則: 3両 = 綾瀬〜北綾瀬だけを走る列車は05系の3両 | 16000系 10両。綾瀬〜北綾瀬の折り返しは3両(05系 3両×4編成)。北綾瀬へ直通する10両の列車もある。小田急4000形とJR E233系は各社の公式で未確認 |
| 東京メトロ 有楽町線<br>`TokyoMetro.Yurakucho` | 10 | 混在(目安) | 10000系・17000系 10両が中心。副都心線と共通の車両に17000系 8両と西武40000系 8両があり(有楽町線・副都心線で57編成540両)、8両が有楽町線を走るかは公式に記載なし |
| 東京メトロ 副都心線<br>`TokyoMetro.Fukutoshin` | 10 | 混在(目安) | 10両と8両が混在(17000系 8両、東急5050系 8両、横浜高速Y500系 8両など)。2013年の資料では急行・通勤急行は10両、各停は8両(一部10両)だが、今の運用は公式で未確認。ODPTのデータに両数はない |
| 東京メトロ 半蔵門線<br>`TokyoMetro.Hanzomon` | 10 | なし | 18000系・08系・8000系 10両。東急2020系・5000系も10両。東武50050型は東武の公式で未確認 |
| 東京メトロ 南北線<br>`TokyoMetro.Namboku` | 8 | 混在(目安) | 6両と8両が混在。9000系の8両化を2023年12月16日から進めている(23編成146両で、8両は4編成)。東急3000系・相鉄21000系は8両、埼玉高速2000系は6両。どの列車が8両かは公式に記載なし |
| 都営 浅草線<br>`Toei.Asakusa` | 8 | なし | 5500形 8両。乗り入れる京成・京急・北総の車両も、都営の資料ではすべて8両 |
| 都営 三田線<br>`Toei.Mita` | 8 | 混在(目安) | 6300形 6両(24編成)と6500形 8両(13編成)が混在。東急・相鉄の車両は8両。どの列車が8両かは公式に規則がない。ODPTのデータに両数はなく、列車番号の末尾の文字(T・K・G)の意味は公式で未確認 |
| 都営 新宿線<br>`Toei.Shinjuku` | 10 | なし | 10-300形 10両(28編成)。乗り入れる京王の車両は、都営の資料で10両(京王の公式は未確認) |
| 都営 大江戸線<br>`Toei.Oedo` | 8 | なし | 12-000形・12-600形 8両。他社の乗り入れなし |
| 都電荒川線(東京さくらトラム)<br>`Toei.Arakawa` | 1 | 公式で未確認(目安) | 在籍33両(形式ごとの両数だけ)。1列車の両数は、読めた公式資料に記載がない |
| 日暮里・舎人ライナー<br>`Toei.NipporiToneri` | 5 | なし | 5両×20編成 |
| 横浜市営地下鉄 ブルーライン<br>`YokohamaMunicipal.Blue` | 6 | なし | 6両(37編成222両)。他社の乗り入れなし |
| 横浜市営地下鉄 グリーンライン<br>`YokohamaMunicipal.Green` | 6 | 混在(目安) | 4両と6両が混在(17編成中10編成が6両)。公式の駅時刻表では6両の列車に印があり、平日朝の上りに集中しているが、ODPTのデータには両数がない |
| つくばエクスプレス<br>`MIR.TsukubaExpress` | 6 | なし | 6両(41編成)。8両化は2030年代前半が目標で工事中、8両の営業列車はまだない |
| りんかい線<br>`TWR.Rinkai` | 10 | なし | 70-000形・71-000形 10両。JR埼京線の車両(E233系)も入るが、その両数はJRの公式で未確認 |
| 多摩モノレール<br>`TamaMonorail.TamaMonorail` | 4 | なし | 1編成4両(16編成64両) |
| ゆりかもめ<br>`Yurikamome.Yurikamome` | 6 | なし | 6両(7300系・7500系) |

## 出典

- 東京メトロ 銀座線: <https://www.tokyometro.jp/corporate/enterprise/passenger_rail/cars/working/>、<https://www.tokyometro.jp/corporate/ir/library/factbook/pdf/factbook_2026.pdf>
- 東京メトロ 丸ノ内線: <https://www.tokyometro.jp/corporate/enterprise/passenger_rail/cars/working/>、<https://www.tokyometro.jp/corporate/ir/library/factbook/pdf/factbook_2026.pdf>
- 東京メトロ 丸ノ内線(分岐線): <https://www.tokyometro.jp/corporate/enterprise/passenger_rail/cars/working/>、<https://www.tokyometro.jp/news/images_h/metroNews220707_2.pdf>
- 東京メトロ 日比谷線: <https://www.tokyometro.jp/corporate/enterprise/passenger_rail/cars/working/>、<https://www.tokyometro.jp/corporate/ir/library/factbook/pdf/factbook_2026.pdf>、<https://www.tobu.co.jp/corporation/rail/vehicles/>
- 東京メトロ 東西線: <https://www.tokyometro.jp/corporate/enterprise/passenger_rail/cars/working/>、<https://www.tokyometro.jp/corporate/ir/library/factbook/pdf/factbook_2026.pdf>
- 東京メトロ 千代田線: <https://www.tokyometro.jp/corporate/enterprise/passenger_rail/cars/working/>、<https://www.tokyometro.jp/corporate/ir/library/factbook/pdf/factbook_2026.pdf>、<https://www.tokyometro.jp/news/images_h/metroNews20181214_124.pdf>、<https://www.tokyometro.jp/safety/attention/women/index.html>
- 東京メトロ 有楽町線: <https://www.tokyometro.jp/corporate/enterprise/passenger_rail/cars/working/>、<https://www.tokyometro.jp/corporate/ir/library/factbook/pdf/factbook_2026.pdf>
- 東京メトロ 副都心線: <https://www.tokyometro.jp/corporate/enterprise/passenger_rail/cars/working/>、<https://www.tokyometro.jp/corporate/ir/library/factbook/pdf/factbook_2026.pdf>、<https://www.tokyometro.jp/news/2013/pdf/metroNews20130122_1306-1.pdf>
- 東京メトロ 半蔵門線: <https://www.tokyometro.jp/corporate/enterprise/passenger_rail/cars/working/>、<https://www.tokyometro.jp/corporate/ir/library/factbook/pdf/factbook_2026.pdf>
- 東京メトロ 南北線: <https://www.tokyometro.jp/corporate/enterprise/passenger_rail/cars/working/>、<https://www.tokyometro.jp/corporate/ir/library/factbook/pdf/factbook_2026.pdf>、<https://www.tokyometro.jp/news/images_h/metroNews231213_78.pdf>
- 都営 浅草線: <https://www.kotsu.metro.tokyo.jp/about/information/statistics/pdf/statistics_2023_03.pdf>、<https://www.kotsu.metro.tokyo.jp/about/service/pdf/aramashi_04.pdf>、<https://www.keisei.co.jp/keisei/keisei_museum/pictbook/>、<https://www.keikyu.co.jp/ride/train/>、<https://www.hokuso-railway.co.jp/trackside/train/>
- 都営 三田線: <https://www.kotsu.metro.tokyo.jp/about/information/statistics/pdf/statistics_2023_03.pdf>、<https://www.kotsu.metro.tokyo.jp/about/service/pdf/aramashi_04.pdf>、<https://www.kotsu.metro.tokyo.jp/pickup_information/news/pdf/2025/sub_p_2025021411894_h_01.pdf>、<https://www.tokyu.co.jp/company/news/detail/388.html>、<https://www.sotetsu.co.jp/life/gallery/train/>
- 都営 新宿線: <https://www.kotsu.metro.tokyo.jp/about/information/statistics/pdf/statistics_2023_03.pdf>、<https://www.kotsu.metro.tokyo.jp/about/service/pdf/aramashi_04.pdf>
- 都営 大江戸線: <https://www.kotsu.metro.tokyo.jp/about/information/statistics/pdf/statistics_2023_03.pdf>
- 都電荒川線(東京さくらトラム): <https://www.kotsu.metro.tokyo.jp/about/information/statistics/pdf/statistics_2023_05.pdf>
- 日暮里・舎人ライナー: <https://www.kotsu.metro.tokyo.jp/about/information/statistics/pdf/statistics_2023_06.pdf>、<https://www.kotsu.metro.tokyo.jp/about/service/pdf/aramashi_07.pdf>
- 横浜市営地下鉄 ブルーライン: <https://www.city.yokohama.lg.jp/kotsu/kigyo/gaiyou/subway.html>、<https://www.city.yokohama.lg.jp/city-info/yokohamashi/org/kotsu/yosan/r8yosangaiyou.files/r8yosangaiyou.pdf>
- 横浜市営地下鉄 グリーンライン: <https://www.city.yokohama.lg.jp/kotsu/sub/gl426.html>、<https://www.city.yokohama.lg.jp/kotsu/kigyo/oshirase/20250918-daiyakaisei.html>
- つくばエクスプレス: <https://www.mir.co.jp/feature/about_tx/>、<https://www.mir.co.jp/company/plan_2026.pdf>
- りんかい線: <https://www.twr.co.jp/route/tabid/144/Default.aspx>、<https://www.twr.co.jp/Portals/0/resources/info/2023/20231106_information.pdf>、<https://www.twr.co.jp/20th/tabid/337/Default.aspx>
- 多摩モノレール: <https://www.tama-monorail.co.jp/ad/tamamonorail_price2020.pdf>
- ゆりかもめ: <https://www.yurikamome.co.jp/company/about.html>、<https://www.yurikamome.co.jp/feature/vehicle/>

## 見分けられない路線と理由

- 三田線: 6300形 6両と6500形 8両が混在。どの列車が8両かの規則は公式にない(2025年3月のダイヤ改正で夕方の8両を増やした、という記載だけ)。公式の駅時刻表に6両の印があるという情報もあるが、交通局のサイトのボット確認で開けず未確認
- 南北線: 9000系の8両化の途中(23編成146両のうち8両は4編成)。東急・相鉄の車両は8両、埼玉高速は6両。規則は公式にない
- 副都心線: 10両と8両が混在。2013年の資料の規則(急行・通勤急行は10両、各停は8両)は、今の運用か確かめられない
- 有楽町線: 副都心線と共通の車両に8両があり、有楽町線を8両が走るかは公式に記載がない
- グリーンライン: 4両と6両が混在。公式の駅時刻表には6両の印があるが、ODPT のデータにはない
- 荒川線: 1列車の両数が、読めた公式資料に書かれていない(在籍33両の形式ごとの数だけ)

## 見分けられる規則

- 千代田線: 停車駅が綾瀬と北綾瀬だけの列車は3両(05系 3両×4編成)。北綾瀬へ直通する10両の列車は、停車駅にほかの駅を含むので10両になる

## 公式で確かめられなかった他社の車両

- 東西線に入る JR E231系800番台、千代田線に入る小田急4000形と JR E233系、半蔵門線に入る東武50050型、りんかい線に入る JR E233系、新宿線に入る京王の車両(都営の資料では10両)。各社の公式サイトが開けないか、両数の記載がなかった。乗り入れ先の路線の両数(表の値)と同じとして扱っている
